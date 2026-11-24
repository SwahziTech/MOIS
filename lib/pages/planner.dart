import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/production.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';

/*
 * Planner — a port of web components/production/CapacityPlanner.jsx: production orders (048) with the capacity
 * simulator (045) that plans them. The simulator turns a target (m² or pieces) into casting days, a ready-by
 * date and the raw materials needed; "Add to order" puts it on a new or open order. Each order shows, per
 * product, planned · cast · curing · passed · rejected, and whether the branch's molds can make its due date.
 * Molds are the only daily limit; a press product's bags a day is a guide only. Online only.
 */
const _statusLabel = {'open': 'Open', 'completed': 'Completed', 'cancelled': 'Cancelled'};
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
double? _num(String s) => s.trim().isEmpty ? null : double.tryParse(s.trim().replaceAll(',', ''));
double _round(double v, [int d = 2]) => (v * math.pow(10, d)).roundToDouble() / math.pow(10, d);
String _addDays(String isoDate, int days) => iso(DateTime.parse(isoDate).add(Duration(days: days)));

class _Line {
  _Line(this.productId, this.colorId, String pieces, this.sqm) : pieces = TextEditingController(text: pieces);
  final String productId, colorId;
  final TextEditingController pieces;
  String sqm;
}

class _Draft {
  String? id;
  Object? orderNo;
  final reference = TextEditingController(), notes = TextEditingController();
  String dueDate = '';
  final List<_Line> lines = [];
}

class Planner extends StatefulWidget {
  const Planner({super.key, required this.refs, required this.recipes, required this.curingDays, this.usage = const {}, this.onOpenForm});
  final Refs refs;
  final List<Json> recipes;
  final int curingDays;
  final Map<String, int> usage;
  final void Function(String productId, String colorId)? onOpenForm;
  @override
  State<Planner> createState() => _PlannerState();
}

class _PlannerState extends State<Planner> {
  Map<String, Json> _capacity = {};
  final Map<String, Json?> _bands = {};
  Map<String, double> _stock = {}, _perSqm = {};
  Map<String, Object?> _wastani = {};
  Map<String, String> _sizes = {};
  List<Json>? _orders; // null = loading
  bool _ordersOff = false;
  Map<String, Json> _progress = {};
  String _show = 'open', _error = '', _note = '';
  _Draft? _draft;
  bool _busy = false;
  // the simulator: one product and a target in _unit ('sqm' | 'pcs')
  String _simProduct = '', _simColour = '', _unit = 'pcs';
  final _target = TextEditingController();

  Refs get refs => widget.refs;
  String get branchId => session.branchId;
  String get today => session.today;
  int get curingDays => widget.curingDays;
  bool get canPlan => session.canAt('production.plan', branchId, null);
  CategoryTools get cats => CategoryTools(refs.categoryRows);

  @override
  void initState() {
    super.initState();
    _target.addListener(() => setState(() {}));
    _loadRefs();
    _loadOrders();
  }

  @override
  void dispose() { _target.dispose(); super.dispose(); }

  Future<void> _loadRefs() async {
    final raw = refs.warehouses.where((w) => w.status == 'active' && w.branchId == branchId && w.type == 'raw_materials').firstOrNull;
    try {
      final r = await Future.wait<dynamic>([
        db.from('branch_product_capacity').select('product_id, molds, bags_per_day_min, bags_per_day_max').eq('branch_id', branchId),
        raw != null ? db.from('stock_balances').select('material_id, quantity').eq('warehouse_id', raw.id).not('material_id', 'is', null) : Future.value(<dynamic>[]),
        db.from('product_specs').select('product_id, spec_id, average_yield_per_bag, pcs_per_sqm'),
        db.from('product_size_specs').select('id, size_cm'),
      ]);
      if (!mounted) return;
      final sizeOf = {for (final x in _l(r[3])) '${x['id']}': '${x['size_cm']}'};
      setState(() {
        _capacity = {for (final x in _l(r[0])) '${x['product_id']}': x};
        _stock = {for (final x in _l(r[1])) '${x['material_id']}': n(x['quantity']).toDouble()};
        _wastani = {for (final x in _l(r[2])) '${x['product_id']}': x['average_yield_per_bag']};
        _perSqm = {for (final x in _l(r[2])) if (n(x['pcs_per_sqm']) > 0) '${x['product_id']}': n(x['pcs_per_sqm']).toDouble()};
        _sizes = {for (final x in _l(r[2])) if (sizeOf[x['spec_id']] != null) '${x['product_id']}': sizeOf[x['spec_id']]!};
      });
    } catch (_) {}
  }

