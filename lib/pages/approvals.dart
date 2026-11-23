import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import 'payment_proofs.dart';

/*
 * Approvals — a port of web pages/Approvals.jsx + components/approvals/RequestDetail.jsx, in the
 * approved design (2026-11-23): Waiting · Settled · Payments. A request opens in full (what will
 * be applied, names not ids) with a note and Reject / Approve (decide_change), or Withdraw when
 * it is yours. Payments: the payment slips waiting for a director.
 */
const _kind = {
  'price': ('Price change', 'products.manage'), 'color_rule': ('Colour pricing', 'products.manage'),
  'production_day': ('Production (earlier date)', 'inventory.adjust'), 'sale_correction': ('Sale correction', 'inventory.adjust'),
  'stock_movement': ('Stock correction', 'inventory.adjust'), 'stock_reversal': ('Reversal', 'inventory.adjust'),
  'stock_import': ('Opening stock', 'inventory.adjust'), 'purchase': ('Purchase (earlier date)', 'inventory.adjust'),
};
const _statusTone = {'pending': Tone.warning, 'approved': Tone.success, 'rejected': Tone.neutral, 'withdrawn': Tone.neutral};

class ApprovalsPage extends StatefulWidget {
  const ApprovalsPage({super.key, this.tab = 'pending'});
  final String tab;
  @override
  State<ApprovalsPage> createState() => _ApprovalsPageState();
}

