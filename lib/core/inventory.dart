import 'format.dart';
import 'offline.dart';
import 'session.dart';

/*
 * Ports of the web's lib/inventory.js (loadInventoryRefs, MOVEMENT_TYPES, mainUnitOf,
 * byMaterialOrder, qty helpers) and lib/categories.js (categoryTools, sizeKey, productOrder).
 */

/// Inventory movement types (migration 022), as named on the web
class MoveType {
  const MoveType(this.label, this.noun, this.perm, this.help);
  final String label, noun, perm, help;
}

const movementTypes = {
  'receipt': MoveType('Receive', 'Receipt', 'inventory.receive', 'Goods arriving at a store, e.g. a delivery from a supplier.'),
  'issue': MoveType('Issue', 'Issue', 'inventory.issue', 'Stock leaving a store for use, e.g. materials to production.'),
  'transfer': MoveType('Transfer', 'Transfer', 'inventory.transfer', 'Moving stock from one store to another, in the same or another branch.'),
  'adjustment': MoveType('Adjust', 'Adjustment', 'inventory.adjust', 'Correcting stock for a known reason, e.g. damage or loss. A reason is required.'),
  'count': MoveType('Count', 'Stock count', 'inventory.count', 'Enter what you physically found; the difference to the records is posted.'),
  'opening_balance': MoveType('Opening balance', 'Opening balance', 'inventory.adjust', 'Stock already on hand when you start using MOIS — once per item per store.'),
  'reversal': MoveType('Reversal', 'Reversal', 'inventory.adjust', ''),
  'reclassification': MoveType('Reclassify', 'Reclassification', 'products.manage', ''),
  'production_use': MoveType('Production use', 'Production use', 'production.create', ''),
  'production_output': MoveType('Into curing', 'Production — curing', 'production.create', ''),
  'curing_release': MoveType('Quality release', 'Quality release', 'production.complete', ''),
  'sale_delivery': MoveType('Sale delivery', 'Sale delivery', 'sales.create', ''),
};

/// Corrective entries need an org admin's approval unless the person is one (033)
bool isCorrective(String type, String? date, String today) =>
    ['adjustment', 'opening_balance', 'reversal'].contains(type) || (date != null && date.compareTo(today) < 0);

class UnitF {
  const UnitF(this.id, this.factor);
  final String id;
  final double factor;
}

class Item {
  Item({
    required this.key, required this.kind, required this.id, required this.name, this.code, this.status, this.branchId,
    this.rank = 999, this.materialCategory, this.inRecipes = true, this.stockUnitId, this.mainUnitId, this.units = const [],
    this.ref, this.size, this.category, this.categoryId, this.colorIds = const [],
  });
  final String key, kind, id, name;
  final String? code, status, branchId, materialCategory, stockUnitId, mainUnitId, ref, size, category, categoryId;
  final int rank;
  final bool inRecipes;
  final List<UnitF> units;
  final List<String> colorIds;
  bool get isProduct => kind == 'product';
}

class Store {
  Store(this.row);
  final Json row;
  String get id => row['id'];
  String get name => '${row['name']}';
  String get branchId => '${row['branch_id']}';
  String? get type => row['type'];
  String? get status => row['status'];
  bool get receivesProduction => row['receives_production'] != false;
  String get branchName => '${row['branch']?['name'] ?? ''}';
}

/// "Dodoma — Raw Materials Store"
String warehouseLabel(Store? w) => w == null ? '—' : '${w.branchName} — ${w.name}';

class Refs {
  Refs({required this.warehouses, required this.items, required this.unitById, required this.colorById, required this.suppliers,
      required this.carriedByBranch, required this.categoryRows});
  final List<Store> warehouses;
  final Map<String, Item> items;
  final Map<String, Json> unitById;
  final Map<String, Json> colorById;
  final List<Json> suppliers;
  final Map<String, Set<String>> carriedByBranch;
  final List<Json> categoryRows;

  String unit(String? id) => '${unitById[id]?['symbol'] ?? ''}';
  String colour(String? id) => '${colorById[id]?['name'] ?? ''}';
  Store? store(String? id) => warehouses.where((w) => w.id == id).firstOrNull;
  String productLabel(String? pid, [String? cid]) =>
      [items['p:$pid']?.name ?? '?', if (cid != null && cid.isNotEmpty) colour(cid)].where((x) => x.isNotEmpty).join(' ');

  static Refs? _last;
  static DateTime? savedAt;

