import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'billing_error.dart';
import 'billing_storage.dart';
import 'billing_store.dart';
import 'customer_info.dart';
import 'purchase_intents.dart';

abstract class ProtectedBillingState {
  Future<String?> read();
  Future<void> write(String value);
}

class NativeProtectedBillingState implements ProtectedBillingState {
  static const channel = MethodChannel('com.apprefer.sdk/adservices');
  @override
  Future<String?> read() =>
      channel.invokeMethod<String>('billingAutomaticStateGet');
  @override
  Future<void> write(String value) =>
      channel.invokeMethod<void>('billingAutomaticStateSet', value);
}

typedef AutomaticIdentity = ({String user, String revision, String? reset});

class AutomaticScopeTicket {
  final String user, key, revision, generation, context;
  final int epoch, transition;
  const AutomaticScopeTicket(
    this.user,
    this.key,
    this.revision,
    this.generation,
    this.context,
    this.epoch,
    this.transition,
  );
}

/// Only caller-authorized exact proofs may infer an automatic environment.
class AutomaticBillingScope {
  final ProtectedBillingState state;
  final String? Function() key;
  final AutomaticIdentity Function() identity;
  final int Function() epoch;
  final BillingEnvironment? explicit, nativeContext;
  Map<String, dynamic>? _doc;
  String? _context, _contextKey;
  int _seenEpoch, _transition = 0;
  bool _unfinalized = false;
  final _committed = <String>{};
  Future<void> _tail = Future.value();
  AutomaticBillingScope(
    this.state,
    this.key,
    this.identity,
    this.epoch, {
    this.explicit,
    this.nativeContext,
  }) : _seenEpoch = epoch();
  bool isIntentQuarantined(PurchaseIntent intent) =>
      _quarantinedIntents.contains(_intent(intent));
  void releaseIntentQuarantine(PurchaseIntent intent) =>
      _quarantinedIntents.remove(_intent(intent));
  static String tokenHash(String token) => _hash(token);
  final Set<String> _quarantinedIntents = {};
  void quarantineIntent(PurchaseIntent intent) =>
      _quarantinedIntents.add(_intent(intent));
  static String _hash(String s) => sha256.convert(utf8.encode(s)).toString();
  static String _intent(PurchaseIntent i) => _hash(
    jsonEncode([
      i.appUserId,
      i.productId,
      i.accountToken,
      i.startedAt.millisecondsSinceEpoch,
    ]),
  );
  static String _proof(Map<String, String> f) {
    final keys = f.keys.toList()..sort();
    return _hash(jsonEncode(keys.map((k) => [k, f[k]]).toList()));
  }

  static AppReferBillingException _error() => const AppReferBillingException(
    AppReferBillingErrorCode.storage,
    message: 'Automatic billing state unavailable',
  );
  Future<T> _run<T>(Future<T> Function() body) {
    final next = _tail.then((_) => body());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return next;
  }

  Map<String, dynamic> _map(Map<String, dynamic> d, String name) =>
      Map<String, dynamic>.from(d[name] as Map);
  Future<Map<String, dynamic>> _load() async {
    if (_doc != null) return _doc!;
    try {
      final raw = await state.read();
      final d = raw == null
          ? <String, dynamic>{
              'version': 1,
              'user': null,
              'revision': '',
              'reset': null,
              'generation': BillingStorage.generateUuidV4(),
              'contexts': <String, dynamic>{},
              'intents': <String, dynamic>{},
              'proofs': <String, dynamic>{},
            }
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (d['version'] != 1 ||
          (d['user'] != null && d['user'] is! String) ||
          d['revision'] is! String ||
          (d['reset'] != null && d['reset'] is! String) ||
          d['generation'] is! String)
        throw _error();
      for (final name in ['contexts', 'intents', 'proofs']) {
        if (d[name] is! Map) throw _error();
      }
      if (_map(
        d,
        'contexts',
      ).values.any((v) => v != 'production' && v != 'sandbox'))
        throw _error();
      for (final v in [
        ..._map(d, 'intents').values,
        ..._map(d, 'proofs').values,
      ]) {
        if (v is! Map ||
            v['context'] is! String ||
            v['generation'] is! String ||
            (v['intent'] != null && v['intent'] is! String) ||
            (v['proof'] != null && v['proof'] is! String))
          throw _error();
      }
      for (final name in ['completedProofs', 'completedIntents']) {
        if (d[name] != null &&
            (d[name] is! List || (d[name] as List).any((v) => v is! String)))
          throw _error();
      }
      d.remove(
        'pending',
      ); // Never use a candidate's proposed scope after a crash.
      return _doc = d;
    } catch (_) {
      _doc = null;
      throw _error();
    }
  }

  Future<void> _save(Map<String, dynamic> d) async {
    try {
      await state.write(jsonEncode(d));
      _doc = d;
    } catch (_) {
      _doc = null;
      _context = null;
      _contextKey = null;
      throw _error();
    }
  }

