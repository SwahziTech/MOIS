import 'package:flutter/material.dart';

import 'board_data.dart';
import 'format.dart';

const _show = 5;
const _salesColor = Color(0xFF3F8FCB);
const _costsColor = Color(0xFFC2851F);

/// The director's dashboard: the phone version of the web app's DirectorBoard.
class BoardScreen extends StatelessWidget {
  const BoardScreen({super.key, required this.board, required this.onRefresh, required this.place, required this.today});
  final Board board;
  final Future<void> Function() onRefresh;
  final String place, today;

  @override
  Widget build(BuildContext context) {
    final m = board.money;
    final f = board.factory;
    final needs = board.needs;
    final change = m != null && m.lastMonth > 0 ? ((m.sales / m.lastMonth - 1) * 100).round() : null;
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (needs != null && needs.isNotEmpty) ...[_NeedsBlock(needs: needs), const SizedBox(height: 12)],
          if (needs != null && needs.isEmpty) ...[_muted(context, 'Nothing needs you right now.'), const SizedBox(height: 12)],
          if (m == null) _muted(context, "Couldn't load the money figures.")
          else ...[
            IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: _Num('Cash now', moneyShort(m.cash), m.openingUnset > 0 ? 'Opening balances not set' : '${m.accounts} accounts', warn: m.openingUnset > 0)),
              const SizedBox(width: 10),
              Expanded(child: _Num('Sales this month', moneyShort(m.sales), change == null ? 'Nothing to compare yet' : '${change >= 0 ? '+' : ''}$change% vs same days in ${monthShort(m.prevMonth)}')),
            ])),
            const SizedBox(height: 10),
            IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(child: _Num('Customers owe us', moneyShort(m.owedToUs), board.overdueTotal > 0 ? '${moneyShort(board.overdueTotal)} overdue' : 'None overdue', warn: board.overdueTotal > 0)),
              const SizedBox(width: 10),
              Expanded(child: _Num('We owe suppliers', moneyShort(m.weOwe), '${m.supplierCount} suppliers')),
            ])),
          ],
          const SizedBox(height: 12),
          _Block(title: 'Production', note: 'this month', children: f == null ? [_muted(context, "Couldn't load this part.")] : [
            _Line('Cement bags today', commas(f.bagsToday)),
            _Line('Cement bags this month', commas(f.bagsMonth)),
            _Line('Pieces curing', f.ready > 0 ? '${commas(f.curing)} · ${f.ready} ready' : commas(f.curing)),
            _Line('Batches outside the yield band', '${f.flags}', warn: f.flags > 0),
            _Line('Pieces rejected', commas(f.rejected), warn: f.rejected > 0),
          ]),
          const SizedBox(height: 12),
          _Block(title: 'Stock at risk', note: "only what's low", children: board.risk == null ? [_muted(context, "Couldn't load this part.")]
            : board.risk!.isEmpty ? [_muted(context, 'Nothing is low.')] : [
              for (final r in board.risk!.take(_show)) _Line(r.name, r.note, warn: r.warn),
              if (board.risk!.length > _show) Padding(padding: const EdgeInsets.only(top: 6), child: _muted(context, '${board.risk!.length - _show} more')),
            ]),
          if (m != null) ...[
            const SizedBox(height: 12),
            _Block(title: 'Sales vs money paid out', note: 'last 6 months', children: [_Trend(months: m.trend)]),
          ],
          const SizedBox(height: 12),
          _Block(title: 'Top overdue customers', note: 'days late', children: board.overdue.isEmpty ? [_muted(context, 'Nobody is overdue.')] : [
            for (final o in board.overdue.take(_show)) _Line('${o.name} · ${moneyShort(o.amount)}', '${o.days}', warn: o.days > 30),
          ]),
          if (place == 'All branches' && m != null && m.branches.length > 1) ...[
            const SizedBox(height: 12),
            _Block(title: 'Branches', note: 'this month', children: [
              for (final b in m.branches) _Line(b.name, 'Sales ${moneyShort(b.sales)} · cash ${moneyShort(b.cash)}'),
            ]),
          ],
          const SizedBox(height: 10),
          Text("$place · $today. Days left are an estimate from the last 14 days' use. Sales include VAT.", style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        ],
      ),
    );
  }
}