class _ApprovalsPageState extends State<ApprovalsPage> {
  late String _tab = widget.tab;
  List<Json>? _rows;
  Map<String, String> _people = {};
  String _error = '';
  DateTime? _savedAt;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final (d, at) = await offline.load<Json>('approvals', () async {
        final rows = await db.from('pending_changes').select('id, branch_id, kind, summary, payload, status, requested_by, requested_at, decided_by, decided_at, decision_note, last_error')
            .order('requested_at', ascending: false).limit(300);
        final ids = {for (final r in rows) ...[r['requested_by'], r['decided_by']]}.whereType<String>().toList();
        final ppl = ids.isEmpty ? <dynamic>[] : await db.from('profiles').select('id, first_name, last_name, email').inFilter('id', ids);
        return {'rows': rows, 'people': ppl};
      });
      if (!mounted) return;
      setState(() {
        _savedAt = at;
        _rows = [for (final r in d['rows'] as List) Map<String, dynamic>.from(r)];
        _people = {
          for (final p in d['people'] as List)
            p['id'] as String: (() { final nm = [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' '); return nm.isNotEmpty ? nm : '${p['email'] ?? ''}'; })(),
        };
      });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load approvals. Please try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    final inView = rows?.where((r) => session.inBranch(r['branch_id'])).toList() ?? [];
    final waiting = inView.where((r) => r['status'] == 'pending').length;
    final shown = inView.where((r) => _tab == 'pending' ? r['status'] == 'pending' : r['status'] != 'pending').toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: PageTabs<String>(
        tabs: [('pending', 'Waiting ($waiting)'), ('settled', 'Settled'), ('payments', 'Payments')], value: _tab, onChange: (v) => setState(() => _tab = v))),
      Expanded(
        child: _tab == 'payments'
            ? const PaymentProofsList(directorView: true)
            : _error.isNotEmpty
                ? ErrorState(_error, onRetry: _load)
                : rows == null
                    ? const Padding(padding: EdgeInsets.all(14), child: Skeleton())
                    : RefreshIndicator(
                        onRefresh: _load,
                        child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
                          OfflineNote(_savedAt),
                          if (shown.isEmpty)
                            EmptyState(icon: LucideIcons.squareCheck, title: _tab == 'pending' ? 'Nothing waiting' : 'Nothing settled yet',
                                description: _tab == 'pending' ? 'Price changes and stock corrections from branch managers appear here until an admin approves them.' : null)
                          else
                            for (final r in shown) _card(context, r),
                        ]),
                      ),
      ),
    ]);
  }

  Widget _card(BuildContext context, Json r) {
    final t = context.tk;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: t.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => _open(r),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              PlLabel('${_kind[r['kind']]?.$1 ?? r['kind']} · ${session.branchNameOf(r['branch_id'])}'),
              const SizedBox(height: 4),
              Text(datesInText('${r['summary']}'), style: const TextStyle(fontSize: Fs.sm)),
              if (r['status'] == 'pending' && r['last_error'] != null) PlHelp("Last approval couldn't be applied: ${r['last_error']}", color: C.error),
              if (r['decision_note'] != null) PlHelp('Note: ${r['decision_note']}'),
              const SizedBox(height: 6),
              Row(children: [
                Expanded(child: PlHelp('Asked by ${_people[r['requested_by']] ?? '—'} · ${tableDateTime(r['requested_at'])}')),
                Badge2('${r['status']}', tone: _statusTone[r['status']] ?? Tone.neutral),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _open(Json r) async {
    final refs = await Refs.load();
    if (!mounted) return;
    final done = await showModal<bool>(context, title: _kind[r['kind']]?.$1 ?? '${r['kind']}', body: (ctx) => _RequestDetail(request: r, refs: refs, askedBy: _people[r['requested_by']]));
    if (done == true) _load();
  }
}

class _RequestDetail extends StatefulWidget {
  const _RequestDetail({required this.request, required this.refs, this.askedBy});
  final Json request;
  final Refs refs;
  final String? askedBy;
  @override
  State<_RequestDetail> createState() => _RequestDetailState();
}

class _RequestDetailState extends State<_RequestDetail> {
  final _note = TextEditingController();
  bool _busy = false;
  String _error = '';

  Json get r => widget.request;
  Refs get refs => widget.refs;

  @override
  void dispose() { _note.dispose(); super.dispose(); }

  Future<void> _decide(bool approve) async {
    setState(() { _busy = true; _error = ''; });
    try {
      final data = await db.rpc('decide_change', params: {'p_id': r['id'], 'p_approve': approve, 'p_note': _note.text.trim().isEmpty ? null : _note.text.trim()});
      if (data is Map && data['status'] == 'pending') {
        setState(() { _busy = false; _error = "Couldn't apply it: ${data['error']}"; });
        return;
      }
      if (mounted) { toast(context, approve ? 'Approved' : 'Rejected'); Navigator.pop(context, true); }
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = dbError(e); });
    }
  }

  Future<void> _withdraw() async {
    setState(() { _busy = true; _error = ''; });
    try {
      await db.rpc('withdraw_change', params: {'p_id': r['id']});
      if (mounted) { toast(context, 'Withdrawn'); Navigator.pop(context, true); }
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = dbError(e); });
    }
  }

  String _item(Map x) => (x['product_id'] != null ? refs.items['p:${x['product_id']}'] : refs.items['m:${x['material_id']}'])?.name ?? '—';
  String _store(Object? id) => warehouseLabel(refs.store('$id'));

  @override
  Widget build(BuildContext context) {
    final pending = r['status'] == 'pending';
    final canDecide = pending && session.canManage(_kind[r['kind']]?.$2 ?? 'system.manage');
    final mine = r['requested_by'] == session.userId;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(datesInText('${r['summary']}'), style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      PlHelp('${session.branchNameOf(r['branch_id'])} · asked by ${widget.askedBy ?? '—'} · ${dateTimeText(r['requested_at'])} · ${r['status']}'),
      if (pending && r['last_error'] != null) Padding(padding: const EdgeInsets.only(top: 8), child: Alert("Last approval couldn't be applied: ${r['last_error']}", tone: Tone.error)),
      if (r['decision_note'] != null) PlHelp('Note: ${r['decision_note']}'),
      const SizedBox(height: 10),
      _body(context),
      if (_error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Alert(_error, tone: Tone.error)),
      if (canDecide) ...[
        const SizedBox(height: 12),
        TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)')),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _decide(false), child: const Text('Reject'))),
          const SizedBox(width: 10),
          Expanded(child: FilledButton(onPressed: _busy ? null : () => _decide(true), child: Text(_busy ? 'Saving…' : 'Approve'))),
        ]),
      ] else if (pending && mine) ...[
        const SizedBox(height: 12),
        OutlinedButton(onPressed: _busy ? null : _withdraw, child: const Text('Withdraw')),
      ],
    ]);
  }

  Widget _body(BuildContext context) {
    final p = Map<String, dynamic>.from((r['payload'] as Map?) ?? {});
    switch (r['kind']) {
      case 'production_day':
        final batches = (p['batches'] as List? ?? []).cast<Map>();
        final first = batches.firstOrNull;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (first != null) PlHelp('${dateText(first['batch_date'])} · from ${_store(first['raw_warehouse_id'])} → cures in ${_store(first['curing_warehouse_id'])}'),
          for (final (i, b) in batches.indexed)
            CardBox(title: 'Batch ${i + 1} · ${qtyText(n(b['cement_bags']))} bags', child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final o in [...(b['outputs'] as List? ?? [])]..sort((x, y) => (y['primary'] == true ? 1 : 0) - (x['primary'] == true ? 1 : 0)))
                _kv('${o['primary'] == true ? '' : '+ '}${_item(o)}${(o['primary'] == true ? b['color_id'] : o['color_id']) != null ? ' ${refs.colour(o['primary'] == true ? b['color_id'] : o['color_id'])}' : ''}', '${formatAmount(n(o['pieces']))} pcs'),
              const Divider(),
              for (final m in (b['materials'] as List? ?? [])) _kv(_item(m), '${qtyText(n(m['quantity']))} ${refs.unit(m['unit_id'])}'),
              if (b['notes'] != null) PlHelp('Note: ${b['notes']}'),
            ])),
        ]);
      case 'purchase':
        final rc = Map<String, dynamic>.from((p['receipt'] as Map?) ?? {});
        final price = {for (final l in (p['lines'] as List? ?? [])) l['material_id']: l['unit_price']};
        final sup = refs.suppliers.where((s) => s['id'] == p['supplier_id']).firstOrNull?['name'] ?? p['new_supplier_name'] ?? '—';
        var total = 0.0;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PlHelp('Received ${dateText(rc['movement_date']) ?? '—'} into ${_store(rc['warehouse_id'])} · supplier $sup${p['invoice_reference'] != null ? ' · invoice ${p['invoice_reference']}' : ''}'),
          for (final l in (rc['lines'] as List? ?? []))
            (() {
              final amt = price[l['material_id']] != null ? n(price[l['material_id']]) * n(l['quantity']) : null;
              if (amt != null) total += amt;
              return _kv('${_item(l)} · ${qtyText(n(l['quantity']))} ${refs.unit(l['unit_id'])} × ${price[l['material_id']] != null ? formatAmount(n(price[l['material_id']])) : '—'}', amt == null ? '—' : formatAmount(amt));
            })(),
          const Divider(),
          _kv('Lines total${p['prices_include_vat'] == true ? ' (VAT included)' : ''}', formatAmount(total)),
          if (n(p['transport_charge']) > 0) _kv('Transport', formatAmount(n(p['transport_charge']))),
          if (p['vat_amount'] != null) _kv('VAT', formatAmount(n(p['vat_amount']))),
          _kv('Paid', '${formatAmount(n(p['amount_paid']))}${p['paid_on'] != null ? ' on ${dateText(p['paid_on'])}' : ''}${p['payment_method'] != null ? ' · ${p['payment_method']}' : ''}'),
          if (p['notes'] != null) _kv('Notes', '${p['notes']}'),
        ]);
      case 'stock_movement':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          PlHelp('${movementTypes[p['type']]?.noun ?? p['type']} · ${dateText(p['movement_date']) ?? '—'} · ${_store(p['warehouse_id'])}${p['to_warehouse_id'] != null ? ' → ${_store(p['to_warehouse_id'])}' : ''}${p['reason'] != null ? ' · ${p['reason']}' : ''}'),
          for (final l in (p['lines'] as List? ?? [])) _kv('${_item(l)}${l['color_id'] != null ? ' · ${refs.colour(l['color_id'])}' : ''}', '${qtyText(n(l['quantity']))} ${refs.unit(l['unit_id'] ?? l['stock_unit_id'])}'),
          if (p['notes'] != null) PlHelp('Notes: ${p['notes']}'),
        ]);
      case 'sale_correction':
        final c = Map<String, dynamic>.from((p['changes'] as Map?) ?? {});
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('Sale #${p['sale_no']} — reason: ${p['reason']}', style: const TextStyle(fontSize: Fs.sm)),
          for (final (k, f) in const [('Date', 'sale_date'), ('Customer', 'walk_in_name'), ('Site', 'site'), ('EFD receipt', 'efd_receipt_no'), ('Notes', 'notes')])
            if (c.containsKey(f)) _kv(k, '${c[f] ?? ''}'.isEmpty ? '— (cleared)' : '${c[f]}'),
          for (final l in (c['lines'] as List? ?? []))
            _kv('${l['remove'] == true ? 'Remove ' : ''}${_item(l)}${l['color_id'] != null ? ' ${refs.colour(l['color_id'])}' : ''}', l['remove'] == true ? '—' : '${qtyText(n(l['quantity']))} × ${l['price'] == null ? '—' : formatAmount(n(l['price']))}'),
          for (final x in (c['payments'] as List? ?? []))
            _kv(x['remove'] == true ? 'Remove this payment' : 'Change payment', '${x['amount'] != null ? formatAmount(n(x['amount'])) : '—'} · ${tableDate(x['paid_on']) ?? '—'} · ${x['receipt_no'] ?? '—'}'),
        ]);
      default:
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final e in p.entries.where((e) => e.key != 'draft_id' && e.value is! Map && e.value is! List))
            _kv(e.key.replaceAll(RegExp(r'_id$'), '').replaceAll('_', ' '), _show(e.key, e.value)),
        ]);
    }
  }

  String _show(String k, Object? v) {
    if (v == null || '$v'.isEmpty) return '—';
    if (k == 'product_id') return refs.items['p:$v']?.name ?? '—';
    if (k == 'material_id') return refs.items['m:$v']?.name ?? '—';
    if (k == 'color_id' || k == 'base_color_id') return refs.colour('$v');
    if (k == 'unit_id') return refs.unit('$v');
    if (k == 'warehouse_id') return _store(v);
    if (k == 'supplier_id') return '${refs.suppliers.where((s) => s['id'] == v).firstOrNull?['name'] ?? '—'}';
    if (k == 'category_id') return '${refs.categoryRows.where((c) => c['id'] == v).firstOrNull?['name'] ?? '—'}';
    if (v is bool) return v ? 'Yes' : 'No';
    if (v is num) return formatAmount(v);
    return '$v';
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: Text(k, style: TextStyle(fontSize: Fs.sm, color: context.tk.textSecondary))),
          const SizedBox(width: 10),
          Flexible(child: Text(v, textAlign: TextAlign.right, style: const TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w600))),
        ]),
      );
}

