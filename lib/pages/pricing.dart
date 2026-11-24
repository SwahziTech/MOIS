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
 * Pricing — a port of web pages/Pricing.jsx (approved 2026-11-24): Product prices (a row a product,
 * its price at each branch in view; tap a price to change it) and Colour pricing (a card a coloured
 * category, a line a branch). Prices are kept with VAT; they may be typed without. A branch manager's
 * change goes to Approvals (request_change 'price' / 'color_rule'), an org admin's is saved directly.
 */
const _ruleType = {'delta_over_base_color': 'Added to the base-colour price', 'absolute_price_per_sqmt': 'Price per m²'};
double r2x(num v) => (v * 100).roundToDouble() / 100;
double? impliedVatRate(Json? r) =>
    r != null && r['price_per_unit_exclusive'] != null && n(r['price_per_unit_exclusive']) > 0 && r['price_per_unit_inclusive'] != null
        ? r2x((n(r['price_per_unit_inclusive']) / n(r['price_per_unit_exclusive']) - 1) * 100)
        : null;
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
String _money(Object? v) => v == null ? '—' : formatMoney(n(v), session.currency);
String _s(num? v) => v == null ? '' : p6(v);

Future<Json> _fetch() async {
  const cols = 'id, product_id, branch_id, color_id, is_available, price_per_unit_exclusive, vat_per_unit, price_per_unit_inclusive, price_per_sqm_inclusive, pcs_per_sqm_at_pricing, raw_notes';
  List prices;
  var vatColumn = true;
  try {
    prices = await db.from('product_branch_pricing').select('$cols, vat_rate');
  } catch (_) {
    prices = await db.from('product_branch_pricing').select(cols);
    vatColumn = false;
  }
  final r = await Future.wait<dynamic>([
    db.from('branches').select('id, name, status, vat_rate').order('name', ascending: true),
    db.from('category_color_pricing_rules').select('id, category_id, branch_id, pricing_type, base_color_id, items:category_color_price_items(color_id, amount)'),
    db.from('products').select('id, canonical_name, product_id_ref, category_id, status, pcs_per_sqm, unit:units(symbol), category:product_categories(name)').order('canonical_name', ascending: true),
    db.from('product_categories').select('id, name, sort_order, status, parent_category_id, colors:product_category_colors(color_id, display_order, color:color_palette(name, is_active))').order('sort_order', ascending: true),
    db.from('branch_products').select('branch_id, product_id').eq('status', 'active'),
  ]);
  return {'prices': prices, 'vatColumn': vatColumn, 'branches': r[0], 'rules': r[1], 'products': r[2], 'categories': r[3], 'carried': r[4]};
}

class PricingPage extends StatefulWidget {
  const PricingPage({super.key});
  @override
  State<PricingPage> createState() => _PricingPageState();
}

