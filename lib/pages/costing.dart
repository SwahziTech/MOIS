import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../core/costing_calc.dart';
import '../core/format.dart';
import '../core/inventory.dart';
import '../core/sales.dart' show jl;
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../shell.dart';
import 'reports.dart' show ReportSheet, RCell;

/*
 * Costing — a port of web pages/Costing.jsx and components/costing (1e 058, 076, 118, 138; approved for the
 * phone 2026-11-27). Products: per product and colour at a branch — the latest batch's production cost per m² or
 * piece, the price WITHOUT VAT, the margin, the finished stock at cost (oldest first; stock with no production
 * cost estimated at its price) and at price; tap shows its cost in parts month by month and its stock lot by lot.
 * Standard vs actual: what each product should have cost against what it did, and why. Cost inputs: materials
 * (with consumables a bag), labour (from HR), electricity (from the meters), other overheads (from expenses).
 * Read only except consumables and the Technical admin's bag target. Online only.
 */
const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _monthsLong = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
String monthShort(String ym) => '${_months[int.parse(ym.substring(5, 7)) - 1]} ${ym.substring(0, 4)}';
String monthLong(String d) => '${_monthsLong[int.parse(d.substring(5, 7)) - 1]} ${d.substring(0, 4)}';
double _rd(num v, [int d = 2]) => (v * math.pow(10, d)).roundToDouble() / math.pow(10, d);
String _units(num v) => qtyText(_rd(v));

class CostingPage extends StatefulWidget {
  const CostingPage({super.key});
  @override
  State<CostingPage> createState() => _CostingPageState();
}

