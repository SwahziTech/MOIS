import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide SortOrder;
import 'package:uuid/uuid.dart';

/*
 * Offline (2026-11-23, the user: "with offline ability"):
 *
 *  - Saved copies: what a page last loaded is kept on the phone (cached). With no
 *    connection the page shows that copy, marked "Offline — as of …".
 *  - Waiting to send: production, sales and payments, goods leaving, expenses and meter
 *    readings recorded offline are kept as jobs — the same database calls the web makes,
 *    in order — and sent when the phone is back online. A call the server refuses (a rule,
 *    not the connection) stops that job; it waits with the reason, for the person to fix
 *    or remove. Nothing is changed on the way: the server checks everything as on the web.
 */
final _uuid = const Uuid();
Database? _db;
final _cache = stringMapStoreFactory.store('cache');
final _jobs = stringMapStoreFactory.store('jobs');

Future<Database> _open() async {
  if (_db != null) return _db!;
  // the browser copy (for checking pages beside the web): kept in memory
  if (kIsWeb) return _db = await databaseFactoryMemory.openDatabase('mois_offline.db');
  final dir = await getApplicationDocumentsDirectory();
  _db = await databaseFactoryIo.openDatabase('${dir.path}${Platform.pathSeparator}mois_offline.db');
  return _db!;
}

/// A connection problem (not a refusal by the server)
bool isOffline(Object e) {
  if (e is SocketException || e is TimeoutException || e is HandshakeException) return true;
  final s = '$e';
  return s.contains('SocketException') || s.contains('ClientException') || s.contains('Failed host lookup') ||
      s.contains('Connection closed') || s.contains('Network is unreachable') || s.contains('Connection refused');
}

class Offline extends ChangeNotifier {
  Offline._();
  static final instance = Offline._();

  bool online = true;
  int waiting = 0;
  int failed = 0;
  bool _syncing = false;
  StreamSubscription? _sub;

  Future<void> start() async {
    await _open();
    await _count();
    final now = await Connectivity().checkConnectivity();
    online = !now.contains(ConnectivityResult.none);
    _sub = Connectivity().onConnectivityChanged.listen((r) {
      final was = online;
      online = !r.contains(ConnectivityResult.none);
      notifyListeners();
      if (online && !was) sync();
    });
    if (online) unawaited(sync());
    Timer.periodic(const Duration(minutes: 2), (_) { if (online) sync(); });
  }

  @override
  void dispose() { _sub?.cancel(); super.dispose(); }

  // ---- saved copies -------------------------------------------------------------------
  /// The page's data: fresh when online (and saved), else the saved copy. Returns (data, savedAt) —
  /// savedAt is null when the data is fresh.
  Future<(T, DateTime?)> load<T>(String key, Future<T> Function() fetch) async {
    try {
      final v = await fetch();
      final db = await _open();
      await _cache.record(key).put(db, {'at': DateTime.now().toIso8601String(), 'v': _plain(v)});
      if (!online) { online = true; notifyListeners(); unawaited(sync()); }
      return (v, null);
    } catch (e) {
      if (!isOffline(e)) rethrow;
      online = false;
      notifyListeners();
      final db = await _open();
      final rec = await _cache.record(key).get(db);
      if (rec == null) rethrow;
      return (rec['v'] as T, DateTime.parse(rec['at'] as String));
    }
  }

  static Object? _plain(Object? v) {
    if (v is Map) return {for (final e in v.entries) '${e.key}': _plain(e.value)};
    if (v is List) return [for (final x in v) _plain(x)];
    return v;
  }

  // ---- waiting to send ---------------------------------------------------------------
  /// A job: the calls the web makes, in order. A later call's params may name an earlier
  /// call's result as '$0', '$1'… (e.g. record_sale's new id for set_sale_store).
  Future<String> queue({required String label, required String branchId, required List<Call> calls}) async {
    final db = await _open();
    final id = _uuid.v4();
    await _jobs.record(id).put(db, {
      'id': id, 'label': label, 'branch_id': branchId, 'created_at': DateTime.now().toIso8601String(),
      'calls': [for (final c in calls) c.toJson()], 'done': 0, 'results': [], 'status': 'waiting', 'error': null,
    });
    await _count();
    if (online) unawaited(sync());
    return id;
  }

