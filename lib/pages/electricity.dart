import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import 'expense_form.dart' show parseLukuReceipt;
import 'procurement_actions.dart';
import 'reports.dart' show ReportSheet, RCell;

/*
 * Electricity under Expenses — a port of web components/purchases/ElectricityPanel.jsx (072/081/144): each
 * LUKU meter read in the morning (asubuhi) and the evening (jioni); day use = morning − evening, night use =
 * evening − next morning. A top-up: ask for a meter → the branch manager approves → an order → bought, the
 * token recorded and the meter topped up. Readings save on the phone when offline (2026-11-24, the user).
 */
String _units(Object? v) => qtyText((n(v) * 100).roundToDouble() / 100);
double? _num(String v) => v.trim().isEmpty ? null : double.tryParse(v.trim().replaceAll(',', ''));
String _money(Object? v) => formatMoney(n(v), session.currency);
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
double? _avg(List<double> xs) => xs.isEmpty ? null : xs.reduce((a, b) => a + b) / xs.length;
const topupStatus = {
  'waiting': ('Waiting for the branch manager', Tone.warning), 'approved': ('Approved — to order', Tone.info), 'ordered': ('Ordered — to buy', Tone.info),
  'done': ('Bought', Tone.success), 'rejected': ('Turned down', Tone.error), 'cancelled': ('Cancelled', Tone.neutral),
};

Future<bool> _push(BuildContext context, Widget page) async => await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => page)) == true;

class ElectricityPanel extends StatefulWidget {
  const ElectricityPanel({super.key, required this.branchId, this.onOrder});
  final String branchId;
  final void Function(Json request)? onOrder;   // an approved top-up made into an order (Orders)
  @override
  State<ElectricityPanel> createState() => _ElectricityPanelState();
}

class _ElectricityPanelState extends State<ElectricityPanel> {
  String _tab = 'days';
  Json? _data;
  DateTime? _savedAt;
  String _error = '';
  String get branchId => widget.branchId;
  bool get canFix => branchId.isNotEmpty && session.canAt('system.manage', branchId, null);
  bool get canRecord => branchId.isNotEmpty && (session.canAt('procurement.receive', branchId, null) || session.canAt('production.create', branchId, null));

  @override
  void initState() { super.initState(); _load(); }

  @override
  void didUpdateWidget(ElectricityPanel old) {
    super.didUpdateWidget(old);
    if (old.branchId != branchId) _load();
  }

  Future<void> _load() async {
    setState(() => _error = '');
    if (branchId.isEmpty) return setState(() => _data = null);
    try {
      final (j, at) = await offline.load<Json>('electricity:$branchId', () async {
        final r = await Future.wait<dynamic>([
          db.from('power_meters').select('*').eq('branch_id', branchId).order('name', ascending: true),
          db.from('power_daily').select('*').eq('branch_id', branchId).order('day', ascending: false).limit(400),
          db.from('power_readings').select('*').eq('branch_id', branchId).order('read_at', ascending: false).limit(400),
          db.from('power_tokens').select('*').eq('branch_id', branchId).order('loaded_at', ascending: false).limit(200),
          db.from('purchase_requests').select('*, lines:purchase_request_lines!inner(*)').eq('branch_id', branchId).not('lines.meter_id', 'is', null)
              .order('requested_on', ascending: false).limit(100).then<List>((v) => v).catchError((_) => <dynamic>[]),
        ]);
        return {'meters': r[0], 'days': r[1], 'readings': r[2], 'tokens': r[3], 'topups': r[4]};
      });
      if (mounted) setState(() { _data = j; _savedAt = at; });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load electricity. Please try again.");
    }
  }

