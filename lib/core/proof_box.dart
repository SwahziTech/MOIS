import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'files.dart';
import 'session.dart';
import 'theme.dart';
import 'ui.dart';

/*
 * The proof of a payment — a port of web components/ProofBox.jsx + lib/proofName.js, the phone's way:
 * type or paste the SMS (muamala); + takes a photo with the camera, picks one from the gallery, or a PDF.
 * Photos are made smaller before upload (web 2026-11-11), files over 10 MB are refused.
 */
class ProofFile {
  const ProofFile(this.bytes, this.name, this.mime);
  final Uint8List bytes;
  final String name, mime;
  bool get isImage => mime.startsWith('image/');
  String get ext {
    final fromName = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    if (RegExp(r'^[a-z0-9]{2,5}$').hasMatch(fromName)) return fromName;
    return (mime.split('/').length > 1 ? mime.split('/')[1] : 'jpg').replaceAll('jpeg', 'jpg');
  }
}

String _clean(Object? s) => '${s ?? ''}'.replaceAll(RegExp(r'[^\w.-]+'), '-').replaceAll(RegExp('-+'), '-').replaceAll(RegExp(r'^-|-$'), '');
String _cut(String s) => s.length > 40 ? s.substring(0, 40) : s;

/// Sale-12_Mbaga_235000_2026-11-02.jpg · Paid-Supplier_maneno_13530000_2026-10-30.pdf
String proofName({required String kind, Object? who, num? amount, Object? date, String ext = 'jpg'}) =>
    '${[_cut(_clean(kind)), _cut(_clean(who)), if (amount != null) '${amount.round()}', _cut(_clean(date))].where((x) => x.isNotEmpty).join('_')}.$ext';

/// Upload a proof to bucket/org/branch/folder/time.ext; returns the path
Future<String> uploadProof(String bucket, String branchId, String folder, ProofFile f) async {
  final path = '${session.organization!['id']}/$branchId/$folder/${DateTime.now().millisecondsSinceEpoch}.${f.ext}';
  await uploadFile(bucket, path, f.bytes, f.mime);
  return path;
}

class ProofBox extends StatelessWidget {
  const ProofBox({super.key, required this.file, required this.onFile, required this.text, required this.onText, this.placeholder = 'Paste the SMS (muamala), or add a photo of the slip…'});
  final ProofFile? file;
  final ValueChanged<ProofFile?> onFile;
  final TextEditingController text;
  final VoidCallback onText;
  final String placeholder;

  Future<void> _add(BuildContext context) async {
    final how = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(leading: const Icon(LucideIcons.camera), title: const Text('Take a photo'), onTap: () => Navigator.pop(ctx, 'camera')),
          ListTile(leading: const Icon(LucideIcons.image), title: const Text('Choose a photo'), onTap: () => Navigator.pop(ctx, 'gallery')),
          ListTile(leading: const Icon(LucideIcons.fileText), title: const Text('Choose a PDF'), onTap: () => Navigator.pop(ctx, 'pdf')),
        ]),
      ),
    );
    if (how == null) return;
    ProofFile? f;
    if (how == 'pdf') {
      final r = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
      final x = r.firstOrNull;
      if (x != null) f = ProofFile(await x.xFile.readAsBytes(), x.name, 'application/pdf');
    } else {
      // made smaller before upload: about 1600 px on the long side, JPEG quality 80
      final x = await ImagePicker().pickImage(source: how == 'camera' ? ImageSource.camera : ImageSource.gallery, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
      if (x != null) f = ProofFile(await x.readAsBytes(), x.name, x.mimeType ?? 'image/jpeg');
    }
    if (f == null) return;
    if (f.bytes.length > 10 * 1024 * 1024) {
      if (context.mounted) toast(context, 'That file is over 10 MB — choose a smaller one.', error: true);
      return;
    }
    onFile(f);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Container(
      decoration: BoxDecoration(border: Border.all(color: t.borderStrong), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (file != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: file!.isImage ? Image.memory(file!.bytes, width: 56, height: 56, fit: BoxFit.cover) : Container(width: 56, height: 56, color: t.soft, child: const Icon(LucideIcons.fileText)),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(file!.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: Fs.sm))),
              IconButton(tooltip: 'Remove the file', onPressed: () => onFile(null), icon: const Icon(LucideIcons.x, size: 16)),
            ]),
          ),
        TextField(
          controller: text, minLines: 3, maxLines: 6, onChanged: (_) => onText(),
          decoration: InputDecoration(hintText: placeholder, border: InputBorder.none, enabledBorder: InputBorder.none, focusedBorder: InputBorder.none, filled: false),
        ),
        Container(
          decoration: BoxDecoration(border: Border(top: BorderSide(color: t.border))),
          child: Row(children: [
            IconButton(tooltip: 'Add a photo or PDF', onPressed: () => _add(context), icon: const Icon(LucideIcons.plus, size: 18)),
            const PlHelp('Photo, PDF or SMS'),
          ]),
        ),
      ]),
    );
  }
}