  /// Reference data every inventory screen needs, in one round trip (saved for offline)
  static Future<Refs> load({bool fresh = false}) async {
    if (!fresh && _last != null) return _last!;
    final (raw, at) = await offline.load<Json>('refs', () async {
      final res = await Future.wait<dynamic>([
        db.from('warehouses').select('*, branch:branches(id, name, status)').order('name', ascending: true),
        db.from('materials').select('*, category:material_categories(*), conversions:material_unit_conversions(unit_id, factor_to_stock_unit)').order('name', ascending: true),
        db.from('products').select('*, category:product_categories(name)').order('canonical_name', ascending: true),
        db.from('units').select('id, symbol, name'),
        db.from('suppliers').select('id, name, status').order('name', ascending: true),
        db.from('product_category_colors').select('category_id, color_id, display_order'),
        db.from('product_categories').select('id, name, parent_category_id, sort_order, status'),
        db.from('color_palette').select('id, name, display_order, is_active'),
        db.from('branch_products').select('branch_id, product_id').eq('status', 'active'),
        db.from('product_colors').select('product_id, color_id, display_order').then<List>((v) => v).catchError((_) => <dynamic>[]),
      ]);
      return {
        'wh': res[0], 'mat': res[1], 'prod': res[2], 'units': res[3], 'sup': res[4], 'cats': res[5],
        'catRows': res[6], 'colors': res[7], 'bp': res[8], 'own': res[9],
      };
    });
    savedAt = at;
    List<Json> l(String k) => [for (final x in (raw[k] as List? ?? [])) Map<String, dynamic>.from(x)];
    final warehouses = [for (final w in l('wh')) Store(w)]
      ..sort((a, b) => a.branchName.compareTo(b.branchName) != 0 ? a.branchName.compareTo(b.branchName) : a.name.compareTo(b.name));
    final items = <String, Item>{};
    for (final m in l('mat')) {
      final conv = [for (final c in (m['conversions'] as List? ?? [])) UnitF(c['unit_id'], n(c['factor_to_stock_unit']))];
      final main = m['main_unit_id'] as String?;
      items['m:${m['id']}'] = Item(
        key: 'm:${m['id']}', kind: 'material', id: m['id'], name: '${m['name']}', code: m['code'], status: m['status'], branchId: m['branch_id'],
        rank: (m['category']?['display_order'] as num?)?.toInt() ?? 999, materialCategory: m['category']?['name'],
        inRecipes: m['category']?['used_in_recipes'] != false, stockUnitId: m['stock_unit_id'],
        mainUnitId: main != null && main != m['stock_unit_id'] && conv.any((c) => c.id == main) ? main : null,
        units: m['stock_unit_id'] == null ? [] : [UnitF(m['stock_unit_id'], 1), ...conv],
      );
    }
    final cats = l('catRows');
    final catById = {for (final c in cats) c['id'] as String: c};
    String? catLabel(String? id) {
      final c = catById[id];
      if (c == null) return null;
      final g = c['parent_category_id'] != null ? catById[c['parent_category_id']] : null;
      return g != null ? '${g['name']} › ${c['name']}' : '${c['name']}';
    }
    final catColors = l('cats');
    final own = l('own');
    for (final p in l('prod')) {
      final rows = (p['own_colors'] == true ? own.where((c) => c['product_id'] == p['id']) : catColors.where((c) => c['category_id'] == p['category_id'])).toList()
        ..sort((a, b) => n(a['display_order']).compareTo(n(b['display_order'])));
      items['p:${p['id']}'] = Item(
        key: 'p:${p['id']}', kind: 'product', id: p['id'], name: '${p['canonical_name']}', ref: p['product_id_ref'], size: p['size_cm'],
        category: catLabel(p['category_id']) ?? p['category']?['name'], categoryId: p['category_id'], status: p['status'],
        stockUnitId: p['unit_id'], units: p['unit_id'] == null ? [] : [UnitF(p['unit_id'], 1)],
        colorIds: [for (final r in rows) r['color_id'] as String],
      );
    }
    final carried = <String, Set<String>>{};
    for (final r in l('bp')) {
      carried.putIfAbsent(r['branch_id'], () => <String>{}).add(r['product_id']);
    }
    _last = Refs(
      warehouses: warehouses, items: items,
      unitById: {for (final u in l('units')) u['id'] as String: u},
      colorById: {for (final c in l('colors')) c['id'] as String: c},
      suppliers: l('sup'), carriedByBranch: carried, categoryRows: cats,
    );
    return _last!;
  }

