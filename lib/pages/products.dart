import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide SortOrder;

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';

/*
 * Products — a port of web pages/Products.jsx with ProductDetail, ProductEditModal (a full-screen
 * form), CapacityEditor, ProductMore / MergePanel and EntityFlags / EntityHistory. Same loads,
 * filters, sort, chips, checks and writes as the web (approved 2026-11-24).
 */
const _sortLabel = {
  'size_asc': 'Size: smallest → largest (default)', 'size_desc': 'Size: largest → smallest',
  'name_asc': 'Name: A → Z', 'name_desc': 'Name: Z → A',
  'stock_desc': 'Stock qty: highest → lowest', 'stock_asc': 'Stock qty: lowest → highest',
};

double? numOrNull(String v) => v.trim().isEmpty ? null : double.tryParse(v.trim());
String p6(Object? v) {
  if (v == null) return '—';
  final d = double.parse(n(v).toStringAsPrecision(6));
  return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}

String? capacityText(Json? row, {bool short = false}) {
  if (row?['molds'] != null && n(row!['molds']) > 0) return short ? qtyText(n(row['molds'])) : '${qtyText(n(row['molds']))} molds — up to ${qtyText(n(row['molds']))} pcs a day';
  final lo = row?['bags_per_day_min'] ?? row?['bags_per_day_max'], hi = row?['bags_per_day_max'] ?? row?['bags_per_day_min'];
  if (lo == null || n(lo) == 0) return null;
  return '${qtyText(n(lo))}${n(hi) != n(lo) ? '–${qtyText(n(hi))}' : ''} bags${short ? '/day' : ' of cement a day'}';
}

bool _sameName(String a, String b) => a.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ') == b.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
bool _sameSet(List a, List b) => a.length == b.length && a.every(b.contains);

/// Everything the page loads, as the web holds it in state
class _Data {
  _Data(Json j)
      : categories = _l(j['categories']), products = _l(j['products']), units = _l(j['units']),
        palette = _l(j['palette']), catColours = _l(j['catColours']), ownColours = _l(j['ownColours']),
        stock = _l(j['stock']), warehouses = _l(j['warehouses']), capacityOk = j['capacityOk'] == true {
    for (final f in _l(j['flags'])) { openFlags['${f['entity_id']}'] = (openFlags['${f['entity_id']}'] ?? 0) + 1; }
    for (final r in _l(j['branchProducts'])) { (carried[r['product_id']] ??= {})[r['branch_id']] = r; }
    for (final b in _l(j['branches'])) { branchNames['${b['id']}'] = '${b['name']}'; }
    for (final s in _l(j['specs'])) { specs['${s['product_id']}'] = s; }
    for (final w in warehouses) { whBranch['${w['id']}'] = w['branch_id']; }
    for (final r in _l(j['capacity'])) { (capacity[r['branch_id']] ??= {})[r['product_id']] = r; }
    cats = CategoryTools(categories);
  }
  static List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
  final List<Json> categories, products, units, palette, catColours, ownColours, stock, warehouses;
  final bool capacityOk;
  final Map<String, int> openFlags = {};
  final Map<String, Map<String, Json>> carried = {}, capacity = {};
  final Map<String, String> branchNames = {};
  final Map<String, Json> specs = {};
  final Map<String, String?> whBranch = {};
  late final CategoryTools cats;

  Json? product(String id) => products.where((p) => p['id'] == id).firstOrNull;
  Json? colour(String id) => palette.where((c) => c['id'] == id).firstOrNull;
  List<String> colourIds(Json p) {
    final rows = p['own_colors'] == true
        ? ownColours.where((c) => c['product_id'] == p['id']).toList()
        : catColours.where((c) => c['category_id'] == p['category_id']).toList();
    rows.sort((a, b) => n(a['display_order']).compareTo(n(b['display_order'])));
    return [for (final r in rows) '${r['color_id']}'];
  }

  List<String> categoryColours(String cid) {
    final rows = catColours.where((c) => c['category_id'] == cid).toList()..sort((a, b) => n(a['display_order']).compareTo(n(b['display_order'])));
    return [for (final r in rows) '${r['color_id']}'];
  }

  String unitOf(Json p) => '${(p['unit'] as Map?)?['symbol'] ?? ''}';
  int recipeLinks(Json p) => n(((p['recipes'] as List?)?.firstOrNull as Map?)?['count']).toInt();
}

