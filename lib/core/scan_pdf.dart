import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

import 'format.dart';
import 'theme.dart';
import 'ui.dart';

/*
 * Scan a written report (2026-11-26, the user): take photos of the pages with the camera (or pick them),
 * put them in order, and make one PDF — each page a full A4 page — then share it through any app the
 * person chooses (WhatsApp, email, Drive …). The pages can also go into the upload as its photos.
 */
class ScanPage {
  ScanPage(this.bytes, this.name);
  final Uint8List bytes;
  final String name;
}

/// Opens the scanner; returns the pages when "Use in the upload" is pressed (null otherwise)
Future<List<ScanPage>?> openScanner(BuildContext context, {String title = 'Report', bool canUse = false}) =>
    Navigator.push<List<ScanPage>>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _Scanner(title: title, canUse: canUse)));

Future<Uint8List> scanPdf(List<ScanPage> pages) async {
  final doc = pw.Document();
  for (final p in pages) {
    final img = pw.MemoryImage(p.bytes);
    doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.all(18), build: (_) => pw.Center(child: pw.Image(img, fit: pw.BoxFit.contain))));
  }
  return doc.save();
}

class _Scanner extends StatefulWidget {
  const _Scanner({required this.title, required this.canUse});
  final String title;
  final bool canUse;
  @override
  State<_Scanner> createState() => _ScannerState();
}

class _ScannerState extends State<_Scanner> {
  final List<ScanPage> _pages = [];
  bool _busy = false;
  String _error = '';

  Future<void> _add(ImageSource src) async {
    setState(() => _error = '');
    try {
      if (src == ImageSource.gallery) {
        final xs = await ImagePicker().pickMultiImage(maxWidth: 2400, maxHeight: 2400, imageQuality: 85);
        for (final x in xs) { _pages.add(ScanPage(await x.readAsBytes(), x.name)); }
      } else {
        final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2400, maxHeight: 2400, imageQuality: 85);
        if (x != null) _pages.add(ScanPage(await x.readAsBytes(), x.name));
      }
    } catch (_) {
      _error = "We couldn't open the camera. Check the app may use it.";
    }
    if (mounted) setState(() {});
  }

  String get fileName => '${widget.title.replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '').trim()} ${tableDate(DateTime.now().toIso8601String().substring(0, 10)) ?? ''}'.trim();

  Future<void> _share() async {
    setState(() { _busy = true; _error = ''; });
    try {
      final bytes = await scanPdf(_pages);
      // the phone's share sheet: the person picks WhatsApp, email, Drive …
      await SharePlus.instance.share(ShareParams(files: [XFile.fromData(bytes, name: '$fileName.pdf', mimeType: 'application/pdf')], fileNameOverrides: ['$fileName.pdf'], subject: fileName));
    } catch (_) {
      _error = "We couldn't make the PDF. Please try again.";
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return FullPage(
      title: 'Scan to PDF',
      footer: [
        if (widget.canUse) OutlinedButton(onPressed: _pages.isEmpty ? null : () => Navigator.pop(context, _pages), child: const Text('Use in the upload')),
        FilledButton.icon(onPressed: _pages.isEmpty || _busy ? null : _share, icon: const Icon(LucideIcons.share2, size: 16), label: Text(_busy ? 'Making PDF…' : 'Share PDF')),
      ],
      children: [
        const PlHelp('Photograph each page flat and in good light. Share sends one PDF through the app you choose.'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: FilledButton.icon(onPressed: () => _add(ImageSource.camera), icon: const Icon(LucideIcons.camera, size: 16), label: Text(_pages.isEmpty ? 'Take a photo' : 'Next page'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(onPressed: () => _add(ImageSource.gallery), icon: const Icon(LucideIcons.image, size: 16), label: const Text('From gallery'))),
        ]),
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        const SizedBox(height: 12),
        if (_pages.isEmpty)
          const EmptyState(icon: LucideIcons.scanLine, title: 'No pages yet', description: 'Take a photo of the first page.')
        else ...[
          Text('${_pages.length} page${_pages.length == 1 ? '' : 's'}', style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          for (final (i, p) in _pages.indexed)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: t.border)),
              clipBehavior: Clip.antiAlias,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Image.memory(p.bytes, height: 260, fit: BoxFit.contain),
                Container(
                  color: t.soft,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(children: [
                    Text('  Page ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(tooltip: 'Move up', onPressed: i == 0 ? null : () => setState(() => _pages.insert(i - 1, _pages.removeAt(i))), icon: const Icon(LucideIcons.arrowUp, size: 16)),
                    IconButton(tooltip: 'Move down', onPressed: i == _pages.length - 1 ? null : () => setState(() => _pages.insert(i + 1, _pages.removeAt(i))), icon: const Icon(LucideIcons.arrowDown, size: 16)),
                    IconButton(tooltip: 'Remove page', onPressed: () => setState(() => _pages.removeAt(i)), icon: const Icon(LucideIcons.trash2, size: 16)),
                  ]),
                ),
              ]),
            ),
        ],
      ],
    );
  }
}
