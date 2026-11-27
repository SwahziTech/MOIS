import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import 'products.dart' show EntityHistory;

/*
 * Recipe / BOM — a port of web pages/Recipes.jsx (approved 2026-11-24). Recipes belong to a branch
 * and are shared per category + colour or variant (011, 016, 031); a branch can start from another
 * branch's recipe (copy_recipe_to_branch). A saved version is never edited: changing ingredients
 * saves a new version (create_recipe_version, 020); which products use it changes in place.
 * The web's table is a card a recipe on the phone; Change / View opens a full-screen form.
 */
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
String variantName(Json r) => '${r['color']?['name'] ?? r['variant_label'] ?? '—'}';
String _key(Json r) => '${r['branch_id']}|${r['category_id']}|${r['color_id'] ?? ''}|${r['variant_label'] ?? ''}';

int _byIngredientOrder(Json a, Json b) {
  final c = n(a['material']?['category']?['display_order'] ?? 999).compareTo(n(b['material']?['category']?['display_order'] ?? 999));
  return c != 0 ? c : '${a['material']?['name'] ?? ''}'.compareTo('${b['material']?['name'] ?? ''}');
}

String _qty(Object? v) => qtyText(n(v));

class _Data {
  _Data(Json j)
      : recipes = _l(j['recipes']), categories = _l(j['categories']), materials = _l(j['materials']),
        units = _l(j['units']), products = _l(j['products']), carried = _l(j['carried']) {
    for (final b in _l(j['branches'])) { branchNames['${b['id']}'] = '${b['name']}'; }
    for (final p in _l(j['people'])) {
      people['${p['id']}'] = [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ');
      if (people['${p['id']}']!.isEmpty) people['${p['id']}'] = '${p['email']}';
    }
    recipes.sort((a, b) {
      int c = n(a['category']?['sort_order']).compareTo(n(b['category']?['sort_order']));
      if (c != 0) return c;
      c = '${a['category']?['name'] ?? ''}'.compareTo('${b['category']?['name'] ?? ''}');
      if (c != 0) return c;
      c = n(a['color']?['display_order'] ?? 999).compareTo(n(b['color']?['display_order'] ?? 999));
      if (c != 0) return c;
      c = '${a['variant_label'] ?? ''}'.compareTo('${b['variant_label'] ?? ''}');
      return c != 0 ? c : n(b['version_number']).compareTo(n(a['version_number']));
    });
    cats = CategoryTools(categories);
  }
  final List<Json> recipes, categories, materials, units, products, carried;
  final Map<String, String> branchNames = {}, people = {};
  late final CategoryTools cats;
}

Future<Json> _fetch() async {
  final r = await Future.wait<dynamic>([
    db.from('recipe_versions').select('id, branch_id, copied_from_version_id, category_id, color_id, variant_label, version_number, effective_date, status, notes, created_by, created_at, '
        'color:color_palette(name, display_order), category:product_categories(name, sort_order), '
        'items:recipe_items(material_id, quantity, unit_id, quantity_confirmed, notes, material:materials(name, category:material_categories(display_order)), unit:units(symbol)), '
        'links:recipe_version_products(product_id)').order('version_number', ascending: true),
    db.from('product_categories').select('id, name, sort_order, status, parent_category_id, colors:product_category_colors(color_id, display_order, color:color_palette(name, is_active))').order('sort_order', ascending: true),
    db.from('materials').select('id, name, status, stock_unit_id, branch_id, category:material_categories(*), conversions:material_unit_conversions(unit_id)').order('name', ascending: true),
    db.from('units').select('id, symbol, name'),
    db.from('products').select('id, canonical_name, product_id_ref, size_cm, category_id, status').order('canonical_name', ascending: true),
    db.from('branches').select('id, name'),
    db.from('branch_products').select('branch_id, product_id, status'),
  ]);
  final ids = {for (final x in r[0] as List) if (x['created_by'] != null) '${x['created_by']}'}.toList();
  final people = ids.isEmpty ? [] : await db.from('profiles').select('id, first_name, last_name, email').inFilter('id', ids);
  return {'recipes': r[0], 'categories': r[1], 'materials': r[2], 'units': r[3], 'products': r[4], 'branches': r[5], 'carried': r[6], 'people': people};
}

/// The ingredients as small badges: material: quantity unit (* = not yet confirmed)
class IngredientBadges extends StatelessWidget {
  const IngredientBadges(this.items, {super.key});
  final List<Json> items;
  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return PlHelp('—');
    return Wrap(spacing: 4, runSpacing: 4, children: [
      for (final it in [...items]..sort(_byIngredientOrder))
        Badge2('${it['material']?['name'] ?? ''}: ${_qty(it['quantity'])}${it['unit']?['symbol'] != null ? ' ${it['unit']['symbol']}' : ''}${it['quantity_confirmed'] == true ? '' : ' *'}'),
    ]);
  }
}

