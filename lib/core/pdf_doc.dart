import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'format.dart';
import 'offline.dart';
import 'session.dart';
import 'theme.dart';

/*
 * Printed documents on the phone (approved 2026-11-24: a PDF made on the phone). A port of the
 * web's .doc print pages (styles .doc-head, .doc-to, .doc-table, .doc-totals, .doc-sign, .doc-foot):
 * A4, 16 mm × 14 mm margins, Times New Roman 12 pt (LOCKED printed-docs font) — Tinos, the
 * metric twin of Times New Roman, when it can be fetched, else the PDF's own Times.
 * The PDF opens in the app's viewer with Print and Share (WhatsApp, email, Drive).
 */
const _ink = PdfColor.fromInt(0xFF1A1A1A);
const _muted = PdfColor.fromInt(0xFF777777);
const _rule = PdfColor.fromInt(0xFFBBBBBB);
const _light = PdfColor.fromInt(0xFFE3E3E3);
const _brand = PdfColor.fromInt(0xFF4B3621);

class DocFonts {
  DocFonts(this.base, this.bold);
  final pw.Font base, bold;
  static DocFonts? _cached;
  static Future<DocFonts> load() async {
    if (_cached != null) return _cached!;
    try {
      _cached = DocFonts(await PdfGoogleFonts.tinosRegular(), await PdfGoogleFonts.tinosBold());
    } catch (_) {
      _cached = DocFonts(pw.Font.times(), pw.Font.timesBold());
    }
    return _cached!;
  }
}

/// The organization's logo for the letterhead, or null
Future<pw.ImageProvider?> docLogo(Json? org) async {
  final url = '${org?['logo_url'] ?? ''}';
  if (!url.startsWith('http')) return null;
  try {
    final r = await http.get(Uri.parse(url));
    return r.statusCode == 200 ? pw.MemoryImage(r.bodyBytes) : null;
  } catch (_) {
    return null;
  }
}

pw.TextStyle docStyle({double size = 12, bool bold = false, PdfColor color = _ink}) =>
    pw.TextStyle(fontSize: size, fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal, color: color);

/// .doc-label — small upper-case grey label
pw.Widget docLabel(String s) => pw.Text(s.toUpperCase(), style: docStyle(size: 9, color: _muted).copyWith(letterSpacing: 0.6));

/// .doc-head — company (logo, legal name, address, phone · email, TIN · VRN, branch) left; title block right
pw.Widget docHead({required Json? org, Json? branch, pw.ImageProvider? logo, required String title, required List<String> right, String? number, List<String>? coLines}) {
  final co = coLines != null
      ? <pw.Widget>[pw.Text('${org?['legal_name'] ?? org?['name'] ?? ''}', style: docStyle(size: 16, bold: true)), for (final l in coLines) if (l.isNotEmpty) pw.Text(l)]
      : <pw.Widget>[
    pw.Text('${org?['legal_name'] ?? org?['name'] ?? ''}', style: docStyle(size: 16, bold: true)),
    if ('${org?['address'] ?? ''}'.isNotEmpty) pw.Text('${org!['address']}'),
    if ([org?['phone'], org?['email']].any((x) => x != null && '$x'.isNotEmpty)) pw.Text([org?['phone'], org?['email']].where((x) => x != null && '$x'.isNotEmpty).join(' · ')),
    if (org?['tin'] != null || org?['vrn'] != null) pw.Text([if (org?['tin'] != null) 'TIN ${org!['tin']}', if (org?['vrn'] != null) 'VRN ${org!['vrn']}'].join(' · ')),
    if (branch != null) pw.Text('Branch: ${branch['name']}${'${branch['location'] ?? ''}'.isNotEmpty ? ' — ${branch['location']}' : ''}'),
  ];
  return pw.Container(
    padding: const pw.EdgeInsets.only(bottom: 10),
    decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _brand, width: 2))),
    child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
      pw.Expanded(
        child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          if (logo != null) pw.Padding(padding: const pw.EdgeInsets.only(right: 12), child: pw.ConstrainedBox(constraints: const pw.BoxConstraints(maxHeight: 64, maxWidth: 150), child: pw.Image(logo, fit: pw.BoxFit.contain))),
          pw.Expanded(child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: co)),
        ]),
      ),
      pw.SizedBox(width: 16),
      pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.end, children: [
        pw.Text(title, style: docStyle(size: 20, bold: true)),
        if (number != null) pw.Text(number, style: docStyle(bold: true)),
        for (final r in right) pw.Text(r),
      ]),
    ]),
  );
}

