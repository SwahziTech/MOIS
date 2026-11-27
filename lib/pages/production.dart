import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/production.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../core/pdf_doc.dart';
import '../docs/job_card_doc.dart';
import '../shell.dart';
import 'day_log.dart';
import 'planner.dart';
import 'production_settings.dart';
import 'procurement_actions.dart' show DateField;
import 'reports.dart' show ReportSheet, RCell;

/*
 * Production — a port of web pages/Production.jsx (042/043/054/056/140; approved 2026-11-24). The menu
 * shows it three ways: Production (Production · Curing · Materials to issue · Released & void), Job
 * Costing › Material variance (a batch a row, materials as columns with their cost below) and Planner.
 * Pieces cure (not sellable) until the quality release moves the passed ones into finished goods and the
 * rejects into the Rejects store. Online only (2026-11-24, the user).
 */
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
double _r2(num v) => (v * 100).roundToDouble() / 100;
const _qcTags = ['Colour', 'Edges', 'Size', 'Strength', 'Surface'];

/// a branch's ready-goods stores that take production — the yard, not the shop (135)
List<Store> fgStoresOf(Refs refs, String branchId) =>
    refs.warehouses.where((w) => w.status == 'active' && w.branchId == branchId && w.type == 'finished_goods' && w.receivesProduction).toList();

class ProductionPage extends StatefulWidget {
  const ProductionPage({super.key, this.query = const {}});
  final Map<String, String> query;
  @override
  State<ProductionPage> createState() => _ProductionPageState();
}

class _ProductionPageState extends State<ProductionPage> {
  Refs? _refs;
  List<Json> _batches = [], _reasons = [], _recipes = [];
  Map<String, String> _flags = {}, _people = {};
  int _curingDays = 14;
  int? _minCuring;
  bool _loading = true;
  String _error = '', _rowError = '';
  String? _tab;
  String? _busyId;
  final Set<String> _picked = {};
  ({String productId, String colorId, int at})? _preset;
  DateTime? _savedAt;

  String get branchId => session.branchId;
  String get today => session.today;
  bool get canRecord => branchId.isNotEmpty && session.canAt('production.create', branchId, null);
  String get current => _tab ?? widget.query['tab'] ?? (canRecord ? 'log' : 'curing');

  @override
  void initState() {
    super.initState();
    // Stock's "Produce" opens the form with that product (?produce=<id>)
    _takePreset();
    _load();
  }

  // Stock's "Produce" and the Planner open the form with that product (?produce=<id>&colour=<id>)
  void _takePreset() {
    final p = widget.query['produce'];
    if (p != null) { _preset = (productId: p, colorId: widget.query['colour'] ?? '', at: DateTime.now().millisecondsSinceEpoch); _tab = 'log'; }
  }

