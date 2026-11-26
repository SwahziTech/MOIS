import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/daily_report.dart';
import '../core/files.dart';
import '../core/format.dart';
import '../core/inventory.dart';
import '../core/production.dart';
import '../core/proof_box.dart' show ProofFile;
import '../core/scan_pdf.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../shell.dart';
import 'procurement_actions.dart' show DateField;
import 'stock_movement.dart' show MovementPage;

/*
 * Upload a report — a port of web components/reports/ReportUpload.jsx, SalesUpload.jsx and StockCountUpload.jsx
 * (2026-11-03 / 11-20; approved for the phone 2026-11-26). A report can come in typed, or as photos / a PDF kept
 * with the branch and day (103). Production report: the WhatsApp text is read and matched to MOIS; what it
 * doesn't hold shows red until typed; saving keeps the pages and text, records meter readings, and hands the
 * batches to Production one at a time. Sales sheet / Past sales: rows typed beside the pages, handed to
 * Record sale one sale at a time. Stock count: rows of store, item, colour and what was found, opened in
 * Stock › Count filled in, one store at a time. Uploads only save retyping. Scan to PDF (2026-11-26):
 * photograph a written report into one PDF and share it through any app. Online only.
 */
const _kinds = [('production', 'Production report'), ('sales', 'Sales sheet'), ('stock', 'Stock count'), ('past_sales', 'Past sales')];
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
double? _num(String? v) => (v ?? '').trim().isEmpty ? null : double.tryParse(v!.trim().replaceAll(',', ''));
double _r2(num v) => (v * 100).roundToDouble() / 100;
bool _whole(String v) => _num(v) != null && _num(v)! >= 0 && _num(v)! == _num(v)!.roundToDouble();
String _plural(int k, String one, [String? many]) => '$k ${k == 1 ? one : (many ?? '${one}s')}';

class _Left {
  _Left(this.readName, this.productId, String pieces) : pieces = TextEditingController(text: pieces);
  final String readName;
  String productId;
  final TextEditingController pieces;
}

class _Batch {
  _Batch(this.readName, this.productId, this.colorId, String pieces, String bags, this.people, this.leftovers)
      : pieces = TextEditingController(text: pieces), bags = TextEditingController(text: bags);
  final String readName;
  String productId, colorId, teamId = '', machineId = '';
  final TextEditingController pieces, bags;
  final num? people;
  final List<_Left> leftovers;
}

class _Meter {
  _Meter(this.readName, this.meterId, String morning, String evening) : morning = TextEditingController(text: morning), evening = TextEditingController(text: evening);
  final String readName;
  String meterId;
  final TextEditingController morning, evening;
}

String _n(Object? v) => v == null ? '' : qtyText(n(v)).replaceAll(',', '');

class ReportUpload extends StatefulWidget {
  const ReportUpload({super.key});
  @override
  State<ReportUpload> createState() => _ReportUploadState();
}

class _ReportUploadState extends State<ReportUpload> {
  Refs? _refs;
  ProductionLists? _lists;
  String _kind = 'production';
  late String _date = session.today;
  Json? _salesStats, _countStats;
  final List<ProofFile> _files = [];
  final _text = TextEditingController();
  List<_Batch>? _batches;
  List<_Meter> _readMeters = [];
  double? _cementStore;
  String? _readDate;
  Json? _facts;
  List<Json> _meters = [], _kept = [];
  bool _tried = false, _busy = false;
  String _error = '';

  String get branchId => session.branchId;
  String get today => session.today;
  bool get canUpload => branchId.isNotEmpty && session.canAt('production.create', branchId, null);

  @override
  void initState() {
    super.initState();
    _text.addListener(() => setState(() {}));
    _init();
  }

  Future<void> _init() async {
    try {
      final r = await Future.wait<dynamic>([
        Refs.load(),
        loadProductionLists(branchId),
        db.from('power_meters').select('id, name, status').eq('branch_id', branchId).order('name', ascending: true).then<List>((v) => v).catchError((_) => <dynamic>[]),
      ]);
      if (!mounted) return;
      setState(() { _refs = r[0] as Refs; _lists = r[1] as ProductionLists; _meters = _l(r[2]).where((m) => m['status'] == 'active').toList(); });
      _loadDay();
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load the upload. Please try again.");
    }
  }

  Future<void> _loadDay() async {
    final refs = _refs;
    if (refs == null) return;
    setState(() => _facts = null);
    loadDayFacts(branchId, _date, today, refs).then((f) { if (mounted) setState(() => _facts = f); }).catchError((_) {});
    try {
      final k = _l(await db.from('report_uploads').select('id, kind, file_path, file_name, report_text, created_at').eq('branch_id', branchId).eq('report_date', _date).order('created_at', ascending: false));
      if (mounted) setState(() => _kept = k);
    } catch (_) {
      if (mounted) setState(() => _kept = []);
    }
  }

