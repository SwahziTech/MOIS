import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../shell.dart';
import 'categories.dart' show slugify;
import 'products.dart' show EntityFlags, EntityHistory, numOrNull, p6;
import 'stock_history.dart';
import 'stock_movement.dart';

/*
 * Materials — a port of web pages/Materials.jsx with MaterialInfo, MaterialModal, ConversionsEditor,
 * NewUnitInline, FormerSources and SimpleModal (approved 2026-11-24). Tabs Materials · Material
 * categories · Units. A material is shared by every branch or is one branch's own (032); suppliers
 * are recorded on each purchase (031). Cards: category above name (LOCKED), stock in the main unit.
 */
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
String _money(Object? v) => v == null ? '—' : formatMoney(n(v), session.currency);
double _r(num v) => (v * 100).roundToDouble() / 100;

class _Data {
  _Data(Json j)
      : materials = _l(j['materials']), categories = _l(j['categories']), units = _l(j['units']),
        branches = _l(j['branches']).where((b) => b['status'] == 'active').toList(), suppliers = _l(j['suppliers']) {
    for (final it in _l(j['items'])) {
      final u = usage['${it['material_id']}'] ??= {'active': 0, 'any': 0};
      u['any'] = u['any']! + 1;
      if (it['recipe']?['status'] == 'active') u['active'] = u['active']! + 1;
      _bump(it['unit_id']);
    }
    for (final m in materials) {
      _bump(m['stock_unit_id']);
      for (final c in _l(m['conversions'])) { _bump(c['unit_id']); }
      for (final s in _l(m['sources'])) { _bump(s['purchase_unit_id']); }
    }
    for (final p in _l(j['products'])) { _bump(p['unit_id']); }
    for (final f in _l(j['flags'])) { openFlags['${f['entity_id']}'] = (openFlags['${f['entity_id']}'] ?? 0) + 1; }
    for (final u in units) { unitById['${u['id']}'] = u; }
  }
  void _bump(Object? id) { if (id != null) unitUse['$id'] = (unitUse['$id'] ?? 0) + 1; }
  final List<Json> materials, categories, units, branches, suppliers;
  final Map<String, Map<String, int>> usage = {};
  final Map<String, int> unitUse = {}, openFlags = {};
  final Map<String, Json> unitById = {};
  String sym(Object? id) => '${unitById['$id']?['symbol'] ?? ''}';
  String branchName(Object? id) => '${branches.where((b) => b['id'] == id).firstOrNull?['name'] ?? '—'}';
  Json? category(Object? id) => categories.where((c) => c['id'] == id).firstOrNull;

  /// the main unit (051): (id, symbol, factor = stock units per main unit), or null
  ({String id, String sym, double f})? mainOf(Json m) {
    if (m['main_unit_id'] == null || m['main_unit_id'] == m['stock_unit_id']) return null;
    final c = _l(m['conversions']).where((x) => x['unit_id'] == m['main_unit_id']).firstOrNull;
    return c == null ? null : (id: '${c['unit_id']}', sym: sym(c['unit_id']), f: n(c['factor_to_stock_unit']).toDouble());
  }
}

Future<Json> _fetch() async {
  final r = await Future.wait<dynamic>([
    db.from('materials').select('*, conversions:material_unit_conversions(unit_id, factor_to_stock_unit, notes), sources:material_branch_sources(id, branch_id, source_name, purchase_unit_id, supplier_id, is_primary, status, notes)').order('name'),
    db.from('material_categories').select('*').order('display_order').order('name'),
    db.from('units').select('id, symbol, name, notes, status').order('symbol'),
    db.from('branches').select('id, name, status').order('name'),
    db.from('recipe_items').select('material_id, unit_id, recipe:recipe_versions(status)'),
    db.from('review_flags').select('entity_id').eq('entity_type', 'material').eq('status', 'open'),
    db.from('products').select('unit_id'),
    db.from('suppliers').select('id, name, status').order('name'),
  ]);
  return {'materials': r[0], 'categories': r[1], 'units': r[2], 'branches': r[3], 'items': r[4], 'flags': r[5], 'products': r[6], 'suppliers': r[7]};
}

/// On hand, opening balances, last supplier and FIFO value for the branch in view
Future<Json> _fetchStock(String branchId) async {
  final r = await Future.wait<dynamic>([
    db.from('warehouses').select('id, branch_id, type, status'),
    db.from('stock_balances').select('warehouse_id, material_id, quantity').not('material_id', 'is', null),
    db.from('inventory_transactions').select('material_id, warehouse_id').eq('transaction_type', 'opening_balance').not('material_id', 'is', null),
    db.from('purchase_line_costs').select('material_id, branch_id, supplier_id, purchase_date').order('purchase_date', ascending: false),
  ]);
  final raw = {for (final w in r[0] as List) if (w['type'] != 'finished_goods' && w['type'] != 'wip' && session.inBranch(w['branch_id'])) '${w['id']}'};
  final q = <String, double>{};
  for (final b in r[1] as List) { if (raw.contains('${b['warehouse_id']}')) q['${b['material_id']}'] = (q['${b['material_id']}'] ?? 0) + n(b['quantity']); }
  final opened = {for (final t in r[2] as List) if (raw.contains('${t['warehouse_id']}')) '${t['material_id']}': true};
  final last = <String, String>{};
  for (final l in r[3] as List) { if (session.inBranch(l['branch_id']) && !last.containsKey('${l['material_id']}')) last['${l['material_id']}'] = '${l['supplier_id']}'; }
  final cost = <String, Object?>{}, value = <String, Object?>{};
  if (branchId.isNotEmpty) {
    final ids = q.keys.toList();
    // first in, first out (052): opening stock at its opening cost, each purchase at its own cost
    final res = await Future.wait([for (final id in ids) db.rpc('material_stock_value', params: {'p_branch_id': branchId, 'p_material_id': id}).catchError((_) => <dynamic>[])]);
    for (var i = 0; i < ids.length; i++) {
      final x = (res[i] as List?)?.firstOrNull as Map?;
      cost[ids[i]] = x?['unit_cost'];
      value[ids[i]] = x?['value'];
    }
  }
  return {'onHand': q, 'opened': opened, 'last': last, 'cost': cost, 'value': value};
}

