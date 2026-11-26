import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';

import '../core/daily_report.dart';
import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import 'report_upload.dart';

/*
 * Daily report — a port of web pages/DailyReport.jsx in the approved design (2026-11-23):
 * From MOIS (the day's report in the branch's Swahili format; Copy opens the phone's share sheet,
 * WhatsApp first) · Compare a report (pasted, lined up against MOIS) · Upload a report (comes
 * with Record production, whose form it fills).
 */
bool _close(num a, num b) => (a - b).abs() < 0.5;

class DailyReportPage extends StatefulWidget {
  const DailyReportPage({super.key});
  @override
  State<DailyReportPage> createState() => _DailyReportPageState();
}

class _DailyReportPageState extends State<DailyReportPage> {
  String _tab = 'write';
  late String _date = session.today;
  Json? _facts;
  DateTime? _savedAt;
  String _error = '';
  String _pasted = '';

  String get branchId => session.branchId;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    if (branchId.isEmpty) return;
    setState(() { _error = ''; _facts = null; });
    try {
      final refs = await Refs.load();
      final (f, at) = await offline.load<Json>('day:$branchId:$_date', () => loadDayFacts(branchId, _date, session.today, refs));
      if (mounted) setState(() { _facts = f; _savedAt = at; });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load the day.");
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final canUpload = branchId.isNotEmpty && session.canAt('production.create', branchId);
    final tabs = [('write', 'From MOIS'), ('compare', 'Compare a report'), if (canUpload) ('upload', 'Upload a report')];
    if (branchId.isEmpty) {
      return ListView(padding: const EdgeInsets.all(14), children: const [EmptyState(icon: LucideIcons.fileText, title: 'Choose a branch', description: "The daily report is one branch's day — pick a branch in the menu.")]);
    }
    final f = _facts;
    final text = f == null ? '' : writeReport(f, session.branchName ?? '', _date);
    final products = (f?['products'] as List?)?.cast<Map>() ?? [];
    final meters = (f?['meters'] as List?)?.cast<Map>() ?? [];
    final pieces = products.fold<double>(0, (s, p) => s + n(p['pieces']));
    final bags = products.fold<double>(0, (s, p) => s + n(p['cement']));
    final units = meters.fold<double>(0, (s, m) => s + n(m['used']));
    final rows = f != null && _pasted.trim().isNotEmpty ? compareReport(readReport(_pasted), f) : <Json>[];
    final off = rows.where((r) => r['report'] != null && r['mois'] != null && !_close(n(r['report']), n(r['mois']))).length;
    final missing = rows.where((r) => (r['report'] == null) != (r['mois'] == null)).length;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        PageTabs<String>(tabs: tabs, value: _tab, onChange: (v) => setState(() => _tab = v)),
        if (_tab == 'upload')
          ReportUpload(key: ValueKey('upload$branchId'))
        else ...[
          OfflineNote(_savedAt),
          if (_error.isNotEmpty) ErrorState(_error, onRetry: _load),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  final d = await showDatePicker(context: context, initialDate: DateTime.parse(_date), firstDate: DateTime(2024), lastDate: DateTime.parse(session.today));
                  if (d != null) { setState(() => _date = iso(d)); _load(); }
                },
                icon: const Icon(LucideIcons.calendar, size: 15),
                label: Text(dateText(_date)!),
              ),
            ),
            if (_tab == 'write') ...[
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: text.isEmpty ? null : () => SharePlus.instance.share(ShareParams(text: text)),
                icon: const Icon(LucideIcons.share2, size: 15),
                label: const Text('Copy'),
              ),
            ],
          ]),
          const SizedBox(height: 10),
          if (_tab == 'write')
            Stats([
              Stat('Production', f == null ? '…' : '${formatAmount(pieces)} pcs', help: f == null ? '' : '${products.length} product${products.length == 1 ? '' : 's'}'),
              Stat('Cement', f == null ? '…' : '${formatAmount(bags)} bags used', help: f?['cementStore'] != null ? '${formatAmount(n(f!['cementStore']))} left in store' : 'store not found'),
              Stat('Electricity', f == null ? '…' : '${formatAmount(units)} units', help: f == null ? '' : '${meters.where((m) => m['morning'] != null && m['evening'] != null).length} of ${meters.length} meters read'),
            ])
          else
            Stats([
              Stat('Lines read', '${rows.where((r) => r['report'] != null).length}', help: 'from the pasted report'),
              Stat('Differ', '$off', figureColor: off > 0 ? C.warning : null, help: 'report ≠ MOIS'),
              Stat('On one side only', '$missing', figureColor: missing > 0 ? C.warning : null, help: 'missing from report or MOIS'),
            ]),
          const PlHelp("From the day's records."),
          const SizedBox(height: 8),
          if (_tab == 'write')
            CardBox(child: f == null ? const Skeleton(rows: 6, height: 16) : SelectableText(text, style: const TextStyle(fontSize: Fs.md, height: 1.6)))
          else ...[
            TextField(
              minLines: 8, maxLines: 16,
              decoration: const InputDecoration(labelText: "Paste or type the day's report", hintText: 'RIPOTI YA … TAREHE …\nUZALISHAJI WA …\nPcs … Cem … Wastani …'),
              onChanged: (v) => setState(() => _pasted = v),
            ),
            const SizedBox(height: 10),
            if (_pasted.trim().isEmpty) PlHelp('Paste a report to compare it with ${tableDate(_date)}.')
            else if (f == null) const Skeleton(rows: 4, height: 30)
            else
              for (final r in rows)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${r['item']}', style: const TextStyle(fontSize: Fs.sm)), PlHelp('${r['section']}')])),
                    _cell(r['report']), _cell(r['mois']),
                    SizedBox(
                      width: 64,
                      child: Text(
                        r['report'] != null && r['mois'] != null ? (_close(n(r['report']), n(r['mois'])) ? '✓' : formatAmount(n(r['report']) - n(r['mois']))) : '—',
                        textAlign: TextAlign.right,
                        style: TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w600,
                            color: r['report'] != null && r['mois'] != null ? (_close(n(r['report']), n(r['mois'])) ? C.success : C.warning) : C.warning),
                      ),
                    ),
                  ]),
                ),
          ],
          if (meters.any((m) => m['tokenMissing'] == true))
            const Padding(padding: EdgeInsets.only(top: 8), child: PlHelp('A meter went up with no token recorded — enter the LUKU token under Expenses.', color: C.warning)),
        ],
      ]),
    );
  }

  Widget _cell(Object? v) => SizedBox(width: 64, child: Text(v == null ? '—' : formatAmount(n(v)), textAlign: TextAlign.right, style: const TextStyle(fontSize: Fs.sm)));
}
