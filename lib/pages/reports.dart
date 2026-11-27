import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/reports.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../core/xlsx.dart';
import '../shell.dart';

/*
 * Reports — a port of web pages/Reports.jsx (1f, PRD 4.15; approved 2026-11-24): a tab a report for a date
 * range at the chosen branch (or every branch the viewer sees). Each tab: three summary cards, the range,
 * its table, Excel. On the phone the table is a sheet: first column fixed, figures swipe, total row last.
 */
const _tabs = [('production', 'Production'), ('sales', 'Sales'), ('spending', 'Purchases & expenses'), ('materials', 'Materials used'), ('profit', 'Profit'), ('branches', 'Branches')];
String _n2(Object? v) => v == null ? '' : qtyText((n(v) * 100).roundToDouble() / 100);
String _n1(Object? v) => v == null ? '' : n1(n(v));
String _amt(Object? v) => formatAmount(n(v).roundToDouble());
int _r(Object? v) => n(v).round();

/// A sheet cell: text, an optional small line under it, warning colour, bold, indent
class RCell {
  const RCell(this.text, {this.sub, this.warn = false, this.bold = false, this.indent = false});
  final String text;
  final String? sub;
  final bool warn, bold, indent;
}

RCell _c(Object? v) => v is RCell ? v : RCell('${v ?? ''}');

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, this.tab, this.from, this.to});
  final String? tab, from, to;   // a dashboard card opens its own report (?tab=, ?from=&to=)
  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage> {
  late String _tab = _tabs.any((t) => t.$1 == widget.tab) ? widget.tab! : 'production';
  String _nested = 'a';
  late final _rp = RangePeriod('reports');
  Refs? _refs;
  ({String tab, Object value})? _loaded;
  DateTime? _savedAt;
  String _error = '';
  int _req = 0;

  @override
  void initState() {
    super.initState();
    if (widget.from != null && widget.to != null) _rp.set('custom', (widget.from!, widget.to!));
    Refs.load().then((r) { if (mounted) { setState(() => _refs = r); _load(); } }).catchError((_) { if (mounted) setState(() => _error = "We couldn't load the report."); });
  }

  Future<void> _load() async {
    final refs = _refs;
    if (refs == null) return;
    setState(() { _error = ''; _loaded = null; });
    final tab = _tab, from = _rp.from, to = _rp.to, req = ++_req;
    try {
      final (value, at) = await offline.load<Object>('report:$tab:${session.branchId}:$from:$to', () async => switch (tab) {
            'production' => await rpProduction(refs, from, to),
            'sales' => await rpSales(refs, from, to),
            'spending' => await rpSpending(from, to),
            'materials' => await rpMaterialUse(refs, from, to),
            'profit' => await rpProfit(from, to),
            _ => await rpBranches(from, to),
          });
      if (mounted && req == _req) setState(() { _loaded = (tab: tab, value: value); _savedAt = at; });
    } catch (_) {
      if (mounted && req == _req) setState(() => _error = "We couldn't load the report.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = session.currency;
    String money(Object? v) => formatMoney(n(v).roundToDouble(), cur);
    String short(Object? v) => formatMoneyShort(n(v), cur);
    final from = _rp.from, to = _rp.to;
    final where = session.branchId.isNotEmpty ? (session.branchName ?? '') : 'all branches';
    final title = '${_tabs.firstWhere((t) => t.$1 == _tab).$2} — $where, $from to $to';
    final data = _loaded?.tab == _tab ? _loaded!.value : null;

    List<Stat>? cards;
    var head = <String>[];
    var rows = <List<Object?>>[];
    List<Object?>? total;
    VoidCallback? xl;
    List<(String, String)>? nestedTabs;
    String? note;
    Stat card(String label, String figure, String help) => Stat(label, figure, help: help);

    if (data != null) {
      switch (_tab) {
        case 'production':
          final d = data as Json;
          final r = [for (final x in d['rows'] as List) x as Map];
          double tt(String f) => r.fold(0, (t, x) => t + n(x[f]));
          final pcs = tt('pieces'), bags = tt('bags'), rel = tt('released'), rej = tt('rejected'), cost = tt('cost');
          cards = [
            card('Pieces cast', formatAmount(pcs), '${d['batches']} batches · ${r.length} products'),
            card('Cement', '${_n2(bags)} bags', 'wastani ${bags > 0 ? _n1((pcs + tt('leftovers')) / bags) : '—'} a bag'),
            card('Rejected', formatAmount(rej), rel > 0 ? '${_n1(rej / rel * 100)}% of released' : 'nothing released yet'),
          ];
          head = ['Product', 'Batches', 'Cement bags', 'Pieces cast', 'Leftovers', 'Wastani', 'Curing', 'Passed', 'Rejected', 'Reject %', 'Material cost (TZS)', 'A piece (TZS)'];
          rows = [
            for (final x in r)
              [x['name'], _r(x['batches']), _n2(x['bags']), formatAmount(n(x['pieces'])), n(x['leftovers']) != 0 ? formatAmount(n(x['leftovers'])) : '', _n1(x['wastani']),
                n(x['curing']) != 0 ? formatAmount(n(x['curing'])) : '', n(x['passed']) != 0 ? formatAmount(n(x['passed'])) : '', n(x['rejected']) != 0 ? formatAmount(n(x['rejected'])) : '',
                _n1(x['rejectPct']), _amt(x['cost']), _n2(x['perPiece'])],
          ];
          total = ['Total', d['batches'], _n2(bags), formatAmount(pcs), '', '', '', formatAmount(tt('passed')), formatAmount(rej), rel > 0 ? _n1(rej / rel * 100) : '', money(cost), ''];
          xl = () => shareXlsx('Production $from to $to', title, head, [
                for (final x in r) [x['name'], x['batches'], x['bags'], x['pieces'], x['leftovers'], x['wastani'], x['curing'], x['passed'], x['rejected'], x['rejectPct'], _r(x['cost']), x['perPiece']],
              ], ['Total', d['batches'], bags, pcs, '', '', '', '', rej, '', cost.round(), '']);
          note = 'Material cost only (materials as they left the store); full cost per product is in Costing.';
        case 'sales':
          final d = data as Json;
          cards = [
            card('Sales', short(d['total']), '${d['docs']} orders & invoices · VAT ${short(d['vat'])}'),
            card('Received', short(d['received']), 'payments in the range'),
            card('Owed now', short(d['owed']), 'all orders & invoices'),
          ];
          nestedTabs = [('a', 'By product'), ('b', 'By customer')];
          final list = [for (final x in (_nested == 'a' ? d['products'] : d['customers']) as List) x as Map];
          if (_nested == 'a') {
            head = ['Product', 'Quantity', 'Without VAT (TZS)', 'VAT (TZS)', 'Total (TZS)'];
            rows = [for (final x in list) [x['name'], '${_n2(x['quantity'])} ${x['unit']}', _amt(x['amount']), _amt(x['vat']), _amt(x['total'])]];
            xl = () => shareXlsx('Sales by product $from to $to', title, head, [for (final x in list) [x['name'], x['quantity'], _r(x['amount']), _r(x['vat']), _r(x['total'])]],
                ['Total', '', _r(d['amount']), _r(d['vat']), _r(d['total'])]);
          } else {
            head = ['Customer', 'Orders & invoices', 'Without VAT (TZS)', 'VAT (TZS)', 'Total (TZS)'];
            rows = [for (final x in list) [x['name'], _r(x['docs']), _amt(x['amount']), _amt(x['vat']), _amt(x['total'])]];
            xl = () => shareXlsx('Sales by customer $from to $to', title, head, [for (final x in list) [x['name'], _r(x['docs']), _r(x['amount']), _r(x['vat']), _r(x['total'])]],
                ['Total', d['docs'], _r(d['amount']), _r(d['vat']), _r(d['total'])]);
          }
          total = ['Total', _nested == 'a' ? '' : d['docs'], _amt(d['amount']), _amt(d['vat']), money(d['total'])];
          note = 'Orders and invoices by their date (invoiced, else ordered); quotations and cancelled ones left out.';
        case 'spending':
          final d = data as Json;
          final sup = [for (final x in d['suppliers'] as List) x as Map], cat = [for (final x in d['categories'] as List) x as Map];
          cards = [
            card('Purchases', short(d['purchases']), '${sup.fold<num>(0, (t, x) => t + n(x['count'])).round()} purchases'),
            card('Expenses', short(d['expenses']), '${cat.fold<num>(0, (t, x) => t + n(x['count'])).round()} expenses'),
            card('Not paid', short(d['owed']), 'of these, still owed'),
          ];
          nestedTabs = [('a', 'Purchases by supplier'), ('b', 'Expenses by category')];
          final list = _nested == 'a' ? sup : cat;
          double tt(String f) => list.fold(0, (t, x) => t + n(x[f]));
          head = [_nested == 'a' ? 'Supplier' : 'Category', _nested == 'a' ? 'Purchases' : 'Expenses', 'Total (TZS)', 'Paid (TZS)', 'Owed (TZS)'];
          rows = [for (final x in list) [x['name'], _r(x['count']), _amt(x['total']), _amt(x['paid']), n(x['owed']) > 0.5 ? _amt(x['owed']) : '']];
          total = ['Total', tt('count').round(), money(tt('total')), _amt(tt('paid')), _amt(tt('owed'))];
          xl = () => shareXlsx('${_nested == 'a' ? 'Purchases' : 'Expenses'} $from to $to', title, head,
              [for (final x in list) [x['name'], _r(x['count']), _r(x['total']), _r(x['paid']), _r(x['owed'])]], ['Total', '', tt('total').round(), tt('paid').round(), tt('owed').round()]);
        case 'materials':
          final d = [for (final x in data as List) x as Map];
          final cost = d.fold<double>(0, (t, x) => t + n(x['cost']));
          final over = d.where((x) => x['diffPct'] != null && n(x['diffPct']) > 5).length;
          cards = [
            card('Materials used', short(cost), '${d.length} materials'),
            card('Over the recipe', '$over', over > 0 ? 'more than 5% above' : 'all within 5%'),
            card('Counted', '${d.where((x) => n(x['counted']) > 0).length}', 'materials counted for real'),
          ];
          head = ['Material', 'Recipe (standard)', 'Actual', 'Difference', 'Difference %', 'Counted', 'Cost (TZS)'];
          rows = [
            for (final x in d)
              [
                RCell('${x['name']}', sub: '${x['category']}'),
                '${_n2(x['standard'])} ${x['unit']}', '${_n2(x['actual'])} ${x['unit']}',
                x['diff'] != null ? '${n(x['diff']) > 0 ? '+' : ''}${_n2(x['diff'])}' : '',
                x['diffPct'] != null ? RCell('${n(x['diffPct']) > 0 ? '+' : ''}${_n1(x['diffPct'])}%', warn: n(x['diffPct']).abs() > 5) : '',
                n(x['counted']) != 0 ? _n2(x['counted']) : '',
                x['costKnown'] == true ? _amt(x['cost']) : RCell(_amt(x['cost']), sub: 'part'),
              ],
          ];
          total = ['Total', '', '', '', '', '', money(cost)];
          xl = () => shareXlsx('Materials used $from to $to', title, ['Material', 'Category', 'Unit', 'Recipe', 'Actual', 'Difference', 'Difference %', 'Counted', 'Cost'],
              [for (final x in d) [x['name'], x['category'], x['unit'], x['standard'], x['actual'], x['diff'], x['diffPct'], x['counted'], _r(x['cost'])]], ['Total', '', '', '', '', '', '', '', cost.round()]);
          note = 'Recipe = the recipe × the bags of cement; actual = what left the store. Only counted materials can differ.';
        case 'profit':
          final d = data as Json;
          final pct = n(d['sales']) != 0 ? n(d['margin']) / n(d['sales']) * 100 : null;
          final exps = [for (final x in d['expenses'] as List) x as Map];
          cards = [
            card('Delivered', short(d['sales']), '${d['deliveries']} lines · without VAT'),
            card('Gross margin', short(d['margin']), pct != null ? '${_n1(pct)}% of delivered' : '—'),
            card('Profit', short(d['net']), 'after other costs'),
          ];
          head = ['', 'Amount (TZS)'];
          rows = [
            ['Goods delivered or collected (without VAT)', _amt(d['sales'])],
            [
              RCell('Their production cost', sub: 'materials, electricity, overheads, labour${n(d['noCost']) > 0 ? ' · ${d['noCost']} lines had no cost' : ''}${n(d['estimated']) != 0 ? ' · ${_amt(d['estimated'])} estimated' : ''}'),
              '− ${_amt(d['cost'])}',
            ],
            [const RCell('Gross margin', bold: true), RCell(_amt(d['margin']), bold: true)],
            for (final x in exps) [RCell('${x['name']}', indent: true), '− ${_amt(x['total'])}'],
            if (d['officePay'] != null) [const RCell('Office & running staff pay (paid sheets)', indent: true), '− ${_amt(d['officePay'])}'],
          ];
          total = ['Profit', money(d['net'])];
          xl = () => shareXlsx('Profit $from to $to', title, ['', 'Amount'], [
                ['Goods delivered (without VAT)', _r(d['sales'])], ['Production cost', -_r(d['cost'])], ['Gross margin', _r(d['margin'])],
                for (final x in exps) [x['name'], -_r(x['total'])],
                if (d['officePay'] != null) ['Office & running staff pay', -_r(d['officePay'])],
              ], ['Profit', _r(d['net'])]);
          note = 'Basic: electricity, production overheads and production staff are already in the production cost, so their expenses are left out here. Cash timing, depreciation and tax are not included.';
        default:
          final d = [for (final x in data as List) x as Map];
          double tt(String f) => d.fold(0, (t, x) => t + n(x[f]));
          cards = [
            card('Branches', '${d.length}', '${dateText(from)} to ${dateText(to)}'),
            card('Sales', short(tt('sales')), 'orders & invoices'),
            card('Pieces cast', formatAmount(tt('pieces')), '${_n2(tt('bags'))} bags of cement'),
          ];
          head = ['Branch', 'Batches', 'Cement bags', 'Pieces cast', 'Sales (TZS)', 'Purchases (TZS)', 'Expenses (TZS)'];
          rows = [for (final x in d) [x['name'], _r(x['batches']), _n2(x['bags']), formatAmount(n(x['pieces'])), _amt(x['sales']), _amt(x['purchases']), _amt(x['expenses'])]];
          total = ['Total', tt('batches').round(), _n2(tt('bags')), formatAmount(tt('pieces')), money(tt('sales')), _amt(tt('purchases')), _amt(tt('expenses'))];
          xl = () => shareXlsx('Branches $from to $to', title, head,
              [for (final x in d) [x['name'], _r(x['batches']), x['bags'], x['pieces'], _r(x['sales']), _r(x['purchases']), _r(x['expenses'])]],
              ['Total', tt('batches').round(), tt('bags'), tt('pieces'), tt('sales').round(), tt('purchases').round(), tt('expenses').round()]);
          note = 'Every branch you can see, whichever branch is chosen above.';
      }
    }

    return RefreshIndicator(
      onRefresh: _load,
      child: PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        OfflineNote(_savedAt),
        PageTabs<String>(tabs: _tabs, value: _tab, onChange: (v) { setState(() { _tab = v; _nested = 'a'; }); _load(); }),
        PlHelp(where.isEmpty ? '' : '${where[0].toUpperCase()}${where.substring(1)}'),
        const SizedBox(height: 6),
        if (_error.isNotEmpty)
          ErrorState(_error, onRetry: _load)
        else ...[
          Stats(cards ?? [Stat('…', '…'), Stat('…', '…'), Stat('…', '…')]),
          Align(
            alignment: Alignment.centerRight,
            child: OutlinedButton.icon(onPressed: xl, icon: const Icon(LucideIcons.download, size: 15), label: const Text('Excel')),
          ),
          const SizedBox(height: 8),
          _rp.bar(context, () { setState(() {}); _load(); }),
          const SizedBox(height: 8),
          if (nestedTabs != null) PageTabs<String>(tabs: nestedTabs, value: _nested, onChange: (v) => setState(() => _nested = v)),
          if (data == null)
            const Skeleton(rows: 6, height: 40)
          else if (rows.isEmpty)
            const PlHelp('Nothing in this range.')
          else
            ReportSheet(head: head, rows: rows, total: total),
          if (note != null) Padding(padding: const EdgeInsets.only(top: 8), child: PlHelp(note)),
          const SizedBox(height: 8),
          Wrap(spacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const PlHelp('Also:'),
            for (final (label, path) in const [('Stock', '/stock'), ('Movements', '/movements'), ('Customer balances', '/customers'), ('Supplier balances', '/purchases'), ('Costing', '/costing'), ('Daily report', '/daily-report')])
              TextButton(onPressed: () => Shell.of(context).go(path), child: Text(label)),
          ]),
        ],
      ]),
    );
  }
}