class MaterialsPage extends StatefulWidget {
  const MaterialsPage({super.key});
  @override
  State<MaterialsPage> createState() => _MaterialsPageState();
}

class _MaterialsPageState extends State<MaterialsPage> {
  _Data? _d;
  Json _stock = {};
  DateTime? _savedAt;
  String _error = '', _tab = 'materials', _search = '', _filter = 'active', _categoryId = '', _sortBy = 'category';

  String get branchId => session.branchId;
  bool get canWriteMaterials => session.canManage('materials.manage');
  bool canEditMaterial(Json m) => m['branch_id'] != null ? session.canAt('materials.manage', '${m['branch_id']}', null) : session.can('materials.manage');
  bool get canAddMaterial => canWriteMaterials || (branchId.isNotEmpty && session.canAt('materials.manage', branchId, null));
  bool get canWriteUnits => session.canManage('materials.manage') || session.canManage('products.manage');

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final (j, at) = await offline.load<Json>('materials', _fetch);
      if (mounted) setState(() { _d = _Data(j); _savedAt = at; });
      _loadStock();
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load this page. Please try again.");
    }
  }

  Future<void> _loadStock() async {
    try {
      final (s, _) = await offline.load<Json>('materials:stock:$branchId', () => _fetchStock(branchId));
      if (mounted) setState(() => _stock = s);
    } catch (_) {}
  }

  double _onHand(Json m) => n((_stock['onHand'] as Map?)?['${m['id']}']).toDouble();
  bool _hasOnHand(Json m) => (_stock['onHand'] as Map?)?.containsKey('${m['id']}') ?? false;
  Object? _avgCost(Json m) => (_stock['cost'] as Map?)?['${m['id']}'];
  double? _valueOf(Json m) {
    final v = (_stock['value'] as Map?)?['${m['id']}'];
    if (v != null) return n(v).toDouble();
    final c = _avgCost(m);
    return _hasOnHand(m) && c != null ? _onHand(m) * n(c) : null;
  }

  Future<void> _push(Widget page) async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => page));
    if (saved == true) _load();
  }

  Future<void> _opening(String key) async {
    final refs = await Refs.load();
    final wh = refs.warehouses.where((w) => w.status == 'active' && w.type == 'raw_materials' && (branchId.isEmpty || w.branchId == branchId)).firstOrNull;
    if (!mounted) return;
    final done = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => MovementPage(type: 'opening_balance', refs: refs, balances: const {}, defaultItemKey: key, defaultWarehouseId: wh?.id)));
    if (done == true) _loadStock();
  }

  void _add() {
    final d = _d!;
    switch (_tab) {
      case 'materials':
        _push(_MaterialForm(data: d, material: {}, usage: const {'active': 0, 'any': 0}, canShare: canWriteMaterials,
            ownBranchChoices: d.branches.where((b) => session.canAt('materials.manage', '${b['id']}', null)).toList(), defaultBranchId: canWriteMaterials ? '' : branchId, onChanged: _load));
      case 'categories':
        _push(_categoryForm(d, {}));
      default:
        _push(_unitForm({}));
    }
  }

  Widget _categoryForm(_Data d, Json row) => _SimpleForm(
        title: 'material category', table: 'material_categories', entityType: 'material_category', row: row,
        fields: [
          (key: 'name', label: 'Name', type: 'text', required: true, def: null),
          (key: 'display_order', label: 'Display order', type: 'number', required: false, def: d.categories.fold<num>(0, (m, c) => n(c['display_order']) > m ? n(c['display_order']) : m) + 1),
          if ((row['id'] != null ? row : (d.categories.firstOrNull ?? {})).containsKey('used_in_recipes'))
            (key: 'used_in_recipes', label: 'Used in recipes (a mix ingredient)', type: 'checkbox', required: false, def: true),
        ],
        inactiveNote: 'Inactive — not offered for new materials.',
      );

  Widget _unitForm(Json row) => _SimpleForm(
        title: 'unit', table: 'units', entityType: 'unit', row: row,
        fields: const [
          (key: 'symbol', label: 'Symbol', type: 'text', required: true, def: null),
          (key: 'name', label: 'Name', type: 'text', required: true, def: null),
          (key: 'notes', label: 'Notes', type: 'text', required: false, def: null),
        ],
        inactiveNote: 'Inactive — not offered for new choices.',
      );

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final d = _d;
    if (_error.isNotEmpty && d == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    if (d == null) return ListView(padding: const EdgeInsets.all(14), children: const [Skeleton(rows: 6)]);
    final inView = d.materials.where((m) => m['branch_id'] == null || session.inBranch(m['branch_id'])).toList();
    final q = _search.trim().toLowerCase();
    final shown = inView.where((m) =>
        (_categoryId.isEmpty || (_categoryId == 'none' ? m['category_id'] == null : m['category_id'] == _categoryId)) &&
        (_filter == 'all' || (_filter == 'review' ? (d.openFlags['${m['id']}'] ?? 0) > 0 : m['status'] == _filter)) &&
        (q.isEmpty || '${m['name']}'.toLowerCase().contains(q) || '${m['material_id_ref'] ?? ''}'.toLowerCase().contains(q))).toList();
    final catOrder = {for (final c in d.categories) '${c['id']}': (n(c['display_order']), '${c['name']}')};
    shown.sort((a, b) {
      if (_sortBy == 'name_desc') return '${b['name']}'.compareTo('${a['name']}');
      if (_sortBy == 'category') {
        final x = catOrder['${a['category_id']}'] ?? (1e9, ''), y = catOrder['${b['category_id']}'] ?? (1e9, '');
        var c = x.$1.compareTo(y.$1);
        if (c == 0) c = x.$2.compareTo(y.$2);
        return c != 0 ? c : '${a['name']}'.compareTo('${b['name']}');
      }
      return '${a['name']}'.compareTo('${b['name']}');
    });
    final reviewCount = inView.where((m) => (d.openFlags['${m['id']}'] ?? 0) > 0).length;
    final active = inView.where((m) => m['status'] == 'active').toList();
    final total = active.fold<double>(0, (s, m) => s + (_valueOf(m) ?? 0));
    final uncosted = active.where((m) => _onHand(m) > 0 && _avgCost(m) == null).length;
    final out = active.where((m) => !(_onHand(m) > 0)).toList();
    final noOpening = _stock.isEmpty ? <Json>[] : active.where((m) => (_stock['opened'] as Map?)?['${m['id']}'] != true).toList();
    final canAdd = _tab == 'units' ? canWriteUnits : _tab == 'materials' ? canAddMaterial : canWriteMaterials;
    final chips = [
      for (final c in d.categories.where((c) => c['status'] == 'active' || inView.any((m) => m['category_id'] == c['id'])))
        ChipItem('${c['id']}', '${c['name']} (${inView.where((m) => m['category_id'] == c['id'] && m['status'] == 'active').length})'),
      if (inView.any((m) => m['category_id'] == null)) const ChipItem('none', 'No category'),
    ];

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: !canAdd
          ? null
          : FloatingActionButton(
              tooltip: {'materials': 'New material', 'categories': 'New category', 'units': 'New unit'}[_tab],
              backgroundColor: t.dark ? C.khaki : C.charcoal,
              foregroundColor: t.dark ? C.charcoal : Colors.white,
              onPressed: _add,
              child: const Icon(LucideIcons.plus),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 88), children: [
          OfflineNote(_savedAt),
          PageTabs<String>(tabs: const [('materials', 'Materials'), ('categories', 'Material categories'), ('units', 'Units')], value: _tab, onChange: (v) => setState(() => _tab = v)),
          if (_tab == 'materials') ...[
            Stats([
              Stat('Materials', '${active.length}', help: 'in use'),
              Stat('Stock value', branchId.isNotEmpty ? _money(total) : '—', help: branchId.isNotEmpty ? (uncosted > 0 ? '$uncosted without a cost' : 'oldest stock used first') : 'Pick a branch'),
              Stat('Out of stock', '${out.length}', figureColor: out.isNotEmpty ? C.error : null, help: out.isNotEmpty ? 'need intake' : 'all in stock'),
              Stat('Opening stock', noOpening.isNotEmpty ? '${noOpening.length}' : 'All set', figureColor: noOpening.isNotEmpty ? C.warning : null, help: noOpening.isNotEmpty ? 'not set yet' : 'every material counted'),
            ]),
            if (noOpening.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Alert('Opening stock not set: ${noOpening.map((m) => m['name']).join(', ')}', tone: Tone.warning,
                    action: session.canAt('inventory.adjust', branchId.isEmpty ? null : branchId, null)
                        ? TextButton(onPressed: () => _opening('m:${noOpening.first['id']}'), child: const Text('Set opening stock'))
                        : null),
              ),
            ListToolbar(
              placeholder: 'Search materials…',
              onSearch: (v) => setState(() => _search = v),
              sort: SortSpec(value: _sortBy, onChange: (v) => setState(() => _sortBy = v), options: const [('category', 'Material order (default)'), ('name_asc', 'Name: A → Z'), ('name_desc', 'Name: Z → A')]),
              filters: [
                FilterSpec(key: 'status', label: 'Status', value: _filter, onChange: (v) => setState(() => _filter = v),
                    options: [('active', 'Active'), ('review', 'Needs review ($reviewCount)'), ('inactive', 'Inactive'), ('all', 'All')]),
              ],
            ),
            ChipRow(items: chips, value: _categoryId, onChange: (v) => setState(() => _categoryId = v)),
            const SizedBox(height: 10),
            Text('${_categoryId.isEmpty ? 'All materials' : _categoryId == 'none' ? 'No category' : d.category(_categoryId)?['name'] ?? ''} (${shown.length})', style: TextStyle(fontWeight: FontWeight.w600, color: t.textSecondary)),
            const SizedBox(height: 8),
            if (shown.isEmpty)
              EmptyState(icon: LucideIcons.layers, title: 'No materials in this view', description: _search.isNotEmpty ? 'No materials match "$_search".' : null)
            else
              for (var i = 0; i < shown.length; i++) _card(context, d, shown[i], i),
          ] else if (_tab == 'categories') ...[
            if (d.categories.isEmpty)
              const EmptyState(icon: LucideIcons.layers, title: 'No material categories yet', description: 'Group materials, e.g. aggregates or pigments.')
            else
              for (final c in d.categories)
                _simpleRow(
                  title: '${c['name']}',
                  badges: [if (c['used_in_recipes'] == false) const Badge2('Not in recipes')],
                  sub: 'Order ${c['display_order']} · ${inView.where((m) => m['category_id'] == c['id'] && m['status'] == 'active').length} materials',
                  status: '${c['status']}',
                  onTap: canWriteMaterials ? () => _push(_categoryForm(d, c)) : null,
                ),
          ] else
            for (final u in d.units)
              _simpleRow(
                title: '${u['symbol']}',
                badges: const [],
                sub: '${u['name']}${'${u['notes'] ?? ''}'.isNotEmpty ? ' · ${u['notes']}' : ''} · in use ${d.unitUse['${u['id']}'] != null ? '${d.unitUse['${u['id']}']}×' : '—'}',
                status: '${u['status']}',
                onTap: canWriteUnits ? () => _push(_unitForm(u)) : null,
              ),
        ]),
      ),
    );
  }

  Widget _simpleRow({required String title, required List<Widget> badges, required String sub, required String status, VoidCallback? onTap}) {
    final t = context.tk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: t.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.md)), ...badges]),
                  Text(sub, style: TextStyle(fontSize: Fs.sm, color: t.textMuted)),
                ]),
              ),
              Badge2(status, tone: status == 'active' ? Tone.success : Tone.neutral),
              if (onTap != null) ...[const SizedBox(width: 8), Icon(LucideIcons.pencil, size: 16, color: t.textSecondary)],
            ]),
          ),
        ),
      ),
    );
  }

  /// One material card — category above the name (LOCKED), stock in its main unit, value at the branch
  Widget _card(BuildContext context, _Data d, Json m, int i) {
    final t = context.tk;
    final st = d.sym(m['stock_unit_id']);
    final main = d.mainOf(m);
    final qty = _onHand(m);
    final sup = d.suppliers.where((x) => x['id'] == (_stock['last'] as Map?)?['${m['id']}']).firstOrNull?['name'];
    final v = _valueOf(m);
    final cost = _avgCost(m);
    String? alt() {
      final convs = _l(m['conversions'])..sort((x, y) => (n(y['factor_to_stock_unit']).abs()).compareTo(n(x['factor_to_stock_unit']).abs()));
      final c = convs.firstOrNull;
      return c != null && qty != 0 ? '${qtyText(_r(qty / n(c['factor_to_stock_unit'])))} ${d.sym(c['unit_id'])}' : null;
    }

    final fig = main != null ? '${qtyText(_r(qty / main.f))} ${main.sym}' : '${qtyText(_r(qty))} $st';
    final sub = main != null ? '(${qtyText(_r(qty))} $st)' : (alt() != null ? '(${alt()})' : null);
    final tags = [
      '#${i + 1}',
      '${d.category(m['category_id'])?['name'] ?? 'No category'}',
      if (m['branch_id'] != null) '${d.branchName(m['branch_id'])} only',
      if (m['status'] != 'active') 'inactive',
    ].join(' · ');
    final canIntake = m['status'] == 'active' && session.canAt('procurement.receive', branchId.isEmpty ? null : branchId, null);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: m['status'] != 'active' ? 0.6 : 1,
        child: Material(
          color: t.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _push(_MaterialInfo(data: d, material: m, onHand: qty, avgCost: cost, canEdit: canEditMaterial(m), onEdit: () => _edit(d, m))),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Text(tags.toUpperCase(), style: TextStyle(fontSize: Fs.xs, color: t.textMuted, letterSpacing: 0.4)),
                        if ((d.openFlags['${m['id']}'] ?? 0) > 0) const Badge2('review', tone: Tone.warning),
                        if (m['status'] == 'active' && !(qty > 0))
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5),
                            decoration: BoxDecoration(border: Border.all(color: C.error), borderRadius: BorderRadius.circular(4)),
                            child: const Text('OUT', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: C.error)),
                          ),
                      ]),
                      const SizedBox(height: 2),
                      Text('${m['name']}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.md)),
                      if (sup != null) PlHelp('last from $sup'),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(fig, style: TextStyle(fontWeight: FontWeight.w700, fontSize: Fs.md, color: qty < 0 ? C.error : null)),
                    if (sub != null) Text(sub, style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                  ]),
                  if (canEditMaterial(m)) IconButton(tooltip: 'Edit', onPressed: () => _edit(d, m), icon: Icon(LucideIcons.pencil, size: 16, color: t.textSecondary)),
                ]),
                if (branchId.isNotEmpty || canIntake)
                  Row(children: [
                    if (branchId.isNotEmpty)
                      Expanded(
                        child: Text.rich(TextSpan(style: TextStyle(fontSize: Fs.sm, color: t.textSecondary), children: [
                          const TextSpan(text: 'Value '),
                          TextSpan(text: v != null ? _money(v) : '—', style: TextStyle(fontWeight: FontWeight.w700, color: t.textPrimary)),
                          if (cost != null) TextSpan(text: ' · @ ${main != null ? '${_money(n(cost) * main.f)}/${main.sym}' : '${_money(cost)}/$st'}'),
                        ])),
                      )
                    else
                      const Spacer(),
                    if (canIntake)
                      TextButton.icon(
                        onPressed: () => Shell.of(context).go('/purchases?buy=${m['id']}'),
                        icon: const Icon(LucideIcons.plus, size: 14),
                        label: const Text('Intake'),
                      ),
                  ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  void _edit(_Data d, Json m) => _push(_MaterialForm(
        data: d, material: m, usage: d.usage['${m['id']}'] ?? const {'active': 0, 'any': 0}, canShare: canWriteMaterials,
        ownBranchChoices: d.branches.where((b) => session.canAt('materials.manage', '${b['id']}', null)).toList(),
        defaultBranchId: canWriteMaterials ? '' : branchId, onChanged: _load,
      ));
}

// ---- MaterialInfo: a material at a glance, read-only ---------------------------------------------
class _MaterialInfo extends StatefulWidget {
  const _MaterialInfo({required this.data, required this.material, required this.onHand, required this.avgCost, required this.canEdit, required this.onEdit});
  final _Data data;
  final Json material;
  final double onHand;
  final Object? avgCost;
  final bool canEdit;
  final VoidCallback onEdit;
  @override
  State<_MaterialInfo> createState() => _MaterialInfoState();
}

class _MaterialInfoState extends State<_MaterialInfo> {
  Json? _fifo;
  List<Json>? _recipes;
  Refs? _refs;
  Json get m => widget.material;
  _Data get d => widget.data;
  String get branchId => session.branchId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait<dynamic>([
        branchId.isNotEmpty ? db.rpc('material_stock_value', params: {'p_branch_id': branchId, 'p_material_id': m['id']}).catchError((_) => <dynamic>[]) : Future.value(<dynamic>[]),
        db.from('recipe_items').select('quantity, unit_id, recipe:recipe_versions!inner(status, branch_id, variant_label, color:color_palette(name), category:product_categories(name))').eq('material_id', m['id']).eq('recipe.status', 'active'),
        Refs.load(),
      ]);
      if (!mounted) return;
      setState(() {
        _fifo = ((r[0] as List?)?.firstOrNull as Map?)?.cast<String, dynamic>();
        _recipes = [for (final x in r[1] as List) if (branchId.isEmpty || x['recipe']['branch_id'] == branchId) Map<String, dynamic>.from(x)];
        _refs = r[2] as Refs;
      });
    } catch (_) {
      if (mounted) setState(() => _recipes ??= []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final st = d.sym(m['stock_unit_id']);
    final main = d.mainOf(m);
    final mf = main?.f ?? 1;
    final ms = main?.sym ?? st;
    final f = _fifo;
    final item = _refs?.items['m:${m['id']}'];
    final layers = _l(f?['layers']);
    return FullPage(
      title: '${m['name']}',
      footer: [
        if (widget.canEdit) OutlinedButton(onPressed: () { Navigator.pop(context); widget.onEdit(); }, child: const Text('Edit')),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
      children: [
        Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          PlHelp('${d.category(m['category_id'])?['name'] ?? 'No category'} · ${m['branch_id'] != null ? '${d.branchName(m['branch_id'])} only' : 'All branches'}'),
          Badge2('${m['status']}', tone: m['status'] == 'active' ? Tone.success : Tone.neutral),
        ]),
        const SizedBox(height: 10),
        Stats([
          Stat('On hand${branchId.isEmpty ? ' (all branches)' : ''}', '${qtyText(_r(widget.onHand / mf))} $ms', help: main != null ? '${qtyText(_r(widget.onHand))} $st' : ''),
          Stat('Value of stock left', f?['value'] != null ? _money(f!['value']) : widget.avgCost != null ? _money(widget.onHand * n(widget.avgCost)) : '—', help: 'oldest stock is used first'),
          Stat('Latest cost', f?['last_cost'] != null ? '${_money(n(f!['last_cost']) * mf)}/$ms' : '—', help: f?['unit_cost'] != null ? 'average of stock left ${_money(n(f!['unit_cost']) * mf)}/$ms' : ''),
        ]),
        if (item != null && _refs != null)
          ItemHistoryList(item: item, branchId: branchId.isEmpty ? null : branchId, refs: _refs!, factor: mf, symbol: ms, stockSymbol: st),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text('More about ${m['name']} — units, cost layers, recipes, notes', style: TextStyle(fontSize: Fs.sm, color: t.textSecondary)),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SectionTitle('Units'),
              Text('Stock unit: ${d.unitById['${m['stock_unit_id']}']?['name'] ?? '—'} (${st.isEmpty ? '—' : st})', style: const TextStyle(fontSize: Fs.sm)),
              if (main != null) Text('Main unit: $ms — stock is counted and shown in it', style: const TextStyle(fontSize: Fs.sm)),
              for (final c in _l(m['conversions']))
                Builder(builder: (_) {
                  final fc = n(c['factor_to_stock_unit']);
                  final u = d.sym(c['unit_id']);
                  return Text('Also counted in: ${fc >= 1 ? '1 $u = ${qtyText(fc)} $st' : '1 $st = ${qtyText(_r(1 / fc))} $u'}${c['notes'] != null ? ' — ${c['notes']}' : ''}', style: const TextStyle(fontSize: Fs.sm));
                }),
              if (layers.isNotEmpty) ...[
                const SectionTitle('Stock left, by cost — oldest is used first'),
                for (final l in layers.reversed)   // newest on top (LOCKED)
                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
                    child: Row(children: [
                      SizedBox(width: 92, child: Text(tableDate(l['date']) ?? '—', style: const TextStyle(fontSize: Fs.sm))),
                      Expanded(child: Text('${qtyText(_r(n(l['quantity']) / mf))} $ms', style: const TextStyle(fontSize: Fs.sm))),
                      Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(l['cost'] != null ? '${_money(n(l['cost']) * mf)}/$ms' : 'no cost', style: const TextStyle(fontSize: Fs.sm)),
                        Text(l['cost'] != null ? _money(n(l['cost']) * n(l['quantity'])) : '—', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                      ]),
                    ]),
                  ),
              ],
              SectionTitle('Used in recipes${branchId.isNotEmpty ? ' at ${session.branchName}' : ''}'),
              if (_recipes == null)
                const Skeleton(rows: 1, height: 20)
              else if (_recipes!.isEmpty)
                const PlHelp('Not in any active recipe.')
              else
                Wrap(spacing: 4, runSpacing: 4, children: [
                  for (final r in _recipes!)
                    Badge2('${r['recipe']['category']?['name'] ?? ''} ${r['recipe']['color']?['name'] ?? r['recipe']['variant_label'] ?? ''} · ${qtyText(n(r['quantity']))} ${d.sym(r['unit_id'])}/bag'),
                ]),
              if ('${m['notes'] ?? ''}'.isNotEmpty) ...[const SectionTitle('Notes'), Text('${m['notes']}', style: const TextStyle(fontSize: Fs.sm))],
              EntityFlags(entityType: 'material', entityId: '${m['id']}'),
              EntityHistory(entityType: 'material', entityId: '${m['id']}'),
            ],
          ),
        ),
      ],
    );
  }
}