  Future<void> _then(Future<bool> f) async { if (await f) _load(); }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    if (branchId.isEmpty) return const EmptyState(icon: LucideIcons.zap, title: 'Pick a branch', description: 'Meters are per branch — pick one in the menu.');
    if (_error.isNotEmpty) return ErrorState(_error, onRetry: _load);
    final d = _data;
    if (d == null) return const Skeleton(rows: 4);
    final meters = _l(d['meters']), days = _l(d['days']), readings = _l(d['readings']), tokens = _l(d['tokens']), topups = _l(d['topups']);
    if (meters.isEmpty) return const EmptyState(icon: LucideIcons.zap, title: 'No meters yet', description: "Add the branch's LUKU meters under ⚙ (beside the heading), with the machines each one feeds.");
    String meterName(Object? id) => '${meters.where((m) => m['id'] == id).firstOrNull?['name'] ?? ''}';
    final active = meters.where((m) => m['status'] == 'active').toList();
    final since = iso(DateTime.now().subtract(const Duration(days: 60)));
    final open = topups.where((q) => ['waiting', 'approved', 'ordered'].contains(q['status'])).length;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OfflineNote(_savedAt),
      // each meter a summary card: units left, the last reading, token since, units a cement bag
      for (final m in active)
        Builder(builder: (_) {
          final ds = days.where((x) => x['meter_id'] == m['id'] && '${x['day']}'.compareTo(since) >= 0).toList();
          final working = ds.where((x) => x['day_units'] != null && n(x['cement_bags']) > 0).toList();
          final perBag = working.isEmpty ? null : working.fold<double>(0, (s, x) => s + n(x['day_units'])) / working.fold<double>(0, (s, x) => s + n(x['cement_bags']));
          final last = readings.where((r) => r['meter_id'] == m['id'] && r['status'] == 'recorded').firstOrNull;
          final loadedSince = tokens.where((k) => k['meter_id'] == m['id'] && k['status'] == 'recorded' && (last == null || '${k['loaded_at']}'.compareTo('${last['read_at']}') > 0)).fold<double>(0, (s, k) => s + n(k['units']));
          final idle = ds.where((x) => x['day_units'] != null && !(n(x['cement_bags']) > 0)).toList();
          final workDay = _avg([for (final x in working) n(x['day_units']).toDouble()]), idleDay = _avg([for (final x in idle) n(x['day_units']).toDouble()]);
          final night = _avg([for (final x in ds) if (x['night_units'] != null) n(x['night_units']).toDouble()]);
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: t.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _then(_push(context, _MeterSettings(meter: m, branchId: branchId))),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    PlLabel('${m['name']}'),
                    Text(last != null ? '${_units(last['reading'])} units left' : 'no reading yet', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: Fs.lg)),
                    PlHelp('${last != null ? '${dateText(last['read_on'])} ${last['slot'] == 'morning' ? 'morning' : 'evening'}' : ''}'
                        '${loadedSince > 0 ? ' · +${_units(loadedSince)} token since' : ''}${perBag != null ? ' · ${_units(perBag)} units/bag' : ''}'),
                    PlHelp('Last 60 days: ${working.length} working, ${idle.length} idle days${workDay != null ? ' · ${_units(workDay)} a working day' : ''}'
                        '${idleDay != null ? ' · ${_units(idleDay)} an idle day' : ''}${night != null ? ' · ${_units(night)} a night' : ''}'),
                  ]),
                ),
              ),
            ),
          );
        }),
      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (canRecord) FilledButton(onPressed: () => _then(_push(context, _Readings(meters: active, readings: readings))), child: const Text('Record readings')),
        if (session.canAt('procurement.request', branchId, null)) OutlinedButton(onPressed: () async { if (await _push(context, _Topup(meters: active))) { setState(() => _tab = 'topups'); _load(); } }, child: const Text('Request top-up')),
        const PlHelp('Morning (asubuhi) and evening (jioni).'),
      ]),
      const SizedBox(height: 8),
      PageTabs<String>(tabs: [('days', 'Days'), ('topups', 'Top-ups${open > 0 ? ' ($open)' : ''}'), ('readings', 'Readings'), ('tokens', 'Tokens')], value: _tab, onChange: (v) => setState(() => _tab = v)),
      if (_tab == 'topups') ...[
        if (topups.isEmpty) const PlHelp('No top-ups yet — Request top-up when a meter runs low.'),
        for (final q in topups)
          Builder(builder: (_) {
            final l = _l(q['lines']).first;
            final tok = tokens.where((k) => k['expense_id'] != null && q['status'] == 'done' && k['meter_id'] == l['meter_id'] && '${k['loaded_at']}'.substring(0, 10).compareTo('${q['requested_on']}') >= 0).firstOrNull;
            final (label, tone) = topupStatus[q['status']] ?? ('${q['status']}', Tone.neutral);
            return CardBox(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${tableDate(q['requested_on'])} · ${meterName(l['meter_id'])}', style: const TextStyle(fontWeight: FontWeight.w600))),
                  Badge2(label, tone: tone),
                ]),
                PlHelp([
                  if (l['amount'] != null) _money(l['amount']),
                  if (l['quantity'] != null) '${_units(l['quantity'])} units',
                  if (tok != null) 'got ${_units(tok['units'])}',
                  if ('${q['notes'] ?? ''}'.isNotEmpty) '${q['notes']}',
                  if ('${q['decision_note'] ?? ''}'.isNotEmpty) '${q['decision_note']}',
                ].join(' · ')),
                Wrap(spacing: 6, children: [
                  if (q['status'] == 'waiting' && session.canAt('procurement.approve', '${q['branch_id']}', null)) ...[
                    FilledButton(onPressed: () => _then(_push(context, _Decision(q: q, decision: 'approved'))), child: const Text('Approve')),
                    TextButton(onPressed: () => _then(_push(context, _Decision(q: q, decision: 'rejected'))), child: const Text('Turn down…')),
                  ],
                  if (q['status'] == 'approved' && widget.onOrder != null && session.canAt('procurement.order', '${q['branch_id']}', null))
                    FilledButton(onPressed: () => widget.onOrder!(q), child: const Text('Make order')),
                  if (['approved', 'ordered'].contains(q['status']) && (session.canAt('cash.approve', '${q['branch_id']}', null) || session.canAt('procurement.receive', '${q['branch_id']}', null)))
                    (q['status'] == 'ordered' ? FilledButton.new : TextButton.new)(onPressed: () => _then(buyTopup(context, q, meterName(l['meter_id']))), child: const Text('Bought — record token')),
                ]),
              ]),
            );
          }),
      ] else if (_tab == 'days') ...[
        if (days.isEmpty)
          const PlHelp('Days show once a meter has two readings.')
        else
          ReportSheet(
            head: const ['Day', 'Meter', 'Morning', 'Evening', 'Day use', 'Day (TZS)', 'Night use', 'Night (TZS)', 'Batches', 'Cement bags', 'Units a bag'],
            rows: [
              for (final x in days)
                [
                  _dayCell(x),
                  x['meter_name'],
                  // the day's readings (2026-11-11, the user)
                  for (final slot in ['morning', 'evening'])
                    () {
                      final r = readings.where((y) => y['meter_id'] == x['meter_id'] && y['read_on'] == x['day'] && y['slot'] == slot && y['status'] == 'recorded').firstOrNull;
                      return r != null ? _units(r['reading']) : '';
                    }(),
                  x['day_units'] != null ? _units(x['day_units']) : '',
                  x['day_cost'] != null ? formatAmount(n(x['day_cost'])) : '',
                  x['night_units'] != null ? _units(x['night_units']) : '',
                  x['night_cost'] != null ? formatAmount(n(x['night_cost'])) : '',
                  n(x['batches']) != 0 ? '${n(x['batches']).round()}' : '',
                  n(x['cement_bags']) != 0 ? _units(x['cement_bags']) : '',
                  x['units_per_bag'] != null ? _units(x['units_per_bag']) : n(x['cement_bags']) != 0 ? '' : 'idle',
                ],
            ],
            total: [
              'Total', '', '', '',
              _units(days.fold<double>(0, (s, x) => s + n(x['day_units']))), _money(days.fold<double>(0, (s, x) => s + n(x['day_cost']))),
              _units(days.fold<double>(0, (s, x) => s + n(x['night_units']))), _money(days.fold<double>(0, (s, x) => s + n(x['night_cost']))), '', '', '',
            ],
            firstWidth: 130,
          ),
      ] else if (_tab == 'readings') ...[
        if (readings.isEmpty) const PlHelp('No readings yet.'),
        for (final r in readings)
          Opacity(
            opacity: r['status'] == 'void' ? 0.55 : 1,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${tableDate(r['read_on'])} · ${r['slot'] == 'morning' ? 'Morning' : 'Evening'} · ${meterName(r['meter_id'])}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (r['status'] == 'void') PlHelp('Void — ${r['void_reason'] ?? ''}') else if ('${r['note'] ?? ''}'.isNotEmpty) PlHelp('${r['note']}'),
                  ]),
                ),
                Text(_units(r['reading']), style: const TextStyle(fontWeight: FontWeight.w700)),
                if (r['status'] == 'recorded' && (canFix || canRecord))
                  PopupMenuButton<String>(
                    onSelected: (k) => _then(k == 'fix' ? _push(context, _Fix(row: r, name: meterName(r['meter_id']))) : _push(context, _Void(row: r))),
                    itemBuilder: (_) => [
                      if (canFix) const PopupMenuItem(value: 'fix', child: Text('Edit…')),
                      if (canRecord) const PopupMenuItem(value: 'void', child: Text('Void…')),
                    ],
                  ),
              ]),
            ),
          ),
      ] else ...[
        if (tokens.isEmpty)
          const PlHelp('No tokens yet — Record expense → Electricity.')
        else
          ReportSheet(
            head: const ['Loaded', 'Meter', 'Units', 'Paid (TZS)', 'VAT (TZS)', 'EWURA (TZS)', 'REA (TZS)', 'Old debt (TZS)', 'A unit (TZS)', 'Token no.'],
            rows: [
              for (final k in tokens)
                [
                  RCell(tableDateTime(k['loaded_at']) ?? '', sub: k['status'] == 'void' ? 'Void — ${k['void_reason'] ?? ''}' : null),
                  meterName(k['meter_id']), _units(k['units']), formatAmount(n(k['amount'])),
                  for (final f in ['vat_amount', 'ewura_levy', 'rea_levy', 'debt_deducted']) k[f] != null ? formatAmount(n(k[f])) : '',
                  n(k['units']) > 0 ? formatAmount((n(k['amount']) - n(k['debt_deducted'])) / n(k['units'])) : '',
                  [k['token_no'], k['receipt_ref']].where((x) => x != null && '$x'.isNotEmpty).join(' · '),
                ],
            ],
            firstWidth: 140,
          ),
      ],
      const Padding(padding: EdgeInsets.only(top: 8), child: PlHelp('Day = morning − evening.')),
    ]);
  }
}