/// The report table on a phone: first column fixed, the figures swipe sideways, total row bold at the bottom
/// The column heads stay at the top (under the pinned tabs) while the table scrolls under them (2026-11-27, the user)
class ReportSheet extends StatefulWidget {
  const ReportSheet({super.key, required this.head, required this.rows, this.total, this.firstWidth = 150, this.colWidth = 112, this.onRowTap});
  final List<String> head;
  /// a tap on a row's first cell (not the total), e.g. a batch's job card
  final ValueChanged<int>? onRowTap;
  final List<List<Object?>> rows;
  final List<Object?>? total;
  final double firstWidth, colWidth;
  static const _rowH = 48.0, _headH = 40.0;
  @override
  State<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<ReportSheet> {
  ScrollPosition? _pos;
  ValueListenable<double>? _inset;
  double _lift = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final p = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (p != _pos) { _pos?.removeListener(_update); _pos = p; _pos?.addListener(_update); }
    final i = PinInset.of(context);
    if (i != _inset) { _inset?.removeListener(_update); _inset = i; _inset?.addListener(_update); }
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
  }

  @override
  void dispose() { _pos?.removeListener(_update); _inset?.removeListener(_update); super.dispose(); }

  /// how far the heads move down: as far as the sheet's top has gone under the pinned area, never past its last row
  void _update() {
    if (!mounted) return;
    final box = context.findRenderObject() as RenderBox?;
    final vp = Scrollable.maybeOf(context, axis: Axis.vertical)?.context.findRenderObject() as RenderBox?;
    if (box == null || vp == null || !box.attached || !vp.attached || !box.hasSize) return;
    final top = box.localToGlobal(Offset.zero, ancestor: vp).dy;
    final max = box.size.height - ReportSheet._headH - ReportSheet._rowH;
    final lift = ((_inset?.value ?? 0) - top).clamp(0.0, max < 0 ? 0.0 : max);
    if ((lift - _lift).abs() > 0.5) setState(() => _lift = lift);
  }

