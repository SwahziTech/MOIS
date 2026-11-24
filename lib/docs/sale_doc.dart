import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/format.dart';
import '../core/pdf_doc.dart';
import '../core/session.dart';

/*
 * A sale's documents — a port of web pages/SaleDocument.jsx: doc = quotation | proforma | invoice |
 * receipt (paymentId) | delivery (deliveryId). Every figure is read as saved — nothing is worked out
 * here (PRD 4.12). Company details from Settings → Company details for documents (066).
 */
const _methods = {'cash': 'Cash', 'mobile_money': 'Mobile money', 'bank': 'Bank'};
double _r2(num v) => (v * 100).roundToDouble() / 100;
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];

String saleDocTitle(String doc, bool hasVat) =>
    {'quotation': 'Quotation', 'proforma': 'Proforma invoice', 'invoice': hasVat ? 'Tax invoice' : 'Invoice', 'receipt': 'Payment receipt', 'delivery': 'Delivery note'}[doc] ?? 'Invoice';

Future<Uint8List> saleDocPdf(String saleId, String doc, {String? paymentId, String? deliveryId}) async {
  final sale = await db.from('sales').select('*, lines:sale_lines(*), payments:sale_payments(*), deliveries:sale_deliveries(*, lines:sale_delivery_lines(*))').eq('id', saleId).maybeSingle();
  if (sale == null) throw "We couldn't find this sale.";
  final ids = {for (final l in sale['lines'] as List) if (l['product_id'] != null) '${l['product_id']}'}.toList();   // other items (104) have none
  final r = await Future.wait<dynamic>([
    db.from('organizations').select('*').eq('id', sale['organization_id']).maybeSingle(),
    db.from('branches').select('*').eq('id', sale['branch_id']).maybeSingle(),
    sale['customer_id'] != null ? db.from('customers').select('*').eq('id', sale['customer_id']).maybeSingle() : Future.value(null),
    db.from('products').select('id, canonical_name, unit:units(symbol)').inFilter('id', ids),
    db.from('color_palette').select('id, name'),
    db.from('payment_accounts').select('id, name').eq('branch_id', sale['branch_id']),   // 067
  ]);
  final org = r[0] as Json?, branch = r[1] as Json?, customer = r[2] as Json?;
  final product = {for (final p in r[3] as List) '${p['id']}': p};
  final colour = {for (final c in r[4] as List) '${c['id']}': '${c['name']}'};
  final account = {for (final a in r[5] as List) '${a['id']}': '${a['name']}'};
  String money(Object? v) => docMoney(v, org);
  String nameOf(Json l) => l['product_id'] != null
      ? '${product['${l['product_id']}']?['canonical_name'] ?? '—'}${l['color_id'] != null ? ' ${colour['${l['color_id']}'] ?? ''}' : ''}'
      : '${l['item_name'] ?? '—'}';
  String per(Json l) => l['product_id'] == null ? '' : '${product['${l['product_id']}']?['unit']?['symbol'] ?? ''}'.toUpperCase() == 'SQM' ? 'm²' : 'pcs';
  final lines = _l(sale['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no'])));
  final payments = _l(sale['payments']);
  final paid = payments.fold<double>(0, (t, p) => t + n(p['amount']));
  final payment = payments.where((p) => p['id'] == paymentId).firstOrNull;
  final delivery = _l(sale['deliveries']).where((x) => x['id'] == deliveryId).firstOrNull;
  if ((doc == 'receipt' && payment == null) || (doc == 'delivery' && delivery == null)) throw "That $doc isn't on this sale.";
  final buyer = customer ?? {'name': '${sale['walk_in_name'] ?? ''}'.isEmpty ? 'Walk-in customer' : sale['walk_in_name'], 'phone': sale['walk_in_phone']};
  final hasVat = n(sale['vat']) > 0;
  final title = saleDocTitle(doc, hasVat);
  final upTo = payment == null ? <Json>[] : payments.where((p) => '${p['created_at']}'.compareTo('${payment['created_at']}') <= 0).toList();
  final number = doc == 'receipt' ? 'R-${sale['sale_no']}-${upTo.length}' : doc == 'delivery' ? 'DN-${delivery?['delivery_no'] ?? '—'}' : '#${sale['sale_no']}';
  final date = doc == 'receipt' ? payment!['paid_on'] : doc == 'delivery' ? delivery!['delivered_on'] : doc == 'invoice' ? (sale['invoiced_on'] ?? sale['sale_date']) : sale['sale_date'];
  final stageWord = sale['stage'] == 'invoice' ? 'invoice' : 'order';

  final body = <pw.Widget>[
    docHead(org: org, branch: branch, logo: await docLogo(org), title: title, number: number, right: [
      'Date: ${dateText(date) ?? '—'}',
      if (doc == 'quotation' && sale['valid_until'] != null) 'Valid until: ${dateText(sale['valid_until'])}',
      if ((doc == 'invoice' || doc == 'receipt') && sale['efd_receipt_no'] != null) 'EFD receipt: ${sale['efd_receipt_no']}',
      if (doc == 'receipt' && payment!['receipt_no'] != null) 'Receipt book no.: ${payment['receipt_no']}',
      if (doc == 'receipt' || doc == 'delivery') 'For $stageWord #${sale['sale_no']}',
    ]),
    docTo(doc == 'delivery' ? 'Deliver to' : doc == 'receipt' ? 'Received from' : 'Bill to', [
      pw.Text('${buyer['name']}', style: docStyle(bold: true)),
      if ('${buyer['address'] ?? ''}'.isNotEmpty) pw.Text('${buyer['address']}'),
      if ([buyer['phone'], buyer['tin'], buyer['vrn']].any((x) => x != null && '$x'.isNotEmpty))
        pw.Text([if ('${buyer['phone'] ?? ''}'.isNotEmpty) buyer['phone'], if (buyer['tin'] != null) 'TIN ${buyer['tin']}', if (buyer['vrn'] != null) 'VRN ${buyer['vrn']}'].join(' · ')),
      if ('${sale['site'] ?? ''}'.isNotEmpty) pw.Text('Site: ${sale['site']}'),
    ]),
  ];

  if (doc == 'receipt') {
    final upToPaid = upTo.fold<double>(0, (t, p) => t + n(p['amount']));
    body.addAll([
      pw.RichText(text: pw.TextSpan(children: [
        const pw.TextSpan(text: 'Received with thanks the sum of '),
        pw.TextSpan(text: money(payment!['amount']), style: docStyle(bold: true)),
        pw.TextSpan(text: ' into ${account['${payment['account_id']}'] ?? _methods[payment['method']] ?? ''}${'${payment['reference'] ?? ''}'.isNotEmpty ? ' (ref. ${payment['reference']})' : ''}.'),
      ])),
      docTotals([
        ('Total of $stageWord #${sale['sale_no']}', money(sale['total']), grand: false, bold: false),
        ('Paid up to and including this receipt', money(_r2(upToPaid)), grand: false, bold: false),
        ('Balance', money(_r2(n(sale['total']) - upToPaid)), grand: false, bold: true),
      ]),
    ]);
  } else if (doc == 'delivery') {
    final d = delivery!;
    body.addAll([
      docTable(['#', 'Product', 'Quantity'], [
        for (final (i, x) in _l(d['lines']).indexed)
          () {
            final l = lines.where((y) => y['id'] == x['sale_line_id']).firstOrNull;
            return ['${i + 1}', l != null ? nameOf(l) : '—', '${qtyText(n(x['quantity']))} ${l != null ? per(l) : ''}'];
          }(),
      ], num: {2}, widths: {0: const pw.FixedColumnWidth(28), 2: const pw.IntrinsicColumnWidth()}),
      pw.Text('${d['kind'] == 'collection' ? 'Collected by the customer' : 'Delivery'}${'${sale['site'] ?? ''}'.isNotEmpty ? ' · site: ${sale['site']}' : ''}'
          '${'${d['driver'] ?? ''}'.isNotEmpty ? ' · driver: ${d['driver']}' : ''}${'${d['vehicle'] ?? ''}'.isNotEmpty ? ' · vehicle: ${d['vehicle']}' : ''}'),
      // proof of delivery once confirmed (096)
      if (d['kind'] == 'delivery' && d['status'] == 'delivered' && d['pod_received_by'] != null)
        pw.RichText(text: pw.TextSpan(children: [
          pw.TextSpan(text: 'Delivered', style: docStyle(bold: true)),
          pw.TextSpan(text: ' — received by ${d['pod_received_by']}${d['delivered_at'] != null ? ', ${dateTimeText(d['delivered_at'])}' : ''}${'${d['pod_note'] ?? ''}'.isNotEmpty ? ' · ${d['pod_note']}' : ''}'),
        ])),
      docSign(['Issued by', 'Received by${'${d['received_by'] ?? ''}'.isNotEmpty ? ': ${d['received_by']}' : ''}', 'Date and time']),
    ]);
  } else {
    final balance = n(sale['total']) - paid;
    body.addAll([
      docTable(['#', 'Product', 'Quantity', 'Price', 'Amount'], [
        for (final l in lines)
          ['${l['line_no']}', nameOf(l), '${qtyText(n(l['quantity']))} ${per(l)}', money(_r2(n(l['total']) / n(l['quantity']))), money(l['total'])],
      ], num: {2, 3, 4}, widths: {0: const pw.FixedColumnWidth(28), 1: const pw.FlexColumnWidth(3), 2: const pw.IntrinsicColumnWidth(), 3: const pw.IntrinsicColumnWidth(), 4: const pw.IntrinsicColumnWidth()}),
      docTotals([
        if (hasVat) ('Amount without VAT', money(sale['subtotal']), grand: false, bold: false),
        if (hasVat) ('VAT', money(sale['vat']), grand: false, bold: false),
        ('Total${hasVat ? ' (incl. VAT)' : ''}', money(sale['total']), grand: true, bold: true),
        if (doc != 'quotation' && paid > 0) ('Paid', money(_r2(paid)), grand: false, bold: false),
        if (doc != 'quotation' && paid > 0) ('Balance', money(_r2(balance)), grand: false, bold: true),
      ]),
      if ((doc != 'invoice' || balance > 0) && '${org?['bank_details'] ?? ''}'.isNotEmpty)
        pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [docLabel('How to pay'), pw.Text('${org!['bank_details']}')]),
    ]);
  }
  if ('${sale['notes'] ?? ''}'.isNotEmpty && doc != 'receipt') body.add(pw.Text('${sale['notes']}', style: docStyle(color: const PdfColor.fromInt(0xFF444444))));
  return docPdf(title: '$title $number', body: body, org: org);
}
