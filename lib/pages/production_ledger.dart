import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/production.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';

/*
 * Production ledger — a port of web pages/ProductionLedger.jsx (2026-10-21/11-02): every production day by
 * period and stage; a day opens as the one-screen summary (LOCKED batch tables: materials as columns with
 * their cost below; team name + people count). One product (and colour) for a period: a summary, then each
 * batch it was cast in. Tracking: the period's batches by team, machine or product.
 */
const _stages = ['Curing', 'Ready', 'Released', 'Void'];
const _stageTone = {'Curing': Tone.info, 'Ready': Tone.warning, 'Released': Tone.success, 'Void': Tone.neutral};
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
double _r2(num v) => (v * 100).roundToDouble() / 100;
String _pct(double? v) => v == null || !v.isFinite ? '—' : '${(v * 1000).roundToDouble() / 10}%';

/// A batch's stage: Curing → Ready (curing time up) → Released; or Void
String stageOf(Json b, String today) => b['status'] == 'void' ? 'Void' : b['status'] == 'released' ? 'Released' : '${b['curing_until']}'.compareTo(today) <= 0 ? 'Ready' : 'Curing';

class ProductionLedgerPage extends StatefulWidget {
  const ProductionLedgerPage({super.key});
  @override
  State<ProductionLedgerPage> createState() => _ProductionLedgerPageState();
}