  BillingEnvironment? current() {
    final k = key();
    if (k == null) return explicit;
    if (k.startsWith('pk_test_'))
      return explicit == BillingEnvironment.production
          ? null
          : BillingEnvironment.sandbox;
    if (explicit != null) return explicit;
    final cached = _contextKey == k ? (_doc?['contexts']?[_context]) : null;
    final raw = _contextKey == k && _committed.contains(_context)
        ? cached
        : nativeContext?.name ?? cached;
    return raw == 'sandbox'
        ? BillingEnvironment.sandbox
        : BillingEnvironment.production;
  }

  int get transitionRevision => _transition;

  void noteTransition() {
    _transition++;
  }

  Future<void> setUser({bool invalidate = false}) => _run(() async {
    if (_unfinalized) await _finalize();
    final e = epoch(), i = identity(), d = await _load();
    if (invalidate ||
        _seenEpoch != e ||
        d['user'] != i.user ||
        d['revision'] != i.revision ||
        d['reset'] != i.reset) {
      await _save({
        ...d,
        'user': i.user,
        'revision': i.revision,
        'reset': i.reset,
        'generation': BillingStorage.generateUuidV4(),
        'intents': <String, dynamic>{},
        'proofs': <String, dynamic>{},
      });
    }
    _seenEpoch = e;
    final k = key();
    _contextKey = k;
    _context = k == null ? null : _hash('${i.user}\u0000$k');
  });
  Future<AutomaticScopeTicket?> capture(String user) async {
    await setUser();
    final k = key(), d = _doc;
    if (explicit != null ||
        k == null ||
        k.isEmpty ||
        k.startsWith('pk_test_') ||
        d == null ||
        d['user'] != user)
      return null;
    final t = AutomaticScopeTicket(
      user,
      k,
      d['revision'] as String,
      d['generation'] as String,
      _hash('$user\u0000$k'),
      _seenEpoch,
      _transition,
    );
    return isCurrent(t) ? t : null;
  }

  bool isCurrent(AutomaticScopeTicket t) {
    final i = identity();
    return explicit == null &&
        key() == t.key &&
        epoch() == t.epoch &&
        _transition == t.transition &&
        _doc?['generation'] == t.generation &&
        i.user == t.user &&
        i.revision == t.revision &&
        _doc?['reset'] == i.reset;
  }

  bool _matches(dynamic a, AutomaticScopeTicket t) =>
      a is Map && a['context'] == t.context && a['generation'] == t.generation;
  Future<void> authorizeIntent(PurchaseIntent i, AutomaticScopeTicket t) =>
      _authorize('intents', _intent(i), t);
  Future<void> authorizePending(
    PurchaseIntent i,
    Map<String, String> fields,
  ) async {
    final t = await capture(i.appUserId), token = fields['purchaseToken'];
    if (t == null || token == null || token.isEmpty) return;
    await _run(() async {
      if (!isCurrent(t)) throw _error();
      final d = await _load(),
          intents = _map(d, 'intents'),
          id = _intent(i),
          entry = intents[_intent(i)];
      if (!_matches(entry, t)) return;
      final hash = _hash(token);
      if (entry['pendingToken'] != null && entry['pendingToken'] != hash)
        throw _error();
      intents[id] = {
        ...Map<String, dynamic>.from(entry as Map),
        'pendingToken': hash,
      };
      await _save({...d, 'intents': intents});
    });
  }

  Future<AutomaticScopeTicket?> recoverIntent(
    PurchaseIntent i,
    StorePurchase p,
  ) async {
    if (p.isRenewal ||
        p.productId != i.productId ||
        p.purchasedAt == null ||
        p.purchasedAt!.isBefore(
          i.startedAt.subtract(const Duration(minutes: 5)),
        ) ||
        (i.accountToken != null && i.accountToken != p.accountToken))
      return null;
    if (_quarantinedIntents.contains(_intent(i)) ||
        (i.pendingTokenHash != null &&
            (p.purchaseToken == null ||
                i.pendingTokenHash != _hash(p.purchaseToken!))))
      return null;
    final t = await capture(i.appUserId), id = _intent(i), f = p.storeFields;
    final a = _doc?['intents'][id];
    if (a is Map &&
        a['pendingToken'] != null &&
        (p.purchaseToken == null ||
            a['pendingToken'] != _hash(p.purchaseToken!)))
      return null;
    if (f == null ||
        (a is Map && a['proof'] != null && a['proof'] != _proof(f)))
      return null;
    return t != null &&
            !(_doc?['completedIntents'] as List? ?? []).contains(id) &&
            _matches(a, t)
        ? t
        : null;
  }

