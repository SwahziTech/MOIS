import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:share_plus/share_plus.dart';

/*
 * A small Excel (.xlsx) writer — the phone's version of the web's exportTable (lib/reports.js, ExcelJS):
 * one sheet, a bold title row, an empty row, a bold head row, the rows, a bold total row; first column
 * 32 wide, the rest 16. Times New Roman 12 pt (LOCKED printed-docs font, Excel too). Numbers stay numbers.
 * The file goes to the phone's share sheet (WhatsApp, Drive, Files), as the web's lib/native does.
 */
String _esc(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');

String _col(int i) {
  var s = '';
  for (var n = i + 1; n > 0; n = (n - 1) ~/ 26) {
    s = String.fromCharCode(65 + (n - 1) % 26) + s;
  }
  return s;
}

Uint8List buildXlsx(String title, List<String> head, List<List<Object?>> rows, [List<Object?>? total]) {
  final all = <(List<Object?>, bool)>[([title], true), (<Object?>[], false), (head, true), for (final r in rows) (r, false), if (total != null) (total, true)];
  final width = [head.length, ...rows.map((r) => r.length)].fold<int>(1, (m, x) => x > m ? x : m);
  final sb = StringBuffer();
  for (final (ri, (r, bold)) in all.indexed) {
    sb.write('<row r="${ri + 1}">');
    for (final (ci, v) in r.indexed) {
      if (v == null || (v is String && v.isEmpty)) continue;
      final ref = '${_col(ci)}${ri + 1}';
      final s = bold ? ' s="1"' : '';
      if (v is num && v.isFinite) {
        sb.write('<c r="$ref"$s><v>$v</v></c>');
      } else {
        sb.write('<c r="$ref" t="inlineStr"$s><is><t xml:space="preserve">${_esc('$v')}</t></is></c>');
      }
    }
    sb.write('</row>');
  }
  final cols = [for (var i = 0; i < width; i++) '<col min="${i + 1}" max="${i + 1}" width="${i == 0 ? 32 : 16}" customWidth="1"/>'].join();
  final sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cols>$cols</cols><sheetData>$sb</sheetData></worksheet>';
  final name = _esc(title.length > 30 ? title.substring(0, 30) : title).replaceAll(RegExp(r'[\\/?*\[\]:]'), ' ');
  final files = {
    '[Content_Types].xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>'
        '<Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>'
        '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>',
    '_rels/.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    'xl/workbook.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="$name" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>',
    'xl/styles.xml': '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="2"><font><sz val="12"/><name val="Times New Roman"/></font><font><b/><sz val="12"/><name val="Times New Roman"/></font></fonts>'
        '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>'
        '<borders count="1"><border/></borders><cellStyleXfs count="1"><xf/></cellStyleXfs>'
        '<cellXfs count="2"><xf fontId="0"/><xf fontId="1" applyFont="1"/></cellXfs></styleSheet>',
    'xl/worksheets/sheet1.xml': sheet,
  };
  final a = Archive();
  for (final e in files.entries) {
    final b = utf8.encode(e.value);
    a.addFile(ArchiveFile(e.key, b.length, b));
  }
  return Uint8List.fromList(ZipEncoder().encode(a));
}

/// Make the Excel file and open the share sheet with it
Future<void> shareXlsx(String fileName, String title, List<String> head, List<List<Object?>> rows, [List<Object?>? total]) async {
  final bytes = buildXlsx(title, head, rows, total);
  await SharePlus.instance.share(ShareParams(files: [
    XFile.fromData(bytes, name: '$fileName.xlsx', mimeType: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'),
  ], fileNameOverrides: ['$fileName.xlsx']));
}