class _CostingPageState extends State<CostingPage> {
  Refs? _refs;
  List<Json>? _rows;
  String _error = '', _search = '', _chip = '', _sortBy = 'order', _view = 'products', _inView = 'materials';
  double? _target; // the Technical admin's target a bag (075) — no one else sees it
  Map<String, double?> _perBag = {};
  bool _belowOnly = false;
  String get branchId => session.branchId;
  bool get isTech => session.can('system.manage');
  String money(num v) => formatMoney(v, session.currency);

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    if (branchId.isEmpty) { setState(() => _rows = []); return; }
    try {
      final r = await Future.wait<dynamic>([Refs.load(), db.rpc('product_costing', params: {'p_branch_id': branchId})]);
      if (isTech) {
        final b = await Future.wait<dynamic>([
          db.from('tech_admin_settings').select('revenue_per_bag_target').maybeSingle().catchError((_) => null),
          db.rpc('product_yield_per_unit', params: {'p_branch_id': branchId}).catchError((_) => <dynamic>[]),
        ]);
        _target = (b[0] as Map?)?['revenue_per_bag_target'] != null ? n((b[0] as Map)['revenue_per_bag_target']).toDouble() : null;
        _perBag = {for (final x in jl(b[1])) '${x['product_id']}': x['units_per_bag'] != null ? n(x['units_per_bag']).toDouble() : null};
      }
      if (mounted) setState(() { _refs = r[0] as Refs; _rows = jl(r[1]); });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load costing. Please try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    if (branchId.isEmpty) return ListView(padding: const EdgeInsets.all(14), children: const [EmptyState(icon: LucideIcons.calculator, title: 'Pick a branch', description: 'Costs, prices and stock are per branch.')]);
    final refs = _refs;
    final tabs = PageTabs<String>(tabs: const [('products', 'Products'), ('standard', 'Standard vs actual'), ('inputs', 'Cost inputs')], value: _view, onChange: (v) => setState(() => _view = v));
    final head = [PlHelp(session.branchName ?? ''), tabs];
    if (_view == 'standard') return ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 32), children: [...head, if (refs != null) _StandardVsActual(refs: refs) else const Skeleton(rows: 4)]);
    if (_view == 'inputs') {
      return ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 32), children: [
        ...head,
        PageTabs<String>(tabs: const [('materials', 'Materials'), ('labour', 'Labour'), ('electricity', 'Electricity'), ('other', 'Other overheads')], value: _inView, onChange: (v) => setState(() => _inView = v)),
        if (refs == null)
          const Skeleton(rows: 4)
        else if (_inView == 'labour')
          const _Labour()
        else if (_inView == 'materials') ...[
          // mafuta, sabuni: an amount a bag, set here (138)
          _Consumables(refs: refs),
          _MaterialsUsed(refs: refs),
        ] else if (_inView == 'electricity')
          _Electricity(refs: refs)
        else
          const _Overheads(),
      ]);
    }

    if (_error.isNotEmpty && _rows == null) return ListView(padding: const EdgeInsets.all(14), children: [...head, ErrorState(_error, onRetry: _load)]);
    final cats = CategoryTools(refs?.categoryRows ?? []);
    String unitOf(Item? it) => refs?.unit(it?.stockUnitId) ?? '';
    String per(Item? it) => unitOf(it).toUpperCase() == 'SQM' ? 'm²' : 'pc';
    final items = [
      for (final r in _rows ?? <Json>[])
        () {
          final it = refs?.items['p:${r['product_id']}'];
          final cost = r['last_batch_cost'] != null ? n(r['last_batch_cost']).toDouble() : null;
          final price = r['price_ex_vat'] != null ? n(r['price_ex_vat']).toDouble() : null;
          final pb = isTech ? _perBag['${r['product_id']}'] : null;
          return (r: r, it: it, cost: cost, price: price, margin: cost != null && price != null ? price - cost : null, bag: price != null && pb != null && pb > 0 ? price * pb : null,
              colour: r['color_id'] != null ? refs?.colour('${r['color_id']}') : null);
        }(),
    ].where((x) => x.it != null && (n(x.r['on_hand']) != 0 || n(x.r['batches']) > 0)).toList();
    bool belowBag(x) => _target != null && x.bag != null && x.bag < _target!;
    final q = _search.trim().toLowerCase();
    bool inChip(Item it) => _chip.isEmpty || it.categoryId == _chip || cats.byId[it.categoryId]?['parent_category_id'] == _chip;
    double pctOf(x) => x.margin != null && (x.price ?? 0) > 0 ? x.margin! / x.price! : double.negativeInfinity;
    final order = productOrder(cats);
    final shown = items.where((x) => inChip(x.it!) && (!_belowOnly || belowBag(x)) && (q.isEmpty || '${x.it!.name} ${x.colour ?? ''} ${x.it!.category ?? ''}'.toLowerCase().contains(q))).toList()
      ..sort((a, b) {
        final c = _sortBy == 'bag' ? (a.bag ?? double.infinity).compareTo(b.bag ?? double.infinity)
            : _sortBy == 'margin' ? pctOf(a).compareTo(pctOf(b))
            : _sortBy == 'value' ? n(b.r['value']).compareTo(n(a.r['value'])) : 0;
        if (c != 0) return c;
        final o = order(a.it!, b.it!);
        return o != 0 ? o : (a.colour ?? '').compareTo(b.colour ?? '');
      });
    final value = items.fold<double>(0, (s, x) => s + n(x.r['value'])), est = items.fold<double>(0, (s, x) => s + n(x.r['estimated_value'])), sales = items.fold<double>(0, (s, x) => s + n(x.r['sales_value']));

    return RefreshIndicator(
      onRefresh: () async { await Refs.load(fresh: true); await _load(); },
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 32), children: [
        ...head,
        Stats([
          Stat('Finished stock at cost', _rows != null ? formatMoneyShort(value, session.currency) : '—', help: '${formatMoneyShort(value - est, session.currency)} made · ${formatMoneyShort(est, session.currency)} estimated'),
          Stat('Stock at price', _rows != null ? formatMoneyShort(sales, session.currency) : '—', help: 'without VAT'),
          if (isTech)
            Stat('A bag · target', _target != null ? '${items.where(belowBag).length} below' : '—', figureColor: items.any(belowBag) ? C.warning : null,
                help: '${_target != null ? 'target ${formatMoneyShort(_target!, session.currency)} a bag' : 'no target set'} · tap to ${_target != null ? 'show / change' : 'set'}',
                onTap: () async {
                  if (_target == null) { _editTarget(); return; }
                  final a = await showModalBottomSheet<String>(context: context, builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        ListTile(title: Text(_belowOnly ? 'Show all products' : 'Show only those below the target'), onTap: () => Navigator.pop(ctx, 'toggle')),
                        ListTile(title: const Text('Change the target'), onTap: () => Navigator.pop(ctx, 'edit')),
                      ])));
                  if (a == 'toggle') setState(() => _belowOnly = !_belowOnly);
                  if (a == 'edit') _editTarget();
                }),
        ]),
        ListToolbar(
          placeholder: 'Search product (e.g. Buibui, 600R)…', onSearch: (v) => setState(() => _search = v),
          sort: SortSpec(value: _sortBy, onChange: (v) => setState(() => _sortBy = v), options: [('order', 'Category order'), ('margin', 'Lowest margin first'), ('value', 'Highest stock value first'), if (isTech) ('bag', 'Lowest a bag first')]),
        ),
        if (refs != null) ChipRow(items: [for (final c in categoryChipItems(cats, (c) => c['status'] == 'active')) ChipItem(c.id, c.label, c.children?.map((k) => ChipItem(k.id, k.label)).toList())], value: _chip, onChange: (v) => setState(() => _chip = v)),
        if (_belowOnly) Align(alignment: Alignment.centerLeft, child: Chip2('Below the bag target ×', on: true, onTap: () => setState(() => _belowOnly = false))),
        const SizedBox(height: 8),
        Row(children: [
          Text('Products (${shown.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
          const Spacer(),
          const Tooltip(
            message: 'Production cost = materials of the latest batch (VAT included) + its electricity + its share of the month\'s production overheads. Stock with no production cost is estimated at its price without VAT. Margin = price without VAT − production cost. Labour: casual days and production salaries from HR (Staff).',
            child: PlHelp('per m² or piece, without VAT ⓘ'),
          ),
        ]),
        const SizedBox(height: 6),
        if (_rows == null)
          const Skeleton(rows: 5)
        else if (shown.isEmpty)
          const EmptyState(icon: LucideIcons.calculator, title: 'Nothing to show', description: 'Products this branch has made or holds appear here.')
        else
          for (final x in shown)
            () {
              final pct = x.margin != null && (x.price ?? 0) > 0 ? (x.margin! / x.price! * 100).round() : null;
              final it = x.it!;
              final r = x.r;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: t.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: () => Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ProductCost(row: r, title: '${it.name}${x.colour != null ? ' ${x.colour}' : ''}', unit: per(it), stockUnit: unitOf(it)))),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        // products: name on top, category below (LOCKED)
                        Text('${it.name}${x.colour != null ? ' ${x.colour}' : ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        PlHelp(it.category ?? ''),
                        const SizedBox(height: 6),
                        Center(child: x.margin != null
                            ? Text.rich(TextSpan(children: [
                                TextSpan(text: money(_rd(x.margin!)), style: TextStyle(fontWeight: FontWeight.w700, fontSize: Fs.lg, color: x.margin! < 0 ? C.error : null)),
                                TextSpan(text: ' /${per(it)}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                                TextSpan(text: '  margin${pct != null ? ' · $pct%' : ''}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                              ]))
                            : PlHelp(x.cost == null ? 'not produced yet' : 'no price')),
                        const SizedBox(height: 6),
                        PlHelp(x.cost != null ? 'production cost ${money(_rd(x.cost!))} /${per(it)} · ${tableDate(r['last_batch_date'])}' : 'cost estimated at price'),
                        if (isTech && x.bag != null) PlHelp('a bag ${money(_rd(x.bag!, 0))}${belowBag(x) ? ' · below target' : ''}', color: belowBag(x) ? C.warning : null),
                        PlHelp('price ${x.price != null ? money(_rd(x.price!)) : '—'} /${per(it)}${x.price == null && r['price_source'] != null ? ' · ${r['price_source']}' : ''}'),
                        PlHelp('stock ${_units(n(r['on_hand']))} ${unitOf(it)}${r['value'] != null ? ' · at cost ${money(_rd(n(r['value'])))}' : ''}'
                            '${n(r['estimated_value']) > 0 ? (n(r['estimated_value']) < n(r['value']) - 0.5 ? ' (${money(_rd(n(r['estimated_value'])))} estimated)' : ' (estimated)') : ''}'
                            '${r['sales_value'] != null ? ' · at price ${money(_rd(n(r['sales_value'])))}' : ''}'
                            '${n(r['uncosted_quantity']) > 0 ? ' · ${_units(n(r['uncosted_quantity']))} not valued' : ''}'),
                      ]),
                    ),
                  ),
                ),
              );
            }(),
      ]),
    );
  }

  /// the Technical admin's target a cement bag (075): price without VAT × yield a bag, per product
  Future<void> _editTarget() async {
    final c = TextEditingController(text: _target != null ? qtyText(_target!).replaceAll(',', '') : '');
    String err = '';
    final saved = await showDialog<bool>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
          title: const Text('Target a cement bag'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            TextField(controller: c, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Revenue a cement bag (TZS)')),
            const SizedBox(height: 6),
            PlHelp('Below this shows in amber.${_target != null ? ' Now: ${money(_target!)}.' : ''}'),
            if (err.isNotEmpty) PlHelp(err, color: C.error),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final v = c.text.trim().isEmpty ? null : double.tryParse(c.text.trim().replaceAll(',', ''));
                if (c.text.trim().isNotEmpty && (v == null || v < 0)) { set(() => err = 'Enter the amount as a number.'); return; }
                try {
                  await db.from('tech_admin_settings').upsert({'organization_id': session.organization!['id'], 'revenue_per_bag_target': v}, onConflict: 'organization_id');
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  set(() => err = dbError(e));
                }
              },
              child: const Text('Save'),
            ),
          ],
        )));
    if (saved == true) _load();
  }
}

// ---- a product's cost: its parts, month by month, and its stock lot by lot ----
class _ProductCost extends StatefulWidget {
  const _ProductCost({required this.row, required this.title, required this.unit, required this.stockUnit});
  final Json row;
  final String title, unit, stockUnit;
  @override
  State<_ProductCost> createState() => _ProductCostState();
}

class _ProductCostState extends State<_ProductCost> {
  List<OutRow>? _rows;
  List<Json>? _layers;
  String _error = '';
  String get today => session.today;
  String get monthStart => '${today.substring(0, 7)}-01';