/// The day, with its warnings under it
RCell _dayCell(Json x) => RCell('${tableDate(x['day'])}',
    warn: x['gap_units'] != null || x['token_missing'] == true,
    sub: x['gap_units'] != null ? 'a reading missing: ${_units(x['gap_units'])} units not split' : x['token_missing'] == true ? 'the meter went up — a token not recorded yet' : null);

// ---- A day's readings: morning and evening for each meter (either can wait until later); offline-capable ----
class _Readings extends StatefulWidget {
  const _Readings({required this.meters, required this.readings});
  final List<Json> meters, readings;
  @override
  State<_Readings> createState() => _ReadingsState();
}

class _ReadingsState extends State<_Readings> {
  late String _day = session.today;
  final Map<String, TextEditingController> _vals = {};
  bool _busy = false;
  String _error = '';
  bool get canFix => widget.meters.isNotEmpty && session.canAt('system.manage', '${widget.meters.first['branch_id']}', null);
  Json? had(Object? m, String slot) => widget.readings.where((r) => r['meter_id'] == m && r['read_on'] == _day && r['slot'] == slot && r['status'] == 'recorded').firstOrNull;
  TextEditingController ctl(Object? m, String slot) => _vals.putIfAbsent('$m|$slot', () => TextEditingController(text: had(m, slot) != null ? p6s(n(had(m, slot)!['reading'])) : ''));

