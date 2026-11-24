import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import 'products.dart' show EntityFlags, EntityHistory, numOrNull, p6;

/*
 * Categories — a port of web pages/Categories.jsx (approved 2026-11-24): name, layout, suggested
 * unit and the colours products in the category come in; groups (038) with the categories under
 * them. Deactivate-only; a category with active products can't be deactivated. The web's table
 * is a row a category on the phone; editing opens a full-screen form.
 */
const _layouts = {'colored': 'By colour', 'plain': 'Single price'};

String slugify(String name) {
  final s = name.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  return s.isEmpty ? 'item' : s;
}

List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];

class CategoriesPage extends StatefulWidget {
  const CategoriesPage({super.key});
  @override
  State<CategoriesPage> createState() => _CategoriesPageState();
}

class _CategoriesPageState extends State<CategoriesPage> {
  List<Json>? _categories;
  List<Json> _palette = [], _units = [];
  DateTime? _savedAt;
  String _error = '';
  bool get canWrite => session.canManage('products.manage');

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final (j, at) = await offline.load<Json>('categories', () async {
        final r = await Future.wait<dynamic>([
          db.from('product_categories')
              .select('id, category_id_ref, name, display_format, sort_order, status, default_unit_id, default_yield_tolerance, parent_category_id, unit:units(symbol, name), colors:product_category_colors(color_id, display_order), products(count)')
              .eq('products.status', 'active').order('sort_order').order('name'),
          db.from('color_palette').select('id, name, display_order, is_active').order('display_order').order('name'),
          db.from('units').select('id, symbol, name, status').order('symbol'),
        ]);
        return {'categories': r[0], 'palette': r[1], 'units': r[2]};
      });
      if (mounted) setState(() { _categories = _l(j['categories']); _palette = _l(j['palette']); _units = _l(j['units']); _savedAt = at; });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load this page. Please try again.");
    }
  }

  Future<void> _edit(Json c) async {
    final cats = CategoryTools(_categories!);
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _CategoryForm(
          category: c, palette: _palette, units: _units, cats: cats,
          takenRefs: {for (final x in _categories!) '${x['category_id_ref']}'},
          nextOrder: _categories!.fold<num>(0, (m, x) => n(x['sort_order']) > m ? n(x['sort_order']) : m).toInt() + 1,
        )));
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final list = _categories;
    if (_error.isNotEmpty && list == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    if (list == null) return ListView(padding: const EdgeInsets.all(14), children: const [Skeleton(rows: 6)]);
    final cats = CategoryTools(list);
    String colourName(Object? id) => '${_palette.where((c) => c['id'] == id).firstOrNull?['name'] ?? ''}';
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: !canWrite
          ? null
          : FloatingActionButton(
              tooltip: 'New category',
              backgroundColor: t.dark ? C.khaki : C.charcoal,
              foregroundColor: t.dark ? C.charcoal : Colors.white,
              onPressed: () => _edit({}),
              child: const Icon(LucideIcons.plus),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 88), children: [
          OfflineNote(_savedAt),
          if (list.isEmpty)
            const EmptyState(icon: LucideIcons.folderTree, title: 'No categories yet', description: 'Group your products into categories.')
          else
            for (final c in cats.ordered)
              Padding(
                padding: EdgeInsets.only(bottom: 8, left: c['parent_category_id'] != null ? 18 : 0),
                child: Material(
                  color: t.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: canWrite ? () => _edit(c) : null,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
                      child: Row(children: [
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                              Text('${c['parent_category_id'] != null ? '↳ ' : ''}${c['name']}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.md)),
                              if (cats.isGroup('${c['id']}')) const Badge2('group'),
                              if (c['status'] != 'active') Badge2('${c['status']}'),
                            ]),
                            const SizedBox(height: 3),
                            Text(
                              '${_layouts[c['display_format']] ?? c['display_format']} · ${c['unit']?['symbol'] ?? '—'} · ${n(((c['products'] as List?)?.firstOrNull as Map?)?['count']).toInt()} active products',
                              style: TextStyle(fontSize: Fs.sm, color: t.textMuted),
                            ),
                            if ((c['colors'] as List?)?.isNotEmpty ?? false) ...[
                              const SizedBox(height: 4),
                              Wrap(spacing: 8, runSpacing: 4, children: [
                                for (final x in [..._l(c['colors'])]..sort((a, b) => n(a['display_order']).compareTo(n(b['display_order']))))
                                  if (colourName(x['color_id']).isNotEmpty) ColourDot(colourName(x['color_id'])),
                              ]),
                            ],
                          ]),
                        ),
                        if (canWrite) Icon(LucideIcons.pencil, size: 16, color: t.textSecondary),
                      ]),
                    ),
                  ),
                ),
              ),
        ]),
      ),
    );
  }
}