Future<Json> _fetch() async {
  final r = await Future.wait<dynamic>([
    db.from('product_categories').select('id, name, category_id_ref, display_format, sort_order, status, default_unit_id, default_yield_tolerance, parent_category_id').order('sort_order', ascending: true),
    db.from('products').select('id, product_id_ref, canonical_name, size_cm, category_id, unit_id, pcs_per_sqm, wastani_per_bag, status, notes, strength_class, yield_tolerance, own_colors, category:product_categories(id, name, display_format, sort_order), unit:units(symbol, name), recipes:recipe_version_products(count)'),
    db.from('units').select('id, symbol, name, status').order('symbol', ascending: true),
    db.from('review_flags').select('entity_id').eq('entity_type', 'product').eq('status', 'open'),
    db.from('branch_products').select('id, branch_id, product_id, status, reorder_level, bags_per_person_min, bags_per_person_max'),
    db.from('branches').select('id, name'),
    db.from('product_specs').select('product_id, spec_id, pcs_per_sqm, pcs_source, average_yield_per_bag, yield_source, yield_tolerance'),
    db.from('stock_balances').select('warehouse_id, product_id, color_id, quantity').not('product_id', 'is', null),
    db.from('warehouses').select('id, name, branch_id'),
    db.from('color_palette').select('id, name, display_order, is_active').order('display_order', ascending: true),
    db.from('product_category_colors').select('category_id, color_id, display_order'),
  ]);
  // molds (045) and own colours (046) on their own, so the page still works without them
  List cap = [], own = [];
  var capOk = true;
  try { cap = await db.from('branch_product_capacity').select('id, branch_id, product_id, molds, bags_per_day_min, bags_per_day_max'); } catch (_) { capOk = false; }
  try { own = await db.from('product_colors').select('product_id, color_id, display_order'); } catch (_) {}
  return {
    'categories': r[0], 'products': r[1], 'units': r[2], 'flags': r[3], 'branchProducts': r[4], 'branches': r[5],
    'specs': r[6], 'stock': r[7], 'warehouses': r[8], 'palette': r[9], 'catColours': r[10],
    'capacity': cap, 'capacityOk': capOk, 'ownColours': own,
  };
}

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key, this.edit});
  final String? edit;   // links from the Review queue open a product (?edit=<id>)
  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage> {
  _Data? _d;
  DateTime? _savedAt;
  String _error = '';
  String _search = '', _categoryId = '', _status = 'active', _catalogue = 'carried', _stockF = '', _size = '', _sortBy = 'size_asc';
  bool _editOpened = false;

  String get branchId => session.branchId;
  bool get canWrite => session.can('products.manage');
  bool get canCatalogue => branchId.isNotEmpty && session.canAt('products.manage', branchId, null);

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final (j, at) = await offline.load<Json>('products', _fetch);
      if (!mounted) return;
      setState(() { _d = _Data(j); _savedAt = at; });
      if (widget.edit != null && !_editOpened) {
        _editOpened = true;
        final p = _d!.product(widget.edit!);
        if (p != null) { setState(() => _status = 'all'); _edit(p); }
      }
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load this page. Please try again.");
    }
  }

  bool _carriedHere(String id) => _d!.carried[id]?[branchId]?['status'] == 'active';

  Map<String, double> _onHand() {
    final m = <String, double>{};
    for (final s in _d!.stock) {
      if (session.inBranch(_d!.whBranch['${s['warehouse_id']}'])) m['${s['product_id']}'] = (m['${s['product_id']}'] ?? 0) + n(s['quantity']);
    }
    return m;
  }

  Future<void> _edit(Json p) async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ProductEditPage(data: _d!, product: p)));
    if (saved == true) _load();
  }

  Future<void> _view(Json p) async {
    final r = await Navigator.push<String>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ProductDetailPage(data: _d!, productId: '${p['id']}', onChanged: _load)));
    if (r == 'edit' && mounted) { final x = _d!.product('${p['id']}'); if (x != null) _edit(x); }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final d = _d;
    if (_error.isNotEmpty && d == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    if (d == null) return ListView(padding: const EdgeInsets.all(14), children: const [Skeleton(rows: 7)]);
    final cats = d.cats;
    final onHand = _onHand();

    // category order, then size smallest to largest, then name (groups sit together)
    int byCat(Json a, Json b) => cats.byId[a['category_id']] != null && cats.byId[b['category_id']] != null ? cats.compare(cats.byId[a['category_id']]!, cats.byId[b['category_id']]!) : 0;
    int byName(Json a, Json b) => naturalCompare('${a['canonical_name']}', '${b['canonical_name']}');
    double qty(Json p) => onHand['${p['id']}'] ?? 0;
    final sorted = [...d.products]..sort((a, b) {
        var c = byCat(a, b);
        if (c != 0) return c;
        c = cats.label(a['category_id']).compareTo(cats.label(b['category_id']));
        if (c != 0) return c;
        c = compareKeys(sizeKey(a['size_cm']), sizeKey(b['size_cm']));
        return c != 0 ? c : byName(a, b);
      });
    final ordered = switch (_sortBy) {
      'size_desc' => [...sorted]..sort((x, y) { final c = byCat(x, y); if (c != 0) return c; final s = compareKeys(sizeKey(y['size_cm']), sizeKey(x['size_cm'])); return s != 0 ? s : byName(x, y); }),
      'name_asc' => [...sorted]..sort(byName),
      'name_desc' => [...sorted]..sort((x, y) => byName(y, x)),
      'stock_desc' => [...sorted]..sort((x, y) { final c = qty(y).compareTo(qty(x)); return c != 0 ? c : byName(x, y); }),
      'stock_asc' => [...sorted]..sort((x, y) { final c = qty(x).compareTo(qty(y)); return c != 0 ? c : byName(x, y); }),
      _ => sorted,
    };

    final q = _search.trim().toLowerCase();
    bool passesCatalogue(Json p) => branchId.isEmpty || _catalogue == 'all' || _carriedHere('${p['id']}') == (_catalogue == 'carried');
    bool inCategory(Json p) => _categoryId.isEmpty || p['category_id'] == _categoryId || cats.byId[p['category_id']]?['parent_category_id'] == _categoryId;
    final filtered = ordered.where((p) {
      if (!inCategory(p)) return false;
      final flags = d.openFlags['${p['id']}'] ?? 0;
      if (_status == 'review' ? flags == 0 : _status != 'all' && p['status'] != _status) return false;
      if (!passesCatalogue(p)) return false;
      if (_stockF.isNotEmpty && (qty(p) != 0) != (_stockF == 'in_stock')) return false;
      if (_size.isNotEmpty && '${p['size_cm'] ?? ''}' != _size) return false;
      return q.isEmpty || '${p['canonical_name']}'.toLowerCase().contains(q) || '${p['product_id_ref']}'.toLowerCase().contains(q);
    }).toList();
    final reviewCount = d.products.where((p) => (d.openFlags['${p['id']}'] ?? 0) > 0 && passesCatalogue(p)).length;
    final carriedCount = branchId.isNotEmpty ? d.products.where((p) => _carriedHere('${p['id']}')).length : 0;
    final sizes = {for (final p in d.products) if (inCategory(p) && '${p['size_cm'] ?? ''}'.isNotEmpty) '${p['size_cm']}'}.toList()
      ..sort((a, b) => compareKeys(sizeKey(a), sizeKey(b)));
    final chips = [
      for (final c in categoryChipItems(cats, (c) => c['status'] == 'active' || d.products.any((p) => p['category_id'] == c['id'] || cats.byId[p['category_id']]?['parent_category_id'] == c['id'])))
        ChipItem(c.id, c.label, c.children?.map((k) => ChipItem(k.id, k.label)).toList()),
    ];
    final canAdd = canWrite || canCatalogue;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: !canAdd
          ? null
          : FloatingActionButton(
              tooltip: 'New product',
              backgroundColor: t.dark ? C.khaki : C.charcoal,
              foregroundColor: t.dark ? C.charcoal : Colors.white,
              onPressed: () => _edit({}),
              child: const Icon(LucideIcons.plus),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 88), children: [
          OfflineNote(_savedAt),
          ListToolbar(
            placeholder: 'Search products…',
            onSearch: (v) => setState(() => _search = v),
            sort: SortSpec(value: _sortBy, onChange: (v) => setState(() => _sortBy = v), options: [for (final e in _sortLabel.entries) (e.key, e.value)]),
            filters: [
              FilterSpec(key: 'size', label: 'Size', value: _size, onChange: (v) => setState(() => _size = v), options: [('', 'Any size'), for (final z in sizes) (z, z)]),
              if (branchId.isNotEmpty)
                FilterSpec(key: 'list', label: "${session.branchName}'s list", value: _catalogue, onChange: (v) => setState(() => _catalogue = v),
                    options: [('carried', 'In the list ($carriedCount)'), ('not_carried', 'Not in the list'), ('all', 'All products')]),
              FilterSpec(key: 'stock', label: 'Stock', value: _stockF, onChange: (v) => setState(() => _stockF = v), options: const [('', 'Any stock'), ('in_stock', 'In stock'), ('none', 'Out of stock')]),
              FilterSpec(key: 'status', label: 'Status', value: _status, onChange: (v) => setState(() => _status = v),
                  options: [('active', 'Active'), ('review', 'Needs review ($reviewCount)'), ('inactive', 'Inactive'), ('all', 'All')]),
            ],
          ),
          ChipRow(items: chips, value: _categoryId, onChange: (v) => setState(() { _categoryId = v; _size = ''; })),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: Text('${_categoryId.isNotEmpty ? cats.label(_categoryId) : 'All products'} (${filtered.length})', style: TextStyle(fontWeight: FontWeight.w600, color: t.textSecondary))),
            PlHelp(_sortLabel[_sortBy]!.replaceAll(' (default)', '')),
          ]),
          const SizedBox(height: 8),
          if (filtered.isEmpty)
            EmptyState(icon: LucideIcons.package, title: 'No products found', description: _search.isNotEmpty ? 'No products match "$_search".' : 'No products in this view.')
          else
            for (final p in filtered) _card(context, d, p),
        ]),
      ),
    );
  }

  /// One product card (products: name on top, category below — locked 2026-10-25)
  Widget _card(BuildContext context, _Data d, Json p) {
    final t = context.tk;
    final id = '${p['id']}';
    final sp = d.specs[id];
    final cap = d.capacity[branchId]?[id];
    final cols = d.colourIds(p);
    final unit = d.unitOf(p);
    final flags = d.openFlags[id] ?? 0;
    final canEdit = canWrite || canCatalogue;
    final tags = [
      d.cats.label(p['category_id']),
      if ('${p['size_cm'] ?? ''}'.isNotEmpty) '${p['size_cm']}',
      unit.isEmpty ? '—' : unit,
      if (p['status'] != 'active') 'inactive',
      if (branchId.isNotEmpty && !_carriedHere(id)) "not in ${session.branchName}'s list",
    ].join(' · ');
    final capText = branchId.isNotEmpty && d.capacityOk
        ? (cap?['molds'] != null && n(cap!['molds']) > 0 ? '${qtyText(n(cap['molds']))} molds' : capacityText(cap, short: true) != null ? '~${capacityText(cap, short: true)}' : 'Molds not set')
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: p['status'] != 'active' ? 0.6 : 1,
        child: Material(
          color: t.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _view(p),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Flexible(child: Text('${p['canonical_name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.md))),
                      if (flags > 0) ...[const SizedBox(width: 6), const Badge2('review', tone: Tone.warning)],
                    ]),
                    const SizedBox(height: 3),
                    Text(tags, style: TextStyle(fontSize: Fs.sm, color: t.textMuted)),
                    if (capText != null || cols.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        if (capText != null)
                          Row(mainAxisSize: MainAxisSize.min, children: [Icon(LucideIcons.factory, size: 12, color: t.textMuted), const SizedBox(width: 3), Text(capText, style: TextStyle(fontSize: Fs.xs, color: t.textMuted))]),
                        for (final c in cols)
                          if (d.colour(c) != null) ColourDot('${d.colour(c)!['name']}'),
                      ]),
                    ],
                  ]),
                ),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text.rich(TextSpan(children: [
                    TextSpan(text: p6(sp?['average_yield_per_bag']), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: Fs.md)),
                    TextSpan(text: ' pcs/bag', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                  ])),
                  Text('wastani${sp?['pcs_per_sqm'] != null && unit.toUpperCase() == 'SQM' ? ' · ${p6(sp!['pcs_per_sqm'])} pcs/m²' : ''}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                ]),
                if (canEdit)
                  IconButton(tooltip: 'Edit', onPressed: () => _edit(p), icon: Icon(LucideIcons.pencil, size: 16, color: t.textSecondary)),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

// ======================================================================================
// ProductDetail: its details, this branch's stock, prices and recipes, and whether the branch
// carries it. Adding or removing it from the branch's list always asks first.
// ======================================================================================
class _ProductDetailPage extends StatefulWidget {
  const _ProductDetailPage({required this.data, required this.productId, required this.onChanged});
  final _Data data;
  final String productId;
  final Future<void> Function() onChanged;
  @override
  State<_ProductDetailPage> createState() => _ProductDetailPageState();
}

class _ProductDetailPageState extends State<_ProductDetailPage> {
  late _Data d = widget.data;
  List<Json>? _prices, _recipes;
  Json? _band, _own;
  Map<String, String> _whNames = {};
  bool _busy = false;
  String _error = '';

  String get branchId => session.branchId;
  String get branchName => session.branchName ?? '';
  Json get p => d.product(widget.productId) ?? {};
  Json? get spec => d.specs[widget.productId];
  bool get canWrite => session.can('products.manage');
  bool get canCatalogue => branchId.isNotEmpty && session.canAt('products.manage', branchId, null);
  bool get canBranchYield => canCatalogue;
  Json? get row => branchId.isNotEmpty ? (d.carried[widget.productId]?[branchId]) : null;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final (j, _) = await offline.load<Json>('product:${widget.productId}:$branchId', () async {
        final pr = db.from('product_branch_pricing').select('branch_id, color_id, price_per_sqm_inclusive, price_per_unit_inclusive, pcs_per_sqm_at_pricing, is_available').eq('product_id', widget.productId);
        final r = await Future.wait<dynamic>([
          branchId.isNotEmpty ? pr.eq('branch_id', branchId) : pr,
          db.from('recipe_version_products').select('recipe:recipe_versions(id, branch_id, status, version_number, variant_label, color:color_palette(name), category:product_categories(name))').eq('product_id', widget.productId),
          db.from('warehouses').select('id, name, branch:branches(name)'),
          branchId.isNotEmpty ? db.rpc('product_yield_band', params: {'p_product_id': widget.productId, 'p_branch_id': branchId}) : Future.value(null),
          spec?['spec_id'] != null ? db.from('product_size_specs').select('yield_tolerance, size_cm, strength_class').eq('id', spec!['spec_id']).maybeSingle() : Future.value(null),
        ]);
        Object? own;
        if (branchId.isNotEmpty && spec?['spec_id'] != null) {
          own = await db.from('branch_yield_overrides').select('id, average_yield_per_bag, yield_tolerance').eq('spec_id', spec!['spec_id']).eq('branch_id', branchId).maybeSingle();
        }
        return {'prices': r[0], 'recipes': r[1], 'wh': r[2], 'band': r[3], 'size': r[4], 'own': own};
      });
      if (!mounted) return;
      final ss = j['size'] as Map?;
      final b = (j['band'] as List?)?.firstOrNull as Map?;
      final avg = b?['average_yield_per_bag'] ?? spec?['average_yield_per_bag'];
      final tol = b?['yield_tolerance'] ?? spec?['yield_tolerance'];
      final cat = d.cats.byId[p['category_id']];
      // the QC band (037): branch figure → product → size → category → organization
      final from = b?['source'] == 'branch' ? "$branchName's own figure"
          : p['yield_tolerance'] != null ? "this product's own"
          : ss?['yield_tolerance'] != null ? 'its size'
          : cat?['default_yield_tolerance'] != null ? '${cat!['name']} default'
          : "the organization's";
      setState(() {
        _band = avg != null ? {'average': n(avg), 'tolerance': tol != null ? n(tol) : null, 'from': from} : null;
        _prices = [for (final x in (j['prices'] as List? ?? [])) Map<String, dynamic>.from(x)];
        _recipes = [
          for (final x in (j['recipes'] as List? ?? []))
            if (x['recipe'] != null && x['recipe']['status'] == 'active' && (branchId.isEmpty || x['recipe']['branch_id'] == branchId)) Map<String, dynamic>.from(x['recipe']),
        ];
        _whNames = {for (final w in (j['wh'] as List? ?? [])) '${w['id']}': '${w['branch']?['name']} — ${w['name']}'};
        if (branchId.isNotEmpty && spec?['spec_id'] != null) {
          _own = {...?(j['own'] as Map?)?.cast<String, dynamic>(), 'size': ss?['size_cm'], 'strength': ss?['strength_class']};
        }
      });
    } catch (_) {
      if (mounted) setState(() { _prices ??= []; _recipes ??= []; });
    }
  }

  Future<void> _write(Future<void> Function() f, {bool reloadAll = true}) async {
    setState(() { _error = ''; _busy = true; });
    try {
      await f();
      if (reloadAll) {
        await widget.onChanged();
        final (j, _) = await offline.load<Json>('products', _fetch);
        d = _Data(j);
      }
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = dbError(e));
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<bool> _ask(String text, String yes, [String? help]) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(text), if (help != null) ...[const SizedBox(height: 6), PlHelp(help)]]),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(yes))],
        ),
      ) ==
      true;

  Future<void> _setCarried(bool on) async {
    final total = _stockRows.fold<double>(0, (s, r) => s + n(r['quantity']));
    final name = '${p['canonical_name']}';
    final ok = await _ask(on ? "Add $name to $branchName's catalogue?" : "Remove $name from $branchName's catalogue?", on ? 'Yes, add it' : 'Yes, remove it',
        !on && total != 0 ? '$branchName still holds ${qtyText(total)} ${d.unitOf(p)} — the stock stays.' : null);
    if (!ok) return;
    await _write(() async {
      if (row != null) {
        await db.from('branch_products').update({'status': on ? 'active' : 'inactive'}).eq('id', row!['id']);
      } else {
        await db.from('branch_products').insert({'organization_id': session.organization!['id'], 'branch_id': branchId, 'product_id': widget.productId});
      }
    });
  }

  /// The branch's own average yield per bag for this size (031)
  Future<void> _editOwn() async {
    final avg = TextEditingController(text: '${_own?['average_yield_per_bag'] ?? spec?['average_yield_per_bag'] ?? ''}');
    final tol = TextEditingController(text: '${_own?['yield_tolerance'] ?? ''}');
    String err = '';
    final cl = d.cats.label(p['category_id'], ' · ');
    final save = await showModal<bool>(context,
        title: "$branchName's own yield per bag",
        body: (ctx) => StatefulBuilder(builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (err.isNotEmpty) Alert(err, tone: Tone.error),
              TextField(controller: avg, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Average pieces per bag')),
              const SizedBox(height: 10),
              TextField(controller: tol, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Tolerance (±)', hintText: 'Same as shared')),
              const SizedBox(height: 8),
              PlHelp("Applies to every $cl product of size ${_own?['size'] ?? ''}${_own?['strength'] != null ? ' ${_own!['strength']}' : ''} at $branchName."),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () {
                  final a = numOrNull(avg.text), t = numOrNull(tol.text);
                  if (!(a != null && a > 0)) return set(() => err = 'Enter an average yield above zero.');
                  if (tol.text.trim().isNotEmpty && !(t != null && t >= 0)) return set(() => err = 'Tolerance must be zero or more, or blank.');
                  Navigator.pop(ctx, true);
                },
                child: const Text('Save'),
              ),
            ])));
    if (save != true) return;
    final a = numOrNull(avg.text), t = numOrNull(tol.text);
    await _write(() async {
      if (_own?['id'] != null) {
        await db.from('branch_yield_overrides').update({'average_yield_per_bag': a, 'yield_tolerance': t}).eq('id', _own!['id']);
      } else {
        await db.from('branch_yield_overrides').insert({'organization_id': session.organization!['id'], 'spec_id': spec!['spec_id'], 'branch_id': branchId, 'average_yield_per_bag': a, 'yield_tolerance': t});
      }
    }, reloadAll: false);
  }

  List<Json> get _stockRows => d.stock.where((s) => s['product_id'] == widget.productId && session.inBranch(d.whBranch['${s['warehouse_id']}'])).toList();

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final unit = d.unitOf(p);
    final flags = d.openFlags[widget.productId] ?? 0;
    final isCarried = row?['status'] == 'active';
    final stock = _stockRows.where((s) => n(s['quantity']) != 0).toList();
    final total = _stockRows.fold<double>(0, (s, r) => s + n(r['quantity']));
    String srcText(Object? s) => s == 'size' ? 'from its size' : s == 'product' ? "this product's own figure" : '';
    String money(Object? v) => formatMoney(n(v), session.currency);
    String priceText(Json r) => r['price_per_sqm_inclusive'] != null ? '${money(r['price_per_sqm_inclusive'])} /m²' : r['price_per_unit_inclusive'] != null ? '${money(r['price_per_unit_inclusive'])} each' : 'category colour pricing';
    final band = _band;
    String bandText() {
      if (band == null) return '— (no average yield yet)';
      if (band['tolerance'] == null) return 'no tolerance set';
      final a = n(band['average']), tl = n(band['tolerance']);
      return '${p6(a)} ± ${p6(tl)} → ${tl == 0 ? 'exactly ${p6(a)}' : '${p6(a - tl)}–${p6(a + tl)}'} per bag (tolerance: ${band['from']})';
    }

    Widget line(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 110, child: Text(k, style: TextStyle(fontSize: Fs.sm, color: t.textMuted))),
            Expanded(child: Text(v, style: const TextStyle(fontSize: Fs.sm))),
          ]),
        );
    Widget muted(String s) => Text(s, style: TextStyle(fontSize: Fs.sm, color: t.textMuted));

    return FullPage(
      title: '${p['canonical_name'] ?? ''}',
      footer: [
        if (canWrite) OutlinedButton(onPressed: () => Navigator.pop(context, 'edit'), child: const Text('Edit details')),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          muted('${d.cats.label(p['category_id'], ' · ')}${p['strength_class'] != null ? ' · ${p['strength_class']}' : ''}'),
          Badge2('${p['status']}', tone: p['status'] == 'active' ? Tone.success : Tone.neutral),
          if (flags > 0) Badge2('$flags to review', tone: Tone.warning),
        ]),
        const SizedBox(height: 8),
        line('Size', '${p['size_cm'] ?? '—'}'),
        line('Stock unit', unit.isEmpty ? '—' : unit),
        if (unit.toUpperCase() == 'SQM') line('Pieces per m²', spec?['pcs_per_sqm'] != null ? '${p6(spec!['pcs_per_sqm'])} (${srcText(spec!['pcs_source'])})' : '—'),
        line('Yield per bag', spec?['average_yield_per_bag'] != null ? '${p6(spec!['average_yield_per_bag'])} average (${srcText(spec!['yield_source'])})' : '—'),
        line('Quality check', bandText()),
        if ('${p['notes'] ?? ''}'.isNotEmpty) line('Notes', '${p['notes']}'),

        if (branchId.isNotEmpty) _CapacityEditor(productId: widget.productId, canEdit: canBranchYield, onChanged: widget.onChanged),

        if (branchId.isNotEmpty && spec?['spec_id'] != null && (_own?['id'] != null || canBranchYield)) ...[
          SectionTitle("$branchName's own yield per bag"),
          Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _own?['id'] != null
                ? Text("${p6(_own!['average_yield_per_bag'])} per bag${_own!['yield_tolerance'] != null ? ' ± ${p6(_own!['yield_tolerance'])}' : ''} (instead of the shared figure, for size ${_own!['size']})", style: const TextStyle(fontSize: Fs.sm))
                : muted('Uses the shared figure for size ${_own?['size'] ?? p['size_cm'] ?? ''}.'),
            if (canBranchYield) ...[
              TextButton(onPressed: _busy ? null : _editOwn, child: Text(_own?['id'] != null ? 'Change…' : "Set $branchName's own…")),
              if (_own?['id'] != null)
                TextButton(onPressed: _busy ? null : () => _write(() async => db.from('branch_yield_overrides').delete().eq('id', _own!['id']), reloadAll: false), child: const Text('Use the shared figure again')),
            ],
          ]),
        ],

        SectionTitle(branchId.isNotEmpty ? "$branchName's product list" : 'Carried by'),
        if (branchId.isNotEmpty)
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Badge2(isCarried ? "In $branchName's list" : "Not in $branchName's list", tone: isCarried ? Tone.success : Tone.neutral),
            if (canCatalogue && p['status'] == 'active')
              TextButton(onPressed: _busy ? null : () => _setCarried(!isCarried), child: Text(isCarried ? "Remove from $branchName's list…" : "Add to $branchName's list…")),
          ])
        else
          Text(([for (final r in (d.carried[widget.productId] ?? {}).values) if (r['status'] == 'active') d.branchNames['${r['branch_id']}'] ?? ''].toList()..sort()).join(', ').ifEmpty('No branch'), style: const TextStyle(fontSize: Fs.sm)),

        SectionTitle('Stock on hand${branchId.isNotEmpty ? ' at $branchName' : ''}'),
        if (stock.isEmpty)
          muted('None.')
        else ...[
          for (final s in stock)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text.rich(TextSpan(style: const TextStyle(fontSize: Fs.sm), children: [
                TextSpan(text: '${_whNames['${s['warehouse_id']}'] ?? '…'}${s['color_id'] != null ? ' · ${d.colour('${s['color_id']}')?['name'] ?? ''}' : ''}: '),
                TextSpan(text: qtyText(n(s['quantity'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                TextSpan(text: ' $unit'),
              ])),
            ),
          muted('Total ${qtyText(total)} $unit'),
        ],

        SectionTitle('Prices${branchId.isNotEmpty ? ' at $branchName' : ''}'),
        if (_prices == null)
          muted('Loading…')
        else if (_prices!.isEmpty)
          muted('No price yet.')
        else
          for (final r in [..._prices!]..sort((a, b) => (a['color_id'] != null ? 1 : 0) - (b['color_id'] != null ? 1 : 0)))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                '${branchId.isEmpty ? '${d.branchNames['${r['branch_id']}'] ?? ''}: ' : ''}${r['color_id'] != null ? '${d.colour('${r['color_id']}')?['name'] ?? 'Colour'}: ' : 'Base: '}${priceText(r)}${r['is_available'] == false ? ' (not sold here)' : ''}',
                style: const TextStyle(fontSize: Fs.sm),
              ),
            ),

        SectionTitle('Recipes using it${branchId.isNotEmpty ? ' at $branchName' : ''}'),
        if (_recipes == null)
          muted('Loading…')
        else if (_recipes!.isEmpty)
          muted('None linked.')
        else
          for (final r in _recipes!)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text('${branchId.isEmpty ? '${d.branchNames['${r['branch_id']}'] ?? ''}: ' : ''}${r['category']?['name'] ?? ''} — ${r['color']?['name'] ?? r['variant_label'] ?? ''} (v${r['version_number']})', style: const TextStyle(fontSize: Fs.sm)),
            ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Molds available at the branch (CapacityEditor): vibro molds, or the press's bags a day
class _CapacityEditor extends StatefulWidget {
  const _CapacityEditor({required this.productId, required this.canEdit, this.onChanged});
  final String productId;
  final bool canEdit;
  final Future<void> Function()? onChanged;
  @override
  State<_CapacityEditor> createState() => _CapacityEditorState();
}

class _CapacityEditorState extends State<_CapacityEditor> {
  Json? _row;
  bool _loaded = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final (r, _) = await offline.load<Json?>('capacity:${session.branchId}:${widget.productId}', () async {
        final x = await db.from('branch_product_capacity').select('*').eq('branch_id', session.branchId).eq('product_id', widget.productId).maybeSingle();
        return x;
      });
      if (mounted) setState(() { _row = r == null ? null : Map<String, dynamic>.from(r); _loaded = true; });
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  Future<void> _edit() async {
    final molds = TextEditingController(text: '${_row?['molds'] ?? ''}');
    final lo = TextEditingController(text: '${_row?['bags_per_day_min'] ?? ''}');
    final hi = TextEditingController(text: '${_row?['bags_per_day_max'] ?? ''}');
    String err = '';
    var busy = false;
    await showModal<void>(context,
        title: 'Molds available at ${session.branchName}',
        body: (ctx) => StatefulBuilder(builder: (ctx, set) {
              Future<void> save() async {
                final m = numOrNull(molds.text), l = numOrNull(lo.text), h = numOrNull(hi.text);
                if (m != null && !(m == m.roundToDouble() && m > 0)) return set(() => err = 'Molds: a whole number above zero, or blank.');
                if ((l != null && !(l > 0)) || (h != null && !(h > 0)) || (l != null && h != null && l > h)) return set(() => err = 'Bags a day: from ≤ to, both above zero.');
                set(() { busy = true; err = ''; });
                final fields = {'molds': m?.toInt(), 'bags_per_day_min': l, 'bags_per_day_max': h};
                try {
                  if (_row?['id'] != null) {
                    if (m == null && l == null && h == null) {
                      await db.from('branch_product_capacity').delete().eq('id', _row!['id']);
                    } else {
                      await db.from('branch_product_capacity').update(fields).eq('id', _row!['id']);
                    }
                  } else {
                    await db.from('branch_product_capacity').insert({'organization_id': session.organization!['id'], 'branch_id': session.branchId, 'product_id': widget.productId, ...fields});
                  }
                  if (ctx.mounted) Navigator.pop(ctx);
                  await _load();
                  await widget.onChanged?.call();
                } catch (e) {
                  set(() { busy = false; err = dbError(e); });
                }
              }

              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (err.isNotEmpty) Alert(err, tone: Tone.error),
                TextField(controller: molds, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Molds (vibro)', hintText: '—')),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(child: TextField(controller: lo, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Bags a day (press), from', hintText: '—'))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: hi, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'to', hintText: '—'))),
                ]),
                const SizedBox(height: 12),
                FilledButton(onPressed: busy ? null : save, child: const Text('Save')),
              ]);
            }));
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Molds available at ${session.branchName}'),
      Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Text(capacityText(_row) ?? 'Not filled in yet', style: TextStyle(fontSize: Fs.sm, color: _row == null ? context.tk.textMuted : null)),
        if (widget.canEdit) TextButton(onPressed: _edit, child: Text(_row != null ? 'Change…' : 'Fill in…')),
      ]),
    ]);
  }
}