class _PricingPageState extends State<PricingPage> {
  Json? _j;
  DateTime? _savedAt;
  String _error = '', _tab = 'prices', _search = '', _categoryId = '', _sortBy = 'category';
  bool _unpricedOnly = false;
  bool get canWrite => session.canManage('products.manage');
  // a branch's managers may propose its prices; an org admin approves (033)
  bool canProposeAt(Json b) => !canWrite && session.canAt('products.manage', '${b['id']}', null);

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final (j, at) = await offline.load<Json>('pricing', _fetch);
      if (mounted) setState(() { _j = j; _savedAt = at; });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load this page. Please try again.");
    }
  }

  Future<void> _push(Widget page) async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => page));
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final j = _j;
    if (_error.isNotEmpty && j == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    if (j == null) return ListView(padding: const EdgeInsets.all(14), children: const [Skeleton(rows: 7)]);
    final prices = _l(j['prices']), rules = _l(j['rules']), products = _l(j['products']), categories = _l(j['categories']);
    final carried = {for (final r in _l(j['carried'])) '${r['branch_id']}|${r['product_id']}'};
    final branches = _l(j['branches']).where((b) => b['status'] == 'active' && session.inBranch(b['id'])).toList();
    final branchId = session.branchId;
    final basePrice = {for (final p in prices) if (p['color_id'] == null) '${p['product_id']}|${p['branch_id']}': p};
    final colourPrices = <String, List<Json>>{};
    for (final p in prices) {
      if (p['color_id'] == null || (p['price_per_sqm_inclusive'] == null && p['price_per_unit_inclusive'] == null)) continue;
      (colourPrices['${p['product_id']}|${p['branch_id']}'] ??= []).add(p);
    }
    // most common VAT rate in this organization's prices: a suggestion for a new price
    final counts = <double, int>{};
    for (final p in prices) { final r = impliedVatRate(p); if (r != null) counts[r] = (counts[r] ?? 0) + 1; }
    final usualVat = counts.isEmpty ? null : (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;

    final cats = CategoryTools(categories);
    final q = _search.trim().toLowerCase();
    bool inPicked(Object? id) => _categoryId.isEmpty || id == _categoryId || cats.byId[id]?['parent_category_id'] == _categoryId;
    bool inList(Json p) => branchId.isEmpty || carried.contains('$branchId|${p['id']}') || basePrice['${p['id']}|$branchId'] != null;
    final shown = products.where((p) => inList(p) &&
        (p['status'] == 'active' || branches.any((b) => basePrice['${p['id']}|${b['id']}'] != null)) &&
        inPicked(p['category_id']) &&
        (q.isEmpty || '${p['canonical_name']}'.toLowerCase().contains(q) || '${p['product_id_ref']}'.toLowerCase().contains(q)) &&
        (!_unpricedOnly || (p['status'] == 'active' && branches.any((b) => basePrice['${p['id']}|${b['id']}'] == null)))).toList();
    double? shownPrice(Json p) {
      final r = branches.length == 1 ? basePrice['${p['id']}|${branches.first['id']}'] : null;
      return r == null ? null : n(r['price_per_sqm_inclusive'] ?? r['price_per_unit_inclusive']).toDouble();
    }

    shown.sort((a, b) {
      final byName = naturalCompare('${a['canonical_name']}', '${b['canonical_name']}');
      if (_sortBy == 'name') return byName;
      if (_sortBy == 'price_desc' || _sortBy == 'price_asc') {
        final x = shownPrice(a), y = shownPrice(b);
        if (x == null || y == null) { final c = (x == null ? 1 : 0) - (y == null ? 1 : 0); return c != 0 ? c : byName; }
        final c = _sortBy == 'price_desc' ? y.compareTo(x) : x.compareTo(y);
        return c != 0 ? c : byName;
      }
      final ca = cats.byId[a['category_id']], cb = cats.byId[b['category_id']];
      final c = ca != null && cb != null ? cats.compare(ca, cb) : 0;
      return c != 0 ? c : byName;
    });
    final unpricedCount = products.where((p) => inList(p) && p['status'] == 'active' && branches.every((b) => basePrice['${p['id']}|${b['id']}'] == null)).length;
    final colouredCategories = cats.ordered.where((c) => _l(c['colors']).isNotEmpty && inPicked(c['id'])).toList();
    final colourName = {for (final c in categories) for (final x in _l(c['colors'])) '${x['color_id']}': '${x['color']?['name'] ?? ''}'};
    final chips = [for (final c in categoryChipItems(cats, (c) => c['status'] == 'active')) ChipItem(c.id, c.label, c.children?.map((k) => ChipItem(k.id, k.label)).toList())];

    Widget priceCell(Json p, Json b) {
      final row = basePrice['${p['id']}|${b['id']}'];
      final editable = (canWrite || canProposeAt(b)) && (p['status'] == 'active' || row != null);
      final vat0 = row != null && n(row['vat_rate'] ?? impliedVatRate(row) ?? -1) == 0;
      final cp = colourPrices['${p['id']}|${b['id']}'];
      final sub = row == null
          ? null
          : row['is_available'] != true
              ? 'not sold here'
              : row['price_per_sqm_inclusive'] != null
                  ? '${row['price_per_unit_inclusive'] != null && row['pcs_per_sqm_at_pricing'] != null ? '${_money(row['price_per_unit_inclusive'])} each · ${p6(row['pcs_per_sqm_at_pricing'])} per m²' : 'per-piece price not set'}${vat0 ? ' · no VAT' : ''}'
                  : vat0 ? 'no VAT' : 'incl. VAT';
      final body = Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (row == null)
          Text(editable ? '+ Add' : '—', style: TextStyle(fontSize: Fs.sm, color: editable ? C.khaki : t.textMuted, fontWeight: editable ? FontWeight.w600 : null))
        else
          Text(row['price_per_sqm_inclusive'] != null ? '${_money(row['price_per_sqm_inclusive'])} /m²' : _money(row['price_per_unit_inclusive']),
              style: TextStyle(fontWeight: FontWeight.w700, color: row['is_available'] == true ? null : t.textMuted)),
        if (sub != null) Text(sub, style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
        if (cp != null) Text('+ ${cp.length} colour price${cp.length == 1 ? '' : 's'}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
      ]);
      return InkWell(
        onTap: !editable
            ? null
            : () => _push(_PriceForm(
                  product: p, branch: b, row: row, usualVat: usualVat, vatColumn: j['vatColumn'] == true, viaApproval: !canWrite,
                  colours: _l(categories.where((c) => c['id'] == p['category_id']).firstOrNull?['colors']),
                  baseColourId: rules.where((r) => r['category_id'] == p['category_id'] && r['branch_id'] == b['id']).firstOrNull?['base_color_id'],
                  colourRows: prices.where((x) => x['color_id'] != null && x['product_id'] == p['id'] && x['branch_id'] == b['id']).toList(),
                )),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: body),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        OfflineNote(_savedAt),
        PageTabs<String>(tabs: const [('prices', 'Product prices'), ('colours', 'Colour pricing')], value: _tab, onChange: (v) => setState(() => _tab = v)),
        if (_tab == 'prices')
          ListToolbar(
            placeholder: 'Search products…',
            onSearch: (v) => setState(() => _search = v),
            sort: SortSpec(value: _sortBy, onChange: (v) => setState(() => _sortBy = v), options: [
              ('category', 'By category (default)'), ('name', 'Name: A → Z'),
              if (branches.length == 1) ...[('price_desc', 'Price at ${branches.first['name']}: highest → lowest'), ('price_asc', 'Price at ${branches.first['name']}: lowest → highest')],
            ]),
            filters: [
              FilterSpec(key: 'priced', label: 'Prices', value: _unpricedOnly ? 'missing' : '', onChange: (v) => setState(() => _unpricedOnly = v == 'missing'),
                  options: [('', 'All products'), ('missing', 'Missing a price ($unpricedCount with none)')]),
            ],
          ),
        ChipRow(items: chips, value: _categoryId, onChange: (v) => setState(() => _categoryId = v)),
        const SizedBox(height: 10),
        if (_tab == 'prices') ...[
          if (shown.isEmpty)
            EmptyState(icon: LucideIcons.dollarSign, title: 'No products in this view', description: _search.isNotEmpty ? 'No products match "$_search".' : null)
          else
            for (final p in shown)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(10)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  // products: name on top, category below (locked 2026-10-25)
                  Text('${p['canonical_name']}${p['status'] != 'active' ? ' (inactive)' : ''}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.md)),
                  PlHelp(cats.label(p['category_id'])),
                  for (final b in branches)
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      if (branches.length > 1) Padding(padding: const EdgeInsets.only(top: 6), child: Text('${b['name']}', style: TextStyle(fontSize: Fs.sm, color: t.textSecondary))),
                      const Spacer(),
                      priceCell(p, b),
                    ]),
                ]),
              ),
          const PlHelp("Prices include VAT and are the base price. Other colours follow the category's colour pricing, unless the product has its own colour prices (open a price to set them)."),
        ] else if (colouredCategories.isEmpty)
          const EmptyState(icon: LucideIcons.palette, title: 'No coloured categories', description: 'Give a category colours under Categories to price colours.')
        else
          for (final cat in colouredCategories)
            CardBox(
              title: cats.label(cat),
              child: Column(children: [
                for (final b in branches)
                  Builder(builder: (_) {
                    final rule = rules.where((r) => r['category_id'] == cat['id'] && r['branch_id'] == b['id']).firstOrNull;
                    final order = {for (final c in _l(cat['colors'])) '${c['color_id']}': n(c['display_order'])};
                    final items = _l(rule?['items'])..sort((x, y) => (order['${x['color_id']}'] ?? 0).compareTo(order['${y['color_id']}'] ?? 0));
                    final can = canWrite || canProposeAt(b);
                    return InkWell(
                      onTap: !can ? null : () => _push(_RuleForm(category: cat, branch: b, rule: rule, viaApproval: !canWrite, colourName: colourName, catLabel: cats.label(cat))),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
                        child: Row(children: [
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${b['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                              if (rule == null)
                                const PlHelp('No colour pricing.')
                              else ...[
                                PlHelp('Base ${colourName['${rule['base_color_id']}'] ?? '—'} · ${_ruleType[rule['pricing_type']] ?? rule['pricing_type']}'),
                                const SizedBox(height: 4),
                                Wrap(spacing: 4, runSpacing: 4, children: [
                                  for (final i in items) Badge2('${colourName['${i['color_id']}']}: ${rule['pricing_type'] == 'delta_over_base_color' ? '+' : ''}${_money(i['amount'])}'),
                                  if (items.isEmpty) const PlHelp('—'),
                                ]),
                              ],
                            ]),
                          ),
                          if (can) Text(rule != null ? 'Edit' : 'Add', style: const TextStyle(fontSize: Fs.sm, color: C.khaki, fontWeight: FontWeight.w600)),
                        ]),
                      ),
                    );
                  }),
              ]),
            ),
      ]),
    );
  }
}