  // ---- the pages ----
  Future<void> _addPages(String how) async {
    setState(() => _error = '');
    try {
      if (how == 'scan') {
        final pages = await openScanner(context, title: 'Report ${tableDate(_date) ?? ''}', canUse: true);
        if (pages != null) _files.addAll([for (final p in pages) ProofFile(p.bytes, p.name, 'image/jpeg')]);
      } else if (how == 'pdf') {
        final r = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['pdf']);
        for (final x in r) {
          final b = await x.xFile.readAsBytes();
          if (b.length > 10 * 1024 * 1024) { _error = 'A file is over 10 MB. Take the photo again at a smaller size.'; continue; }
          _files.add(ProofFile(b, x.name, 'application/pdf'));
        }
      } else if (how == 'gallery') {
        // smaller before upload; sheets keep more detail (2400 px)
        for (final x in await ImagePicker().pickMultiImage(maxWidth: 2400, maxHeight: 2400, imageQuality: 85)) {
          _files.add(ProofFile(await x.readAsBytes(), x.name, x.mimeType ?? 'image/jpeg'));
        }
      } else {
        final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2400, maxHeight: 2400, imageQuality: 85);
        if (x != null) _files.add(ProofFile(await x.readAsBytes(), x.name, x.mimeType ?? 'image/jpeg'));
      }
    } catch (_) {
      _error = "We couldn't add that page. Please try again.";
    }
    if (mounted) setState(() {});
  }

  /// the pages and the text, kept with the branch and day (103)
  Future<void> keep(String reportKind, String? reportText) async {
    final at = DateTime.now().millisecondsSinceEpoch;
    final rows = <Json>[];
    for (final (i, f) in _files.indexed) {
      final path = '${session.organization!['id']}/$branchId/$_date/$at-${i + 1}.${f.ext}';
      await uploadFile('report-photos', path, f.bytes, f.mime);
      rows.add({'file_path': path, 'file_name': f.name});
    }
    if (rows.isEmpty && (reportText ?? '').isNotEmpty) rows.add({});
    for (final (i, r) in rows.indexed) {
      await db.rpc('record_report_upload', params: {'p': {'branch_id': branchId, 'report_date': _date, 'kind': reportKind, ...r, 'report_text': i == 0 && (reportText ?? '').isNotEmpty ? reportText : null}});
    }
  }

  Future<void> _openKept(Json u) async {
    final url = await signedUrl('report-photos', u['file_path'] as String?);
    if (url != null) await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }

  void _cleared() { _files.clear(); _tried = false; }

  // ---- production report ----
  List<Item> get carried {
    final refs = _refs!;
    return refs.items.values.where((i) => i.kind == 'product' && i.status == 'active' && (refs.carriedByBranch[branchId]?.contains(i.id) ?? false)).toList()..sort((a, b) => a.name.compareTo(b.name));
  }

  List<Json> get teams => (_lists?.teams ?? []).where((t) => t['status'] == 'active').toList();
  List<Json> get people => (_lists?.people ?? []).where((p) => p['status'] == 'active' && p['in_production_cost'] != false).toList();
  List<String> membersOf(String teamId) => [
        for (final m in _l(teams.where((t) => t['id'] == teamId).firstOrNull?['members']))
          if (m['status'] == 'active' && m['staff_id'] != null && people.any((p) => p['id'] == m['staff_id'])) '${m['staff_id']}',
      ];
  List<Json> machinesFor(String productId) {
    final all = (_lists?.machines ?? []).where((m) => m['status'] == 'active').toList();
    final linked = all.where((m) => (_lists?.links ?? []).any((l) => l['machine_id'] == m['id'] && l['product_id'] == productId)).toList();
    return linked.isNotEmpty ? linked : all;
  }

  /// a written colour in the product's line ("TOFALI 5 RED") → that colour, if the product comes in it
  String colourIn(String name, Item? product) {
    final w = words(name);
    return product?.colorIds.where((id) => w.contains(_refs!.colour(id).toLowerCase())).firstOrNull ?? '';
  }

  void _read() {
    setState(() { _tried = false; _error = ''; });
    final r = readReport(_text.text);
    final products = _l(r['products']), meters = _l(r['meters']);
    if (products.isEmpty && meters.isEmpty && r['cementStore'] == null) {
      setState(() { _batches = null; _error = "MOIS couldn't find production, cement or meters in that text. Check it follows the daily report format."; });
      return;
    }
    final rd = r['date'] as String?;
    if (rd != null && rd.compareTo(today) <= 0 && rd != _date) { _date = rd; _loadDay(); }
    final list = [for (final i in carried) {'id': i.id, 'name': i.name}];
    final used = <String>{};
    setState(() {
      _batches = [
        for (final p in products)
          () {
            final m = bestMatch('${p['name']}', list);
            final item = m == null ? null : _refs!.items['p:${m['id']}'];
            return _Batch('${p['name']}', '${m?['id'] ?? ''}', colourIn('${p['name']}', item), _n(p['pieces']), _n(p['cement']), p['people'] as num?, [
              for (final l in _l(p['leftovers'])) _Left('${l['name']}', '${bestMatch('${l['name']}', list)?['id'] ?? ''}', _n(l['pieces'])),
            ]);
          }(),
      ];
      _readMeters = [
        for (final x in meters)
          () {
            final m = bestMatch('${x['name']}', _meters.where((y) => !used.contains(y['id'])).toList());
            if (m != null) used.add('${m['id']}');
            return _Meter('${x['name']}', '${m?['id'] ?? ''}', _n(x['morning']), _n(x['evening']));
          }(),
      ];
      _cementStore = r['cementStore'] == null ? null : n(r['cementStore']).toDouble();
      _readDate = rd;
    });
  }

  Item? productOf(String id) => _refs!.items['p:$id'];
  Map<String, bool> missingOf(_Batch b) => {
        'product': b.productId.isEmpty,
        'colour': b.productId.isNotEmpty && (productOf(b.productId)?.colorIds.isNotEmpty ?? false) && b.colorId.isEmpty,
        'pieces': !(_whole(b.pieces.text) && _num(b.pieces.text)! > 0),
        'bags': !((_num(b.bags.text) ?? 0) > 0),
        'team': b.teamId.isEmpty,
        'machine': b.machineId.isEmpty,
        'leftovers': b.leftovers.any((l) => l.productId.isEmpty || !_whole(l.pieces.text)),
      };
  /// a meter's readings already in MOIS for the day aren't sent again
  num? had(String meterId, String slot) {
    final name = _meters.where((m) => m['id'] == meterId).firstOrNull?['name'];
    final f = _l(_facts?['meters']).where((m) => m['name'] == name).firstOrNull;
    return f?[slot] as num?;
  }

  bool meterMissing(_Meter m) => m.meterId.isEmpty && (_num(m.morning.text) != null || _num(m.evening.text) != null);
  int get toType => _batches == null ? 0 : _batches!.fold<int>(0, (t, b) => t + missingOf(b).values.where((v) => v).length) + _readMeters.where(meterMissing).length;
  double get already => _l(_facts?['products']).fold<double>(0, (t, p) => t + n(p['pieces']));

  Future<void> _saveProduction() async {
    setState(() { _tried = true; _error = ''; });
    if (toType > 0) { setState(() => _error = 'Fill the ${_plural(toType, 'red box', 'red boxes')} first.'); return; }
    setState(() => _busy = true);
    try {
      // 1. the photos and the text, kept with the day
      await keep('production', _text.text.trim());
      // 2. meter readings not yet in MOIS
      final readings = [
        for (final m in _readMeters.where((m) => m.meterId.isNotEmpty))
          for (final (s, c) in [('morning', m.morning), ('evening', m.evening)])
            if (_num(c.text) != null && had(m.meterId, s) == null) {'meter_id': m.meterId, 'slot': s, 'reading': _num(c.text)},
      ];
      if (readings.isNotEmpty) await db.rpc('record_power_readings', params: {'p': {'read_on': _date, 'readings': readings}});
      // 3. the batches go to Production, one at a time through the usual form
      if (_batches!.isNotEmpty) {
        final forms = [
          for (final b in _batches!)
            {
              'productId': b.productId, 'colorId': b.colorId, 'bags': _n(_num(b.bags.text)), 'pieces': _n(_num(b.pieces.text)),
              'leftovers': [for (final l in b.leftovers) {'productId': l.productId, 'pieces': _n(_num(l.pieces.text))}],
              'allowOther': b.leftovers.any((l) => productOf(l.productId)?.categoryId != productOf(b.productId)?.categoryId),
              'teamId': b.teamId, 'workerIds': membersOf(b.teamId), 'machineId': b.machineId,
            },
        ];
        final p = await SharedPreferences.getInstance();
        await p.setString('mois.upload.queue.${session.organization!['id']}.$branchId', jsonEncode({'date': _date, 'forms': forms}));
        if (mounted) Shell.of(context).go('/production?tab=log');
        return;
      }
      setState(() { _batches = null; _text.clear(); _cleared(); });
      await _loadDay();
    } catch (e) {
      _error = dbError(e, "We couldn't save the report. Please try again.");
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final refs = _refs;
    if (!canUpload) return PlHelp('Uploading reports is for the Branch Manager and the Secretary at ${session.branchName ?? 'this branch'}.');
    if (refs == null) return _error.isNotEmpty ? ErrorState(_error, onRetry: _init) : const Skeleton(rows: 5);
    final nBatches = _batches?.length ?? 0;
    final pieces = (_batches ?? []).fold<double>(0, (t, b) => t + (_num(b.pieces.text) ?? 0) + b.leftovers.fold<double>(0, (s, l) => s + (_num(l.pieces.text) ?? 0)));
    final cs = _countStats, ss = _salesStats;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (_kind == 'production')
        Stats([
          Stat('Read', _batches != null ? _plural(nBatches, 'batch', 'batches') : '—', help: _batches != null ? '${formatAmount(pieces)} pcs · ${_plural(_readMeters.length, 'meter')}' : 'paste the report, then Read'),
          Stat('To type', _batches != null ? '$toType' : '—', figureColor: toType > 0 ? C.warning : null, help: "details the report doesn't hold"),
          Stat('Already in MOIS', _facts != null ? '${formatAmount(already)} pcs' : '…', figureColor: already > 0 ? C.warning : null,
              help: 'for ${tableDate(_date)}${_kept.isNotEmpty ? ' · ${_plural(_kept.length, 'upload')} kept' : ''}'),
        ])
      else if (_kind == 'stock')
        Stats([
          Stat('Counted', '${cs?['rows'] ?? 0}', help: n(cs?['stores']) > 0 ? '${n(cs!['rows']) == 1 ? 'item' : 'items'} in ${_plural(n(cs['stores']).toInt(), 'store')}' : 'type the rows below'),
          Stat('Differences', '${cs?['diffs'] ?? 0}', figureColor: n(cs?['diffs']) > 0 ? C.warning : null, help: 'counted ≠ MOIS'),
          Stat('To type', '${cs?['toType'] ?? 0}', figureColor: n(cs?['toType']) > 0 ? C.warning : null, help: 'red boxes'),
        ])
      else
        Stats([
          Stat('Sales', '${ss?['sales'] ?? 0}', help: ss != null ? '${_plural(n(ss['rows']).toInt(), 'row')}${'${ss['span'] ?? ''}'.isNotEmpty ? ' · ${ss['span']}' : ''}' : 'type the rows below'),
          Stat('Value', 'Tsh ${formatAmount(n(ss?['value']))}', help: 'paid Tsh ${formatAmount(n(ss?['paid']))}'),
          Stat('To type', '${ss?['toType'] ?? 0}', figureColor: n(ss?['toType']) > 0 ? C.warning : null, help: 'red boxes'),
        ]),
      const SizedBox(height: 8),
      SlideRow(children: [for (final (k, l) in _kinds) Chip2(l, on: _kind == k, onTap: () => setState(() { _kind = k; _error = ''; }))]),
      const SizedBox(height: 8),

      // ---- the pages, kept with the day ----
      CardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: 74,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              if (_files.isEmpty)
                Container(width: 64, decoration: BoxDecoration(color: t.soft, borderRadius: BorderRadius.circular(8)), child: Icon(LucideIcons.fileImage, color: t.textMuted)),
              for (final (i, f) in _files.indexed)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Stack(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: f.isImage
                          ? Image.memory(f.bytes, width: 64, height: 74, fit: BoxFit.cover)
                          : Container(width: 64, height: 74, color: t.soft, alignment: Alignment.center, child: const Text('PDF', style: TextStyle(fontWeight: FontWeight.w700))),
                    ),
                    Positioned(
                      right: 0, top: 0,
                      child: InkWell(
                        onTap: () => setState(() => _files.removeAt(i)),
                        child: Container(decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle), padding: const EdgeInsets.all(2), child: const Icon(LucideIcons.x, size: 14, color: Colors.white)),
                      ),
                    ),
                  ]),
                ),
            ]),
          ),
          const SizedBox(height: 6),
          Text(_files.isNotEmpty ? _plural(_files.length, 'page') : 'No photo yet', style: const TextStyle(fontWeight: FontWeight.w700)),
          PlHelp(_files.isNotEmpty ? 'Kept with the day when you save.'
              : _kind == 'production' ? 'Photo or PDF of the report; paste its text below.' : _kind == 'stock' ? 'Photos of the count sheet; type the rows below.' : 'Photos of the sales book; type the rows below.'),
          const SizedBox(height: 8),
          DateField(
            label: _kind == 'past_sales' ? 'Day the pages were uploaded' : _kind == 'stock' ? 'Day of the count' : 'Day of the report',
            value: _date, last: today, onChange: (v) { setState(() => _date = v); _loadDay(); },
          ),
          if (_kind == 'production' && _readDate != null && _readDate != _date) PlHelp('The report says ${dateText(_readDate)}.', color: C.warning),
          const SizedBox(height: 8),
          Wrap(spacing: 6, runSpacing: 6, children: [
            OutlinedButton.icon(onPressed: () => _addPages('camera'), icon: const Icon(LucideIcons.camera, size: 15), label: const Text('Camera')),
            OutlinedButton.icon(onPressed: () => _addPages('gallery'), icon: const Icon(LucideIcons.image, size: 15), label: const Text('Gallery')),
            OutlinedButton.icon(onPressed: () => _addPages('pdf'), icon: const Icon(LucideIcons.fileText, size: 15), label: const Text('PDF')),
            // a written report → one PDF, shared through WhatsApp, email … (2026-11-26, the user)
            FilledButton.tonalIcon(onPressed: () => _addPages('scan'), icon: const Icon(LucideIcons.scanLine, size: 15), label: const Text('Scan to PDF')),
          ]),
        ]),
      ),

      if (_kind == 'stock')
        _CountGrid(key: ValueKey('count$branchId'), refs: refs, day: _date, keep: keep, onStats: (s) => setState(() => _countStats = s), onDone: () { setState(_cleared); _loadDay(); })
      else if (_kind != 'production')
        _SalesGrid(key: ValueKey(_kind), refs: refs, day: _date, past: _kind == 'past_sales', keep: keep, onStats: (s) => setState(() => _salesStats = s))
      else
        ..._production(t, refs, nBatches),

      if (_kept.isNotEmpty)
        CardBox(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Kept for ${dateText(_date)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            for (final u in _kept)
              Row(children: [
                if (u['file_path'] != null)
                  TextButton(onPressed: () => _openKept(u), child: Text('${u['file_name'] ?? 'Photo'}', overflow: TextOverflow.ellipsis))
                else
                  const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text('Text only')),
                Expanded(child: PlHelp(' · ${_kinds.where((k) => k.$1 == u['kind']).firstOrNull?.$2 ?? ''} · ${timeText(u['created_at'])}')),
              ]),
          ]),
        ),
    ]);
  }

  String timeText(Object? v) {
    final d = DateTime.tryParse('${v ?? ''}')?.toLocal();
    return d == null ? '' : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Widget _red(bool on, Widget child) => _tried && on
      ? Container(decoration: BoxDecoration(border: Border.all(color: C.error, width: 1.5), borderRadius: BorderRadius.circular(6)), child: child)
      : child;

  Widget _pick(String label, String value, List<(String, String)> options, bool missing, ValueChanged<String> onChange) => _red(
        missing,
        DropdownButtonFormField<String>(
          initialValue: options.any((o) => o.$1 == value) ? value : '', isExpanded: true, decoration: InputDecoration(isDense: true, labelText: label),
          items: [const DropdownMenuItem(value: '', child: Text('Choose…')), for (final (v, l) in options) DropdownMenuItem(value: v, child: Text(l, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => onChange(v ?? ''),
        ),
      );

  Widget _numField(String label, TextEditingController c, bool missing) => _red(
        missing,
        TextField(controller: c, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(isDense: true, labelText: label)),
      );

  List<Widget> _production(Tokens t, Refs refs, int nBatches) {
    final batches = _batches;
    final products = [for (final p in carried) (p.id, p.name)];
    return [
      CardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: _text, minLines: 6, maxLines: 14, decoration: const InputDecoration(labelText: "The report's text (as sent on WhatsApp)", hintText: 'RIPOTI YA … TAREHE …\nUZALISHAJI WA …\nPcs … Cem …\n…', alignLabelWithHint: true)),
          const SizedBox(height: 8),
          Row(children: [
            OutlinedButton(onPressed: _text.text.trim().isEmpty ? null : _read, child: Text(batches != null ? 'Read again' : 'Read the report')),
            if (batches != null) const Expanded(child: Padding(padding: EdgeInsets.only(left: 8), child: PlHelp('Reading again replaces what you typed below.'))),
          ]),
        ]),
      ),
      if (batches != null) ...[
        if (already > 0) Alert('MOIS already has ${formatAmount(already)} pieces for ${dateText(_date)}. Check these aren\'t the same batches.', tone: Tone.warning),
        const SectionTitle('Production'),
        if (batches.isEmpty) const PlHelp('No production in the report.'),
        for (final b in batches)
          () {
            final miss = missingOf(b);
            final main = productOf(b.productId);
            return CardBox(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: PlHelp('"${b.readName}" →')),
                  IconButton(tooltip: 'Not this batch', onPressed: () => setState(() => batches.remove(b)), icon: const Icon(LucideIcons.trash2, size: 16)),
                ]),
                _pick('Product', b.productId, products, miss['product']!, (v) => setState(() { b.productId = v; b.colorId = ''; b.machineId = ''; })),
                if (main?.colorIds.isNotEmpty ?? false) ...[
                  const SizedBox(height: 8),
                  _pick('Colour', b.colorId, [for (final id in main!.colorIds) (id, refs.colour(id))], miss['colour']!, (v) => setState(() => b.colorId = v)),
                ],
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _numField('Pieces', b.pieces, miss['pieces']!)),
                  const SizedBox(width: 8),
                  Expanded(child: _numField('Cement (bags)', b.bags, miss['bags']!)),
                ]),
                const SizedBox(height: 8),
                _pick('Team', b.teamId, [for (final tm in teams) ('${tm['id']}', '${tm['name']} (${membersOf('${tm['id']}').length})')], miss['team']!, (v) => setState(() => b.teamId = v)),
                if (b.people != null) PlHelp('read: watu ${qtyText(b.people)}'),
                const SizedBox(height: 8),
                _pick('Machine', b.machineId, [for (final m in machinesFor(b.productId)) ('${m['id']}', '${m['name']}')], miss['machine']!, (v) => setState(() => b.machineId = v)),
                for (final l in b.leftovers) ...[
                  const Divider(height: 18),
                  Row(children: [
                    Expanded(child: PlHelp('↳ mabaki "${l.readName}" → · same batch, no cement of its own')),
                    IconButton(tooltip: 'Remove leftover', onPressed: () => setState(() => b.leftovers.remove(l)), icon: const Icon(LucideIcons.trash2, size: 16)),
                  ]),
                  Row(children: [
                    Expanded(flex: 3, child: _pick('Leftover product', l.productId, [for (final p in carried.where((p) => p.id != b.productId)) (p.id, p.name)], l.productId.isEmpty, (v) => setState(() => l.productId = v))),
                    const SizedBox(width: 8),
                    Expanded(flex: 2, child: _numField('Pieces', l.pieces, !_whole(l.pieces.text))),
                  ]),
                ],
              ]),
            );
          }(),
        const SectionTitle('Cement and electricity'),
        CardBox(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Expanded(child: Text('Cement in store (bags)')),
              Text(_cementStore != null ? formatAmount(_cementStore!) : 'not in the report', style: TextStyle(fontWeight: FontWeight.w700, color: _cementStore == null ? t.textMuted : null)),
            ]),
            PlHelp('MOIS: ${_facts?['cementStore'] != null ? '${formatAmount(n(_facts!['cementStore']))}${_cementStore != null && (_cementStore! - n(_facts!['cementStore'])).abs() >= 0.5 ? ' · differs by ${formatAmount((_cementStore! - n(_facts!['cementStore'])).abs())}' : ''}' : '—'}'),
            for (final m in _readMeters) ...[
              const Divider(height: 20),
              Row(children: [
                Expanded(child: PlHelp('"${m.readName}" →')),
                IconButton(tooltip: 'Remove meter', onPressed: () => setState(() => _readMeters.remove(m)), icon: const Icon(LucideIcons.trash2, size: 16)),
              ]),
              _pick('Meter', m.meterId, [for (final x in _meters) ('${x['id']}', '${x['name']}')], meterMissing(m), (v) => setState(() => m.meterId = v)),
              const SizedBox(height: 8),
              Row(children: [
                for (final (s, label, c) in [('morning', 'Morning', m.morning), ('evening', 'Evening', m.evening)])
                  Expanded(child: Padding(
                    padding: EdgeInsets.only(right: s == 'morning' ? 8 : 0),
                    child: had(m.meterId, s) != null
                        ? InputDecorator(decoration: InputDecoration(isDense: true, labelText: label), child: Text('${formatAmount(had(m.meterId, s)!)} in MOIS', style: TextStyle(color: t.textMuted)))
                        : _numField(label, c, false),
                  )),
              ]),
              if (_num(m.morning.text) != null && _num(m.evening.text) != null) PlHelp('${formatAmount(_num(m.morning.text)! - _num(m.evening.text)!)} units used'),
            ],
          ]),
        ),
      ],
      if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
      if (batches != null) ...[
        const PlHelp('Opens in Production, one batch at a time.'),
        const SizedBox(height: 6),
        Row(children: [
          OutlinedButton(onPressed: () => setState(() { _batches = null; _tried = false; _error = ''; }), child: const Text('Cancel')),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: _busy ? null : _saveProduction, child: Text(_busy ? 'Saving…' : nBatches > 0 ? 'Save and open ${_plural(nBatches, 'batch', 'batches')}' : 'Save readings'))),
        ]),
        const SizedBox(height: 10),
      ],
    ];
  }
}

