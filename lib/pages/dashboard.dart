import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/dashboard_data.dart';
import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../shell.dart';
import 'stock.dart';

/*
 * Dashboard — a port of web pages/Dashboard.jsx + components/dashboard/DirectorBoard.jsx, in the
 * design the user approved (2026-11-23): Director view top to bottom (Needs you now, period bar,
 * Sales · Weekly cash · Purchases cards, Production, Stock, Money in vs out, Branches), plus an
 * Overview tab — the Technical admin: Director view · Overview · Setup; branch managers and
 * secretaries: Overview and their tabs (dashboard_layouts, 116, else each role's built-in set).
 */
const _tabLabels = {
  'director': 'Director view', 'overview': 'Overview', 'hr': 'HR', 'attendance': 'Attendance', 'sales': 'Sales',
  'production': 'Production', 'purchases': 'Purchases', 'inventory': 'Inventory', 'setup': 'Setup',
};
const _tabPerm = {
  'hr': ['staff.view'], 'attendance': ['staff.view'], 'sales': ['sales.view'], 'production': ['production.view'],
  'purchases': ['procurement.view', 'procurement.receive'], 'inventory': ['inventory.view'],
};
const _defaults = {
  'owner': ['director', 'overview', 'setup'],
  'director': ['director'],
  'branch_manager': ['overview', 'attendance', 'sales', 'production', 'purchases', 'inventory'],
  'secretary': ['overview', 'attendance', 'sales', 'production', 'purchases', 'inventory'],
};

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});
  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  List<String>? _keys;
  String _tab = '';

  @override
  void initState() { super.initState(); _layout(); }

  Future<void> _layout() async {
    final role = session.primaryRole;
    List<String>? keys;
    if (role != null) {
      try {
        final (row, _) = await offline.load<Json?>('dashLayout:$role', () => db.from('dashboard_layouts').select('tabs').eq('role_name', role).maybeSingle());
        if (row?['tabs'] is List) keys = [for (final k in row!['tabs'] as List) '$k'];
      } catch (_) {}
    }
    keys ??= _defaults[role] ?? ['overview', 'sales', 'production', 'inventory', 'setup'];
    if (role == 'owner' && !keys.contains('overview')) keys = [...keys, 'overview'];
    keys = keys.where((k) => _tabPerm[k] == null || _tabPerm[k]!.any(session.can)).toList();
    if (mounted) setState(() { _keys = keys; _tab = keys!.first; });
  }

  @override
  Widget build(BuildContext context) {
    final keys = _keys;
    if (keys == null) return const Padding(padding: EdgeInsets.all(14), child: Skeleton());
    final body = switch (_tab) {
      'director' => const DirectorView(),
      'setup' => const _Setup(),
      'inventory' => const StockPage(),
      'overview' => const _Overview(),
      _ => _Pending(_tabLabels[_tab] ?? _tab),
    };
    if (keys.length == 1) return body;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: PageTabs<String>(tabs: [for (final k in keys) (k, _tabLabels[k] ?? k)], value: _tab, onChange: (v) => setState(() => _tab = v))),
      Expanded(child: KeyedSubtree(key: ValueKey(_tab), child: body)),
    ]);
  }
}

class _Pending extends StatelessWidget {
  const _Pending(this.label);
  final String label;
  @override
  Widget build(BuildContext context) => ListView(children: [EmptyState(icon: LucideIcons.hammer, title: '$label is being ported from the web', description: 'It comes in this first release.')]);
}

// ---- Director view (DirectorBoard.jsx) ----------------------------------------------------
class DirectorView extends StatefulWidget {
  const DirectorView({super.key});
  @override
  State<DirectorView> createState() => _DirectorViewState();
}

class _DirectorViewState extends State<DirectorView> {

  List<Need>? _needs;
  Json? _money;
  Json? _curing;
  Json? _stock;
  bool _stockFailed = false, _loaded = false;
  String _periodKey = 'month';
  DateTime? _savedAt;

  String get today => session.today;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final refs = await Refs.load();
      final (d, at) = await offline.load<Json>('director:${session.branchId}', () async {
        Future<T?> safe<T>(Future<T> f) => f.then<T?>((v) => v).catchError((_) => null);
        final res = await Future.wait<dynamic>([safe(loadNeeds()), safe(loadMoneyData()), safe(loadCuringNow(refs, today))]);
        return {'needs': res[0] == null ? null : [for (final x in res[0] as List<Need>) {'key': x.key, 'count': x.count, 'label': x.label, 'to': x.to}], 'money': res[1], 'curing': res[2]};
      });

