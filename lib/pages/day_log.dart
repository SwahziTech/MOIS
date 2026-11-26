import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/production.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../shell.dart';
import 'procurement_actions.dart' show DateField;

/*
 * Record the day's production — a port of web components/production/DayLog.jsx with BatchNotes.jsx
 * (043/048/055/056/087/127/135/138): each mix is one batch — main product, colour, bags of cement —
 * scaled from the branch's recipe (recipe tiles, LOCKED) and checked against the store; its pieces (plus
 * residuals from the same mix) give the yield check. Batches are added to the day's list and saved
 * together; the unsaved list stays on this phone until saved. Online only (2026-11-24, the user).
 */
double? _num(String v) => v.trim().isEmpty ? null : double.tryParse(v.trim().replaceAll(',', ''));
double _round(num v, [int d = 4]) => (v * _pow(d)).roundToDouble() / _pow(d);
double _pow(int d) => [1.0, 10.0, 100.0, 1000.0, 10000.0][d];
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];

/// The batch being typed
class _Form {
  String productId = '', colorId = '', bags = '', pieces = '', notes = '', teamId = '', machineId = '', curingId = '';
  List<Map<String, String>> leftovers = [];
  Map<String, String> edits = {}, orderPick = {};
  bool allowOther = false;
  List<String>? workerIds;
  Json toJson() => {
        'productId': productId, 'colorId': colorId, 'bags': bags, 'pieces': pieces, 'notes': notes, 'teamId': teamId, 'machineId': machineId, 'curingId': curingId,
        'leftovers': leftovers, 'edits': edits, 'orderPick': orderPick, 'allowOther': allowOther, 'workerIds': workerIds,
      };
  static _Form from(Json j) => _Form()
    ..productId = '${j['productId'] ?? ''}'..colorId = '${j['colorId'] ?? ''}'..bags = '${j['bags'] ?? ''}'..pieces = '${j['pieces'] ?? ''}'
    ..notes = '${j['notes'] ?? ''}'..teamId = '${j['teamId'] ?? ''}'..machineId = '${j['machineId'] ?? ''}'..curingId = '${j['curingId'] ?? ''}'
    ..leftovers = [for (final x in (j['leftovers'] as List? ?? [])) Map<String, String>.from((x as Map).map((k, v) => MapEntry('$k', '$v')))]
    ..edits = Map<String, String>.from(((j['edits'] as Map?) ?? {}).map((k, v) => MapEntry('$k', '$v')))
    ..orderPick = Map<String, String>.from(((j['orderPick'] as Map?) ?? {}).map((k, v) => MapEntry('$k', '$v')))
    ..allowOther = j['allowOther'] == true
    ..workerIds = (j['workerIds'] as List?)?.map((e) => '$e').toList();
  /// the next batch keeps the machine; the team is chosen afresh for every batch (2026-10-30)
  _Form next() => _Form()..machineId = machineId..curingId = curingId;
}

class DayLog extends StatefulWidget {
  const DayLog({super.key, required this.refs, required this.recipes, required this.curingDays, this.usage = const {}, this.preset, required this.onSaved});
  final Refs refs;
  final List<Json> recipes;
  final int curingDays;
  final Map<String, int> usage;
  final ({String productId, String colorId, int at})? preset;
  final VoidCallback onSaved;
  @override
  State<DayLog> createState() => _DayLogState();
}

class _DayLogState extends State<DayLog> {
  Refs get refs => widget.refs;
  String get branchId => session.branchId;
  String get today => session.today;
  String get key => 'mois.production.day.${session.organization?['id']}.$branchId';
  late final List<Store> stores = refs.warehouses.where((w) => w.status == 'active' && w.branchId == branchId).toList();
  late final List<Store> rawStores = stores.where((w) => w.type == 'raw_materials' || w.type == 'general').toList();
  late final List<Store> curingStores = stores.where((w) => w.type == 'wip').toList();
  bool get isManager => session.canAt('products.manage', branchId, null) || session.canAt('production.other_products', branchId, null);
  // an earlier date is a stock correction: someone who isn't an org admin sends the day for approval (044)
  bool get viaApproval => _date.compareTo(today) < 0 && !session.canManage('inventory.adjust');

  late String _date = today;
  String _rawId = '';
  _Form _form = _Form();
  List<Json> _staged = [];
  bool _restored = false, _busy = false, _ready = false;
  Map<String, double> _stock = {};
  Map<String, Map<String, double>> _otherStock = {};
  final Map<String, Json?> _bands = {};
  Map<String, Object?> _specs = {}, _wastani = {};
  List<Json> _consumables = [], _openLines = [];
  ProductionLists? _lists;
  String _error = '', _addError = '', _sentNote = '';
  String? _editingId;
  // batches handed over from Daily report › Upload a report: { date, forms, at }, one form at a time
  Json? _upload;
  bool _uploadClash = false, _uploadDone = false;
  String get uploadKey => 'mois.upload.queue.${session.organization?['id']}.$branchId';
  final Map<String, TextEditingController> _ctl = {};

  TextEditingController ctl(String k, String v) {
    final c = _ctl.putIfAbsent(k, () => TextEditingController(text: v));
    if (c.text != v && !_focused(k)) c.text = v;
    return c;
  }

