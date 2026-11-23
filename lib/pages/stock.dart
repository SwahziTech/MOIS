import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../shell.dart';
import 'stock_history.dart';
import 'stock_movement.dart';

/*
 * Stock — a port of web/src/pages/Stock.jsx. Stock on hand = the sum of the inventory ledger
 * (stock_balances, 022); nothing here edits a number, every change is a posted movement.
 * Raw materials / Finished goods, one card an item with its total and, for coloured products,
 * a box a colour; m² products show pieces too. Curing stock apart (not sellable until its
 * quality release); sold-but-not-collected shown under the total. Stock as of a date.
 */
const _actions = ['receipt', 'issue', 'transfer', 'adjustment', 'count', 'opening_balance'];
const _sortLabel = {
  'size': 'Structural size (smallest → largest)', 'name': 'Name (A → Z)', 'qty_desc': 'Quantity (highest → lowest)',
  'qty_asc': 'Quantity (lowest → highest)', 'recent': 'Last movement (newest first)',
};
double _round(double v, [int d = 2]) { var p = 1.0; for (var i = 0; i < d; i++) { p *= 10; } return (v * p).round() / p; }

class StockPage extends StatefulWidget {
  const StockPage({super.key});
  @override
  State<StockPage> createState() => _StockPageState();
}

class _Card {
  _Card(this.item, this.unitId);
  final Item item;
  final String? unitId;
  double total = 0, curing = 0, rejects = 0;
  final Map<String, double> byColour = {};
  String? last;
}

class _StockPageState extends State<StockPage> {
  String _asOf = '';
  Refs? _refs;
  List<Json> _balances = [];
  Map<String, double> _perSqm = {};
  Map<String, Map<String, double>> _reorder = {};
  Map<String, double> _toCollect = {};
  DateTime? _savedAt;
  bool _loading = true;
  String _error = '';
  String _q = '';
  String _view = 'products';
  String _warehouseId = '';
  bool _showZero = false;
  String _chip = '';
  String _sortBy = 'size';

  String get today => session.today;
  String get branchId => session.branchId;
  bool get isProducts => _view == 'products';

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load([String? date]) async {
    final d = date ?? _asOf;
    setState(() => _error = '');
    try {
      final r = await Refs.load();
      final (data, at) = await offline.load<Json>('stock:$d', () async {
        final res = await Future.wait<dynamic>([
          d.isNotEmpty && d.compareTo(today) < 0
              ? db.rpc('stock_balances_as_of', params: {'p_date': d})
              : db.from('stock_balances').select('warehouse_id, material_id, product_id, color_id, stock_unit_id, quantity, last_movement_date'),
          db.from('product_specs').select('product_id, pcs_per_sqm'),
          db.from('branch_products').select('branch_id, product_id, reorder_level').not('reorder_level', 'is', null).then<List>((v) => v).catchError((_) => <dynamic>[]),
        ]);
        return {'bal': res[0], 'ps': res[1], 'rl': res[2]};
      });
      _refs = r;
      _savedAt = at;
      _balances = [for (final x in (data['bal'] as List? ?? [])) Map<String, dynamic>.from(x)];
      _perSqm = {for (final x in (data['ps'] as List? ?? [])) if (n(x['pcs_per_sqm']) > 0) x['product_id'] as String: n(x['pcs_per_sqm'])};
      final m = <String, Map<String, double>>{};
      for (final x in (data['rl'] as List? ?? [])) {
        m.putIfAbsent(x['branch_id'], () => {})[x['product_id']] = n(x['reorder_level']);
      }
      _reorder = m;
      _loadToCollect();
    } catch (e) {
      _error = "We couldn't load stock. Please try again.";
    }
    if (mounted) setState(() => _loading = false);
  }

  /// sold but not yet collected — the stock stays until the goods leave (sales_availability.reserved)
  Future<void> _loadToCollect() async {
    final ids = branchId.isNotEmpty ? [branchId] : session.branches.map((b) => b.id).toList();
    try {
      final (data, _) = await offline.load<List>('toCollect:$branchId:$_warehouseId', () async {
        final res = await Future.wait([for (final id in ids) db.rpc('sales_availability', params: {'p_branch_id': id, if (_warehouseId.isNotEmpty) 'p_warehouse_id': _warehouseId})]);
        return [for (final r in res) ...(r as List)];
      });
      final m = <String, double>{};
      for (final x in data) {
        final k = '${x['product_id']}|${x['color_id'] ?? ''}';
        final v = n(x['reserved']);
        m[k] = (m[k] ?? 0) + (v > 0 ? v : 0);
      }
      if (mounted) setState(() => _toCollect = m);
    } catch (_) {}
  }