  @override
  void initState() {
    super.initState();
    final d = DateTime.parse(monthStart);
    final from = iso(DateTime(d.year, d.month - 5, 1));
    loadOutputs(session.branchId, from, today).then((r) { if (mounted) setState(() => _rows = r); }).catchError((_) { if (mounted) setState(() => _error = "We couldn't load its costs."); });
    db.rpc('product_stock_value', params: {'p_branch_id': session.branchId, 'p_product_id': widget.row['product_id'], 'p_color_id': widget.row['color_id']})
        .then((d) { if (mounted) setState(() => _layers = jl((d as List?)?.firstOrNull?['layers'])); }).catchError((_) { if (mounted) setState(() => _layers = []); });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final u = widget.unit;
    String money(num v) => formatMoney(v, session.currency);
    final k = costKey(widget.row);
    final rows = _rows;
    Widget body;
    if (_error.isNotEmpty) {
      body = PlHelp(_error, color: C.error);
    } else if (rows == null) {
      body = const Skeleton(rows: 4);
    } else {
      final costed = rows.where((r) => r.key == k && r.material != null && r.qtyCast > 0).toList();
      final last = costed.isEmpty ? null : costed.reduce((a, b) => b.batchDate.compareTo(a.batchDate) >= 0 ? b : a);
      final (sFrom, sTo) = standardWindow(monthStart);
      final std = standards(rows.where((r) => r.batchDate.compareTo(sFrom) >= 0 && r.batchDate.compareTo(sTo) <= 0).toList()).byKey[k];
      if (last == null) {
        body = const PlHelp('Not made at this branch in the last 6 months.');
      } else {
        final lu = perUnit(totals(costed.where((r) => r.batchId == last.batchId)))!;
        final months = trend(costed);
        const colours = {'material': C.khakiDark, 'labour': C.info, 'power': C.warning, 'overhead': C.success};
        body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PlHelp('Cost a $u · latest batch ${tableDate(last.batchDate)}'),
          Text.rich(TextSpan(children: [
            TextSpan(text: money(lu['total']!.round()), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: Fs.lg)),
            if (std != null) TextSpan(text: '  · standard ${money(std.unit.round())}', style: TextStyle(fontSize: Fs.sm, color: t.textMuted)),
          ])),
          const SizedBox(height: 6),
          ClipRRect(borderRadius: BorderRadius.circular(4), child: SizedBox(height: 10, child: Row(children: [
            for (final p in costParts) if (lu[p]! > 0) Expanded(flex: math.max(1, (lu[p]! / lu['total']! * 1000).round()), child: Container(color: colours[p])),
          ]))),
          const SizedBox(height: 6),
          Wrap(spacing: 12, runSpacing: 4, children: [
            for (final p in costParts)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 8, height: 8, decoration: BoxDecoration(color: colours[p], shape: BoxShape.circle)),
                const SizedBox(width: 4),
                Text('${partLabel[p]} ', style: const TextStyle(fontSize: Fs.sm)),
                Text(formatAmount(lu[p]!.round()), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: Fs.sm)),
                PlHelp(' ${(lu[p]! / lu['total']! * 100).round()}%'),
              ]),
          ]),
          const SizedBox(height: 10),
          ReportSheet(
            firstWidth: 100, colWidth: 96,
            head: ['Month', 'Made', for (final p in costParts) partLabel[p]!, 'Total / $u'],
            rows: [
              for (final m in months) [monthShort(m.month), '${qtyText(m.made.round())} $u', for (final p in costParts) formatAmount(m.unit[p]!.round()), RCell(formatAmount(m.unit['total']!.round()), bold: true)],
              if (std != null) [RCell('Standard', sub: '3 months before'), '', for (final p in costParts) formatAmount(std.parts[p]!.round()), RCell(formatAmount(std.unit.round()), bold: true)],
            ],
          ),
        ]);
      }
    }
    final layers = _layers;
    return FullPage(
      title: '${widget.title} — cost',
      footer: [OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      children: [
        body,
        const SectionTitle('Stock at cost'),
        if (layers == null)
          const Skeleton(rows: 2)
        else if (layers.isEmpty)
          const PlHelp('No stock left.')
        else
          // newest on top (LOCKED)
          for (final l in layers.reversed)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${tableDate(l['date'])} · ${l['stage'] == 'curing' ? 'curing' : l['stage'] == 'released' ? 'released' : l['batch'] != null ? '—' : 'opening stock'}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.sm)),
                  PlHelp('${_units(n(l['quantity']))} ${widget.stockUnit} · ${l['cost'] != null ? '${money(_rd(n(l['cost'])))} / ${widget.stockUnit}' : '—'}'),
                  PlHelp(l['estimated'] == true ? 'estimated at price' : l['cost'] == null ? 'no price' : 'production cost', color: l['estimated'] == true ? C.warning : null),
                ])),
                Text(l['cost'] != null ? money(_rd(n(l['cost']) * n(l['quantity']))) : '—', style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
      ],
    );
  }
}

// ======================= Standard vs actual =======================
class _StandardVsActual extends StatefulWidget {
  const _StandardVsActual({required this.refs});
  final Refs refs;
  @override
  State<_StandardVsActual> createState() => _StandardVsActualState();
}

class _StandardVsActualState extends State<_StandardVsActual> {
  final _rp = RangePeriod('costing-standard');
  List<OutRow>? _rows;
  String _error = '', _loaded = '';
  String? _open;

  Future<void> _load() async {
    final key = '${_rp.from}|${_rp.to}';
    _loaded = key;
    setState(() { _error = ''; _rows = null; });
    try {
      final (sFrom, _) = standardWindow(_rp.from);
      final r = await loadOutputs(session.branchId, sFrom, _rp.to.compareTo(session.today) < 0 ? _rp.to : session.today);
      if (mounted && _loaded == key) setState(() => _rows = r);
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load the costs.");
    }
  }

  @override
  void initState() { super.initState(); _load(); }