  bool _focused(String k) => false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _rawId = (rawStores.where((w) => w.type == 'raw_materials').firstOrNull ?? rawStores.firstOrNull)?.id ?? '';
    // the unsaved list (and the batch being typed) from this phone
    try {
      final p = await SharedPreferences.getInstance();
      final saved = jsonDecode(p.getString(key) ?? 'null') as Map?;
      if (saved != null) {
        _staged = _l(saved['staged']);
        if (_staged.isNotEmpty) { _date = '${saved['date'] ?? today}'; _restored = true; }
        if (rawStores.any((w) => w.id == saved['rawId'])) _rawId = '${saved['rawId']}';
        if (saved['form'] is Map) _form = _Form.from(Map<String, dynamic>.from(saved['form'] as Map))..teamId = ''..workerIds = null;
      }
    } catch (_) {}
    if (widget.preset != null) _form = _Form()..productId = widget.preset!.productId..colorId = widget.preset!.colorId;
    final r = await Future.wait<dynamic>([
      db.from('product_specs').select('product_id, spec_id, pcs_per_sqm, average_yield_per_bag'),
      db.from('production_consumables').select('material_id, unit_id, quantity_per_bag, category_ids, status').eq('branch_id', branchId).then<List>((v) => v).catchError((_) => <dynamic>[]),
      loadProductionLists(branchId),
    ]);
    _specs = {for (final s in r[0] as List) '${s['product_id']}': s['pcs_per_sqm']};
    _wastani = {for (final s in r[0] as List) '${s['product_id']}': s['average_yield_per_bag']};
    _consumables = _l(r[1]);
    _lists = r[2] as ProductionLists;
    await _readUpload();
    await Future.wait([_loadStock(), _loadOrders()]);
    if (mounted) setState(() => _ready = true);
    _bandsFor();
  }

  @override
  void didUpdateWidget(DayLog old) {
    super.didUpdateWidget(old);
    // a product sent from the planner or Stock starts a new batch form
    if (widget.preset != null && widget.preset!.at != old.preset?.at) {
      setState(() { _editingId = null; _form = _Form()..productId = widget.preset!.productId..colorId = widget.preset!.colorId; });
      _bandsFor();
    }
  }

  Future<void> _readUpload() async {
    try {
      final p = await SharedPreferences.getInstance();
      final q = jsonDecode(p.getString(uploadKey) ?? 'null') as Map?;
      if (q == null || (q['forms'] as List? ?? []).isEmpty) return;
      final up = Map<String, dynamic>.from(q);
      // the listed batches all save under one date: a different day waits until they are saved or cleared
      if (_staged.isNotEmpty && _date != up['date']) { _upload = up; _uploadClash = true; return; }
      final forms = up['forms'] as List;
      final at = n(up['at'] ?? 0).toInt().clamp(0, forms.length - 1);
      _uploadClash = false;
      _date = '${up['date']}';
      _editingId = null;
      _form = _Form.from(Map<String, dynamic>.from(forms[at] as Map));
      _upload = {...up, 'next': at + 1};
    } catch (_) {}
  }

  Future<void> _storeUpload(Json? q) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (q == null) {
        await p.remove(uploadKey);
      } else {
        await p.setString(uploadKey, jsonEncode(q));
      }
    } catch (_) {}
  }

  /// after a batch is added: the next uploaded batch, if any
  bool _nextFromUpload() {
    final u = _upload;
    if (u == null || u['next'] == null || _uploadClash) return false;
    final forms = u['forms'] as List, next = n(u['next']).toInt();
    if (next < forms.length) {
      _form = _Form.from(Map<String, dynamic>.from(forms[next] as Map));
      _storeUpload({'date': u['date'], 'forms': forms, 'at': next});
      _upload = {...u, 'next': next + 1};
      _bandsFor();
      return true;
    }
    _storeUpload(null);
    _upload = null;
    _uploadDone = true;
    return false;
  }

  Future<void> _keep() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(key, jsonEncode({'date': _date, 'rawId': _rawId, 'form': _form.toJson(), 'staged': _staged, 'at': DateTime.now().toIso8601String()}));
    } catch (_) {}
  }

  void _set(void Function() f) {
    setState(() { _addError = ''; f(); });
    _keep();
    _bandsFor();
  }

  Future<void> _loadStock() async {
    if (_rawId.isEmpty) return;
    final ids = rawStores.map((w) => w.id).toList();
    try {
      final d = await db.from('stock_balances').select('warehouse_id, material_id, quantity').inFilter('warehouse_id', ids.isEmpty ? [_rawId] : ids).not('material_id', 'is', null);
      final by = <String, Map<String, double>>{};
      for (final x in d) { (by['${x['warehouse_id']}'] ??= {})['${x['material_id']}'] = n(x['quantity']).toDouble(); }
      _otherStock = by;
      _stock = by[_rawId] ?? {};
      if (mounted) setState(() {});
    } catch (_) {}
  }

  // open production orders: each product cast can count towards one (048)
  Future<void> _loadOrders() async {
    try {
      final d = await db.from('production_order_lines').select('id, product_id, color_id, pieces, order:production_orders!inner(id, order_no, reference, due_date, status, branch_id)')
          .eq('order.branch_id', branchId).eq('order.status', 'open');
      final lines = _l(d);
      if (lines.isEmpty) { _openLines = []; return; }
      final g = await db.from('production_order_line_progress').select('line_id, passed, curing').inFilter('line_id', [for (final l in lines) l['id']]);
      final done = {for (final x in g) '${x['line_id']}': n(x['passed']) + n(x['curing'])};
      _openLines = [for (final l in lines) {...l, 'left': (n(l['pieces']) - (done['${l['id']}'] ?? 0)).clamp(0, double.infinity)}]
        ..sort((a, b) {
          final c = '${a['order']['due_date'] ?? '9999'}'.compareTo('${b['order']['due_date'] ?? '9999'}');
          return c != 0 ? c : n(a['order']['order_no']).compareTo(n(b['order']['order_no']));
        });
    } catch (_) {
      _openLines = [];
    }
  }

  void _bandsFor() {
    for (final o in _outputs) {
      final id = o.productId;
      if (id.isEmpty || _bands.containsKey(id)) continue;
      _bands[id] = null;
      db.rpc('product_yield_band', params: {'p_product_id': id, 'p_branch_id': branchId}).then((d) {
        if (mounted) setState(() => _bands[id] = ((d as List?)?.firstOrNull as Map?)?.cast<String, dynamic>());
      }).catchError((_) {});
    }
  }

  Item? get main => refs.items['p:${_form.productId}'];
  List<String> get colours => main?.colorIds ?? [];
  double? get bags => _num(_form.bags);
  String sym(Object? id) => refs.unit('$id');
  String stockSym(Object? m) => refs.unit(refs.items['m:$m']?.stockUnitId);
  CategoryTools get cats => CategoryTools(refs.categoryRows);

  /// the branch's active recipe for the main product's category + colour (the server picks the same)
  Json? get recipe {
    final m = main;
    if (m == null || (colours.isNotEmpty && _form.colorId.isEmpty)) return null;
    final c = widget.recipes.where((r) => r['branch_id'] == branchId && r['category_id'] == m.categoryId && '${r['color_id'] ?? ''}' == _form.colorId).toList()
      ..sort((a, b) {
        int has(Json r) => _l(r['products']).any((x) => x['product_id'] == m.id) ? 1 : 0;
        var c = has(b) - has(a);
        if (c != 0) return c;
        c = '${b['effective_date'] ?? ''}'.compareTo('${a['effective_date'] ?? ''}');
        return c != 0 ? c : n(b['version_number']).compareTo(n(a['version_number']));
      });
    return c.firstOrNull;
  }

  Map<String, double> get usedToday {
    final u = <String, double>{};
    for (final s in _staged.where((x) => x['payload']['raw_warehouse_id'] == _rawId)) {
      for (final m in _l(s['payload']['materials'])) {
        u['${m['material_id']}'] = (u['${m['material_id']}'] ?? 0) + n(m['quantity']) * (stockFactorOf(refs, m['material_id'], m['unit_id']) ?? 0);
      }
      for (final c in _l(s['consumables'])) { u['${c['materialId']}'] = (u['${c['materialId']}'] ?? 0) + n(c['need']); }
    }
    return u;
  }

  bool isSteel(Object? m) => RegExp('steel|chuma', caseSensitive: false).hasMatch(refs.items['m:$m']?.materialCategory ?? '');

  List<Json> get recipeItems => _l(recipe?['items']).where((it) => refs.items['m:${it['material_id']}']?.inRecipes != false).toList()
    ..sort((a, b) {
      final x = refs.items['m:${a['material_id']}'], y = refs.items['m:${b['material_id']}'];
      if (x == null || y == null) return 0;
      return byMaterialOrder(x, y);
    });

  /// materials: recipe × bags (cement = the bags), each editable; checked against the store minus the day's list
  List<Json> get lines {
    final used = usedToday;
    return [
      for (final it in recipeItems)
        () {
          final isBag = sym(it['unit_id']).toLowerCase() == 'bag' && n(it['quantity']) == 1;
          final edited = _form.edits['${it['material_id']}'];
          final quantity = edited != null ? _num(edited) : bags != null ? _round(n(it['quantity']) * bags!) : 0.0;
          final f = stockFactorOf(refs, it['material_id'], it['unit_id']);
          final need = quantity != null && f != null ? quantity * f : null;
          final available = (_stock['${it['material_id']}'] ?? 0) - (used['${it['material_id']}'] ?? 0);
          return {...it, 'factor': f, 'isBag': isBag, 'edited': edited != null, 'quantity': quantity, 'need': need, 'available': available,
            'short': need != null && need > available + 1e-9, 'source': isBag || edited != null ? 'counted' : 'recipe'};
        }(),
    ];
  }

  /// consumables a bag (138): mafuta, sabuni — set in Costing, taken with the batch by the server
  List<Json> get consLines {
    if (recipe == null) return [];
    final used = usedToday;
    final mainCat = main?.categoryId;
    final mainGroup = cats.byId[mainCat]?['parent_category_id'];
    final ls = lines;
    return [
      for (final c in _consumables)
        if ((c['category_ids'] as List? ?? []).any((id) => id == mainCat || id == mainGroup) && !ls.any((l) => l['material_id'] == c['material_id']))
          () {
            final quantity = bags != null ? (n(c['quantity_per_bag']) * bags! * 1000).roundToDouble() / 1000 : 0.0;
            final f = stockFactorOf(refs, c['material_id'], c['unit_id']);
            final need = f != null ? quantity * f : quantity;
            final available = (_stock['${c['material_id']}'] ?? 0) - (used['${c['material_id']}'] ?? 0);
            final on = c['status'] == 'active';   // an Off row shows, muted, but takes nothing and never blocks
            return {'material_id': c['material_id'], 'unit_id': c['unit_id'], 'quantity': quantity, 'factor': f, 'need': on ? need : 0, 'available': available, 'short': on && need > available + 1e-9, 'on': on};
          }(),
    ];
  }

  /// a residual's colour is the main product's (by name); a plain main product's residuals are White
  String residualColour(Item? item) {
    if (item == null || item.colorIds.isEmpty) return '';
    if (_form.colorId.isNotEmpty && item.colorIds.contains(_form.colorId)) return _form.colorId;
    final want = (_form.colorId.isNotEmpty ? refs.colour(_form.colorId) : 'White').toLowerCase();
    return item.colorIds.where((id) => refs.colour(id).toLowerCase() == want).firstOrNull ?? '';
  }

  List<Item> get carried => refs.items.values.where((i) => i.kind == 'product' && i.status == 'active' && (refs.carriedByBranch[branchId]?.contains(i.id) ?? false)).toList()..sort(productOrder(cats));

  List<Json> orderLinesFor(String productId, String colorId) => _openLines.where((l) => l['product_id'] == productId && '${l['color_id'] ?? ''}' == colorId).toList();
  String orderLineOf(String productId, String colorId) {
    final c = orderLinesFor(productId, colorId);
    final pick = _form.orderPick[productId];
    if (pick == 'none') return '';
    if (pick != null && c.any((l) => l['id'] == pick)) return pick;
    return '${(c.where((l) => n(l['left']) > 0).firstOrNull ?? c.firstOrNull)?['id'] ?? ''}';
  }

  List<({String productId, String colorId, double? pieces, bool primary})> get _outputs => [
        if (main != null) (productId: main!.id, colorId: _form.colorId, pieces: _num(_form.pieces), primary: true),
        for (final l in _form.leftovers)
          if ((l['productId'] ?? '').isNotEmpty) (productId: l['productId']!, colorId: residualColour(refs.items['p:${l['productId']}']), pieces: _num(l['pieces'] ?? ''), primary: false),
      ];

  double? sqmOf(String productId, double? pcs) {
    final it = refs.items['p:$productId'];
    final sqm = sym(it?.stockUnitId).toUpperCase() == 'SQM';
    return sqm && n(_specs[productId]) > 0 && pcs != null ? pcs / n(_specs[productId]) : null;
  }

  String? _curingId(String machineCure) {
    final cands = [_form.curingId, machineCure];
    return cands.where((id) => id.isNotEmpty && curingStores.any((w) => w.id == id)).firstOrNull ?? (curingStores.length == 1 ? curingStores.first.id : null);
  }

  void _addToList() {
    final outputs = _outputs;
    final ls = lines, cons = consLines;
    final shortLines = [...ls, ...cons].where((l) => l['short'] == true).toList();
    final totalPieces = outputs.fold<double>(0, (s, o) => s + (o.pieces ?? 0));
    final counted = outputs.where((o) => (o.pieces ?? 0) > 0).toList();
    final allBanded = counted.isNotEmpty && counted.every((o) => n(_bands[o.productId]?['average_yield_per_bag']) > 0);
    final theoretical = allBanded ? counted.fold<double>(0, (s, o) => s + o.pieces! / n(_bands[o.productId]!['average_yield_per_bag'])) : null;
    final bagsMin = allBanded ? counted.fold<double>(0, (s, o) => s + o.pieces! / n(_bands[o.productId]!['yield_max'])) : null;
    final bagsMax = allBanded && counted.every((o) => n(_bands[o.productId]!['yield_min']) > 0) ? counted.fold<double>(0, (s, o) => s + o.pieces! / n(_bands[o.productId]!['yield_min'])) : null;
    final outOfBand = theoretical != null && (bags ?? 0) > 0 && totalPieces > 0 && (bags! < bagsMin! - 1e-9 || (bagsMax != null && bags! > bagsMax + 1e-9));
    final mainBand = _bands[_form.productId];
    final expected = n(mainBand?['average_yield_per_bag']) > 0 && (bags ?? 0) > 0 ? (bags! * n(mainBand!['average_yield_per_bag'])).roundToDouble() : null;
    final noWastani = outputs.where((o) => _bands.containsKey(o.productId) && _bands[o.productId] != null && !(n(_bands[o.productId]?['average_yield_per_bag']) > 0)).toList();
    final lists = _lists;
    final machineCure = '${lists?.machines.where((m) => m['id'] == _form.machineId).firstOrNull?['curing_warehouse_id'] ?? ''}';
    final cureId = _curingId(machineCure);
    void fail(String m) => setState(() => _addError = m);
    if (main == null) return fail('Choose the product.');
    if (colours.isNotEmpty && _form.colorId.isEmpty) return fail('Choose the colour.');
    if (recipe == null) return fail('No active recipe for this product and colour at this branch — add one under Recipes.');
    if (!((bags ?? 0) > 0)) return fail('Enter the bags of cement used.');
    if (outputs.any((o) => o.pieces == null || o.pieces! < 0 || o.pieces != o.pieces!.roundToDouble())) return fail('Enter the pieces cast for each product (whole numbers).');
    if (totalPieces == 0) return fail('Enter the pieces cast.');
    if (shortLines.isNotEmpty) return fail('Not enough stock — the branch manager should check the stock first.');
    if (noWastani.isNotEmpty) return fail('Set the wastani for ${noWastani.map((o) => refs.items['p:${o.productId}']?.name).join(', ')} first.');
    if (_form.leftovers.any((l) => (l['productId'] ?? '').isEmpty)) return fail('Choose each leftover product, or remove the empty row.');
    final noColour = outputs.where((o) => !o.primary && (refs.items['p:${o.productId}']?.colorIds.isNotEmpty ?? false) && o.colorId.isEmpty).firstOrNull;
    if (noColour != null) return fail('Choose the colour for ${refs.items['p:${noColour.productId}']?.name}.');
    final tracked = lists?.ready ?? false;
    if (tracked && _form.teamId.isEmpty) return fail('Choose the team that made this batch (or + New team).');
    if (tracked && _form.machineId.isEmpty) return fail('Choose the machine it was made on (or + New machine).');
    if (tracked && (_form.workerIds?.isEmpty ?? true)) return fail('Tick who worked on this batch (the people chip).');
    if (cureId == null) return fail('Choose where this batch cures.');
    final payload = {
      'batch_date': _date, 'raw_warehouse_id': _rawId, 'curing_warehouse_id': cureId, 'color_id': _form.colorId.isEmpty ? null : _form.colorId,
      'recipe_version_id': recipe!['id'], 'cement_bags': bags, 'notes': _form.notes.trim().isEmpty ? null : _form.notes.trim(), 'allow_other_products': _form.allowOther,
      if (tracked) ...{'team_id': _form.teamId, 'machine_id': _form.machineId, 'worker_ids': ?_form.workerIds},
      'outputs': [
        for (final o in outputs)
          {'product_id': o.productId, 'pieces': o.pieces?.round(), 'primary': o.primary, if (!o.primary) 'color_id': o.colorId.isEmpty ? null : o.colorId,
            if (orderLineOf(o.productId, o.colorId).isNotEmpty) 'order_line_id': orderLineOf(o.productId, o.colorId)},
      ],
      'materials': [for (final l in ls) {'material_id': l['material_id'], 'unit_id': l['unit_id'], 'quantity': l['quantity'] ?? 0, 'source': l['source']}],
    };
    final colourTxt = _form.colorId.isNotEmpty ? ' ${refs.colour(_form.colorId)}' : '';
    final item = {
      'id': _editingId ?? const Uuid().v4(), 'payload': payload, 'form': _form.toJson(), 'label': '${main!.name}$colourTxt', 'category': main!.category, 'bags': bags,
      'outputs': [
        for (final o in outputs)
          {'productId': o.productId, 'name': '${refs.items['p:${o.productId}']?.name}${o.colorId.isNotEmpty ? ' ${refs.colour(o.colorId)}' : ''}',
            'order': _openLines.where((l) => l['id'] == orderLineOf(o.productId, o.colorId)).firstOrNull?['order']?['order_no'],
            'pieces': o.pieces, 'sqm': sqmOf(o.productId, o.pieces), 'residual': !o.primary, 'wastani': _bands[o.productId]?['average_yield_per_bag']},
      ],
      'consumables': [for (final c in cons) if (c['on'] == true) {'materialId': c['material_id'], 'need': c['need']}],
      'factor': theoretical != null ? theoretical / bags! : null, 'theoretical': theoretical, 'outOfBand': outOfBand, 'expected': expected, 'notes': _form.notes.trim(),
      'team': tracked ? teamLabel(lists, _form.teamId, _form.workerIds) : null,
      'machine': tracked ? (lists!.machines.where((m) => m['id'] == _form.machineId).firstOrNull?['name']) : null,
    };
    _set(() {
      _staged = _editingId != null ? [for (final x in _staged) x['id'] == _editingId ? item : x] : [..._staged, item];
      final wasEditing = _editingId != null;
      _editingId = null;
      if (wasEditing || !_nextFromUpload()) _form = _form.next();
    });
  }

  List<Json> _costInput() => [
        for (final b in _staged)
          {'materials': b['payload']['materials'], 'outputs': [for (final o in _l(b['outputs'])) {'pieces': o['pieces'], 'perBag': o['wastani'], 'sqm': o['sqm']}]},
      ];

  Future<void> _confirm() async {
    setState(() { _error = ''; _busy = true; });
    // before saving: the same product, colour and bags already recorded (or sent for approval) on this date
    final r = await Future.wait<dynamic>([
      db.from('production_batches').select('product_id, color_id, cement_bags, created_at').eq('branch_id', branchId).eq('batch_date', _date).neq('status', 'void'),
      db.from('pending_changes').select('payload, requested_at').eq('kind', 'production_day').eq('status', 'pending'),
      estimateBatchCosts(refs, branchId, _costInput()).catchError((_) => <({double cost, bool complete, List<({double? perPiece, double? perSqm})> outputs})>[]),
    ]);
    final seen = [
      for (final b in r[0] as List) (product: '${b['product_id']}', color: '${b['color_id'] ?? ''}', bags: n(b['cement_bags']), how: 'saved', at: b['created_at']),
      for (final x in r[1] as List)
        for (final b in _l(x['payload']?['batches']))
          if (b['batch_date'] == _date)
            (product: '${_l(b['outputs']).where((o) => o['primary'] == true).firstOrNull?['product_id']}', color: '${b['color_id'] ?? ''}', bags: n(b['cement_bags']), how: 'waiting for approval', at: x['requested_at']),
    ];
    final already = [
      for (final st in _staged)
        () {
          final mainId = '${_l(st['payload']['outputs']).where((o) => o['primary'] == true).firstOrNull?['product_id']}';
          final m = seen.where((x) => x.product == mainId && x.color == '${st['payload']['color_id'] ?? ''}' && x.bags == n(st['payload']['cement_bags'])).firstOrNull;
          return m == null ? null : '${st['label']} · ${qtyText(n(st['bags']))} bags — ${m.how} ${dateTimeText(m.at)}';
        }(),
    ].whereType<String>().toList();
    final est = r[2] as List;
    if (!mounted) return;
    setState(() => _busy = false);
    final peopleIn = [for (final b in _staged) if ((_lists?.ready ?? false) && b['payload']['team_id'] != null) (b['payload']['worker_ids'] as List? ?? []).map((e) => '$e').toList()];
    final people = peopleIn.isEmpty ? null : {for (final p in peopleIn) ...p}.length;
    final norm = peopleIn.isEmpty
        ? null
        : labourNorm(_lists, [for (final b in _staged) (machineId: b['payload']['machine_id'] as String?, bags: n(b['bags']).toDouble(), productId: '${_l(b['payload']['outputs']).where((o) => o['primary'] == true).firstOrNull?['product_id']}')]);
    final used = <String, double>{};
    final mats = <String, ({String name, String unit, int rank})>{};
    for (final b in _staged) {
      for (final m in _l(b['payload']['materials'])) {
        used['${m['material_id']}'] = 0;
        mats['${m['material_id']}'] = (name: refs.items['m:${m['material_id']}']?.name ?? '—', unit: sym(m['unit_id']), rank: refs.items['m:${m['material_id']}']?.rank ?? 999);
      }
    }
    final ut = usedToday;
    final save = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (ctx) => FullPage(
          title: viaApproval ? 'Submit this production for approval?' : 'Confirm daily production',
          footer: [
            OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back to edit')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(already.isNotEmpty ? (viaApproval ? 'Submit anyway' : 'Save anyway') : viaApproval ? 'Submit for approval' : 'Confirm & save')),
          ],
          children: [
            if (already.isNotEmpty) ...[
              Alert('${dateText(_date)} may already be recorded. These look like batches already saved or waiting for approval for this date — saving again counts them twice:\n${already.map((a) => '• $a').join('\n')}\nSave only if these are extra batches.', tone: Tone.warning),
              const SizedBox(height: 10),
            ],
            DaySummary(
              date: _date, branchName: session.branchName ?? '', curingDays: widget.curingDays, people: people, norm: norm,
              curingUntil: iso(DateTime.parse(_date).add(Duration(days: widget.curingDays))),
              batches: [
                for (final (i, b) in _staged.indexed)
                  _bBatch(i, b, est.length > i ? est[i] : null, people: (_lists?.ready ?? false) && b['payload']['team_id'] != null ? (b['payload']['worker_ids'] as List? ?? []).length : null),
              ],
              left: [
                for (final e in mats.entries)
                  (name: e.value.name, label: materialShortName(refs.items['m:${e.key}']), left: (_stock[e.key] ?? 0) - (ut[e.key] ?? 0), unit: stockSym(e.key),
                      short: (_stock[e.key] ?? 0) - (ut[e.key] ?? 0) < -1e-9, rank: e.value.rank),
              ],
            ),
          ],
        )));
    if (save == true) _saveDay();
  }

  BBatch _bBatch(int i, Json b, dynamic est, {int? people}) => BBatch(
        n: i + 1, bags: n(b['bags']).toDouble(), team: b['team'], machine: b['machine'], people: people,
        cost: est?.cost, costComplete: est?.complete, estimate: est != null,
        outputs: [
          for (final (j, o) in _l(b['outputs']).indexed)
            BOut(name: '${o['name']}', pieces: o['pieces'] as num?, residual: o['residual'] == true, perBag: o['wastani'] as num?,
                perPiece: est != null && est.outputs.length > j ? est.outputs[j].perPiece : null, perSqm: est != null && est.outputs.length > j ? est.outputs[j].perSqm : null),
        ],
        materials: breakdownMaterials(_l(b['payload']['materials']), refs),
      );

  Future<void> _saveDay() async {
    setState(() { _error = ''; _sentNote = ''; _busy = true; });
    final batches = [for (final s in _staged) {...(s['payload'] as Map), 'batch_date': _date}];
    final bagsTotal = _round(_staged.fold<double>(0, (s, x) => s + n(x['bags'])));
    final made = _staged.expand((s) => _l(s['outputs']).map((o) => '${n(o['pieces']).round()} ${o['name']}')).join(', ');
    try {
      if (viaApproval) {
        await db.rpc('request_change', params: {'p_kind': 'production_day', 'p_branch_id': null, 'p_payload': {'batches': batches},
          'p_summary': 'Production of ${dateText(_date)} at ${session.branchName}: ${_staged.length} batch${_staged.length == 1 ? '' : 'es'}, ${qtyText(bagsTotal)} bags — $made'});
      } else {
        await db.rpc('record_production_batches', params: {'p': {'batches': batches}});
      }
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e, "We couldn't save these batches. Please try again."); });
      _loadStock();
      return;
    }
    setState(() { _busy = false; _staged = []; });
    try { (await SharedPreferences.getInstance()).remove(key); } catch (_) {}
    _loadStock();
    if (viaApproval) {
      setState(() => _sentNote = "Sent for approval — ${dateText(_date)}'s batches are recorded once an admin approves (Approvals).");
      return;
    }
    _loadOrders();
    widget.onSaved();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    if (!_ready) return const Skeleton(rows: 6);
    if (curingStores.isEmpty) return PlHelp('${session.branchName} has no curing store yet.');
    final m = main;
    final rc = recipe;
    final ls = lines, cons = consLines;
    final shortLines = [...ls, ...cons].where((l) => l['short'] == true).toList();
    final betterStore = shortLines.isEmpty
        ? null
        : rawStores.where((w) => w.id != _rawId && shortLines.every((l) => (_otherStock[w.id]?['${l['material_id']}'] ?? 0) + 1e-9 >= n(l['need'] ?? double.infinity))).firstOrNull;
    final outputs = _outputs;
    final mainBand = _bands[_form.productId];
    final expected = n(mainBand?['average_yield_per_bag']) > 0 && (bags ?? 0) > 0 ? (bags! * n(mainBand!['average_yield_per_bag'])).roundToDouble() : null;
    final totalPieces = outputs.fold<double>(0, (s, o) => s + (o.pieces ?? 0));
    final counted = outputs.where((o) => (o.pieces ?? 0) > 0).toList();
    final unbanded = counted.where((o) => !(n(_bands[o.productId]?['average_yield_per_bag']) > 0)).toList();
    final allBanded = counted.isNotEmpty && unbanded.isEmpty;
    final theoretical = allBanded ? counted.fold<double>(0, (s, o) => s + o.pieces! / n(_bands[o.productId]!['average_yield_per_bag'])) : null;
    final bagsMin = allBanded ? counted.fold<double>(0, (s, o) => s + o.pieces! / n(_bands[o.productId]!['yield_max'])) : null;
    final bagsMax = allBanded && counted.every((o) => n(_bands[o.productId]!['yield_min']) > 0) ? counted.fold<double>(0, (s, o) => s + o.pieces! / n(_bands[o.productId]!['yield_min'])) : null;
    final outOfBand = theoretical != null && (bags ?? 0) > 0 && totalPieces > 0 && (bags! < bagsMin! - 1e-9 || (bagsMax != null && bags! > bagsMax + 1e-9));
    final mainPieces = _num(_form.pieces);
    final mainYield = n(_bands[_form.productId]?['average_yield_per_bag']);
    final mixPieces = mainPieces == null
        ? null
        : outputs.fold<double>(0, (tt, o) {
            if (!((o.pieces ?? 0) > 0)) return tt;
            final y = n(_bands[o.productId]?['average_yield_per_bag']);
            return tt + (mainYield > 0 && y > 0 ? o.pieces! * (mainYield / y) : o.pieces!);
          });
    final hasResidual = outputs.any((o) => !o.primary && (o.pieces ?? 0) > 0);
    final stagedBags = _round(_staged.fold<double>(0, (s, b) => s + n(b['bags'])));
    final leftoverChoices = carried.where((i) => i.id != _form.productId && (_form.allowOther || i.categoryId == m?.categoryId) && (i.colorIds.isEmpty || residualColour(i).isNotEmpty)).toList();
    final machineCure = '${_lists?.machines.where((x) => x['id'] == _form.machineId).firstOrNull?['curing_warehouse_id'] ?? ''}';
    final cureId = _curingId(machineCure);
    Widget orderPick(String productId, String colorId) {
      final c = orderLinesFor(productId, colorId);
      if (c.isEmpty) return const SizedBox.shrink();
      return DropdownButtonFormField<String>(
        initialValue: orderLineOf(productId, colorId).isEmpty ? 'none' : orderLineOf(productId, colorId), isExpanded: true, decoration: const InputDecoration(labelText: 'For order'),
        items: [
          for (final l in c) DropdownMenuItem(value: '${l['id']}', child: Text('Order ${l['order']['order_no']}${l['order']['reference'] != null ? ' · ${l['order']['reference']}' : ''} · ${qtyText(n(l['left']))} to go', overflow: TextOverflow.ellipsis)),
          const DropdownMenuItem(value: 'none', child: Text('No order')),
        ],
        onChanged: (v) => _set(() => _form.orderPick = {..._form.orderPick, productId: v ?? 'none'}),
      );
    }

    Widget colourChip(String id) => id.isEmpty ? const SizedBox.shrink() : ColourDot(refs.colour(id));
    Widget card(String title, List<Widget> children) => Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(12)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [PlLabel(title), const SizedBox(height: 8), ...children]),
        );

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_uploadClash && _upload != null)
        Alert('An uploaded report for ${dateText(_upload!['date'])} is waiting. Save or clear the ${_staged.length} batch${_staged.length == 1 ? '' : 'es'} listed for ${dateText(_date)} first, then open it again from Daily report.', tone: Tone.warning),
      if (!_uploadClash && _upload?['next'] != null)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: BoxDecoration(color: t.bgInfo, borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Expanded(child: Text('From the uploaded report: batch ${_upload!['next']} of ${(_upload!['forms'] as List).length}. Check the materials, then Add to list.', style: const TextStyle(fontSize: Fs.sm))),
            TextButton(onPressed: () => _set(() { if (!_nextFromUpload()) _form = _form.next(); }), child: const Text('Skip this batch')),
          ]),
        ),
      if (_uploadDone && _staged.isNotEmpty) const Alert('Uploaded batches are on the list.', tone: Tone.info),
      if (_restored && _staged.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Alert('Your unsaved list from earlier is back: ${_staged.length} batch${_staged.length == 1 ? '' : 'es'} not saved yet, dated ${dateText(_date)}.', tone: Tone.info)),
      Row(children: [
        if (rawStores.length > 1) ...[
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _rawId, isExpanded: true, decoration: const InputDecoration(labelText: 'From'),
              items: [for (final w in rawStores) DropdownMenuItem(value: w.id, child: Text(w.name, overflow: TextOverflow.ellipsis))],
              onChanged: _staged.isNotEmpty ? null : (v) { _set(() => _rawId = v ?? ''); _loadStock(); },
            ),
          ),
          const SizedBox(width: 8),
        ],
        Expanded(child: DateField(label: 'Date', value: _date, last: today, onChange: (v) => _set(() => _date = v))),
      ]),
      const SizedBox(height: 12),

      // 1 · batch mix recipe scaling
      card('Batch mix recipe scaling', [
        const PlLabel('Primary product'),
        if (m != null)
          Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(m.name, style: const TextStyle(fontSize: Fs.lg, fontWeight: FontWeight.w700)),
            colourChip(_form.colorId),
            Badge2(m.category ?? ''),
            if (n(mainBand?['average_yield_per_bag']) > 0) Badge2('Wastani: ${qtyText(n(mainBand!['average_yield_per_bag']))} pcs/bag', tone: Tone.info),
          ])
        else
          Text('Choose a product', style: TextStyle(fontSize: Fs.lg, color: t.textMuted)),
        if (m != null && _bands.containsKey(m.id) && _bands[m.id] != null && !(n(mainBand?['average_yield_per_bag']) > 0)) _wastaniMissing(m),
        const SizedBox(height: 8),
        Row(children: [
          OutlinedButton(
            onPressed: () async {
              final id = await pickProduct(context, items: carried, cats: cats, usage: widget.usage, wastani: _wastani);
              if (id != null) _set(() => _form = (_form.next()..productId = id..machineId = _form.machineId));
            },
            child: Text(m != null ? 'Change' : 'Choose product…'),
          ),
          if (colours.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: SlideRow(children: [
                for (final c in colours) Chip2(refs.colour(c), on: _form.colorId == c, onTap: () => _set(() { _form.colorId = c; _form.leftovers = []; _form.edits = {}; })),
              ]),
            ),
          ],
        ]),
        const SizedBox(height: 10),
        if (rc == null)
          PlHelp(m != null && (colours.isEmpty || _form.colorId.isNotEmpty) ? 'No active recipe for ${m.name} ${refs.colour(_form.colorId)} — add one under Recipes.' : 'Choose the product and colour.')
        else ...[
          PlHelp('Baseline: ${recipeItems.where((it) => !isSteel(it['material_id'])).map((it) => '${qtyText(n(it['quantity']))}${sym(it['unit_id']).length <= 3 ? ' ${sym(it['unit_id'])}' : ''} ${materialShortName(refs.items['m:${it['material_id']}'])}').join(' : ')}'),
          const SizedBox(height: 8),
          // recipe tiles (LOCKED): short name on top, the amount big and editable, its unit small
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final l in ls.where((l) => !isSteel(l['material_id'])))
              Container(
                width: 104,
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
                decoration: BoxDecoration(
                  color: l['short'] == true ? t.bgError : t.soft,
                  border: Border.all(color: l['short'] == true ? C.error : l['edited'] == true ? C.khaki : t.border),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(materialShortName(refs.items['m:${l['material_id']}']).toUpperCase(), style: TextStyle(fontSize: Fs.xs, color: t.textMuted, letterSpacing: 0.4)),
                  Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Expanded(
                      child: TextField(
                        controller: ctl('mat:${l['material_id']}:${_form.productId}:${_form.colorId}:${_form.bags}', l['quantity'] == null ? '' : p6x(l['quantity'] as num)),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        style: const TextStyle(fontSize: Fs.lg, fontWeight: FontWeight.w700),
                        decoration: const InputDecoration(isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 4), border: InputBorder.none, enabledBorder: InputBorder.none, filled: false),
                        onChanged: (v) => _set(() => _form.edits = {..._form.edits, '${l['material_id']}': v}),
                      ),
                    ),
                    Text(sym(l['unit_id']), style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                  ]),
                  if (l['short'] == true)
                    Text('Short ${qtyText(_round(l['factor'] != null ? (n(l['need']) - n(l['available'])) / n(l['factor']) : n(l['need']) - n(l['available']), 2))} ${l['factor'] != null ? sym(l['unit_id']) : stockSym(l['material_id'])}',
                        style: const TextStyle(fontSize: 10, color: C.error)),
                  if (l['edited'] == true)
                    InkWell(onTap: () => _set(() => _form.edits = {..._form.edits}..remove('${l['material_id']}')), child: const Text('↺ recipe', style: TextStyle(fontSize: 10, color: C.khaki))),
                ]),
              ),
          ]),
          if (ls.any((l) => isSteel(l['material_id']))) ...[
            const SizedBox(height: 8),
            const PlLabel('Steel'),
            for (final l in ls.where((l) => isSteel(l['material_id'])))
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: TextField(
                  controller: ctl('steel:${l['material_id']}:${_form.productId}:${_form.bags}', l['quantity'] == null ? '' : p6x(l['quantity'] as num)),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: refs.items['m:${l['material_id']}']?.name, suffixText: sym(l['unit_id']),
                      errorText: l['short'] == true ? 'Short ${qtyText(_round(l['factor'] != null ? (n(l['need']) - n(l['available'])) / n(l['factor']) : n(l['need']) - n(l['available']), 2))}' : null),
                  onChanged: (v) => _set(() => _form.edits = {..._form.edits, '${l['material_id']}': v}),
                ),
              ),
          ],
          // consumables a bag (138): mafuta · sabuni from the bags — not in the recipe
          if (cons.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: PlHelp(cons.map((c) => '${refs.items['m:${c['material_id']}']?.name} ${qtyText(n(c['quantity']))} ${sym(c['unit_id'])}'
                  '${c['short'] == true ? ' (short ${qtyText(_round(c['factor'] != null ? (n(c['need']) - n(c['available'])) / n(c['factor']) : n(c['need']) - n(c['available']), 2))})' : ''}${c['on'] != true ? ' (off)' : ''}').join(' · ')),
            ),
        ],
        if (shortLines.isNotEmpty) ...[
          const SizedBox(height: 8),
          Alert('Not enough ${shortLines.map((l) => refs.items['m:${l['material_id']}']?.name).join(', ')} in ${refs.store(_rawId)?.name ?? 'this store'}.${betterStore != null ? '' : ' The branch manager should check the stock.'}',
              tone: Tone.error, action: betterStore != null ? TextButton(onPressed: () { _set(() => _rawId = betterStore.id); _loadStock(); }, child: Text('Use ${betterStore.name}')) : null),
        ],
      ]),

      // 2 · main batch output
      card('Main batch output', [
        PlHelp('Mold : ${m?.category ?? '—'}'),
        Row(children: [Text(m?.name ?? '—', style: const TextStyle(fontSize: Fs.lg, fontWeight: FontWeight.w700)), const SizedBox(width: 6), colourChip(_form.colorId)]),
        if (m != null) orderPick(m.id, _form.colorId),
        const SizedBox(height: 6),
        PlHelp('Expected output (${(bags ?? 0) > 0 ? qtyText(bags!) : '—'} bags × ${mainYield > 0 ? qtyText(mainYield) : 'wastani'})'),
        Text(expected != null ? '${qtyText(expected)} pcs${sqmOf(m!.id, expected) != null ? ' (${qtyText(_round(sqmOf(m.id, expected)!, 2))} m²)' : ''}' : '—', style: const TextStyle(fontSize: Fs.lg, fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: ctl('bags', _form.bags), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Cement bags'), onChanged: (v) => _set(() => _form.bags = v))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: ctl('pieces', _form.pieces), keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Counted pcs'), onChanged: (v) => _set(() => _form.pieces = v))),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const PlLabel('Average'),
            Text(mixPieces != null && (bags ?? 0) > 0 ? '${qtyText(_round(mixPieces / bags!, 1))} pcs/bag' : '—', style: const TextStyle(fontWeight: FontWeight.w700)),
            if (hasResidual && mainPieces != null && (bags ?? 0) > 0) PlHelp('main only ${qtyText(_round(mainPieces / bags!, 1))}'),
          ])),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const PlLabel('Actual yield'),
            Text(m != null && mainPieces != null && sqmOf(m.id, mainPieces) != null ? '${qtyText(_round(sqmOf(m.id, mainPieces)!, 2))} m²' : mainPieces != null ? '${qtyText(mainPieces)} pcs' : '—', style: const TextStyle(fontWeight: FontWeight.w700)),
            if (m != null && mainPieces != null && sqmOf(m.id, mainPieces) != null) PlHelp('${qtyText(mainPieces)} pcs'),
          ])),
        ]),
        const SectionTitle('Residuals (secondary products)'),
        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          OutlinedButton.icon(
            onPressed: m == null
                ? null
                : () async {
                    final id = await pickProduct(context, title: 'Select residual product', items: leftoverChoices.where((c) => !_form.leftovers.any((x) => x['productId'] == c.id)).toList(), cats: cats, usage: widget.usage, wastani: _wastani);
                    // a new residual goes on top, its pieces box ready to type in
                    if (id != null) _set(() => _form.leftovers = [{'productId': id, 'pieces': ''}, ..._form.leftovers]);
                  },
            icon: const Icon(LucideIcons.plus, size: 14), label: const Text('Add residual product'),
          ),
          // only the box toggles it; residuals already entered stay — unticking drops those outside the main product's category
          if (isManager && m != null)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(
                value: _form.allowOther,
                onChanged: (v) => _set(() {
                  _form.allowOther = v ?? false;
                  if (!_form.allowOther) _form.leftovers = _form.leftovers.where((l) => (l['productId'] ?? '').isEmpty || refs.items['p:${l['productId']}']?.categoryId == m.categoryId).toList();
                }),
              ),
              const Text('Allow other products for this batch', style: TextStyle(fontSize: Fs.sm)),
            ]),
        ]),
        for (final (i, l) in _form.leftovers.indexed)
          Builder(builder: (_) {
            final it = refs.items['p:${l['productId']}'];
            final b = _bands[l['productId']];
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(it?.name ?? 'Choose residual product…', style: const TextStyle(fontWeight: FontWeight.w600))),
                  colourChip(residualColour(it)),
                  const SizedBox(width: 6),
                  SizedBox(width: 90, child: TextField(controller: ctl('res$i:${l['productId']}', l['pieces'] ?? ''), keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'Pcs', isDense: true),
                      onChanged: (v) => _set(() => _form.leftovers = [for (final (j, x) in _form.leftovers.indexed) j == i ? {...x, 'pieces': v} : x]))),
                  IconButton(tooltip: 'Remove residual', onPressed: () => _set(() => _form.leftovers = [..._form.leftovers]..removeAt(i)), icon: const Icon(LucideIcons.trash2, size: 16)),
                ]),
                if (it != null && n(b?['average_yield_per_bag']) > 0) PlHelp('Wastani: ${qtyText(n(b!['average_yield_per_bag']))} pcs/bag', color: C.khaki),
                if (it != null && b != null && !(n(b['average_yield_per_bag']) > 0)) _wastaniMissing(it),
                if (it != null) orderPick(it.id, residualColour(it)),
              ]),
            );
          }),
        // the yield factor alone: products, pieces and the cement implied in its help
        if ((theoretical != null && (bags ?? 0) > 0 && totalPieces > 0) || unbanded.isNotEmpty) ...[
          const SizedBox(height: 8),
          if (unbanded.isNotEmpty) PlHelp('No yield check until ${unbanded.map((o) => refs.items['p:${o.productId}']?.name).join(', ')} ${unbanded.length == 1 ? 'has' : 'have'} a wastani', color: C.warning),
          if (outOfBand) const PlHelp('Outside the band — flagged for review', color: C.warning),
          if (theoretical != null && (bags ?? 0) > 0 && totalPieces > 0)
            Tooltip(
              message: '${counted.map((o) => '${refs.items['p:${o.productId}']?.name ?? ''} ${qtyText(o.pieces!)} pcs').join(' + ')} → cement implied ${qtyText(_round(theoretical, 2))} of ${qtyText(bags!)} bags',
              child: Badge2('Yield factor: ${(theoretical / bags! * 1000).roundToDouble() / 10}%', tone: outOfBand ? Tone.warning : Tone.success),
            ),
        ],
        const SizedBox(height: 10),
        // team, who worked, machine and note belong to the batch: inside its card
        if (_lists != null)
          _BatchNotes(
            lists: _lists!, productId: _form.productId, date: _date, form: _form,
            reload: () async { final l = await loadProductionLists(branchId); if (mounted) setState(() => _lists = l); },
            onChange: (f) => _set(() {}),
          ),
        // where it cures (135): asked only when the branch has several and the machine has none
        if (curingStores.length > 1) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: cureId, isExpanded: true, decoration: const InputDecoration(labelText: 'Cures in'),
            items: [for (final w in curingStores) DropdownMenuItem(value: w.id, child: Text('${w.name}${w.id == machineCure ? ' (machine)' : ''}', overflow: TextOverflow.ellipsis))],
            onChanged: (v) => _set(() => _form.curingId = v ?? ''),
          ),
        ],
      ]),
      Row(children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: shortLines.isNotEmpty ? null : _addToList,
            icon: Icon(_editingId != null ? LucideIcons.pencil : LucideIcons.plus, size: 16),
            label: Text(_editingId != null ? 'Update batch ${_staged.indexWhere((x) => x['id'] == _editingId) + 1}' : 'Add batch to daily productions'),
          ),
        ),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: () => _set(() { _form = _form.next(); _editingId = null; _ctl.clear(); }), child: Text(_editingId != null ? 'Cancel edit' : 'Reset')),
      ]),
      if (_addError.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: PlHelp(_addError, color: C.error)),
      const SizedBox(height: 14),

      // 3 · the day's list — newest on top, numbered in the order added, saved in that order
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: t.surface, border: Border(left: const BorderSide(color: C.khaki, width: 3), top: BorderSide(color: t.border), right: BorderSide(color: t.border), bottom: BorderSide(color: t.border)), borderRadius: BorderRadius.circular(10)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Expanded(child: Text('Daily Production Ledger', style: TextStyle(fontWeight: FontWeight.w700))),
            Badge2('${_staged.length} batch${_staged.length == 1 ? '' : 'es'} · ${qtyText(stagedBags)} bag${stagedBags == 1 ? '' : 's'}'),
          ]),
          const SizedBox(height: 8),
          if (_staged.isEmpty)
            const PlHelp('No batches staged yet.')
          else
            for (final (i, st) in _staged.indexed.toList().reversed)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: _editingId == st['id'] ? t.soft : null,
                  border: Border(bottom: BorderSide(color: t.border)),
                ),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  CircleAvatar(radius: 11, backgroundColor: C.khaki, child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: Colors.white, fontWeight: FontWeight.w700))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: InkWell(
                      onTap: () => _preview(i, st),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        for (final o in _l(st['outputs']))
                          Text('${o['residual'] == true ? '+ ' : ''}${o['name']} · ${qtyText(n(o['pieces']))} pcs${o['order'] != null ? ' · order ${o['order']}' : ''}',
                              style: TextStyle(fontWeight: o['residual'] == true ? FontWeight.w400 : FontWeight.w600)),
                        PlHelp([
                          '${qtyText(n(st['bags']))} bags',
                          if (st['machine'] != null) '${st['machine']}',
                          if (st['team'] != null) '${st['team']}',
                          st['factor'] == null ? 'no check' : 'yield ${(n(st['factor']) * 1000).roundToDouble() / 10}%${st['outOfBand'] == true ? ' — outside' : ''}',
                        ].join(' · '), color: st['outOfBand'] == true ? C.warning : null),
                      ]),
                    ),
                  ),
                  IconButton(tooltip: 'Edit it in the form', onPressed: st['form'] == null ? null : () => _set(() { _form = _Form.from(Map<String, dynamic>.from(st['form'] as Map)); _editingId = '${st['id']}'; _ctl.clear(); }),
                      icon: const Icon(LucideIcons.pencil, size: 16)),
                  IconButton(tooltip: 'Remove from the list', onPressed: () => _set(() { _staged = _staged.where((y) => y['id'] != st['id']).toList(); if (_editingId == st['id']) { _editingId = null; _form = _Form(); } }),
                      icon: const Icon(LucideIcons.trash2, size: 16)),
                ]),
              ),
          if (_staged.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Total ${qtyText(stagedBags)} bags · ${_staged.length} batch${_staged.length == 1 ? '' : 'es'}', style: const TextStyle(fontWeight: FontWeight.w700))),
          if (_error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: PlHelp(_error, color: C.error)),
          if (_sentNote.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: PlHelp(_sentNote, color: C.success)),
          if (viaApproval && _staged.isNotEmpty) const PlHelp("An earlier date needs an admin's approval."),
          if (_editingId != null) const PlHelp('Finish or cancel the edit to save.'),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _busy || _staged.isEmpty || _editingId != null ? null : _confirm,
            child: Text('${viaApproval ? 'Submit for approval' : 'Save all'} · ${_staged.length} batch${_staged.length == 1 ? '' : 'es'}'),
          ),
        ]),
      ),
    ]);
  }

  Future<void> _preview(int i, Json st) async {
    final est = await estimateBatchCosts(refs, branchId, [_costInput()[i]]).then((x) => x.first).catchError((_) => (cost: 0.0, complete: false, outputs: <({double? perPiece, double? perSqm})>[]));
    if (!mounted) return;
    final edit = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (ctx) => FullPage(
          title: 'Batch ${i + 1} — ${st['label']}',
          footer: [
            OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Close')),
            if (st['form'] != null) FilledButton.icon(onPressed: () => Navigator.pop(ctx, true), icon: const Icon(LucideIcons.pencil, size: 15), label: const Text('Edit')),
          ],
          children: [
            PlHelp('Mold : ${st['category'] ?? ''}'),
            Text('${st['label']}', style: const TextStyle(fontSize: Fs.lg, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Stats([
              Stat('Cement', '${qtyText(n(st['bags']))} bags'),
              Stat('Expected', st['expected'] != null ? '${qtyText(n(st['expected']))} pcs' : '—'),
              Stat('Cement implied', st['theoretical'] != null ? '${qtyText(_round(n(st['theoretical']), 2))} bags' : '—'),
              Stat('Yield factor', st['factor'] != null ? '${(n(st['factor']) * 1000).roundToDouble() / 10}%' : 'no check', figureColor: st['outOfBand'] == true ? C.warning : C.success),
            ]),
            ProductionBreakdown(dayTotal: false, batches: [_bBatch(0, st, est)]),
            if ('${st['notes'] ?? ''}'.isNotEmpty) PlHelp('Note: ${st['notes']}'),
          ],
        )));
    if (edit == true) _set(() { _form = _Form.from(Map<String, dynamic>.from(st['form'] as Map)); _editingId = '${st['id']}'; _ctl.clear(); });
  }

  /// a product without a wastani: quality control needs it, so the batch waits
  Widget _wastaniMissing(Item it) {
    final canSet = session.canAt('products.manage', branchId, null);
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
      PlHelp('No wastani for ${it.name}.', color: C.warning),
      if (canSet) TextButton(onPressed: () => Shell.of(context).go('/products?edit=${it.id}'), child: const Text('Set it now')) else const PlHelp(' Ask the branch manager to set it.'),
    ]);
  }
}

