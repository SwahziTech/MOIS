import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../core/format.dart';
import '../core/pdf_doc.dart';
import '../core/sales.dart' show jl;
import '../core/session.dart';

/*
 * What customers owe — a port of web lib/receivables.js — and the customer's statement of account (web
 * pages/StatementDocument.jsx, A4): balance brought forward, each order/invoice and payment with the running
 * balance, the balance due and how old it is. Orders and invoices only (never quotations or cancelled sales),
 * aged from the day the sale became owed. Read as saved.
 */
const ageBuckets = [(0, 30, '0–30 days'), (31, 60, '31–60 days'), (61, 90, '61–90 days'), (91, 1 << 30, 'Over 90 days')];
String owedSince(Json s) => '${s['ordered_on'] ?? s['invoiced_on'] ?? s['sale_date']}';
int _days(String a, String b) => DateTime.parse(b).difference(DateTime.parse(a)).inDays;

Future<List<Json>> loadOwing({String? customerId}) async {
  dynamic q = db.from('sales')
      .select('id, sale_no, branch_id, stage, customer_id, walk_in_name, walk_in_phone, sale_date, ordered_on, invoiced_on, total, efd_receipt_no, payments:sale_payments(id, paid_on, amount, receipt_no, method, created_at)')
      .inFilter('stage', ['order', 'invoice']);
  if (customerId != null) q = q.eq('customer_id', customerId);
  return jl(await q);
}

class Buyer {
  Buyer(this.key, this.customer, this.name, this.phone);
  final String key, name;
  final Json? customer;
  final String? phone;
  double owed = 0, total = 0, paid = 0;
  final List<double> buckets = [0, 0, 0, 0];
  String? oldest, lastPaid;
  int sales = 0;
}

/// per buyer: owed, by age, oldest unpaid day, last payment
List<Buyer> ageByBuyer(List<Json> sales, List<Json> customers, String today) {
  final byId = {for (final c in customers) '${c['id']}': c};
  final out = <String, Buyer>{};
  for (final s in sales) {
    final paid = jl(s['payments']).fold<double>(0, (t, p) => t + n(p['amount']));
    final bal = r2(n(s['total']) - paid);
    final cid = s['customer_id'] as String?;
    final key = cid ?? 'walkin:${'${s['walk_in_name'] ?? 'Walk-in'}'.trim().toLowerCase()}';
    final c = cid != null ? byId[cid] : null;
    final Object? phone = cid != null ? (c ?? const {})['phone'] : s['walk_in_phone'];
    final b = out.putIfAbsent(key, () => Buyer(key, c, cid != null ? '${c?['name'] ?? '—'}' : '${s['walk_in_name'] ?? 'Walk-in'}'.trim(), phone?.toString()));
    b.sales++;
    b.total += n(s['total']);
    b.paid += paid;
    for (final p in jl(s['payments'])) { if (b.lastPaid == null || '${p['paid_on']}'.compareTo(b.lastPaid!) > 0) b.lastPaid = '${p['paid_on']}'; }
    if (bal <= 0.004) continue;
    final since = owedSince(s);
    final age = _days(since, today);
    final i = ageBuckets.indexWhere((x) => age >= x.$1 && age <= x.$2);
    b.buckets[i < 0 ? 0 : i] += bal;
    b.owed += bal;
    if (b.oldest == null || since.compareTo(b.oldest!) < 0) b.oldest = since;
  }
  for (final b in out.values) {
    b.owed = r2(b.owed); b.total = r2(b.total); b.paid = r2(b.paid);
    for (var i = 0; i < 4; i++) { b.buckets[i] = r2(b.buckets[i]); }
  }
  return out.values.toList();
}

typedef Move = ({String date, String ref, double charge, double paid, double balance});