  String sign(double v) => v > 0.5 ? '+' : v < -0.5 ? '−' : '';
  Color? cls(double v) => v > 0.5 ? C.error : v < -0.5 ? C.success : null;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final refs = widget.refs;
    String money(num v) => formatMoney(v, session.currency);
    String per(String id) => refs.unit(refs.items['p:$id']?.stockUnitId).toUpperCase() == 'SQM' ? 'm²' : 'pc';
    String nameOf(OutRow r) => '${refs.items['p:${r.productId}']?.name ?? ''}${r.colorId != null ? ' ${refs.colour(r.colorId)}' : ''}';
    final rows = _rows;
    final children = <Widget>[_rp.bar(context, _load), const SizedBox(height: 8)];
    if (_error.isNotEmpty) return Column(children: [...children, ErrorState(_error, onRetry: _load)]);
    if (rows == null) return Column(children: [...children, const Skeleton(rows: 4)]);
    final (sFrom, sTo) = standardWindow(_rp.from);
    final s = standards(rows.where((r) => r.batchDate.compareTo(sFrom) >= 0 && r.batchDate.compareTo(sTo) <= 0).toList());
    final groups = <String, List<OutRow>>{};
    for (final r in rows.where((r) => r.batchDate.compareTo(_rp.from) >= 0 && r.batchDate.compareTo(_rp.to) <= 0)) { (groups[r.key] ??= []).add(r); }
    final list = [
      for (final e in groups.entries)
        () { final tt = totals(e.value); return (key: e.key, first: e.value.first, t: tt, v: variance(tt, s.byKey[e.key], s)); }(),
    ].where((x) => x.t.qtyCast > 0).toList()
      ..sort((a, b) => (b.v?.diff.abs() ?? 0).compareTo(a.v?.diff.abs() ?? 0));
    var std = 0.0, actual = 0.0, rejects = 0.0;
    final causes = <String, double>{};
    for (final x in list) {
      if (x.v == null) continue;
      std += x.v!.stdTotal; actual += x.v!.actualTotal; rejects += x.v!.rejectCost;
      for (final c in x.v!.causes.entries) { causes[c.key] = (causes[c.key] ?? 0) + c.value; }
    }
    final top = (causes.entries.toList()..sort((a, b) => b.value.abs().compareTo(a.value.abs()))).firstOrNull;
    final noStd = list.where((x) => x.v == null).length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...children,
      Stats([
        Stat('Actual cost', formatMoneyShort(actual.round(), session.currency), help: 'standard ${formatMoneyShort(std.round(), session.currency)}'),
        Stat('Difference', '${sign(actual - std)}${formatMoneyShort((actual - std).abs().round(), session.currency)}', figureColor: cls(actual - std),
            help: top != null && top.value.abs() > 0.5 ? 'most from ${causeLabel[top.key]!.toLowerCase()}' : ''),
        Stat('Rejects', formatMoneyShort(rejects.round(), session.currency), figureColor: rejects > 0.5 ? C.error : null, help: 'at full cost'),
      ]),
      if (list.isEmpty)
        const EmptyState(icon: LucideIcons.scale, title: 'Nothing made in this period', description: 'Products made in the period are compared with their standard here.')
      else
        for (final x in list)
          () {
            final p = per(x.first.productId);
            final isOpen = _open == x.key;
            final d = x.v != null ? x.v!.actualUnit - x.v!.stdUnit : null;
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: t.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                InkWell(
                  onTap: x.v == null ? null : () => setState(() => _open = isOpen ? null : x.key),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        if (x.v != null) Icon(isOpen ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 14),
                        Expanded(child: Text(nameOf(x.first), style: const TextStyle(fontWeight: FontWeight.w700))),
                        if (d != null) Text('${sign(d * x.t.qtyCast)}${formatAmount(d.abs().round())} /$p', style: TextStyle(fontWeight: FontWeight.w700, color: cls(d * x.t.qtyCast))),
                      ]),
                      PlHelp('${x.t.count} batch${x.t.count == 1 ? '' : 'es'} · made ${qtyText(x.t.qtyCast.round())} $p'
                          ' · standard ${x.v != null ? formatAmount(x.v!.stdUnit.round()) : '—'} · actual ${formatAmount((x.t.total / x.t.qtyCast).round())}'
                          '${d != null ? ' · ${(d / x.v!.stdUnit * 100).round()}%' : ''}'
                          '${(x.v?.rejectQty ?? 0) > 0 ? ' · rejects ${qtyText(_rd(x.v!.rejectQty))} $p' : ''}'),
                    ]),
                  ),
                ),
                if (isOpen && x.v != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Wrap(spacing: 8, runSpacing: 8, children: [
                        for (final c in x.v!.causes.entries)
                          Tooltip(message: causeHelp[c.key]!, child: _CauseBox(label: causeLabel[c.key]!, value: c.value.abs() < 0.5 ? '—' : '${sign(c.value)}${money(c.value.abs().round())}', color: cls(c.value))),
                        _CauseBox(label: 'Total', value: '${sign(x.v!.diff)}${money(x.v!.diff.abs().round())}', color: cls(x.v!.diff), bold: true),
                        if (x.v!.rejectCost > 0.5) _CauseBox(label: 'Rejects', value: money(x.v!.rejectCost.round()), color: C.error),
                      ]),
                      const SizedBox(height: 6),
                      PlHelp('+ costs more than the standard, − costs less. Standard from ${tableDate(sFrom)} to ${tableDate(sTo)}: recipe × average material prices, the branch\'s labour, electricity and overheads a cement bag, the usual yield.'),
                    ]),
                  ),
              ]),
            );
          }(),
      if (noStd > 0) PlHelp('$noStd product${noStd == 1 ? ' was' : 's were'} not made in the 3 months before, so ${noStd == 1 ? 'it has' : 'they have'} no standard yet.'),
    ]);
  }
}

class _CauseBox extends StatelessWidget {
  const _CauseBox({required this.label, required this.value, this.color, this.bold = false});
  final String label, value;
  final Color? color;
  final bool bold;
  @override
  Widget build(BuildContext context) => Container(
        width: 140,
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: context.tk.soft, borderRadius: BorderRadius.circular(8)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          PlHelp(label),
          Text(value, style: TextStyle(fontWeight: bold ? FontWeight.w800 : FontWeight.w700, color: color)),
        ]),
      );
}

// ======================= Cost inputs: consumables a bag (138) =======================
class _Consumables extends StatefulWidget {
  const _Consumables({required this.refs});
  final Refs refs;
  @override
  State<_Consumables> createState() => _ConsumablesState();
}

class _ConsumablesState extends State<_Consumables> {
  List<Json>? _rows;
  bool _off = false;
  bool get canEdit => session.canAt('products.manage', session.branchId, null);

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final d = jl(await db.from('production_consumables').select('*').eq('branch_id', session.branchId));
      if (mounted) setState(() => _rows = d);
    } catch (_) {
      if (mounted) setState(() => _off = true); // before 138
    }
  }

  Future<void> _edit([Json? r]) async {
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ConsumableForm(row: r, refs: widget.refs, taken: [for (final x in _rows ?? <Json>[]) '${x['material_id']}'])));
    if (ok == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_off) return const SizedBox.shrink();
    final refs = widget.refs;
    final cats = CategoryTools(refs.categoryRows);
    final rows = _rows;
    String name(Object? id) => refs.items['m:$id']?.name ?? '—';
    return CardBox(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Tooltip(
            message: 'Not in the recipes: each batch of these categories takes bags × the amount out of its store, and their cost goes into the batch\'s cost',
            child: Text('Consumables a bag of cement ⓘ', style: TextStyle(fontWeight: FontWeight.w700)),
          )),
          if (canEdit) TextButton.icon(onPressed: () => _edit(), icon: const Icon(LucideIcons.plus, size: 14), label: const Text('Add')),
        ]),
        if (rows == null)
          const Skeleton(rows: 2)
        else if (rows.isEmpty)
          const PlHelp('None yet — e.g. mafuta and sabuni for floor tiles.')
        else
          for (final r in [...rows]..sort((a, b) => name(a['material_id']).compareTo(name(b['material_id']))))
            InkWell(
              onTap: canEdit ? () => _edit(r) : null,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name(r['material_id']), style: TextStyle(fontWeight: FontWeight.w600, color: r['status'] == 'active' ? null : context.tk.textMuted)),
                    PlHelp([for (final id in (r['category_ids'] as List? ?? [])) cats.label('$id')].join(', ').ifEmpty('no category'), color: (r['category_ids'] as List? ?? []).isEmpty ? C.warning : null),
                  ])),
                  Text('${qtyText(n(r['quantity_per_bag']))} ${refs.unit('${r['unit_id']}')}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  Badge2(r['status'] == 'active' ? 'On' : 'Off', tone: r['status'] == 'active' ? Tone.success : Tone.neutral),
                ]),
              ),
            ),
      ]),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

class _ConsumableForm extends StatefulWidget {
  const _ConsumableForm({this.row, required this.refs, required this.taken});
  final Json? row;
  final Refs refs;
  final List<String> taken;
  @override
  State<_ConsumableForm> createState() => _ConsumableFormState();
}

