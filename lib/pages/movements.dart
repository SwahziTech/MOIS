import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../shell.dart';

/*
 * Movements — a port of web pages/Movements.jsx with MovementDetail (approved 2026-11-24): the inventory
 * ledger as documents (022), read-only. One card an item moved: date · type · item · qty · allocation
 * (from → to) · reference. A mistake is corrected by reversing the movement, which posts its exact
 * opposite and keeps both on record; non-admins send the reversal to Approvals (033).
 */
const _page = 500;
// every kind of movement has a plain name (2026-11-21, the user: all movements show here)
const _noun = {'production_use': 'Production use', 'production_output': 'Production', 'curing_release': 'Quality release', 'waste': 'Waste / broken',
  'sale_delivery': 'Goods leaving', 'reclassification': 'Reclassification'};
const _core = {'receipt', 'issue', 'transfer', 'adjustment', 'count', 'opening_balance', 'reversal'};
String nounOf(String t) => _core.contains(t) ? movementTypes[t]!.noun : _noun[t] ?? movementTypes[t]?.noun ?? t;
// the other side of a one-store movement, by its kind (Allocation: from → to)
const _source = {'receipt': 'Supplier', 'production_output': 'Production', 'opening_balance': 'Opening stock', 'adjustment': 'Adjustment', 'count': 'Stock count', 'reversal': 'Reversed (undone)', 'reclassification': 'Reclassified'};
const _dest = {'sale_delivery': 'Customer', 'production_use': 'Production', 'issue': 'Issued out', 'waste': 'Waste', 'adjustment': 'Adjustment', 'count': 'Stock count', 'reversal': 'Reversed (undone)', 'reclassification': 'Reclassified'};

String _itemKey(Map l) => l['material_id'] != null ? 'm:${l['material_id']}' : 'p:${l['product_id']}';
/// the date (YYYY-MM-DD) a timestamp falls on in the organization's time zone (East Africa, UTC+3)
String _dateIn(Object? ts) => ts == null ? '' : iso(DateTime.parse('$ts').toUtc().add(const Duration(hours: 3)));

/// A movement's legs for one item: from and to (a transfer, a release, broken → Rejects); one leg's other side by its kind
List<({String key, Map line, List<Map> out, List<Map> inn, String from, String to})> _groups(Map m, Refs refs, {String? kind}) {
  final g = <String, ({Map line, List<Map> out, List<Map> inn})>{};
  for (final l in [for (final x in m['lines'] as List) x as Map]) {
    if (kind != null && (kind == 'products' ? l['product_id'] == null : l['material_id'] == null)) continue;
    final k = '${_itemKey(l)}|${l['color_id'] ?? ''}';
    final e = g[k] ??= (line: l, out: <Map>[], inn: <Map>[]);
    (n(l['quantity']) < 0 ? e.out : e.inn).add(l);
  }
  String store(Object? id) => refs.store('$id')?.name ?? '—';
  return [
    for (final e in g.entries)
      (
        key: e.key, line: e.value.line, out: e.value.out, inn: e.value.inn,
        from: e.value.out.isNotEmpty
            ? {for (final l in e.value.out) store(l['warehouse_id'])}.join(', ')
            : (m['movement_type'] == 'receipt' && m['supplier']?['name'] != null ? '${m['supplier']['name']}' : _source[m['movement_type']] ?? '—'),
        to: e.value.inn.isNotEmpty
            ? {for (final l in e.value.inn) store(l['warehouse_id'])}.join(', ')
            : (m['movement_type'] == 'transfer' ? store(m['to_warehouse_id']) : _dest[m['movement_type']] ?? '—'),
      ),
  ];
}

class MovementsPage extends StatefulWidget {
  const MovementsPage({super.key});
  @override
  State<MovementsPage> createState() => _MovementsPageState();
}

class _MovementsPageState extends State<MovementsPage> {
  Refs? _refs;
  List<Map>? _movements;
  Map<String, String> _people = {};
  DateTime? _savedAt;
  String _error = '', _type = '', _warehouseId = '', _kind = 'products';