// ======================================================================================
// ProductEditModal: add or edit a product in one short form. Products are never deleted —
// they are deactivated, keeping their prices, recipes and history.
// ======================================================================================
class _ProductEditPage extends StatefulWidget {
  const _ProductEditPage({required this.data, required this.product});
  final _Data data;
  final Json product;
  @override
  State<_ProductEditPage> createState() => _ProductEditPageState();
}

class _ProductEditPageState extends State<_ProductEditPage> {
  _Data get d => widget.data;
  Json get product => widget.product;
  bool get isNew => product['id'] == null;
  String get branchId => session.branchId;
  String get branchName => session.branchName ?? '';
  bool get canWrite => session.can('products.manage');
  bool get canBranch => branchId.isNotEmpty && session.canAt('products.manage', branchId, null);
  Json? get capacityRow => !isNew && branchId.isNotEmpty ? (d.capacity[branchId]?['${product['id']}']) : null;
  Json? get branchRow => !isNew && branchId.isNotEmpty ? (d.carried['${product['id']}']?[branchId]) : null;
  Json? get sqmUnit => d.units.where((u) => RegExp(r'^(sqm|m²)$', caseSensitive: false).hasMatch('${u['symbol']}')).firstOrNull;
  Json? get pcsUnit => d.units.where((u) => RegExp(r'^pcs$', caseSensitive: false).hasMatch('${u['symbol']}')).firstOrNull;