  Future<void> _save() async {
    setState(() => _error = '');
    final list = [
      for (final m in widget.meters)
        for (final s in ['morning', 'evening'])
          if (had(m['id'], s) == null && _num(ctl(m['id'], s).text) != null) {'meter_id': m['id'], 'slot': s, 'reading': _num(ctl(m['id'], s).text)},
    ];
    final fixes = canFix
        ? [for (final m in widget.meters) for (final s in ['morning', 'evening']) if (had(m['id'], s) != null && _num(ctl(m['id'], s).text) != null && _num(ctl(m['id'], s).text) != n(had(m['id'], s)!['reading'])) had(m['id'], s)!]
        : <Json>[];
    if (list.isEmpty && fixes.isEmpty) return setState(() => _error = 'Enter a reading.');
    setState(() => _busy = true);
    try {
      for (final r in fixes) {
        await db.rpc('correct_power_reading', params: {'p_id': r['id'], 'p': {'reading': _num(ctl(r['meter_id'], '${r['slot']}').text)}});
      }
      if (list.isNotEmpty) {
        final how = await offline.send(label: 'Meter readings ${tableDate(_day)}', branchId: '${widget.meters.first['branch_id']}',
            calls: [Call.rpc('record_power_readings', {'p': {'read_on': _day, 'readings': list}})]);
        if (mounted) sentOrQueued(context, how, 'Readings saved');
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return FullPage(
      title: 'Meter readings',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        DateField(label: 'Day', value: _day, last: session.today, onChange: (v) => setState(() { _day = v; _vals.clear(); })),
        const SizedBox(height: 12),
        for (final m in widget.meters)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${m['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              Row(children: [
                for (final (s, label) in const [('morning', 'Morning (asubuhi)'), ('evening', 'Evening (jioni)')]) ...[
                  Expanded(
                    child: TextField(
                      controller: ctl(m['id'], s), enabled: had(m['id'], s) == null || canFix, onChanged: (_) => setState(() {}),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: label, helperText: had(m['id'], s) != null && canFix ? 'Recorded — change to correct' : null),
                    ),
                  ),
                  if (s == 'morning') const SizedBox(width: 8),
                ],
              ]),
              if (_num(ctl(m['id'], 'morning').text) != null && _num(ctl(m['id'], 'evening').text) != null)
                Padding(padding: const EdgeInsets.only(top: 4), child: Text('Used ${_units(_num(ctl(m['id'], 'morning').text)! - _num(ctl(m['id'], 'evening').text)!)}', style: const TextStyle(fontWeight: FontWeight.w700))),
            ]),
          ),
        const Padding(padding: EdgeInsets.only(top: 8), child: PlHelp('Units left on each meter. A token loaded during the day: enter it first (Record expense → Electricity). Offline, readings are kept on the phone and sent later.')),
      ],
    );
  }
}