  String get branchId => session.branchId;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final refs = await Refs.load();
      final (j, at) = await offline.load<Json>('movements:$branchId', () async {
        // with a branch picked, only its movements are fetched (incl. transfers into it)
        var q = db.from('inventory_movements').select('id, movement_type, movement_date, created_at, created_by, branch_id, warehouse_id, to_warehouse_id, '
            'reference, reason, notes, reverses_movement_id, supplier:suppliers(name), sale:sales(id, sale_no, walk_in_name, customer:customers(name)), '
            'lines:inventory_transactions(id, transaction_type, warehouse_id, material_id, product_id, color_id, quantity, stock_unit_id, entered_quantity, entered_unit_id, counted_quantity, unit_cost)');
        if (branchId.isNotEmpty) {
          final ids = [for (final w in refs.warehouses) if (w.branchId == branchId) w.id];
          q = q.or(ids.isNotEmpty ? 'branch_id.eq.$branchId,to_warehouse_id.in.(${ids.join(',')})' : 'branch_id.eq.$branchId');
        }
        // the day it happened, newest first; the same day in the order recorded, latest first (2026-11-21, the user)
        final mv = await q.order('movement_date', ascending: false).order('created_at', ascending: false).limit(_page);
        final ids = {for (final m in mv) if (m['created_by'] != null) '${m['created_by']}'}.toList();
        final ppl = ids.isEmpty ? [] : await db.from('profiles').select('id, first_name, last_name, email').inFilter('id', ids);
        return {'mv': mv, 'people': ppl};
      });
      if (!mounted) return;
      setState(() {
        _refs = refs;
        _movements = [for (final m in j['mv'] as List) m as Map];
        _people = {
          for (final p in j['people'] as List)
            '${p['id']}': [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ').isNotEmpty
                ? [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ')
                : '${p['email']}',
        };
        _savedAt = at;
      });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load movements. Please try again.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final refs = _refs, list = _movements;
    if (_error.isNotEmpty && list == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    if (refs == null || list == null) return ListView(padding: const EdgeInsets.all(14), children: const [Skeleton(rows: 6)]);
    final reversedBy = {for (final m in list) if (m['reverses_movement_id'] != null) '${m['reverses_movement_id']}': m};
    bool ofKind(Map m) => (m['lines'] as List).any((l) => _kind == 'products' ? l['product_id'] != null : l['material_id'] != null);
    final types = {for (final m in list) if (ofKind(m)) '${m['movement_type']}'}.toList()..sort((a, b) => nounOf(a).compareTo(nounOf(b)));
    final stores = refs.warehouses.where((w) => session.inBranch(w.branchId)).toList();
    final shown = list.where((m) => ofKind(m) && (_type.isEmpty || m['movement_type'] == _type) &&
        (session.inBranch(refs.store('${m['warehouse_id']}')?.branchId) || session.inBranch(refs.store('${m['to_warehouse_id']}')?.branchId)) &&
        (_warehouseId.isEmpty || m['warehouse_id'] == _warehouseId || m['to_warehouse_id'] == _warehouseId));
    final rows = [
      for (final m in shown)
        for (final g in _groups(m, refs, kind: _kind))
          (
            m: m, g: g,
            name: '${refs.items[_itemKey(g.line)]?.name ?? '—'}${g.line['color_id'] != null ? ' ${refs.colour('${g.line['color_id']}')}' : ''}',
            qty: (g.out.isNotEmpty ? g.out : g.inn).fold<double>(0, (s, l) => s + n(l['quantity']).abs()),
            unit: refs.unit('${g.line['stock_unit_id']}'),
          ),
    ];
    Widget drop(String value, String all, List<(String, String)> items, ValueChanged<String> on) => PopupMenuButton<String>(
          initialValue: value,
          onSelected: on,
          itemBuilder: (_) => [PopupMenuItem(value: '', child: Text(all)), for (final (v, l) in items) PopupMenuItem(value: v, child: Text(l))],
          child: Container(
            constraints: const BoxConstraints(maxWidth: 170),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(border: Border.all(color: t.borderStrong), borderRadius: BorderRadius.circular(6)),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: Text(value.isEmpty ? all : items.where((x) => x.$1 == value).firstOrNull?.$2 ?? all, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: Fs.sm))),
              const Icon(LucideIcons.chevronDown, size: 14),
            ]),
          ),
        );
    return RefreshIndicator(
      onRefresh: () async { await Refs.load(fresh: true); await _load(); },
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        OfflineNote(_savedAt),
        PageTabs<String>(tabs: const [('products', 'Products'), ('materials', 'Materials')], value: _kind, onChange: (k) => setState(() { _kind = k; _type = ''; })),
        SlideRow(spacing: 8, children: [
          drop(_type, 'All types', [for (final k in types) (k, nounOf(k))], (v) => setState(() => _type = v)),
          drop(_warehouseId, 'All stores', [for (final w in stores) (w.id, branchId.isEmpty ? warehouseLabel(w) : w.name)], (v) => setState(() => _warehouseId = v)),
        ]),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          const EmptyState(icon: LucideIcons.arrowLeftRight, title: 'No movements yet', description: 'Receipts, issues, transfers, adjustments and counts appear here once posted.')
        else
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: t.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () async {
                    final done = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _MovementDetail(
                          movement: r.m, refs: refs, people: _people,
                          original: list.where((x) => x['id'] == r.m['reverses_movement_id']).firstOrNull,
                          reversal: reversedBy['${r.m['id']}'],
                        )));
                    if (done == true) _load();
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Text(tableDate(r.m['movement_date']) ?? '—', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                        Badge2(nounOf('${r.m['movement_type']}')),
                        if (reversedBy['${r.m['id']}'] != null) const Badge2('reversed', tone: Tone.warning),
                        if (_dateIn(r.m['created_at']).compareTo('${r.m['movement_date']}') > 0) PlHelp('entered ${tableDate(_dateIn(r.m['created_at']))}'),
                      ]),
                      const SizedBox(height: 4),
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                        Text.rich(TextSpan(children: [
                          TextSpan(text: qtyText((r.qty * 1000).roundToDouble() / 1000), style: const TextStyle(fontWeight: FontWeight.w700)),
                          TextSpan(text: ' ${r.unit}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                        ])),
                      ]),
                      Text('${r.g.from} → ${r.g.to}', style: TextStyle(fontSize: Fs.sm, color: t.textSecondary)),
                      PlHelp([
                        '${r.m['reference'] ?? ''}'.isNotEmpty ? '${r.m['reference']}' : '${r.m['supplier']?['name'] ?? '—'}',
                        if (r.m['sale'] != null) '${r.m['sale']['customer']?['name'] ?? r.m['sale']['walk_in_name'] ?? 'Walk-in'}',
                        if (_people['${r.m['created_by']}'] != null) 'by ${_people['${r.m['created_by']}']}',
                      ].join(' · ')),
                    ]),
                  ),
                ),
              ),
            ),
        if (list.length == _page) const PlHelp('Showing the latest $_page movements.'),
      ]),
    );
  }
}

