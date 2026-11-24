import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/format.dart';
import '../core/pdf_doc.dart';
import '../core/session.dart';

/*
 * Purchasing documents — ports of web pages/GoodsReceivedDocument.jsx (GRN-xxxxxxxx: what came into
 * the store on one receipt, signature lines for the storekeeper and driver/supplier) and
 * PurchaseOrderDocument.jsx (PO #n for the supplier). Read as saved (PRD 4.12).
 */
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
const _note = PdfColor.fromInt(0xFF444444);

Future<Uint8List> grnPdf(String movementId) async {
  final mv = await db.from('inventory_movements').select('*').eq('id', movementId).maybeSingle();
  if (mv == null) throw "We couldn't find this receipt.";
  final r = await Future.wait<dynamic>([
    db.from('organizations').select('*').eq('id', mv['organization_id']).maybeSingle(),
    db.from('branches').select('name').eq('id', mv['branch_id']).maybeSingle(),
    db.from('warehouses').select('name').eq('id', mv['warehouse_id']).maybeSingle(),
    db.from('inventory_transactions').select('id, material_id, product_id, entered_quantity, entered_unit_id, quantity, stock_unit_id')
        .eq('movement_id', movementId).eq('transaction_type', 'receipt').order('created_at', ascending: true),
    db.from('purchases').select('id, supplier_id, invoice_reference, purchase_date, status, purchase_order_id').eq('movement_id', movementId).neq('status', 'void').maybeSingle(),
    mv['created_by'] != null ? db.from('profiles').select('first_name, last_name').eq('id', mv['created_by']).maybeSingle() : Future.value(null),
  ]);
  final org = r[0] as Json?, purchase = r[4] as Json?, by = r[5] as Json?;
  final supplierId = purchase?['supplier_id'] ?? mv['supplier_id'];
  final r2 = await Future.wait<dynamic>([
    supplierId != null ? db.from('suppliers').select('name').eq('id', supplierId).maybeSingle() : Future.value(null),
    purchase?['purchase_order_id'] != null ? db.from('purchase_orders').select('po_no').eq('id', purchase!['purchase_order_id']).maybeSingle() : Future.value(null),
    db.from('materials').select('id, name, code'),
    db.from('units').select('id, symbol'),
  ]);
  final supplier = (r2[0] as Json?)?['name'];
  final po = (r2[1] as Json?)?['po_no'];
  final mat = {for (final m in r2[2] as List) '${m['id']}': '${m['name']}'};
  final unit = {for (final u in r2[3] as List) '${u['id']}': '${u['symbol']}'};
  final tx = _l(r[3]);
  final byName = by == null ? null : [by['first_name'], by['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ');
  final number = 'GRN-${'${mv['id']}'.substring(0, 8).toUpperCase()}';
  return docPdf(
    title: 'Goods received note $number',
    org: org,
    foot: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      docSign(['Received by${byName != null && byName.isNotEmpty ? ': $byName' : ''}', 'Delivered by (driver / supplier)', 'Date']),
      pw.SizedBox(height: 4),
      pw.Text('${org?['legal_name'] ?? org?['name'] ?? ''} · prepared with MOIS', style: docStyle(size: 9.5, color: const PdfColor.fromInt(0xFF999999))),
    ]),
    body: [
      docHead(
        org: org, logo: await docLogo(org), title: 'Goods received note',
        coLines: ['${org?['address'] ?? ''}', [if (org?['tin'] != null) 'TIN ${org!['tin']}', if ((r[1] as Json?)?['name'] != null) '${(r[1] as Json)['name']}'].join(' · ')],
        right: [number, 'Date: ${dateText(mv['movement_date']) ?? '—'}'],
      ),
      docTo('From', [
        pw.Text('${supplier ?? 'Supplier not recorded'}', style: docStyle(bold: true)),
        pw.Text(purchase != null
            ? (() {
                final s = [if ('${purchase['invoice_reference'] ?? ''}'.isNotEmpty) 'Invoice / delivery note ${purchase['invoice_reference']}', if (po != null) 'PO #$po'].join(' · ');
                return s.isEmpty ? 'Purchase recorded' : s;
              })()
            : 'Purchase details to follow'),
        pw.Text('Received into: ${(r[2] as Json?)?['name'] ?? '—'}${'${mv['reference'] ?? ''}'.isNotEmpty ? ' · ref ${mv['reference']}' : ''}'),
      ]),
      tx.isEmpty
          ? docTable(['#', 'Material', 'Quantity received'], [['', 'Nothing on this receipt.', '']], num: {2})
          : docTable(['#', 'Material', 'Quantity received'], [
              for (final (i, t) in tx.indexed)
                ['${i + 1}', mat['${t['material_id']}'] ?? '—', '${qtyText(n(t['entered_quantity'] ?? t['quantity']))} ${unit['${t['entered_unit_id'] ?? t['stock_unit_id']}'] ?? ''}'],
            ], num: {2}, widths: {0: const pw.FixedColumnWidth(28), 2: const pw.IntrinsicColumnWidth()}),
      if ('${mv['notes'] ?? ''}'.isNotEmpty) pw.Text('${mv['notes']}'),
    ],
  );
}