String p6x(num v) {
  final d = double.parse(v.toDouble().toStringAsPrecision(10));
  return d == d.roundToDouble() ? '${d.toInt()}' : '$d';
}

// ---- BatchNotes: team (ticks its active members), who worked, machine, note (056/087/093) ----
class _BatchNotes extends StatefulWidget {
  const _BatchNotes({required this.lists, required this.productId, required this.date, required this.form, required this.reload, required this.onChange});
  final ProductionLists lists;
  final String productId, date;
  final _Form form;
  final Future<void> Function() reload;
  final ValueChanged<_Form> onChange;
  @override
  State<_BatchNotes> createState() => _BatchNotesState();
}

class _BatchNotesState extends State<_BatchNotes> {
  _Form get f => widget.form;
  ProductionLists get lists => widget.lists;
  String get branchId => session.branchId;
  Map<String, double> _present = {};
  final _note = TextEditingController();
  bool _busy = false;
  String _error = '';

  List<Json> get active => lists.people.where((p) => p['status'] == 'active' && p['in_production_cost'] != false).toList();
  List<Json> get allMachines => lists.machines.where((m) => m['status'] == 'active').toList();
  List<Json> get linked => allMachines.where((m) => lists.links.any((l) => l['machine_id'] == m['id'] && l['product_id'] == widget.productId)).toList();
  List<Json> get machines => linked.isNotEmpty ? linked : allMachines;
  List<String> membersOf(String teamId) => [
        for (final m in _l(lists.teams.where((t) => t['id'] == teamId).firstOrNull?['members']))
          if (m['status'] == 'active' && m['staff_id'] != null && active.any((p) => p['id'] == m['staff_id'])) '${m['staff_id']}',
      ];