/// the balance brought forward, then each sale owed (a charge) and each payment, by date, with the running balance
({double opening, List<Move> rows, double closing, double charged, double paid}) statementLines(List<Json> sales, String? from, String? to) {
  final moves = <({String date, String ref, double charge, double paid, int order, String at})>[];
  for (final s in sales) {
    moves.add((date: owedSince(s), ref: '${s['stage'] == 'invoice' ? 'Invoice' : 'Order'} #${s['sale_no']}', charge: n(s['total']).toDouble(), paid: 0, order: 0, at: ''));
    for (final p in jl(s['payments'])) {
      moves.add((date: '${p['paid_on']}', ref: 'Payment — #${s['sale_no']}${p['receipt_no'] != null ? ' (receipt ${p['receipt_no']})' : ''}', charge: 0, paid: n(p['amount']).toDouble(), order: 1, at: '${p['created_at'] ?? ''}'));
    }
  }
  moves.sort((a, b) => a.date == b.date ? (a.order != b.order ? a.order - b.order : a.at.compareTo(b.at)) : a.date.compareTo(b.date));
  final opening = r2(moves.where((m) => from != null && m.date.compareTo(from) < 0).fold<double>(0, (t, m) => t + m.charge - m.paid));
  var bal = opening;
  final rows = <Move>[
    for (final m in moves.where((m) => (from == null || m.date.compareTo(from) >= 0) && (to == null || m.date.compareTo(to) <= 0)))
      () { bal = r2(bal + m.charge - m.paid); return (date: m.date, ref: m.ref, charge: m.charge, paid: m.paid, balance: bal); }(),
  ];
  return (opening: opening, rows: rows, closing: bal, charged: r2(rows.fold(0.0, (t, m) => t + m.charge)), paid: r2(rows.fold(0.0, (t, m) => t + m.paid)));
}

Future<Uint8List> statementPdf(String customerId, {String? from, String? to}) async {
  final customer = await db.from('customers').select('*').eq('id', customerId).maybeSingle();
  if (customer == null) throw "We couldn't find this customer.";
  final r = await Future.wait<dynamic>([
    db.from('organizations').select('*').eq('id', customer['organization_id']).maybeSingle(),
    loadOwing(customerId: customerId),
  ]);
  final org = r[0] as Json?;
  final sales = r[1] as List<Json>;
  final end = to ?? session.today;
  final st = statementLines(sales, from, end);
  final age = ageByBuyer(sales.where((s) => owedSince(s).compareTo(end) <= 0).toList(), [customer], end).firstOrNull;
  String money(num v) => docMoney(v, org);
  return docPdf(
    title: 'Statement ${customer['name']} ${tableDate(end) ?? ''}',
    org: org,
    foot: docFoot(org),
    body: [
      docHead(
        org: org, logo: await docLogo(org), title: 'Statement of account',
        coLines: ['${org?['address'] ?? ''}', [org?['phone'], org?['email']].where((x) => x != null).join(' · '), [if (org?['tin'] != null) 'TIN ${org!['tin']}', if (org?['vrn'] != null) 'VRN ${org!['vrn']}'].join(' · ')],
        right: ['Date: ${dateText(end) ?? ''}', 'Period: ${from != null ? '${dateText(from)} to ${dateText(end)}' : 'up to ${dateText(end)}'}'],
      ),
      docTo('Customer', [
        pw.Text('${customer['name']}', style: docStyle(bold: true)),
        if (customer['address'] != null) pw.Text('${customer['address']}'),
        pw.Text([customer['phone'], if (customer['tin'] != null) 'TIN ${customer['tin']}', if (customer['vrn'] != null) 'VRN ${customer['vrn']}'].where((x) => x != null).join(' · ')),
      ]),
      docTable(
        ['Date', 'Details', 'Charged', 'Paid', 'Balance'],
        [
          if (from != null) [tableDate(from) ?? '', 'Balance brought forward', '', '', formatAmount(st.opening)],
          if (st.rows.isEmpty) ['', 'Nothing in this period.', '', '', ''],
          for (final m in st.rows) [tableDate(m.date) ?? '', m.ref, m.charge != 0 ? formatAmount(m.charge) : '', m.paid != 0 ? formatAmount(m.paid) : '', formatAmount(m.balance)],
        ],
        num: {2, 3, 4},
      ),
      docTotals([
        if (from != null) ('Brought forward', money(st.opening), grand: false, bold: false),
        ('Charged in the period', money(st.charged), grand: false, bold: false),
        ('Paid in the period', money(st.paid), grand: false, bold: false),
        ('Balance due', money(st.closing), grand: true, bold: true),
      ]),
      if (age != null && age.owed > 0) ...[
        pw.SizedBox(height: 10),
        docTable([for (final b in ageBuckets) b.$3, 'Total due'], [[for (final v in age.buckets) v != 0 ? formatAmount(v) : '—', formatAmount(age.owed)]], num: {0, 1, 2, 3, 4}),
      ],
      if (st.closing > 0 && org?['bank_details'] != null) ...[
        pw.SizedBox(height: 10),
        docLabel('How to pay'),
        pw.Text('${org!['bank_details']}'),
      ],
    ],
  );
}