// ---- MaterialModal: add or edit a material -------------------------------------------------------
class _MaterialForm extends StatefulWidget {
  const _MaterialForm({required this.data, required this.material, required this.usage, required this.canShare, required this.ownBranchChoices, required this.defaultBranchId, required this.onChanged});
  final _Data data;
  final Json material;
  final Map<String, int> usage;
  final bool canShare;
  final List<Json> ownBranchChoices;
  final String defaultBranchId;
  final Future<void> Function() onChanged;
  @override
  State<_MaterialForm> createState() => _MaterialFormState();
}

class _MaterialFormState extends State<_MaterialForm> {
  _Data get d => widget.data;
  Json get m => widget.material;
  bool get isNew => m['id'] == null;
  // '' = shared by every branch; otherwise the one branch that uses it
  late String _scope = isNew ? (widget.defaultBranchId.isNotEmpty ? widget.defaultBranchId : (widget.canShare ? '' : '${widget.ownBranchChoices.firstOrNull?['id'] ?? ''}')) : '${m['branch_id'] ?? ''}';
  late final _name = TextEditingController(text: '${m['name'] ?? ''}');
  late String _category = '${m['category_id'] ?? ''}';
  late String _stockId = '${m['stock_unit_id'] ?? ''}';
  late String _mainId = '${m['main_unit_id'] ?? ''}';
  late final _notes = TextEditingController(text: '${m['notes'] ?? ''}');
  final List<Json> _extraUnits = [];
  bool _newUnit = false, _busy = false;
  String _error = '';