// ======================= Stock count =======================
class _CRow {
  _CRow(this.warehouseId);
  String warehouseId, key = '', colorId = '', unitId = '';
  final counted = TextEditingController();
}

bool _holdsProducts(Store? w) => w?.type == 'finished_goods' || w?.type == 'wip';
// the yard first, then the shop, the curing places, then the material stores
int _rank(Store w) => w.type == 'finished_goods' ? (w.receivesProduction ? 0 : 1) : w.type == 'wip' ? 2 : 3;

class _CountGrid extends StatefulWidget {
  const _CountGrid({super.key, required this.refs, required this.day, required this.keep, required this.onStats, required this.onDone});
  final Refs refs;
  final String day;
  final Future<void> Function(String kind, String? text) keep;
  final ValueChanged<Json> onStats;
  final VoidCallback onDone;
  @override
  State<_CountGrid> createState() => _CountGridState();
}

class _CountGridState extends State<_CountGrid> {
  Refs get refs => widget.refs;
  String get branchId => session.branchId;
  late final List<Store> stores = refs.warehouses
      .where((w) => w.status == 'active' && w.branchId == branchId && session.canAt(movementTypes['count']!.perm, w.branchId, w.id)).toList()
    ..sort((a, b) => _rank(a) != _rank(b) ? _rank(a) - _rank(b) : a.name.compareTo(b.name));
  late final List<_CRow> rows = [_CRow(stores.firstOrNull?.id ?? '')];
  Map<String, double>? _bal; // '<store>|<m:id or p:id>[|c:<colour>]' → quantity on the count day
  bool _tried = false, _busy = false;
  String _error = '', _loadedDay = '';