  List<Store> get _activeWarehouses => _refs!.warehouses.where((w) => w.status == 'active').toList();
  List<String> get _allowedActions => _actions.where((t) => _activeWarehouses.any((w) => session.canAt(movementTypes[t]!.perm, w.branchId, w.id))).toList();
  List<Store> get _stores => _activeWarehouses.where((w) => (branchId.isEmpty || w.branchId == branchId) && w.type != 'wip' &&
      (isProducts ? w.type != 'raw_materials' : (w.type == 'raw_materials' || w.type == 'general'))).toList();

  List<_Card> _cards() {
    final r = _refs!;
    final whById = {for (final w in r.warehouses) w.id: w};
    final m = <String, _Card>{};
    for (final b in _balances) {
      final key = b['material_id'] != null ? 'm:${b['material_id']}' : 'p:${b['product_id']}';
      final item = r.items[key];
      final wh = whById[b['warehouse_id']];
      if (item == null || wh == null || item.isProduct != isProducts) continue;
      if (branchId.isNotEmpty && wh.branchId != branchId) continue;
      final picked = whById[_warehouseId];
      if (_warehouseId.isNotEmpty && b['warehouse_id'] != _warehouseId && !(wh.type == 'wip' && picked?.type == 'finished_goods' && picked?.branchId == wh.branchId)) continue;
      final c = m.putIfAbsent(item.key, () => _Card(item, b['stock_unit_id']));
      final q = n(b['quantity']);
      if (wh.type == 'wip') {
        c.curing += q;
      } else if (wh.type == 'rejects' && _warehouseId != wh.id) {
        c.rejects += q;
      } else {
        c.total += q;
        if (b['color_id'] != null) c.byColour[b['color_id']] = (c.byColour[b['color_id']] ?? 0) + q;
      }
      final d = '${b['last_movement_date'] ?? ''}';
      if (c.last == null || d.compareTo(c.last!) > 0) c.last = d;
    }
    if (_showZero && isProducts) {
      for (final i in r.items.values) {
        if (!i.isProduct || i.status != 'active' || m.containsKey(i.key)) continue;
        if (branchId.isNotEmpty && !(r.carriedByBranch[branchId]?.contains(i.id) ?? false)) continue;
        m[i.key] = _Card(i, i.stockUnitId);
      }
    }
    if (!isProducts) {
      for (final i in r.items.values) {
        if (i.isProduct || i.status != 'active' || m.containsKey(i.key)) continue;
        if (branchId.isNotEmpty && i.branchId != null && i.branchId != branchId) continue;
        m[i.key] = _Card(i, i.stockUnitId);
      }
    }
    return m.values.toList();
  }