class _ConsumableFormState extends State<_ConsumableForm> {
  Json? get row => widget.row;
  Refs get refs => widget.refs;
  late String _materialId = '${row?['material_id'] ?? ''}', _unitId = '${row?['unit_id'] ?? ''}';
  late final _qty = TextEditingController(text: row?['quantity_per_bag'] != null ? qtyText(n(row!['quantity_per_bag'])).replaceAll(',', '') : '');
  late List<String> _cats = [for (final x in (row?['category_ids'] as List? ?? [])) '$x'];
  late bool _on = (row?['status'] ?? 'active') == 'active';
  bool _busy = false;
  String _error = '';

  Item? get mat => refs.items['m:$_materialId'];

  Future<void> _save() async {
    setState(() => _error = '');
    final q = double.tryParse(_qty.text.trim().replaceAll(',', ''));
    if (_materialId.isEmpty) { setState(() => _error = 'Choose the material.'); return; }
    if (!((q ?? 0) > 0)) { setState(() => _error = 'Enter the amount a bag of cement.'); return; }
    if (_cats.isEmpty) { setState(() => _error = 'Tick the categories that use it.'); return; }
    final values = {'material_id': _materialId, 'unit_id': _unitId, 'quantity_per_bag': q, 'category_ids': _cats, 'status': _on ? 'active' : 'inactive'};
    setState(() => _busy = true);
    try {
      if (row == null) {
        await db.from('production_consumables').insert({...values, 'organization_id': session.organization!['id'], 'branch_id': session.branchId});
      } else {
        await db.from('production_consumables').update(values).eq('id', row!['id']);
      }
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      _error = e is PostgrestException && e.code == '23505' ? 'That material is already on the list.' : dbError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _remove() async {
    setState(() => _busy = true);
    try {
      await db.from('production_consumables').delete().eq('id', row!['id']);
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final cats = CategoryTools(refs.categoryRows);
    final materials = refs.items.values.where((i) => i.kind == 'material' && i.status == 'active' && (i.branchId == null || i.branchId == session.branchId) && (i.id == row?['material_id'] || !widget.taken.contains(i.id))).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final categories = refs.categoryRows.where((c) => c['status'] == 'active').toList()..sort(cats.compare);
    return FullPage(
      title: row == null ? 'Add a consumable' : 'Edit ${mat?.name ?? ''}',
      footer: [
        if (row != null) TextButton(onPressed: _busy ? null : _remove, child: const Text('Remove', style: TextStyle(color: C.error))),
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
      ],
      children: [
        DropdownButtonFormField<String>(
          initialValue: _materialId, isExpanded: true, decoration: const InputDecoration(labelText: 'Material'),
          items: [const DropdownMenuItem(value: '', child: Text('Choose…')), for (final m in materials) DropdownMenuItem(value: m.id, child: Text(m.name, overflow: TextOverflow.ellipsis))],
          onChanged: row != null ? null : (v) => setState(() {
            _materialId = v ?? '';
            final m = mat;
            if (m != null && !m.units.any((u) => u.id == _unitId)) _unitId = m.mainUnitId ?? m.stockUnitId ?? '';
          }),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'A bag of cement'))),
          const SizedBox(width: 8),
          Expanded(child: DropdownButtonFormField<String>(
            initialValue: (mat?.units ?? []).any((u) => u.id == _unitId) ? _unitId : null, isExpanded: true, decoration: const InputDecoration(labelText: 'Unit'),
            items: [for (final u in mat?.units ?? <UnitF>[]) DropdownMenuItem(value: u.id, child: Text(refs.unit(u.id)))],
            onChanged: mat == null ? null : (v) => setState(() => _unitId = v ?? ''),
          )),
        ]),
        const SizedBox(height: 10),
        const PlLabel('For these categories'),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final c in categories)
            Chip2(cats.label(c), on: _cats.contains(c['id']), onTap: () => setState(() => _cats = _cats.contains(c['id']) ? _cats.where((x) => x != c['id']).toList() : [..._cats, '${c['id']}'])),
        ]),
        CheckboxListTile(value: _on, onChanged: (v) => setState(() => _on = v ?? true), contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
            title: const Text('On — batches take it from the store (turn on once its stock is entered)', style: TextStyle(fontSize: Fs.sm))),
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
      ],
    );
  }
}

// ======================= Cost inputs: materials used =======================
class _MaterialsUsed extends StatefulWidget {
  const _MaterialsUsed({required this.refs});
  final Refs refs;
  @override
  State<_MaterialsUsed> createState() => _MaterialsUsedState();
}

class _MaterialsUsedState extends State<_MaterialsUsed> {
  final _rp = RangePeriod('costing-materials');
  List<Json>? _used;
  Map<String, Json?> _stock = {};
  String _error = '';
  Refs get refs => widget.refs;
  late final List<Item> mats = refs.items.values.where((i) => i.kind == 'material' && i.status == 'active' && (i.branchId == null || i.branchId == session.branchId)).toList();

  @override
  void initState() {
    super.initState();
    _load();
    Future.wait([for (final m in mats) db.rpc('material_stock_value', params: {'p_branch_id': session.branchId, 'p_material_id': m.id}).then<Json?>((v) => (v as List?)?.firstOrNull as Json?).catchError((_) => null)])
        .then((r) { if (mounted) setState(() => _stock = {for (final (i, m) in mats.indexed) m.id: r[i]}); });
  }