/// "Sent for approval" — the web shows this in place of the form
Widget _sentForApproval(BuildContext context, String title) => FullPage(
      title: title,
      footer: [FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done'))],
      children: const [Text('Sent for approval — see Approvals.')],
    );

/// The price I type: includes / excludes VAT
Widget _vatSwitch(String label, bool exVat, ValueChanged<bool> onChange, [String plural = '']) => Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text(label, style: const TextStyle(fontSize: Fs.sm)),
      Chip2('include$plural VAT', on: !exVat, onTap: () => onChange(false)),
      Chip2('exclude$plural VAT', on: exVat, onTap: () => onChange(true)),
    ]);

class _PriceForm extends StatefulWidget {
  const _PriceForm({required this.product, required this.branch, required this.row, required this.usualVat, required this.vatColumn, required this.viaApproval,
      required this.colours, required this.baseColourId, required this.colourRows});
  final Json product, branch;
  final Json? row;
  final double? usualVat;
  final bool vatColumn, viaApproval;
  final List<Json> colours, colourRows;
  final Object? baseColourId;
  @override
  State<_PriceForm> createState() => _PriceFormState();
}

class _PriceFormState extends State<_PriceForm> {
  Json get p => widget.product;
  Json get b => widget.branch;
  Json? get row => widget.row;
  bool get isNew => row == null;
  // the product's unit decides (2026-10-25): counted in m² → priced per m²; otherwise per piece
  bool get byArea => '${p['unit']?['symbol'] ?? ''}'.toUpperCase() == 'SQM';
  late final _perSqm = TextEditingController(text: _s(row?['price_per_sqm_inclusive'] as num?));
  late final _pcs = TextEditingController(text: _s((row?['pcs_per_sqm_at_pricing'] ?? p['pcs_per_sqm']) as num?));
  late final _perUnit = TextEditingController(text: _s(row?['price_per_unit_inclusive'] as num?));
  late final _vat = TextEditingController(text: _s(row != null ? ((row!['vat_rate'] as num?) ?? impliedVatRate(row) ?? widget.usualVat) : widget.usualVat));
  late bool _available = row?['is_available'] ?? true;
  late final _notes = TextEditingController(text: '${row?['raw_notes'] ?? ''}');
  late final List<Json> others = ([...widget.colours]..sort((a, b) => n(a['display_order']).compareTo(n(b['display_order'])))).where((c) => c['color_id'] != widget.baseColourId).toList();
  late final Map<String, Json> rowByColour = {for (final r in widget.colourRows) '${r['color_id']}': r};
  num? _shownColour(Json? r) => r == null ? null : (byArea ? r['price_per_sqm_inclusive'] : r['price_per_unit_inclusive']) as num?;
  late final Map<String, TextEditingController> _amounts = {for (final c in others) '${c['color_id']}': TextEditingController(text: _s(_shownColour(rowByColour['${c['color_id']}'])))};
  bool _exVat = false, _busy = false, _submitted = false;
  String _error = '';