  @override
  void initState() {
    super.initState();
    _note.text = f.notes;
    _pickMachine();
    _loadPresence();
  }

  @override
  void didUpdateWidget(_BatchNotes old) {
    super.didUpdateWidget(old);
    if (old.productId != widget.productId) _pickMachine();
    if (old.date != widget.date) _loadPresence();
    if (_note.text != f.notes) _note.text = f.notes;
  }

  /// the machine starts as the one last used for this product (or the only one); the team is never filled in
  Future<void> _pickMachine() async {
    if (!lists.ready || widget.productId.isEmpty) return;
    if (f.machineId.isNotEmpty && machines.any((m) => m['id'] == f.machineId)) return;
    String? last;
    try { last = (await SharedPreferences.getInstance()).getString('mois.batchnotes.machine.$branchId.${widget.productId}'); } catch (_) {}
    final pick = machines.where((m) => m['id'] == last).firstOrNull ?? (machines.length == 1 ? machines.first : null);
    f.machineId = '${pick?['id'] ?? ''}';
    widget.onChange(f);
  }

  // who is marked at work that day is listed first
  Future<void> _loadPresence() async {
    if (!lists.ready) return;
    try {
      final d = await db.from('production_presence').select('staff_id, day_fraction').eq('branch_id', branchId).eq('work_date', widget.date);
      if (mounted) setState(() => _present = {for (final a in d) '${a['staff_id']}': n(a['day_fraction']).toDouble()});
    } catch (_) {}
  }

