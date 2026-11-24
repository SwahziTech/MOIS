import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/pdf_doc.dart';
import '../core/session.dart';

/*
 * Production job card — a port of web pages/JobCardDocument.jsx (2026-11-20, "the uploaded format"): one batch
 * a card, A4. The company's details, the card's details (PJC-yyyymmdd-n, batch n of the day, made by: team name
 * + people count, no names), then three boxes — production costs (consumables, 138), the materials used
 * (quantity × cost a unit = total, oldest stock first, VAT included) and the products made (pieces × cost a piece).
 */
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
String _amt(num v) {
  final s = v.abs().toStringAsFixed(2).split('.');
  return '${v < 0 ? '-' : ''}${s[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',')}.${s[1]}';
}

Future<Uint8List> jobCardPdf(String batchId) async {
  final r0 = await Future.wait<dynamic>([
    db.from('production_batches').select('*, materials:production_batch_materials(*), outputs:production_batch_outputs(*)').eq('id', batchId).maybeSingle(),
    Refs.load(),
  ]);
  final b = r0[0] as Json?;
  if (b == null) throw "We couldn't find this batch.";
  final refs = r0[1] as Refs;
  final r = await Future.wait<dynamic>([
    db.from('production_batches').select('id').eq('branch_id', b['branch_id']).eq('batch_date', b['batch_date']).order('created_at', ascending: true),
    db.from('branches').select('name').eq('id', b['branch_id']).maybeSingle(),
    db.from('organizations').select('*').eq('id', b['organization_id']).maybeSingle(),
    b['team_id'] != null ? db.from('production_teams').select('name').eq('id', b['team_id']).maybeSingle() : Future.value(null),
    b['machine_id'] != null ? db.from('machines').select('name').eq('id', b['machine_id']).maybeSingle() : Future.value(null),
  ]);
  final ids = [for (final x in r[0] as List) '${x['id']}'];
  final nth = ids.indexOf(batchId) + 1, of = ids.length;
  final branch = (r[1] as Json?)?['name'];
  final org = r[2] as Json?;
  final team = (r[3] as Json?)?['name'];
  final people = (b['worker_ids'] as List? ?? []).length;
  final machine = (r[4] as Json?)?['name'];

  String name(Object? id) => refs.items['m:$id']?.name ?? '—';
  String prod(Json o) => '${refs.items['p:${o['product_id']}']?.name ?? '—'}${o['color_id'] != null ? ' ${refs.colour('${o['color_id']}')}' : ''}';
  // materials in material order; consumables (138) go in the costs box
  final mats = _l(b['materials']);
  final matRows = mats.where((m) => m['source'] != 'consumable' && n(m['quantity']) > 0).toList()
    ..sort((x, y) {
      final a = refs.items['m:${x['material_id']}'], c = refs.items['m:${y['material_id']}'];
      return a == null || c == null ? 0 : byMaterialOrder(a, c);
    });
  final costRows = mats.where((m) => m['source'] == 'consumable' && n(m['quantity']) > 0).toList();
  final prodRows = [
    for (final o in _l(b['outputs'])..sort((x, y) => (y['is_primary'] == true ? 1 : 0) - (x['is_primary'] == true ? 1 : 0)))
      (name: prod(o), pcs: n(o['pieces_cast']).toDouble(), each: o['cost_per_piece'] != null ? n(o['cost_per_piece']).toDouble() : null),
  ];
  double total(List<Json> rows) => rows.fold(0, (t, m) => t + (m['cost'] != null ? n(m['cost']) : 0));
  final prodTotal = prodRows.fold<double>(0, (t, p) => t + (p.each != null ? p.each! * p.pcs : 0));
  double? each(Json m) => m['cost'] != null && n(m['quantity']) > 0 ? n(m['cost']) / n(m['quantity']) : null;
  final date = '${b['batch_date']}';

  pw.Widget matTable(List<Json> rows) => docTable(
        ['Item', 'Unit', 'Qty', 'Unit cost', 'Total'],
        [
          for (final m in rows)
            [name(m['material_id']), refs.unit('${m['unit_id']}'), qtyText(n(m['quantity'])), each(m) != null ? _amt(each(m)!) : '—', m['cost'] != null ? _amt(n(m['cost'])) : '—'],
        ],
        num: {2, 3, 4},
        foot: rows.isEmpty ? null : ['', '', '', '', _amt(total(rows))],
      );
  pw.Widget box(String title, pw.Widget child) => pw.Padding(
        padding: const pw.EdgeInsets.only(top: 10),
        child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [pw.Text(title, style: docStyle(bold: true)), pw.SizedBox(height: 4), child]),
      );
  pw.Widget line(String label, String value) => pw.Padding(
        padding: const pw.EdgeInsets.only(bottom: 2),
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [pw.SizedBox(width: 90, child: docLabel(label)), pw.Expanded(child: pw.Text(value))]),
      );

  return docPdf(
    title: 'Job card PJC-${date.replaceAll('-', '')}-$nth',
    org: org,
    fontSize: 10.5,
    foot: docSign(['Recorded by', 'Checked by', 'Approved by']),
    body: [
      docHead(
        org: org, logo: await docLogo(org), title: 'Production job card',
        coLines: ['${org?['address'] ?? ''}', '${org?['phone'] ?? ''}', if (org?['email'] != null) 'Email: ${org!['email']}'],
        right: const [],
      ),
      pw.SizedBox(height: 8),
      pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        pw.Expanded(flex: 3, child: pw.Column(children: [
          line('Job card', 'PJC-${date.replaceAll('-', '')}-$nth'),
          line('Description', 'Production · ${branch ?? ''} · batch $nth of $of'),
          line('Batch', '${qtyText(n(b['cement_bags']))} bags of cement${b['status'] == 'void' ? ' · VOID' : ''}'),
          line('Made by', [if (team != null) '$team', if (people > 0) '$people ${people == 1 ? 'person' : 'people'}', if (machine != null) '$machine'].join(' · ').ifEmpty('—')),
          line('Currency', '${org?['currency_code'] ?? 'TZS'}'),
        ])),
        pw.SizedBox(width: 16),
        pw.Expanded(flex: 2, child: pw.Column(children: [
          line('Started', tableDate(date) ?? ''),
          line('Completed', b['released_on'] != null ? tableDate(b['released_on']) ?? '' : 'curing'),
          line('Date printed', dateText(session.today) ?? ''),
        ])),
      ]),
      box('Production costs', costRows.isNotEmpty ? matTable(costRows) : pw.Text('Consumables, electricity and labour come in through Costing.', style: docStyle(size: 10, color: const PdfColor.fromInt(0xFF777777)))),
      box('Production materials', matTable(matRows)),
      box('Production products', docTable(
        ['Product', 'Qty', 'Unit cost', 'Total'],
        [for (final p in prodRows) [p.name, qtyText(p.pcs), p.each != null ? _amt(p.each!) : '—', p.each != null ? _amt(p.each! * p.pcs) : '—']],
        num: {1, 2, 3},
        foot: ['', '', '', _amt(prodTotal)],
      )),
    ],
  );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