      _savedAt = at;
      _needs = d['needs'] == null ? null : [for (final x in d['needs'] as List) Need(x['key'], x['count'], x['label'], x['to'])];
      _money = d['money'] == null ? null : Map<String, dynamic>.from(d['money']);
      _curing = d['curing'] == null ? null : Map<String, dynamic>.from(d['curing']);
      if (mounted) setState(() => _loaded = true);
      try {
        final (s, _) = await offline.load<Json>('stockBlock:${session.branchId}', () => loadStockBlock(refs, today));
        if (mounted) setState(() => _stock = s);
      } catch (_) {
        if (mounted) setState(() => _stockFailed = true);
      }
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  String short(num v) => formatMoneyShort(v, session.currency);

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    if (!_loaded) return const Padding(padding: EdgeInsets.all(14), child: Skeleton());
    final periods = periodsFor(today);
    final period = periods.firstWhere((p) => p.key == _periodKey, orElse: () => periods.firstWhere((p) => p.key == 'month'));
    final money = _money;
    final c = money == null ? null : cardsFor(money, period);
    final f = money == null ? null : productionFor(money, period, today);
    final trend = money == null ? null : trendFrom(money, today);
    final change = c != null && (c.salesBefore ?? 0) > 0 ? ((c.sales / c.salesBefore! - 1) * 100).round() : null;
    const unavailable = PlHelp("Couldn't load this part.");
    final shell = Shell.of(context);
    return RefreshIndicator(
      onRefresh: () async { setState(() { _loaded = false; _stock = null; }); await _load(); },
      child: PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        OfflineNote(_savedAt),
        if (_needs != null)
          _needs!.isEmpty ? const Padding(padding: EdgeInsets.only(bottom: 10), child: PlHelp('Nothing needs you right now.')) : _NeedsNow(needs: _needs!, go: shell.go),
        _PeriodBar(periods: periods, value: _periodKey, onChange: (v) => setState(() => _periodKey = v)),
        if (c == null) unavailable
        else ...[
          Row(children: [
            Expanded(child: _Num('Sales', short(c.sales), '${c.salesCount} sale${c.salesCount == 1 ? '' : 's'} made${change == null ? '' : ' · ${change >= 0 ? '+' : ''}$change% vs ${period.cLabel}'}', big: true, onTap: () => shell.go('/sales'))),
            const SizedBox(width: 8),
            Expanded(child: _Num('Weekly cash', '${short(c.sent)} sent', c.hasRequests ? '${short(c.spent)} spent · ${short(c.left)} left' : 'No requests yet', onTap: () => shell.go('/weekly-cash'))),
          ]),
          const SizedBox(height: 8),
          _Num('Purchases', '${short(c.paid)} paid', '${short(c.bought)} bought · ${short(c.toPay)} to pay', warn: c.toPay > 0, onTap: () => shell.go('/purchases')),
        ],
        const SizedBox(height: 8),
        _Block(title: 'Production', note: period.label.toLowerCase(), onOpen: () => shell.go('/production'), children: f == null ? [unavailable] : [
          _Line('Cement bags', formatAmount(f.bags)),
          if (_curing != null) _Line('Pieces curing', n(_curing!['ready']) > 0 ? '${formatAmount(n(_curing!['curing']))} · ${_curing!['ready']} batches ready' : formatAmount(n(_curing!['curing']))),
          if (_curing != null) _Line('Batches outside the yield band', '${_curing!['flags']}', warn: n(_curing!['flags']) > 0, onTap: () => shell.go('/review')),
          _Line('Pieces rejected', formatAmount(f.rejected), warn: f.rejected > 0, onTap: () => shell.go('/production/ledger')),
        ]),
        _Block(title: 'Stock', note: 'at cost, today', onOpen: () => shell.go('/stock'), children: _stockFailed ? [unavailable] : _stock == null ? [const Skeleton(rows: 2, height: 20)] : [
          _Line('Products', short(n(_stock!['finished'])), onTap: () => shell.go('/stock')),
          _Line('Materials', short(n(_stock!['materials_value'])), onTap: () => shell.go('/stock')),
          for (final x in (_stock!['materials'] as List).take(4)) _Line('${x['name']}', 'about ${x['days']} day${x['days'] == 1 ? '' : 's'} left', warn: true, onTap: () => shell.go('/stock')),
          for (final x in (_stock!['products'] as List).take((4 - (_stock!['materials'] as List).length).clamp(0, 4))) _Line('${x['name']}', 'below reorder', onTap: () => shell.go('/stock')),
          if ((_stock!['materials'] as List).length + (_stock!['products'] as List).length > 4)
            PlHelp('${(_stock!['materials'] as List).length + (_stock!['products'] as List).length - 4} more at risk'),
          if (n(_stock!['uncosted']) > 0) PlHelp('${_stock!['uncosted']} items have no cost yet, so the value is lower than it will be.'),
        ]),
        if (trend != null)
          _Block(title: 'Money in vs out', note: 'last 6 months', onOpen: () => shell.go('/cash-flow?tab=monthly'), children: [
            Row(children: [
              _key(C.khaki, 'In'), const SizedBox(width: 12), _key(t.textMuted, 'Out'),
            ]),
            const SizedBox(height: 8),
            _Chart(trend),
          ]),
        if (session.branchId.isEmpty && money != null && session.branches.length > 1)
          _Block(title: 'Branches', note: period.label.toLowerCase(), children: [
            for (final b in session.branches)
              _Line(b.name, (() {
                final cards = _branchCards(money, period, b.id);
                return '${short(cards.$1)} · ${formatAmount(cards.$2)} bags';
              })()),
          ]),
        PlHelp('${session.branchId.isNotEmpty ? session.branchName : 'All branches'} · ${dateText(today)}'),
      ]),
    );
  }

  (double, double) _branchCards(Json money, DPeriod p, String id) {
    final sales = (money['sales'] as List).where((x) => x['branch_id'] == id && '${x['day']}'.compareTo(p.from) >= 0 && '${x['day']}'.compareTo(p.to) <= 0).fold<double>(0, (t, x) => t + n(x['total']));
    final bags = productionFor(money, p, today, (b) => b == id).bags;
    return (sales, bags);
  }

  Widget _key(Color c, String s) => Row(children: [Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))), const SizedBox(width: 4), PlHelp(s)]);
}