  Future<void> _run(Future<void> Function() fn) async {
    setState(() { _error = ''; _busy = true; });
    try {
      await fn();
    } catch (e) {
      _error = '$e'.contains('23505') ? 'That name is already on the list.' : dbError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<String?> _ask(String title, String hint, String button) async {
    final c = TextEditingController();
    return showModal<String>(context,
        title: title,
        body: (ctx) => TextField(controller: c, autofocus: true, textCapitalization: TextCapitalization.words, decoration: InputDecoration(hintText: hint)),
        footer: (ctx) => Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text(button))));
  }

  Future<void> _team(String? id) async {
    if (id == '+') {
      final name = await _ask('New team', 'Team name, e.g. Juma team', 'Create team');
      if (name == null || name.isEmpty) return;
      await _run(() async {
        final t = await db.from('production_teams').insert({'organization_id': session.organization!['id'], 'branch_id': branchId, 'name': name}).select('id').single();
        await widget.reload();
        f.teamId = '${t['id']}';
        f.workerIds = f.workerIds ?? [];
        widget.onChange(f);
        if (mounted) _workers();
      });
      return;
    }
    // its active members ticked; untick anyone not on this batch (they stay in the team)
    f.teamId = id ?? '';
    f.workerIds = membersOf(f.teamId);
    widget.onChange(f);
  }

