import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

class EventResponse {
  const EventResponse(this.status, {this.retryAfter = 0});
  final int? status;
  final int retryAfter;
}

enum AppReferEventResult { sent, queued, dropped }

/// Durable, at-least-once product delivery. Transport must make one attempt.
class EventQueue {
  EventQueue(this.send, this.enabled, {bool Function()? held})
    : held = held ?? (() => false);
  Future<dynamic> Function(Map<String, dynamic>) send;
  bool Function() enabled;

  /// True after reset() until configure: events stay queued but are not sent.
  final bool Function() held;
  void replace(
    Future<dynamic> Function(Map<String, dynamic>) send,
    bool Function() enabled,
  ) {
    _generation++;
    _running = false;
    _timer?.cancel();
    this.send = send;
    this.enabled = enabled;
  }

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
    try {
      final values = raw == null ? <dynamic>[] : jsonDecode(raw) as List;
      final valid = values
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where(
            (e) =>
                DateTime.now().millisecondsSinceEpoch - (e['created'] as num) <
                7 * 86400000,
          )
          .toList();
      if (valid.any(
        (e) =>
            e['id'] is! String ||
            e['body'] is! Map ||
            e['attempts'] is! int ||
            e['next'] is! num,
      ))
        throw const FormatException('Queue');
      return valid.skip(max(0, valid.length - 1000)).toList();
    } catch (_) {
      if (raw != null && !await prefs.setString('$key.corrupt', raw))
        throw StateError('Quarantine failed');
      if (!await prefs.remove(key)) throw StateError('Queue clear failed');
      return [];
    }
  }

  Future<void> _save(List<Map<String, dynamic>> values) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(
      key,
      jsonEncode(values.skip(max(0, values.length - 1000)).toList()),
    );
    if (!saved) throw StateError('Queue save failed');
  }

  Future<void> clear() async {
    _generation++;
    _running = false;
    _timer?.cancel();
    await _serial(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(key);
      await prefs.remove('$key.corrupt');
    });
  }

  Future<AppReferEventResult> enqueue(Map<String, dynamic> body) async {
    try {
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
      if (epoch != _generation)
        return _serial(
          () async => (await _load()).any((e) => e['id'] == id)
              ? AppReferEventResult.queued
              : AppReferEventResult.dropped,
        );
      final results = await flush(only: id);
      if (epoch != _generation)
        return _serial(
          () async => (await _load()).any((e) => e['id'] == id)
              ? AppReferEventResult.queued
              : AppReferEventResult.dropped,
        );
      final status = results[id];
      return status == null
          ? AppReferEventResult.queued
          : status >= 200 && status < 300
          ? AppReferEventResult.sent
          : AppReferEventResult.dropped;
    } catch (_) {
      return AppReferEventResult.dropped;
    }
  }

  Future<Map<String, int>> flush({String? only}) async {
    final results = <String, int>{};
    if (!enabled()) {
      await clear();
      return results;
    }
    if (held() || _running) return results;
    _running = true;
    final epoch = _generation;
    try {
      final values = await _serial(() async {
        final v = await _load();
        await _save(v);
        return v;
      });
      for (final entry in values) {
        if (epoch != _generation || !enabled() || held()) break;
        if ((only != null && entry['id'] != only) ||
            (entry['next'] as num) > DateTime.now().millisecondsSinceEpoch)
          continue;
        final response = await send(
          Map<String, dynamic>.from(entry['body'] as Map),
        );
        final int? status = response is EventResponse
            ? response.status
            : response as int?;
        final retryAfter = response is EventResponse ? response.retryAfter : 0;
        final retryable =
            status == null ||
            status == 408 ||
            status == 429 ||
            (status >= 500 && status < 600);
        await _serial(() async {
          if (epoch != _generation) return;
          final current = await _load();
          if (status != null && !retryable) {
            current.removeWhere((e) => e['id'] == entry['id']);
            results[entry['id'] as String] = status;
          } else {
            for (final e in current.where((e) => e['id'] == entry['id'])) {
              final attempts = (e['attempts'] as int) + 1;
              e['attempts'] = attempts;
              final next =
                  DateTime.now().millisecondsSinceEpoch +
                  max(
                    retryAfter,
                    min(3600000, 1000 * pow(2, min(attempts, 12))).toInt(),
                  );
              for (final item in current) {
                item['next'] = max((item['next'] as num).toInt(), next);
              }
            }
          }
          await _save(current);
        });
        if (retryable) break;
      }
    } catch (_) {
      // Retain durable events while storage is unavailable.
    } finally {
      if (epoch == _generation) {
        _running = false;
        try {
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
                unawaited(flush().catchError((Object _) => <String, int>{}));
              },
            );
          }
        } catch (_) {
          /* A later enqueue/activation retries storage. */
        }
      }
    }
    return results;
  }
}