  late final _name = TextEditingController(text: '${product['canonical_name'] ?? ''}');
  late final _size = TextEditingController(text: '${product['size_cm'] ?? ''}');
  late final _wastani = TextEditingController(text: _s(product['wastani_per_bag']));
  late final _molds = TextEditingController(text: _s(capacityRow?['molds']));
  late final _perSqm = TextEditingController(text: _s(product['pcs_per_sqm']));
  late final _reorder = TextEditingController(text: _s(branchRow?['reorder_level']));
  late final String _lab0 = branchRow?['bags_per_person_min'] != null
      ? (n(branchRow!['bags_per_person_min']) == n(branchRow!['bags_per_person_max']) ? p6(branchRow!['bags_per_person_min']) : '${p6(branchRow!['bags_per_person_min'])}-${p6(branchRow!['bags_per_person_max'])}')
      : '';
  late final _perPerson = TextEditingController(text: _lab0);
  late final _tolerance = TextEditingController(text: _s(product['yield_tolerance']));
  late final _notes = TextEditingController(text: '${product['notes'] ?? ''}');
  late String _category = '${product['category_id'] ?? ''}';
  late String _unitId = '${product['unit_id'] ?? ''}';
  late final List<String> _colorIds = isNew ? [] : d.colourIds(product);
  late List<String> _chosen = isNew ? [] : [..._colorIds];
  bool _touched = false;
  late bool _pick = isNew ? d.categoryColours(_category).isNotEmpty : _colorIds.isNotEmpty;
  Map<String, dynamic>? _stuck;   // { message, ids } — stock in a colour switched off
  String _moveTo = '';
  bool _busy = false;
  String _error = '';