class RecipesPage extends StatefulWidget {
  const RecipesPage({super.key});
  @override
  State<RecipesPage> createState() => _RecipesPageState();
}

class _RecipesPageState extends State<RecipesPage> {
  _Data? _d;
  DateTime? _savedAt;
  String _error = '', _search = '', _status = 'active', _categoryId = '', _sortBy = 'category';

  String get branchId => session.branchId;
  bool canWriteAt(Object? id) => id != null && '$id'.isNotEmpty && session.canAt('products.manage', '$id', null);

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final (j, at) = await offline.load<Json>('recipes', _fetch);
      if (mounted) setState(() { _d = _Data(j); _savedAt = at; });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load this page. Please try again.");
    }
  }

  Future<void> _open(Json? recipe) async {
    final d = _d!;
    final bid = '${recipe?['branch_id'] ?? branchId}';
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _RecipeForm(
          data: d, recipe: recipe, branchId: bid, branchName: d.branchNames[bid] ?? session.branchName ?? '',
          versions: recipe == null ? [] : d.recipes.where((r) => _key(r) == _key(recipe)).toList(),
          carriedIds: {for (final c in d.carried) if (c['branch_id'] == bid && c['status'] == 'active') '${c['product_id']}'},
        )));
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final d = _d;
    if (_error.isNotEmpty && d == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    if (d == null) return ListView(padding: const EdgeInsets.all(14), children: const [Skeleton(rows: 6)]);
    final q = _search.trim().toLowerCase();
    final view = d.recipes.where((r) =>
        session.inBranch(r['branch_id']) &&
        (_status == 'all' || r['status'] == _status) &&
        (q.isEmpty || '${r['category']?['name'] ?? ''}'.toLowerCase().contains(q) || variantName(r).toLowerCase().contains(q)) &&
        (_categoryId.isEmpty || r['category_id'] == _categoryId || d.cats.byId[r['category_id']]?['parent_category_id'] == _categoryId)).toList();
    if (_sortBy == 'newest') view.sort((a, b) => '${b['created_at']}'.compareTo('${a['created_at']}'));
    if (_sortBy == 'effective') view.sort((a, b) => '${b['effective_date']}'.compareTo('${a['effective_date']}'));
    final chips = [for (final c in categoryChipItems(d.cats, (c) => c['status'] == 'active')) ChipItem(c.id, c.label, c.children?.map((k) => ChipItem(k.id, k.label)).toList())];
    final canWrite = canWriteAt(branchId);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: !canWrite
          ? null
          : FloatingActionButton(
              tooltip: 'New recipe',
              backgroundColor: t.dark ? C.khaki : C.charcoal,
              foregroundColor: t.dark ? C.charcoal : Colors.white,
              onPressed: () => _open(null),
              child: const Icon(LucideIcons.plus),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 88), children: [
          OfflineNote(_savedAt),
          if (branchId.isEmpty) const Padding(padding: EdgeInsets.only(bottom: 8), child: PlHelp('Pick a branch in the menu to add a recipe.')),
          ListToolbar(
            placeholder: 'Search category or colour…',
            onSearch: (v) => setState(() => _search = v),
            sort: SortSpec(value: _sortBy, onChange: (v) => setState(() => _sortBy = v), options: const [
              ('category', 'By category and colour (default)'), ('newest', 'Newest version first'), ('effective', 'Effective date: newest first'),
            ]),
            filters: [
              FilterSpec(key: 'status', label: 'Status', value: _status, onChange: (v) => setState(() => _status = v),
                  options: const [('active', 'Active'), ('archived', 'Archived'), ('all', 'All versions')]),
            ],
          ),
          ChipRow(items: chips, value: _categoryId, onChange: (v) => setState(() => _categoryId = v)),
          const SizedBox(height: 10),
          if (view.isEmpty)
            EmptyState(icon: LucideIcons.scrollText, title: 'No recipes found', description: _search.isNotEmpty ? 'No recipes match "$_search".' : 'No recipes in this view.')
          else ...[
            for (final r in view)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: t.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: canWriteAt(r['branch_id']) ? () => _open(r) : null,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                              Text(d.cats.label(r['category_id']), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.md)),
                              Badge2(variantName(r), tone: Tone.info),
                              Text('v${r['version_number']}', style: TextStyle(fontSize: Fs.sm, color: t.textSecondary)),
                            ]),
                          ),
                          Badge2('${r['status']}', tone: r['status'] == 'active' ? Tone.success : Tone.neutral),
                        ]),
                        const SizedBox(height: 4),
                        PlHelp([
                          if (branchId.isEmpty) d.branchNames['${r['branch_id']}'] ?? '—',
                          '${(r['links'] as List?)?.length ?? 0} products',
                          'from ${tableDate(r['effective_date']) ?? '—'}',
                        ].join(' · ')),
                        const SizedBox(height: 6),
                        IngredientBadges(_l(r['items'])),
                        if (canWriteAt(r['branch_id']))
                          Align(alignment: Alignment.centerRight, child: Text(r['status'] == 'active' ? 'Change' : 'View', style: const TextStyle(fontSize: Fs.sm, color: C.khaki, fontWeight: FontWeight.w600))),
                      ]),
                    ),
                  ),
                ),
              ),
            PlHelp('${view.length} recipe version${view.length != 1 ? 's' : ''} · * quantity not yet confirmed'),
          ],
        ]),
      ),
    );
  }
}

