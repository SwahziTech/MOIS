import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/pdf_doc.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../docs/list_doc.dart';

/*
 * Print lists (Document Center) — a port of web pages/PrintLists.jsx (approved 2026-11-24): A4 lists of
 * the branch in the menu, each opening as a PDF to print or share. Dated lists use the period bar.
 */
const _lists = [
  (kind: 'stock', label: 'Stock list', icon: LucideIcons.boxes, perm: 'inventory.view', dated: false,
      text: 'Every product (by colour) and material in the branch stores, with the quantity on hand — for a stock count or the notice board.'),
  (kind: 'prices', label: 'Price list', icon: LucideIcons.dollarSign, perm: 'products.view', dated: false,
      text: 'The branch’s selling prices with VAT, per piece or per m² as each product is sold — to hand to customers.'),
  (kind: 'attendance', label: 'Attendance sheet', icon: LucideIcons.calendarCheck, perm: 'staff.view', dated: true,
      text: 'Who worked each day of the period, person by person, with the days worked.'),
  (kind: 'purchases', label: 'Purchase record', icon: LucideIcons.shoppingCart, perm: 'procurement.view', dated: true,
      text: 'Every purchase in the period: supplier, invoice, total, paid and still to pay.'),
];

class PrintListsPage extends StatefulWidget {
  const PrintListsPage({super.key});
  @override
  State<PrintListsPage> createState() => _PrintListsPageState();
}

class _PrintListsPageState extends State<PrintListsPage> {
  final _rp = RangePeriod('print-lists');

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final branchId = session.branchId;
    final lists = _lists.where((l) => session.can(l.perm)).toList();
    return PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
      PlHelp(branchId.isNotEmpty ? (session.branchName ?? '') : 'Pick a branch in the menu'),
      const SizedBox(height: 8),
      const PlLabel('Period for dated lists'),
      const SizedBox(height: 4),
      _rp.bar(context, () => setState(() {})),
      const SizedBox(height: 12),
      if (lists.isEmpty) const PlHelp("Your role doesn't open any of these lists."),
      for (final l in lists)
        Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Icon(l.icon, size: 18), const SizedBox(width: 8), Text(l.label, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: Fs.md))]),
            const SizedBox(height: 6),
            PlHelp(l.text),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: PlHelp(l.dated ? '${dateText(_rp.from)} to ${dateText(_rp.to)}' : 'as of today')),
              FilledButton.icon(
                onPressed: branchId.isEmpty
                    ? null
                    : () => openDoc(context, '${l.label}${l.dated ? ' ${tableDate(_rp.from)} – ${tableDate(_rp.to)}' : ''}',
                        () => listPdf(l.kind, branchId, from: l.dated ? _rp.from : null, to: l.dated ? _rp.to : null)),
                icon: const Icon(LucideIcons.printer, size: 15),
                label: const Text('Open to print'),
              ),
            ]),
          ]),
        ),
    ]);
  }
}