  List<Json> get allUnits => [...d.units, ..._extraUnits.where((x) => !d.units.any((u) => u['id'] == x['id']))];
  String sym(Object? id) => '${allUnits.where((u) => u['id'] == id).firstOrNull?['symbol'] ?? ''}';
  List<Json> get conversions => _l(m['conversions']);
  // 021: the stock unit is fixed once anything is expressed relative to it
  bool get stockLocked => m['stock_unit_id'] != null && (conversions.isNotEmpty || _l(m['sources']).isNotEmpty || (widget.usage['any'] ?? 0) > 0);
  List<Json> get activeUnits => allUnits.where((u) => u['status'] != 'inactive' || u['id'] == m['stock_unit_id']).toList();

  void _unitAdded(Json u) { setState(() => _extraUnits.add(u)); widget.onChanged(); }

  Future<void> _run(Future<void> Function() f) async {
    setState(() { _error = ''; _busy = true; });
    try {
      await f();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = dbError(e); });
    }
  }

  Future<void> _save() async {
    final clash = d.materials.where((x) => x['id'] != m['id'] && '${x['name']}'.trim().toLowerCase() == _name.text.trim().toLowerCase()).firstOrNull;
    if (clash != null) return setState(() => _error = 'A material called "${clash['name']}" already exists.');
    final row = {
      'name': _name.text.trim(), 'category_id': _category.isEmpty ? null : _category, 'stock_unit_id': _stockId.isEmpty ? null : _stockId,
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      if (!isNew && m.containsKey('main_unit_id')) 'main_unit_id': _mainId.isNotEmpty && _mainId != _stockId ? _mainId : null,
    };
    await _run(() async {
      if (isNew) {
        final taken = {for (final x in d.materials) if (x['material_id_ref'] != null) '${x['material_id_ref']}'};
        final base = slugify('${row['name']}');
        var ref = base;
        for (var i = 2; taken.contains(ref); i++) { ref = '${base}_$i'; }
        await db.from('materials').insert({...row, 'organization_id': session.organization!['id'], 'status': 'active', 'branch_id': _scope.isEmpty ? null : _scope, 'material_id_ref': ref});
      } else {
        await db.from('materials').update(row).eq('id', m['id']);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final usage = widget.usage;
    final cats = d.categories.where((c) => c['status'] == 'active' || c['id'] == m['category_id']).toList();
    Widget gap() => const SizedBox(height: 12);
    return FullPage(
      title: isNew ? 'Add material' : 'Edit ${m['name']}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
        FilledButton(onPressed: _busy || _name.text.trim().isEmpty ? null : _save, child: Text(isNew ? 'Add material' : 'Save details')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        if (!isNew) PlHelp('${m['material_id_ref'] ?? ''}'),
        TextField(controller: _name, autofocus: isNew, onChanged: (_) => setState(() {}), textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Name')),
        gap(),
        DropdownButtonFormField<String>(
          initialValue: _category, isExpanded: true, decoration: const InputDecoration(labelText: 'Category'),
          items: [const DropdownMenuItem(value: '', child: Text('None')), for (final c in cats) DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}'))],
          onChanged: (v) => setState(() => _category = v ?? ''),
        ),
        gap(),
        if (isNew) ...[
          DropdownButtonFormField<String>(
            initialValue: _scope, isExpanded: true, decoration: const InputDecoration(labelText: 'Used by', helperText: 'Only this branch uses it.'),
            items: [
              if (widget.canShare) const DropdownMenuItem(value: '', child: Text('All branches (shared)')),
              for (final b in widget.ownBranchChoices) DropdownMenuItem(value: '${b['id']}', child: Text('${b['name']} only')),
            ],
            onChanged: (v) => setState(() => _scope = v ?? ''),
          ),
          gap(),
        ] else if (m['branch_id'] != null) ...[
          Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Badge2('${d.branchName(m['branch_id'])} only', tone: Tone.info),
            PlHelp('Only ${d.branchName(m['branch_id'])} edits and uses it.'),
            if (widget.canShare) TextButton(onPressed: _busy ? null : () => _run(() async => db.from('materials').update({'branch_id': null}).eq('id', m['id'])), child: const Text('Make shared with all branches')),
          ]),
          gap(),
        ],
        DropdownButtonFormField<String>(
          key: ValueKey('stock$_stockId${_extraUnits.length}'),
          initialValue: _newUnit ? '__new' : _stockId, isExpanded: true,
          decoration: InputDecoration(labelText: 'Stock unit', helperText: stockLocked ? 'Fixed: conversions, sources or recipes are expressed in it.' : 'The unit stock of this material is counted in.', helperMaxLines: 2),
          items: [
            const DropdownMenuItem(value: '', child: Text('Not set yet')),
            for (final u in activeUnits) DropdownMenuItem(value: '${u['id']}', child: Text('${u['symbol']} — ${u['name']}')),
            const DropdownMenuItem(value: '__new', child: Text('+ New unit…')),
          ],
          onChanged: stockLocked ? null : (v) => setState(() { if (v == '__new') { _newUnit = true; } else { _newUnit = false; _stockId = v ?? ''; } }),
        ),
        if (_newUnit) _NewUnitInline(units: allUnits, onCancel: () => setState(() => _newUnit = false), onCreated: (u) { _unitAdded(u); setState(() { _stockId = '${u['id']}'; _newUnit = false; }); }),
        if (!isNew && conversions.isNotEmpty && m.containsKey('main_unit_id')) ...[
          gap(),
          DropdownButtonFormField<String>(
            initialValue: _mainId.isNotEmpty ? _mainId : _stockId, isExpanded: true,
            decoration: InputDecoration(labelText: 'Main unit (counting and display)', helperText: 'Stock is counted and shown in this unit; the ledger keeps ${sym(_stockId).isEmpty ? 'the stock unit' : sym(_stockId)} and recipes keep theirs.', helperMaxLines: 3),
            items: [
              if (_stockId.isNotEmpty) DropdownMenuItem(value: _stockId, child: Text('${sym(_stockId)} — the stock unit')),
              for (final c in conversions) DropdownMenuItem(value: '${c['unit_id']}', child: Text('${sym(c['unit_id'])} (= ${p6(c['factor_to_stock_unit'])} ${sym(_stockId)})')),
            ],
            onChanged: (v) => setState(() => _mainId = v ?? ''),
          ),
        ],
        gap(),
        TextField(controller: _notes, minLines: 2, maxLines: 4, decoration: const InputDecoration(labelText: 'Notes')),
        if (!isNew) ...[
          _ConversionsEditor(material: m, units: activeUnits, sym: sym, onChanged: widget.onChanged, onUnitAdded: _unitAdded),
          _FormerSources(data: d, material: m),
          const SectionTitle('Status'),
          if (m['status'] == 'active' && (usage['active'] ?? 0) > 0)
            PlHelp('In ${usage['active']} recipe line${usage['active'] == 1 ? '' : 's'} — remove it there first.')
          else ...[
            PlHelp(m['status'] == 'active' ? 'Deactivating hides it from new recipes and sources. History is kept.' : 'Inactive — kept for history, not offered for new recipes.'),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: _busy ? null : () => _run(() async => db.from('materials').update({'status': m['status'] == 'active' ? 'inactive' : 'active'}).eq('id', m['id'])),
                child: Text(m['status'] == 'active' ? 'Deactivate material' : 'Reactivate material'),
              ),
            ),
          ],
          EntityFlags(entityType: 'material', entityId: '${m['id']}', canResolve: true, canRaise: true, onChanged: () => widget.onChanged()),
          EntityHistory(entityType: 'material', entityId: '${m['id']}'),
        ],
      ],
    );
  }
}