// ---- Reviews (web pages/ReviewQueue.jsx): open flags, newest on top -------------------------------
const _entityNames = {
  'product': ('products', 'canonical_name'), 'material': ('materials', 'name'), 'product_category': ('product_categories', 'name'),
  'color': ('color_palette', 'name'), 'unit': ('units', 'symbol'), 'supplier': ('suppliers', 'name'), 'identity_decision': ('identity_decisions', 'term'),
};
const _entityLabels = {
  'product': 'Product', 'material': 'Material', 'product_category': 'Category', 'color': 'Colour', 'unit': 'Unit', 'supplier': 'Supplier',
  'identity_decision': 'Decision', 'production_batch': 'Production batch', 'stock_double_entry': 'Stock double entry',
};

class ReviewsPage extends StatefulWidget {
  const ReviewsPage({super.key});
  @override
  State<ReviewsPage> createState() => _ReviewsPageState();
}

class _ReviewsPageState extends State<ReviewsPage> {
  List<Json>? _flags;
  Map<String, String> _names = {};
  String _filter = 'all';
  String _error = '';

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final (d, _) = await offline.load<Json>('flags', () async {
        final flags = await db.from('review_flags').select('id, entity_type, entity_id, reason_code, reason, created_at, admin_explanation').eq('status', 'open')
            .order('entity_type').order('created_at', ascending: false);
        final byType = <String, List>{};
        for (final f in flags) { byType.putIfAbsent(f['entity_type'], () => []).add(f['entity_id']); }
        final names = <String, String>{};
        for (final e in byType.entries.where((e) => _entityNames.containsKey(e.key))) {
          final (table, col) = _entityNames[e.key]!;
          final rows = await db.from(table).select('id, $col').inFilter('id', e.value);
          for (final r in rows) { names['${e.key}:${r['id']}'] = '${r[col]}'; }
        }
        return {'flags': flags, 'names': names};
      });
      if (mounted) setState(() { _flags = [for (final f in d['flags'] as List) Map<String, dynamic>.from(f)]; _names = Map<String, String>.from(d['names']); });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load the review queue. Please try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_error.isNotEmpty) return ErrorState(_error, onRetry: _load);
    final flags = _flags;
    if (flags == null) return const Padding(padding: EdgeInsets.all(14), child: Skeleton());
    final types = {for (final f in flags) '${f['entity_type']}'}.toList();
    final shown = _filter == 'all' ? flags : flags.where((f) => f['entity_type'] == _filter).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        if (types.length > 1) ...[
          Wrap(spacing: 6, runSpacing: 6, children: [
            Chip2('All (${flags.length})', on: _filter == 'all', onTap: () => setState(() => _filter = 'all')),
            for (final t in types) Chip2('${_entityLabels[t] ?? t} (${flags.where((f) => f['entity_type'] == t).length})', on: _filter == t, onTap: () => setState(() => _filter = t)),
          ]),
          const SizedBox(height: 10),
        ],
        if (shown.isEmpty) const EmptyState(icon: LucideIcons.flag, title: 'Nothing to review', description: 'Records with missing or uncertain data appear here.')
        else
          for (final f in shown)
            CardBox(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(_names['${f['entity_type']}:${f['entity_id']}'] ?? '—', style: const TextStyle(fontWeight: FontWeight.w600)),
              PlHelp(_entityLabels[f['entity_type']] ?? '${f['entity_type']}'),
              const SizedBox(height: 6),
              Text(datesInText('${f['reason'] ?? ''}'), style: const TextStyle(fontSize: Fs.sm)),
              const SizedBox(height: 6),
              const PlHelp('Your choices for this flag come with its page (Products, Materials…).'),
            ])),
      ]),
    );
  }
}
