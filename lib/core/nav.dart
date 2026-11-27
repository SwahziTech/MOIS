import 'package:flutter/widgets.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'session.dart';

/*
 * The web's menu (web/src/components/Sidebar.jsx NAV): the same sections, entries, groups,
 * Lucide icons and permissions. A group entry (Review queue, Products, Docs, Job Costing,
 * Cash flow) opens its first page the person may open; its pages show as round tabs under
 * the heading (.page-group), as on the web. A role's own layout (menu_layouts, 098) orders it.
 */
class NavPage {
  const NavPage(this.label, this.path, {this.perm, this.perms});
  final String label, path;
  final String? perm;
  final List<String>? perms;
  bool mayOpen(Session s) => perms != null ? perms!.any(s.can) : perm == null || s.can(perm!);
}

class NavItem {
  const NavItem(this.label, this.path, this.icon, {this.perm, this.perms, this.group, this.badge});
  final String label, path;
  final IconData icon;
  final String? perm, badge;
  final List<String>? perms;
  final List<NavPage>? group;

  bool _may(Session s) => perms != null ? perms!.any(s.can) : perm == null || s.can(perm!);
  bool mayOpen(Session s) => group != null ? group!.any((g) => g.mayOpen(s)) : _may(s);
  List<NavPage> pagesFor(Session s) => group != null ? group!.where((g) => g.mayOpen(s)).toList() : [NavPage(label, path)];
  bool owns(String p) => path == p || (group?.any((g) => g.path == p) ?? false);
  String hrefFor(Session s) => pagesFor(s).firstOrNull?.path ?? path;
}

class NavSection {
  const NavSection(this.title, this.items);
  final String title;
  final List<NavItem> items;
}

const nav = [
  NavSection('Home', [
    NavItem('Dashboard', '/', LucideIcons.layoutDashboard),
    NavItem('Daily report', '/daily-report', LucideIcons.fileText, perm: 'production.view'),
    NavItem('Review queue', '/approvals', LucideIcons.flag, badge: 'approvals', group: [
      NavPage('Approvals', '/approvals', perm: 'inventory.view'),
      NavPage('Reviews', '/review', perm: 'products.view'),
    ]),
  ]),
  NavSection('Master Data', [
    NavItem('Products', '/products', LucideIcons.package, group: [
      NavPage('Products', '/products', perm: 'products.view'),
      NavPage('Categories', '/categories', perm: 'products.view'),
      NavPage('Colours', '/colours', perm: 'products.view'),
      NavPage('Recipe / BOM', '/recipes', perm: 'products.view'),
      NavPage('Pricing', '/pricing', perm: 'products.view'),
    ]),
    NavItem('Materials', '/materials', LucideIcons.layers, perm: 'materials.view'),
    NavItem('Docs', '/documents', LucideIcons.folderOpen, group: [
      NavPage('Documents', '/documents', perms: ['sales.view', 'procurement.view', 'staff.view']),
      NavPage('Reports', '/reports', perm: 'products.manage'),
      NavPage('Print lists', '/print-lists', perms: ['inventory.view', 'products.view', 'staff.view', 'procurement.view']),
    ]),
  ]),
  NavSection('Inventory', [
    NavItem('Stock', '/stock', LucideIcons.boxes, perm: 'inventory.view'),
    NavItem('Movements', '/movements', LucideIcons.arrowLeftRight, perm: 'inventory.view'),
  ]),
  NavSection('Procurement', [
    NavItem('Purchases', '/purchases', LucideIcons.shoppingCart, perm: 'procurement.view'),
    NavItem('Expenses', '/expenses', LucideIcons.banknote, perm: 'procurement.view'),
    NavItem('Orders', '/orders', LucideIcons.clipboardList, perm: 'procurement.view'),
  ]),
  NavSection('Production', [
    NavItem('Production', '/production', LucideIcons.factory, perm: 'production.view'),
    NavItem('Job Costing', '/production/ledger', LucideIcons.bookOpen, group: [
      NavPage('Production ledger', '/production/ledger', perm: 'production.view'),
      NavPage('Material variance', '/production?tab=variance', perm: 'production.view'),
    ]),
    NavItem('Planner', '/production?tab=planner', LucideIcons.calendarClock, perm: 'production.view'),
  ]),
  NavSection('Sales', [
    NavItem('Sales', '/sales', LucideIcons.receipt, perm: 'sales.view'),
    NavItem('Customers', '/customers', LucideIcons.contact, perm: 'sales.view'),
    NavItem('Invoices', '/sales?tab=list', LucideIcons.files, perm: 'sales.view'),
  ]),
  NavSection('Finance & Accounting', [
    NavItem('Costing', '/costing', LucideIcons.calculator, perm: 'products.manage'),
    NavItem('Cash flow', '/cash-flow', LucideIcons.landmark, group: [
      NavPage('Weekly', '/weekly-cash', perm: 'cash.request'),
      NavPage('Monthly', '/cash-flow?tab=monthly', perm: 'finance.view'),
      NavPage('Cash flow', '/cash-flow', perm: 'finance.view'),
    ]),
    NavItem('Statements', '/statements', LucideIcons.scrollText, perm: 'finance.view'),
  ]),
  NavSection('HR', [
    NavItem('Personnel', '/staff', LucideIcons.hardHat, perm: 'staff.view'),
    NavItem('Attendance', '/staff?tab=attendance', LucideIcons.calendarCheck, perm: 'staff.view'),
    NavItem('Payroll', '/staff?tab=pay', LucideIcons.wallet, perm: 'staff.view'),
  ]),
  NavSection('Organization', [
    NavItem('Branches', '/branches', LucideIcons.building2, perm: 'branches.manage'),
    NavItem('Users', '/users', LucideIcons.users, perm: 'users.invite'),
    NavItem('Settings', '/settings', LucideIcons.settings),
  ]),
];