  static String _s(Object? v) => v == null ? '' : p6(v);

  double get _onHand => d.stock.where((x) => x['product_id'] == product['id']).fold(0.0, (s, x) => s + n(x['quantity']));
  bool get _unitLocked => !isNew && _onHand != 0;
  bool get _isSqm => _unitId.isNotEmpty && _unitId == sqmUnit?['id'];
  List<String> get _shown => isNew && !_touched ? d.categoryColours(_category) : _chosen;

  void _chooseCategory(String id) {
    setState(() {
      _category = id;
      if (isNew && !_touched) _pick = d.categoryColours(id).isNotEmpty;
      final suggested = d.cats.byId[id]?['default_unit_id'];
      if (isNew && suggested != null && _unitId.isEmpty) _unitId = '$suggested';
    });
  }

  void _toggle(String id) {
    final base = _shown;
    setState(() {
      _stuck = null;
      _touched = true;
      _chosen = (base.contains(id) ? base.where((x) => x != id).toList() : [...base, id])
        ..sort((a, b) => n(d.colour(a)?['display_order']).compareTo(n(d.colour(b)?['display_order'])));
    });
  }

  String _nextRef(String? catRef) {
    final taken = {for (final p in d.products) '${p['product_id_ref']}'};
    var i = d.products.where((p) => '${p['product_id_ref']}'.startsWith('${catRef}_')).length + 1;
    String ref;
    do { ref = '${catRef}_${'${i++}'.padLeft(2, '0')}'; } while (taken.contains(ref));
    return ref;
  }