Widget _muted(BuildContext c, String t) => Text(t, style: TextStyle(fontSize: 13, color: Theme.of(c).hintColor));

BoxDecoration _card(BuildContext c, {Color? border}) => BoxDecoration(
      color: Theme.of(c).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: border ?? Theme.of(c).dividerColor),
    );

class _NeedsBlock extends StatelessWidget {
  const _NeedsBlock({required this.needs});
  final List<Need> needs;
  @override
  Widget build(BuildContext context) {
    final total = needs.fold(0, (t, x) => t + x.count);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _card(context, border: Theme.of(context).colorScheme.primary),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          const Expanded(child: Text('Needs you now', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
          _muted(context, '$total items'),
        ]),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, c) => Wrap(runSpacing: 10, children: [
          for (final x in needs)
            SizedBox(
              width: c.maxWidth / 2,
              child: Row(children: [
                Text('${x.count}', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: x.warn ? Theme.of(context).colorScheme.error : null)),
                const SizedBox(width: 8),
                Expanded(child: Text(x.label, style: const TextStyle(fontSize: 13, height: 1.2))),
              ]),
            ),
        ])),
      ]),
    );
  }
}

class _Num extends StatelessWidget {
  const _Num(this.label, this.figure, this.note, {this.warn = false});
  final String label, figure, note;
  final bool warn;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        constraints: const BoxConstraints(minHeight: 94),
        decoration: _card(context),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          const SizedBox(height: 2),
          FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(figure, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w600))),
          const SizedBox(height: 2),
          Text(note, style: TextStyle(fontSize: 12, color: warn ? Theme.of(context).colorScheme.error : Theme.of(context).hintColor)),
        ]),
      );
}

class _Block extends StatelessWidget {
  const _Block({required this.title, required this.note, required this.children});
  final String title, note;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: _card(context),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Expanded(child: Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14))),
            _muted(context, note),
          ]),
          const SizedBox(height: 6),
          ...children,
        ]),
      );
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.warn = false});
  final String label, value;
  final bool warn;
  @override
  Widget build(BuildContext context) => Container(
        constraints: const BoxConstraints(minHeight: 38),
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
          const SizedBox(width: 10),
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 190), child: Text(value, textAlign: TextAlign.right, style: TextStyle(fontSize: 14, color: warn ? Theme.of(context).colorScheme.error : Theme.of(context).hintColor))),
        ]),
      );
}

class _Trend extends StatelessWidget {
  const _Trend({required this.months});
  final List<TrendMonth> months;
  @override
  Widget build(BuildContext context) {
    final top = months.fold(1.0, (t, x) => [t, x.sales, x.costs].reduce((a, b) => a > b ? a : b));
    Widget key(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 5),
          _muted(context, t),
        ]);
    Widget bar(Color c, double v, double h) => Container(
          width: 12,
          height: (v / top * h).clamp(1, h),
          decoration: BoxDecoration(color: c, borderRadius: const BorderRadius.vertical(top: Radius.circular(4))),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 14, children: [key(_salesColor, 'Sales'), key(_costsColor, 'Paid out')]),
      const SizedBox(height: 10),
      Semantics(
        label: months.map((x) => '${monthShort(x.month)}: sales ${commas(x.sales)}, paid out ${commas(x.costs)}').join('; '),
        child: Row(children: [
          for (final x in months)
            Expanded(
              child: Tooltip(
                message: '${monthShort(x.month)}\nSales: ${commas(x.sales)}\nPaid out: ${commas(x.costs)}',
                triggerMode: TooltipTriggerMode.tap,
                child: Column(children: [
                  SizedBox(
                    height: 110,
                    child: Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                      bar(_salesColor, x.sales, 110),
                      const SizedBox(width: 2),
                      bar(_costsColor, x.costs, 110),
                    ]),
                  ),
                  const SizedBox(height: 4),
                  _muted(context, monthShort(x.month)),
                ]),
              ),
            ),
        ]),
      ),
    ]);
  }
}