// ---- The technical admin corrects a reading (144): the old one stays, void "Corrected" ----
class _Fix extends StatefulWidget {
  const _Fix({required this.row, required this.name});
  final Json row;
  final String name;
  @override
  State<_Fix> createState() => _FixState();
}

class _FixState extends State<_Fix> {
  late String _day = '${widget.row['read_on']}', _slot = '${widget.row['slot']}';
  late final _reading = TextEditingController(text: p6s(n(widget.row['reading'])));
  bool _busy = false;
  String _error = '';
  @override
  Widget build(BuildContext context) => FullPage(
        title: 'Correct reading — ${widget.name}',
        footer: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: _busy || _num(_reading.text) == null
                ? null
                : () async {
                    setState(() { _busy = true; _error = ''; });
                    try {
                      await db.rpc('correct_power_reading', params: {'p_id': widget.row['id'], 'p': {'read_on': _day, 'slot': _slot, 'reading': _num(_reading.text)}});
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (e) {
                      setState(() { _busy = false; _error = dbError(e); });
                    }
                  },
            child: const Text('Save'),
          ),
        ],
        children: [
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
          DateField(label: 'Day', value: _day, last: session.today, onChange: (v) => setState(() => _day = v)),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _slot, decoration: const InputDecoration(labelText: 'When'),
            items: const [DropdownMenuItem(value: 'morning', child: Text('Morning (asubuhi)')), DropdownMenuItem(value: 'evening', child: Text('Evening (jioni)'))],
            onChanged: (v) => setState(() => _slot = v ?? 'morning'),
          ),
          const SizedBox(height: 12),
          TextField(controller: _reading, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Units left')),
          PlHelp('Was ${tableDate(widget.row['read_on'])} ${widget.row['slot'] == 'morning' ? 'morning' : 'evening'}: ${_units(widget.row['reading'])}. The old one stays in the list as void.'),
        ],
      );
}

class _Void extends StatefulWidget {
  const _Void({required this.row});
  final Json row;
  @override
  State<_Void> createState() => _VoidState();
}

class _VoidState extends State<_Void> {
  final _reason = TextEditingController();
  bool _busy = false;
  String _error = '';
  @override
  Widget build(BuildContext context) => FullPage(
        title: 'Void reading',
        footer: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.error),
            onPressed: _busy || _reason.text.trim().isEmpty
                ? null
                : () async {
                    setState(() { _busy = true; _error = ''; });
                    try {
                      await db.rpc('void_power_reading', params: {'p_id': widget.row['id'], 'p_reason': _reason.text});
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (e) {
                      setState(() { _busy = false; _error = dbError(e); });
                    }
                  },
            child: const Text('Void'),
          ),
        ],
        children: [
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
          TextField(controller: _reason, autofocus: true, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Why?')),
        ],
      );
}