/// .doc-to — "Bill to" block
pw.Widget docTo(String label, List<pw.Widget> lines) => pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [docLabel(label), ...lines]);

/// .doc-table — header row in small grey capitals, a thin rule a row; numeric columns right
pw.Widget docTable(List<String> head, List<List<String>> rows, {Set<int> num = const {}, Map<int, pw.TableColumnWidth>? widths, List<String>? foot}) {
  pw.Widget cell(String s, int i, {bool header = false, bool bold = false}) => pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 4),
        child: pw.Text(header ? s.toUpperCase() : s,
            textAlign: num.contains(i) ? pw.TextAlign.right : pw.TextAlign.left,
            style: header ? docStyle(size: 9, color: const PdfColor.fromInt(0xFF555555)).copyWith(letterSpacing: 0.5) : docStyle(bold: bold)),
      );
  return pw.Table(
    columnWidths: widths,
    children: [
      pw.TableRow(decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _rule))), children: [for (final (i, h) in head.indexed) cell(h, i, header: true)]),
      for (final r in rows) pw.TableRow(decoration: const pw.BoxDecoration(border: pw.Border(bottom: pw.BorderSide(color: _light))), children: [for (final (i, c) in r.indexed) cell(c, i)]),
      if (foot != null) pw.TableRow(decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _ink, width: 1.5))), children: [for (final (i, c) in foot.indexed) cell(c, i, bold: true)]),
    ],
  );
}

/// .doc-totals — label / amount pairs on the right; grand = the bold total with a rule above
pw.Widget docTotals(List<(String, String, {bool grand, bool bold})> rows) => pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Container(
        width: 260,
        margin: const pw.EdgeInsets.only(top: 8),
        child: pw.Column(children: [
          for (final r in rows)
            pw.Container(
              padding: const pw.EdgeInsets.symmetric(vertical: 3, horizontal: 4),
              decoration: r.grand ? const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _ink, width: 2))) : null,
              child: pw.Row(children: [
                pw.Expanded(child: pw.Text(r.$1, style: docStyle(bold: r.grand || r.bold, size: r.grand ? 14 : 12))),
                pw.Text(r.$2, style: docStyle(bold: r.grand || r.bold, size: r.grand ? 14 : 12)),
              ]),
            ),
        ]),
      ),
    );

/// .doc-sign — signature lines
pw.Widget docSign(List<String> labels) => pw.Padding(
      padding: const pw.EdgeInsets.only(top: 40),
      child: pw.Row(children: [
        for (final (i, l) in labels.indexed) ...[
          if (i > 0) pw.SizedBox(width: 24),
          pw.Expanded(
            child: pw.Container(
              padding: const pw.EdgeInsets.only(top: 4),
              decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: _ink))),
              child: pw.Text(l, style: docStyle(size: 10.5, color: const PdfColor.fromInt(0xFF444444))),
            ),
          ),
        ],
      ]),
    );

/// .doc-foot — the organization's footer text and "prepared with MOIS"
pw.Widget docFoot(Json? org) => pw.Container(
      width: double.infinity,
      padding: const pw.EdgeInsets.only(top: 8),
      decoration: const pw.BoxDecoration(border: pw.Border(top: pw.BorderSide(color: PdfColor.fromInt(0xFFDDDDDD)))),
      child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
        if ('${org?['document_footer'] ?? ''}'.isNotEmpty) pw.Text('${org!['document_footer']}', style: docStyle(size: 10.5, color: const PdfColor.fromInt(0xFF444444))),
        pw.SizedBox(height: 4),
        pw.Text('${org?['legal_name'] ?? org?['name'] ?? ''} · prepared with MOIS', style: docStyle(size: 9.5, color: const PdfColor.fromInt(0xFF999999))),
      ]),
    );

