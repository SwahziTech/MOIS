import 'dart:typed_data';

import 'package:pdf/widgets.dart' as pw;

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/pdf_doc.dart';
import '../core/session.dart';

/*
 * Printed lists — a port of web pages/ListDocument.jsx (Document Center › Print lists):
 *   stock       products by colour and materials on hand now (with a Counted column)
 *   prices      selling prices with VAT (per m² or per piece, as the product is sold)
 *   attendance  who worked each day (up to 62 days) — landscape, a column a day
 *   purchases   each purchase: supplier, invoice, total, paid, to pay
 * Read as saved; nothing is changed.
 */
const listTitles = {'stock': 'Stock list', 'prices': 'Price list', 'attendance': 'Attendance sheet', 'purchases': 'Purchase record'};
String _q(num v) => qtyText((v * 100).roundToDouble() / 100);
String _amt(Object? v) => formatAmount(n(v).roundToDouble());

List<String> _days(String from, String to) {
  final out = <String>[];
  for (var d = DateTime.parse('${from}T00:00:00Z'); !d.isAfter(DateTime.parse('${to}T00:00:00Z')) && out.length < 62; d = d.add(const Duration(days: 1))) {
    out.add(iso(d));
  }
  return out;
}

Future<Uint8List> listPdf(String kind, String branchId, {String? from, String? to}) async {
  final today = session.today;
  from ??= '${today.substring(0, 7)}-01';
  to ??= today;
  final r = await Future.wait<dynamic>([
    db.from('organizations').select('*').eq('id', session.organization!['id']).maybeSingle(),
    db.from('branches').select('name').eq('id', branchId).maybeSingle(),
  ]);
  final org = (r[0] as Json?) ?? session.organization;
  final branch = '${(r[1] as Json?)?['name'] ?? ''}';
  final dated = kind == 'attendance' || kind == 'purchases';
  final body = <pw.Widget>[
    docHead(org: org, logo: await docLogo(org), title: listTitles[kind]!, coLines: [branch],
        right: [dated ? '${dateText(from)} to ${dateText(to)}' : 'As of ${dateText(today)}']),
  ];

  switch (kind) {
    case 'stock':
      final refs = await Refs.load();
      final bal = await db.from('stock_balances').select('product_id, material_id, color_id, quantity').eq('branch_id', branchId);
      final sum = <String, double>{};
      for (final b in bal) {
        final k = b['material_id'] != null ? 'm:${b['material_id']}' : 'p:${b['product_id']}|${b['color_id'] ?? ''}';
        sum[k] = (sum[k] ?? 0) + n(b['quantity']);
      }
      final prod = <String, List<({String name, double qty, String unit})>>{};
      final mats = <({Item it, String name, double qty, String unit})>[];
      for (final e in sum.entries) {
        if (e.value.abs() < 1e-9) continue;
        if (e.key.startsWith('m:')) {
          final it = refs.items[e.key];
          if (it == null) continue;
          final mu = mainUnitOf(it);
          mats.add((it: it, name: it.name, qty: mu != null ? e.value / mu.factor : e.value, unit: refs.unit(mu?.id ?? it.stockUnitId)));
        } else {
          final parts = e.key.split('|');
          final it = refs.items[parts[0]];
          if (it == null) continue;
          final colour = parts[1].isNotEmpty ? refs.colour(parts[1]) : '';
          (prod[it.category ?? 'Products'] ??= []).add((name: '${it.name}${colour.isNotEmpty ? ' — $colour' : ''}', qty: e.value, unit: refs.unit(it.stockUnitId)));
        }
      }
      final groups = [
        for (final g in (prod.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
          (title: g.key, rows: [for (final x in g.value..sort((a, b) => a.name.compareTo(b.name))) (x.name, '${_q(x.qty)} ${x.unit}')]),
        if (mats.isNotEmpty) (title: 'Materials', rows: [for (final x in mats..sort((a, b) => byMaterialOrder(a.it, b.it))) (x.name, '${_q(x.qty)} ${x.unit}')]),
      ];
      for (final g in groups) {
        body.add(pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          docLabel(g.title),
          docTable(['#', 'Item', 'On hand', 'Counted'], [for (final (i, x) in g.rows.indexed) ['${i + 1}', x.$1, x.$2, '']],
              num: {2, 3}, widths: {0: const pw.FixedColumnWidth(28), 1: const pw.FlexColumnWidth(3), 2: const pw.IntrinsicColumnWidth(), 3: const pw.FixedColumnWidth(80)}),
        ]));
      }
    case 'prices':
      final res = await Future.wait<dynamic>([
        db.from('product_branch_pricing').select('product_id, color_id, is_available, price_per_unit_inclusive, price_per_sqm_inclusive, vat_rate').eq('branch_id', branchId).isFilter('color_id', null).eq('is_available', true),
        db.from('products').select('id, canonical_name, status, unit:units(symbol), category:product_categories(name, sort_order)'),
      ]);
      final byId = {for (final p in res[1] as List) '${p['id']}': p};
      final g = <String, ({num order, List<(String, Object?, String, String)> rows})>{};
      for (final x in res[0] as List) {
        final p = byId['${x['product_id']}'];
        if (p == null || p['status'] != 'active') continue;
        final sqm = x['price_per_sqm_inclusive'] != null;
        final price = sqm ? x['price_per_sqm_inclusive'] : x['price_per_unit_inclusive'];
        if (price == null) continue;
        final cat = '${p['category']?['name'] ?? 'Products'}';
        (g[cat] ??= (order: n(p['category']?['sort_order'] ?? 999), rows: [])).rows.add((
          '${p['canonical_name']}', price,
          sqm ? 'm²' : ('${p['unit']?['symbol'] ?? ''}'.toUpperCase() == 'SQM' ? 'm²' : 'piece'),
          x['vat_rate'] != null && n(x['vat_rate']) == 0 ? 'no VAT' : 'incl.',
        ));
      }
      for (final e in (g.entries.toList()..sort((a, b) => a.value.order.compareTo(b.value.order)))) {
        body.add(pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          docLabel(e.key),
          docTable(['Product', 'Price (TZS)', 'Per', 'VAT'], [for (final x in e.value.rows..sort((a, b) => a.$1.compareTo(b.$1))) [x.$1, _amt(x.$2), x.$3, x.$4]],
              num: {1}, widths: {0: const pw.FlexColumnWidth(3), 1: const pw.IntrinsicColumnWidth(), 2: const pw.IntrinsicColumnWidth(), 3: const pw.IntrinsicColumnWidth()}),
        ]));
      }
      body.add(pw.Text('Prices include VAT where shown. Some colours cost more — ask for the colour price.'));
    case 'attendance':
      final res = await Future.wait<dynamic>([
        db.from('staff_attendance').select('staff_id, work_date, day_fraction').eq('branch_id', branchId).gte('work_date', from).lte('work_date', to),
        db.from('staff').select('id, full_name'),
      ]);
      final all = _days(from, to);
      final name = {for (final s in res[1] as List) '${s['id']}': '${s['full_name']}'};
      final m = <String, ({String name, Map<String, double> at, List<double> total})>{};
      for (final a in res[0] as List) {
        final p = m['${a['staff_id']}'] ??= (name: name['${a['staff_id']}'] ?? '—', at: {}, total: [0]);
        final f = n(a['day_fraction'] ?? 1).toDouble();
        p.at['${a['work_date']}'] = (p.at['${a['work_date']}'] ?? 0) + f;
        p.total[0] += f;
      }
      final people = m.values.toList()..sort((a, b) => a.name.compareTo(b.name));
      String mark(double? v) => v == null ? '' : v == 1 ? '✓' : v == 0.5 ? '½' : _q(v);
      body.add(docTable(
        ['Name', for (final d in all) '${int.parse(d.substring(8))}', 'Days'],
        [for (final p in people) [p.name, for (final d in all) mark(p.at[d]), _q(p.total[0])]],
        num: {for (var i = 1; i <= all.length + 1; i++) i},
        widths: {0: const pw.FlexColumnWidth(3)},
      ));
      if (people.isEmpty) body.add(pw.Text('Nobody recorded as working in this period.'));
      if (all.length >= 62 && all.last.compareTo(to) < 0) body.add(pw.Text('Only the first 62 days are shown.'));
    case 'purchases':
      final res = await Future.wait<dynamic>([
        db.from('purchases').select('id, purchase_date, supplier_id, invoice_reference, status').eq('branch_id', branchId).neq('status', 'void').gte('purchase_date', from).lte('purchase_date', to).order('purchase_date', ascending: false),
        db.from('suppliers').select('id, name'),
      ]);
      final ids = [for (final p in res[0] as List) p['id']];
      final tot = ids.isEmpty ? <dynamic>[] : await db.from('purchase_totals').select('purchase_id, total, amount_paid, balance').inFilter('purchase_id', ids);
      final t = {for (final x in tot) '${x['purchase_id']}': x};
      final sup = {for (final s in res[1] as List) '${s['id']}': '${s['name']}'};
      final rows = [
        for (final p in res[0] as List)
          (date: '${p['purchase_date']}', supplier: sup['${p['supplier_id']}'] ?? '—', ref: '${p['invoice_reference'] ?? ''}',
              total: n(t['${p['id']}']?['total']).toDouble(), paid: n(t['${p['id']}']?['amount_paid']).toDouble(), balance: n(t['${p['id']}']?['balance']).toDouble()),
      ];
      body.add(docTable(
        ['Date', 'Supplier', 'Invoice', 'Total (TZS)', 'Paid (TZS)', 'To pay (TZS)'],
        [for (final x in rows) [tableDate(x.date) ?? '', x.supplier, x.ref, _amt(x.total), _amt(x.paid), x.balance > 0 ? _amt(x.balance) : '']],
        num: {3, 4, 5},
        foot: ['Total (${rows.length})', '', '', _amt(rows.fold<double>(0, (s, x) => s + x.total)), _amt(rows.fold<double>(0, (s, x) => s + x.paid)),
          'Tsh ${_amt(rows.fold<double>(0, (s, x) => s + (x.balance > 0 ? x.balance : 0)))}'],
      ));
      if (rows.isEmpty) body.add(pw.Text('No purchases in this period.'));
  }

  return docPdf(
    title: '${listTitles[kind]} $branch',
    org: org,
    landscape: kind == 'attendance',
    fontSize: kind == 'attendance' ? 9 : 12,
    body: body,
    foot: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      docSign(['Prepared by', 'Checked by', 'Date']),
      pw.SizedBox(height: 4),
      pw.Text('${org?['legal_name'] ?? org?['name'] ?? ''} · prepared with MOIS', style: docStyle(size: 9.5)),
    ]),
  );
}