List<NavItem> get allItems => [for (final s in nav) ...s.items];
NavItem? itemFor(String path) => allItems.where((i) => i.owns(path)).firstOrNull ?? allItems.where((i) => i.owns(path.split('?').first)).firstOrNull;
String sectionOf(NavItem i) => nav.firstWhere((s) => s.items.contains(i), orElse: () => nav.first).title;

/// The menu a person sees: their role's layout (098) if set; entries they can't open left out
Future<List<NavSection>> menuFor(Session s) async {
  List<NavSection> sections = nav;
  final role = s.primaryRole;
  if (role != null) {
    try {
      final row = await db.from('menu_layouts').select('layout').eq('role_name', role).maybeSingle();
      final layout = row?['layout'];
      if (layout is Map && layout['sections'] is List) sections = _resolve(layout['sections'] as List);
    } catch (_) {/* the default menu */}
  }
  return [
    for (final sec in sections)
      if (sec.items.any((i) => i.mayOpen(s))) NavSection(sec.title, sec.items.where((i) => i.mayOpen(s)).toList()),
  ];
}

/// web lib/menu.js resolveMenu: a layout's paths onto the entries; unmentioned ones go to their section
List<NavSection> _resolve(List sections) {
  final byPath = {for (final s in nav) for (final i in s.items) i.path: i};
  final homeOf = {for (final s in nav) for (final i in s.items) i.path: s.title};
  final used = <String>{};
  final out = <NavSection>[];
  for (final s in sections) {
    final items = <NavItem>[];
    for (final p in (s['items'] as List? ?? [])) {
      final i = byPath['$p'];
      if (i != null && used.add(i.path)) items.add(i);
    }
    out.add(NavSection('${s['title'] ?? ''}', items));
  }
  for (final s in nav) {
    for (final i in s.items) {
      if (used.contains(i.path)) continue;
      var sec = out.where((x) => x.title == homeOf[i.path]).firstOrNull;
      if (sec == null) {
        sec = NavSection(homeOf[i.path]!, []);
        out.add(sec);
      }
      sec.items.add(i);
      used.add(i.path);
    }
  }
  return out;
}
