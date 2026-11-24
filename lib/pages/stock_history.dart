import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';

/*
 * One item's stock history at a branch — a port of web components/inventory/ItemHistory.jsx:
 * short rows, newest on top, a running balance, a row's details when opened. Filters by kind
 * (materials: All · Purchases · Production · Other; products: All · Production · Sales · Rejects)
 * and period; order can be flipped. Products: sold but not yet collected on the Sales tab;
 * the Rejects store's own lines on the Rejects tab (139).
 */
const _label = {
  'opening_balance': 'Opening stock', 'receipt': 'Received', 'issue': 'Issued', 'transfer_in': 'Transfer in', 'transfer_out': 'Transfer out',
  'adjustment': 'Adjustment', 'count': 'Count', 'reversal': 'Reversal', 'reclassification': 'Reclassified',
  'production_use': 'Production', 'production_output': 'Cast', 'curing_out': 'Out of curing', 'curing_in': 'Released',
  'sale_delivery': 'Sold — left', 'waste': 'Thrown away',
};
const _production = {'production_use', 'production_output', 'curing_out', 'curing_in'};
String _groupOf(Json t) => t['buy'] != null ? 'purchase' : _production.contains(t['transaction_type']) ? 'production' : t['transaction_type'] == 'sale_delivery' ? 'sales' : 'movement';
const _groups = [('all', 'All'), ('purchase', 'Purchases'), ('production', 'Production'), ('movement', 'Other')];
const _productGroups = [('all', 'All'), ('production', 'Production'), ('sales', 'Sales'), ('rejects', 'Rejects')];
double _r2(double v) => (v * 100).round() / 100;

class ItemHistoryList extends StatefulWidget {
  const ItemHistoryList({super.key, required this.item, required this.branchId, required this.refs, this.mode = 'all',
      required this.factor, required this.symbol, required this.stockSymbol});
  final Item item;
  final String? branchId;
  final Refs refs;
  final String mode;
  final double factor;
  final String symbol, stockSymbol;
  @override
  State<ItemHistoryList> createState() => _ItemHistoryListState();
}

class _ItemHistoryListState extends State<ItemHistoryList> {
  List<Json>? _rows;
  List<Json> _rejectRows = [];
  List<Json> _owed = [];
  Map<String, String> _people = {};
  late String _group = widget.mode == 'purchases' ? 'purchase' : 'all';
  String _period = 'month';
  bool _newestFirst = true;
  String? _open;

