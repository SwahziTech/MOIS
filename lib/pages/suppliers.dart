import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/ui.dart';
import 'products.dart' show EntityFlags, EntityHistory;

/*
 * Suppliers — a port of web pages/Suppliers.jsx (022/035/130), shown as Procurement's Suppliers tab. What a
 * supplier provides is never fixed on a material (031): it comes from the purchases recorded with them —
 * what was bought, where, when, and what is still to pay. (All fields are loaded, so the pay details
 * show in the edit form and are kept when saving.)
 */
const _fields = [
  ('contact_person', 'Contact person'), ('phone', 'Phone'), ('email', 'Email'), ('tax_id', 'Tax ID (TIN)'), ('address', 'Address'),
  // where it is paid (130): filled in the Pay window too
  ('pay_bank', 'Paid by: bank or network'), ('pay_account_no', 'Account or phone number'), ('pay_account_name', 'Account name'),
  ('notes', 'Notes'),
];
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];

class SuppliersPanel extends StatefulWidget {
  const SuppliersPanel({super.key});
  @override
  State<SuppliersPanel> createState() => SuppliersPanelState();
}

class SuppliersPanelState extends State<SuppliersPanel> {
  List<Json>? _suppliers;
  List<Json> _purchases = [];
  Map<String, String> _names = {};
  String _search = '', _sortBy = 'name';
  bool _showInactive = false;
  DateTime? _savedAt;
  String _error = '';
  bool get canWrite => session.canManage('materials.manage');

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final (j, at) = await offline.load<Json>('suppliers', () async {
        final r = await Future.wait<dynamic>([
          db.from('suppliers').select('*').order('name', ascending: true),
          db.from('purchases').select('id, supplier_id, branch_id, purchase_date, lines:purchase_lines(tx:inventory_transactions(material_id, product_id))').eq('status', 'recorded'),
          db.from('materials').select('id, name'),
          db.from('products').select('id, canonical_name'),
          db.from('purchase_totals').select('purchase_id, balance'),
        ]);
        return {'sup': r[0], 'pu': r[1], 'mat': r[2], 'prod': r[3], 'tot': r[4]};
      });
      final balance = {for (final t in _l(j['tot'])) '${t['purchase_id']}': n(t['balance']).toDouble()};
      if (!mounted) return;
      setState(() {
        _suppliers = _l(j['sup']);
        _purchases = [for (final p in _l(j['pu'])) {...p, 'balance': balance['${p['id']}'] ?? 0}];
        _names = {for (final m in _l(j['mat'])) 'm:${m['id']}': '${m['name']}', for (final p in _l(j['prod'])) 'p:${p['id']}': '${p['canonical_name']}'};
        _savedAt = at;
      });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load suppliers. Please try again.");
    }
  }

  /// the page's New Supplier button
  Future<void> newSupplier() => _edit({});

  Future<void> _edit(Json s) async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _SupplierForm(supplier: s)));
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final list = _suppliers;
    if (_error.isNotEmpty && list == null) return ErrorState(_error, onRetry: _load);
    if (list == null) return const Skeleton(rows: 4);
    // per supplier, from the purchases in view (the menu's branch, or all)
    final bought = <String, ({int count, String last, Set<String> items, double owed})>{};
    for (final r in _purchases) {
      if (!session.inBranch(r['branch_id'])) continue;
      final b = bought['${r['supplier_id']}'] ?? (count: 0, last: '', items: <String>{}, owed: 0.0);
      final items = {...b.items, for (final l in _l(r['lines'])) _names[l['tx']?['material_id'] != null ? 'm:${l['tx']['material_id']}' : 'p:${l['tx']?['product_id']}'] ?? '—'};
      bought['${r['supplier_id']}'] = (
        count: b.count + 1, last: '${r['purchase_date']}'.compareTo(b.last) > 0 ? '${r['purchase_date']}' : b.last,
        items: items, owed: b.owed + (n(r['balance']) > 0 ? n(r['balance']).toDouble() : 0),
      );
    }
    final q = _search.trim().toLowerCase();
    final shown = list.where((s) => (_showInactive || s['status'] == 'active') && (q.isEmpty || '${s['name']}'.toLowerCase().contains(q) || '${s['contact_person'] ?? ''}'.toLowerCase().contains(q))).toList()
      ..sort((a, b) {
        final ba = bought['${a['id']}'], bb = bought['${b['id']}'];
        final byName = '${a['name']}'.compareTo('${b['name']}');
        if (_sortBy == 'purchases') { final c = (bb?.count ?? 0).compareTo(ba?.count ?? 0); return c != 0 ? c : byName; }
        if (_sortBy == 'owed') { final c = (bb?.owed ?? 0).compareTo(ba?.owed ?? 0); return c != 0 ? c : byName; }
        return byName;
      });
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OfflineNote(_savedAt),
      ListToolbar(
        placeholder: 'Search suppliers…',
        onSearch: (v) => setState(() => _search = v),
        sort: SortSpec(value: _sortBy, onChange: (v) => setState(() => _sortBy = v), options: const [('name', 'Name: A → Z (default)'), ('purchases', 'Most purchases first'), ('owed', 'Most still to pay first')]),
        filters: [FilterSpec(key: 'status', label: 'Status', value: _showInactive ? 'all' : 'active', onChange: (v) => setState(() => _showInactive = v == 'all'), options: const [('active', 'Active'), ('all', 'Active and inactive')])],
      ),
      if (shown.isEmpty)
        const EmptyState(icon: LucideIcons.truck, title: 'No suppliers yet', description: 'Add the people and companies you buy from — or name a new one when recording a receipt.')
      else
        for (final s in shown)
          Builder(builder: (_) {
            final b = bought['${s['id']}'];
            final contact = [s['contact_person'], s['phone'], s['email']].where((x) => x != null && '$x'.isNotEmpty).join(' · ');
            return CardBox(
              child: InkWell(
                onTap: canWrite ? () => _edit(s) : null,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text('${s['name']}', style: const TextStyle(fontWeight: FontWeight.w700))),
                    Badge2('${s['status']}', tone: s['status'] == 'active' ? Tone.success : Tone.neutral),
                  ]),
                  PlHelp(contact.isEmpty ? '—' : contact),
                  const SizedBox(height: 4),
                  Text(b != null ? ([...b.items]..sort()).join(', ') : '—', style: const TextStyle(fontSize: 13)),
                  Row(children: [
                    Expanded(child: PlHelp(b != null ? '${b.count} purchase${b.count == 1 ? '' : 's'} · last ${tableDate(b.last) ?? ''}' : 'none yet')),
                    if (b != null && b.owed > 0) Text('${formatMoney((b.owed * 100).roundToDouble() / 100, session.currency)} to pay', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                ]),
              ),
            );
          }),
    ]);
  }
}