  @override
  void initState() { super.initState(); _loadBal(); }

  @override
  void didUpdateWidget(_CountGrid old) {
    super.didUpdateWidget(old);
    if (old.day != widget.day) _loadBal();
  }

  Future<void> _loadBal() async {
    final day = widget.day;
    _loadedDay = day;
    setState(() => _bal = null);
    try {
      final data = day.compareTo(session.today) < 0
          ? await db.rpc('stock_balances_as_of', params: {'p_date': day})
          : await db.from('stock_balances').select('warehouse_id, material_id, product_id, color_id, quantity');
      if (!mounted || _loadedDay != day) return;
      setState(() => _bal = {
            for (final b in data as List)
              '${b['warehouse_id']}|${b['material_id'] != null ? 'm:${b['material_id']}' : 'p:${b['product_id']}'}${b['color_id'] != null ? '|c:${b['color_id']}' : ''}': n(b['quantity']).toDouble(),
          });
      _stats();
    } catch (_) {
      if (mounted) setState(() => _bal = {});
    }
  }

  CategoryTools get cats => CategoryTools(refs.categoryRows);
  List<Item> get all => refs.items.values.where((i) => i.status == 'active').toList();
  List<Item> get products => all.where((i) => i.isProduct && (refs.carriedByBranch[branchId]?.contains(i.id) ?? false)).toList()..sort(productOrder(cats));
  List<Item> get materials => all.where((i) => !i.isProduct && (i.branchId == null || i.branchId == branchId)).toList()..sort(byMaterialOrder);
  Store? storeOf(_CRow r) => refs.store(r.warehouseId);
  List<Item> itemsFor(_CRow r) => _holdsProducts(storeOf(r)) ? products : materials;
  Item? itemOf(_CRow r) => refs.items[r.key];
  double factorOf(_CRow r) => itemOf(r)?.units.where((u) => u.id == r.unitId).firstOrNull?.factor ?? 1;
  /// in MOIS, in the row's unit
  double? inMois(_CRow r) {
    final it = itemOf(r);
    if (it == null || _bal == null || r.warehouseId.isEmpty) return null;
    return (_bal!['${r.warehouseId}|${r.key}${r.colorId.isNotEmpty ? '|c:${r.colorId}' : ''}'] ?? 0) / factorOf(r);
  }