  Future<void> _save() async {
    setState(() => _error = '');
    void fail(String m) => setState(() { _busy = false; _error = m; });
    if (canWrite) {
      if (_name.text.trim().isEmpty || _category.isEmpty || _unitId.isEmpty) return fail('Enter the name, category and unit.');
      final clash = d.products.where((p) => p['id'] != product['id'] && p['status'] == 'active' && p['category_id'] == _category && _sameName('${p['canonical_name']}', _name.text)).firstOrNull;
      if (clash != null) return fail('"${clash['canonical_name']}" already exists in this category.');
      for (final (label, v) in [('Wastani', _wastani.text), ('Pieces per m²', _isSqm ? _perSqm.text : '')]) {
        final x = numOrNull(v);
        if (v.trim().isNotEmpty && !(x != null && x > 0)) return fail('$label must be above zero, or blank if not known.');
      }
      final tol = numOrNull(_tolerance.text);
      if (_tolerance.text.trim().isNotEmpty && !(tol != null && tol >= 0)) return fail('Yield tolerance must be zero or more, or blank.');
    }
    final m = numOrNull(_molds.text);
    if (_molds.text.trim().isNotEmpty && !(m != null && m == m.roundToDouble() && m > 0)) return fail('Molds: a whole number above zero, or blank.');
    final r = numOrNull(_reorder.text);
    if (_reorder.text.trim().isNotEmpty && !(r != null && r >= 0)) return fail('Reorder level: zero or more, or blank.');
    final ppText = _perPerson.text.trim();
    final pp = ppText.isEmpty ? null : ppText.split(RegExp('[-–]')).map((x) => double.tryParse(x.trim()) ?? 0).toList();
    if (pp != null && (pp.length > 2 || pp.any((x) => !(x > 0)) || (pp.length == 2 && pp[0] > pp[1]))) return fail('Bags a person: a number like 3, or a range like 2-3, or blank.');

    setState(() => _busy = true);
    final org = session.organization!['id'];
    String id = '${product['id'] ?? ''}';
    try {
      if (canWrite) {
        final row = {
          'canonical_name': _name.text.trim(), 'category_id': _category, 'unit_id': _unitId, 'size_cm': _size.text.trim().isEmpty ? null : _size.text.trim(),
          'wastani_per_bag': numOrNull(_wastani.text), 'pcs_per_sqm': _isSqm ? numOrNull(_perSqm.text) : null,
          'yield_tolerance': numOrNull(_tolerance.text), 'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        };
        final res = isNew
            ? await db.from('products').insert({...row, 'organization_id': org, 'product_id_ref': _nextRef(d.cats.byId[_category]?['category_id_ref'])}).select('id').single()
            : await db.from('products').update(row).eq('id', id).select('id').single();
        id = '${res['id']}';
      }
      // the branch's list: a new product joins it; the reorder level lives there
      if (branchId.isNotEmpty) {
        if (isNew) {
          try {
            await db.from('branch_products').insert({'organization_id': org, 'branch_id': branchId, 'product_id': id, 'reorder_level': ?r});
          } catch (e) {
            return fail("Saved, but not added to $branchName's list: ${dbError(e)}");
          }
        } else if (branchRow?['id'] != null && (branchRow!['reorder_level'] == null ? null : n(branchRow!['reorder_level'])) != r) {
          await db.from('branch_products').update({'reorder_level': r}).eq('id', branchRow!['id']);
        }
        // the labour norm (057): bags a person, on the branch's list
        if (branchRow?['id'] != null && ppText != _lab0) {
          await db.from('branch_products').update({'bags_per_person_min': pp?.first, 'bags_per_person_max': pp?.last}).eq('id', branchRow!['id']);
        }
        // the branch's molds (press products keep their bags a day)
        final cap = capacityRow;
        if ((cap?['molds'] == null ? null : n(cap!['molds'])) != m) {
          final hasBags = cap?['bags_per_day_min'] != null || cap?['bags_per_day_max'] != null;
          if (cap?['id'] != null) {
            if (m == null && !hasBags) {
              await db.from('branch_product_capacity').delete().eq('id', cap!['id']);
            } else {
              await db.from('branch_product_capacity').update({'molds': m?.toInt()}).eq('id', cap!['id']);
            }
          } else if (m != null) {
            await db.from('branch_product_capacity').insert({'organization_id': org, 'branch_id': branchId, 'product_id': id, 'molds': m.toInt()});
          }
        }
      }
      // colours, only when changed (a new product keeps its category's unless changed)
      if (canWrite && _touched && !(isNew ? _sameSet(_chosen, d.categoryColours(_category)) : _sameSet(_chosen, _colorIds))) {
        try {
          await db.rpc('set_product_colors', params: {'p_product': id, 'p_own': true, 'p_color_ids': _chosen, 'p_move_to': _stuck != null ? (_moveTo.isEmpty || _moveTo == 'none' ? null : _moveTo) : null});
        } on PostgrestException catch (e) {
          if (e.hint == 'move_stock') {
            return setState(() { _busy = false; _stuck = {'message': e.message, 'ids': [..._chosen]}; _moveTo = _chosen.isEmpty ? 'none' : ''; });
          }
          rethrow;
        }
      }
    } catch (e) {
      return fail(dbError(e));
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _toggleStatus() async {
    setState(() { _error = ''; _busy = true; });
    try {
      await db.from('products').update({'status': product['status'] == 'active' ? 'inactive' : 'active'}).eq('id', product['id']);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final recipeLinks = isNew ? 0 : d.recipeLinks(product);
    final choosable = d.cats.leaves.where((c) => c['status'] == 'active' || c['id'] == product['category_id']).toList();
    final shown = _shown;
    final choices = d.palette.where((c) => c['is_active'] == true || shown.contains(c['id'])).toList();
    final unitSym = d.units.where((u) => u['id'] == _unitId).firstOrNull?['symbol'];
    final catDefault = d.cats.byId[_category]?['default_yield_tolerance'];
    InputDecoration dec(String label, [String? hint]) => InputDecoration(labelText: label, hintText: hint);
    const num = TextInputType.numberWithOptions(decimal: true);
    Widget gap() => const SizedBox(height: 12);

    return FullPage(
      title: isNew ? 'New product' : 'Edit: ${product['canonical_name']}',
      footer: [
        if (!isNew && canWrite)
          OutlinedButton(
            style: product['status'] == 'active' ? OutlinedButton.styleFrom(foregroundColor: C.error, side: const BorderSide(color: C.error)) : null,
            onPressed: _busy ? null : _toggleStatus,
            child: Text(product['status'] == 'active' ? 'Deactivate' : 'Reactivate'),
          ),
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(isNew ? 'Add product' : 'Save changes')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        TextField(controller: _name, enabled: canWrite, autofocus: isNew, textCapitalization: TextCapitalization.words, decoration: dec('Product name (as used in factory)')),
        gap(),
        DropdownButtonFormField<String>(
          initialValue: _category.isEmpty ? null : _category,
          isExpanded: true,
          decoration: dec('Category'),
          items: [for (final c in choosable) DropdownMenuItem(value: '${c['id']}', child: Text('${d.cats.label(c)}${c['status'] != 'active' ? ' (inactive)' : ''}', overflow: TextOverflow.ellipsis))],
          onChanged: !canWrite || (!isNew && recipeLinks > 0) ? null : (v) => _chooseCategory(v ?? ''),
        ),
        if (!isNew && recipeLinks > 0) const PlHelp('Linked to recipes of this category — unlink them under Recipes to move it.'),
        gap(),
        TextField(controller: _size, enabled: canWrite, decoration: dec('Size', 'e.g. 40x40')),
        gap(),
        Row(children: [
          Expanded(child: TextField(controller: _wastani, enabled: canWrite, keyboardType: num, decoration: dec('Wastani (pcs / 50 kg bag)', 'Not known'))),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(controller: _molds, enabled: branchId.isNotEmpty && canBranch, keyboardType: TextInputType.number,
                decoration: dec('Molds${branchName.isNotEmpty ? ' at $branchName' : ''}', capacityRow?['bags_per_day_max'] != null ? 'Press — bags a day' : 'Not set')),
          ),
        ]),
        gap(),
        const PlLabel('Unit of measure'),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          for (final (u, label) in [if (sqmUnit != null) (sqmUnit!, 'Square metre (m²)'), if (pcsUnit != null) (pcsUnit!, 'Pieces (pcs)')])
            Chip2(label, on: _unitId == u['id'], onTap: () { if (canWrite && !_unitLocked) setState(() => _unitId = '${u['id']}'); }),
        ]),
        if (_unitId.isNotEmpty && _unitId != sqmUnit?['id'] && _unitId != pcsUnit?['id']) PlHelp('Counted in ${d.units.where((u) => u['id'] == _unitId).firstOrNull?['name'] ?? ''}.'),
        if (_unitLocked) const PlHelp("It has stock on hand, so its unit can't change."),
        if (_isSqm) ...[gap(), TextField(controller: _perSqm, enabled: canWrite, keyboardType: num, decoration: dec('Pieces per square metre', 'Not known'))],
        gap(),
        const PlLabel('Colours'),
        const SizedBox(height: 6),
        if (!_pick)
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Badge2('No colour'),
            const PlHelp('Stocked as a single item.'),
            if (canWrite) TextButton(onPressed: _busy ? null : () => setState(() => _pick = true), child: const Text('Add colours')),
          ])
        else ...[
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final c in choices)
              FilterChip(
                selected: shown.contains(c['id']),
                showCheckmark: false,
                avatar: CircleAvatar(radius: 6, backgroundColor: cssColour('${c['name']}')),
                label: Text('${c['name']}${shown.contains(c['id']) ? ' ✓' : ''}'),
                onSelected: !canWrite || _busy ? null : (_) => _toggle('${c['id']}'),
              ),
            if (canWrite && shown.isNotEmpty)
              TextButton(onPressed: _busy ? null : () => setState(() { _stuck = null; _touched = true; _chosen = []; _pick = false; }), child: const Text('No colour')),
          ]),
          if (shown.isEmpty) const PlHelp('All off — it will be saved with no colour.'),
        ],
        if (_stuck != null) ...[
          gap(),
          Alert('${_stuck!['message']}', tone: Tone.warning),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _moveTo.isEmpty ? null : _moveTo,
                decoration: dec('Move it to'),
                items: (_stuck!['ids'] as List).isEmpty
                    ? [const DropdownMenuItem(value: 'none', child: Text('No colour'))]
                    : [for (final id in _stuck!['ids'] as List) DropdownMenuItem(value: '$id', child: Text('${d.colour('$id')?['name'] ?? '—'}'))],
                onChanged: (v) => setState(() => _moveTo = v ?? ''),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _busy || _moveTo.isEmpty ? null : _save, child: const Text('Move stock and save')),
          ]),
        ],
        if (branchId.isNotEmpty) ...[
          gap(),
          TextField(controller: _reorder, enabled: canBranch && (isNew || branchRow?['id'] != null), keyboardType: num, decoration: dec('Low-stock reorder level at $branchName', 'Not set')),
          if (!isNew && branchRow?['id'] == null) PlHelp("Not in $branchName's list — add it there first."),
          PlHelp('In ${unitSym ?? 'its unit'}. Stock shows LOW below this.'),
        ],
        if (branchId.isNotEmpty && !isNew && branchRow?['id'] != null) ...[
          gap(),
          TextField(controller: _perPerson, enabled: canBranch, keyboardType: TextInputType.text, decoration: dec('Bags a person at $branchName', "e.g. 3 or 2-3 (blank: the machine's crew)")),
          const PlHelp('Bags one person casts a day.'),
        ],
        if (!isNew && canWrite) ...[
          gap(),
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: Text('More — tolerance, notes, merge, review, history', style: TextStyle(fontSize: Fs.sm, color: t.textSecondary)),
              children: [
                TextField(controller: _tolerance, keyboardType: num,
                    decoration: dec('Yield tolerance (± pieces per bag)', catDefault != null ? 'Category default: ±${p6(catDefault)}' : 'Organization default')),
                gap(),
                TextField(controller: _notes, minLines: 2, maxLines: 5, decoration: dec('Notes')),
                _ProductMore(data: d, product: product, onDone: (close) { if (close && mounted) Navigator.pop(context, true); }),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// The edit window's "More": merge into another product, review flags, history
class _ProductMore extends StatefulWidget {
  const _ProductMore({required this.data, required this.product, required this.onDone});
  final _Data data;
  final Json product;
  final void Function(bool close) onDone;
  @override
  State<_ProductMore> createState() => _ProductMoreState();
}

class _ProductMoreState extends State<_ProductMore> {
  bool _merging = false;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (session.canManage('products.manage') && widget.product['status'] == 'active' && !_merging)
          Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(top: 12), child: OutlinedButton(onPressed: () => setState(() => _merging = true), child: const Text('Merge into another product…')))),
        if (_merging) _MergePanel(data: widget.data, product: widget.product, onCancel: () => setState(() => _merging = false), onMerged: () => widget.onDone(true)),
        EntityFlags(entityType: 'product', entityId: '${widget.product['id']}', canResolve: true, canRaise: true),
        EntityHistory(entityType: 'product', entityId: '${widget.product['id']}'),
      ]);
}