// ---- Ask for a LUKU top-up for a meter (081) ----
class _Topup extends StatefulWidget {
  const _Topup({required this.meters});
  final List<Json> meters;
  @override
  State<_Topup> createState() => _TopupState();
}

class _TopupState extends State<_Topup> {
  late String _meterId = widget.meters.length == 1 ? '${widget.meters.first['id']}' : '';
  final _amount = TextEditingController(), _units = TextEditingController(), _note = TextEditingController();
  bool _busy = false;
  String _error = '';
  Future<void> _save() async {
    setState(() => _error = '');
    if (_meterId.isEmpty) return setState(() => _error = 'Choose the meter.');
    if (!((_num(_amount.text) ?? 0) > 0)) return setState(() => _error = 'Enter how much LUKU to buy.');
    setState(() => _busy = true);
    try {
      await db.rpc('request_power_topup', params: {'p': {'meter_id': _meterId, 'amount': _num(_amount.text), 'units': _num(_units.text), 'note': _note.text}});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e); });
    }
  }

  @override
  Widget build(BuildContext context) => FullPage(
        title: 'Request a LUKU top-up',
        footer: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Send for approval')),
        ],
        children: [
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
          DropdownButtonFormField<String>(
            initialValue: _meterId.isEmpty ? null : _meterId, decoration: const InputDecoration(labelText: 'Meter'),
            items: [for (final m in widget.meters) DropdownMenuItem(value: '${m['id']}', child: Text('${m['name']}${m['meter_no'] != null ? ' · ${m['meter_no']}' : ''}'))],
            onChanged: (v) => setState(() => _meterId = v ?? ''),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: _amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount (TZS)'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _units, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'About how many units (optional)'))),
          ]),
          const SizedBox(height: 12),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'e.g. units left this morning')),
        ],
      );
}

class _Decision extends StatefulWidget {
  const _Decision({required this.q, required this.decision});
  final Json q;
  final String decision;
  @override
  State<_Decision> createState() => _DecisionState();
}

class _DecisionState extends State<_Decision> {
  final _note = TextEditingController();
  bool _busy = false;
  String _error = '';
  bool get approve => widget.decision == 'approved';
  @override
  Widget build(BuildContext context) => FullPage(
        title: approve ? 'Approve the top-up' : 'Turn down the top-up',
        footer: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            style: approve ? null : FilledButton.styleFrom(backgroundColor: C.error),
            onPressed: _busy || (!approve && _note.text.trim().isEmpty)
                ? null
                : () async {
                    setState(() { _busy = true; _error = ''; });
                    try {
                      await db.rpc('decide_purchase_request', params: {'p_id': widget.q['id'], 'p_decision': widget.decision, 'p_note': _note.text.trim().isEmpty ? null : _note.text});
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (e) {
                      setState(() { _busy = false; _error = dbError(e); });
                    }
                  },
            child: Text(approve ? 'Approve' : 'Turn down'),
          ),
        ],
        children: [
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
          TextField(controller: _note, autofocus: true, onChanged: (_) => setState(() {}), decoration: InputDecoration(labelText: approve ? 'Note (optional)' : 'Why?')),
        ],
      );
}

// ---- The token was bought: record it — the meter is topped up and the expense made (081) ----
Future<bool> buyTopup(BuildContext context, Json q, String meterName) => _push(context, _Buy(q: q, meterName: meterName));

class _Buy extends StatefulWidget {
  const _Buy({required this.q, required this.meterName});
  final Json q;
  final String meterName;
  @override
  State<_Buy> createState() => _BuyState();
}

class _BuyState extends State<_Buy> {
  late final Json l = _l(widget.q['lines']).first;
  late final Map<String, TextEditingController> f = {
    'units': TextEditingController(text: l['quantity'] != null ? p6s(n(l['quantity'])) : ''),
    'amount': TextEditingController(text: l['amount'] != null ? p6s(n(l['amount'])) : ''),
    for (final k in ['token_no', 'vat', 'ewura', 'rea', 'debt', 'ref']) k: TextEditingController(),
  };
  late String _date = session.today;
  String _time = '${TimeOfDay.now().hour.toString().padLeft(2, '0')}:${TimeOfDay.now().minute.toString().padLeft(2, '0')}';
  bool _busy = false;
  String _error = '';