/// An A4 document: body widgets flow over pages; the footer sits at the bottom of the last page
Future<Uint8List> docPdf({required String title, required List<pw.Widget> body, Json? org, bool landscape = false, double fontSize = 12, pw.Widget? foot}) async {
  final f = await DocFonts.load();
  final doc = pw.Document(title: title, author: '${org?['legal_name'] ?? org?['name'] ?? 'MOIS'}', creator: 'MOIS');
  doc.addPage(pw.MultiPage(
    pageTheme: pw.PageTheme(
      pageFormat: landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
      margin: const pw.EdgeInsets.symmetric(vertical: 16 * PdfPageFormat.mm, horizontal: 14 * PdfPageFormat.mm),
      theme: pw.ThemeData.withFont(base: f.base, bold: f.bold).copyWith(defaultTextStyle: pw.TextStyle(font: f.base, fontBold: f.bold, fontSize: fontSize, lineSpacing: 2, color: _ink)),
    ),
    build: (_) => [
      for (final (i, w) in body.indexed) ...[if (i > 0) pw.SizedBox(height: 14), w],
    ],
    footer: org == null && foot == null ? null : (ctx) => ctx.pageNumber == ctx.pagesCount ? (foot ?? docFoot(org)) : pw.SizedBox(),
  ));
  return doc.save();
}

/// Open a document: build it, then show it with Print and Share
Future<void> openDoc(BuildContext context, String title, Future<Uint8List> Function() build) =>
    Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _DocView(title: title, make: () async {
          // a document opened once is kept on the phone: offline it opens from that copy
          final (b64, _) = await offline.load<String>('pdf:$title',() async => base64Encode(await build()));
          return base64Decode(b64);
        })));

class _DocView extends StatelessWidget {
  const _DocView({required this.title, required this.make});
  final String title;
  final Future<Uint8List> Function() make;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final file = '${title.replaceAll(RegExp(r'[^A-Za-z0-9 #._-]+'), ' ').trim()}.pdf';
    return Scaffold(
      backgroundColor: t.canvas,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: Fs.md, fontWeight: FontWeight.w600)),
        actions: [IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(context), icon: const Icon(LucideIcons.x, size: 20))],
      ),
      body: PdfPreview(
        build: (_) => make(),
        pdfFileName: file,
        canChangePageFormat: false,
        canChangeOrientation: false,
        canDebug: false,
        allowPrinting: true,
        allowSharing: true,
        loadingWidget: const Center(child: CircularProgressIndicator()),
        onError: (_, e) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(e is String ? e : "We couldn't make this document."))),
      ),
    );
  }
}

String docMoney(Object? v, Json? org) => v == null ? '—' : formatMoney(n(v), '${org?['currency_code'] ?? 'TZS'}');

/// Several documents in one PDF, each starting on its own page (payslips: one a page)
Future<Uint8List> docPdfPages({required String title, required List<List<pw.Widget>> pages, required pw.Widget Function() foot, Json? org}) async {
  final f = await DocFonts.load();
  final doc = pw.Document(title: title, author: '${org?['legal_name'] ?? org?['name'] ?? 'MOIS'}', creator: 'MOIS');
  for (final body in pages) {
    doc.addPage(pw.MultiPage(
      pageTheme: pw.PageTheme(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.symmetric(vertical: 16 * PdfPageFormat.mm, horizontal: 14 * PdfPageFormat.mm),
        theme: pw.ThemeData.withFont(base: f.base, bold: f.bold).copyWith(defaultTextStyle: pw.TextStyle(font: f.base, fontBold: f.bold, fontSize: 12, lineSpacing: 2, color: _ink)),
      ),
      build: (_) => [for (final (i, w) in body.indexed) ...[if (i > 0) pw.SizedBox(height: 14), w]],
      footer: (ctx) => foot(),
    ));
  }
  return doc.save();
}