  Future<void> _loadOrders() async {
    try {
      final data = _l(await db.from('production_orders').select('*, lines:production_order_lines(id, product_id, color_id, pieces, sqm, display_order)').eq('branch_id', branchId).order('order_no', ascending: false));
      final ids = data.map((o) => o['id']).toList();
      final g = ids.isEmpty ? <Json>[] : _l(await db.from('production_order_line_progress').select('*').inFilter('order_id', ids));
      if (mounted) setState(() { _orders = data; _ordersOff = false; _progress = {for (final x in g) '${x['line_id']}': x}; });
    } catch (_) {
      if (mounted) setState(() { _orders = []; _ordersOff = true; });
    }
  }

  /// each product's yield band at this branch (the branch's own wastani wins)
  void _band(String id) {
    if (id.isEmpty || _bands.containsKey(id)) return;
    _bands[id] = null;
    db.rpc('product_yield_band', params: {'p_product_id': id, 'p_branch_id': branchId}).then((d) {
      if (mounted) setState(() => _bands[id] = (d as List?)?.isNotEmpty == true ? Map<String, dynamic>.from(d!.first as Map) : null);
    }).catchError((_) {});
  }

  // pieces per m² only for products counted in m² — piece products always in pieces (2026-10-25)
  double? sqmPer(String id) => refs.unit(refs.items['p:$id']?.stockUnitId).toUpperCase() == 'SQM' ? _perSqm[id] : null;
  List<Item> get carried => refs.items.values.where((i) => i.kind == 'product' && i.status == 'active' && (refs.carriedByBranch[branchId]?.contains(i.id) ?? false)).toList()..sort(productOrder(cats));
  String nameOf(Object? productId, Object? colorId) => '${refs.items['p:$productId']?.name ?? '—'}${colorId != null && '$colorId'.isNotEmpty ? ' ${refs.colour('$colorId')}' : ''}';
  Json? recipeFor(Item item, String colorId) {
    final c = widget.recipes.where((r) => r['branch_id'] == branchId && r['category_id'] == item.categoryId && '${r['color_id'] ?? ''}' == colorId).toList()
      ..sort((a, b) {
        int has(Json r) => _l(r['products']).any((x) => x['product_id'] == item.id) ? 1 : 0;
        final c = has(b) - has(a);
        return c != 0 ? c : n(b['version_number']).compareTo(n(a['version_number']));
      });
    return c.firstOrNull;
  }

  // ---- orders
  void _addToOrder(double target, bool inSqm, double typed) {
    setState(() {
      _note = ''; _error = '';
      final d = _draft ??= _Draft();
      final at = d.lines.indexWhere((l) => l.productId == _simProduct && l.colorId == _simColour);
      if (at >= 0) {
        d.lines[at].pieces.text = qtyText((_num(d.lines[at].pieces.text) ?? 0) + target).replaceAll(',', '');
        d.lines[at].sqm = '';
      } else {
        d.lines.add(_Line(_simProduct, _simColour, qtyText(target).replaceAll(',', ''), inSqm ? '$typed' : ''));
      }
      _target.text = '';
    });
  }

  void _editOrder(Json o) {
    setState(() {
      _note = ''; _error = '';
      final d = _Draft()
        ..id = '${o['id']}'
        ..orderNo = o['order_no']
        ..dueDate = '${o['due_date'] ?? ''}';
      d.reference.text = '${o['reference'] ?? ''}';
      d.notes.text = '${o['notes'] ?? ''}';
      for (final l in _l(o['lines'])..sort((a, b) => n(a['display_order']).compareTo(n(b['display_order'])))) {
        d.lines.add(_Line('${l['product_id']}', '${l['color_id'] ?? ''}', qtyText(n(l['pieces'])).replaceAll(',', ''), l['sqm'] != null ? '${l['sqm']}' : ''));
      }
      _draft = d;
    });
  }