  Future<void> _load() async {
    setState(() { _error = ''; _used = null; });
    try {
      final d = jl(await db.from('production_batch_materials').select('material_id, stock_quantity, cost, source, batch:production_batches!inner(batch_date, branch_id, status)')
          .eq('batch.branch_id', session.branchId).neq('batch.status', 'void').gte('batch.batch_date', _rp.from).lte('batch.batch_date', _rp.to));
      if (mounted) setState(() => _used = d);
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load material costs.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final used = _used;
    final children = <Widget>[const SizedBox(height: 10), _rp.bar(context, _load), const SizedBox(height: 8)];
    if (_error.isNotEmpty) return Column(children: [...children, ErrorState(_error, onRetry: _load)]);
    if (used == null) return Column(children: [...children, const Skeleton(rows: 4)]);
    final by = <String, ({double qty, double cost, bool uncosted, bool indirect})>{};
    for (final u in used) {
      final x = by['${u['material_id']}'];
      by['${u['material_id']}'] = (qty: (x?.qty ?? 0) + n(u['stock_quantity']), cost: (x?.cost ?? 0) + n(u['cost']), uncosted: (x?.uncosted ?? false) || u['cost'] == null,
          indirect: (x?.indirect ?? false) || u['source'] == 'consumable');
    }
    final total = by.values.where((x) => !x.indirect).fold<double>(0, (s, x) => s + x.cost);
    final rows = [
      for (final m in mats)
        () {
          final x = by[m.id] ?? (qty: 0.0, cost: 0.0, uncosted: false, indirect: false);
          final main = m.mainUnitId != null ? m.units.where((u) => u.id == m.mainUnitId).firstOrNull : null; // shown in its main unit (051)
          final f = main?.factor ?? 1;
          final sv = _stock[m.id];
          return (m: m, indirect: x.indirect || !m.inRecipes, qty: x.qty / f, unit: refs.unit(main?.id ?? m.stockUnitId), cost: _rd(x.cost), share: !x.indirect && total > 0 ? x.cost / total : 0.0,
              perUnit: x.qty > 0 ? x.cost / (x.qty / f) : null, uncosted: x.uncosted,
              stockValue: sv?['value'] != null ? n(sv!['value']).toDouble() : null, stockQty: sv?['on_hand'] != null ? n(sv!['on_hand']) / f : null, unitCost: sv?['unit_cost'] != null ? n(sv!['unit_cost']) * f : null);
        }(),
    ].where((r) => r.qty > 0 || (r.stockValue ?? 0) > 0).toList()
      ..sort((a, b) { final c = b.cost.compareTo(a.cost); if (c != 0) return c; final k = a.m.rank.compareTo(b.m.rank); return k != 0 ? k : a.m.name.compareTo(b.m.name); });
    final direct = rows.where((r) => !r.indirect).toList(), indirect = rows.where((r) => r.indirect).toList();
    final totalUsed = direct.fold<double>(0, (s, r) => s + r.cost), indirectUsed = indirect.fold<double>(0, (s, r) => s + r.cost);
    final top = direct.where((r) => r.cost > 0).firstOrNull;
    final stockTotal = rows.fold<double>(0, (s, r) => s + (r.stockValue ?? 0));
    Widget row(r) => Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            // materials: category above the name (LOCKED)
            PlHelp(r.m.materialCategory ?? ''),
            Row(children: [
              Expanded(child: Text(r.m.name, style: const TextStyle(fontWeight: FontWeight.w700))),
              Text(r.cost != 0 ? formatAmount(r.cost) : '', style: const TextStyle(fontWeight: FontWeight.w700)),
            ]),
            PlHelp([
              if (r.qty > 0) 'used ${qtyText(_rd(r.qty))} ${r.unit}',
              if (r.share > 0) '${(r.share * 1000).round() / 10}%',
              if (r.perUnit != null) '${formatAmount(r.perUnit!)} /${r.unit}',
              if (r.stockQty != null) 'in store ${qtyText(_rd(r.stockQty!))} ${r.unit}${r.unitCost != null ? ' at ${formatAmount(r.unitCost!)}' : ''}',
              if (r.stockValue != null) 'value ${formatAmount(r.stockValue!)}',
            ].join(' · ')),
            if (r.uncosted) const PlHelp('part without a cost', color: C.warning),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...children,
      Stats([
        Stat('Materials used', formatMoneyShort(_rd(totalUsed), session.currency), help: 'into production${indirectUsed > 0 ? ' · + ${formatMoneyShort(_rd(indirectUsed), session.currency)} consumables' : ''}'),
        Stat('Biggest cost', top?.m.name ?? '—', help: top != null ? '${(top.share * 100).round()}% · ${formatMoneyShort(top.cost, session.currency)}' : 'nothing used yet'),
        Stat('In store at cost', formatMoneyShort(_rd(stockTotal), session.currency), help: 'oldest stock first'),
      ]),
      if (rows.isEmpty)
        const EmptyState(icon: LucideIcons.layers, title: 'Nothing used in this period', description: 'Materials taken by production batches show here, with their cost.')
      else ...[
        for (final r in direct) row(r),
        if (indirect.isNotEmpty) const SectionTitle('Indirect materials (consumables)'),
        for (final r in indirect) row(r),
        Padding(padding: const EdgeInsets.only(top: 8), child: Text('Total ${formatMoney(_rd(totalUsed + indirectUsed), session.currency)} · store ${formatMoney(_rd(stockTotal), session.currency)}', style: const TextStyle(fontWeight: FontWeight.w700))),
      ],
      const SizedBox(height: 6),
      const Tooltip(message: "From Production: each batch's materials, costed oldest stock first with VAT included — the material part of every product's production cost. Purchases › Material costs shows prices paid.", child: PlHelp("How it's worked out ⓘ")),
    ]);
  }
}

// ======================= Cost inputs: labour (HR) =======================
class _Labour extends StatefulWidget {
  const _Labour();
  @override
  State<_Labour> createState() => _LabourState();
}

class _LabourState extends State<_Labour> {
  String _view = 'days', _error = '';
  ({List<Json> days, List<Json> months, Map<String, double> bagsDay, Map<String, double> bagsMonth})? _data;
  bool get can => session.canAt('staff.view', session.branchId, null);

  @override
  void initState() { super.initState(); if (can) _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    final since = iso(DateTime.parse(session.today).subtract(const Duration(days: 90)));
    try {
      final r = await Future.wait<dynamic>([
        db.from('labour_days').select('*').eq('branch_id', session.branchId).gte('day', since).order('day', ascending: false),
        db.from('labour_months').select('*').eq('branch_id', session.branchId).gte('month', '${since.substring(0, 8)}01').order('month', ascending: false),
        db.from('production_batches').select('batch_date, cement_bags').eq('branch_id', session.branchId).neq('status', 'void').gte('batch_date', '${since.substring(0, 8)}01'),
      ]);
      final bd = <String, double>{}, bm = <String, double>{};
      for (final x in jl(r[2])) {
        bd['${x['batch_date']}'] = (bd['${x['batch_date']}'] ?? 0) + n(x['cement_bags']);
        final mo = '${'${x['batch_date']}'.substring(0, 8)}01';
        bm[mo] = (bm[mo] ?? 0) + n(x['cement_bags']);
      }
      if (mounted) setState(() => _data = (days: jl(r[0]), months: jl(r[1]), bagsDay: bd, bagsMonth: bm));
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load labour costs.");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!can) return const EmptyState(icon: LucideIcons.hardHat, title: 'Labour pay is private', description: 'Seen by those who see staff pay (Technical admin, directors, branch manager, secretary).');
    if (_error.isNotEmpty) return ErrorState(_error, onRetry: _load);
    final d = _data;
    if (d == null) return const Skeleton(rows: 4);
    final thisMonth = '${session.today.substring(0, 8)}01';
    final mo = d.months.where((x) => x['month'] == thisMonth).firstOrNull;
    double costOf(Json? x) => n(x?['wages']) + n(x?['employer']).toDouble();
    final bags = d.bagsMonth[thisMonth] ?? 0;
    final total = costOf(mo);
    final unpriced = n(mo?['without_rate']).toInt();
    final list = _view == 'days' ? d.days : d.months;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 10),
      Stats([
        Stat('Labour this month', formatMoneyShort(_rd(total), session.currency), help: 'pay ${formatAmount(n(mo?['wages']))} · employer ${formatAmount(n(mo?['employer']))}'),
        Stat('A cement bag', bags > 0 ? formatMoney(_rd(total / bags), session.currency) : '—', help: bags > 0 ? '${formatAmount(bags)} bags this month' : 'no batches this month'),
        Stat('Pay not set', '$unpriced', figureColor: unpriced > 0 ? C.warning : null, help: unpriced > 0 ? 'worked this month, no rate' : 'everyone has a rate'),
      ]),
      Row(children: [
        Expanded(child: SlideRow(children: [Chip2('By day', on: _view == 'days', onTap: () => setState(() => _view = 'days')), Chip2('By month', on: _view == 'months', onTap: () => setState(() => _view = 'months'))])),
        TextButton(onPressed: () => Shell.of(context).go('/staff'), child: const Text('Staff ›')),
      ]),
      const SizedBox(height: 6),
      if (list.isEmpty)
        const PlHelp('No days yet — mark attendance in HR › Staff.')
      else
        ReportSheet(
          firstWidth: 120,
          head: [_view == 'days' ? 'Day' : 'Month', 'People', 'Days', 'Pay (TZS)', 'Employer (TZS)', 'Labour (TZS)', 'Cement bags', 'A bag (TZS)'],
          rows: [
            for (final x in list)
              () {
                final key = _view == 'days' ? '${x['day']}' : '${x['month']}';
                final b = _view == 'days' ? d.bagsDay[key] : d.bagsMonth[key];
                return [
                  RCell(_view == 'days' ? (tableDate(key) ?? key) : monthLong(key), sub: n(x['without_rate']) > 0 ? '${x['without_rate']} without a rate' : null, warn: n(x['without_rate']) > 0),
                  '${x['people'] ?? ''}', qtyText(n(x['days'])), formatAmount(n(x['wages'])), n(x['employer']) != 0 ? formatAmount(n(x['employer'])) : '',
                  RCell(formatAmount(costOf(x)), bold: true), b != null ? formatAmount(b) : 'no batches', b != null && b > 0 ? formatAmount(costOf(x) / b) : '',
                ];
              }(),
          ],
        ),
      const SizedBox(height: 6),
      const Tooltip(message: "From HR, as the pay sheets pay it: each production person's days attended × day rate (a salary ÷ working days a month), plus the employer's NSSF, WCF and SDL — shared over that day's batches by cement bags. Office and running staff are left out (untick them in Staff).", child: PlHelp("How it's worked out ⓘ")),
    ]);
  }
}