Future<Uint8List> poPdf(String id) async {
  final po = await db.from('purchase_orders').select('*, lines:purchase_order_lines(*)').eq('id', id).maybeSingle();
  if (po == null) throw "We couldn't find this purchase order.";
  final lines = _l(po['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no'])));
  final r = await Future.wait<dynamic>([
    db.from('organizations').select('*').eq('id', po['organization_id']).maybeSingle(),
    db.from('branches').select('*').eq('id', po['branch_id']).maybeSingle(),
    db.from('suppliers').select('*').eq('id', po['supplier_id']).maybeSingle(),
    db.from('materials').select('id, name').inFilter('id', [for (final l in lines) if (l['material_id'] != null) l['material_id']]),
    db.from('units').select('id, symbol'),
  ]);
  final org = r[0] as Json?, branch = r[1] as Json?, supplier = r[2] as Json?;
  final mat = {for (final m in r[3] as List) '${m['id']}': '${m['name']}'};
  final unit = {for (final u in r[4] as List) '${u['id']}': '${u['symbol']}'};
  String money(Object? v) => docMoney(v, org);
  final priced = lines.any((l) => l['unit_price'] != null || l['amount'] != null);
  double? amountOf(Json l) => l['kind'] == 'expense'
      ? (l['amount'] != null ? n(l['amount']).toDouble() : null)
      : l['unit_price'] != null ? n(l['unit_price']) * n(l['quantity']).toDouble() : null;
  final total = lines.fold<double>(0, (t, l) => t + (amountOf(l) ?? 0));
  return docPdf(title: 'Purchase order PO #${po['po_no']}', org: org, body: [
    docHead(
      org: org, logo: await docLogo(org), title: 'Purchase order', number: 'PO #${po['po_no']}',
      coLines: [
        '${org?['address'] ?? ''}',
        [org?['phone'], org?['email']].where((x) => x != null && '$x'.isNotEmpty).join(' · '),
        [if (org?['tin'] != null) 'TIN ${org!['tin']}', if (org?['vrn'] != null) 'VRN ${org!['vrn']}'].join(' · '),
        if (branch != null) 'Deliver to: ${branch['name']}${'${branch['location'] ?? ''}'.isNotEmpty ? ' — ${branch['location']}' : ''}',
      ],
      right: ['Date: ${dateText(po['order_date']) ?? '—'}', if (po['expected_on'] != null) 'Expected by: ${dateText(po['expected_on'])}'],
    ),
    docTo('Supplier', [
      pw.Text('${supplier?['name'] ?? ''}', style: docStyle(bold: true)),
      if ('${supplier?['address'] ?? ''}'.isNotEmpty) pw.Text('${supplier!['address']}'),
      pw.Text([supplier?['contact_person'], supplier?['phone'], if (supplier?['tax_id'] != null) 'TIN ${supplier!['tax_id']}'].where((x) => x != null && '$x'.isNotEmpty).join(' · ')),
    ]),
    docTable(['#', 'Item', 'Quantity', if (priced) 'Price', if (priced) 'Amount'], [
      for (final l in lines)
        [
          '${l['line_no']}',
          l['kind'] == 'expense' ? '${l['description'] ?? ''}' : mat['${l['material_id']}'] ?? '—',
          l['quantity'] != null ? '${qtyText(n(l['quantity']))} ${l['kind'] == 'expense' ? l['unit_text'] ?? '' : unit['${l['unit_id']}'] ?? ''}' : '',
          if (priced) l['unit_price'] != null ? money(l['unit_price']) : '',
          if (priced) amountOf(l) != null ? money(amountOf(l)) : '—',
        ],
    ], num: {2, 3, 4}, widths: {0: const pw.FixedColumnWidth(28), 1: const pw.FlexColumnWidth(3), 2: const pw.IntrinsicColumnWidth(), if (priced) 3: const pw.IntrinsicColumnWidth(), if (priced) 4: const pw.IntrinsicColumnWidth()}),
    if (priced) docTotals([('Total', money(total), grand: true, bold: true)]),
    if ('${po['notes'] ?? ''}'.isNotEmpty) pw.Text('${po['notes']}', style: docStyle(color: _note)),
    docSign(['Ordered by', 'Approved by', "Supplier's acceptance"]),
  ]);
}