  double get _factor => 1 + (numOrNull(_vat.text) ?? 0) / 100;
  double? _toInc(double? v) => v == null ? null : _exVat ? v * _factor : v;
  double? _perPiece(String sqm, String each) {
    if (byArea) {
      final s = numOrNull(sqm), pc = numOrNull(_pcs.text);
      return s != null && pc != null && pc > 0 ? _toInc(s)! / pc : null;
    }
    return _toInc(numOrNull(each));
  }

  void _switchVat(bool next) {
    if (next == _exVat) return;
    if (next && numOrNull(_vat.text) == null) return setState(() => _error = 'Enter the VAT rate first, to type prices without VAT.');
    final f = _factor;
    void conv(TextEditingController c) { final v = numOrNull(c.text); if (v != null) c.text = p6(r2x(next ? v / f : v * f)); }
    setState(() {
      _error = '';
      conv(_perSqm); conv(_perUnit);
      _amounts.values.forEach(conv);
      _exVat = next;
    });
  }

  Future<void> _save() async {
    setState(() => _error = '');
    void fail(String m) => setState(() { _busy = false; _error = m; });
    final unitInc = _perPiece(_perSqm.text, _perUnit.text);
    final rate = numOrNull(_vat.text);
    if (byArea) {
      if (!((numOrNull(_perSqm.text) ?? 0) > 0)) return fail('Enter the price per m².');
      final pc = numOrNull(_pcs.text);
      if (_pcs.text.trim().isNotEmpty && !(pc != null && pc == pc.roundToDouble() && pc > 0)) return fail('Pieces per m² must be a whole number above zero, or left blank.');
    } else if (!((unitInc ?? 0) > 0)) {
      return fail('Enter the price.');
    }
    if (rate != null && !(rate >= 0 && rate < 100)) return fail('VAT rate must be between 0 and 100.');
    if (_exVat && rate == null) return fail('Enter the VAT rate — the price is typed without VAT.');
    for (final c in others) {
      final v = numOrNull(_amounts['${c['color_id']}']!.text);
      if (_amounts['${c['color_id']}']!.text.trim().isNotEmpty && !(v != null && v > 0)) return fail('${c['color']?['name']}: enter a price above zero, or leave blank.');
    }
    Json priceFields(String sqm, String each) {
      final inc = _perPiece(sqm, each);
      final ex = inc != null && rate != null ? inc / (1 + rate / 100) : null;
      return {
        'price_per_unit_inclusive': inc != null ? r2x(inc) : null,
        'price_per_unit_exclusive': ex != null ? r2x(ex) : null,
        'vat_per_unit': ex != null ? r2x(inc! - ex) : null,
        if (widget.vatColumn) 'vat_rate': rate,   // 061
        'price_per_sqm_inclusive': byArea && numOrNull(sqm) != null ? (_exVat ? r2x(_toInc(numOrNull(sqm))!) : numOrNull(sqm)) : null,
        'pcs_per_sqm_at_pricing': byArea && numOrNull(_pcs.text) != null ? numOrNull(_pcs.text) : null,
      };
    }

    final fields = {...priceFields(_perSqm.text, _perUnit.text), 'is_available': _available, 'raw_notes': _notes.text.trim().isEmpty ? null : _notes.text.trim()};
    // price and VAT rate untouched: keep the stored figures exactly as they are
    if (row != null && unitInc != null && rate == impliedVatRate(row) && r2x(unitInc) == r2x(n(row!['price_per_unit_inclusive']))) {
      fields['price_per_unit_inclusive'] = row!['price_per_unit_inclusive'];
      fields['price_per_unit_exclusive'] = row!['price_per_unit_exclusive'];
      fields['vat_per_unit'] = row!['vat_per_unit'];
    }
    final changes = <Json>[{'color_id': null, 'existingId': row?['id'], 'fields': fields}];
    // colour prices: add, change, or blank out — rows are never deleted
    for (final c in others) {
      final existing = rowByColour['${c['color_id']}'];
      final text = _amounts['${c['color_id']}']!.text.trim();
      final v = numOrNull(text);
      if (v == null && (existing == null || (_shownColour(existing) == null && existing['price_per_unit_inclusive'] == null))) continue;
      final cf = v == null
          ? {'price_per_unit_inclusive': null, 'price_per_unit_exclusive': null, 'vat_per_unit': null, 'price_per_sqm_inclusive': null, 'pcs_per_sqm_at_pricing': null}
          : {...priceFields(byArea ? text : '', byArea ? '' : text), 'is_available': _available};
      if (existing != null && v != null && _shownColour(existing) != null && r2x(n(_shownColour(existing))) == r2x(_toInc(v)!) &&
          (existing['price_per_sqm_inclusive'] != null) == byArea && existing['pcs_per_sqm_at_pricing'] == cf['pcs_per_sqm_at_pricing'] && existing['is_available'] == _available) {
        continue;
      }
      changes.add({'color_id': c['color_id'], 'existingId': existing?['id'], 'fields': cf, 'colourName': c['color']?['name']});
    }
    setState(() => _busy = true);
    try {
      if (widget.viaApproval) {
        String shown(Json f) => f['price_per_sqm_inclusive'] != null ? '${_money(f['price_per_sqm_inclusive'])} /m²' : f['price_per_unit_inclusive'] != null ? '${_money(f['price_per_unit_inclusive'])} each' : 'colour pricing';
        final summary = '${p['canonical_name']} at ${b['name']}: ${changes.map((ch) => '${ch['colourName'] != null ? '${ch['colourName']} ' : ''}${shown(ch['fields'] as Json)}').join(', ')}${row != null ? ' (was ${shown(row!)})' : ' (new price)'}';
        await db.rpc('request_change', params: {
          'p_kind': 'price', 'p_branch_id': b['id'], 'p_summary': summary,
          'p_payload': {'rows': [for (final ch in changes) {'product_id': p['id'], 'color_id': ch['color_id'], ...(ch['fields'] as Json)}]},
        });
        return setState(() { _busy = false; _submitted = true; });
      }
      for (final ch in changes) {
        try {
          if (ch['existingId'] != null) {
            await db.from('product_branch_pricing').update(ch['fields'] as Json).eq('id', ch['existingId']);
          } else {
            await db.from('product_branch_pricing').insert({...(ch['fields'] as Json), 'organization_id': session.organization!['id'], 'product_id': p['id'], 'branch_id': b['id'], 'color_id': ch['color_id']});
          }
        } catch (e) {
          return fail('${ch['colourName'] != null ? '${ch['colourName']}: ' : ''}${dbError(e)}');
        }
      }
    } catch (e) {
      return fail(dbError(e, widget.viaApproval ? "We couldn't send this for approval. Please try again." : 'Something went wrong. Please try again.'));
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final title = '${p['canonical_name']} — ${b['name']}';
    if (_submitted) return _sentForApproval(context, title);
    final vatTag = _exVat ? 'excl. VAT' : 'incl. VAT';
    final rate = numOrNull(_vat.text);
    final unitInc = _perPiece(_perSqm.text, _perUnit.text);
    final unitEx = unitInc != null && rate != null ? unitInc / (1 + rate / 100) : null;
    final sqm = numOrNull(_perSqm.text);
    const num = TextInputType.numberWithOptions(decimal: true);
    void redraw(_) => setState(() {});
    Widget gap() => const SizedBox(height: 12);
    return FullPage(
      title: title,
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(widget.viaApproval ? 'Submit for approval' : isNew ? 'Add price' : 'Save')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        if (widget.viaApproval) const Alert('Needs approval.', tone: Tone.info),
        PlHelp('Base price${p['unit']?['symbol'] != null ? ' · stocked in ${p['unit']['symbol']}' : ''}'),
        const SizedBox(height: 8),
        _vatSwitch('The price I type', _exVat, _switchVat, 's'),
        PlHelp('${byArea ? 'Per m²' : 'Per piece'} (set on the product).'),
        gap(),
        if (byArea)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: TextField(controller: _perSqm, autofocus: true, onChanged: redraw, keyboardType: num, decoration: InputDecoration(labelText: 'Price per m² ($vatTag)'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _pcs, onChanged: redraw, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Pieces per m² (optional)', hintText: 'Not known', helperText: 'Only for a price per piece.'))),
          ])
        else
          TextField(controller: _perUnit, autofocus: true, onChanged: redraw, keyboardType: num, decoration: InputDecoration(labelText: 'Price each ($vatTag)')),
        gap(),
        TextField(controller: _vat, onChanged: redraw, keyboardType: num, decoration: const InputDecoration(labelText: 'VAT rate (%)', hintText: 'Not recorded')),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          if (widget.usualVat != null && widget.usualVat! > 0) Chip2('VAT ${p6(widget.usualVat)}%', on: rate == widget.usualVat, onTap: () => setState(() => _vat.text = p6(widget.usualVat))),
          Chip2('No VAT', on: rate == 0, onTap: () => setState(() => _vat.text = '0')),
        ]),
        PlHelp(rate == 0 ? 'Sold without VAT: the price is the same with and without VAT.' : 'The VAT in this price. Pick No VAT for a product sold without VAT.'),
        gap(),
        const PlLabel('Works out to'),
        Text(
          [
            if (byArea && sqm != null && rate != null) '${_money(r2x(_toInc(sqm)!))} /m² incl. VAT · ${_money(r2x(_toInc(sqm)! / (1 + rate / 100)))} excl.',
            if (unitInc != null) '${_money(r2x(unitInc))} each incl. VAT${unitEx != null ? '\n${_money(r2x(unitEx))} excl. VAT' : ''}'
            else if (byArea && sqm != null) 'No price per piece — add pieces per m² if you need one.'
            else '—',
          ].join('\n'),
          style: const TextStyle(fontSize: Fs.sm),
        ),
        CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: _available, onChanged: (v) => setState(() => _available = v ?? true), title: Text('Sold at ${b['name']}')),
        if (others.isNotEmpty) ...[
          const SectionTitle('Colour prices for this product (optional)'),
          PlHelp("${byArea ? 'Price per m²' : 'Price each'} ($vatTag) for ${p['canonical_name']} in each colour at ${b['name']}. Blank follows the category's colour pricing."),
          const SizedBox(height: 8),
          for (final c in others)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(child: Text('${c['color']?['name']}${c['color']?['is_active'] == false ? ' (discontinued)' : ''}', style: const TextStyle(fontSize: Fs.sm))),
                SizedBox(width: 160, child: TextField(controller: _amounts['${c['color_id']}'], keyboardType: num, decoration: const InputDecoration(hintText: 'Category pricing'))),
              ]),
            ),
        ],
        gap(),
        TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes')),
        if (!isNew) ...[
          EntityFlags(entityType: 'product_price', entityId: '${row!['id']}', canResolve: true),
          EntityHistory(entityType: 'product_price', entityId: '${row!['id']}'),
        ],
      ],
    );
  }
}