// ======================= Cost inputs: electricity =======================
class _Electricity extends StatefulWidget {
  const _Electricity({required this.refs});
  final Refs refs;
  @override
  State<_Electricity> createState() => _ElectricityState();
}

class _ElectricityState extends State<_Electricity> {
  final _rp = RangePeriod('costing-electricity');
  String _view = 'days', _error = '';
  String? _openDay;
  ({List<Json> meters, List<Json> links, List<Json> days, List<Json> batches, Map<String, double?> perSqm})? _data;
  Refs get refs => widget.refs;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() { _error = ''; _data = null; });
    final b = session.branchId;
    try {
      final r = await Future.wait<dynamic>([
        db.from('power_meters').select('id, name, status').eq('branch_id', b).order('name', ascending: true),
        db.from('power_meter_machines').select('meter_id, machine_id'),
        db.from('power_daily').select('*').eq('branch_id', b).gte('day', _rp.from).lte('day', _rp.to).order('day', ascending: false),
        db.from('production_batches').select('id, batch_date, machine_id, cement_bags, outputs:production_batch_outputs(product_id, color_id, pieces_cast, cement_share)')
            .eq('branch_id', b).gte('batch_date', _rp.from).lte('batch_date', _rp.to).neq('status', 'void'),
        db.from('product_specs').select('product_id, pcs_per_sqm'),
      ]);
      if (mounted) {
        setState(() => _data = (meters: jl(r[0]), links: jl(r[1]), days: jl(r[2]), batches: jl(r[3]),
            perSqm: {for (final x in jl(r[4])) '${x['product_id']}': n(x['pcs_per_sqm']) > 0 ? n(x['pcs_per_sqm']).toDouble() : null}));
      }
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load electricity costs.");
    }
  }

  bool isSqm(Object? pid) => refs.unit(refs.items['p:$pid']?.stockUnitId).toUpperCase() == 'SQM';
  String nameOf(Object? pid, Object? cid) => '${refs.items['p:$pid']?.name ?? '—'}${cid != null ? ' ${refs.colour('$cid')}' : ''}';

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final data = _data;
    final top = <Widget>[const SizedBox(height: 10), _rp.bar(context, _load), const SizedBox(height: 8)];
    if (_error.isNotEmpty) return Column(children: [...top, ErrorState(_error, onRetry: _load)]);
    if (data == null) return Column(children: [...top, const Skeleton(rows: 4)]);
    if (data.meters.isEmpty) return const EmptyState(icon: LucideIcons.zap, title: 'No meters yet', description: 'Electricity is recorded under Purchases: meters (⚙), tokens (Record expense → Electricity) and morning/evening readings.');
    // each day and meter: its batches with their share of the day use
    final meterOf = {for (final l in data.links) '${l['machine_id']}': '${l['meter_id']}'};
    final days = [
      for (final d in data.days.where((d) => d['day_units'] != null))
        () {
          final bs = data.batches.where((b) => b['batch_date'] == d['day'] && meterOf['${b['machine_id']}'] == '${d['meter_id']}').toList();
          final bags = bs.fold<double>(0, (s, b) => s + n(b['cement_bags']));
          final cost = n(d['day_cost']).toDouble();
          return (d: d, bags: bags, batches: [
            for (final b in bs)
              () {
                final share = bags > 0 ? _rd(cost * n(b['cement_bags']) / bags) : 0.0;
                return (b: b, share: share, outputs: [for (final o in jl(b['outputs']).where((o) => n(o['pieces_cast']) > 0)) (o: o, share: _rd(share * n(o['cement_share'])))]);
              }(),
          ]);
        }(),
    ];
    // per product: electricity charged, per bag, per m² or piece
    final byP = <String, ({String pid, String? cid, Set<String> batches, double bags, double pieces, double cost, String? last})>{};
    for (final d in days) {
      for (final b in d.batches) {
        for (final o in b.outputs) {
          final k = '${o.o['product_id']}|${o.o['color_id'] ?? ''}';
          final x = byP[k];
          byP[k] = (pid: '${o.o['product_id']}', cid: o.o['color_id'] as String?, batches: {...?x?.batches, '${b.b['id']}'}, bags: (x?.bags ?? 0) + n(b.b['cement_bags']) * n(o.o['cement_share']),
              pieces: (x?.pieces ?? 0) + n(o.o['pieces_cast']), cost: (x?.cost ?? 0) + o.share, last: x?.last == null || '${d.d['day']}'.compareTo(x!.last!) > 0 ? '${d.d['day']}' : x.last);
        }
      }
    }
    final products = [
      for (final x in byP.values)
        () {
          final sqm = isSqm(x.pid) && data.perSqm[x.pid] != null ? x.pieces / data.perSqm[x.pid]! : null;
          final qty = sqm ?? x.pieces;
          return (x: x, qty: qty, unit: sqm != null ? 'm²' : 'pc', perUnit: qty > 0 ? x.cost / qty : null, perBag: x.bags > 0 ? x.cost / x.bags : null);
        }(),
    ]..sort((a, b) => b.x.cost.compareTo(a.x.cost));
    var units = 0.0, cost = 0.0, night = 0.0, unused = 0.0;
    for (final d in days) { units += n(d.d['day_units']); cost += n(d.d['day_cost']); night += n(d.d['night_cost']); if (d.bags <= 0) unused += n(d.d['day_cost']); }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 10),
      Stats([
        Stat('Into products', formatMoneyShort(_rd(cost - unused), session.currency), help: 'day use on days with batches'),
        Stat('Day use, no batches', formatMoneyShort(_rd(unused), session.currency), figureColor: unused > 0 ? C.warning : null, help: 'idle days — not charged'),
        Stat('Nights (lights)', formatMoneyShort(_rd(night), session.currency), help: 'running cost'),
        Stat('Day units', _units(units), help: '${days.length} meter-days'),
      ]),
      _rp.bar(context, _load),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: SlideRow(children: [Chip2('By day', on: _view == 'days', onTap: () => setState(() => _view = 'days')), Chip2('By product', on: _view == 'products', onTap: () => setState(() => _view = 'products'))])),
        TextButton(onPressed: () => Shell.of(context).go('/expenses?tab=electricity'), child: const Text('Readings ›')),
      ]),
      const SizedBox(height: 6),
      if (_view == 'days') ...[
        if (days.isEmpty) const PlHelp('No day use in this period.'),
        for (final d in days)
          () {
            final k = '${d.d['meter_id']}|${d.d['day']}';
            final isOpen = _openDay == k;
            return Container(
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                InkWell(
                  onTap: d.batches.isEmpty ? null : () => setState(() => _openDay = isOpen ? null : k),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        if (d.batches.isNotEmpty) Icon(isOpen ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 14),
                        Expanded(child: Text('${tableDate(d.d['day'])} · ${d.d['meter_name'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600))),
                        Text(formatAmount(n(d.d['day_cost'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                      PlHelp('${_units(n(d.d['day_units']))} units · ${d.batches.isEmpty ? 'idle' : '${d.batches.length} batches · ${_units(d.bags)} bags · ${_units(n(d.d['day_units']) / d.bags)} units a bag · ${formatAmount(n(d.d['day_cost']) / d.bags)} a bag'}'),
                    ]),
                  ),
                ),
                if (isOpen)
                  for (final b in d.batches)
                    for (final o in b.outputs)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 0, 0, 6),
                        child: Row(children: [
                          Expanded(child: PlHelp('${nameOf(o.o['product_id'], o.o['color_id'])} · ${_units(n(o.o['pieces_cast']))} pcs')),
                          Text(formatAmount(o.share), style: const TextStyle(fontSize: Fs.sm)),
                          PlHelp('  ${() { final sq = isSqm(o.o['product_id']) && data.perSqm['${o.o['product_id']}'] != null ? n(o.o['pieces_cast']) / data.perSqm['${o.o['product_id']}']! : null; return sq != null ? '${formatAmount(o.share / sq)} /m²' : '${formatAmount(o.share / n(o.o['pieces_cast']))} /pc'; }()}'),
                        ]),
                      ),
              ]),
            );
          }(),
      ] else ...[
        if (products.isEmpty) const PlHelp('No batches on metered machines in this period.'),
        for (final p in products)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [Expanded(child: Text(nameOf(p.x.pid, p.x.cid), style: const TextStyle(fontWeight: FontWeight.w700))), Text(formatAmount(p.x.cost), style: const TextStyle(fontWeight: FontWeight.w700))]),
              PlHelp('${p.x.batches.length} batches · ${_units(p.x.bags)} bags · made ${_units(p.qty)} ${p.unit == 'm²' ? 'm²' : 'pcs'}'
                  '${p.perBag != null ? ' · ${formatAmount(p.perBag!)} a bag' : ''}${p.perUnit != null ? ' · ${formatAmount(p.perUnit!)} /${p.unit}' : ''} · latest ${tableDate(p.x.last)}'),
            ]),
          ),
        if (products.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Total ${formatMoney(_rd(products.fold<double>(0, (s, p) => s + p.x.cost)), session.currency)}', style: const TextStyle(fontWeight: FontWeight.w700))),
      ],
      const SizedBox(height: 6),
      const Tooltip(message: "From Purchases › Electricity (each meter's day use, morning → evening) and Production (the batches on that meter's machines). A day's cost is shared over its batches by cement bags, and within a batch over its products by cement taken. Idle days and nights are not charged to products.", child: PlHelp("How it's worked out ⓘ")),
    ]);
  }
}