/// Merge a duplicate into the product that stays: the duplicate is deactivated (never deleted)
/// and its open flags resolved; prices are not copied — the comparison shows where they differ.
class _MergePanel extends StatefulWidget {
  const _MergePanel({required this.data, required this.product, required this.onCancel, required this.onMerged});
  final _Data data;
  final Json product;
  final VoidCallback onCancel, onMerged;
  @override
  State<_MergePanel> createState() => _MergePanelState();
}

class _MergePanelState extends State<_MergePanel> {
  String _targetId = '';
  List<Json>? _prices;
  bool _busy = false;
  String _error = '';
  Json get product => widget.product;
  late final List<Json> candidates = widget.data.products
      .where((p) => p['id'] != product['id'] && p['status'] == 'active' && p['category_id'] == product['category_id'])
      .toList()
    ..sort((a, b) => '${a['canonical_name']}'.compareTo('${b['canonical_name']}'));
  Json? get target => candidates.where((p) => p['id'] == _targetId).firstOrNull;

  Future<void> _pick(String id) async {
    setState(() { _targetId = id; _prices = null; });
    if (id.isEmpty) return;
    try {
      final data = await db.from('product_branch_pricing')
          .select('product_id, branch_id, color_id, price_per_unit_inclusive, price_per_sqm_inclusive, branch:branches(name), color:color_palette(name)')
          .inFilter('product_id', [product['id'], id]);
      final rows = <String, Json>{};
      for (final r in data) {
        final key = '${r['branch_id']}|${r['color_id'] ?? ''}';
        rows[key] ??= {'label': [r['branch']?['name'], r['color']?['name']].where((x) => x != null).join(' · ')};
        rows[key]![r['product_id'] == product['id'] ? 'dup' : 'keep'] = r['price_per_sqm_inclusive'] ?? r['price_per_unit_inclusive'];
      }
      if (mounted) setState(() => _prices = rows.values.toList()..sort((a, b) => '${a['label']}'.compareTo('${b['label']}')));
    } catch (_) {
      if (mounted) setState(() => _prices = []);
    }
  }

  Future<void> _merge() async {
    final tg = target!;
    setState(() { _error = ''; _busy = true; });
    try {
      await db.from('products').update({'status': 'inactive'}).eq('id', product['id']);
    } catch (e) {
      return setState(() { _busy = false; _error = dbError(e); });
    }
    try {
      await db.from('review_flags').update({
        'status': 'resolved', 'resolved_at': DateTime.now().toUtc().toIso8601String(), 'resolved_by': session.userId,
        'resolution_note': 'Merged into ${tg['canonical_name']}; this product was retired.',
      }).eq('entity_type', 'product').eq('entity_id', '${product['id']}').eq('status', 'open');
    } catch (e) {
      return setState(() { _busy = false; _error = 'Deactivated, but its flags could not be closed: ${dbError(e)}'; });
    }
    // the merge answers "is X the same as Y" for good (026); an earlier answer is corrected
    final evidence = 'Merged into ${tg['canonical_name']} in the Products screen';
    final term = '${product['canonical_name']}'.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');
    try {
      final existing = await db.from('identity_decisions').select('id, product_id')
          .eq('subject_type', 'product').eq('status', 'active').eq('context_normalized', '').eq('term_normalized', term)
          .inFilter('decision', ['same_as', 'new_record']).maybeSingle();
      if (existing != null && existing['product_id'] != tg['id']) {
        await db.rpc('correct_identity_decision', params: {'p_id': existing['id'], 'p_new': {'decision': 'same_as', 'product_id': tg['id']}, 'p_evidence': evidence});
      } else if (existing == null) {
        try {
          await db.from('identity_decisions').insert({
            'organization_id': session.organization!['id'], 'subject_type': 'product', 'term': product['canonical_name'], 'context': '',
            'decision': 'same_as', 'product_id': tg['id'], 'source': 'merge', 'evidence': evidence,
            'decided_by': session.userId, 'decided_by_label': session.fullName,
          });
        } on PostgrestException catch (e) {
          if (e.code != '23505') rethrow;
        }
      }
    } catch (e) {
      return setState(() { _busy = false; _error = 'Merged, but the decision could not be recorded: ${dbError(e)}'; });
    }
    widget.onMerged();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final tg = target;
    final diffs = (_prices ?? []).where((r) => r['dup'] != r['keep']).length;
    String money(Object? v) => v == null ? '—' : formatMoney(n(v), session.currency);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Merge ${product['canonical_name']} into…'),
      if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
      if (candidates.isEmpty)
        const PlHelp('No other active product in this category to merge into.')
      else
        DropdownButtonFormField<String>(
          initialValue: _targetId.isEmpty ? null : _targetId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Choose the product that stays…'),
          items: [for (final p in candidates) DropdownMenuItem(value: '${p['id']}', child: Text('${p['canonical_name']}${p['size_cm'] != null ? ' (${p['size_cm']})' : ''}', overflow: TextOverflow.ellipsis))],
          onChanged: (v) => _pick(v ?? ''),
        ),
      if (tg != null && _prices != null) ...[
        const SizedBox(height: 8),
        if (_prices!.isEmpty)
          const PlHelp('Neither product has prices.')
        else
          for (final r in _prices!)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Row(children: [
                Expanded(child: Text('${r['label']}', style: const TextStyle(fontSize: Fs.sm))),
                Text(money(r['dup']), style: TextStyle(fontSize: Fs.sm, color: t.textMuted)),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(LucideIcons.arrowRight, size: 12)),
                Text(money(r['keep']), style: TextStyle(fontSize: Fs.sm, fontWeight: r['dup'] != r['keep'] ? FontWeight.w700 : null)),
              ]),
            ),
        const SizedBox(height: 6),
        PlHelp("${product['canonical_name']} will be deactivated and its open flags resolved; its prices and history are kept."
            "${diffs > 0 ? ' $diffs price${diffs == 1 ? ' differs' : 's differ'} — correct ${tg['canonical_name']}\'s prices under Pricing if needed.' : ''}"),
      ],
      const SizedBox(height: 8),
      Row(children: [
        FilledButton(onPressed: _busy || tg == null ? null : _merge, child: const Text('Merge')),
        const SizedBox(width: 8),
        TextButton(onPressed: _busy ? null : widget.onCancel, child: const Text('Cancel')),
      ]),
    ]);
  }
}