  Item get item => widget.item;
  double get f => widget.factor == 0 ? 1 : widget.factor;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final col = item.isProduct ? 'product_id' : 'material_id';
    try {
      final (data, _) = await offline.load<Json>('history:${item.key}', () async {
        final res = await Future.wait<dynamic>([
          db.from('inventory_transactions').select(
              'id, transaction_date, transaction_type, quantity, entered_quantity, entered_unit_id, unit_cost, color_id, seq, created_at, warehouse:warehouses!inner(branch_id, name, type), unit:units!inventory_transactions_entered_unit_id_fkey(symbol), movement:inventory_movements(movement_type, reason, reference, notes, created_by, production_batch_id, sale_id)')
              .eq(col, item.id).order('transaction_date').order('seq'),
          item.isProduct ? Future.value(<dynamic>[]) : db.from('purchase_line_costs').select('*').eq('material_id', item.id),
          item.isProduct
              ? db.from('sale_lines').select('id, quantity, color_id, sale:sales!inner(id, sale_no, stage, sale_date, branch_id, walk_in_name, customer:customers(name)), done:sale_delivery_lines(quantity)')
                  .eq('product_id', item.id).inFilter('sale.stage', ['order', 'invoice'])
              : Future.value(<dynamic>[]),
        ]);
        return {'t': res[0], 'pc': res[1], 'owed': res[2]};
      });
      final bought = {for (final x in (data['pc'] as List? ?? [])) x['transaction_id']: Map<String, dynamic>.from(x)};
      final here = [for (final x in (data['t'] as List? ?? [])) Map<String, dynamic>.from(x)]
          .where((x) => widget.branchId == null || x['warehouse']?['branch_id'] == widget.branchId).toList();
      var rb = 0.0;
      _rejectRows = [for (final x in here.where((x) => x['warehouse']?['type'] == 'rejects')) {...x, 'balance': rb += n(x['quantity']), 'inRejects': true}];
      var bal = 0.0;
      final list = [
        for (final x in here.where((x) => x['warehouse']?['type'] != 'rejects'))
          {...x, 'buy': bought[x['id']], 'balance': bal += n(x['quantity']), 'reject': x['transaction_type'] == 'waste' && x['movement']?['reason'] == 'Broken while loading'},
      ];
      _owed = [
        for (final l in (data['owed'] as List? ?? []))
          if (widget.branchId == null || l['sale']['branch_id'] == widget.branchId)
            {...Map<String, dynamic>.from(l), 'left': n(l['quantity']) - (l['done'] as List? ?? []).fold<double>(0, (t, d) => t + n(d['quantity']))},
      ].where((l) => n(l['left']) > 1e-9).toList()
        ..sort((a, b) => '${b['sale']['sale_date']}'.compareTo('${a['sale']['sale_date']}'));
      if (mounted) setState(() => _rows = list);
      final ids = {for (final x in list) x['movement']?['created_by']}.whereType<String>().toList();
      if (ids.isNotEmpty && offline.online) {
        final ppl = await db.from('profiles').select('id, first_name, last_name, email').inFilter('id', ids);
        if (mounted) {
          setState(() => _people = {
                for (final p in ppl)
                  p['id'] as String: [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ').isNotEmpty
                      ? [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ')
                      : '${p['email'] ?? ''}',
              });
        }
      }
    } catch (_) {
      if (mounted) setState(() => _rows = []);
    }
  }

  bool _inGroup(Json x, String g) => g == 'all' || (g == 'rejects' ? x['inRejects'] == true : _groupOf(x) == g);

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final groups = item.isProduct ? _productGroups : _groups;
    final (since, until) = periodRange(_period, session.today);
    final pool = _group == 'rejects' ? _rejectRows : (_rows ?? []);
    final shown = pool.where((x) => _inGroup(x, _group) && '${x['transaction_date']}'.compareTo(since) >= 0 && '${x['transaction_date']}'.compareTo(until) <= 0).toList();
    final ordered = _newestFirst ? shown.reversed.toList() : shown;
    final rejectsTotal = _rejectRows.isEmpty ? 0.0 : n(_rejectRows.last['balance']);
    final counts = {
      for (final (k, _) in groups) k: k == 'rejects' ? _rejectRows.length : (_rows ?? []).where((x) => _inGroup(x, k)).length + (k == 'sales' ? _owed.length : 0),
    };
    String dm(String d) => '${d.substring(8, 10)}/${d.substring(5, 7)}';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.mode != 'purchases')
        SlideRow(children: [
          for (final (k, l) in groups)
            if (counts[k]! > 0 || k == 'all') Chip2('$l ${counts[k]! > 0 ? '(${counts[k]})' : ''}', on: _group == k, onTap: () => setState(() => _group = k)),
        ]),
      const SizedBox(height: 8),
      PeriodBar(value: _period, onChange: (v) => setState(() => _period = v), extra: const [('all', 'All time')]),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton(onPressed: () => setState(() => _newestFirst = !_newestFirst), child: Text('${_newestFirst ? 'Newest first' : 'Oldest first'} ⇅')),
      ),
      if (_group == 'sales' && _owed.isNotEmpty) ...[
        Text.rich(TextSpan(children: [
          const TextSpan(text: 'Sold, still to collect: '),
          TextSpan(text: '${qtyText(_r2(_owed.fold<double>(0, (s, l) => s + n(l['left'])) / f))} ${widget.symbol}', style: const TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: ' · still in the store until the goods leave', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
        ]), style: const TextStyle(fontSize: Fs.sm)),
        const SizedBox(height: 6),
        for (final l in _owed)
          _line(context, dm('${l['sale']['sale_date']}'), 'To collect', C.warning,
              '#${l['sale']['sale_no']} · ${l['sale']['customer']?['name'] ?? l['sale']['walk_in_name'] ?? 'Walk-in'}${l['color_id'] != null ? ' · ${widget.refs.colour(l['color_id'])}' : ''}',
              '${qtyText(_r2(n(l['left']) / f))} ${widget.symbol}', true, '', '—', null),
        const Padding(padding: EdgeInsets.only(top: 10, bottom: 4), child: PlHelp('Left the store:')),
      ],
      if (_group == 'rejects')
        Text.rich(TextSpan(children: [
          const TextSpan(text: 'In Rejects now: '),
          TextSpan(text: '${qtyText(_r2(rejectsTotal / f))} ${widget.symbol}', style: const TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: ' · rejected at release or broken while loading — kept apart from the good stock', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
        ]), style: const TextStyle(fontSize: Fs.sm)),
      if (_rows == null) const Skeleton(rows: 4, height: 34)
      else if (ordered.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: PlHelp('Nothing in this view.'))
      else
        for (final x in ordered) ...[
          (() {
            final q = n(x['quantity']);
            final price = x['buy'] != null ? x['buy']['unit_price'] : x['unit_cost'];
            final supplier = x['buy'] != null ? (widget.refs.suppliers.where((s) => s['id'] == x['buy']['supplier_id']).firstOrNull?['name']) : null;
            final kind = x['buy'] != null
                ? 'Purchase'
                : x['inRejects'] == true
                    ? (q < 0 ? 'Out of rejects' : x['transaction_type'] == 'curing_in' ? 'Rejected at release' : x['movement']?['reason'] == 'Broken while loading' ? 'Broken loading' : 'Into rejects')
                    : x['reject'] == true ? 'Reject' : _label[x['transaction_type']] ?? '${x['transaction_type']}';
            final color = switch (_groupOf(x)) { 'purchase' => C.info, 'production' => C.success, 'sales' => C.warning, _ => t.textSecondary };
            return _line(context, dm('${x['transaction_date']}'), kind, color, '${supplier ?? (x['color_id'] != null ? widget.refs.colour(x['color_id']) : '')}',
                '${q < 0 ? '−' : '+'}${qtyText(_r2(q.abs() / f))} ${widget.symbol}', q < 0, price != null ? formatMoney(n(price), session.currency) : '',
                qtyText(_r2(n(x['balance']) / f)), x);
          })(),
        ],
      const SizedBox(height: 8),
      PlHelp('Quantities in ${widget.symbol}; balance after each line.'),
    ]);
  }

  Widget _line(BuildContext context, String date, String kind, Color kindColor, String who, String qty, bool out, String price, String bal, Json? x) {
    final t = context.tk;
    final isOpen = x != null && _open == x['id'];
    return Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InkWell(
          onTap: x == null ? null : () => setState(() => _open = isOpen ? null : x['id']),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Icon(isOpen ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 14, color: x == null ? Colors.transparent : t.textMuted),
              const SizedBox(width: 4),
              SizedBox(width: 40, child: Text(date, style: TextStyle(fontSize: Fs.xs, color: t.textMuted))),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(kind, style: TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w600, color: kindColor)),
                  if (who.isNotEmpty) Text(who, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(qty, style: TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w600, color: out ? C.error : C.success)),
                if (price.isNotEmpty) Text(price, style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
              ]),
              const SizedBox(width: 10),
              SizedBox(width: 58, child: Text(bal, textAlign: TextAlign.right, style: const TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w600))),
            ]),
          ),
        ),
        if (isOpen) _detail(context, x),
      ]),
    );
  }

  Widget _detail(BuildContext context, Json x) {
    final q = n(x['quantity']);
    final m = x['movement'];
    final buy = x['buy'];
    final cur = session.currency;
    Widget kv(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 82, child: Text(k, style: TextStyle(fontSize: Fs.xs, color: context.tk.textMuted))),
            Expanded(child: Text(v, style: const TextStyle(fontSize: Fs.sm))),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(22, 0, 0, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        kv('Store', '${x['warehouse']?['name'] ?? ''}'),
        kv('Entered', '${qtyText(n(x['entered_quantity']).abs())} ${x['unit']?['symbol'] ?? ''}${f != 1 || x['unit']?['symbol'] != widget.stockSymbol ? ' = ${qtyText(_r2(q.abs()))} ${widget.stockSymbol}' : ''}'),
        if (buy != null) ...[
          kv('Paid', '${formatMoney(n(buy['unit_price']), cur)} per ${x['unit']?['symbol'] ?? ''} · line ${formatMoney(n(buy['line_amount']), cur)}'),
          kv('Cost', '${formatMoney(n(buy['cost_per_stock_unit']) * f, cur)} per ${widget.symbol} (incl. VAT & transport)${n(buy['vat_share']) > 0 ? ' · VAT ${formatMoney(n(buy['vat_share']), cur)}' : ''}'),
        ],
        if (buy == null && x['unit_cost'] != null) kv('Cost', '${formatMoney(n(x['unit_cost']), cur)} per ${x['unit']?['symbol'] ?? ''}'),
        if (m?['reason'] != null) kv('Note', '${m['reason']}'),
        if (m?['reference'] != null || m?['sale_id'] != null || m?['production_batch_id'] != null)
          kv('Reference', '${m['reference'] ?? (m['sale_id'] != null ? 'A sale' : 'Production batch')}'),
        kv('Recorded', '${_people[m?['created_by']] ?? '—'} · ${dateTimeText(x['created_at']) ?? ''}'),
      ]),
    );
  }
}
