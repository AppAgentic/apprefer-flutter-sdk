import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

enum AppReferEventResult { sent, queued, dropped }

/// Durable, at-least-once product delivery. Transport must make one attempt.
class EventQueue {
  EventQueue(this.send, this.enabled);
  final Future<int?> Function(Map<String, dynamic>) send;
  final bool Function() enabled;
  static const key = 'apprefer_pending_events';
  int _generation = 0;
  bool _running = false;
  Timer? _timer;
  Future<void> _writes = Future.value();
  Future<T> _serial<T>(Future<T> Function() fn) {
    final result = _writes.then((_) => fn());
    _writes = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(key);
    final values = raw == null ? <dynamic>[] : jsonDecode(raw) as List;
    final valid = values
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where(
          (e) =>
              DateTime.now().millisecondsSinceEpoch - (e['created'] as num) <
              7 * 86400000,
        )
        .toList();
    return valid.skip(max(0, valid.length - 1000)).toList();
  }

  Future<void> _save(List<Map<String, dynamic>> values) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode(values.skip(max(0, values.length - 1000)).toList()),
    );
  }

  Future<void> clear() async {
    _generation++;
    _timer?.cancel();
    await _serial(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
    });
  }

  Future<AppReferEventResult> enqueue(Map<String, dynamic> body) async {
    if (!enabled()) {
      await clear();
      return AppReferEventResult.dropped;
    }
    final epoch = _generation;
    final random = Random.secure();
    final id = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final copy =
        jsonDecode(jsonEncode({...body, 'eventId': id}))
            as Map<String, dynamic>;
    await _serial(() async {
      if (epoch != _generation) return;
      final values = await _load();
      values.add({
        'id': id,
        'body': copy,
        'created': DateTime.now().millisecondsSinceEpoch,
        'attempts': 0,
        'next': 0,
      });
      await _save(values);
    });
    final results = await flush();
    if (epoch != _generation) return AppReferEventResult.dropped;
    final status = results[id];
    return status == null
        ? AppReferEventResult.queued
        : status >= 200 && status < 300
        ? AppReferEventResult.sent
        : AppReferEventResult.dropped;
  }

  Future<Map<String, int>> flush() async {
    final results = <String, int>{};
    if (!enabled()) {
      await clear();
      return results;
    }
    if (_running) return results;
    _running = true;
    final epoch = _generation;
    try {
      final values = await _serial(() async {
        final v = await _load();
        await _save(v);
        return v;
      });
      for (final entry in values) {
        if (epoch != _generation || !enabled()) break;
        if ((entry['next'] as num) > DateTime.now().millisecondsSinceEpoch)
          continue;
        final status = await send(
          Map<String, dynamic>.from(entry['body'] as Map),
        );
        await _serial(() async {
          if (epoch != _generation) return;
          final current = await _load();
          if (status != null && !(status >= 500 && status < 600)) {
            current.removeWhere((e) => e['id'] == entry['id']);
            results[entry['id'] as String] = status;
          } else {
            for (final e in current.where((e) => e['id'] == entry['id'])) {
              final attempts = (e['attempts'] as int) + 1;
              e['attempts'] = attempts;
              e['next'] =
                  DateTime.now().millisecondsSinceEpoch +
                  min(3600000, 1000 * pow(2, min(attempts, 12))).toInt();
            }
          }
          await _save(current);
        });
      }
    } finally {
      _running = false;
      if (epoch == _generation) {
        final current = await _serial(_load);
        _timer?.cancel();
        if (current.isNotEmpty) {
          final next = current
              .map((e) => (e['next'] as num).toInt())
              .reduce(min);
          _timer = Timer(
            Duration(
              milliseconds: max(
                100,
                next - DateTime.now().millisecondsSinceEpoch,
              ),
            ),
            () {
              unawaited(flush());
            },
          );
        }
      }
    }
    return results;
  }
}