  Future<void> _machine(String? id) async {
    if (id == '+') {
      final name = await _ask('New machine', 'Machine or line, e.g. Press 1', 'Add machine');
      if (name == null || name.isEmpty) return;
      await _run(() async {
        final m = await db.from('machines').insert({'organization_id': session.organization!['id'], 'branch_id': branchId, 'name': name}).select('id').single();
        if (widget.productId.isNotEmpty) await db.from('machine_products').insert({'machine_id': m['id'], 'product_id': widget.productId, 'organization_id': session.organization!['id']});
        await widget.reload();
        f.machineId = '${m['id']}';
        widget.onChange(f);
      });
      return;
    }
    f.machineId = id ?? '';
    widget.onChange(f);
    if (f.machineId.isEmpty || widget.productId.isEmpty) return;
    try { (await SharedPreferences.getInstance()).setString('mois.batchnotes.machine.$branchId.${widget.productId}', f.machineId); } catch (_) {}
    // learn which machines make the product: picking one links it
    if (!lists.links.any((l) => l['machine_id'] == f.machineId && l['product_id'] == widget.productId)) {
      try {
        await db.from('machine_products').insert({'machine_id': f.machineId, 'product_id': widget.productId, 'organization_id': session.organization!['id']});
        await widget.reload();
      } catch (_) {}
    }
  }