class _ProductionLedgerPageState extends State<ProductionLedgerPage> {
  Refs? _refs;
  List<Json> _batches = [];
  Map<String, double> _pcsPerSqm = {};
  ({List<Json> teams, List<Json> machines, List<Json> people, Map<String, Map<String, ({double min, double max})>> norms})? _track;
  bool _loading = true;
  String _error = '', _stage = '', _sortBy = 'newest', _view = 'days', _groupBy = 'team', _productId = '', _colorId = '';
  final _rp = RangePeriod('production-ledger');
  DateTime? _savedAt;
  String get branchId => session.branchId;
  String get today => session.today;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final refs = await Refs.load();
      final (j, at) = await offline.load<Json>('ledger:$branchId', () async {
        dynamic byBranch(dynamic q) => branchId.isNotEmpty ? q.eq('branch_id', branchId) : q;
        final r = await Future.wait<dynamic>([
          byBranch(db.from('production_batches').select('*, materials:production_batch_materials(*), outputs:production_batch_outputs(*), rejects:production_batch_rejects(*)'))
              .order('batch_date', ascending: false).order('created_at', ascending: true).limit(2000),
          db.from('product_specs').select('product_id, pcs_per_sqm'),
          db.from('production_teams').select('id, name').then<List?>((v) => v).catchError((_) => null),
          db.from('machines').select('*').then<List?>((v) => v).catchError((_) => null),
          db.from('production_people').select('id, full_name').then<List>((v) => v).catchError((_) => <dynamic>[]),
          db.from('branch_products').select('branch_id, product_id, bags_per_person_min, bags_per_person_max').then<List>((v) => v).catchError((_) => <dynamic>[]),
        ]);
        return {'b': r[0], 'ps': r[1], 't': r[2], 'm': r[3], 'pp': r[4], 'ln': r[5]};
      });
      if (!mounted) return;
      final norms = <String, Map<String, ({double min, double max})>>{};
      for (final x in _l(j['ln'])) {
        if (x['bags_per_person_min'] == null && x['bags_per_person_max'] == null) continue;
        (norms['${x['branch_id']}'] ??= {})['${x['product_id']}'] = (min: n(x['bags_per_person_min'] ?? x['bags_per_person_max']).toDouble(), max: n(x['bags_per_person_max'] ?? x['bags_per_person_min']).toDouble());
      }
      setState(() {
        _refs = refs;
        _batches = _l(j['b']);
        _pcsPerSqm = {for (final x in _l(j['ps'])) '${x['product_id']}': n(x['pcs_per_sqm']).toDouble()};
        _track = j['t'] == null || j['m'] == null ? null : (teams: _l(j['t']), machines: _l(j['m']), people: _l(j['pp']), norms: norms);
        _loading = false;
        _savedAt = at;
      });
    } catch (_) {
      if (mounted) setState(() { _error = "We couldn't load the production ledger. Please try again."; _loading = false; });
    }
  }

  String branchNameOf(Object? id) => session.branches.where((b) => b.id == id).firstOrNull?.name ?? '';
  String productName(Json o) => '${_refs?.items['p:${o['product_id']}']?.name ?? '—'}${o['color_id'] != null ? ' ${_refs?.colour('${o['color_id']}') ?? ''}' : ''}';
  double? sqmOf(String productId, double pcs) => _refs?.unit(_refs?.items['p:$productId']?.stockUnitId).toUpperCase() == 'SQM' && (_pcsPerSqm[productId] ?? 0) > 0 ? pcs / _pcsPerSqm[productId]! : null;
  String? teamName(Json b) => b['team_name'] as String? ?? _track?.teams.where((x) => x['id'] == b['team_id']).firstOrNull?['name'] as String?;
  int peopleOn(Json b) => ((b['worker_names'] ?? b['worker_ids']) as List? ?? []).length;
  double consOf(Json b) => _l(b['materials']).where((m) => m['source'] == 'consumable').fold<double>(0, (t, m) => t + n(m['cost']));

  /// one row per branch + day, in the period and stage
  List<({String key, String date, String branchId, List<Json> batches, Map<String, int> stages})> get days {
    final from = _rp.from, to = _rp.to;
    final g = <String, ({String key, String date, String branchId, List<Json> batches})>{};
    for (final b in _batches.where((x) => session.inBranch(x['branch_id']) && '${x['batch_date']}'.compareTo(from) >= 0 && '${x['batch_date']}'.compareTo(to) <= 0)) {
      final k = '${b['branch_id']}|${b['batch_date']}';
      (g[k] ??= (key: k, date: '${b['batch_date']}', branchId: '${b['branch_id']}', batches: <Json>[])).batches.add(b);
    }
    var list = [
      for (final d in g.values)
        (key: d.key, date: d.date, branchId: d.branchId, batches: d.batches, stages: () {
          final m = <String, int>{};
          for (final b in d.batches) { m[stageOf(b, today)] = (m[stageOf(b, today)] ?? 0) + 1; }
          return m;
        }()),
    ];
    if (_stage.isNotEmpty) list = list.where((d) => d.stages[_stage] != null).toList();
    list.sort((a, b) {
      final c = _sortBy == 'oldest' ? a.date.compareTo(b.date) : b.date.compareTo(a.date);
      return c != 0 ? c : branchNameOf(a.branchId).compareTo(branchNameOf(b.branchId));
    });
    return list;
  }

  List<({String name, String productId, double pieces})> productsOf(List<Json> batches) {
    final p = <String, ({String name, String productId, double pieces})>{};
    for (final b in batches.where((x) => x['status'] != 'void')) {
      for (final o in _l(b['outputs'])) {
        final k = '${o['product_id']}|${o['color_id'] ?? ''}';
        final x = p[k];
        p[k] = (name: productName(o), productId: '${o['product_id']}', pieces: (x?.pieces ?? 0) + n(o['pieces_cast']));
      }
    }
    return p.values.toList();
  }

  void _openDay(({String key, String date, String branchId, List<Json> batches, Map<String, int> stages}) d) {
    final refs = _refs!;
    final live = d.batches.where((b) => b['status'] != 'void').toList();
    final tracked = _track != null && live.any((b) => b['team_id'] != null);
    final people = tracked ? {for (final b in live.where((b) => b['team_id'] != null)) ...((b['worker_ids'] as List? ?? []).map((e) => '$e'))}.length : null;
    final norm = tracked
        ? labourNorm(ProductionLists(ready: true, machines: _track!.machines, norms: _track!.norms[d.branchId] ?? {}),
            [for (final b in live) (machineId: b['machine_id'] as String?, productId: '${b['product_id']}', bags: n(b['cement_bags']).toDouble())])
        : null;
    final curing = d.batches.where((b) => b['status'] == 'curing').map((b) => '${b['curing_until']}').toList()..sort();
    Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (ctx) => FullPage(
          title: 'Production — ${dateText(d.date)}',
          footer: [OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
          children: [
            DaySummary(
              date: d.date, branchName: branchNameOf(d.branchId), curingUntil: curing.lastOrNull, people: people, norm: norm,
              batches: [
                for (final (i, b) in d.batches.indexed)
                  BBatch(
                    n: i + 1, bags: n(b['cement_bags']).toDouble(), stage: stageOf(b, today), id: '${b['id']}',
                    // 055: costed as the materials left the store; consumables (138) shown apart, not in the material cost
                    cost: b['material_cost'] != null ? n(b['material_cost']) - consOf(b) : null, costComplete: b['material_cost_complete'] as bool?,
                    consumables: consOf(b) > 0 ? consOf(b) : null,
                    team: teamName(b), people: _track != null && b['team_id'] != null ? (b['worker_ids'] as List? ?? []).length : null,
                    machine: _track?.machines.where((m) => m['id'] == b['machine_id']).firstOrNull?['name'] as String?,
                    qcTags: b['status'] == 'released' ? [for (final x in (b['qc_tags'] as List? ?? [])) '$x'] : const [], qcNote: b['status'] == 'released' ? b['release_note'] as String? : null,
                    outputs: [
                      for (final o in _l(b['outputs'])..sort((x, y) => (y['is_primary'] == true ? 1 : 0) - (x['is_primary'] == true ? 1 : 0)))
                        BOut(name: productName(o), pieces: o['pieces_cast'] as num?, residual: o['is_primary'] != true, passed: o['pieces_passed'] as num?, perBag: o['yield_per_bag'] as num?,
                            perPiece: o['cost_per_piece'] != null ? n(o['cost_per_piece']).toDouble() : null, perSqm: o['cost_per_sqm'] != null ? n(o['cost_per_sqm']).toDouble() : null),
                    ],
                    materials: breakdownMaterials(_l(b['materials']).where((m) => m['source'] != 'consumable').toList(), refs),
                  ),
              ],
            ),
          ],
        )));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final refs = _refs;
    if (_error.isNotEmpty && refs == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    if (refs == null) return ListView(padding: const EdgeInsets.all(14), children: const [Skeleton(rows: 6)]);
    final ds = days;
    final productIds = {for (final b in _batches.where((b) => session.inBranch(b['branch_id']))) for (final o in _l(b['outputs'])) '${o['product_id']}'};
    final productOptions = [for (final id in productIds) (id: id, name: refs.items['p:$id']?.name ?? '—')]..sort((a, b) => a.name.compareTo(b.name));
    final colorIds = {for (final b in _batches.where((b) => session.inBranch(b['branch_id']))) for (final o in _l(b['outputs'])) if (o['product_id'] == _productId && o['color_id'] != null) '${o['color_id']}'};
    final colorOptions = [for (final id in colorIds) (id: id, name: refs.colour(id))]..sort((a, b) => a.name.compareTo(b.name));

    // the chosen product's batches: its own pieces on each; bags only where it was the main product
    final productRows = <Json>[];
    if (_productId.isNotEmpty) {
      for (final d in ds) {
        for (final b in d.batches) {
          final st = stageOf(b, today);
          if (b['status'] == 'void' || (_stage.isNotEmpty && st != _stage)) continue;
          final outs = _l(b['outputs']).where((o) => o['product_id'] == _productId && (_colorId.isEmpty || o['color_id'] == _colorId)).toList();
          if (outs.isEmpty) continue;
          final isMain = outs.any((o) => o['is_primary'] == true);
          final pieces = outs.fold<double>(0, (s, o) => s + n(o['pieces_cast']));
          productRows.add({
            'day': d, 'date': b['batch_date'], 'branchId': b['branch_id'], 'created': b['created_at'], 'stage': st, 'pieces': pieces,
            'rejected': b['status'] == 'released' ? outs.fold<double>(0, (s, o) => s + (o['pieces_passed'] == null ? 0 : (n(o['pieces_cast']) - n(o['pieces_passed'])).clamp(0, double.infinity))) : null,
            'bags': isMain ? n(b['cement_bags']).toDouble() : null, 'mainPieces': isMain ? pieces : 0.0, 'team': teamName(b), 'count': peopleOn(b),
            'machine': _track?.machines.where((m) => m['id'] == b['machine_id']).firstOrNull?['name'],
            'colours': {for (final o in outs) if (o['color_id'] != null) refs.colour('${o['color_id']}')}.join(', '),
          });
        }
      }
      productRows.sort((a, b) {
        final c = _sortBy == 'oldest' ? '${a['date']}'.compareTo('${b['date']}') : '${b['date']}'.compareTo('${a['date']}');
        return c != 0 ? c : '${b['created']}'.compareTo('${a['created']}');
      });
    }
    double pt(String k) => productRows.fold<double>(0, (s, r) => s + n(r[k]));
    final productSqm = _productId.isNotEmpty ? sqmOf(_productId, pt('pieces')) : null;

    return RefreshIndicator(
      onRefresh: _load,
      child: PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 32), children: [
        OfflineNote(_savedAt),
        PlHelp(branchId.isNotEmpty ? (session.branchName ?? '') : 'All branches'),
        const SizedBox(height: 6),
        if (_productId.isNotEmpty)
          Stats([
            Stat('Pieces', qtyText(pt('pieces')), help: '${productSqm != null ? '${qtyText(_r2(productSqm))} m² · ' : ''}${productRows.length} batch${productRows.length == 1 ? '' : 'es'}'),
            Stat('Cement bags', qtyText(_r2(pt('bags'))), help: pt('bags') > 0 ? '${qtyText((pt('mainPieces') / pt('bags') * 10).roundToDouble() / 10)} pieces a bag' : 'none as the main product'),
            Stat('Rejected', qtyText(pt('rejected')), figureColor: pt('rejected') > 0 ? C.warning : null, help: 'of pieces released'),
          ]),
        DropdownButtonFormField<String>(
          initialValue: _productId, isExpanded: true, decoration: const InputDecoration(labelText: 'Product'),
          items: [const DropdownMenuItem(value: '', child: Text('All products')), for (final p in productOptions) DropdownMenuItem(value: p.id, child: Text(p.name, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() { _productId = v ?? ''; _colorId = ''; }),
        ),
        if (_productId.isNotEmpty && colorOptions.isNotEmpty) ...[
          const SizedBox(height: 8),
          SlideRow(children: [Chip2('All colours', on: _colorId.isEmpty, onTap: () => setState(() => _colorId = '')), for (final c in colorOptions) Chip2(c.name, on: _colorId == c.id, onTap: () => setState(() => _colorId = c.id))]),
        ],
        const SizedBox(height: 8),
        _rp.bar(context, () => setState(() {})),
        const SizedBox(height: 8),
        SlideRow(children: [
          if (_productId.isEmpty) ...[
            Chip2('Days', on: _view == 'days', onTap: () => setState(() => _view = 'days')),
            if (_track != null) Chip2('Tracking', on: _view == 'tracking', onTap: () => setState(() => _view = 'tracking')),
          ],
          Chip2('All stages', on: _stage.isEmpty, onTap: () => setState(() => _stage = '')),
          for (final s in _stages) Chip2(s, on: _stage == s, onTap: () => setState(() => _stage = _stage == s ? '' : s)),
          Chip2(_sortBy == 'newest' ? 'Newest first' : 'Oldest first', on: false, onTap: () => setState(() => _sortBy = _sortBy == 'newest' ? 'oldest' : 'newest')),
        ]),
        const SizedBox(height: 10),
        if (_loading)
          const Skeleton(rows: 5)
        else if (_productId.isNotEmpty) ...[
          if (productRows.isEmpty) const EmptyState(icon: LucideIcons.bookOpen, title: 'No production in this period', description: 'Try another period.'),
          for (final r in productRows)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: t.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _openDay(r['day'] as ({String key, String date, String branchId, List<Json> batches, Map<String, int> stages})),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text('${tableDate(r['date'])}${branchId.isEmpty ? ' · ${branchNameOf(r['branchId'])}' : ''}${'${r['colours']}'.isNotEmpty ? ' · ${r['colours']}' : ''}', style: const TextStyle(fontWeight: FontWeight.w600))),
                        Badge2('${r['stage']}', tone: _stageTone[r['stage']] ?? Tone.neutral),
                      ]),
                      PlHelp([
                        r['team'] != null ? '${r['team']}${n(r['count']) > 0 ? ' (${r['count']})' : ''}' : '—',
                        '${r['machine'] ?? '—'}',
                        r['bags'] == null ? 'leftover' : '${qtyText(_r2(n(r['bags'])))} bags',
                      ].join(' · ')),
                      Row(children: [
                        Text('${qtyText(n(r['pieces']))} pcs', style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (r['rejected'] != null) PlHelp(' · ${qtyText(n(r['rejected']))} rejected'),
                      ]),
                    ]),
                  ),
                ),
              ),
            ),
          if (productRows.isNotEmpty) Text('Total ${qtyText(_r2(pt('bags')))} bags · ${qtyText(pt('pieces'))} pcs · ${qtyText(pt('rejected'))} rejected', style: const TextStyle(fontWeight: FontWeight.w700)),
        ] else if (_view == 'tracking' && _track != null)
          _tracking(ds)
        else ...[
          if (ds.isEmpty) const EmptyState(icon: LucideIcons.bookOpen, title: 'No production in this period', description: 'Confirmed production days appear here.'),
          for (final d in ds)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: t.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _openDay(d),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text('${tableDate(d.date)}${branchId.isEmpty ? ' · ${branchNameOf(d.branchId)}' : ''}', style: const TextStyle(fontWeight: FontWeight.w700))),
                        Text('${d.batches.length} batch${d.batches.length == 1 ? '' : 'es'} · ${qtyText(_r2(d.batches.where((b) => b['status'] != 'void').fold<double>(0, (s, b) => s + n(b['cement_bags']))))} bags',
                            style: TextStyle(fontSize: Fs.sm, color: t.textSecondary)),
                      ]),
                      const SizedBox(height: 4),
                      for (final p in productsOf(d.batches)) Text('${p.name} · ${qtyText(p.pieces)} pcs', style: const TextStyle(fontSize: Fs.sm)),
                      const SizedBox(height: 4),
                      Wrap(spacing: 4, children: [for (final s in _stages) if (d.stages[s] != null) Badge2('$s ${d.stages[s]}', tone: _stageTone[s]!)]),
                    ]),
                  ),
                ),
              ),
            ),
        ],
      ]),
    );
  }

  /// the period's batches by team, machine or product
  Widget _tracking(List<({String key, String date, String branchId, List<Json> batches, Map<String, int> stages})> ds) {
    final refs = _refs!;
    final tr = _track!;
    final live = [for (final d in ds) ...d.batches.where((b) => b['status'] != 'void')];
    final rows = <String, Map<String, dynamic>>{};
    for (final b in live) {
      final (k, name) = _groupBy == 'team'
          ? ('${b['team_id'] ?? '-'}', '${b['team_name'] ?? tr.teams.where((t) => t['id'] == b['team_id']).firstOrNull?['name'] ?? 'No team (before 25 Oct)'}')
          : _groupBy == 'machine'
              ? ('${b['machine_id'] ?? '-'}', '${tr.machines.where((m) => m['id'] == b['machine_id']).firstOrNull?['name'] ?? 'No machine (before 25 Oct)'}')
              : ('${b['product_id']}', refs.items['p:${b['product_id']}']?.name ?? '—');
      final r = rows.putIfAbsent(k, () => {'key': k, 'name': name, 'batches': 0.0, 'bags': 0.0, 'pieces': 0.0, 'implied': 0.0, 'implying': 0.0, 'released': 0.0, 'rejected': 0.0, 'cost': 0.0, 'costPcs': 0.0});
      void add(String f, num v) => r[f] = n(r[f]) + v;
      final pcs = _l(b['outputs']).fold<double>(0, (s, o) => s + n(o['pieces_cast']));
      add('batches', 1);
      add('bags', n(b['cement_bags']));
      add('pieces', pcs);
      if (b['theoretical_bags'] != null) { add('implied', n(b['theoretical_bags'])); add('implying', n(b['cement_bags'])); }
      if (b['status'] == 'released') { add('released', pcs); add('rejected', _l(b['rejects']).fold<double>(0, (s, x) => s + n(x['pieces']))); }
      if (b['material_cost'] != null) { add('cost', n(b['material_cost'])); add('costPcs', pcs); }
    }
    final list = rows.values.toList()..sort((a, b) => n(b['pieces']).compareTo(n(a['pieces'])));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SlideRow(children: [for (final (k, l) in const [('team', 'Team'), ('machine', 'Machine'), ('product', 'Product')]) Chip2(l, on: _groupBy == k, onTap: () => setState(() => _groupBy = k))]),
      const SizedBox(height: 6),
      const PlHelp('Void batches left out. Yield = cement the pieces imply ÷ cement used; rejects = of pieces released.'),
      const SizedBox(height: 8),
      if (list.isEmpty)
        const PlHelp('No batches in this period.')
      else
        for (final r in list)
          CardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${r['name']}', style: TextStyle(fontWeight: FontWeight.w700, color: r['key'] == '-' ? context.tk.textMuted : null)),
              const SizedBox(height: 4),
              Text('${n(r['batches']).round()} batches · ${qtyText(_r2(n(r['bags'])))} bags · ${qtyText(n(r['pieces']))} pcs', style: const TextStyle(fontSize: Fs.sm)),
              PlHelp('yield ${n(r['implying']) > 0 ? _pct(n(r['implied']) / n(r['implying'])) : '—'} · rejects ${n(r['released']) > 0 ? _pct(n(r['rejected']) / n(r['released'])) : '—'}'
                  ' · material ${n(r['costPcs']) > 0 ? '${formatMoney(n(r['cost']) / n(r['costPcs']), session.currency)} a piece' : '—'}'),
            ]),
          ),
    ]);
  }
}