  Map<String, bool> missingOf(_CRow r) => {
        'store': r.warehouseId.isEmpty,
        'item': r.key.isEmpty,
        'colour': r.key.isNotEmpty && (itemOf(r)?.colorIds.isNotEmpty ?? false) && r.colorId.isEmpty,
        'counted': !(_num(r.counted.text) != null && _num(r.counted.text)! >= 0),
      };
  String dupKey(_CRow r) => '${r.warehouseId}|${r.key}|${r.colorId}';
  Set<String> get dups {
    final c = <String, int>{};
    for (final r in rows.where((r) => r.key.isNotEmpty)) { c[dupKey(r)] = (c[dupKey(r)] ?? 0) + 1; }
    return {for (final e in c.entries) if (e.value > 1) e.key};
  }

  int get toType => rows.fold(0, (t, r) => t + missingOf(r).values.where((v) => v).length);

  void _stats() => widget.onStats({
        'rows': rows.where((r) => r.key.isNotEmpty).length,
        'stores': {for (final r in rows.where((r) => r.warehouseId.isNotEmpty && r.key.isNotEmpty)) r.warehouseId}.length,
        'toType': toType,
        'diffs': rows.where((r) => r.key.isNotEmpty && _num(r.counted.text) != null && inMois(r) != null && (_num(r.counted.text)! - inMois(r)!).abs() > 1e-9).length,
      });

  void _set(void Function() f) { setState(() { _error = ''; f(); }); _stats(); }