  Future<void> _workers() async {
    final inTeam = {for (final m in _l(lists.teams.where((t) => t['id'] == f.teamId).firstOrNull?['members'])) if (m['status'] == 'active' && m['staff_id'] != null) '${m['staff_id']}'};
    final add = TextEditingController();
    await showModal<void>(context,
        title: 'Who worked on this batch',
        body: (ctx) => StatefulBuilder(builder: (ctx, set) {
              final worked = f.workerIds ?? [];
              final extra = lists.people.where((p) => p['status'] != 'active' && worked.contains(p['id'])).toList();
              final listed = [...active, ...extra]..sort((a, b) {
                  int s(Json p) => (inTeam.contains(p['id']) ? 2 : 0) + (_present.containsKey('${p['id']}') ? 1 : 0);
                  final c = s(b).compareTo(s(a));
                  return c != 0 ? c : '${a['full_name']}'.compareTo('${b['full_name']}');
                });
              final atWork = listed.where((p) => _present.containsKey('${p['id']}')).toList();
              void toggle(String id) => set(() { f.workerIds = worked.contains(id) ? worked.where((x) => x != id).toList() : [...worked, id]; widget.onChange(f); });
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                PlHelp('Tick who worked on this batch.${atWork.isNotEmpty ? ' ${atWork.length} marked at work on ${dateText(widget.date)} are listed first.' : ''}'),
                Wrap(spacing: 4, children: [
                  if (worked.isNotEmpty) TextButton(onPressed: () => set(() { f.workerIds = []; widget.onChange(f); }), child: const Text('Untick all')),
                  if (atWork.isNotEmpty) TextButton(onPressed: () => set(() { f.workerIds = {...worked, ...atWork.map((p) => '${p['id']}')}.toList(); widget.onChange(f); }), child: const Text('Tick everyone at work')),
                ]),
                if (listed.isEmpty) const PlHelp('No staff at this branch yet — add a name below.'),
                for (final p in listed)
                  CheckboxListTile(
                    dense: true, contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
                    value: worked.contains(p['id']), onChanged: (_) => toggle('${p['id']}'),
                    title: Text('${p['full_name']}${_present['${p['id']}'] == 0.5 ? ' (½ day)' : ''}${p['status'] != 'active' ? ' (left)' : ''}',
                        style: TextStyle(fontWeight: inTeam.contains(p['id']) ? FontWeight.w600 : FontWeight.w400)),
                    subtitle: inTeam.contains(p['id']) ? const Text('In this team') : null,
                  ),
                Row(children: [
                  Expanded(child: TextField(controller: add, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'Someone new, e.g. a casual labourer'))),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                              if (add.text.trim().isEmpty) return;
                              final id = await db.rpc('add_production_person', params: {'p_branch': branchId, 'p_name': add.text.trim()});
                              add.clear();
                              await widget.reload();
                              set(() { if (!(f.workerIds ?? []).contains('$id')) f.workerIds = [...(f.workerIds ?? []), '$id']; widget.onChange(f); });
                            }),
                    child: const Text('Add'),
                  ),
                ]),
                const PlHelp('Added as a casual in HR › Staff, where their pay is set.'),
              ]);
            }),
        footer: (ctx) => Align(alignment: Alignment.centerRight, child: FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done'))));
    widget.onChange(f);
  }

  @override
  Widget build(BuildContext context) {
    final note = TextField(controller: _note, onChanged: (v) { f.notes = v; widget.onChange(f); }, decoration: const InputDecoration(labelText: 'Note (optional)'));
    if (!lists.ready) return note;   // before 056: the note only
    final teams = lists.teams.where((t) => t['status'] == 'active').toList();
    final worked = f.workerIds ?? [];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey('team${f.teamId}${teams.length}'),
            initialValue: f.teamId.isEmpty ? null : f.teamId, isExpanded: true,
            decoration: InputDecoration(labelText: 'Team', prefixIcon: const Icon(LucideIcons.users, size: 16), errorText: f.teamId.isEmpty ? '' : null, errorStyle: const TextStyle(height: 0)),
            items: [for (final t in teams) DropdownMenuItem(value: '${t['id']}', child: Text('${t['name']}', overflow: TextOverflow.ellipsis)), const DropdownMenuItem(value: '+', child: Text('+ New team…'))],
            onChanged: _team,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey('mach${f.machineId}${lists.machines.length}'),
            initialValue: f.machineId.isEmpty ? null : f.machineId, isExpanded: true,
            decoration: InputDecoration(labelText: 'Machine', prefixIcon: const Icon(LucideIcons.cog, size: 16), errorText: f.machineId.isEmpty ? '' : null, errorStyle: const TextStyle(height: 0)),
            items: [
              for (final m in machines) DropdownMenuItem(value: '${m['id']}', child: Text('${m['name']}', overflow: TextOverflow.ellipsis)),
              if (linked.isNotEmpty) for (final m in allMachines.where((m) => !linked.contains(m))) DropdownMenuItem(value: '${m['id']}', child: Text('${m['name']} (other)', overflow: TextOverflow.ellipsis)),
              const DropdownMenuItem(value: '+', child: Text('+ New machine…')),
            ],
            onChanged: _machine,
          ),
        ),
      ]),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(side: BorderSide(color: worked.isEmpty ? C.warning : context.tk.borderStrong)),
        onPressed: _workers,
        icon: const Icon(LucideIcons.userCheck, size: 16),
        label: Text(worked.isNotEmpty ? '${worked.length} ${worked.length == 1 ? 'person' : 'people'} worked' : 'who worked…'),
      ),
      const SizedBox(height: 8),
      note,
      if (_error.isNotEmpty) PlHelp(_error, color: C.error),
    ]);
  }
}