// ======================================================================================
// EntityFlags / EntityHistory (web components/master/EntityPanels.jsx) — for any master data
// ======================================================================================
class EntityFlags extends StatefulWidget {
  const EntityFlags({super.key, required this.entityType, required this.entityId, this.canResolve = false, this.canRaise = false, this.onChanged});
  final String entityType, entityId;
  final bool canResolve, canRaise;
  final VoidCallback? onChanged;
  @override
  State<EntityFlags> createState() => _EntityFlagsState();
}

class _EntityFlagsState extends State<EntityFlags> {
  List<Json> _flags = [];
  final Map<String, TextEditingController> _notes = {};
  final _reason = TextEditingController();
  String? _busy;
  String _error = '';

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final data = await db.from('review_flags').select('id, reason_code, reason, status, created_at, resolved_at, resolution_note')
          .eq('entity_type', widget.entityType).eq('entity_id', widget.entityId).order('created_at', ascending: false);
      if (mounted) setState(() => _flags = [for (final x in data) Map<String, dynamic>.from(x)]);
    } catch (_) {}
  }

  Future<void> _close(Json f, String status) async {
    setState(() { _error = ''; _busy = '${f['id']}'; });
    try {
      final note = _notes['${f['id']}']?.text.trim() ?? '';
      await db.from('review_flags').update({
        'status': status, 'resolved_at': DateTime.now().toUtc().toIso8601String(), 'resolved_by': session.userId,
        'resolution_note': note.isEmpty ? null : note,
      }).eq('id', f['id']);
      await _load();
      widget.onChanged?.call();
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = null);
  }

  Future<void> _raise() async {
    setState(() { _error = ''; _busy = 'new'; });
    try {
      await db.from('review_flags').insert({
        'organization_id': session.organization!['id'], 'entity_type': widget.entityType, 'entity_id': widget.entityId,
        'reason_code': 'manual', 'reason': _reason.text.trim(), 'created_by': session.userId,
      });
      _reason.clear();
      await _load();
      widget.onChanged?.call();
    } on PostgrestException catch (e) {
      _error = e.code == '23505' ? 'This record already has an open flag raised by hand — add to that one, or close it first.' : dbError(e);
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = null);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final open = _flags.where((f) => f['status'] == 'open').toList();
    final closed = _flags.where((f) => f['status'] != 'open').toList();
    if (_flags.isEmpty && !widget.canRaise) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Needs review', trailing: open.isNotEmpty ? Badge2('${open.length} open', tone: Tone.warning) : null),
      if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
      for (final f in open)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: t.bgWarning, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(datesInText('${f['reason'] ?? ''}'), style: const TextStyle(fontSize: Fs.sm)),
            if (widget.canResolve) ...[
              const SizedBox(height: 6),
              TextField(controller: _notes.putIfAbsent('${f['id']}', TextEditingController.new), decoration: const InputDecoration(hintText: 'Note (optional) — what was decided')),
              Row(children: [
                TextButton.icon(onPressed: _busy == f['id'] ? null : () => _close(f, 'resolved'), icon: const Icon(LucideIcons.circleCheck, size: 14), label: const Text('Resolved')),
                TextButton.icon(onPressed: _busy == f['id'] ? null : () => _close(f, 'dismissed'), icon: const Icon(LucideIcons.circleX, size: 14), label: const Text('Dismiss')),
              ]),
            ],
          ]),
        ),
      for (final f in closed)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(datesInText('${f['reason'] ?? ''}'), style: TextStyle(fontSize: Fs.sm, color: t.textMuted)),
            PlHelp('${f['status'] == 'resolved' ? 'Resolved' : 'Dismissed'} ${dateTimeText(f['resolved_at']) ?? ''}${f['resolution_note'] != null ? ' — ${f['resolution_note']}' : ''}'),
          ]),
        ),
      if (widget.canRaise)
        Row(children: [
          Expanded(child: TextField(controller: _reason, onChanged: (_) => setState(() {}), decoration: const InputDecoration(hintText: 'Flag for review — what needs checking?'))),
          const SizedBox(width: 6),
          OutlinedButton.icon(onPressed: _busy == 'new' || _reason.text.trim().isEmpty ? null : _raise, icon: const Icon(LucideIcons.flag, size: 14), label: const Text('Flag')),
        ]),
    ]);
  }
}

const _fieldLabels = {
  'name': 'Name', 'canonical_name': 'Name', 'status': 'Status', 'is_active': 'Active', 'display_order': 'Order',
  'sort_order': 'Order', 'default_unit_id': 'Default unit', 'stock_unit_id': 'Stock unit', 'unit_id': 'Unit',
  'category_id': 'Category', 'display_format': 'Layout', 'notes': 'Notes', 'source_name': 'Source',
  'purchase_unit_id': 'Purchase unit', 'is_primary': 'Primary', 'factor_to_stock_unit': 'Factor',
};

String auditValue(Object? v) {
  if (v == null) return '—';
  if (v is String) return RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', caseSensitive: false).hasMatch(v) ? 'ref …${v.substring(v.length - 6)}' : v;
  if (v is Map || v is List) return '(record)';
  return '$v';
}

/// Field-level change history for any entity (readable with org.manage)
class EntityHistory extends StatefulWidget {
  const EntityHistory({super.key, required this.entityType, required this.entityId});
  final String entityType, entityId;
  @override
  State<EntityHistory> createState() => _EntityHistoryState();
}

class _EntityHistoryState extends State<EntityHistory> {
  List<Json>? _rows;

  @override
  void initState() {
    super.initState();
    if (session.canManage('org.manage')) _load();
  }

  Future<void> _load() async {
    try {
      final data = await db.from('audit_log').select('id, action, field, old_value, new_value, changed_by, changed_via, changed_at')
          .eq('entity_type', widget.entityType).eq('entity_id', widget.entityId).order('changed_at', ascending: false).limit(50);
      final ids = {for (final r in data) if (r['changed_by'] != null) '${r['changed_by']}'}.toList();
      var names = <String, String>{};
      if (ids.isNotEmpty) {
        final people = await db.from('profiles').select('id, first_name, last_name, email').inFilter('id', ids);
        names = {for (final p in people) '${p['id']}': [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ').ifEmpty('${p['email']}')};
      }
      if (mounted) setState(() => _rows = [for (final r in data) {...r, 'who': names['${r['changed_by']}']}]);
    } catch (_) {
      if (mounted) setState(() => _rows = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (!session.canManage('org.manage') || rows == null || rows.isEmpty) return const SizedBox.shrink();
    final t = context.tk;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        leading: const Icon(LucideIcons.history, size: 16),
        title: Text('Change history (${rows.length})', style: const TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w600)),
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text.rich(TextSpan(style: const TextStyle(fontSize: Fs.sm), children: [
                TextSpan(text: '${dateTimeText(r['changed_at']) ?? ''} · ', style: TextStyle(color: t.textMuted)),
                if (r['action'] == 'update') ...[
                  TextSpan(text: '${_fieldLabels[r['field']] ?? r['field']}: ${auditValue(r['old_value'])} → '),
                  TextSpan(text: auditValue(r['new_value']), style: const TextStyle(fontWeight: FontWeight.w700)),
                ] else
                  TextSpan(text: r['action'] == 'insert' ? 'Created' : 'Deleted'),
                TextSpan(text: ' — ${r['changed_via'] == 'app' ? (r['who'] ?? 'a user') : r['changed_via'] == 'service' ? 'data import' : 'system'}', style: TextStyle(color: t.textMuted)),
              ])),
            ),
        ],
      ),
    );
  }
}