  Future<void> authorizeProof(
    Map<String, String> f,
    AutomaticScopeTicket t, {
    PurchaseIntent? intent,
  }) {
    if (intent != null && _quarantinedIntents.contains(_intent(intent)))
      throw _error();
    return _authorize(
      'proofs',
      _proof(f),
      t,
      intent == null ? null : _intent(intent),
    );
  }

  Future<void> _authorize(
    String kind,
    String id,
    AutomaticScopeTicket t, [
    String? intent,
  ]) => _run(() async {
    if (!isCurrent(t)) throw _error();
    final d = await _load(), intents = _map(d, 'intents');
    if (kind == 'proofs' && intent != null) {
      final a = intents[intent];
      if (!_matches(a, t) || (a['proof'] != null && a['proof'] != id))
        throw _error();
      intents[intent] = {...Map<String, dynamic>.from(a as Map), 'proof': id};
    }
    final entries = kind == 'intents' ? intents : _map(d, kind);
    entries[id] = {
      if (entries[id] is Map) ...Map<String, dynamic>.from(entries[id] as Map),
      'context': t.context,
      'generation': t.generation,
      if (intent != null) 'intent': intent,
    };
    await _save({...d, 'intents': intents, kind: entries});
    if (!isCurrent(t)) throw _error();
  });
  Future<AutomaticScopeTicket?> recoverProof(
    String user,
    Map<String, String> f,
  ) async {
    final t = await capture(user), id = _proof(f);
    return t != null &&
            !(_doc?['completedProofs'] as List? ?? []).contains(id) &&
            _matches(_doc?['proofs'][id], t)
        ? t
        : null;
  }

  Future<bool> hasAuthorizedProofs(String user) async {
    final t = await capture(user);
    return t != null &&
        _map(_doc!, 'proofs').entries.any(
          (e) =>
              !(_doc?['completedProofs'] as List? ?? []).contains(e.key) &&
              _matches(e.value, t),
        );
  }

  Future<void> forgetIntent(PurchaseIntent i) => _forget('intents', _intent(i));
  Future<void> forgetProof(Map<String, String> f) =>
      _forget('proofs', _proof(f));
  Future<void> _forget(String kind, String id) => _run(() async {
    if (kind == 'proofs' && _unfinalized) return;
    final d = await _load(), entries = _map(d, kind)..remove(id);
    await _save({...d, kind: entries});
  });
  Future<bool> _finalize() async {
    if (_doc == null) return false;
    final d = {..._doc!}..remove('pending');
    final proofs = _map(d, 'proofs'), intents = _map(d, 'intents');
    for (final id in d['completedProofs'] as List? ?? []) {
      proofs.remove(id);
    }
    for (final id in d['completedIntents'] as List? ?? []) {
      intents.remove(id);
    }
    d['proofs'] = proofs;
    d['intents'] = intents;
    d.remove('completedProofs');
    d.remove('completedIntents');
    try {
      await state.write(jsonEncode(d));
      _doc = d;
      _unfinalized = false;
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _commit(
    AutomaticScopeTicket t,
    BillingEnvironment environment,
    String owner,
    String? proof,
  ) async {
    if (owner != t.user || !isCurrent(t)) return false;
    final d = await _load();
    await _save({
      ...d,
      'pending': {
        'context': t.context,
        'environment': environment.name,
        'generation': t.generation,
      },
    });
    if (!isCurrent(t))
      return false; // Synchronous activation fence; no await follows before activation.
    final intent = proof == null ? null : d['proofs'][proof]?['intent'];
    _doc = {
      ...d,
      'contexts': {..._map(d, 'contexts'), t.context: environment.name},
      'completedProofs': [
        ...d['completedProofs'] as List? ?? [],
        if (proof != null) proof,
      ],
      'completedIntents': [
        ...d['completedIntents'] as List? ?? [],
        if (intent != null) intent,
      ],
    };
    _context = t.context;
    _contextKey = t.key;
    _committed.add(t.context);
    _unfinalized = true;
    await _finalize();
    return true;
  }

  Future<bool> commit(
    AutomaticScopeTicket t,
    BillingEnvironment e,
    String owner, {
    Map<String, String>? acceptedFields,
  }) => _run(
    () => _commit(
      t,
      e,
      owner,
      acceptedFields == null ? null : _proof(acceptedFields),
    ),
  );
  Future<bool> inheritAnonymous(
    String from,
    AutomaticScopeTicket t,
    String owner,
  ) => _run(() async {
    if (!BillingStorage.isAnonymous(from)) return true;
    if (owner != t.user || !isCurrent(t)) return false;
    if (_unfinalized && !await _finalize()) return false;
    final d = await _load(),
        source = _hash('$from\u0000${t.key}'),
        inherited = d['contexts'][source];
    if (inherited == null || d['contexts'][t.context] != null) return true;
    return await _commit(
          t,
          BillingEnvironment.values.byName(inherited as String),
          owner,
          null,
        ) &&
        !_unfinalized;
  });
}