class _MovementDetail extends StatefulWidget {
  const _MovementDetail({required this.movement, required this.refs, required this.people, this.original, this.reversal});
  final Map movement;
  final Refs refs;
  final Map<String, String> people;
  final Map? original, reversal;
  @override
  State<_MovementDetail> createState() => _MovementDetailState();
}

class _MovementDetailState extends State<_MovementDetail> {
  Map get m => widget.movement;
  Refs get refs => widget.refs;
  Map<String, Object?> _after = {};   // line id → store balance after it (date order)
  final _reason = TextEditingController();
  bool _confirm = false, _busy = false, _requested = false;
  String _error = '';

  bool get canReverse => m['movement_type'] != 'reversal' && widget.reversal == null && session.canAt('inventory.adjust', '${m['branch_id']}', '${m['warehouse_id']}');
  // a reversal is a correction: non-admins send it for approval (033)
  bool get needsApproval => !session.canManage('inventory.adjust');

  @override
  void initState() {
    super.initState();
    db.from('inventory_ledger_running').select('id, running_balance').eq('movement_id', m['id']).then((data) {
      if (mounted) setState(() => _after = {for (final r in data) '${r['id']}': r['running_balance']});
    }).catchError((_) {});
  }

  Future<void> _reverse() async {
    setState(() => _error = '');
    if (_reason.text.trim().isEmpty) return setState(() => _error = 'Give a reason for the reversal.');
    setState(() => _busy = true);
    try {
      if (needsApproval) {
        await db.rpc('request_change', params: {
          'p_kind': 'stock_reversal', 'p_branch_id': null, 'p_payload': {'movement_id': m['id'], 'reason': _reason.text.trim()},
          'p_summary': 'Reverse the ${nounOf('${m['movement_type']}').toLowerCase()} of ${dateText(m['movement_date'])} at ${warehouseLabel(refs.store('${m['warehouse_id']}'))} — ${_reason.text.trim()}',
        });
        setState(() { _busy = false; _requested = true; });
        return;
      }
      await db.rpc('reverse_inventory_movement', params: {'p_movement_id': m['id'], 'p_reason': _reason.text.trim()});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e, needsApproval ? "We couldn't send this for approval. Please try again." : "We couldn't reverse this movement. Please try again."); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final groups = _groups(m, refs);
    String store(Object? id) => refs.store('$id')?.name ?? '—';
    Widget line(String k, Widget v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 100, child: Text(k, style: TextStyle(fontSize: Fs.sm, color: t.textMuted))),
            Expanded(child: v),
          ]),
        );
    Widget txt(String s) => Text(s, style: const TextStyle(fontSize: Fs.sm));
    final sale = m['sale'] as Map?;
    return FullPage(
      title: '${nounOf('${m['movement_type']}')} · ${dateText(m['movement_date'])}',
      footer: [OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        line('Allocation', txt({for (final g in groups) '${g.from} → ${g.to}'}.join(' · '))),
        if (m['supplier'] != null) line('Supplier', txt('${m['supplier']['name']}')),
        if ('${m['reason'] ?? ''}'.isNotEmpty) line('Reason', txt('${m['reason']}')),
        if ('${m['reference'] ?? ''}'.isNotEmpty) line('Reference', txt('${m['reference']}')),
        // the sale's buyer, and the sale itself in Sales (2026-11-21, the user)
        if (sale != null)
          line('Customer', Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            txt('${sale['customer']?['name'] ?? sale['walk_in_name'] ?? 'Walk-in'}'),
            TextButton(
              style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 32)),
              onPressed: () { Navigator.pop(context); Shell.of(context).go('/sales?sale=${sale['id']}'); },
              child: Text('Open sale #${sale['sale_no']} in Sales'),
            ),
          ])),
        if ('${m['notes'] ?? ''}'.isNotEmpty) line('Notes', txt('${m['notes']}')),
        line('Dated', txt(dateText(m['movement_date']) ?? '—')),
        line('Recorded', txt('${dateTimeText(m['created_at']) ?? ''} by ${widget.people['${m['created_by']}'] ?? 'a user'}')),
        if (widget.original != null) line('Reverses', txt('${nounOf('${widget.original!['movement_type']}')} of ${dateText(widget.original!['movement_date'])}')),
        if (widget.reversal != null) line('Reversed', txt('${dateText(widget.reversal!['movement_date'])} — ${widget.reversal!['reason'] ?? ''}')),
        const SectionTitle('Items'),
        for (final g in groups)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${refs.items[_itemKey(g.line)]?.name ?? '—'}${g.line['color_id'] != null ? ' · ${refs.colour('${g.line['color_id']}')}' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text('${g.from} → ${g.to}', style: TextStyle(fontSize: Fs.sm, color: t.textSecondary)),
                  for (final x in [...g.out, ...g.inn])
                    if (_after['${x['id']}'] != null) PlHelp('${store(x['warehouse_id'])} ${qtyText(n(_after['${x['id']}']))} ${refs.unit('${x['stock_unit_id']}')} after'),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                g.line['transaction_type'] == 'count'
                    ? txt('found ${qtyText(n(g.line['entered_quantity']))} ${refs.unit('${g.line['entered_unit_id']}')}')
                    : Text('${qtyText(n(g.line['entered_quantity']).abs())} ${refs.unit('${g.line['entered_unit_id']}')}', style: const TextStyle(fontWeight: FontWeight.w700)),
                if (g.line['unit_cost'] != null) PlHelp('${formatMoney(n(g.line['unit_cost']), session.currency)} each'),
              ]),
            ]),
          ),
        if (canReverse) ...[
          const SizedBox(height: 14),
          if (_requested)
            const Alert('Reversal sent for approval.', tone: Tone.info)
          else if (_confirm) ...[
            PlHelp('Reversing posts the exact opposite of this movement. Both stay on record.${needsApproval ? " A reversal needs an admin's approval: it is sent to the Approvals queue." : ''}'),
            const SizedBox(height: 8),
            TextField(controller: _reason, decoration: const InputDecoration(hintText: 'Reason, e.g. entered twice')),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton(onPressed: _busy ? null : _reverse, child: Text(needsApproval ? 'Submit reversal for approval' : 'Reverse movement')),
              const SizedBox(width: 8),
              TextButton(onPressed: () => setState(() => _confirm = false), child: const Text('Keep it')),
            ]),
          ] else
            Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: () => setState(() => _confirm = true), child: const Text('Reverse this movement…'))),
        ],
      ],
    );
  }
}