  Future<void> _save() async {
    setState(() { _tried = true; _error = ''; });
    if (rows.isEmpty) { setState(() => _error = 'Add the counted items first.'); return; }
    if (toType > 0) { setState(() => _error = 'Fill the ${_plural(toType, 'red box', 'red boxes')} first.'); return; }
    if (dups.isNotEmpty) { setState(() => _error = 'An item is on the sheet twice for the same store: remove one row, or add the two counts together.'); return; }
    setState(() => _busy = true);
    try {
      await widget.keep('stock', null);
      // one count a store, opened in Stock › Count one after another
      final byStore = <String, List<Map<String, String>>>{};
      for (final r in rows) {
        (byStore[r.warehouseId] ??= []).add({'key': r.key, 'colorId': r.colorId, 'unitId': r.unitId, 'quantity': _n(_num(r.counted.text))});
      }
      final bal = {for (final e in (_bal ?? {}).entries) e.key: e.value};
      var i = 0;
      for (final e in byStore.entries) {
        i++;
        if (!mounted) return;
        await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => MovementPage(
              type: 'count', refs: refs, balances: bal, defaultWarehouseId: e.key,
              prefill: (date: widget.day, lines: e.value, note: 'From the uploaded count sheet${byStore.length > 1 ? ': store $i of ${byStore.length}' : ''}. Check, then post.'),
            )));
      }
      if (mounted) {
        setState(() { rows..clear()..add(_CRow(stores.firstOrNull?.id ?? '')); _tried = false; });
        widget.onDone();
        _loadBal();
      }
    } catch (e) {
      _error = dbError(e, "We couldn't save the count sheet. Please try again.");
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _red(bool on, Widget child) => _tried && on
      ? Container(decoration: BoxDecoration(border: Border.all(color: C.error, width: 1.5), borderRadius: BorderRadius.circular(6)), child: child)
      : child;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    if (stores.isEmpty) return const PlHelp("You can't count stock at any store of this branch.");
    final d0 = dups;
    final used = {for (final r in rows.where((r) => r.warehouseId.isNotEmpty && r.key.isNotEmpty)) r.warehouseId}.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SectionTitle('What was counted'),
      for (final r in rows)
        () {
          final miss = missingOf(r);
          final it = itemOf(r);
          final m = inMois(r);
          final c = _num(r.counted.text);
          final d = c != null && m != null ? c - m : null;
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: d0.contains(dupKey(r)) ? C.warning : t.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: _red(miss['store']!, DropdownButtonFormField<String>(
                  initialValue: r.warehouseId, isExpanded: true, decoration: const InputDecoration(isDense: true, labelText: 'Store'),
                  items: [const DropdownMenuItem(value: '', child: Text('Choose…')), for (final w in stores) DropdownMenuItem(value: w.id, child: Text(w.name, overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => _set(() {
                    final changesKind = _holdsProducts(refs.store(v)) != _holdsProducts(storeOf(r));
                    r.warehouseId = v ?? '';
                    if (changesKind) { r.key = ''; r.colorId = ''; r.unitId = ''; }
                  }),
                ))),
                IconButton(tooltip: 'Remove row', onPressed: () => _set(() => rows.remove(r)), icon: const Icon(LucideIcons.trash2, size: 16)),
              ]),
              const SizedBox(height: 8),
              _red(miss['item']!, DropdownButtonFormField<String>(
                key: ValueKey('item${r.hashCode}${r.warehouseId}'),
                initialValue: itemsFor(r).any((x) => x.key == r.key) ? r.key : '', isExpanded: true, decoration: const InputDecoration(isDense: true, labelText: 'Item'),
                items: [const DropdownMenuItem(value: '', child: Text('Choose…')), for (final x in itemsFor(r)) DropdownMenuItem(value: x.key, child: Text(x.name, overflow: TextOverflow.ellipsis))],
                onChanged: r.warehouseId.isEmpty ? null : (v) => _set(() { r.key = v ?? ''; r.colorId = ''; r.unitId = refs.items[r.key]?.mainUnitId ?? refs.items[r.key]?.stockUnitId ?? ''; }),
              )),
              if (it?.colorIds.isNotEmpty ?? false) ...[
                const SizedBox(height: 8),
                _red(miss['colour']!, SlideRow(children: [for (final id in it!.colorIds) Chip2(refs.colour(id), on: r.colorId == id, onTap: () => _set(() => r.colorId = id))])),
              ],
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _red(miss['counted']!, TextField(controller: r.counted, onChanged: (_) => _set(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, labelText: 'Counted')))),
                const SizedBox(width: 8),
                if (it != null && it.units.length > 1)
                  SizedBox(width: 100, child: DropdownButtonFormField<String>(
                    initialValue: it.units.any((u) => u.id == r.unitId) ? r.unitId : it.units.first.id, isExpanded: true, decoration: const InputDecoration(isDense: true, labelText: 'Unit'),
                    items: [for (final u in it.units) DropdownMenuItem(value: u.id, child: Text(refs.unit(u.id)))],
                    onChanged: (v) => _set(() => r.unitId = v ?? ''),
                  ))
                else if (it != null)
                  PlHelp(refs.unit(r.unitId)),
              ]),
              if (it != null && r.warehouseId.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Row(children: [
                    PlHelp('In MOIS ${m == null ? '…' : qtyText((m * 1000).roundToDouble() / 1000)}'),
                    const Spacer(),
                    if (d != null) Text('${d > 0 ? '+' : ''}${qtyText((d * 1000).roundToDouble() / 1000)}', style: TextStyle(fontWeight: FontWeight.w700, color: d.abs() < 1e-9 ? t.textMuted : C.warning)),
                  ]),
                ),
            ]),
          );
        }(),
      Align(alignment: Alignment.centerLeft, child: TextButton.icon(
        onPressed: () => _set(() => rows.add(_CRow(rows.lastOrNull?.warehouseId ?? stores.firstOrNull?.id ?? ''))),
        icon: const Icon(LucideIcons.plus, size: 15), label: const Text('Add row'),
      )),
      const PlHelp('Only the rows here are counted; other items in the stores are left as they are.'),
      if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
      const SizedBox(height: 6),
      PlHelp('Opens Stock › Count filled in${used > 1 ? ', one store at a time ($used)' : ''}.'),
      const SizedBox(height: 6),
      FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save and open the count')),
      const SizedBox(height: 10),
    ]);
  }
}

// ======================= Sales sheet / past sales =======================
class _SRow {
  _SRow(this.date);
  String date, productId = '', colorId = '', accountId = '';
  final receipt = TextEditingController(), buyer = TextEditingController(), phone = TextEditingController(),
      qty = TextEditingController(), price = TextEditingController(), paid = TextEditingController(), efd = TextEditingController();
  bool get used => productId.isNotEmpty || (_num(qty.text) ?? 0) != 0 || buyer.text.trim().isNotEmpty || (_num(paid.text) ?? 0) != 0 || receipt.text.trim().isNotEmpty;
}

class _Sale {
  _Sale(this.key, this.first);
  final String key;
  final _SRow first;
  final List<_SRow> rows = [];
  double value = 0, paid = 0;
}