  String _unit(String? id) => _refs!.unit(id);
  bool _isSqm(_Card c) => RegExp(r'^(sqm|m²)$', caseSensitive: false).hasMatch(_unit(c.unitId));
  double? _pcsOf(_Card c, double q) => _isSqm(c) && _perSqm[c.item.id] != null ? (q * _perSqm[c.item.id]!).roundToDouble() : null;
  String? _altOf(_Card c, double q) {
    final u = c.item.units.where((x) => x.id != c.unitId && x.factor > 0 && x.factor != 1).firstOrNull;
    return u == null ? null : '${qtyText(_round(q / u.factor))} ${_unit(u.id)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.all(14), child: Skeleton());
    if (_error.isNotEmpty) return ErrorState(_error, onRetry: _load);
    final r = _refs!;
    final t = context.tk;
    final cats = CategoryTools(r.categoryRows);
    final order = productOrder(cats);
    final cards = _cards();
    final materialChips = <String, ChipItem>{};
    for (final c in [...cards]..sort((a, b) => a.item.rank.compareTo(b.item.rank))) {
      final mc = c.item.materialCategory;
      if (mc != null) materialChips[mc] = ChipItem(mc, mc);
    }
    bool inChip(Item i) => _chip.isEmpty || (isProducts ? (i.categoryId == _chip || cats.byId[i.categoryId]?['parent_category_id'] == _chip) : i.materialCategory == _chip);
    final q = _q.trim().toLowerCase();
    int byName(_Card a, _Card b) => naturalCompare(a.item.name, b.item.name);
    final shown = cards.where((c) => (_showZero || (!isProducts && _chip.isNotEmpty) || c.total != 0 || c.curing != 0) && inChip(c.item) &&
        (q.isEmpty || '${c.item.name} ${c.item.category ?? c.item.materialCategory ?? ''}'.toLowerCase().contains(q))).toList()
      ..sort((a, b) => switch (_sortBy) {
            'qty_desc' => b.total.compareTo(a.total) != 0 ? b.total.compareTo(a.total) : byName(a, b),
            'qty_asc' => a.total.compareTo(b.total) != 0 ? a.total.compareTo(b.total) : byName(a, b),
            'recent' => (b.last ?? '').compareTo(a.last ?? '') != 0 ? (b.last ?? '').compareTo(a.last ?? '') : byName(a, b),
            'name' => byName(a, b),
            _ => isProducts ? order(a.item, b.item) : (a.item.rank != b.item.rank ? a.item.rank.compareTo(b.item.rank) : byName(a, b)),
          });
    final allowed = _allowedActions;
    final stores = _stores;
    final chipItems = isProducts
        ? [for (final c in categoryChipItems(cats, (c) => c['status'] == 'active')) ChipItem(c.id, c.label, c.children?.map((k) => ChipItem(k.id, k.label)).toList())]
        : materialChips.values.toList();
    return RefreshIndicator(
      onRefresh: () async { await Refs.load(fresh: true); await _load(); },
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        OfflineNote(_savedAt),
        // Stock as of
        Row(children: [
          Text('Stock as of', style: TextStyle(fontSize: Fs.sm, color: t.textSecondary)),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: () async {
              final d = await showDatePicker(context: context, initialDate: DateTime.parse(_asOf.isEmpty ? today : _asOf), firstDate: DateTime(2024), lastDate: DateTime.parse(today));
              if (d == null) return;
              final v = iso(d) == today ? '' : iso(d);
              setState(() { _asOf = v; _loading = true; });
              _load(v);
            },
            icon: const Icon(LucideIcons.calendar, size: 15),
            label: Text(tableDate(_asOf.isEmpty ? today : _asOf)!),
          ),
        ]),
        const SizedBox(height: 12),
        // .sk-tabs
        Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            for (final (k, label, icon) in const [('materials', 'Raw materials', LucideIcons.layers), ('products', 'Finished goods', LucideIcons.package)])
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  child: Material(
                    color: _view == k ? C.khaki : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => setState(() { _view = k; _chip = ''; _warehouseId = ''; }),
                      child: SizedBox(height: 40, child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                        Icon(icon, size: 16, color: _view == k ? const Color(0xFF1E1C19) : t.textSecondary),
                        const SizedBox(width: 8),
                        Text(label, style: TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.md, color: _view == k ? const Color(0xFF1E1C19) : t.textSecondary)),
                      ])),
                    ),
                  ),
                ),
              ),
          ]),
        ),
        const SizedBox(height: 12),
        ListToolbar(
          placeholder: isProducts ? 'Search product (e.g. Chuchu, Buibui, 600R)…' : 'Search material (e.g. Huaxin, Rangi)…',
          onSearch: (v) => setState(() => _q = v),
          sort: SortSpec(value: _sortBy, onChange: (v) => setState(() => _sortBy = v),
              options: [for (final e in _sortLabel.entries) (e.key, isProducts || e.key != 'size' ? e.value : 'Material order (cement → steel)')]),
          filters: [
            FilterSpec(key: 'store', label: 'Store', value: _warehouseId, onChange: (v) { setState(() => _warehouseId = v); _loadToCollect(); },
                options: [('', 'All stores'), for (final w in stores) (w.id, warehouseLabel(w))]),
            FilterSpec(key: 'zero', label: 'Zero stock', value: _showZero ? 'show' : '', onChange: (v) => setState(() => _showZero = v == 'show'),
                options: const [('', 'Hide'), ('show', 'Show')]),
          ],
          trailing: [
            if (allowed.isNotEmpty)
              PopupMenuButton<String>(
                tooltip: 'Stock actions',
                onSelected: (k) => _post(k),
                itemBuilder: (_) => [for (final k in allowed) PopupMenuItem(value: k, child: Text(movementTypes[k]!.label))],
                child: Container(
                  height: 40, padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(color: t.dark ? C.khaki : C.charcoal, borderRadius: BorderRadius.circular(6)),
                  child: Row(children: [
                    Icon(LucideIcons.plus, size: 15, color: t.dark ? C.charcoal : Colors.white),
                    Icon(LucideIcons.chevronDown, size: 14, color: t.dark ? C.charcoal : Colors.white),
                  ]),
                ),
              ),
          ],
        ),
        ChipRow(items: chipItems, value: _chip, onChange: (v) => setState(() => _chip = v)),
        const SizedBox(height: 10),
        // .sk-head
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 8, children: [
            Text('${isProducts ? 'Finished goods' : 'Raw materials'} (${shown.length})', style: TextStyle(fontWeight: FontWeight.w600, color: t.textSecondary)),
            PlHelp(isProducts || _sortBy != 'size' ? _sortLabel[_sortBy]! : 'Material order (cement → steel)'),
          ]),
        ),
        if (shown.isEmpty)
          CardBox(child: EmptyState(icon: LucideIcons.boxes,
              title: _balances.isNotEmpty ? 'Nothing in this view' : 'No stock recorded yet',
              description: _balances.isNotEmpty ? 'Change the search, chips or filters to see more.' : 'Start by posting opening balances for what is on hand, then receive and issue as stock moves.'))
        else
          for (final c in shown) _card(context, c, allowed),
        if (shown.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: PlHelp('${_asOf.isNotEmpty ? 'Stock at the end of ${dateText(_asOf)}, from movements dated up to then. ' : ''}Calculated from posted movements — see Movements for the full history.'),
          ),
      ]),
    );
  }

  Widget _card(BuildContext context, _Card c, List<String> allowed) {
    final r = _refs!;
    final t = context.tk;
    final colours = c.item.colorIds;
    final pcs = _pcsOf(c, c.total);
    final level = branchId.isNotEmpty ? (_reorder[branchId]?[c.item.id]) : null;
    final mu = !isProducts ? mainUnitOf(c.item) : null;
    // to collect: sold, not yet collected
    final double toCollect;
    if (c.item.isProduct && c.byColour.isEmpty) {
      toCollect = _toCollect['${c.item.id}|'] ?? 0;
    } else {
      final byCol = c.byColour.keys.fold<double>(0, (s, col) => s + (_toCollect['${c.item.id}|$col'] ?? 0));
      toCollect = byCol > 0 ? byCol : (_toCollect['${c.item.id}|'] ?? 0);
    }
    Widget tag(String s) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(color: t.soft, borderRadius: BorderRadius.circular(4)),
          child: Text(s, style: TextStyle(fontSize: Fs.xs, color: t.textSecondary)),
        );
    Widget out(String s) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(border: Border.all(color: C.error), borderRadius: BorderRadius.circular(4)),
          child: Text(s, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.4, color: C.error)),
        );
    final name = Text(c.item.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: Fs.lg, fontWeight: FontWeight.w700));
    final tags = Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      tag(isProducts ? (c.item.category ?? '') : (c.item.materialCategory ?? 'Material')),
      if (c.total <= 0 && c.curing <= 0) out('OUT'),
      if (c.total > 0 && level != null && c.total < level) out('LOW'),
      if (c.total < 0) out('BELOW ZERO'),
    ]);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(10)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _history(c.item),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              // LOCKED: products name above category; materials category above name
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: isProducts ? [name, const SizedBox(height: 4), tags] : [tags, const SizedBox(height: 4), name])),
              const SizedBox(width: 10),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                if (mu != null) ...[
                  _fig(context, qtyText(_round(c.total / mu.factor)), _unit(mu.id), c.total < 0),
                  Text('(${qtyText(_round(c.total))} ${_unit(c.unitId)})', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                ] else ...[
                  _fig(context, qtyText(_round(c.total)), _unit(c.unitId), c.total < 0),
                  if (pcs != null) Text('(${qtyText(pcs)} pcs)', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                  if (!isProducts && _altOf(c, c.total) != null) Text('(${_altOf(c, c.total)})', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                ],
                if (toCollect > 0)
                  Text('${qtyText(_round(toCollect))} ${_unit(c.unitId)}${_pcsOf(c, toCollect) != null ? ' (${qtyText(_pcsOf(c, toCollect))} pcs)' : ''} to collect',
                      style: TextStyle(fontSize: Fs.xs, color: t.dark ? C.khakiLight : C.coffee)),
                if (c.curing > 0)
                  Text('+ ${qtyText(_round(c.curing))} ${_unit(c.unitId)}${_pcsOf(c, c.curing) != null ? ' (${qtyText(_pcsOf(c, c.curing))} pcs)' : ''} curing',
                      style: TextStyle(fontSize: Fs.xs, color: t.dark ? C.khakiLight : C.coffee)),
              ]),
            ]),
            // .sk-colours
            if (colours.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final id in colours)
                  Opacity(
                    opacity: (c.byColour[id] ?? 0) != 0 ? 1 : 0.55,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 78),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(color: t.soft, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(6)),
                      child: Column(children: [
                        Row(mainAxisSize: MainAxisSize.min, children: [
                          Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle, color: _cssColour(r.colour(id)), border: Border.all(color: t.borderStrong))),
                          const SizedBox(width: 5),
                          Text(r.colour(id), style: TextStyle(fontSize: Fs.xs, fontWeight: FontWeight.w600, color: t.textSecondary)),
                        ]),
                        Text.rich(TextSpan(children: [
                          TextSpan(text: qtyText(_round(c.byColour[id] ?? 0)), style: const TextStyle(fontWeight: FontWeight.w700)),
                          TextSpan(text: ' ${_unit(c.unitId)}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                        ])),
                        if (_pcsOf(c, c.byColour[id] ?? 0) != null) Text('(${qtyText(_pcsOf(c, c.byColour[id] ?? 0))})', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                      ]),
                    ),
                  ),
              ]),
            ] else if (isProducts)
              Padding(padding: const EdgeInsets.only(top: 6), child: PlHelp('Single colour${pcs != null ? ' · ${qtyText(pcs)} pcs' : ''}')),
            // .sk-actions
            if ((isProducts && session.canAt('production.create', branchId.isEmpty ? null : branchId)) || (!isProducts && (allowed.contains('receipt') || allowed.contains('issue')))) ...[
              const SizedBox(height: 10),
              Wrap(spacing: 8, children: [
                if (isProducts)
                  OutlinedButton.icon(onPressed: () => Shell.of(context).go('/production?produce=${c.item.id}'), icon: const Icon(LucideIcons.plus, size: 13), label: const Text('Produce'))
                else ...[
                  if (allowed.contains('receipt')) OutlinedButton.icon(onPressed: () => _post('receipt', c.item.key), icon: const Icon(LucideIcons.plus, size: 13), label: const Text('Receive')),
                  if (allowed.contains('issue')) OutlinedButton.icon(onPressed: () => _post('issue', c.item.key), icon: const Icon(LucideIcons.minus, size: 13), label: const Text('Issue')),
                ],
              ]),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _fig(BuildContext context, String v, String unit, bool neg) => Text.rich(TextSpan(children: [
        TextSpan(text: v, style: TextStyle(fontSize: Fs.xl, fontWeight: FontWeight.w700, color: neg ? C.error : null)),
        TextSpan(text: ' $unit', style: TextStyle(fontSize: Fs.xs, color: context.tk.textMuted)),
      ]));

  Color _cssColour(String name) => switch (name.toLowerCase()) {
        'red' => const Color(0xFFFF0000), 'grey' || 'gray' => const Color(0xFF808080), 'black' => Colors.black, 'white' => Colors.white,
        'yellow' => const Color(0xFFFFFF00), 'green' => const Color(0xFF008000), 'blue' => const Color(0xFF0000FF), 'brown' => const Color(0xFFA52A2A),
        'orange' => const Color(0xFFFFA500), 'charcoal' => const Color(0xFF36454F), 'cream' => const Color(0xFFFFFDD0), _ => Colors.transparent,
      };

  Map<String, double> get _balanceMap => {
        for (final b in _balances)
          '${b['warehouse_id']}|${b['material_id'] != null ? 'm:${b['material_id']}' : 'p:${b['product_id']}'}${b['color_id'] != null ? '|c:${b['color_id']}' : ''}': n(b['quantity']),
      };

  void _history(Item item) {
    final mu = mainUnitOf(item);
    showModal(context, title: item.name, body: (ctx) => ItemHistoryList(
      item: item, branchId: branchId.isEmpty ? null : branchId, refs: _refs!,
      factor: mu?.factor ?? 1, symbol: _unit(mu?.id ?? item.stockUnitId), stockSymbol: _unit(item.stockUnitId),
    ));
  }

  Future<void> _post(String type, [String? itemKey]) async {
    final done = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => MovementPage(
      type: type, refs: _refs!, balances: _balanceMap, defaultWarehouseId: _warehouseId, defaultItemKey: itemKey, kind: isProducts ? 'product' : 'material',
    )));
    if (done == true) _load();
  }
}