  /// Run the calls now when online; queue them when offline. → 'sent' | 'queued'
  Future<String> send({required String label, required String branchId, required List<Call> calls}) async {
    if (online) {
      try {
        await _run(calls, 0, []);
        return 'sent';
      } catch (e) {
        if (!isOffline(e)) rethrow;
        online = false;
        notifyListeners();
      }
    }
    await queue(label: label, branchId: branchId, calls: calls);
    return 'queued';
  }

  Future<List<Map<String, dynamic>>> jobs() async {
    final db = await _open();
    final rows = await _jobs.find(db, finder: Finder(sortOrders: [SortOrder('created_at')]));
    return [for (final r in rows) Map<String, dynamic>.from(r.value)];
  }

  Future<void> remove(String id) async {
    final db = await _open();
    await _jobs.record(id).delete(db);
    await _count();
  }

  Future<void> retry(String id) async {
    final db = await _open();
    await _jobs.record(id).update(db, {'status': 'waiting', 'error': null});
    await _count();
    unawaited(sync());
  }

  Future<void> sync() async {
    if (_syncing || Supabase.instance.client.auth.currentSession == null) return;
    _syncing = true;
    try {
      final db = await _open();
      final rows = await _jobs.find(db, finder: Finder(filter: Filter.equals('status', 'waiting'), sortOrders: [SortOrder('created_at')]));
      for (final r in rows) {
        final j = Map<String, dynamic>.from(r.value);
        final calls = [for (final c in j['calls'] as List) Call.fromJson(Map<String, dynamic>.from(c))];
        final results = List<Object?>.from(j['results'] as List);
        try {
          await _run(calls, j['done'] as int, results, onStep: (done) => _jobs.record(j['id']).update(db, {'done': done, 'results': _plain(results)}));
          await _jobs.record(j['id']).delete(db);
        } catch (e) {
          if (isOffline(e)) { online = false; break; }
          await _jobs.record(j['id']).update(db, {'status': 'failed', 'error': e is PostgrestException ? e.message : '$e'});
        }
        await _count();
      }
    } finally {
      _syncing = false;
      await _count();
    }
  }

  Future<void> _run(List<Call> calls, int from, List<Object?> results, {Future<void> Function(int)? onStep}) async {
    final c = Supabase.instance.client;
    for (var i = from; i < calls.length; i++) {
      final call = calls[i];
      final params = _fill(call.params, results);
      Object? res;
      if (call.rpc != null) {
        res = await c.rpc(call.rpc!, params: params as Map<String, dynamic>);
      } else if (call.insert != null) {
        res = await c.from(call.insert!).insert(params as Map<String, dynamic>).select('id').single().then((r) => r['id']);
      }
      if (results.length > i) {
        results[i] = res;
      } else {
        results.add(res);
      }
      if (onStep != null) await onStep(i + 1);
    }
  }

  static Object? _fill(Object? v, List<Object?> results) {
    if (v is String && RegExp(r'^\$\d+$').hasMatch(v)) return results[int.parse(v.substring(1))];
    if (v is Map) return {for (final e in v.entries) '${e.key}': _fill(e.value, results)};
    if (v is List) return [for (final x in v) _fill(x, results)];
    return v;
  }

  Future<void> _count() async {
    final db = await _open();
    waiting = await _jobs.count(db, filter: Filter.equals('status', 'waiting'));
    failed = await _jobs.count(db, filter: Filter.equals('status', 'failed'));
    notifyListeners();
  }
}

/// One database call of a job: an RPC (as the web's supabase.rpc) or an insert returning its id
class Call {
  const Call.rpc(String name, this.params) : rpc = name, insert = null;
  const Call.insert(String table, this.params) : insert = table, rpc = null;
  final String? rpc, insert;
  final Map<String, dynamic> params;
  Map<String, dynamic> toJson() => {'rpc': rpc, 'insert': insert, 'params': params};
  static Call fromJson(Map<String, dynamic> j) =>
      j['rpc'] != null ? Call.rpc(j['rpc'], Map<String, dynamic>.from(j['params'])) : Call.insert(j['insert'], Map<String, dynamic>.from(j['params']));
}

final offline = Offline.instance;
