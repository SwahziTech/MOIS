import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'format.dart';
import 'offline.dart';

SupabaseClient get db => Supabase.instance.client;
typedef Json = Map<String, dynamic>;

class Branch {
  const Branch(this.id, this.name);
  final String id, name;
}

class UserRole {
  const UserRole(this.role, this.branchId, this.warehouseId, this.perms);
  final String? role, branchId, warehouseId;
  final Set<String> perms;
  bool get orgWide => branchId == null && warehouseId == null;
}

/// whose layout a person sees when they hold several roles: the highest (web lib/menu.js)
const roleRank = ['owner', 'director', 'branch_manager', 'secretary', 'storekeeper'];

/// 'branch_manager' → 'Branch manager'; 'owner' → 'Technical admin' (web lib/manageUsers.js)
String roleLabelOf(String? name) {
  if (name == null || name.isEmpty) return '';
  if (name == 'owner') return 'Technical admin';
  final s = name.replaceAll('_', ' ');
  return s[0].toUpperCase() + s.substring(1);
}

/*
 * The signed-in person — a port of the web's hooks/useAuth.jsx and hooks/useBranch.jsx:
 * profile, organization, roles and permissions (can / canAt / canManage), and the branch
 * every screen is looking at ('' = all branches). The database's rules still decide what
 * anyone can read or write. Kept on the phone so the app opens offline.
 */
class Session extends ChangeNotifier {
  Json? profile;
  Json? organization;
  List<UserRole> roles = [];
  Set<String> perms = {};
  Set<String> orgWidePerms = {};
  List<Json> _branches = [];
  Map<String, String> _whBranch = {};
  String? _chosen;
  bool ready = false;
  String error = '';

  String? get userId => db.auth.currentUser?.id;
  String get currency => '${organization?['currency_code'] ?? 'TZS'}';
  String get today => orgToday();

  String get fullName {
    final p = profile;
    final n = [p?['first_name'], p?['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ');
    return n.isNotEmpty ? n : '${p?['email'] ?? db.auth.currentUser?.email ?? ''}';
  }

  String? get primaryRole {
    final names = roles.map((r) => r.role).whereType<String>().toSet().toList();
    int rank(String r) { final i = roleRank.indexOf(r); return i < 0 ? 99 : i; }
    names.sort((a, b) => rank(a).compareTo(rank(b)));
    return names.isEmpty ? null : names.first;
  }

  String get roleLabel => roles.map((r) => roleLabelOf(r.role)).where((x) => x.isNotEmpty).toSet().join(', ');

  bool hasRole(String name) => roles.any((r) => r.role == name);
  bool can(String code) => perms.contains(code);
  bool canManage(String code) => orgWidePerms.contains(code);

  /// an org-wide, branch or store grant (has_permission_at, 022)
  bool canAt(String code, String? branchId, [String? warehouseId]) => roles.any((r) =>
      r.perms.contains(code) &&
      (r.orgWide || (r.warehouseId == null && r.branchId == branchId) || (r.warehouseId != null && r.warehouseId == warehouseId)));

  /// Branches this person's roles reach: all active ones with any org-wide role
  List<Branch> get branches {
    final all = [for (final b in _branches) if (b['status'] == 'active') Branch(b['id'], b['name'])];
    if (roles.any((r) => r.orgWide)) return all;
    final reach = roles.map((r) => r.branchId ?? _whBranch[r.warehouseId]).whereType<String>().toSet();
    return all.where((b) => reach.contains(b.id)).toList();
  }

  bool get allowAll => branches.length != 1;
  bool _valid(String? id) => id != null && (id == '' ? allowAll : branches.any((b) => b.id == id));

  String get branchId {
    if (_valid(_chosen)) return _chosen!;
    final def = organization?['default_branch_id'] as String?;
    if (_valid(def)) return def!;
    return allowAll ? '' : (branches.isEmpty ? '' : branches.first.id);
  }

  String? get branchName => branches.where((b) => b.id == branchId).firstOrNull?.name;
  bool inBranch(Object? id) => branchId == '' || id == branchId;
  String branchNameOf(Object? id) => '${_branches.where((b) => b['id'] == id).firstOrNull?['name'] ?? '—'}';

  Future<void> setBranch(String id) async {
    _chosen = id;
    notifyListeners();
    try { (await SharedPreferences.getInstance()).setString('mois.branch.$userId', id); } catch (_) {}
  }

  Future<void> load() async {
    final uid = userId;
    if (uid == null) return;
    ready = false;
    error = '';
    notifyListeners();
    try {
      final (data, _) = await offline.load<Json>('session:$uid', () async {
        final prof = await db.from('profiles').select('*').eq('id', uid).maybeSingle();
        final orgId = prof?['organization_id'];
        if (orgId == null) return {'profile': prof};
        final res = await Future.wait<dynamic>([
          db.from('organizations').select('id, name, legal_name, logo_url, brand_config, status, currency_code, timezone, default_branch_id, yield_tolerance').eq('id', orgId).maybeSingle(),
          db.from('user_roles').select('id, branch_id, warehouse_id, role:roles(id, name, description, role_permissions(permission:permissions(code)))').eq('user_id', uid).eq('organization_id', orgId),
          db.from('branches').select('id, name, status').order('name'),
          db.from('warehouses').select('id, branch_id'),
        ]);
        return {'profile': prof, 'organization': res[0], 'roles': res[1], 'branches': res[2], 'warehouses': res[3]};
      });
      profile = data['profile'] == null ? null : Map<String, dynamic>.from(data['profile']);
      if (profile?['organization_id'] == null) {
        error = 'Your account is not part of a company yet.';
        notifyListeners();
        return;
      }
      organization = Map<String, dynamic>.from(data['organization'] ?? {});
      roles = [
        for (final r in (data['roles'] as List? ?? []))
          UserRole(r['role']?['name'], r['branch_id'], r['warehouse_id'], {
            for (final rp in (r['role']?['role_permissions'] as List? ?? []))
              if (rp['permission']?['code'] != null) rp['permission']['code'] as String,
          }),
      ];
      perms = {for (final r in roles) ...r.perms};
      orgWidePerms = {for (final r in roles.where((r) => r.orgWide)) ...r.perms};
      _branches = [for (final b in (data['branches'] as List? ?? [])) Map<String, dynamic>.from(b)];
      _whBranch = {for (final w in (data['warehouses'] as List? ?? [])) w['id'] as String: w['branch_id'] as String};
      try { _chosen = (await SharedPreferences.getInstance()).getString('mois.branch.$uid'); } catch (_) {}
      ready = true;
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST303') { await db.auth.signOut(); return; }
      error = "We couldn't load your account.";
    } catch (e) {
      error = isOffline(e) ? "No connection, and this phone hasn't opened MOIS before. Connect once, then it works offline." : "We couldn't load your account.";
    }
    notifyListeners();
  }

  void clear() {
    profile = null; organization = null; roles = []; perms = {}; orgWidePerms = {};
    _branches = []; _whBranch = {}; _chosen = null; ready = false; error = '';
  }
}

final session = Session();

/// The database's message as the person should read it (web lib/masterData.js dbErrorMessage)
String dbError(Object e, [String fallback = 'Something went wrong. Please try again.']) {
  if (isOffline(e)) return 'No connection — check the internet and try again.';
  if (e is PostgrestException) {
    if (e.code == '23505') return 'That already exists.';
    if (e.code == '42501' && !e.message.contains(' ')) return "You don't have permission for that.";
    return datesInText(e.message);
  }
  if (e is AuthException) return e.message;
  return kDebugMode ? '$e' : fallback;
}
