import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'core/format.dart';
import 'core/nav.dart';
import 'core/offline.dart';
import 'core/session.dart';
import 'core/theme.dart';
import 'core/ui.dart';
import 'pages/outbox.dart';
import 'pages/registry.dart';

/*
 * The frame every page sits in — the web on a phone (Sidebar.jsx m-topbar + sidebar,
 * PageShell.jsx): a top bar with ⋮ at the top left (the approvals count on it) and the
 * company's name; the side menu sliding in from the left; under the bar the heading is
 * the path, Home › section › page, with the date on the right (LOCKED); a group's pages
 * as round tabs. A strip shows when offline or when recordings wait to be sent.
 */
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => ShellState();
  static ShellState of(BuildContext context) => context.findAncestorStateOfType<ShellState>()!;
}

class ShellState extends State<Shell> {
  final _key = GlobalKey<ScaffoldState>();
  String path = '/';
  final List<String> _history = [];
  List<NavSection>? _menu;
  int _pending = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    menuFor(session).then((m) { if (mounted) setState(() => _menu = m); });
    _countPending();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _countPending());
  }

  @override
  void dispose() { _timer?.cancel(); super.dispose(); }

  /// web usePendingApprovals: changes waiting for the branch in view
  Future<void> _countPending() async {
    if (!offline.online) return;
    try {
      var q = db.from('pending_changes').select('id').eq('status', 'pending');
      if (session.branchId != '') q = q.eq('branch_id', session.branchId);
      final rows = await q;
      if (mounted) setState(() => _pending = (rows as List).length);
    } catch (_) {}
  }

  /// Open a page by its web path ('/sales', '/staff?tab=pay' …)
  void go(String p) {
    if (p == path) return;
    setState(() { _history.add(path); path = p; });
    _countPending();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final item = itemFor(path.split('&').first);
    final siblings = item?.group != null ? item!.pagesFor(session) : <NavPage>[];
    final label = path == '/outbox'
        ? 'Waiting to send'
        : item?.group?.where((g) => g.path == path).firstOrNull?.label ?? item?.label ?? '';
    final section = item == null ? null : sectionOf(item);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) => PopScope(
        canPop: _history.isEmpty,
        onPopInvokedWithResult: (did, _) {
          if (!did && _history.isNotEmpty) setState(() => path = _history.removeLast());
        },
        child: Scaffold(
          key: _key,
          drawer: _SideMenu(menu: _menu, path: path, pending: _pending, onOpen: (p) { Navigator.pop(context); go(p); }),
          appBar: AppBar(
            automaticallyImplyLeading: false,
            toolbarHeight: 52,
            titleSpacing: 2,
            leading: IconButton(
              tooltip: 'Menu',
              onPressed: () => _key.currentState?.openDrawer(),
              icon: Badge(
                isLabelVisible: _pending > 0, backgroundColor: C.warning,
                label: Text(_pending > 99 ? '99+' : '$_pending'),
                child: const Icon(LucideIcons.ellipsisVertical, size: 22),
              ),
            ),
            title: Text('${session.organization?['name'] ?? 'MOIS'}', overflow: TextOverflow.ellipsis),
          ),
          body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SyncStrip(onOpen: () => go('/outbox')),
            // .page-top: the path (Home › section › page) and the date
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                Expanded(
                  child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 2, children: [
                    InkWell(onTap: () => go('/'), child: Text('Home', style: TextStyle(fontSize: 16.8, color: t.textSecondary))),
                    if (section != null && section != 'Home' && section != label) ...[
                      Icon(LucideIcons.chevronRight, size: 14, color: t.textMuted),
                      InkWell(onTap: () => go(item!.hrefFor(session)), child: Text(section, style: TextStyle(fontSize: 16.8, color: t.textSecondary))),
                    ],
                    if (label.isNotEmpty && label != 'Dashboard') ...[
                      Icon(LucideIcons.chevronRight, size: 14, color: t.textMuted),
                      Text(label, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: t.textPrimary)),
                    ],
                  ]),
                ),
                Text('${dateText(session.today)}', style: TextStyle(fontSize: Fs.sm, color: t.textSecondary)),
              ]),
            ),
            // .page-group: a group's pages as round tabs
            if (siblings.length > 1)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final g in siblings)
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () => go(g.path),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
                        decoration: BoxDecoration(
                          color: g.path == path ? const Color(0x2EB7A57A) : null,
                          border: Border.all(color: g.path == path ? C.khaki : t.border),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(g.label, style: TextStyle(fontSize: Fs.sm, color: g.path == path ? t.textPrimary : t.textMuted, fontWeight: g.path == path ? FontWeight.w600 : FontWeight.w400)),
                      ),
                    ),
                ]),
              ),
            Expanded(
              child: KeyedSubtree(
                key: ValueKey('$path|${session.branchId}'),
                child: path == '/outbox' ? const OutboxPage() : pageFor(path, item),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The web's side menu (Sidebar.jsx): logo + company, branch, sections, you + Organization, sign out
class _SideMenu extends StatefulWidget {
  const _SideMenu({required this.menu, required this.path, required this.pending, required this.onOpen});
  final List<NavSection>? menu;
  final String path;
  final int pending;
  final ValueChanged<String> onOpen;
  @override
  State<_SideMenu> createState() => _SideMenuState();
}

class _SideMenuState extends State<_SideMenu> {
  bool _userOpen = false;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final sections = widget.menu ?? [];
    final org = sections.where((s) => s.title == 'Organization').expand((s) => s.items).toList();
    Widget label(String s) => Text(s.toUpperCase(), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 1, color: t.textLabel));
    return Drawer(
      child: SafeArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 14),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
            child: Row(children: [
              Container(
                width: 30, height: 30,
                decoration: BoxDecoration(color: C.coffee, borderRadius: BorderRadius.circular(6)),
                child: const Icon(LucideIcons.layoutGrid, size: 15, color: C.khakiLight),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${session.organization?['name'] ?? 'Organization'}'.toUpperCase(), maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, letterSpacing: 0.3, color: t.textPrimary)),
                  Text('MOIS PLATFORM', style: TextStyle(fontSize: 10, letterSpacing: 0.6, color: t.textMuted)),
                ]),
              ),
            ]),
          ),
          if (session.branches.isNotEmpty)
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                label('Branch'),
                const SizedBox(height: 6),
                DropdownButtonFormField<String>(
                  initialValue: session.branchId, isDense: true, isExpanded: true,
                  style: TextStyle(fontSize: 13, color: t.textPrimary, fontFamily: font),
                  decoration: const InputDecoration(contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8)),
                  items: [
                    if (session.allowAll) const DropdownMenuItem(value: '', child: Text('All branches')),
                    for (final b in session.branches) DropdownMenuItem(value: b.id, child: Text(b.name)),
                  ],
                  onChanged: !session.allowAll && session.branches.length == 1 ? null : (v) => session.setBranch(v ?? ''),
                ),
              ]),
            ),
          Expanded(
            child: widget.menu == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(padding: const EdgeInsets.symmetric(vertical: 6), children: [
                    for (final sec in sections.where((s) => s.title != 'Organization')) ...[
                      if (sec.title.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 6), child: label(sec.title)),
                      for (final i in sec.items) _entry(context, i),
                    ],
                  ]),
          ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_userOpen) for (final i in org) _entry(context, i),
              InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: org.isEmpty ? null : () => setState(() => _userOpen = !_userOpen),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Row(children: [
                    CircleAvatar(radius: 14, backgroundColor: C.khaki, child: Text(initials(session.fullName), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: C.charcoal))),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(session.fullName, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: t.textPrimary)),
                        if (session.roleLabel.isNotEmpty) Text(session.roleLabel, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: t.textMuted)),
                      ]),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 8),
              TextButton.icon(
                onPressed: () => db.auth.signOut(),
                icon: Icon(LucideIcons.logOut, size: 13, color: t.textSecondary),
                label: Text('Sign out', style: TextStyle(fontSize: 11, color: t.textSecondary)),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _entry(BuildContext context, NavItem i) {
    final t = context.tk;
    final active = i.owns(widget.path);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: Material(
        color: active ? t.sidebarActive : Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: BorderSide(color: active ? t.textPrimary : Colors.transparent)),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => widget.onOpen(i.hrefFor(session)),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            child: Row(children: [
              Icon(i.icon, size: 16, color: active ? t.textPrimary : t.textSecondary.withValues(alpha: 0.75)),
              const SizedBox(width: 10),
              Expanded(child: Text(i.label, style: TextStyle(fontSize: 13, fontWeight: active ? FontWeight.w600 : FontWeight.w400, color: active ? t.textPrimary : t.textSecondary))),
              if (i.badge == 'approvals' && widget.pending > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(color: C.warning, borderRadius: BorderRadius.circular(999)),
                  child: Text(widget.pending > 99 ? '99+' : '${widget.pending}', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}