  static void clear() { _last = null; savedAt = null; }
}

/// A material's main unit (051) as {id, factor}, or null when it is the stock unit
UnitF? mainUnitOf(Item? item) {
  if (item?.mainUnitId == null) return null;
  final u = item!.units.where((x) => x.id == item.mainUnitId).firstOrNull;
  return u != null && u.factor > 0 ? u : null;
}

int byMaterialOrder(Item a, Item b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : a.name.compareTo(b.name);

// ---- lib/categories.js ------------------------------------------------------------------
int _cmp(List<num> a, List<num> b) {
  for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

class CategoryTools {
  CategoryTools(List<Json> categories) {
    byId = {for (final c in categories) c['id'] as String: c};
    groupIds = {for (final c in categories) if (c['parent_category_id'] != null) c['parent_category_id'] as String};
    ordered = [...categories]..sort((a, b) {
        final k = _cmp(orderKey(a), orderKey(b));
        return k != 0 ? k : label(a).compareTo(label(b));
      });
  }
  late final Map<String, Json> byId;
  late final Set<String> groupIds;
  late final List<Json> ordered;

  Json? parentOf(Json? c) => c?['parent_category_id'] != null ? byId[c!['parent_category_id']] : null;
  String label(Object? cOrId, [String sep = ' › ']) {
    final c = cOrId is String ? byId[cOrId] : cOrId as Json?;
    if (c == null) return '—';
    final p = parentOf(c);
    return p != null ? '${p['name']}$sep${c['name']}' : '${c['name']}';
  }

  List<num> orderKey(Json c) {
    final p = parentOf(c);
    return p != null ? [n(p['sort_order']), 1, n(c['sort_order'])] : [n(c['sort_order']), 0, 0];
  }

  int compare(Json a, Json b) => _cmp(orderKey(a), orderKey(b));
  bool isGroup(String id) => groupIds.contains(id);
  List<Json> childrenOf(String id) => ordered.where((c) => c['parent_category_id'] == id).toList();
  List<Json> get leaves => ordered.where((c) => !groupIds.contains(c['id'])).toList();
}

/// Size as a sort key: area first, then each dimension; "mm" sizes in mm, the rest in cm
List<double> sizeKey(String? size) {
  if (size == null || size.isEmpty) return [double.infinity];
  final mm = size.toLowerCase().contains('mm');
  final nums = [for (final m in RegExp(r'\d+(?:\.\d+)?').allMatches(size)) double.parse(m[0]!) / (mm ? 10 : 1)];
  if (nums.isEmpty) return [double.infinity];
  return [nums.length >= 2 ? nums[0] * nums[1] : nums[0], ...nums];
}

int compareKeys(List<double> a, List<double> b) {
  for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
    final x = i < a.length ? a[i] : -1.0, y = i < b.length ? b[i] : -1.0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

/// Natural compare ("Tofali 5" before "Tofali 10")
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+|\D+)');
  final ma = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final mb = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < ma.length && i < mb.length; i++) {
    final x = int.tryParse(ma[i]), y = int.tryParse(mb[i]);
    final c = x != null && y != null ? x.compareTo(y) : ma[i].compareTo(mb[i]);
    if (c != 0) return c;
  }
  return ma.length.compareTo(mb.length);
}

/// The order products appear in everywhere: category order, size smallest first, name
int Function(Item, Item) productOrder(CategoryTools cats) => (a, b) {
      final ca = cats.byId[a.categoryId], cb = cats.byId[b.categoryId];
      final c = ca != null && cb != null ? cats.compare(ca, cb) : 0;
      if (c != 0) return c;
      final s = compareKeys(sizeKey(a.size), sizeKey(b.size));
      return s != 0 ? s : naturalCompare(a.name, b.name);
    };

/// Category chips from categoryTools (top-level, with their children)
List<({String id, String label, List<({String id, String label})>? children})> categoryChipItems(CategoryTools cats, bool Function(Json) keep) => [
      for (final c in cats.ordered.where((c) => c['parent_category_id'] == null && keep(c)))
        (
          id: c['id'] as String,
          label: '${c['name']}',
          children: cats.isGroup(c['id']) ? [for (final k in cats.childrenOf(c['id'])) (id: k['id'] as String, label: '${k['name']}')] : null,
        ),
    ];