class _PeriodBar extends StatelessWidget {
  const _PeriodBar({required this.periods, required this.value, required this.onChange});
  final List<DPeriod> periods;
  final String value;
  final ValueChanged<String> onChange;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final steps = periodSteps(session.today);
    final at = steps.indexOf(value);
    const lastOf = {'week': 'lastweek', 'month': 'lastmonth'};
    final earlier = at >= 0 ? (at + 1 < steps.length ? steps[at + 1] : null) : lastOf[value];
    final later = at >= 0 ? (at == 0 ? null : steps[at - 1]) : (lastOf.entries.where((e) => e.value == value).firstOrNull?.key ?? (value == 'week' || value == 'month' ? 'today' : null));
    final p = periods.firstWhere((x) => x.key == value);
    Widget step(IconData i, String? to) => SizedBox(
          width: 36, height: 36,
          child: OutlinedButton(style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, side: BorderSide(color: t.border), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              onPressed: to == null ? null : () => onChange(to), child: Icon(i, size: 18)),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        step(LucideIcons.chevronLeft, earlier),
        const SizedBox(width: 6),
        step(LucideIcons.chevronRight, later),
        const SizedBox(width: 8),
        Expanded(child: Text.rich(TextSpan(children: [TextSpan(text: p.label, style: TextStyle(fontWeight: FontWeight.w700, color: t.textPrimary)), TextSpan(text: ' · ${p.note}')]),
            style: TextStyle(fontSize: Fs.sm, color: t.textMuted), maxLines: 2)),
        if (value != 'month') TextButton(onPressed: () => onChange('month'), child: const Text('This month')),
        PopupMenuButton<String>(
          initialValue: value, onSelected: onChange,
          itemBuilder: (_) => [for (final x in periods) PopupMenuItem(value: x.key, child: Text(x.label))],
          child: Container(height: 36, padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(border: Border.all(color: t.borderStrong), borderRadius: BorderRadius.circular(6)), child: const Icon(LucideIcons.chevronDown, size: 16)),
        ),
      ]),
    );
  }
}