/// A unit added on the spot: short name + full name, e.g. pakti · Pakti, bag12 · Bag 12 kg
class _NewUnitInline extends StatefulWidget {
  const _NewUnitInline({required this.units, required this.onCreated, required this.onCancel});
  final List<Json> units;
  final ValueChanged<Json> onCreated;
  final VoidCallback onCancel;
  @override
  State<_NewUnitInline> createState() => _NewUnitInlineState();
}

class _NewUnitInlineState extends State<_NewUnitInline> {
  final _symbol = TextEditingController(), _name = TextEditingController();
  bool _busy = false;
  String _error = '';

  Future<void> _add() async {
    setState(() => _error = '');
    final s = _symbol.text.trim();
    final nm = _name.text.trim().isEmpty ? s : _name.text.trim();
    if (s.isEmpty) return setState(() => _error = 'Type the short name, e.g. pakti or bag12.');
    if (widget.units.any((u) => '${u['symbol']}'.toLowerCase() == s.toLowerCase())) return setState(() => _error = '$s is already a unit — choose it from the list.');
    setState(() => _busy = true);
    try {
      final data = await db.from('units').insert({'organization_id': session.organization!['id'], 'symbol': s, 'name': nm}).select('id, symbol, name, status').single();
      widget.onCreated(Map<String, dynamic>.from(data));
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e); });
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: TextField(controller: _symbol, autofocus: true, decoration: const InputDecoration(hintText: 'Short, e.g. pakti'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _name, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'Full, e.g. Bag 12 kg'), onSubmitted: (_) => _add())),
          ]),
          if (_error.isNotEmpty) PlHelp(_error, color: C.error),
          Row(children: [
            FilledButton(onPressed: _busy ? null : _add, child: const Text('Add unit')),
            TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
          ]),
        ]),
      );
}