  @override
  void didUpdateWidget(ProductionPage old) {
    super.didUpdateWidget(old);
    if (old.query['produce'] != widget.query['produce'] || old.query['colour'] != widget.query['colour'] || old.query['tab'] != widget.query['tab']) setState(() { _tab = null; _takePreset(); });
  }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final refs = await Refs.load();
      final (j, at) = await offline.load<Json>('production:$branchId', () async {
        dynamic byBranch(dynamic q) => branchId.isNotEmpty ? q.eq('branch_id', branchId) : q;
        final r = await Future.wait<dynamic>([
          byBranch(db.from('production_batches').select('*, materials:production_batch_materials(*), outputs:production_batch_outputs(*), rejects:production_batch_rejects(*)'))
              .order('batch_date', ascending: false).order('created_at', ascending: false).limit(500),
          db.from('reject_reasons').select('id, name, status, display_order').order('display_order', ascending: true).order('name', ascending: true),
          byBranch(db.from('recipe_versions').select('id, branch_id, category_id, color_id, version_number, effective_date, status, items:recipe_items(material_id, quantity, unit_id), products:recipe_version_products(product_id)').eq('status', 'active')),
          db.from('review_flags').select('entity_id, reason').eq('entity_type', 'production_batch').eq('status', 'open'),
          db.from('organizations').select('curing_days, min_curing_days').eq('id', session.organization!['id']).maybeSingle(),
        ]);
        final ids = {for (final b in r[0] as List) if (b['created_by'] != null) '${b['created_by']}'}.toList();
        final ppl = ids.isEmpty ? [] : await db.from('profiles').select('id, first_name, last_name, email').inFilter('id', ids);
        return {'b': r[0], 'rr': r[1], 'rv': r[2], 'fl': r[3], 'org': r[4], 'ppl': ppl};
      });
      if (!mounted) return;
      setState(() {
        _refs = refs;
        _batches = _l(j['b']);
        _reasons = _l(j['rr']);
        _recipes = _l(j['rv']);
        _flags = {for (final f in _l(j['fl'])) '${f['entity_id']}': '${f['reason']}'};
        final org = j['org'] as Map?;
        if (org?['curing_days'] != null) _curingDays = n(org!['curing_days']).toInt();
        _minCuring = org?['min_curing_days'] != null ? n(org!['min_curing_days']).toInt() : null;
        _people = {
          for (final p in _l(j['ppl']))
            '${p['id']}': [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ').isEmpty ? '${p['email']}' : [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' '),
        };
        _loading = false;
        _savedAt = at;
      });
    } catch (_) {
      if (mounted) setState(() { _error = "We couldn't load production. Please try again."; _loading = false; });
    }
  }

  String productName(Json b) => '${_refs?.items['p:${b['product_id']}']?.name ?? '—'}${b['color_id'] != null ? ' ${_refs?.colour('${b['color_id']}') ?? ''}' : ''}';
  List<Json> leftoversOf(Json b) => _l(b['outputs']).where((o) => o['is_primary'] != true).toList();
  String readyOn(Json b) => _minCuring != null ? iso(DateTime.parse('${b['batch_date']}').add(Duration(days: _minCuring!))) : '${b['curing_until']}';
  // with a minimum (054) a batch can be picked from that day; without one, any curing batch (early ones need a reason)
  bool readyToRelease(Json b) => b['status'] == 'curing' && session.canAt('production.complete', '${b['branch_id']}', null) && (_minCuring == null || readyOn(b).compareTo(today) <= 0);
  bool canIssue(Json b) => session.canAt('inventory.issue', '${b['branch_id']}', '${b['raw_warehouse_id']}') || session.canAt('production.create', '${b['branch_id']}', null);

  Map<String, int> get usage {
    final u = <String, int>{};
    for (final b in _batches.where((x) => x['status'] != 'void' && x['branch_id'] == branchId)) {
      for (final id in {'${b['product_id']}', for (final o in _l(b['outputs'])) '${o['product_id']}'}) { u[id] = (u[id] ?? 0) + 1; }
    }
    return u;
  }

  Future<void> _issue(Json b) async {
    setState(() { _rowError = ''; _busyId = '${b['id']}'; });
    try {
      await db.rpc('issue_production_materials', params: {'p_batch': b['id']});
      _load();
    } catch (e) {
      _rowError = dbError(e, "We couldn't issue the materials. Please try again.");
    }
    if (mounted) setState(() => _busyId = null);
  }

  // release several at once (2026-10-24): every piece passes — rejects go through Release… one by one
  Future<void> _releaseMany(List<Json> ready) async {
    final list = ready.where((b) => _picked.contains('${b['id']}')).toList();
    final early = _minCuring != null ? <Json>[] : list.where((b) => '${b['curing_until']}'.compareTo(today) > 0).toList();
    final note = TextEditingController();
    final go = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (ctx) => StatefulBuilder(builder: (ctx, set) => FullPage(
          title: 'Release ${list.length} batch${list.length == 1 ? '' : 'es'}?',
          footer: [
            OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: early.isNotEmpty && note.text.trim().isEmpty ? null : () => Navigator.pop(ctx, true), child: const Text('Release — all pieces pass')),
          ],
          children: [
            const Text("All pieces pass to Finished Goods. Rejects? Use the batch's own Release… instead."),
            if (early.isNotEmpty) ...[
              const SizedBox(height: 10),
              TextField(controller: note, autofocus: true, onChanged: (_) => set(() {}),
                  decoration: InputDecoration(labelText: '${early.length} of them ${early.length == 1 ? 'is' : 'are'} still curing — why release early? (required)', hintText: 'e.g. 7 days only')),
            ],
            const SizedBox(height: 10),
            for (final b in list)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(children: [
                  Expanded(child: Text('${tableDate(b['batch_date'])} · ${productName(b)}${leftoversOf(b).isNotEmpty ? ' + ${leftoversOf(b).map((o) => _refs?.items['p:${o['product_id']}']?.name).join(', ')}' : ''}')),
                  Text('${qtyText(n(b['pieces_cast']))} pcs', style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
              ),
          ],
        ))));
    if (go != true || !mounted) return;
    final failed = <String>[];
    var done = 0;
    final progress = ValueNotifier<int>(0);
    showDialog<void>(context: context, barrierDismissible: false, builder: (_) => AlertDialog(content: ValueListenableBuilder<int>(valueListenable: progress, builder: (_, v, _) => Text('Releasing… $v of ${list.length}'))));
    for (final b in list) {
      final fg = fgStoresOf(_refs!, '${b['branch_id']}').firstOrNull;
      try {
        await db.rpc('release_production_batch', params: {'p_batch': b['id'], 'p': {
          'fg_warehouse_id': fg?.id, 'release_date': today, 'note': _minCuring == null && '${b['curing_until']}'.compareTo(today) > 0 ? note.text.trim() : null,
          'outputs': [for (final o in _l(b['outputs'])) {'output_id': o['id'], 'pieces_passed': o['pieces_cast'], 'rejects': []}],
        }});
      } catch (e) {
        failed.add('${dateText(b['batch_date'])} · ${productName(b)} — ${dbError(e)}');
      }
      progress.value = ++done;
    }
    if (mounted) Navigator.pop(context);
    _picked.clear();
    await _load();
    if (!mounted) return;
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
          title: const Text('Released'),
          content: Text('$done of ${list.length} done.${failed.isEmpty ? ' All released.' : '\nNot released:\n${failed.join('\n')}'}'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
        ));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final refs = _refs;
    if (_error.isNotEmpty && refs == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    if (refs == null) return ListView(padding: const EdgeInsets.all(14), children: const [Skeleton(rows: 6)]);
    final here = _batches.where((b) => session.inBranch(b['branch_id'])).toList();
    final curing = here.where((b) => b['status'] == 'curing').toList();
    final waitingMaterials = here.where((b) => b['status'] != 'void' && b['materials_movement_id'] == null && _l(b['materials']).isNotEmpty).toList();
    final done = here.where((b) => b['status'] != 'curing').toList();
    final page = current == 'planner' ? 'planner' : current == 'variance' ? 'variance' : 'production';
    final shown = current == 'curing' ? curing : current == 'materials' ? waitingMaterials : done;
    final ready = curing.where(readyToRelease).toList();

    return RefreshIndicator(
      onRefresh: () async { await Refs.load(fresh: true); await _load(); },
      child: PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 32), children: [
        OfflineNote(_savedAt),
        Row(children: [
          Expanded(child: PlHelp(branchId.isNotEmpty ? (session.branchName ?? '') : 'All branches')),
          // ⚙ beside the heading, as on the web: curing, teams & machines, reject reasons
          IconButton(tooltip: 'Production settings', visualDensity: VisualDensity.compact, icon: const Icon(LucideIcons.settings, size: 18),
              onPressed: () async { await openProductionSettings(context); _load(); }),
        ]),
        if (page == 'production')
          PageTabs<String>(
            tabs: [
              if (canRecord) ('log', 'Production'),
              ('curing', 'Curing (${curing.length})'),
              if (waitingMaterials.isNotEmpty) ('materials', 'Materials to issue (${waitingMaterials.length})'),
              ('done', 'Released & void'),
            ],
            value: current, onChange: (v) => setState(() => _tab = v),
          ),
        if (_rowError.isNotEmpty) Alert(_rowError, tone: Tone.error),
        if (current == 'planner')
          (branchId.isEmpty
              ? const EmptyState(icon: LucideIcons.factory, title: 'Pick a branch', description: 'Capacity is per branch — pick one in the menu.')
              : Planner(key: ValueKey(branchId), refs: refs, recipes: _recipes, curingDays: _curingDays, usage: usage,
                  onOpenForm: canRecord ? (p, c) => Shell.of(context).go('/production?produce=$p${c.isNotEmpty ? '&colour=$c' : ''}') : null))
        else if (current == 'log')
          (!canRecord ? const PlHelp('Pick a branch to record production.') : DayLog(
              refs: refs, recipes: _recipes, curingDays: _curingDays, usage: usage, preset: _preset,
              onSaved: () { setState(() => _tab = 'curing'); _load(); },
            ))
        else if (current == 'variance')
          _BatchCostTable(batches: _batches, refs: refs, loading: _loading)
        else ...[
          if (current == 'curing' && ready.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.fromLTRB(4, 4, 10, 4),
              decoration: BoxDecoration(color: t.soft, borderRadius: BorderRadius.circular(8)),
              child: Row(children: [
                Checkbox(value: ready.every((b) => _picked.contains('${b['id']}')), onChanged: (v) => setState(() { if (v == true) { _picked.addAll(ready.map((b) => '${b['id']}')); } else { _picked.clear(); } })),
                Expanded(child: Text(_picked.isNotEmpty ? '${_picked.length} selected' : 'Select all (${ready.length})', style: const TextStyle(fontSize: Fs.sm))),
                FilledButton(onPressed: _picked.isEmpty ? null : () => _releaseMany(ready), child: Text('Release selected (${_picked.length})')),
              ]),
            ),
          if (_loading)
            const Skeleton(rows: 4)
          else if (shown.isEmpty)
            EmptyState(icon: LucideIcons.factory, title: current == 'curing' ? 'Nothing curing' : current == 'materials' ? 'No materials waiting' : 'No released batches yet',
                description: current == 'curing' ? 'Batches cast appear here until their quality release.' : null)
          else
            for (final b in shown) _card(context, b),
        ],
      ]),
    );
  }

  Widget _card(BuildContext context, Json b) {
    final t = context.tk;
    final refs = _refs!;
    // the bags used against the band the products' yields give (043)
    final inBand = b['theoretical_bags'] == null ? null : n(b['cement_bags']) >= n(b['bags_min']) - 1e-9 && (b['bags_max'] == null || n(b['cement_bags']) <= n(b['bags_max']) + 1e-9);
    final rejected = _l(b['rejects']).fold<double>(0, (s, r) => s + n(r['pieces']));
    final passed = _l(b['outputs']).fold<double>(0, (s, o) => s + n(o['pieces_passed']));
    final noMaterials = b['materials_movement_id'] == null && b['status'] != 'void' && _l(b['materials']).isNotEmpty;
    final (label, tone) = b['status'] == 'curing' ? ('Curing', Tone.info) : b['status'] == 'released' ? ('Released', Tone.success) : ('Void', Tone.neutral);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: b['status'] == 'void' ? 0.6 : 1,
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 10, 12, 10),
          decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(10)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (current == 'curing')
              SizedBox(
                width: 36,
                child: readyToRelease(b) ? Checkbox(value: _picked.contains('${b['id']}'), onChanged: (_) => setState(() => _picked.contains('${b['id']}') ? _picked.remove('${b['id']}') : _picked.add('${b['id']}'))) : null,
              )
            else
              const SizedBox(width: 4),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${tableDate(b['batch_date'])}${_people['${b['created_by']}'] != null ? ' · ${_people['${b['created_by']}']}' : ''}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted))),
                  Badge2(label, tone: tone),
                ]),
                const SizedBox(height: 2),
                Text(productName(b), style: const TextStyle(fontWeight: FontWeight.w700)),
                if (leftoversOf(b).isNotEmpty) PlHelp('+ ${leftoversOf(b).map((o) => '${o['pieces_cast']} ${refs.items['p:${o['product_id']}']?.name ?? ''}').join(', ')}'),
                const SizedBox(height: 4),
                Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  Text('${qtyText(n(b['cement_bags']))} bags · ${qtyText(n(b['pieces_cast']))} pcs', style: const TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w600)),
                  if (b['status'] == 'released') PlHelp('${passed.round()} passed${rejected > 0 ? ' · ${rejected.round()} rejected' : ''}'),
                  if (inBand == null)
                    const PlHelp('No yield per bag set')
                  else
                    Tooltip(message: _flags['${b['id']}'] ?? '', child: Badge2('${(n(b['theoretical_bags']) / n(b['cement_bags']) * 1000).roundToDouble() / 10}%${inBand ? '' : ' — outside'}', tone: inBand ? Tone.success : Tone.warning)),
                ]),
                if (b['status'] == 'released')
                  PlHelp('Released ${tableDate(b['released_on']) ?? ''}')
                else if (b['status'] == 'curing')
                  readyOn(b).compareTo(today) <= 0
                      ? Text('Curing until ${tableDate(b['curing_until'])} · Ready to release', style: const TextStyle(fontSize: Fs.xs, color: C.success))
                      : PlHelp('Curing until ${tableDate(b['curing_until'])}${_minCuring != null ? ' · ready ${tableDate(readyOn(b))}' : ''}'),
                if (noMaterials) const PlHelp('Materials not issued yet', color: C.warning),
                if (b['status'] == 'void') PlHelp('${b['void_reason'] ?? ''}'),
                if (noMaterials && canIssue(b) || b['status'] == 'curing' && (session.canAt('production.complete', '${b['branch_id']}', null) || session.canManage('inventory.adjust')))
                  Wrap(spacing: 6, children: [
                    if (noMaterials && canIssue(b)) OutlinedButton(onPressed: _busyId == b['id'] ? null : () => _issue(b), child: const Text('Issue materials')),
                    if (b['status'] == 'curing' && session.canAt('production.complete', '${b['branch_id']}', null))
                      FilledButton(onPressed: () => _release(b), child: const Text('Release…')),
                    if (b['status'] == 'curing' && session.canManage('inventory.adjust')) TextButton(onPressed: () => _void(b), child: const Text('Void…')),
                  ]),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Future<void> _release(Json b) async {
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _Release(
          batch: b, name: productName(b), refs: _refs!, reasons: _reasons, minFrom: _minCuring != null ? readyOn(b) : null)));
    if (saved == true) _load();
  }

  Future<void> _void(Json b) async {
    final reason = TextEditingController();
    String err = '';
    var busy = false;
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (ctx) => StatefulBuilder(builder: (ctx, set) => FullPage(
          title: 'Void ${productName(b)} · ${dateText(b['batch_date'])}',
          footer: [
            OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep it')),
            OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: C.error, side: const BorderSide(color: C.error)),
              onPressed: busy
                  ? null
                  : () async {
                      if (reason.text.trim().isEmpty) return set(() => err = 'Give a reason.');
                      set(() { busy = true; err = ''; });
                      try {
                        await db.rpc('void_production_batch', params: {'p_batch': b['id'], 'p_reason': reason.text.trim()});
                        if (ctx.mounted) Navigator.pop(ctx, true);
                      } catch (e) {
                        set(() { busy = false; err = dbError(e); });
                      }
                    },
              child: const Text('Void batch'),
            ),
          ],
          children: [
            if (err.isNotEmpty) Alert(err, tone: Tone.error),
            const Text('Reverses the pieces and materials. The batch stays, marked void.'),
            const SizedBox(height: 10),
            TextField(controller: reason, decoration: const InputDecoration(hintText: 'Reason')),
          ],
        ))));
    if (ok == true) _load();
  }
}