/// "Needs you now" (NeedsNow.jsx): one card a kind, its number in a badge
class _NeedsNow extends StatelessWidget {
  const _NeedsNow({required this.needs, required this.go});
  final List<Need> needs;
  final ValueChanged<String> go;
  static const _label = {'proofs': 'Payment slips to confirm', 'cash': 'Weekly cash requests', 'orders': 'Orders to pay'};
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final total = needs.fold<int>(0, (s, x) => s + x.count);
    Widget badge(int k) => Container(
          constraints: const BoxConstraints(minWidth: 24), padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(color: C.warning, borderRadius: BorderRadius.circular(999)),
          child: Text('$k', textAlign: TextAlign.center, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: Fs.xs)),
        );
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [const Expanded(child: Text('Needs you now', style: TextStyle(fontWeight: FontWeight.w700, fontSize: Fs.md))), badge(total)]),
        const SizedBox(height: 8),
        for (final x in needs)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Material(
              color: t.soft, borderRadius: BorderRadius.circular(8),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => go(x.to),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                  child: Row(children: [
                    badge(x.count), const SizedBox(width: 10),
                    Expanded(child: Text(_label[x.key] ?? '${x.label[0].toUpperCase()}${x.label.substring(1)}', style: const TextStyle(fontWeight: FontWeight.w600))),
                    Icon(LucideIcons.chevronRight, size: 18, color: t.textMuted),
                  ]),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

class _Num extends StatelessWidget {
  const _Num(this.label, this.figure, this.help, {this.big = false, this.warn = false, this.onTap});
  final String label, figure, help;
  final bool big, warn;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Material(
      color: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10), onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PlLabel(label),
            const SizedBox(height: 2),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(figure, maxLines: 1, style: TextStyle(fontSize: big ? Fs.xl : Fs.lg, fontWeight: FontWeight.w700))),
            Text(help, style: TextStyle(fontSize: Fs.xs, color: warn ? C.warning : t.textMuted)),
          ]),
        ),
      ),
    );
  }
}

class _Block extends StatelessWidget {
  const _Block({required this.title, this.note, this.onOpen, required this.children});
  final String title;
  final String? note;
  final VoidCallback? onOpen;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: onOpen,
          child: Row(children: [
            Text(title.toUpperCase(), style: TextStyle(fontSize: Fs.xs, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: t.textSecondary)),
            if (note != null) Text(' · $note', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
            const Spacer(),
            if (onOpen != null) Icon(LucideIcons.chevronRight, size: 16, color: t.textMuted),
          ]),
        ),
        const SizedBox(height: 6),
        ...children,
      ]),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.warn = false, this.onTap});
  final String label, value;
  final bool warn;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(child: Text(label, style: TextStyle(fontSize: Fs.sm, color: context.tk.textSecondary))),
            Text(value, style: TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w600, color: warn ? C.warning : null)),
          ]),
        ),
      );
}

class _Chart extends StatelessWidget {
  const _Chart(this.trend);
  final List<({String month, double inn, double out})> trend;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final top = trend.fold<double>(1, (m, x) => [m, x.inn, x.out].reduce((a, b) => a > b ? a : b));
    return SizedBox(
      height: 120,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final x in trend)
          Expanded(
            child: Tooltip(
              message: '${monthShortOf(x.month)}\nIn: ${formatAmount(x.inn)}\nOut: ${formatAmount(x.out)}',
              child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                Expanded(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.end, mainAxisAlignment: MainAxisAlignment.center, children: [
                    Container(width: 10, height: 96 * x.inn / top, decoration: BoxDecoration(color: C.khaki, borderRadius: BorderRadius.circular(2))),
                    const SizedBox(width: 3),
                    Container(width: 10, height: 96 * x.out / top, decoration: BoxDecoration(color: t.textMuted, borderRadius: BorderRadius.circular(2))),
                  ]),
                ),
                const SizedBox(height: 4),
                PlHelp(monthShortOf(x.month)),
              ]),
            ),
          ),
      ]),
    );
  }
}

// ---- Overview (Dashboard.jsx RoleDashboard: overview + production + inventory + sales) ---------
class _Overview extends StatefulWidget {
  const _Overview();
  @override
  State<_Overview> createState() => _OverviewState();
}