/// 1 unit = factor × stock unit, saved one line at a time
class _ConversionsEditor extends StatefulWidget {
  const _ConversionsEditor({required this.material, required this.units, required this.sym, required this.onChanged, required this.onUnitAdded});
  final Json material;
  final List<Json> units;
  final String Function(Object?) sym;
  final Future<void> Function() onChanged;
  final ValueChanged<Json> onUnitAdded;
  @override
  State<_ConversionsEditor> createState() => _ConversionsEditorState();
}

class _Conv {
  _Conv({this.unitId = '', this.saved = false, this.savedFactor});
  String unitId;
  final TextEditingController factor = TextEditingController();
  bool saved;
  double? savedFactor;
  Object? notes;
}

class _ConversionsEditorState extends State<_ConversionsEditor> {
  Json get m => widget.material;
  late List<_Conv> _rows = [
    for (final c in _l(m['conversions'])) _Conv(unitId: '${c['unit_id']}', saved: true, savedFactor: n(c['factor_to_stock_unit']).toDouble())..factor.text = p6(c['factor_to_stock_unit'])..notes = c['notes'],
  ];
  int? _busy, _newUnitRow;
  String _error = '';

  Future<void> _saveRow(int i) async {
    final r = _rows[i];
    setState(() => _error = '');
    final f = numOrNull(r.factor.text);
    if (r.unitId.isEmpty) return setState(() => _error = 'Choose a unit.');
    if (!(f != null && f > 0)) return setState(() => _error = 'The factor must be a number above zero.');
    setState(() => _busy = i);
    try {
      await db.from('material_unit_conversions').upsert(
          {'organization_id': session.organization!['id'], 'material_id': m['id'], 'unit_id': r.unitId, 'factor_to_stock_unit': f, 'notes': r.notes},
          onConflict: 'material_id,unit_id');
      setState(() { r.saved = true; r.savedFactor = f; });
      widget.onChanged();
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _removeRow(int i) async {
    final r = _rows[i];
    setState(() => _error = '');
    if (!r.saved) return setState(() => _rows = [..._rows]..removeAt(i));
    setState(() => _busy = i);
    try {
      await db.from('material_unit_conversions').delete().eq('material_id', m['id']).eq('unit_id', r.unitId);
      setState(() => _rows = [..._rows]..removeAt(i));
      widget.onChanged();
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) {
    final stock = widget.sym(m['stock_unit_id']);
    final used = {'${m['stock_unit_id']}', for (final r in _rows) r.unitId};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Also counted in'),
      if (m['stock_unit_id'] == null)
        const PlHelp('Set the stock unit first — conversions are expressed in it.')
      else ...[
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        for (var i = 0; i < _rows.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              const Text('1 '),
              SizedBox(
                width: 96,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('cv$i${_rows[i].unitId}'),
                  initialValue: _newUnitRow == i ? '__new' : (_rows[i].unitId.isEmpty ? null : _rows[i].unitId), isExpanded: true,
                  items: [
                    for (final u in _rows[i].saved ? widget.units.where((u) => u['id'] == _rows[i].unitId) : widget.units.where((u) => !used.contains(u['id']) || u['id'] == _rows[i].unitId))
                      DropdownMenuItem(value: '${u['id']}', child: Text('${u['symbol']}')),
                    if (!_rows[i].saved) const DropdownMenuItem(value: '__new', child: Text('+ New…')),
                  ],
                  onChanged: _rows[i].saved ? null : (v) => setState(() { if (v == '__new') { _newUnitRow = i; } else { _newUnitRow = null; _rows[i].unitId = v ?? ''; } }),
                ),
              ),
              const Text(' = '),
              Expanded(child: TextField(controller: _rows[i].factor, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true))),
              Text(' $stock'),
              if (!_rows[i].saved || numOrNull(_rows[i].factor.text) != _rows[i].savedFactor)
                TextButton(onPressed: _busy == i ? null : () => _saveRow(i), child: const Text('Save')),
              IconButton(tooltip: 'Remove conversion', onPressed: _busy == i ? null : () => _removeRow(i), icon: const Icon(LucideIcons.trash2, size: 16)),
            ]),
          ),
        if (_newUnitRow != null)
          _NewUnitInline(units: widget.units, onCancel: () => setState(() => _newUnitRow = null), onCreated: (u) {
            widget.onUnitAdded(u);
            setState(() { _rows[_newUnitRow!].unitId = '${u['id']}'; _newUnitRow = null; });
          }),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: () => setState(() => _rows = [..._rows, _Conv()]), icon: const Icon(LucideIcons.plus, size: 14), label: const Text('Add a unit')),
        ),
      ],
    ]);
  }
}