/// Quality release, product by product: every cast piece passes unless entered as a reject (with its reason);
/// rejects go into the Rejects store (140)
class _Release extends StatefulWidget {
  const _Release({required this.batch, required this.name, required this.refs, required this.reasons, this.minFrom});
  final Json batch;
  final String name;
  final Refs refs;
  final List<Json> reasons;
  final String? minFrom;
  @override
  State<_Release> createState() => _ReleaseState();
}

class _ReleaseState extends State<_Release> {
  Json get b => widget.batch;
  late final fgStores = fgStoresOf(widget.refs, '${b['branch_id']}');
  late final outputs = _l(b['outputs'])..sort((x, y) => (y['is_primary'] == true ? 1 : 0) - (x['is_primary'] == true ? 1 : 0));
  late String _fgId = fgStores.firstOrNull?.id ?? '';
  late String _date = session.today;
  final Map<String, TextEditingController> _rej = {};
  final Map<String, String> _why = {};
  final _note = TextEditingController();
  final List<String> _tags = [];
  bool _busy = false;
  String _error = '';

  double rejectedOf(Json o) => double.tryParse(_rej['${o['id']}']?.text.trim() ?? '') ?? 0;
  double passedOf(Json o) => n(o['pieces_cast']) - rejectedOf(o);
  String nameOf(Json o) => '${widget.refs.items['p:${o['product_id']}']?.name ?? '—'}${o['color_id'] != null ? ' ${widget.refs.colour('${o['color_id']}')}' : ''}';
  bool get tooSoon => widget.minFrom != null && _date.compareTo(widget.minFrom!) < 0;
  bool get early => widget.minFrom == null && _date.compareTo('${b['curing_until']}') < 0;