  List<String> get head => widget.head;
  List<List<Object?>> get rows => widget.rows;
  List<Object?>? get total => widget.total;
  ValueChanged<int>? get onRowTap => widget.onRowTap;
  double get firstWidth => widget.firstWidth;
  double get colWidth => widget.colWidth;
  static const _rowH = ReportSheet._rowH, _headH = ReportSheet._headH;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final all = [...rows, ?total];
    Widget cell(Object? v, {required bool first, bool header = false, bool isTotal = false}) {
      final c = _c(v);
      final style = TextStyle(
        fontSize: header ? Fs.xs : Fs.sm,
        color: header ? t.textMuted : c.warn ? C.warning : null,
        fontWeight: header || isTotal || c.bold ? FontWeight.w700 : (first ? FontWeight.w600 : null),
        letterSpacing: header ? 0.3 : null,
      );
      return Container(
        width: first ? firstWidth : colWidth,
        height: header ? _headH : _rowH,
        padding: EdgeInsets.only(left: first && c.indent ? 18 : 8, right: 8),
        alignment: first ? Alignment.centerLeft : Alignment.centerRight,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: first ? CrossAxisAlignment.start : CrossAxisAlignment.end, children: [
          Text(header ? c.text.toUpperCase() : c.text, maxLines: header ? 2 : (c.sub != null ? 1 : 2), overflow: TextOverflow.ellipsis, textAlign: first ? TextAlign.left : TextAlign.right, style: style),
          if (c.sub != null && !header) Text(c.sub!, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
        ]),
      );
    }