/// Fixed per-branch sources were retired in 031; what was recorded before is kept as history
class _FormerSources extends StatelessWidget {
  const _FormerSources({required this.data, required this.material});
  final _Data data;
  final Json material;
  @override
  Widget build(BuildContext context) {
    final sources = _l(material['sources']);
    if (sources.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('Where it was bought (history)'),
      const PlHelp('Suppliers are set on each receipt.'),
      for (final x in sources)
        Text(
          '${data.branchName(x['branch_id'])}: ${data.suppliers.where((s) => s['id'] == x['supplier_id']).firstOrNull?['name'] ?? x['source_name']}'
          '${x['purchase_unit_id'] != null ? ' · bought in ${data.sym(x['purchase_unit_id'])}' : ''}${x['status'] != 'active' ? ' (inactive)' : ''}',
          style: const TextStyle(fontSize: Fs.sm),
        ),
    ]);
  }
}

/// Name-style records with a status: material categories, units
class _SimpleForm extends StatefulWidget {
  const _SimpleForm({required this.title, required this.table, required this.entityType, required this.row, required this.fields, required this.inactiveNote});
  final String title, table, entityType, inactiveNote;
  final Json row;
  final List<({String key, String label, String type, bool required, Object? def})> fields;
  @override
  State<_SimpleForm> createState() => _SimpleFormState();
}