  Future<void> _save() async {
    setState(() => _error = '');
    for (final o in outputs) {
      if (passedOf(o) < 0) return setState(() => _error = '${nameOf(o)}: more rejects than the ${o['pieces_cast']} pieces cast.');
      if (rejectedOf(o) > 0 && _why['${o['id']}'] == null) return setState(() => _error = '${nameOf(o)}: choose why the pieces are rejected.');
    }
    if (tooSoon) return setState(() => _error = 'It cures at least until ${widget.minFrom} — release from then.');
    if (early && _note.text.trim().isEmpty) return setState(() => _error = 'Curing runs until ${dateText(b['curing_until'])} — say why it is released early.');
    setState(() => _busy = true);
    try {
      await db.rpc('release_production_batch', params: {'p_batch': b['id'], 'p': {
        'fg_warehouse_id': _fgId, 'release_date': _date, 'note': _note.text.trim().isEmpty ? null : _note.text.trim(),
        'outputs': [
          for (final o in outputs)
            {'output_id': o['id'], 'pieces_passed': passedOf(o).round(), 'rejects': rejectedOf(o) > 0 ? [{'reason_id': _why['${o['id']}'], 'pieces': rejectedOf(o).round()}] : []},
        ],
      }});
      if (_tags.isNotEmpty) await db.rpc('set_batch_quality', params: {'p_batch': b['id'], 'p_tags': _tags});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e, "We couldn't release this batch. Please try again."); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final active = widget.reasons.where((r) => r['status'] == 'active').toList();
    return FullPage(
      title: 'Release ${widget.name} · ${dateText(b['batch_date'])}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Release')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        PlHelp('Curing until ${dateText(b['curing_until'])}. Pieces pass unless you enter rejects.'),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _fgId.isEmpty ? null : _fgId, isExpanded: true, decoration: const InputDecoration(labelText: 'Into'),
              items: [for (final w in fgStores) DropdownMenuItem(value: w.id, child: Text(w.name, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => _fgId = v ?? ''),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: DateField(label: 'Date', value: _date, first: '${b['batch_date']}', last: session.today, onChange: (v) => setState(() => _date = v))),
        ]),
        const SizedBox(height: 10),
        for (final o in outputs)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text('${nameOf(o)}${o['is_primary'] != true ? ' · leftover' : ''}', style: const TextStyle(fontWeight: FontWeight.w600))),
                Text('cast ${qtyText(n(o['pieces_cast']))} · passed ', style: const TextStyle(fontSize: Fs.sm)),
                Text(qtyText(passedOf(o)), style: TextStyle(fontWeight: FontWeight.w700, color: passedOf(o) < 0 ? C.error : null)),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                SizedBox(
                  width: 100,
                  child: TextField(controller: _rej.putIfAbsent('${o['id']}', TextEditingController.new), onChanged: (_) => setState(() {}), keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Reject', hintText: '0')),
                ),
                const SizedBox(width: 8),
                if (rejectedOf(o) > 0)
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _why['${o['id']}'], isExpanded: true,
                      decoration: InputDecoration(labelText: 'Reason', errorText: _why['${o['id']}'] == null ? 'Choose…' : null),
                      items: [for (final r in active) DropdownMenuItem(value: '${r['id']}', child: Text('${r['name']}'))],
                      onChanged: (v) => setState(() { if (v != null) _why['${o['id']}'] = v; }),
                    ),
                  )
                else
                  const Expanded(child: PlHelp('Rejects go into the Rejects store, with their reason.')),
              ]),
            ]),
          ),
        const SizedBox(height: 10),
        // quality issues seen at release (056)
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const PlHelp('Issues seen:'),
          for (final tg in _qcTags) Chip2(tg, on: _tags.contains(tg), onTap: () => setState(() => _tags.contains(tg) ? _tags.remove(tg) : _tags.add(tg))),
        ]),
        const SizedBox(height: 10),
        TextField(controller: _note, decoration: InputDecoration(labelText: early ? 'Why released early? (required)' : 'Quality note (optional)')),
      ],
    );
  }
}