class _RuleForm extends StatefulWidget {
  const _RuleForm({required this.category, required this.branch, required this.rule, required this.viaApproval, required this.colourName, required this.catLabel});
  final Json category, branch;
  final Json? rule;
  final bool viaApproval;
  final Map<String, String> colourName;
  final String catLabel;
  @override
  State<_RuleForm> createState() => _RuleFormState();
}

class _RuleFormState extends State<_RuleForm> {
  Json? get rule => widget.rule;
  Json get b => widget.branch;
  bool get isNew => rule == null;
  late final List<Json> colours = _l(widget.category['colors'])..sort((a, b) => n(a['display_order']).compareTo(n(b['display_order'])));
  late String _baseId = '${rule?['base_color_id'] ?? colours.firstOrNull?['color_id'] ?? ''}';
  late String _type = '${rule?['pricing_type'] ?? 'delta_over_base_color'}';
  late final Map<String, TextEditingController> _amounts = {
    for (final c in colours) '${c['color_id']}': TextEditingController(text: _s(_l(rule?['items']).where((i) => i['color_id'] == c['color_id']).firstOrNull?['amount'] as num?)),
  };
  bool _exVat = false, _busy = false, _submitted = false;
  String _error = '';

  double get _f => 1 + n(b['vat_rate'] ?? 0) / 100;
  double? _inc(String id) { final v = numOrNull(_amounts[id]!.text); return v == null ? null : _exVat ? r2x(v * _f) : v; }
  List<Json> get others => colours.where((c) => '${c['color_id']}' != _baseId).toList();