class _SimpleFormState extends State<_SimpleForm> {
  Json get row => widget.row;
  bool get isNew => row['id'] == null;
  late final Map<String, TextEditingController> _text = {
    for (final f in widget.fields) if (f.type != 'checkbox') f.key: TextEditingController(text: '${row[f.key] ?? f.def ?? ''}'),
  };
  late final Map<String, bool> _checks = {for (final f in widget.fields) if (f.type == 'checkbox') f.key: (row[f.key] ?? f.def ?? false) == true};
  bool _busy = false;
  String _error = '';

  Future<void> _run(Future<void> Function() f) async {
    setState(() { _error = ''; _busy = true; });
    try {
      await f();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = dbError(e); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final missing = widget.fields.any((f) => f.required && (_text[f.key]?.text.trim() ?? '').isEmpty);
    final out = {
      for (final f in widget.fields)
        f.key: f.type == 'checkbox' ? _checks[f.key] : f.type == 'number' ? (num.tryParse(_text[f.key]!.text.trim()) ?? 0) : (_text[f.key]!.text.trim().isEmpty ? null : _text[f.key]!.text.trim()),
    };
    return FullPage(
      title: isNew ? 'Add ${widget.title}' : 'Edit ${row['name'] ?? row['symbol']}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy || missing
              ? null
              : () => _run(() async => isNew
                  ? await db.from(widget.table).insert({...out, 'organization_id': session.organization!['id']})
                  : await db.from(widget.table).update(out).eq('id', row['id'])),
          child: const Text('Save'),
        ),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        for (final (i, f) in widget.fields.indexed)
          f.type == 'checkbox'
              ? CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: _checks[f.key], title: Text(f.label), onChanged: (v) => setState(() => _checks[f.key] = v ?? false))
              : Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: _text[f.key], autofocus: i == 0 && isNew, onChanged: (_) => setState(() {}),
                    keyboardType: f.type == 'number' ? TextInputType.number : TextInputType.text,
                    decoration: InputDecoration(labelText: f.label),
                  ),
                ),
        if (!isNew) ...[
          const SectionTitle('Status'),
          PlHelp(row['status'] == 'active' ? 'Deactivating hides it from new choices.' : widget.inactiveNote),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _busy ? null : () => _run(() async => db.from(widget.table).update({'status': row['status'] == 'active' ? 'inactive' : 'active'}).eq('id', row['id'])),
              child: Text(row['status'] == 'active' ? 'Deactivate' : 'Reactivate'),
            ),
          ),
          EntityHistory(entityType: widget.entityType, entityId: '${row['id']}'),
        ],
      ],
    );
  }
}