  void _fromMessage(String text) {
    final r = parseLukuReceipt(text);
    if (r == null) return;
    setState(() {
      if (r['units'] != null) f['units']!.text = p6s(r['units'] as num);
      if (r['total'] != null) f['amount']!.text = p6s(r['total'] as num);
      if (r['token'] != null) f['token_no']!.text = '${r['token']}';
      for (final k in ['vat', 'ewura', 'rea', 'debt']) {
        if (r[k] != null) f[k]!.text = p6s(r[k] as num);
      }
      if (r['ref'] != null) f['ref']!.text = '${r['ref']}';
      if (r['date'] != null && '${r['date']}'.compareTo(session.today) <= 0) _date = '${r['date']}';
      if (r['time'] != null) _time = '${r['time']}';
    });
  }

  Future<void> _save() async {
    setState(() => _error = '');
    if (!((_num(f['units']!.text) ?? 0) > 0)) return setState(() => _error = 'Enter the units bought.');
    if (!((_num(f['amount']!.text) ?? -1) >= 0)) return setState(() => _error = 'Enter what was paid.');
    setState(() => _busy = true);
    try {
      await db.rpc('buy_power_topup', params: {'p_request': widget.q['id'], 'p': {
        'units': _num(f['units']!.text), 'amount': _num(f['amount']!.text), 'token_no': f['token_no']!.text,
        'vat_amount': _num(f['vat']!.text), 'ewura_levy': _num(f['ewura']!.text), 'rea_levy': _num(f['rea']!.text), 'debt_deducted': _num(f['debt']!.text), 'receipt_ref': f['ref']!.text,
        'loaded_at': DateTime.parse('${_date}T${_time.isEmpty ? '12:00' : _time}').toUtc().toIso8601String(),
      }});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e); });
    }
  }

  @override
  Widget build(BuildContext context) {
    const kb = TextInputType.numberWithOptions(decimal: true);
    Widget field(String k, String label, {TextInputType? type}) => SizedBox(width: 150, child: TextField(controller: f[k], keyboardType: type ?? kb, decoration: InputDecoration(labelText: label)));
    return FullPage(
      title: 'LUKU bought — ${widget.meterName}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Record and top up')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        PlHelp('Asked ${dateText(widget.q['requested_on'])}${l['amount'] != null ? ' · ${_money(l['amount'])}' : ''}'),
        const SizedBox(height: 10),
        TextField(minLines: 3, maxLines: 5, onChanged: _fromMessage, decoration: const InputDecoration(labelText: 'Paste the LUKU message (optional — fills the form)', hintText: 'Malipo yamekamilika… TOKEN … KWH Cost … VAT … TOTAL TZS …')),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 10, children: [
          field('units', 'Units bought (kWh)'), field('amount', 'Paid (TZS)'), field('token_no', 'Token number', type: TextInputType.text),
          field('vat', 'VAT'), field('ewura', 'EWURA levy'), field('rea', 'REA levy'), field('debt', 'Old debt taken off'),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: DateField(label: 'Bought on', value: _date, last: session.today, onChange: (v) => setState(() => _date = v))),
          const SizedBox(width: 8),
          Expanded(
            child: InkWell(
              onTap: () async {
                final p = _time.split(':');
                final tm = await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.tryParse(p.first) ?? 12, minute: int.tryParse(p.length > 1 ? p[1] : '0') ?? 0));
                if (tm != null) setState(() => _time = '${tm.hour.toString().padLeft(2, '0')}:${tm.minute.toString().padLeft(2, '0')}');
              },
              child: InputDecorator(decoration: const InputDecoration(labelText: 'At'), child: Text(_time)),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(controller: f['ref'], decoration: const InputDecoration(labelText: 'Receipt / transaction ref.')),
      ],
    );
  }
}

// ---- A meter's settings (2026-11-11): name, LUKU number, retire or bring back, the machines it feeds ----
class _MeterSettings extends StatefulWidget {
  const _MeterSettings({required this.meter, required this.branchId});
  final Json meter;
  final String branchId;
  @override
  State<_MeterSettings> createState() => _MeterSettingsState();
}