class _OverviewState extends State<_Overview> {
  Json? _d;
  DateTime? _savedAt;
  String _error = '';

  String get today => session.today;
  String get from => '${today.substring(0, 7)}-01';

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final refs = await Refs.load();
      final (d, at) = await offline.load<Json>('overview:${session.branchId}', () async {
        final res = await Future.wait<dynamic>([
          loadSalesReport(refs, from, today), loadProductionReport(from, today), loadProfit(from, today), loadPayables(), loadCuring(refs, today),
          loadLowStock(refs, session.branchId), loadWaiting(today), loadOpenOrders(today), loadMaterialUse(refs, from, today).catchError((_) => <Json>[]), loadRecentSales(),
        ]);
        return {'sales': res[0], 'prod': res[1], 'profit': res[2], 'payables': res[3], 'curing': res[4], 'low': res[5], 'waiting': res[6], 'orders': res[7], 'mats': res[8], 'recent': res[9]};
      });
      if (mounted) setState(() { _d = d; _savedAt = at; });
    } catch (e) {
      if (mounted) setState(() => _error = 'Failed to load dashboard data.');
    }
  }

  String short(num v) => formatMoneyShort(v, session.currency);

  @override
  Widget build(BuildContext context) {
    if (_error.isNotEmpty) return ErrorState(_error, onRetry: _load);
    final d = _d;
    if (d == null) return const Padding(padding: EdgeInsets.all(14), child: Skeleton());
    final shell = Shell.of(context);
    final t = context.tk;
    final sales = d['sales'] as Map, prod = d['prod'] as Map, profit = d['profit'] as Map?, curing = d['curing'] as Map, low = d['low'] as Map,
        waiting = d['waiting'] as Map, orders = d['orders'] as Map, mats = (d['mats'] as List).cast<Map>(), recent = (d['recent'] as List).cast<Map>();
    final ready = curing['ready'] as List;
    final late = (orders['rows'] as List).where((r) => r['late'] == true).length;
    String pl(int k, String one, String many) => k == 1 ? one : many;
    final alerts = <(String, String, bool)>[
      if (ready.isNotEmpty) ('${ready.length} ${pl(ready.length, 'batch', 'batches')} done curing — ready to release', '/production', false),
      if (late > 0) ('$late production order(s) past their due date', '/production', true),
      if (n(orders['dueSoon']) > 0) ('${orders['dueSoon']} production order(s) due within 7 days', '/production', false),
      if ((low['rows'] as List).isNotEmpty) ('${(low['rows'] as List).length} product(s) below their reorder level', '/stock', true),
      if (n(waiting['payToApprove']) > 0) ('${waiting['payToApprove']} pay sheet(s) to approve', '/staff', false),
      if (n(waiting['payToPay']) > 0) ('${waiting['payToPay']} approved pay sheet(s) to pay', '/staff', false),
      if (n(waiting['requests']) > 0) ('${waiting['requests']} purchase request(s) waiting for a decision', '/orders', false),
      if (n(waiting['flags']) > 0) ('${waiting['flags']} open review flag(s)', '/review', false),
      if (n(waiting['followUps']) > 0) ('${waiting['followUps']} lead follow-up(s) due', '/customers', false),
    ];
    final bags = n(prod['bags']), pieces = n(prod['pieces']);
    Widget section(String s) => Padding(padding: const EdgeInsets.fromLTRB(2, 14, 2, 6), child: Text(s, style: const TextStyle(fontSize: Fs.md, fontWeight: FontWeight.w700)));
    Widget rowLine(String a, String b, {Color? color, String? sub}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(a, style: const TextStyle(fontSize: Fs.sm)), if (sub != null) PlHelp(sub)])),
            Text(b, style: TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w600, color: color)),
          ]),
        );
    return RefreshIndicator(
      onRefresh: _load,
      child: PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        OfflineNote(_savedAt),
        Stats([
          Stat('Sales', short(n(sales['total'])), help: '${sales['docs']} orders & invoices', onTap: () => shell.go('/sales')),
          Stat('Received', short(n(sales['received'])), help: 'payments this month', onTap: () => shell.go('/sales')),
          Stat('Customers owe', short(n(sales['owed'])), help: 'all open sales', onTap: () => shell.go('/customers')),
          Stat('We owe', d['payables'] == null ? '—' : short(n(d['payables'])), help: 'suppliers & expenses', onTap: () => shell.go('/purchases')),
          Stat('Production', '${formatAmount(pieces)} pcs', help: '${formatAmount(bags)} bags of cement', onTap: () => shell.go('/production/ledger')),
          Stat('Gross margin', profit == null ? '—' : short(n(profit['margin'])),
              help: profit != null && n(profit['sales']) > 0 ? '${n1(n(profit['margin']) / n(profit['sales']) * 100)}% of delivered' : 'nothing delivered'),
        ]),
        CardBox(
          title: 'Needs attention',
          child: alerts.isEmpty
              ? const PlHelp('Nothing waiting.')
              : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final (text, to, warn) in alerts)
                    InkWell(onTap: () => shell.go(to), child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text('$text ›', style: TextStyle(fontSize: Fs.sm, color: warn ? C.warning : t.textPrimary)))),
                ]),
        ),
        section('Production'),
        Stats([
          Stat('Cast this month', '${formatAmount(pieces)} pcs', help: '${prod['batches']} batches'),
          Stat('Cement', '${formatAmount(bags)} bags', help: 'wastani ${bags > 0 ? n1((pieces + n(prod['leftovers'])) / bags) : '—'} a bag'),
          Stat('Curing now', '${formatAmount(n(curing['pieces']))} pcs', help: '${ready.length} batch${ready.length == 1 ? '' : 'es'} ready to release'),
          Stat('Rejected', formatAmount(n(prod['rejected'])), help: n(prod['released']) > 0 ? '${n1(n(prod['rejected']) / n(prod['released']) * 100)}% of released' : 'nothing released'),
          Stat('Open orders', '${(orders['rows'] as List).length}', help: '${orders['dueSoon']} due within 7 days'),
          Stat('Over the recipe', '${mats.where((m) => m['diffPct'] != null && n(m['diffPct']) > 5).length}', help: 'materials > 5% above'),
        ]),
        CardBox(title: 'Ready to release', child: (curing['rows'] as List).isEmpty ? const PlHelp('Nothing curing.') : Column(children: [
          for (final r in (curing['rows'] as List).take(10))
            rowLine('${r['name']}', formatAmount(n(r['pieces'])), sub: 'Cast ${tableDate(r['date'])} · ${r['ready'] == true ? 'ready' : 'cured by ${tableDate(r['until'])}'}', color: r['ready'] == true ? C.success : null),
        ])),
        CardBox(title: 'Open production orders', child: (orders['rows'] as List).isEmpty ? const PlHelp('No open orders.') : Column(children: [
          for (final r in (orders['rows'] as List).take(10))
            rowLine('#${r['no']}${r['reference'] != null ? ' · ${r['reference']}' : ''}', '${formatAmount(n(r['cast']))} / ${formatAmount(n(r['planned']))}',
                sub: 'Due ${r['due'] != null ? tableDate(r['due']) : '—'} · passed ${formatAmount(n(r['passed']))}', color: r['late'] == true ? C.warning : null),
        ])),
        section('Inventory'),
        Stats([
          Stat('Products in stock', session.branchId.isNotEmpty ? '${low['inStock']}' : '—', help: session.branchId.isNotEmpty ? 'with stock at the branch' : 'choose a branch', onTap: () => shell.go('/stock')),
          Stat('Below reorder', session.branchId.isNotEmpty ? '${(low['rows'] as List).length}' : '—', help: session.branchId.isNotEmpty ? 'products to make' : 'choose a branch', onTap: () => shell.go('/stock')),
          Stat('Materials used', short(mats.fold<double>(0, (s, m) => s + n(m['cost']))), help: 'this month, at cost'),
          Stat('Over the recipe', '${mats.where((m) => m['diffPct'] != null && n(m['diffPct']) > 5).length}', help: 'materials > 5% above'),
        ]),
        CardBox(title: 'Below reorder level', child: session.branchId.isEmpty ? const PlHelp('Choose a branch.') : (low['rows'] as List).isEmpty ? const PlHelp('Everything is above its reorder level.') : Column(children: [
          for (final r in (low['rows'] as List).take(12)) rowLine('${r['name']}', '${n1(n(r['qty']))} ${r['unit']}', sub: 'reorder level ${n1(n(r['level']))} ${r['unit']}', color: C.warning),
        ])),
        CardBox(title: 'Materials this month', child: mats.isEmpty ? const PlHelp('No production this month.') : Column(children: [
          for (final m in mats)
            rowLine('${m['name']}', '${n1(n(m['actual']))} ${m['unit']}', sub: '${m['category']} · vs recipe ${m['diffPct'] != null ? '${n(m['diffPct']) > 0 ? '+' : ''}${n1(n(m['diffPct']))}%' : '—'}',
                color: m['diffPct'] != null && n(m['diffPct']).abs() > 5 ? C.warning : null),
        ])),
        section('Sales'),
        Stats([
          Stat('Sales', short(n(sales['total'])), help: '${sales['docs']} orders & invoices'),
          Stat('Received', short(n(sales['received'])), help: 'payments this month'),
          Stat('Customers owe', short(n(sales['owed'])), help: 'all open sales'),
          Stat('VAT', short(n(sales['vat'])), help: "on this month's sales"),
        ]),
        CardBox(title: 'Latest sales', child: recent.isEmpty ? const PlHelp('No orders or invoices yet.') : Column(children: [
          for (final r in recent)
            rowLine('${r['who']}', formatAmount(n(r['total'])), sub: '${tableDate(r['date'])} · #${r['no']} · ${r['stage'] == 'invoice' ? 'Invoice' : 'Order'}${n(r['balance']) > 0.5 ? ' · owes ${formatAmount(n(r['balance']))}' : ''}'),
        ])),
      ]),
    );
  }
}

