import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/format.dart';
import '../core/pdf_doc.dart';
import '../core/session.dart';

/*
 * Payslips of a pay sheet — a port of web pages/PayslipDocument.jsx (088): one a page, earnings beside
 * deductions, then net pay. Read as saved — a draft prints marked DRAFT. lineId = one person only.
 */
const _cycle = {'weekly': 'Weekly', 'fortnightly': 'Every 2 weeks', 'monthly': 'Monthly'};

Future<Uint8List> payslipsPdf(String sheetId, {String? lineId}) async {
  final sheet = await db.from('pay_sheets').select('*').eq('id', sheetId).maybeSingle();
  if (sheet == null) throw "We couldn't find this pay sheet.";
  final r = await Future.wait<dynamic>([
    db.from('organizations').select('*').eq('id', sheet['organization_id']).maybeSingle(),
    db.from('branches').select('name').eq('id', sheet['branch_id']).maybeSingle(),
    db.from('pay_sheet_lines').select('*').eq('sheet_id', sheetId),
    db.from('staff').select('id, full_name, job_title, kind, nssf_no').eq('branch_id', sheet['branch_id']),
  ]);
  final org = r[0] as Json?;
  final branch = (r[1] as Json?)?['name'];
  final staff = {for (final s in r[3] as List) '${s['id']}': Map<String, dynamic>.from(s)};
  Json person(Object? id) => staff['$id'] ?? {};
  final lines = [for (final l in r[2] as List) if (lineId == null || l['id'] == lineId) Map<String, dynamic>.from(l)]
    ..sort((a, b) => '${person(a['staff_id'])['full_name'] ?? ''}'.compareTo('${person(b['staff_id'])['full_name'] ?? ''}'));
  if (lines.isEmpty) throw 'No one on this pay sheet.';
  final logo = await docLogo(org);
  String a(Object? v) => formatAmount(n(v));
  List<String>? row(String label, Object? v) => n(v) != 0 ? [label, a(v)] : null;
  final status = sheet['status'] == 'draft' ? ' — DRAFT' : sheet['status'] == 'void' ? ' — VOID' : '';

  final pages = [
    for (final l in lines)
      () {
        final p = person(l['staff_id']);
        final earnings = [
          [
            l['pay_basis'] == 'daily'
                ? '${p6n(l['days'] ?? 0)} days × ${a(l['rate'] ?? 0)}'
                : l['part'] == 'advance'
                    ? 'First payment of the month (salary ${a(l['rate'] ?? 0)} a month)'
                    : 'Salary (${a(l['rate'] ?? 0)} a month)${l['part'] == 'balance' ? ' — the month' : ''}',
            a(l['base']),
          ],
          ?row('Allowance', l['additions']),
          ?row('Overtime', l['overtime']),
        ];
        final deductions = [
          ?row('NSSF (employee)', l['nssf_employee']),
          ?row('PAYE', l['paye']),
          ?row('Other deductions${'${l['note'] ?? ''}'.isNotEmpty ? ' (${l['note']})' : ''}', l['deductions']),
          ?row('First payment already paid', l['first_payment']),
          ?row('Advance / loan taken back', l['advance_deductions']),
        ];
        final totalDed = ['nssf_employee', 'paye', 'deductions', 'first_payment', 'advance_deductions'].fold<double>(0, (t, k) => t + n(l[k]));
        return <pw.Widget>[
          docHead(
            org: org, logo: logo, title: 'Salary slip$status',
            coLines: ['${org?['address'] ?? ''}', [if (org?['tin'] != null) 'TIN ${org!['tin']}', ?branch].join(' · ')],
            right: [
              'Period: ${dateText(sheet['period_start'])} to ${dateText(sheet['period_end'])}',
              '${_cycle[sheet['cycle']] ?? ''}${sheet['paid_on'] != null ? ' · paid ${dateText(sheet['paid_on'])}' : ''}',
            ],
          ),
          docTo('Employee', [
            pw.Text('${p['full_name'] ?? ''}', style: docStyle(bold: true)),
            pw.Text([p['job_title'], p['kind'] == 'casual' ? 'Casual' : p['kind'] == 'employed' ? 'Employed' : null].where((x) => x != null && '$x'.isNotEmpty).join(' · ')),
            if (p['nssf_no'] != null) pw.Text('NSSF no. ${p['nssf_no']}'),
            if (l['days'] != null) pw.Text('Days attended: ${p6n(l['days'])}'),
          ]),
          pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Expanded(child: docTable(['Earnings', 'TZS'], earnings, num: {1}, foot: ['Gross pay', a(l['gross'])])),
            pw.SizedBox(width: 12),
            pw.Expanded(child: docTable(['Deductions', 'TZS'], deductions, num: {1}, foot: ['Total deductions', a(totalDed)])),
          ]),
          docTotals([('Net pay', docMoney(l['amount'], org), grand: true, bold: true)]),
          if (n(l['nssf_employer']) > 0)
            pw.Text('The employer also pays NSSF ${a(l['nssf_employer'])} for you.', style: docStyle(size: 10, color: const PdfColor.fromInt(0xFF777777))),
        ];
      }(),
  ];
  return docPdfPages(
    title: 'Payslips ${dateText(sheet['period_start'])} – ${dateText(sheet['period_end'])}',
    org: org,
    pages: pages,
    foot: () => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      docSign(['Received by', 'Signature', 'Date']),
      pw.SizedBox(height: 4),
      pw.Text('${org?['legal_name'] ?? org?['name'] ?? ''} · prepared with MOIS', style: docStyle(size: 9.5, color: const PdfColor.fromInt(0xFF999999))),
    ]),
  );
}

/// A plain number as the web's Number(x) shows it (2.5, 3)
String p6n(Object? v) {
  final d = n(v).toDouble();
  return d == d.roundToDouble() ? d.toInt().toString() : d.toString();
}