  Future<void> _saveOrder() async {
    final d = _draft!;
    setState(() { _error = ''; _note = ''; _busy = true; });
    try {
      await db.rpc('save_production_order', params: {'p': {
        'id': d.id, 'branch_id': branchId, 'reference': d.reference.text, 'due_date': d.dueDate.isEmpty ? null : d.dueDate, 'notes': d.notes.text,
        'lines': [for (final l in d.lines) {'product_id': l.productId, 'color_id': l.colorId.isEmpty ? null : l.colorId, 'pieces': _num(l.pieces.text), 'sqm': _num(l.sqm)}],
      }});
      _note = d.id != null ? 'Order ${d.orderNo} saved.' : 'Order saved.';
      _draft = null;
      _loadOrders();
    } catch (e) {
      _error = dbError(e, "We couldn't save the order. Please try again.");
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _setStatus(Json o, String status) async {
    setState(() { _error = ''; _note = ''; });
    String? why = '';
    if (status == 'cancelled') {
      final c = TextEditingController();
      why = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
            title: Text('Cancel order ${o['order_no']}?'),
            content: TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'Say why (optional)')),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back')), FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Cancel order'))],
          ));
      if (why == null) return;
    }
    try {
      await db.rpc('set_production_order_status', params: {'p_order': o['id'], 'p_status': status, 'p_note': why.isEmpty ? null : why});
      _loadOrders();
    } catch (e) {
      if (mounted) setState(() => _error = dbError(e));
    }
  }

  /// how an order stands: per line what is left to cast, and whether the molds can make the due date
  ({List<Json> lines, String? lastReady, bool unknown, bool anyLeft, bool late}) standing(Json o) {
    String? lastReady;
    var unknown = false, anyLeft = false;
    final lines = [
      for (final l in _l(o['lines'])..sort((a, b) => n(a['display_order']).compareTo(n(b['display_order']))))
        () {
          final g = _progress['${l['id']}'] ?? const {'cast_pieces': 0, 'curing': 0, 'passed': 0, 'rejected': 0};
          final planned = n(l['pieces']).toDouble(), passed = n(g['passed']).toDouble(), curing = n(g['curing']).toDouble();
          final toCast = math.max(0.0, planned - passed - curing);
          final molds = _capacity['${l['product_id']}']?['molds'];
          if (toCast > 0) {
            anyLeft = true;
            if (molds != null && n(molds) > 0) {
              final r = _addDays(today, (toCast / n(molds)).ceil() - 1 + curingDays);
              if (lastReady == null || r.compareTo(lastReady!) > 0) lastReady = r;
            } else {
              unknown = true;
            }
          }
          return {...l, 'cast_pieces': g['cast_pieces'], 'curing': curing, 'passed': passed, 'rejected': g['rejected'], 'toCast': toCast,
            'pct': planned > 0 ? math.min(100.0, passed / planned * 100) : 0.0, 'curingPct': planned > 0 ? math.min(100.0, (passed + curing) / planned * 100) : 0.0};
        }(),
    ];
    final late = o['status'] == 'open' && o['due_date'] != null && lastReady != null && lastReady!.compareTo('${o['due_date']}') > 0;
    return (lines: lines, lastReady: lastReady, unknown: unknown, anyLeft: anyLeft, late: late);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    _band(_simProduct);
    for (final l in _draft?.lines ?? const <_Line>[]) { _band(l.productId); }

    // ---- simulator: target pieces → casting days, curing, materials
    final simItem = refs.items['p:$_simProduct'];
    final simW = _simProduct.isNotEmpty && _bands[_simProduct]?['average_yield_per_bag'] != null ? n(_bands[_simProduct]!['average_yield_per_bag']).toDouble() : null;
    final simCap = _capacity[_simProduct];
    final simPerSqm = sqmPer(_simProduct);
    final inSqm = _unit == 'sqm' && (simPerSqm ?? 0) > 0;
    final typed = _num(_target.text) ?? 0;
    final target = inSqm ? (typed * simPerSqm! - 1e-9).ceilToDouble() : typed;
    final simBags = simW != null && simW > 0 ? target / simW : null;
    final perDayMax = simCap?['molds'] != null && n(simCap!['molds']) > 0 ? n(simCap['molds']).toDouble() : null;
    final days = perDayMax != null ? (target / perDayMax).ceil() : null;
    final readyBy = days != null && days > 0 ? _addDays(today, days - 1 + curingDays) : null;
    final simRecipe = simItem != null && (simItem.colorIds.isEmpty || _simColour.isNotEmpty) ? recipeFor(simItem, _simColour) : null;
    final simMaterials = simRecipe == null || simBags == null
        ? <({Item? item, double qty, String unit, bool short, double shortBy})>[]
        : ([
            for (final it in _l(simRecipe['items']).where((it) => refs.items['m:${it['material_id']}']?.inRecipes != false))
              () {
                final qty = n(it['quantity']) * simBags;
                final f = stockFactorOf(refs, it['material_id'], it['unit_id']);
                final have = f != null && f > 0 ? (_stock['${it['material_id']}'] ?? 0) / f : null;
                return (item: refs.items['m:${it['material_id']}'], qty: qty, unit: refs.unit('${it['unit_id']}'), short: have != null && qty > have + 1e-9, shortBy: have != null ? qty - have : 0.0);
              }(),
          ]..sort((a, b) => a.item == null || b.item == null ? 0 : byMaterialOrder(a.item!, b.item!)));
    final lo = simCap?['bags_per_day_min'] ?? simCap?['bags_per_day_max'], hi = simCap?['bags_per_day_max'] ?? simCap?['bags_per_day_min'];
    final size = simItem?.size ?? _sizes[_simProduct];
    final capLine = perDayMax != null
        ? '${qtyText(perDayMax)} molds${size != null ? ' ($size)' : ''} — ${qtyText(perDayMax)} pcs a day'
        : lo != null ? 'About ${qtyText(n(lo))}–${qtyText(n(hi))} bags a day — a guide, not a limit' : null;
    final simReady = simItem != null && target > 0 && (simItem.colorIds.isEmpty || _simColour.isNotEmpty);

    final orders = _orders;
    final shownOrders = (orders ?? []).where((o) => o['status'] == _show).toList();
    final counts = <String, int>{};
    for (final o in orders ?? <Json>[]) { counts['${o['status']}'] = (counts['${o['status']}'] ?? 0) + 1; }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // ---- orders ----
      CardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(LucideIcons.clipboardList, size: 15),
            const SizedBox(width: 6),
            const Expanded(child: Text('Production orders', style: TextStyle(fontWeight: FontWeight.w700))),
            if (canPlan && !_ordersOff && _draft == null)
              FilledButton.icon(onPressed: () => setState(() { _note = ''; _error = ''; _draft = _Draft(); }), icon: const Icon(LucideIcons.plus, size: 14), label: const Text('New order')),
          ]),
          const SizedBox(height: 8),
          SlideRow(children: [for (final s in _statusLabel.keys) Chip2('${_statusLabel[s]}${counts[s] != null ? ' (${counts[s]})' : ''}', on: _show == s, onTap: () => setState(() => _show = s))]),
          const SizedBox(height: 8),
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
          if (_note.isNotEmpty) PlHelp(_note, color: C.success),
          if (orders == null)
            const Skeleton(rows: 2)
          else if (_ordersOff)
            const PlHelp("Production orders aren't switched on yet.")
          else if (shownOrders.isEmpty)
            PlHelp(_show == 'open' ? (canPlan ? 'No open orders — plan one with the simulator below, then "Add to order".' : 'No open orders.') : 'No ${_statusLabel[_show]!.toLowerCase()} orders.')
          else
            for (final o in shownOrders) _order(o, standing(o), t),
        ]),
      ),

      // ---- the order being written ----
      if (_draft != null) _draftCard(_draft!),

      // ---- simulator ----
      CardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(LucideIcons.gauge, size: 20, color: C.khakiDark),
            const SizedBox(width: 8),
            const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Production capacity & mix simulator', style: TextStyle(fontWeight: FontWeight.w700)),
              PlHelp('Order size → casting days, curing and raw materials needed.'),
            ])),
          ]),
          const SizedBox(height: 10),
          const PlHelp('1. Finished product'),
          OutlinedButton(
            onPressed: () async {
              final id = await pickProduct(context, title: 'Select finished product', items: [for (final i in carried) i], cats: cats, usage: widget.usage, wastani: _wastani, capacity: _capacity);
              if (id != null) setState(() { _simProduct = id; _simColour = ''; _target.text = ''; _unit = (sqmPer(id) ?? 0) > 0 ? 'sqm' : 'pcs'; });
            },
            child: Align(alignment: Alignment.centerLeft, child: Text(
                simItem == null ? 'Choose product…' : '${simItem.name}  (${simItem.category ?? ''}${perDayMax != null ? ' · ${qtyText(perDayMax)} molds' : ''})',
                overflow: TextOverflow.ellipsis)),
          ),
          if (simItem != null && simItem.colorIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            SlideRow(children: [for (final c in simItem.colorIds) Chip2(refs.colour(c), on: _simColour == c, onTap: () => setState(() => _simColour = c))]),
          ],
          const SizedBox(height: 10),
          const PlHelp('2. Target output'),
          Row(children: [
            Expanded(child: TextField(controller: _target, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(hintText: '0'))),
            const SizedBox(width: 8),
            if ((simPerSqm ?? 0) > 0)
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'sqm', label: Text('m²')), ButtonSegment(value: 'pcs', label: Text('pcs'))],
                selected: {inSqm ? 'sqm' : 'pcs'}, showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() {
                  final v = _num(_target.text);
                  _unit = s.first;
                  // keep the same amount: m² ↔ pieces at the product's pieces per m²
                  if (v != null) _target.text = _unit == 'sqm' ? '${_round(v / simPerSqm!)}' : '${(v * simPerSqm! - 1e-9).ceil()}';
                }),
              )
            else
              const Text('pcs'),
          ]),
          if ((simPerSqm ?? 0) > 0 && typed > 0) PlHelp('${inSqm ? '= ${qtyText(target)} pcs' : '= ${qtyText(_round(typed / simPerSqm!))} m²'} · ${qtyText(simPerSqm!)} pcs/m²'),
          const SizedBox(height: 8),
          SlideRow(children: [
            for (final v in inSqm ? const [10, 25, 50, 100] : const [100, 200, 500, 1000]) Chip2('${qtyText(v)} ${inSqm ? 'm²' : 'pcs'}', on: typed == v, onTap: () => setState(() => _target.text = '$v')),
            if (perDayMax != null) Chip2('One day max (${qtyText(perDayMax)} pcs)', on: !inSqm && typed == perDayMax, onTap: () => setState(() { _unit = 'pcs'; _target.text = qtyText(perDayMax).replaceAll(',', ''); })),
          ]),
          if (simItem != null) ...[
            const Divider(height: 22),
            Row(children: [
              Expanded(child: Text.rich(TextSpan(children: [TextSpan(text: 'Capacity: ', style: TextStyle(color: t.textSecondary)), TextSpan(text: capLine ?? 'No daily limit', style: const TextStyle(fontWeight: FontWeight.w700))]))),
              if (days != null && target > 0) Badge2('$days casting day${days == 1 ? '' : 's'}'),
            ]),
            if (target > 0 && perDayMax != null && target > perDayMax)
              Alert("${qtyText(target)} pcs is more than one day's capacity (${qtyText(perDayMax)} pcs) — $days days of casting.", tone: Tone.warning),
            if (target > 0) PlHelp(readyBy != null ? 'Ready to sell about ${dateText(readyBy)} (casting + $curingDays days curing).' : 'Ready to sell $curingDays days after casting.'),
            if (simW == null && _bands.containsKey(_simProduct) && _bands[_simProduct] == null) PlHelp('No wastani for ${simItem.name} — set it to work out cement and materials.', color: C.warning),
            if (simItem.colorIds.isNotEmpty && _simColour.isEmpty) const PlHelp('Choose the colour to see its materials.'),
            if (target > 0 && simMaterials.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Raw materials for ${qtyText(target)} pcs${inSqm ? ' (${qtyText(typed)} m²)' : ''}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.sm)),
              const SizedBox(height: 6),
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final m in simMaterials)
                  Container(
                    width: 150,
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: m.short ? C.error : t.border), color: m.short ? C.error.withValues(alpha: .06) : null),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(m.item?.name ?? '—', style: TextStyle(fontSize: Fs.xs, color: t.textSecondary), overflow: TextOverflow.ellipsis),
                      Text.rich(TextSpan(children: [TextSpan(text: qtyText(_round(m.qty)), style: const TextStyle(fontWeight: FontWeight.w700)), TextSpan(text: ' ${m.unit}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted))])),
                      if (m.short) Text('Short ${qtyText(_round(m.shortBy))} ${m.unit}', style: const TextStyle(fontSize: Fs.xs, color: C.error)),
                    ]),
                  ),
              ]),
              if (simW != null && simW > 0) PlHelp('Cement: ${qtyText(target)} pcs ÷ ${qtyText(simW)} pcs/bag = ${qtyText(_round(simBags!))} bags'),
            ],
            const SizedBox(height: 10),
            if (canPlan && !_ordersOff)
              FilledButton.icon(
                onPressed: simReady ? () => _addToOrder(target, inSqm, typed) : null,
                icon: const Icon(LucideIcons.plus, size: 15),
                label: Text(_draft != null ? 'Add to ${_draft!.id != null ? 'order ${_draft!.orderNo}' : 'the new order'}' : 'Add to a new order'),
              ),
            if (widget.onOpenForm != null) ...[
              const SizedBox(height: 6),
              OutlinedButton.icon(
                onPressed: () => widget.onOpenForm!(_simProduct, _simColour),
                icon: const Icon(LucideIcons.factory, size: 15),
                label: Text('Open production form for ${simItem.name}${_simColour.isNotEmpty ? ' ${refs.colour(_simColour)}' : ''}', overflow: TextOverflow.ellipsis),
              ),
            ],
          ],
        ]),
      ),
    ]);
  }

  Widget _order(Json o, ({List<Json> lines, String? lastReady, bool unknown, bool anyLeft, bool late}) st, Tokens t) {
    final open = o['status'] == 'open';
    final badge = !open
        ? Badge2('${_statusLabel[o['status']]}${o['close_note'] != null ? ' — ${o['close_note']}' : ''}')
        : st.late
            ? Badge2('At risk — ready about ${dateText(st.lastReady)}', tone: Tone.error)
            : st.anyLeft && st.lastReady != null && !st.unknown
                ? Badge2('On track — ready about ${dateText(st.lastReady)}', tone: Tone.success)
                : !st.anyLeft
                    ? const Badge2('All cast — waiting for quality release')
                    : null;
    Widget fig(String label, Object? v, {bool bold = false}) => Expanded(child: Column(children: [
          Text(label, style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
          Text(v is num && v != 0 ? qtyText(v) : (v is num ? (label == 'Rejected' || label == 'To cast' ? '—' : '0') : '$v'), style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w500, fontSize: Fs.sm)),
        ]));
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: t.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Text.rich(TextSpan(children: [
            TextSpan(text: 'Order ${o['order_no']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            if (o['reference'] != null && '${o['reference']}'.isNotEmpty) TextSpan(text: '  ${o['reference']}'),
          ]))),
          if (canPlan)
            PopupMenuButton<String>(
              icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
              onSelected: (v) => v == 'edit' ? _editOrder(o) : _setStatus(o, v),
              itemBuilder: (_) => [
                if (open) const PopupMenuItem(value: 'edit', child: Text('Edit')),
                if (open) const PopupMenuItem(value: 'completed', child: Text('Mark done')),
                if (open) const PopupMenuItem(value: 'cancelled', child: Text('Cancel')),
                if (!open) const PopupMenuItem(value: 'open', child: Text('Reopen')),
              ],
            ),
        ]),
        if (o['due_date'] != null) PlHelp('due ${dateText(o['due_date'])}'),
        if (badge != null) Padding(padding: const EdgeInsets.only(top: 4), child: Align(alignment: Alignment.centerLeft, child: badge)),
        for (final l in st.lines) ...[
          const Divider(height: 18),
          Row(children: [
            Expanded(child: Text(nameOf(l['product_id'], l['color_id']), style: const TextStyle(fontWeight: FontWeight.w600))),
            if (open && n(l['toCast']) > 0)
              TextButton(
                onPressed: () => setState(() { _simProduct = '${l['product_id']}'; _simColour = '${l['color_id'] ?? ''}'; _unit = 'pcs'; _target.text = qtyText(n(l['toCast'])).replaceAll(',', ''); }),
                child: const Text('Plan rest'),
              ),
          ]),
          // passed (solid) over passed + curing (light)
          Tooltip(
            message: '${n(l['pct']).round()}% passed',
            child: ClipRRect(borderRadius: BorderRadius.circular(3), child: SizedBox(height: 6, child: Stack(children: [
              Container(color: t.soft),
              FractionallySizedBox(widthFactor: n(l['curingPct']) / 100, child: Container(color: C.success.withValues(alpha: .35))),
              FractionallySizedBox(widthFactor: n(l['pct']) / 100, child: Container(color: C.success)),
            ]))),
          ),
          const SizedBox(height: 6),
          Row(children: [
            fig('Planned', l['sqm'] != null ? '${qtyText(n(l['pieces']))}\n${qtyText(n(l['sqm']))} m²' : n(l['pieces'])),
            fig('Cast', n(l['cast_pieces'])), fig('Curing', n(l['curing'])), fig('Passed', n(l['passed']), bold: true),
            fig('Rejected', n(l['rejected'])), fig('To cast', n(l['toCast']), bold: true),
          ]),
        ],
        if (o['notes'] != null && '${o['notes']}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: PlHelp('${o['notes']}')),
      ]),
    );
  }

  Widget _draftCard(_Draft d) => CardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(d.id != null ? 'Edit order ${d.orderNo}' : 'New order', style: const TextStyle(fontWeight: FontWeight.w700)),
          const PlHelp('Add products with the simulator below.'),
          const SizedBox(height: 8),
          TextField(controller: d.reference, decoration: const InputDecoration(labelText: 'Customer / reference', hintText: 'e.g. Mr Juma — house in Area D')),
          const SizedBox(height: 8),
          InkWell(
            onTap: () async {
              final p = await showDatePicker(context: context, firstDate: DateTime.parse(today), lastDate: DateTime.parse(today).add(const Duration(days: 730)),
                  initialDate: d.dueDate.isNotEmpty && d.dueDate.compareTo(today) >= 0 ? DateTime.parse(d.dueDate) : DateTime.parse(today));
              if (p != null) setState(() => d.dueDate = iso(p));
            },
            child: InputDecorator(decoration: const InputDecoration(labelText: 'Due date'), child: Text(d.dueDate.isEmpty ? '—' : dateText(d.dueDate) ?? '')),
          ),
          const SizedBox(height: 8),
          if (d.lines.isEmpty)
            const PlHelp('No products yet.')
          else
            for (final (i, l) in d.lines.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(children: [
                  Expanded(flex: 3, child: Text(nameOf(l.productId, l.colorId), style: const TextStyle(fontWeight: FontWeight.w600))),
                  SizedBox(width: 90, child: TextField(controller: l.pieces, onChanged: (_) => setState(() => l.sqm = ''), keyboardType: TextInputType.number, decoration: const InputDecoration(isDense: true))),
                  const SizedBox(width: 6),
                  Expanded(flex: 2, child: PlHelp('pcs${(sqmPer(l.productId) ?? 0) > 0 && (_num(l.pieces.text) ?? 0) > 0 ? ' · ${qtyText(_round(_num(l.pieces.text)! / sqmPer(l.productId)!))} m²' : ''}')),
                  IconButton(tooltip: 'Remove', icon: const Icon(LucideIcons.trash2, size: 16), onPressed: () => setState(() => d.lines.removeAt(i))),
                ]),
              ),
          TextField(controller: d.notes, minLines: 2, maxLines: 4, decoration: const InputDecoration(hintText: 'Notes (optional)')),
          const SizedBox(height: 10),
          Row(children: [
            FilledButton(onPressed: _busy || d.lines.isEmpty ? null : _saveOrder, child: Text(_busy ? 'Saving…' : d.id != null ? 'Save changes' : 'Save order')),
            const SizedBox(width: 8),
            TextButton(onPressed: () => setState(() { _draft = null; _error = ''; }), child: const Text('Cancel')),
          ]),
        ]),
      );
}
