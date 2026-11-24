import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import 'files.dart';
import 'format.dart';
import 'session.dart';
import 'ui.dart';

/*
 * ProofView — a port of web components/dashboard/DirectorPayments.jsx ProofView: a proof of payment
 * (photo, PDF or the SMS) with Share and Save. A director's slip is in director-proofs; a proof the
 * branch added to a purchase or an expense is in payment-proofs (134).
 */
const proofKindLabel = {'supplier': 'Supplier', 'expense': 'Expense / bill', 'weekly_cash': 'Weekly cash', 'salaries': 'Salaries', 'other': 'Other'};

Future<void> showProof(BuildContext context, Json row) async {
  final store = '${row['bucket'] ?? 'director-proofs'}';
  final path = row['file_path'] as String?;
  final url = path == null ? null : await signedUrl(store, path);
  if (!context.mounted) return;
  final isPdf = RegExp(r'\.pdf$', caseSensitive: false).hasMatch(path ?? '');
  final title = '${proofKindLabel[row['kind']] ?? ''} · ${formatMoney(n(row['amount']), session.currency)}';
  final text = '$title · paid ${dateText(row['paid_on']) ?? ''}${'${row['description'] ?? ''}'.isNotEmpty ? ' · ${row['description']}' : ''}'
      '${path == null && row['sms_text'] != null ? '\n${row['sms_text']}' : ''}';
  await showModal<void>(context,
      title: title,
      body: (ctx) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PlHelp('Paid ${dateText(row['paid_on']) ?? ''}${'${row['description'] ?? ''}'.isNotEmpty ? ' · ${row['description']}' : ''}'),
            const SizedBox(height: 10),
            if (path != null)
              isPdf
                  ? OutlinedButton.icon(onPressed: url == null ? null : () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication), icon: const Icon(LucideIcons.fileText, size: 16), label: const Text('Open the PDF'))
                  : url == null
                      ? const Skeleton(rows: 1, height: 200)
                      : ClipRRect(borderRadius: BorderRadius.circular(8), child: InteractiveViewer(child: Image.network(url, fit: BoxFit.contain))),
            if (row['sms_text'] != null) ...[
              const SizedBox(height: 10),
              SelectableText('${row['sms_text']}', style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
            ],
          ]),
      footer: (ctx) => Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
            if (url != null || row['sms_text'] != null)
              OutlinedButton.icon(
                icon: const Icon(LucideIcons.share2, size: 15),
                label: const Text('Share'),
                onPressed: () async {
                  if (url != null) {
                    final r = await http.get(Uri.parse(url));
                    final name = '${row['file_name'] ?? 'Paid_${row['paid_on']}${isPdf ? '.pdf' : '.jpg'}'}';
                    await SharePlus.instance.share(ShareParams(text: text, files: [XFile.fromData(r.bodyBytes, name: name, mimeType: isPdf ? 'application/pdf' : 'image/jpeg')], fileNameOverrides: [name]));
                  } else {
                    await SharePlus.instance.share(ShareParams(text: text));
                  }
                },
              ),
            OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ]));
}