class _Row {
  _Row({this.materialId = '', this.quantity = '', this.unitId = '', this.confirmed = true, this.notes});
  String materialId, quantity, unitId;
  bool confirmed;
  Object? notes;
  late final qty = TextEditingController(text: quantity);
}

List<_Row> _toRows(List<Json> items) => [
      for (final it in [...items]..sort(_byIngredientOrder))
        _Row(materialId: '${it['material_id']}', quantity: '${it['quantity']}', unitId: '${it['unit_id'] ?? ''}', confirmed: it['quantity_confirmed'] == true, notes: it['notes']),
    ];

bool _sameItems(List<_Row> rows, List<Json> items) {
  String norm(Iterable<String> l) => (l.toList()..sort()).join(';');
  return norm(rows.map((r) => '${r.materialId}|${double.tryParse(r.qty.text.trim())}|${r.unitId}|${r.confirmed}')) ==
      norm(items.map((i) => '${i['material_id']}|${double.tryParse('${i['quantity']}')}|${i['unit_id'] ?? ''}|${i['quantity_confirmed'] == true}'));
}

class _RecipeForm extends StatefulWidget {
  const _RecipeForm({required this.data, required this.recipe, required this.versions, required this.branchId, required this.branchName, required this.carriedIds});
  final _Data data;
  final Json? recipe;
  final List<Json> versions;
  final String branchId, branchName;
  final Set<String> carriedIds;
  @override
  State<_RecipeForm> createState() => _RecipeFormState();
}

class _RecipeFormState extends State<_RecipeForm> {
  _Data get d => widget.data;
  Json? get recipe => widget.recipe;
  bool get isNew => recipe == null;
  late final Json? active = widget.versions.where((v) => v['status'] == 'active').firstOrNull;
  bool get readOnly => !isNew && active == null;   // every version archived: recipe retired
  late String _categoryId = '${recipe?['category_id'] ?? ''}';
  String _kind = 'color', _colorId = '';
  final _variant = TextEditingController();
  late List<_Row> _rows = _toRows(_l((active ?? recipe)?['items']));
  late final Set<String> _linked = {for (final l in _l((active ?? recipe)?['links'])) '${l['product_id']}'};
  late String _effective = session.today;
  final _notes = TextEditingController();
  String? _viewing;
  bool _busy = false;
  String _error = '';

  Json? _material(String id) => d.materials.where((m) => m['id'] == id).firstOrNull;
  String _unitSym(String id) => '${d.units.where((u) => u['id'] == id).firstOrNull?['symbol'] ?? ''}';
  List<String> _unitChoices(String materialId) {
    final m = _material(materialId);
    if (m == null) return [];
    return {if (m['stock_unit_id'] != null) '${m['stock_unit_id']}', for (final c in _l(m['conversions'])) if (c['unit_id'] != null) '${c['unit_id']}'}.toList();
  }