class _SalesGrid extends StatefulWidget {
  const _SalesGrid({super.key, required this.refs, required this.day, required this.past, required this.keep, required this.onStats});
  final Refs refs;
  final String day;
  final bool past;
  final Future<void> Function(String kind, String? text) keep;
  final ValueChanged<Json> onStats;
  @override
  State<_SalesGrid> createState() => _SalesGridState();
}

class _SalesGridState extends State<_SalesGrid> {
  Refs get refs => widget.refs;
  String get branchId => session.branchId;
  String get today => session.today;
  late final List<_SRow> rows = [for (var i = 0; i < 5; i++) _SRow(widget.past ? '' : widget.day)];
  List<Json> _customers = [], _accounts = [];
  Map<String, double> _listPrice = {}; // product id → lowest price as paid (per m² or piece)
  bool _tried = false, _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
    WidgetsBinding.instance.addPostFrameCallback((_) => _stats());
  }

  @override
  void didUpdateWidget(_SalesGrid old) {
    super.didUpdateWidget(old);
    // the daily sheet is one day: its rows follow the day chosen above
    if (!widget.past && old.day != widget.day) { for (final r in rows) { r.date = widget.day; } }
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait<dynamic>([
        db.from('customers').select('id, name, phone, status').order('name', ascending: true),
        db.from('payment_accounts').select('id, name, status, branch_id').eq('branch_id', branchId).order('display_order', ascending: true).order('name', ascending: true),
        db.from('product_branch_pricing').select('product_id, price_per_sqm_inclusive, price_per_unit_inclusive, is_available').eq('branch_id', branchId),
      ]);
      final m = <String, double>{};
      for (final x in _l(r[2])) {
        if (x['is_available'] != true) continue;
        final sqm = refs.unit(refs.items['p:${x['product_id']}']?.stockUnitId).toUpperCase() == 'SQM';
        final v = n(sqm ? x['price_per_sqm_inclusive'] : x['price_per_unit_inclusive']).toDouble();
        if (v > 0) m['${x['product_id']}'] = m['${x['product_id']}'] == null ? v : (m['${x['product_id']}']! < v ? m['${x['product_id']}']! : v);
      }
      if (mounted) {
        setState(() {
          _customers = _l(r[0]).where((x) => x['status'] == 'active').toList();
          _accounts = _l(r[1]).where((x) => x['status'] == 'active').toList();
          _listPrice = m;
        });
        _stats();
      }
    } catch (_) {}
  }

  List<Item> get carried => refs.items.values.where((i) => i.kind == 'product' && i.status == 'active' && (refs.carriedByBranch[branchId]?.contains(i.id) ?? false)).toList()..sort((a, b) => a.name.compareTo(b.name));
  Item? productOf(String id) => refs.items['p:$id'];
  Json? customerOf(String name) => _customers.where((c) => '${c['name']}'.trim().toLowerCase() == name.trim().toLowerCase()).firstOrNull;

  /// rows → sales: same date and receipt number = one sale; the first row carries the buyer, account and EFD
  List<_Sale> get sales {
    final out = <_Sale>[], byKey = <String, _Sale>{};
    for (final r in rows.where((r) => r.used)) {
      final k = r.receipt.text.trim().isNotEmpty ? '${r.date}|${r.receipt.text.trim().toLowerCase()}' : '${r.hashCode}';
      final s = byKey.putIfAbsent(k, () { final s = _Sale(k, r); out.add(s); return s; });
      s.rows.add(r);
    }
    for (final s in out) {
      s.value = _r2(s.rows.fold<double>(0, (t, r) => t + (_num(r.qty.text) ?? 0) * (_num(r.price.text) ?? _listPrice[r.productId] ?? 0)));
      s.paid = _r2(s.rows.fold<double>(0, (t, r) => t + (_num(r.paid.text) ?? 0)));
    }
    return out;
  }

  Map<String, bool> missingOf(_SRow r, List<_Sale> ss) {
    if (!r.used) return {};
    final s = ss.where((x) => x.rows.contains(r)).first;
    final first = s.first == r;
    return {
      'date': r.date.isEmpty || r.date.compareTo(today) > 0,
      'product': r.productId.isEmpty,
      'colour': r.productId.isNotEmpty && (productOf(r.productId)?.colorIds.isNotEmpty ?? false) && r.colorId.isEmpty,
      'qty': !((_num(r.qty.text) ?? 0) > 0),
      'account': first && s.paid > 0 && r.accountId.isEmpty,
      'over': first && s.paid > s.value + 0.01,
    };
  }

  int toTypeOf(List<_Sale> ss) => rows.fold(0, (t, r) => t + missingOf(r, ss).values.where((v) => v).length);

  void _stats() {
    final ss = sales;
    final dates = [for (final s in ss) if (s.first.date.isNotEmpty) s.first.date]..sort();
    widget.onStats({
      'sales': ss.length, 'rows': rows.where((r) => r.used).length,
      'value': _r2(ss.fold<double>(0, (t, s) => t + s.value)), 'paid': _r2(ss.fold<double>(0, (t, s) => t + s.paid)), 'toType': toTypeOf(ss),
      'span': dates.isEmpty ? '' : dates.first == dates.last ? tableDate(dates.first) : '${tableDate(dates.first)} – ${tableDate(dates.last)}',
    });
  }

  void _set(void Function() f) { setState(() { _error = ''; f(); }); _stats(); }

  Future<void> _save() async {
    final ss = sales;
    setState(() { _tried = true; _error = ''; });
    if (ss.isEmpty) { setState(() => _error = 'Type at least one row.'); return; }
    final toType = toTypeOf(ss);
    if (toType > 0) { setState(() => _error = 'Fill the ${_plural(toType, 'red box', 'red boxes')} first.'); return; }
    setState(() => _busy = true);
    try {
      // the grid as text, kept with the pages
      String nameOf(String id) => productOf(id)?.name ?? '';
      final text = [
        'Date\tReceipt\tCustomer\tPhone\tProduct\tColour\tQty\tPrice\tPaid\tAccount\tEFD',
        for (final r in rows.where((r) => r.used))
          [r.date, r.receipt.text, r.buyer.text, r.phone.text, nameOf(r.productId), r.colorId.isNotEmpty ? refs.colour(r.colorId) : '', r.qty.text, r.price.text, r.paid.text,
            '${_accounts.where((a) => a['id'] == r.accountId).firstOrNull?['name'] ?? ''}', r.efd.text].join('\t'),
      ].join('\n');
      await widget.keep(widget.past ? 'past_sales' : 'sales', text);
      final queue = [
        for (final (i, s) in ss.indexed)
          () {
            final f = s.first, c = customerOf(f.buyer.text);
            return {
              'sale_date': f.date,
              if (c != null) 'customer_id': c['id'] else ...{'walk_in_name': f.buyer.text.trim(), 'walk_in_phone': f.phone.text.trim()},
              'lines': [for (final r in s.rows) {'productId': r.productId, 'colorId': r.colorId, 'quantity': _n(_num(r.qty.text)), 'price': _num(r.price.text) != null ? _n(_num(r.price.text)) : ''}],
              'payments': s.paid > 0 ? [{'accountId': f.accountId, 'amount': _n(s.paid), 'receiptNo': f.receipt.text.trim()}] : [],
              'efd_receipt_no': f.efd.text.trim(),
              'banner': 'From the uploaded sales book: sale ${i + 1} of ${ss.length}${f.receipt.text.trim().isNotEmpty ? ', receipt ${f.receipt.text.trim()}' : ''}.',
            };
          }(),
      ];
      final p = await SharedPreferences.getInstance();
      await p.setString('mois.upload.sales.${session.organization!['id']}.$branchId', jsonEncode({'at': 0, 'sales': queue}));
      if (mounted) Shell.of(context).go('/sales');
      return;
    } catch (e) {
      _error = dbError(e, "We couldn't keep the pages. Please try again.");
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _red(bool on, Widget child) => _tried && on
      ? Container(decoration: BoxDecoration(border: Border.all(color: C.error, width: 1.5), borderRadius: BorderRadius.circular(6)), child: child)
      : child;
  Widget _field(String label, TextEditingController c, {bool number = false, bool missing = false, String? hint, TextInputType? type}) => _red(
        missing,
        TextField(controller: c, onChanged: (_) => _set(() {}), keyboardType: type ?? (number ? const TextInputType.numberWithOptions(decimal: true) : null), decoration: InputDecoration(isDense: true, labelText: label, hintText: hint)),
      );

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final ss = sales;
    final products = carried;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PlHelp('Same ${widget.past ? 'date and ' : ''}receipt = one sale. Empty price = price list.'),
      const SizedBox(height: 8),
      for (final (i, r) in rows.indexed)
        () {
          final miss = missingOf(r, ss);
          final s = ss.where((x) => x.rows.contains(r)).firstOrNull;
          final same = s != null && s.first != r; // a later row of the same sale
          final main = productOf(r.productId);
          final lp = _listPrice[r.productId];
          final below = lp != null && _num(r.price.text) != null && _num(r.price.text)! < lp;
          final buyer = r.buyer.text.trim();
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: t.border)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Text('Row ${i + 1}', style: const TextStyle(fontWeight: FontWeight.w700)),
                if (same) const PlHelp('  · same sale ↑'),
                const Spacer(),
                IconButton(tooltip: 'Remove row ${i + 1}', onPressed: () => _set(() { rows.removeAt(i); if (rows.isEmpty) rows.add(_SRow(widget.past ? '' : widget.day)); }), icon: const Icon(LucideIcons.trash2, size: 16)),
              ]),
              Row(children: [
                if (widget.past) ...[
                  Expanded(child: _red(miss['date'] ?? false, DateField(label: 'Date', value: r.date, last: today, onChange: (v) => _set(() => r.date = v)))),
                  const SizedBox(width: 8),
                ],
                Expanded(child: _field('Receipt', r.receipt)),
              ]),
              if (!same) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: Autocomplete<String>(
                    initialValue: r.buyer.value,
                    optionsBuilder: (v) => v.text.trim().isEmpty ? const [] : [for (final c in _customers) if ('${c['name']}'.toLowerCase().contains(v.text.toLowerCase())) '${c['name']}'],
                    onSelected: (v) => _set(() { r.buyer.text = v; r.phone.text = '${customerOf(v)?['phone'] ?? r.phone.text}'; }),
                    fieldViewBuilder: (ctx, c, focus, submit) => TextField(controller: c, focusNode: focus, onChanged: (v) => _set(() => r.buyer.text = v), decoration: InputDecoration(isDense: true, labelText: 'Customer', hintText: 'Walk-in', helperText: buyer.isEmpty ? null : customerOf(buyer) != null ? 'customer' : 'walk-in')),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: _field('Phone', r.phone, type: TextInputType.phone)),
                ]),
              ],
              const SizedBox(height: 8),
              _red(miss['product'] ?? false, DropdownButtonFormField<String>(
                initialValue: r.productId, isExpanded: true, decoration: const InputDecoration(isDense: true, labelText: 'Product'),
                items: [const DropdownMenuItem(value: '', child: Text('Choose…')), for (final p in products) DropdownMenuItem(value: p.id, child: Text(p.name, overflow: TextOverflow.ellipsis))],
                onChanged: (v) => _set(() { r.productId = v ?? ''; r.colorId = ''; }),
              )),
              if (main?.colorIds.isNotEmpty ?? false) ...[
                const SizedBox(height: 8),
                _red(miss['colour'] ?? false, SlideRow(children: [for (final id in main!.colorIds) Chip2(refs.colour(id), on: r.colorId == id, onTap: () => _set(() => r.colorId = id))])),
              ],
              const SizedBox(height: 8),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _field('Qty', r.qty, number: true, missing: miss['qty'] ?? false)),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _field('Price (TZS)', r.price, number: true, hint: lp != null ? formatAmount(lp) : null),
                  // below the price list: Record sale asks for the reason
                  if (below) const PlHelp('discount', color: C.warning),
                ])),
                const SizedBox(width: 8),
                Expanded(child: _field('Paid (TZS)', r.paid, number: true, missing: miss['over'] ?? false)),
              ]),
              if (!same) ...[
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: _red(miss['account'] ?? false, DropdownButtonFormField<String>(
                    initialValue: r.accountId, isExpanded: true, decoration: const InputDecoration(isDense: true, labelText: 'Account'),
                    items: [DropdownMenuItem(value: '', child: Text(_accounts.isNotEmpty ? 'Choose…' : 'No accounts')), for (final a in _accounts) DropdownMenuItem(value: '${a['id']}', child: Text('${a['name']}', overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => _set(() => r.accountId = v ?? ''),
                  ))),
                  const SizedBox(width: 8),
                  Expanded(child: _field('EFD no', r.efd)),
                ]),
              ],
            ]),
          );
        }(),
      Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(
        onPressed: () => _set(() {
          final last = rows.where((r) => r.used).lastOrNull?.date ?? '';
          rows.addAll([for (var i = 0; i < 5; i++) _SRow(widget.past ? last : widget.day)]);
        }),
        icon: const Icon(LucideIcons.plus, size: 15), label: const Text('Add 5 rows'),
      )),
      if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
      const SizedBox(height: 6),
      const PlHelp('Opens in Record sale, one at a time.'),
      const SizedBox(height: 6),
      FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : ss.isNotEmpty ? 'Save and open ${_plural(ss.length, 'sale')} in Sales' : 'Save')),
      const SizedBox(height: 10),
    ]);
  }
}