class _MeterSettingsState extends State<_MeterSettings> {
  late Json m = widget.meter;
  late final _name = TextEditingController(text: '${m['name']}');
  late final _no = TextEditingController(text: '${m['meter_no'] ?? ''}');
  List<Json>? _links;
  List<Json> _machines = [], _meters = [];
  bool _busy = false, _changed = false;
  String _error = '';
  bool get canEdit => session.canAt('procurement.receive', widget.branchId, null) || session.canAt('production.create', widget.branchId, null) || session.canAt('products.manage', widget.branchId, null);

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final r = await Future.wait<dynamic>([
        db.from('power_meter_machines').select('meter_id, machine_id'),
        db.from('machines').select('id, name, status').eq('branch_id', widget.branchId).order('name', ascending: true),
        db.from('power_meters').select('id, name').eq('branch_id', widget.branchId),
        db.from('power_meters').select('*').eq('id', widget.meter['id']).single(),
      ]);
      if (mounted) setState(() { _links = _l(r[0]); _machines = _l(r[1]); _meters = _l(r[2]); m = Map<String, dynamic>.from(r[3] as Map); });
    } catch (_) {
      if (mounted) setState(() => _links = []);
    }
  }

  Future<void> _run(Future<void> Function() q) async {
    setState(() { _error = ''; _busy = true; });
    try {
      await q();
      _changed = true;
      await _load();
    } catch (e) {
      _error = '$e'.contains('23505') ? 'That name is already used, or the machine is already on another meter.' : dbError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    bool onThis(Object? id) => _links?.any((l) => l['meter_id'] == m['id'] && l['machine_id'] == id) ?? false;
    String? elsewhere(Object? id) {
      final l = _links?.where((k) => k['machine_id'] == id && k['meter_id'] != m['id']).firstOrNull;
      return l == null ? null : '${_meters.where((x) => x['id'] == l['meter_id']).firstOrNull?['name'] ?? 'another meter'}';
    }

    final detailsChanged = _name.text.trim() != m['name'] || (_no.text.trim().isEmpty ? null : _no.text.trim()) != m['meter_no'];
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) { if (!did) Navigator.pop(context, _changed); },
      child: FullPage(
        title: 'Meter · ${m['name']}',
        footer: [
          if (canEdit)
            TextButton(
              onPressed: _busy ? null : () => _run(() async => db.from('power_meters').update({'status': m['status'] == 'active' ? 'inactive' : 'active'}).eq('id', m['id'])),
              child: Text(m['status'] == 'active' ? 'Retire' : 'Bring back'),
            ),
          if (canEdit && detailsChanged)
            OutlinedButton(
              onPressed: _busy || _name.text.trim().isEmpty
                  ? null
                  : () => _run(() async => db.from('power_meters').update({'name': _name.text.trim(), 'meter_no': _no.text.trim().isEmpty ? null : _no.text.trim()}).eq('id', m['id'])),
              child: const Text('Save'),
            ),
          FilledButton(onPressed: () => Navigator.pop(context, _changed), child: const Text('Done')),
        ],
        children: [
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
          Row(children: [
            Expanded(child: TextField(controller: _name, enabled: canEdit, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Name'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _no, enabled: canEdit, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'LUKU meter number', hintText: '—'))),
          ]),
          if (m['status'] != 'active') const PlHelp('Retired — not read any more.', color: C.warning),
          const SectionTitle('Machines it feeds'),
          const PlHelp("Its day use is charged to that day's batches on these machines. A machine can be on one meter only."),
          if (_links == null)
            const Skeleton(rows: 2, height: 24)
          else if (_machines.isEmpty)
            const PlHelp('No machines at this branch yet (Production ⚙).')
          else
            for (final x in _machines.where((x) => x['status'] == 'active' || onThis(x['id'])))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
                value: onThis(x['id']), title: Text('${x['name']}'), subtitle: elsewhere(x['id']) != null ? Text('on ${elsewhere(x['id'])}') : null,
                onChanged: !canEdit || _busy || elsewhere(x['id']) != null || m['status'] != 'active'
                    ? null
                    : (on) => _run(() async => on == true
                        ? await db.from('power_meter_machines').insert({'meter_id': m['id'], 'machine_id': x['id'], 'organization_id': session.organization?['id']})
                        : await db.from('power_meter_machines').delete().eq('meter_id', m['id']).eq('machine_id', x['id'])),
              ),
        ],
      ),
    );
  }
}