  int get _nextVersion => widget.versions.fold<int>(0, (m, v) => n(v['version_number']).toInt() > m ? n(v['version_number']).toInt() : m) + 1;
  bool get _willVersion => !isNew && active != null && !_sameItems(_rows, _l(active!['items']));

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
    void fail(String m) => setState(() => _error = m);
    if (_rows.isEmpty) return fail('A recipe needs at least one ingredient.');
    final ids = _rows.map((r) => r.materialId).toList();
    if (ids.any((x) => x.isEmpty)) return fail('Choose a material for every ingredient line.');
    if (ids.toSet().length != ids.length) return fail('Each material can appear only once in a recipe.');
    if (_rows.any((r) => r.qty.text.trim().isEmpty || !((double.tryParse(r.qty.text.trim()) ?? -1) >= 0))) return fail('Every quantity must be zero or more.');
    if (_rows.any((r) => r.unitId.isEmpty)) return fail("Choose a unit for every ingredient — add the material's units under Materials first.");
    if (isNew && _kind == 'color' && _colorId.isEmpty) return fail('Choose the colour this recipe is for.');
    if (isNew && _kind == 'variant' && _variant.text.trim().isEmpty) return fail('Name the variant, e.g. the mix name.');
    final items = [
      for (final r in _rows) {'material_id': r.materialId, 'quantity': double.parse(r.qty.text.trim()), 'unit_id': r.unitId, 'quantity_confirmed': r.confirmed, 'notes': r.notes},
    ];
    // only the products changed: update the links of the current version in place
    if (!isNew && _sameItems(_rows, _l(active!['items']))) {
      final before = {for (final l in _l(active!['links'])) '${l['product_id']}'};
      final add = _linked.where((x) => !before.contains(x)).toList();
      final remove = before.where((x) => !_linked.contains(x)).toList();
      if (add.isEmpty && remove.isEmpty) return fail('Nothing has changed.');
      return _run(() async {
        if (add.isNotEmpty) await db.from('recipe_version_products').insert([for (final p in add) {'recipe_version_id': active!['id'], 'product_id': p}]);
        if (remove.isNotEmpty) await db.from('recipe_version_products').delete().eq('recipe_version_id', active!['id']).inFilter('product_id', remove);
      });
    }
    await _run(() async => db.rpc('create_recipe_version', params: {
          'p_branch_id': isNew ? widget.branchId : null,
          'p_replaces': active?['id'],
          'p_category_id': isNew ? _categoryId : null,
          'p_color_id': isNew && _kind == 'color' ? _colorId : null,
          'p_variant_label': isNew && _kind == 'variant' ? _variant.text.trim() : null,
          'p_items': items,
          'p_product_ids': _linked.toList(),
          'p_effective_date': _effective.isEmpty ? null : _effective,
          'p_notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        }));
  }

  Future<void> _retire() async {
    final links = _l(active!['links']).length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text('Archive v${active!['version_number']} with no replacement? Its $links product${links == 1 ? '' : 's'} will have no active recipe for ${variantName(recipe!)}.'),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Retire recipe'))],
      ),
    );
    if (ok == true) await _run(() async => db.from('recipe_versions').update({'status': 'archived'}).eq('id', active!['id']));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final category = d.categories.where((c) => c['id'] == _categoryId).firstOrNull;
    final categoryProducts = d.products.where((p) => p['category_id'] == _categoryId && ((p['status'] == 'active' && widget.carriedIds.contains(p['id'])) || _linked.contains(p['id']))).toList();
    final taken = {for (final r in d.recipes) if (r['branch_id'] == widget.branchId && r['category_id'] == _categoryId && r['status'] == 'active' && r['color_id'] != null) '${r['color_id']}'};
    final freeColours = _l(category?['colors']).where((c) => c['color']?['is_active'] == true && !taken.contains('${c['color_id']}')).toList()
      ..sort((a, b) => n(a['display_order']).compareTo(n(b['display_order'])));
    final otherBranches = isNew
        ? d.recipes.where((r) => r['branch_id'] != widget.branchId && r['status'] == 'active' && r['category_id'] == _categoryId &&
            (_kind == 'color' ? _colorId.isNotEmpty && r['color_id'] == _colorId : _variant.text.trim().isNotEmpty && '${r['variant_label'] ?? ''}'.toLowerCase() == _variant.text.trim().toLowerCase())).toList()
        : <Json>[];
    final usable = d.materials.where((m) => m['status'] == 'active' && (m['branch_id'] == null || m['branch_id'] == widget.branchId) && m['category']?['used_in_recipes'] != false).toList()
      ..sort((x, y) {
        final c = n(x['category']?['display_order'] ?? 999).compareTo(n(y['category']?['display_order'] ?? 999));
        return c != 0 ? c : '${x['name']}'.compareTo('${y['name']}');
      });
    final title = '${isNew ? 'Add recipe' : '${d.cats.label(recipe!['category_id'])} — ${variantName(recipe!)}'}${widget.branchName.isNotEmpty ? ' · ${widget.branchName}' : ''}';
    final versions = [...widget.versions]..sort((a, b) => n(b['version_number']).compareTo(n(a['version_number'])));

    return FullPage(
      title: title,
      footer: readOnly
          ? [OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))]
          : [
              OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(onPressed: _busy ? null : _save, child: Text(isNew ? 'Add recipe' : _willVersion ? 'Save as v$_nextVersion' : 'Save')),
            ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        if (isNew) ...[
          DropdownButtonFormField<String>(
            initialValue: _categoryId.isEmpty ? null : _categoryId, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Category'),
            items: [for (final c in d.cats.leaves.where((c) => c['status'] == 'active')) DropdownMenuItem(value: '${c['id']}', child: Text(d.cats.label(c), overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() { _categoryId = v ?? ''; _colorId = ''; _linked.clear(); }),
          ),
          const SizedBox(height: 12),
          Row(children: [
            SizedBox(
              width: 150,
              child: DropdownButtonFormField<String>(
                initialValue: _kind, decoration: const InputDecoration(labelText: 'For'),
                items: const [DropdownMenuItem(value: 'color', child: Text('A colour')), DropdownMenuItem(value: 'variant', child: Text('A named variant'))],
                onChanged: (v) => setState(() => _kind = v ?? 'color'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _kind == 'color'
                  ? DropdownButtonFormField<String>(
                      key: ValueKey('col$_categoryId'),
                      initialValue: _colorId.isEmpty ? null : _colorId, isExpanded: true,
                      decoration: InputDecoration(labelText: 'Colour', hintText: _categoryId.isEmpty ? 'Choose a category first' : freeColours.isNotEmpty ? 'Choose…' : 'All colours have a recipe'),
                      items: [for (final c in freeColours) DropdownMenuItem(value: '${c['color_id']}', child: Text('${c['color']['name']}'))],
                      onChanged: _categoryId.isEmpty ? null : (v) => setState(() => _colorId = v ?? ''),
                    )
                  : TextField(controller: _variant, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Variant name', hintText: 'e.g. Press mix')),
            ),
          ]),
        ],
        if (otherBranches.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final o in otherBranches)
            Alert('${d.branchNames['${o['branch_id']}']} already has this recipe (v${o['version_number']}). The copy becomes ${widget.branchName}\'s own: later changes in either branch don\'t carry over.',
                tone: Tone.info,
                action: TextButton(
                  onPressed: _busy ? null : () => _run(() async => db.rpc('copy_recipe_to_branch', params: {
                        'p_version_id': o['id'], 'p_branch_id': widget.branchId, 'p_notes': "Started from ${d.branchNames['${o['branch_id']}'] ?? 'another branch'}'s recipe",
                      })),
                  child: Text('Copy it to ${widget.branchName}'),
                )),
        ],
        if (readOnly)
          const Padding(padding: EdgeInsets.only(top: 8), child: PlHelp('Retired. History below.'))
        else ...[
          const SectionTitle('Ingredients (per batch)'),
          for (var i = 0; i < _rows.length; i++) _ingredient(i, usable),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: () => setState(() => _rows = [..._rows, _Row()]), icon: const Icon(LucideIcons.plus, size: 14), label: const Text('Add ingredient')),
          ),
          if (isNew || _willVersion) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () async {
                final x = await showDatePicker(context: context, initialDate: DateTime.parse(_effective), firstDate: DateTime(2020), lastDate: DateTime(2100));
                if (x != null) setState(() => _effective = iso(x));
              },
              icon: const Icon(LucideIcons.calendar, size: 15),
              label: Text('Effective from ${dateText(_effective)}'),
            ),
            const SizedBox(height: 10),
            TextField(controller: _notes, decoration: const InputDecoration(labelText: 'What changed and why', hintText: 'Optional')),
          ],
          if (_willVersion) Padding(padding: const EdgeInsets.only(top: 6), child: PlHelp('Saving creates version $_nextVersion; v${active!['version_number']} is archived unchanged.')),
          if (_categoryId.isNotEmpty) ...[
            SectionTitle('Products using this recipe (${_linked.length})'),
            if (categoryProducts.isEmpty)
              PlHelp('No products of this category at ${widget.branchName} (Products).')
            else
              Wrap(spacing: 6, runSpacing: 6, children: [
                for (final p in categoryProducts)
                  FilterChip(
                    selected: _linked.contains(p['id']),
                    tooltip: p['size_cm'] != null ? 'Size ${p['size_cm']}' : null,
                    label: Text('${p['canonical_name']}${p['status'] != 'active' ? ' (inactive)' : ''}'),
                    onSelected: (_) => setState(() => _linked.contains(p['id']) ? _linked.remove(p['id']) : _linked.add('${p['id']}')),
                  ),
              ]),
          ],
          if (!isNew && active != null) ...[
            const SectionTitle('Retire'),
            Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: _busy ? null : _retire, child: const Text('Retire this recipe…'))),
          ],
        ],
        if (versions.isNotEmpty) ...[
          const SectionTitle('Versions'),
          for (final v in versions)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('v${v['version_number']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Badge2('${v['status']}', tone: v['status'] == 'active' ? Tone.success : Tone.neutral),
                  PlHelp('from ${dateText(v['effective_date']) ?? '—'}${v['created_by'] != null ? ' · ${d.people['${v['created_by']}'] ?? 'a user'}' : ' · data import'}'),
                  if (v['status'] != 'active')
                    TextButton(onPressed: () => setState(() => _viewing = _viewing == v['id'] ? null : '${v['id']}'), child: Text(_viewing == v['id'] ? 'Hide' : 'Show')),
                  if (v['status'] != 'active' && active != null)
                    TextButton(onPressed: () => setState(() => _rows = _toRows(_l(v['items']))), child: const Text('Start from this version')),
                ]),
                if (v['notes'] != null) PlHelp('${v['notes']}'),
                if (v['copied_from_version_id'] != null)
                  Builder(builder: (_) {
                    final src = d.recipes.where((x) => x['id'] == v['copied_from_version_id']).firstOrNull;
                    return src == null ? const SizedBox.shrink() : PlHelp("Started from ${d.branchNames['${src['branch_id']}'] ?? 'another branch'}'s v${src['version_number']}");
                  }),
                if (_viewing == v['id'] || (readOnly && v == widget.versions.last)) Padding(padding: const EdgeInsets.only(top: 6), child: IngredientBadges(_l(v['items']))),
              ]),
            ),
        ],
        if (active != null) EntityHistory(entityType: 'recipe_version', entityId: '${active!['id']}'),
      ],
    );
  }

  Widget _ingredient(int i, List<Json> usable) {
    final r = _rows[i];
    final t = context.tk;
    final mats = [...usable, if (r.materialId.isNotEmpty && !usable.any((m) => m['id'] == r.materialId) && _material(r.materialId) != null) _material(r.materialId)!];
    final units = _unitChoices(r.materialId);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 6),
      decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(8)),
      child: Column(children: [
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey('m$i${r.materialId}'),
              initialValue: r.materialId.isEmpty ? null : r.materialId, isExpanded: true,
              decoration: const InputDecoration(labelText: 'Material'),
              items: [for (final m in mats) DropdownMenuItem(value: '${m['id']}', child: Text('${m['name']}${m['status'] != 'active' ? ' (inactive)' : ''}', overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() {
                r.materialId = v ?? '';
                // a new material keeps the unit only if that material allows it
                if (!_unitChoices(r.materialId).contains(r.unitId)) r.unitId = '${_material(r.materialId)?['stock_unit_id'] ?? ''}';
              }),
            ),
          ),
          IconButton(tooltip: 'Remove ingredient', onPressed: () => setState(() => _rows = [..._rows]..removeAt(i)), icon: const Icon(LucideIcons.trash2, size: 16)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: r.qty, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Quantity'))),
          const SizedBox(width: 8),
          SizedBox(
            width: 96,
            child: DropdownButtonFormField<String>(
              key: ValueKey('u$i${r.materialId}${r.unitId}'),
              initialValue: units.contains(r.unitId) ? r.unitId : null,
              decoration: const InputDecoration(labelText: 'Unit'),
              items: [for (final u in units) DropdownMenuItem(value: u, child: Text(_unitSym(u)))],
              onChanged: (v) => setState(() => r.unitId = v ?? ''),
            ),
          ),
          Tooltip(
            message: 'Untick if this quantity still needs confirming',
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Checkbox(value: r.confirmed, onChanged: (v) => setState(() => r.confirmed = v ?? false)),
              const Text('confirmed', style: TextStyle(fontSize: Fs.xs)),
            ]),
          ),
        ]),
      ]),
    );
  }
}