// ---- Setup (master-data counts) -------------------------------------------------------------
class _Setup extends StatefulWidget {
  const _Setup();
  @override
  State<_Setup> createState() => _SetupState();
}

class _SetupState extends State<_Setup> {
  Map<String, int>? _counts;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final b = session.branchId;
    Future<int> count(Future<dynamic> q) => q.then<int>((v) => (v as List).length).catchError((_) => -1);
    final res = await Future.wait<int>([
      count(db.from('product_categories').select('id, parent_category_id').eq('status', 'active')),
      count(b.isNotEmpty ? db.from('branch_products').select('id').eq('status', 'active').eq('branch_id', b) : db.from('products').select('id').eq('status', 'active')),
      count(b.isNotEmpty ? db.from('recipe_versions').select('id').eq('status', 'active').eq('branch_id', b) : db.from('recipe_versions').select('id').eq('status', 'active')),
      count(b.isNotEmpty ? db.from('materials').select('id').eq('status', 'active').or('branch_id.is.null,branch_id.eq.$b') : db.from('materials').select('id').eq('status', 'active')),
      count(db.from('branches').select('id').eq('status', 'active')),
      count(b.isNotEmpty ? db.from('product_branch_pricing').select('product_id').eq('branch_id', b) : db.from('product_branch_pricing').select('product_id')),
      count(db.from('review_flags').select('id').eq('status', 'open')),
    ]);
    if (mounted) setState(() => _counts = {'categories': res[0], 'products': res[1], 'recipes': res[2], 'materials': res[3], 'branches': res[4], 'pricing': res[5], 'review': res[6]});
  }

  @override
  Widget build(BuildContext context) {
    final c = _counts;
    final b = session.branchId.isNotEmpty;
    final name = session.branchName ?? '';
    final shell = Shell.of(context);
    String v(String k) => c == null ? '…' : (c[k]! < 0 ? '—' : formatAmount(c[k]));
    return PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
      Stats([
        Stat('Product categories', v('categories'), help: 'Active categories', onTap: () => shell.go('/categories')),
        Stat('Products', v('products'), help: b ? "In $name's list" : 'Active products', onTap: () => shell.go('/products')),
        Stat('Recipes / BOM', v('recipes'), help: b ? 'Active at $name' : 'Active recipes', onTap: () => shell.go('/recipes')),
        Stat('Materials', v('materials'), help: b ? "Shared + $name's own" : 'Active materials', onTap: () => shell.go('/materials')),
        Stat('Branches', v('branches'), help: 'Active locations', onTap: () => shell.go('/branches')),
        Stat('Price entries', v('pricing'), help: b ? 'At $name' : 'Across all branches', onTap: () => shell.go('/pricing')),
        Stat('Needs review', v('review'), help: b ? "$name's and shared" : 'Open review flags', onTap: () => shell.go('/review')),
      ]),
    ]);
  }
}