// ======================= Cost inputs: other overheads =======================
class _Overheads extends StatefulWidget {
  const _Overheads();
  @override
  State<_Overheads> createState() => _OverheadsState();
}

class _OverheadsState extends State<_Overheads> {
  String _view = 'months', _error = '';
  ({List<Json> months, List<Json> expenses, Map<String, String> machine})? _data;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    final b = session.branchId;
    try {
      final r = await Future.wait<dynamic>([
        db.from('production_overhead_months').select('*').eq('branch_id', b).order('month', ascending: false),
        db.from('production_overhead_expenses').select('*').eq('branch_id', b).order('expense_date', ascending: false).limit(500),
        db.from('machines').select('id, name').eq('branch_id', b),
      ]);
      if (mounted) setState(() => _data = (months: jl(r[0]), expenses: jl(r[1]), machine: {for (final x in jl(r[2])) '${x['id']}': '${x['name']}'}));
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load overheads.");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error.isNotEmpty) return ErrorState(_error, onRetry: _load);
    final d = _data;
    if (d == null) return const Skeleton(rows: 4);
    final thisMonth = '${session.today.substring(0, 8)}01';
    final now = d.months.where((r) => r['month'] == thisMonth).toList();
    final total = now.fold<double>(0, (s, r) => s + n(r['overheads']));
    final branchWide = now.where((r) => r['machine_id'] == null).firstOrNull;
    final unshared = d.months.where((r) => !(n(r['bags']) > 0)).fold<double>(0, (s, r) => s + n(r['overheads']));
    String forOf(Object? id) => id != null ? (d.machine['$id'] ?? '—') : 'the whole branch';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 10),
      Stats([
        Stat('Overheads this month', formatMoneyShort(total, session.currency), help: '${now.fold<num>(0, (s, r) => s + n(r['expenses']))} expenses into products'),
        Stat('A cement bag', branchWide?['per_bag'] != null ? formatMoney(n(branchWide!['per_bag']), session.currency) : '—', help: 'branch-wide, this month'),
        Stat('Not shared', formatMoneyShort(unshared, session.currency), figureColor: unshared > 0 ? C.warning : null, help: 'no batches on that machine or month'),
      ]),
      Row(children: [
        Expanded(child: SlideRow(children: [Chip2('By month', on: _view == 'months', onTap: () => setState(() => _view = 'months')), Chip2('Expenses counted', on: _view == 'expenses', onTap: () => setState(() => _view = 'expenses'))])),
        TextButton(onPressed: () => Shell.of(context).go('/expenses'), child: const Text('Expenses ›')),
      ]),
      const SizedBox(height: 6),
      if (d.months.isEmpty)
        const EmptyState(icon: LucideIcons.wrench, title: 'No production overheads yet', description: 'Tick the expense categories that are production costs under Purchases ⚙, then record those expenses — naming the machine when it is for one.')
      else if (_view == 'months')
        ReportSheet(
          firstWidth: 120,
          head: const ['Month', 'For', 'Expenses', 'Overheads (TZS)', 'Batches', 'Cement bags', 'A bag (TZS)'],
          rows: [
            for (final r in d.months)
              [monthLong('${r['month']}'), forOf(r['machine_id']), '${r['expenses'] ?? ''}', RCell(formatAmount(n(r['overheads'])), bold: true),
                n(r['batches']) != 0 ? '${r['batches']}' : '', n(r['bags']) != 0 ? qtyText(n(r['bags'])) : '', r['per_bag'] != null ? formatAmount(n(r['per_bag'])) : RCell('not shared', warn: true)],
          ],
        )
      else
        ReportSheet(
          firstWidth: 110,
          head: const ['Date', 'Category', 'What', 'For', 'Amount (TZS)'],
          rows: [for (final e in d.expenses) [tableDate(e['expense_date']) ?? '', '${e['category'] ?? ''}', '${e['description'] ?? ''}', forOf(e['machine_id']), formatAmount(n(e['amount']))]],
          total: ['Total', '', '', '', formatMoney(d.expenses.fold<double>(0, (s, e) => s + n(e['amount'])), session.currency)],
        ),
      const SizedBox(height: 6),
      const Tooltip(message: "From Purchases › Expenses (categories ticked as production costs under Purchases ⚙). A month's overheads are shared over that month's batches by cement bags — on the expense's machine when it names one — and go into each product's production cost. Electricity is costed from the meters; labour comes with HR.", child: PlHelp("How it's worked out ⓘ")),
    ]);
  }
}