  void _switchVat(bool next) {
    if (next == _exVat) return;
    setState(() {
      for (final c in _amounts.values) { final v = numOrNull(c.text); if (v != null) c.text = p6(r2x(next ? v / _f : v * _f)); }
      _exVat = next;
    });
  }

  Future<void> _save() async {
    setState(() => _error = '');
    void fail(String m) => setState(() { _busy = false; _error = m; });
    for (final c in others) {
      final t = _amounts['${c['color_id']}']!.text.trim(), v = numOrNull(t);
      if (t.isNotEmpty && !(v != null && v >= 0)) return fail('${c['color']?['name']}: enter zero or more, or leave blank.');
    }
    setState(() => _busy = true);
    final org = session.organization!['id'];
    try {
      // a branch manager's change waits for an org admin (039)
      if (widget.viaApproval) {
        final items = [for (final c in others) if (_inc('${c['color_id']}') != null) {'color_id': c['color_id'], 'amount': _inc('${c['color_id']}')}];
        final what = items.isEmpty ? 'no other colours priced' : items.map((i) => '${widget.colourName['${i['color_id']}']} ${_type == 'delta_over_base_color' ? '+' : ''}${_money(i['amount'])}').join(', ');
        await db.rpc('request_change', params: {
          'p_kind': 'color_rule', 'p_branch_id': b['id'],
          'p_payload': {'category_id': widget.category['id'], 'base_color_id': _baseId, 'pricing_type': _type, 'items': items},
          'p_summary': 'Colour pricing for ${widget.catLabel} at ${b['name']}: base ${widget.colourName[_baseId] ?? ''}; $what',
        });
        return setState(() { _busy = false; _submitted = true; });
      }
      var ruleId = '${rule?['id'] ?? ''}';
      if (isNew) {
        final res = await db.from('category_color_pricing_rules').insert({'organization_id': org, 'category_id': widget.category['id'], 'branch_id': b['id'], 'base_color_id': _baseId, 'pricing_type': _type}).select('id').single();
        ruleId = '${res['id']}';
      } else if (rule!['base_color_id'] != _baseId || rule!['pricing_type'] != _type) {
        await db.from('category_color_pricing_rules').update({'base_color_id': _baseId, 'pricing_type': _type}).eq('id', ruleId);
      }
      final current = {for (final i in _l(rule?['items'])) '${i['color_id']}': n(i['amount']).toDouble()};
      final upserts = [
        for (final c in others)
          if (_inc('${c['color_id']}') != null && (current['${c['color_id']}'] == null || r2x(_inc('${c['color_id']}')!) != r2x(current['${c['color_id']}']!)))
            {'organization_id': org, 'rule_id': ruleId, 'color_id': c['color_id'], 'amount': _inc('${c['color_id']}')},
      ];
      // blank amounts, and the base colour itself, have no item
      final removals = current.keys.where((id) => id == _baseId || numOrNull(_amounts[id]?.text ?? '') == null).toList();
      if (upserts.isNotEmpty) await db.from('category_color_price_items').upsert(upserts, onConflict: 'rule_id,color_id');
      if (removals.isNotEmpty) await db.from('category_color_price_items').delete().eq('rule_id', ruleId).inFilter('color_id', removals);
    } catch (e) {
      return fail(dbError(e, widget.viaApproval ? "We couldn't send this for approval. Please try again." : 'Something went wrong. Please try again.'));
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final title = '${widget.catLabel} — ${b['name']} colour pricing';
    if (_submitted) return _sentForApproval(context, title);
    final first = others.firstOrNull;
    final firstAmt = first == null ? null : numOrNull(_amounts['${first['color_id']}']!.text);
    return FullPage(
      title: title,
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy || _baseId.isEmpty ? null : _save, child: Text(widget.viaApproval ? 'Submit for approval' : isNew ? 'Add colour pricing' : 'Save')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        if (widget.viaApproval) const Alert('Needs approval.', tone: Tone.info),
        DropdownButtonFormField<String>(
          initialValue: _baseId.isEmpty ? null : _baseId, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Base colour', helperText: "Products' own prices are for this colour."),
          items: [for (final c in colours) DropdownMenuItem(value: '${c['color_id']}', child: Text('${c['color']?['name']}${c['color']?['is_active'] == false ? ' (discontinued)' : ''}'))],
          onChanged: (v) => setState(() => _baseId = v ?? ''),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _type, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Other colours are priced as'),
          items: [for (final e in _ruleType.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
          onChanged: (v) => setState(() => _type = v ?? 'delta_over_base_color'),
        ),
        SectionTitle('${_type == 'delta_over_base_color' ? 'Amount added per m²' : 'Price per m²'} (${_exVat ? 'excl.' : 'incl.'} VAT)'),
        _vatSwitch('The amounts I type', _exVat, _switchVat),
        PlHelp('VAT ${p6(n(b['vat_rate'] ?? 0))}% at ${b['name']}'),
        const SizedBox(height: 8),
        for (final c in others)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              Expanded(child: Text('${c['color']?['name']}${c['color']?['is_active'] == false ? ' (discontinued)' : ''}', style: const TextStyle(fontSize: Fs.sm))),
              SizedBox(width: 160, child: TextField(controller: _amounts['${c['color_id']}'], onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(hintText: 'No price'))),
            ]),
          ),
        PlHelp("Blank means that colour has no price at ${b['name']}.${_type == 'delta_over_base_color' && first != null && firstAmt != null ? ' e.g. ${first['color']?['name']} = base price + ${_money(firstAmt)} per m².' : ''}"),
        if (!isNew) EntityHistory(entityType: 'color_pricing_rule', entityId: '${rule!['id']}'),
      ],
    );
  }
}