class _CategoryForm extends StatefulWidget {
  const _CategoryForm({required this.category, required this.palette, required this.units, required this.cats, required this.takenRefs, required this.nextOrder});
  final Json category;
  final List<Json> palette, units;
  final CategoryTools cats;
  final Set<String> takenRefs;
  final int nextOrder;
  @override
  State<_CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends State<_CategoryForm> {
  Json get c => widget.category;
  bool get isNew => c['id'] == null;
  late final Set<String> _initial = {for (final x in _l(c['colors'])) '${x['color_id']}'};
  late final _name = TextEditingController(text: '${c['name'] ?? ''}');
  late final _order = TextEditingController(text: '${c['sort_order'] ?? widget.nextOrder}');
  late final _tolerance = TextEditingController(text: c['default_yield_tolerance'] == null ? '' : p6(c['default_yield_tolerance']));
  late String _layout = '${c['display_format'] ?? 'colored'}';
  late String _unitId = '${c['default_unit_id'] ?? ''}';
  late String _parentId = '${c['parent_category_id'] ?? ''}';
  late final Set<String> _colours = {..._initial};
  Set<String> _used = {};   // colours with recipes/prices in this category
  bool _busy = false;
  String _error = '';

  bool get isGroup => !isNew && widget.cats.isGroup('${c['id']}');
  int get activeProducts => n(((c['products'] as List?)?.firstOrNull as Map?)?['count']).toInt();

  @override
  void initState() {
    super.initState();
    if (!isNew) _loadUsed();
  }

  // colours this category's recipes or colour prices depend on can't be removed here
  Future<void> _loadUsed() async {
    try {
      final r = await Future.wait<dynamic>([
        db.from('recipe_versions').select('color_id').eq('category_id', c['id']).eq('status', 'active').not('color_id', 'is', null),
        db.from('category_color_pricing_rules').select('base_color_id, items:category_color_price_items(color_id)').eq('category_id', c['id']),
      ]);
      final used = <String>{};
      for (final x in r[0] as List) { used.add('${x['color_id']}'); }
      for (final x in r[1] as List) {
        used.add('${x['base_color_id']}');
        for (final i in (x['items'] as List? ?? [])) { used.add('${i['color_id']}'); }
      }
      if (mounted) setState(() => _used = used);
    } catch (_) {}
  }

  String _uniqueRef(String name) {
    final base = slugify(name);
    var ref = base;
    for (var i = 2; widget.takenRefs.contains(ref); i++) { ref = '${base}_$i'; }
    return ref;
  }

  Future<void> _save() async {
    setState(() => _error = '');
    void fail(String m) => setState(() { _busy = false; _error = m; });
    if (_layout == 'colored' && _colours.isEmpty) return fail('Choose at least one colour, or use the single-price layout.');
    if (_layout == 'plain' && _colours.isNotEmpty) return fail('A single-price category has no colours — remove them first.');
    final tol = numOrNull(_tolerance.text);
    if (_tolerance.text.trim().isNotEmpty && !(tol != null && tol >= 0)) return fail('Default yield tolerance must be zero or more, or blank for the organization default.');
    setState(() => _busy = true);
    final org = session.organization!['id'];
    final row = {
      'name': _name.text.trim(), 'sort_order': int.tryParse(_order.text.trim()) ?? 0, 'display_format': _layout,
      'default_unit_id': _unitId.isEmpty ? null : _unitId, 'default_yield_tolerance': tol, 'parent_category_id': _parentId.isEmpty ? null : _parentId,
    };
    try {
      var id = '${c['id'] ?? ''}';
      if (isNew) {
        final res = await db.from('product_categories').insert({...row, 'organization_id': org, 'category_id_ref': _uniqueRef('${row['name']}')}).select('id').single();
        id = '${res['id']}';
      } else {
        await db.from('product_categories').update(row).eq('id', id);
      }
      final added = _colours.where((x) => !_initial.contains(x)).toList();
      final removed = _initial.where((x) => !_colours.contains(x)).toList();
      if (added.isNotEmpty) {
        await db.from('product_category_colors').insert([
          for (final cid in added)
            {'organization_id': org, 'category_id': id, 'color_id': cid, 'display_order': widget.palette.where((p) => p['id'] == cid).firstOrNull?['display_order'] ?? 0},
        ]);
      }
      if (removed.isNotEmpty) await db.from('product_category_colors').delete().eq('category_id', id).inFilter('color_id', removed);
    } catch (e) {
      return fail(dbError(e));
    }
    if (mounted) Navigator.pop(context, true);
  }

  Future<void> _toggleStatus() async {
    setState(() { _error = ''; _busy = true; });
    try {
      await db.from('product_categories').update({'status': c['status'] == 'active' ? 'inactive' : 'active'}).eq('id', c['id']);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = widget.cats;
    final groupChoices = cats.ordered.where((x) => x['parent_category_id'] == null && x['id'] != c['id']).toList();
    final choosable = widget.palette.where((p) => p['is_active'] == true || _initial.contains(p['id'])).toList();
    final units = widget.units.where((u) => u['status'] == 'active' || u['id'] == c['default_unit_id']).toList();
    Widget gap() => const SizedBox(height: 12);
    return FullPage(
      title: isNew ? 'Add category' : 'Edit ${c['name']}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy || _name.text.trim().isEmpty ? null : _save, child: const Text('Save')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        Row(children: [
          Expanded(flex: 2, child: TextField(controller: _name, autofocus: isNew, textCapitalization: TextCapitalization.words, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Name'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _order, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Display order'))),
        ]),
        gap(),
        DropdownButtonFormField<String>(
          initialValue: _layout, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Price layout'),
          items: [for (final e in _layouts.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => _layout = v ?? 'colored'),
        ),
        gap(),
        DropdownButtonFormField<String>(
          initialValue: _unitId, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Default unit for new products'),
          items: [const DropdownMenuItem(value: '', child: Text('None')), for (final u in units) DropdownMenuItem(value: '${u['id']}', child: Text('${u['symbol']} — ${u['name']}'))],
          onChanged: (v) => setState(() => _unitId = v ?? ''),
        ),
        gap(),
        if (isGroup)
          PlHelp('Group of: ${cats.childrenOf('${c['id']}').map((x) => x['name']).join(', ')}')
        else
          DropdownButtonFormField<String>(
            initialValue: _parentId, isExpanded: true,
            decoration: const InputDecoration(labelText: 'Group under'),
            items: [
              const DropdownMenuItem(value: '', child: Text('No group')),
              for (final g in groupChoices) DropdownMenuItem(value: '${g['id']}', child: Text('${g['name']}${cats.isGroup('${g['id']}') ? '' : ' (becomes a group)'}', overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => setState(() => _parentId = v ?? ''),
          ),
        PlHelp(_parentId.isNotEmpty ? 'Display order sets its place inside the group.' : 'A group is only a heading: its products, colours, recipes and prices live on the categories under it.'),
        gap(),
        TextField(controller: _tolerance, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Default yield tolerance (± pieces per bag)', hintText: 'Organization default')),
        const PlHelp('0 = exactly the average yield.'),
        if (_layout == 'colored' || _colours.isNotEmpty) ...[
          const SectionTitle('Colours'),
          if (choosable.isEmpty)
            const PlHelp('No colours in the palette yet — add them under Colours.')
          else
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final p in choosable)
                FilterChip(
                  selected: _colours.contains(p['id']),
                  showCheckmark: false,
                  avatar: CircleAvatar(radius: 6, backgroundColor: cssColour('${p['name']}')),
                  label: Text('${p['name']}${p['is_active'] != true ? ' (inactive)' : ''}${_colours.contains(p['id']) ? ' ✓' : ''}'),
                  tooltip: _colours.contains(p['id']) && _used.contains(p['id']) ? 'Used by a recipe or colour price in this category' : null,
                  onSelected: _colours.contains(p['id']) && _used.contains(p['id'])
                      ? null
                      : (_) => setState(() => _colours.contains(p['id']) ? _colours.remove(p['id']) : _colours.add('${p['id']}')),
                ),
            ]),
          if (_colours.any(_used.contains)) const Padding(padding: EdgeInsets.only(top: 6), child: PlHelp("Locked colours are used by this category's recipes or colour prices.")),
        ],
        if (!isNew) ...[
          const SectionTitle('Status'),
          if (c['status'] == 'active' && activeProducts > 0)
            PlHelp('$activeProducts active product${activeProducts == 1 ? ' is' : 's are'} in this category. Deactivate or move them first.')
          else ...[
            PlHelp(c['status'] == 'active' ? 'Deactivating hides it when adding products.' : 'Inactive — not offered when adding products.'),
            const SizedBox(height: 8),
            Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: _busy ? null : _toggleStatus, child: Text(c['status'] == 'active' ? 'Deactivate category' : 'Reactivate category'))),
          ],
          EntityFlags(entityType: 'product_category', entityId: '${c['id']}', canResolve: true),
          EntityHistory(entityType: 'product_category', entityId: '${c['id']}'),
        ],
      ],
    );
  }
}