    BoxDecoration rowDeco(int i) => BoxDecoration(
          border: Border(
            bottom: BorderSide(color: t.border),
            top: total != null && i == all.length - 1 ? BorderSide(color: t.textPrimary, width: 1.5) : BorderSide.none,
          ),
        );
    return Container(
      decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(10)),
      clipBehavior: Clip.antiAlias,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          decoration: BoxDecoration(border: Border(right: BorderSide(color: t.border))),
          child: Stack(children: [
            Column(children: [
              const SizedBox(height: _headH + 1),
              for (final (i, r) in all.indexed)
                Container(
                  decoration: rowDeco(i),
                  child: onRowTap != null && i < rows.length
                      ? InkWell(onTap: () => onRowTap!(i), child: cell(r.isEmpty ? '' : r.first, first: true))
                      : cell(r.isEmpty ? '' : r.first, first: true, isTotal: total != null && i == all.length - 1),
                ),
            ]),
            // the head, painted last so it lies over the rows it slides along
            Positioned(top: _lift, left: 0, child: Container(decoration: BoxDecoration(color: t.soft, border: Border(bottom: BorderSide(color: t.borderStrong))), child: cell(head.first, first: true, header: true))),
          ]),
        ),
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Stack(children: [
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SizedBox(height: _headH + 1),
                for (final (i, r) in all.indexed)
                  Container(
                    decoration: rowDeco(i),
                    child: Row(children: [for (var j = 1; j < head.length; j++) cell(j < r.length ? r[j] : '', first: false, isTotal: total != null && i == all.length - 1)]),
                  ),
              ]),
              Positioned(
                top: _lift, left: 0,
                child: Container(
                  decoration: BoxDecoration(color: t.soft, border: Border(bottom: BorderSide(color: t.borderStrong))),
                  child: Row(children: [for (final h in head.skip(1)) cell(h, first: false, header: true)]),
                ),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}