class _SupplierForm extends StatefulWidget {
  const _SupplierForm({required this.supplier});
  final Json supplier;
  @override
  State<_SupplierForm> createState() => _SupplierFormState();
}

class _SupplierFormState extends State<_SupplierForm> {
  Json get s => widget.supplier;
  bool get isNew => s['id'] == null;
  late final Map<String, TextEditingController> _v = {for (final k in ['name', ..._fields.map((f) => f.$1)]) k: TextEditingController(text: '${s[k] ?? ''}')};
  bool _busy = false;
  String _error = '';

  Future<void> _run(Future<void> Function() f) async {
    setState(() { _error = ''; _busy = true; });
    try {
      await f();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final row = {for (final e in _v.entries) e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim()};
    return FullPage(
      title: isNew ? 'Add supplier' : 'Edit ${s['name']}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy || _v['name']!.text.trim().isEmpty
              ? null
              : () => _run(() async => isNew
                  ? await db.from('suppliers').insert({...row, 'organization_id': session.organization!['id']})
                  : await db.from('suppliers').update(row).eq('id', s['id'])),
          child: const Text('Save'),
        ),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        TextField(controller: _v['name'], autofocus: isNew, onChanged: (_) => setState(() {}), textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Name')),
        for (final (k, label) in _fields)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TextField(controller: _v[k], keyboardType: k == 'email' ? TextInputType.emailAddress : k == 'phone' ? TextInputType.phone : TextInputType.text, decoration: InputDecoration(labelText: label)),
          ),
        if (!isNew) ...[
          const SectionTitle('Status'),
          PlHelp(s['status'] == 'active' ? 'Deactivating hides it when recording receipts. History is kept.' : 'Inactive — kept for history.'),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _busy ? null : () => _run(() async => db.from('suppliers').update({'status': s['status'] == 'active' ? 'inactive' : 'active'}).eq('id', s['id'])),
              child: Text(s['status'] == 'active' ? 'Deactivate supplier' : 'Reactivate supplier'),
            ),
          ),
          EntityFlags(entityType: 'supplier', entityId: '${s['id']}', canResolve: true, canRaise: true),
          EntityHistory(entityType: 'supplier', entityId: '${s['id']}'),
        ],
      ],
    );
  }
}