/// Material variance as a table of batches (2026-11-21): a row a batch, newest first — each main material the
/// quantity used with its cost below, material cost, cost a piece; consumables (138) left out of the columns
class _BatchCostTable extends StatefulWidget {
  const _BatchCostTable({required this.batches, required this.refs, required this.loading});
  final List<Json> batches;
  final Refs refs;
  final bool loading;
  @override
  State<_BatchCostTable> createState() => _BatchCostTableState();
}

class _BatchCostTableState extends State<_BatchCostTable> {
  String _period = 'month';

  @override
  Widget build(BuildContext context) {
    final refs = widget.refs;
    final (from, to) = periodRange(_period, session.today);
    final live = widget.batches.where((b) => b['status'] != 'void' && session.inBranch(b['branch_id']) && '${b['batch_date']}'.compareTo(from) >= 0 && '${b['batch_date']}'.compareTo(to) <= 0).toList();
    // batch n of the day, as recorded (the job card's number)
    final dayIds = <String, List<String>>{};
    for (final b in [...live]..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'))) { (dayIds['${b['branch_id']}|${b['batch_date']}'] ??= []).add('${b['id']}'); }
    String nameO(Json o) => '${refs.items['p:${o['product_id']}']?.name ?? '—'}${o['color_id'] != null ? ' ${refs.colour('${o['color_id']}')}' : ''}';
    final rows = [
      for (final b in live)
        () {
          final mats = _l(b['materials']).where((m) => m['source'] != 'consumable' && n(m['quantity']) > 0).toList();
          final outs = _l(b['outputs'])..sort((x, y) => (y['is_primary'] == true ? 1 : 0) - (x['is_primary'] == true ? 1 : 0));
          final cons = _l(b['materials']).where((m) => m['source'] == 'consumable').fold<double>(0, (t, m) => t + n(m['cost']));
          return (
            b: b, n: dayIds['${b['branch_id']}|${b['batch_date']}']!.indexOf('${b['id']}') + 1, mats: mats,
            product: outs.isNotEmpty ? nameO(outs.first) : '—', extra: outs.skip(1).map(nameO).toList(),
            pcs: outs.fold<double>(0, (t, o) => t + n(o['pieces_cast'])),
            cost: b['material_cost'] != null ? n(b['material_cost']) - cons : null,
            perPiece: outs.isNotEmpty && outs.first['cost_per_piece'] != null ? n(outs.first['cost_per_piece']).toDouble() : null,
          );
        }(),
    ]..sort((a, b) {
        final c = '${b.b['batch_date']}'.compareTo('${a.b['batch_date']}');
        return c != 0 ? c : '${b.b['created_at']}'.compareTo('${a.b['created_at']}');
      });
    // the main materials used in the period, in material order; one column each (same material, same unit)
    final colMap = <String, ({String k, String id, String unit, String label, String name, int rank})>{};
    for (final r in rows) {
      for (final x in r.mats) {
        final k = '${x['material_id']}|${x['unit_id']}';
        final it = refs.items['m:${x['material_id']}'];
        colMap.putIfAbsent(k, () => (k: k, id: '${x['material_id']}', unit: refs.unit('${x['unit_id']}'), label: materialShortName(it), name: it?.name ?? '—', rank: it?.rank ?? 999));
      }
    }
    final cols = colMap.values.toList()..sort((a, b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : (a.name != b.name ? a.name.compareTo(b.name) : a.unit.compareTo(b.unit)));
    final seen = <String, Set<String>>{};
    for (final c in cols) { (seen[c.label] ??= {}).add(c.id); }
    String labelOf(({String k, String id, String unit, String label, String name, int rank}) c) => (seen[c.label]?.length ?? 0) > 1 ? c.name : c.label;
    List<Json> cell(dynamic r, String k) => [for (final x in r.mats as List<Json>) if ('${x['material_id']}|${x['unit_id']}' == k) x];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PeriodBar(value: _period, onChange: (v) => setState(() => _period = v)),
      const PlHelp('Tap a batch for its job card.'),
      const SizedBox(height: 10),
      if (widget.loading)
        const Skeleton(rows: 4)
      else if (rows.isEmpty)
        const EmptyState(icon: LucideIcons.layers, title: 'No batches in this period', description: 'Each production batch shows here with the materials it used and their cost.')
      else
        ReportSheet(
          firstWidth: 150,
          // a batch's job card, A4 (one card a batch), as the web's icon on each row
          onRowTap: (i) => openDoc(context, 'Job card PJC batch ${rows[i].n} · ${'${rows[i].b['id']}'.substring(0, 8)}', () => jobCardPdf('${rows[i].b['id']}')),
          head: ['Product', 'Date', 'Batch', 'Pcs', for (final c in cols) '${labelOf(c)} ${c.unit}', 'Material cost (TZS)', 'Cost /pc (TZS)'],
          rows: [
            for (final r in rows)
              [
                RCell(r.product, sub: r.extra.isNotEmpty ? '+ ${r.extra.join(', ')}' : null),
                tableDate(r.b['batch_date']) ?? '', '${r.n}', qtyText(r.pcs),
                for (final c in cols)
                  () {
                    final xs = cell(r, c.k);
                    if (xs.isEmpty) return '';
                    final q = xs.fold<double>(0, (t, x) => t + n(x['quantity'])), k = xs.fold<double>(0, (t, x) => t + n(x['cost']));
                    return RCell(qtyText(_r2(q)), sub: xs.any((x) => x['cost'] != null) ? formatAmount(_r2(k)) : null);
                  }(),
                RCell(r.cost != null ? formatAmount(_r2(r.cost!)) : '—', bold: true),
                r.perPiece != null ? formatAmount(_r2(r.perPiece!)) : '—',
              ],
          ],
          total: [
            'Total', '', '${rows.length}', qtyText(rows.fold<double>(0, (t, r) => t + r.pcs)),
            for (final c in cols)
              () {
                final xs = [for (final r in rows) ...cell(r, c.k)];
                return RCell(qtyText(_r2(xs.fold<double>(0, (t, x) => t + n(x['quantity'])))), sub: formatAmount(_r2(xs.fold<double>(0, (t, x) => t + n(x['cost'])))));
              }(),
            formatMoney(_r2(rows.fold<double>(0, (t, r) => t + (r.cost ?? 0))), session.currency), '',
          ],
        ),
    ]);
  }
}
