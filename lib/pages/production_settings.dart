import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';

/*
 * Production settings — a port of web components/production/ProductionSettings.jsx, opened from the ⚙ beside
 * the Production heading: curing (organization), the branch's teams & machines (056 / 087 / 135), reject reasons.
 * Online only.
 */
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];

Future<void> openProductionSettings(BuildContext context) => Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (ctx) => FullPage(
      title: 'Production settings',
      footer: [OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      children: const [_Curing(), SizedBox(height: 10), _TeamsCard(), SizedBox(height: 10), _ReasonsCard()],
    )));

String _err(Object e) => e is PostgrestException && e.code == '23505' ? 'That name is already on the list.' : dbError(e);

// ---- Curing: days before quality release (042) and the fewest days (054) ----
class _Curing extends StatefulWidget {
  const _Curing();
  @override
  State<_Curing> createState() => _CuringState();
}

class _CuringState extends State<_Curing> {
  Json? _org;
  String? _editing; // 'curing_days' | 'min_curing_days'
  final _value = TextEditingController();
  bool _busy = false;
  String _error = '';
  bool get canEdit => session.canManage('org.manage');

  @override
  void initState() {
    super.initState();
    db.from('organizations').select('*').eq('id', session.organization!['id']).maybeSingle().then((d) { if (mounted) setState(() => _org = d); }).catchError((_) {});
  }

  Future<void> _save() async {
    final k = _editing!;
    final v = _value.text.trim();
    final d = v.isEmpty ? null : int.tryParse(v);
    if ((k == 'curing_days' && d == null) || (v.isNotEmpty && (d == null || d < 0 || d > 365))) {
      setState(() => _error = k == 'curing_days' ? 'Enter whole days, 0 to 365.' : 'Enter whole days, 0 to 365, or leave blank for no minimum.');
      return;
    }
    setState(() { _error = ''; _busy = true; });
    try {
      await db.from('organizations').update({k: d}).eq('id', session.organization!['id']);
      _org = {...?_org, k: d};
      _editing = null;
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget _row(String label, String k, String shown, String help) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: _editing == k
            ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Row(children: [
                  SizedBox(width: 90, child: TextField(controller: _value, autofocus: true, keyboardType: TextInputType.number, decoration: InputDecoration(isDense: true, hintText: k == 'min_curing_days' ? 'None' : null))),
                  const SizedBox(width: 6),
                  const Text('days'),
                  const Spacer(),
                  FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
                  TextButton(onPressed: () => setState(() { _editing = null; _error = ''; }), child: const Text('Cancel')),
                ]),
                PlHelp(help),
                if (_error.isNotEmpty) PlHelp(_error, color: C.error),
              ])
            : Row(children: [
                Expanded(child: Text(label)),
                Text(shown, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (canEdit) TextButton(onPressed: () => setState(() { _editing = k; _error = ''; _value.text = _org?[k] == null ? '' : '${_org![k]}'; }), child: const Text('Change')),
              ]),
      );

  @override
  Widget build(BuildContext context) => CardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Curing', style: TextStyle(fontWeight: FontWeight.w700)),
          if (_org == null)
            const Skeleton(rows: 2)
          else ...[
            _row('Curing period', 'curing_days', '${_org!['curing_days']} days', 'Days before quality release.'),
            if (_org!.containsKey('min_curing_days'))
              _row('Minimum curing', 'min_curing_days', _org!['min_curing_days'] == null ? 'No minimum' : '${_org!['min_curing_days']} days', 'Release is refused before this; from it on, no reason is needed.'),
          ],
        ]),
      );
}

// ---- a name line: rename, retire / bring back ----
class _NameLine extends StatefulWidget {
  const _NameLine({required this.row, required this.canEdit, required this.busy, required this.run, required this.offWord, required this.onWord, required this.offLabel});
  final Json row;
  final bool canEdit, busy;
  final Future<bool> Function(Future<dynamic> Function() q) run;
  final String offWord, onWord, offLabel;
  @override
  State<_NameLine> createState() => _NameLineState();
}

class _NameLineState extends State<_NameLine> {
  TextEditingController? _rename;
  @override
  Widget build(BuildContext context) {
    final r = widget.row;
    final off = r['status'] == 'inactive';
    if (_rename != null) {
      return Row(children: [
        Expanded(child: TextField(controller: _rename, autofocus: true, decoration: const InputDecoration(isDense: true, labelText: 'Name'))),
        FilledButton(
          onPressed: widget.busy ? null : () async {
            final name = _rename!.text.trim();
            if (name.isEmpty) return;
            if (await widget.run(() => db.from(r['_table'] as String).update({'name': name}).eq('id', r['id']))) setState(() => _rename = null);
          },
          child: const Text('Save'),
        ),
        TextButton(onPressed: () => setState(() => _rename = null), child: const Text('Cancel')),
      ]);
    }
    return Row(children: [
      Expanded(child: Text.rich(TextSpan(children: [
        TextSpan(text: '${r['name']}', style: TextStyle(fontWeight: FontWeight.w600, color: off ? context.tk.textMuted : null)),
        if (off) TextSpan(text: ' · ${widget.offLabel}', style: TextStyle(fontSize: Fs.xs, color: context.tk.textMuted)),
      ]))),
      if (widget.canEdit)
        PopupMenuButton<String>(
          icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
          enabled: !widget.busy,
          onSelected: (v) => v == 'rename'
              ? setState(() => _rename = TextEditingController(text: '${r['name']}'))
              : widget.run(() => db.from(r['_table'] as String).update({'status': off ? 'active' : 'inactive'}).eq('id', r['id'])),
          itemBuilder: (_) => [const PopupMenuItem(value: 'rename', child: Text('Rename')), PopupMenuItem(value: 'status', child: Text(off ? widget.onWord : widget.offWord))],
        ),
    ]);
  }
}

class _AddRow extends StatefulWidget {
  const _AddRow({required this.placeholder, required this.busy, required this.onAdd});
  final String placeholder;
  final bool busy;
  final Future<bool> Function(String name) onAdd;
  @override
  State<_AddRow> createState() => _AddRowState();
}

class _AddRowState extends State<_AddRow> {
  final _c = TextEditingController();
  @override
  void initState() { super.initState(); _c.addListener(() => setState(() {})); }
  Future<void> _add() async { if (_c.text.trim().isNotEmpty && await widget.onAdd(_c.text.trim())) _c.clear(); }
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: TextField(controller: _c, onSubmitted: (_) => _add(), decoration: InputDecoration(isDense: true, hintText: widget.placeholder))),
        IconButton(tooltip: widget.placeholder, onPressed: widget.busy || _c.text.trim().isEmpty ? null : _add, icon: const Icon(LucideIcons.plus, size: 18)),
      ]);
}

// ---- Production teams & machines of a branch ----
class _TeamsCard extends StatefulWidget {
  const _TeamsCard();
  @override
  State<_TeamsCard> createState() => _TeamsCardState();
}

class _TeamsCardState extends State<_TeamsCard> {
  late String _branch = session.branchId.isNotEmpty ? session.branchId : (session.branches.firstOrNull?.id ?? '');
  Json? _data; // null = loading; {'ready': false} before 056
  bool _busy = false;
  String _error = '';
  bool get canEdit => _branch.isNotEmpty && (session.canAt('production.create', _branch, null) || session.canAt('products.manage', _branch, null));
  Object? get org => session.organization!['id'];

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    if (_branch.isEmpty) return;
    try {
      final r = await Future.wait<dynamic>([
        db.from('production_teams').select('id, name, status').eq('branch_id', _branch).order('name', ascending: true),
        db.from('machines').select('*').eq('branch_id', _branch).order('name', ascending: true),
        db.from('machine_products').select('machine_id, product_id'),
        db.from('branch_products').select('product_id, product:products(canonical_name)').eq('branch_id', _branch).eq('status', 'active'),
        db.from('warehouses').select('id, name').eq('branch_id', _branch).eq('type', 'wip').eq('status', 'active').order('name', ascending: true),
      ]);
      if (!mounted) return;
      setState(() => _data = {
            'ready': true,
            'teams': [for (final t in _l(r[0])) {...t, '_table': 'production_teams'}],
            'machines': [for (final m in _l(r[1])) {...m, '_table': 'machines'}],
            'links': _l(r[2]), 'curing': _l(r[4]),
            'products': [for (final x in _l(r[3])) {'id': '${x['product_id']}', 'name': '${(x['product'] as Map?)?['canonical_name'] ?? '—'}'}]..sort((a, b) => a['name']!.compareTo(b['name']!)),
          });
    } catch (_) {
      if (mounted) setState(() => _data = {'ready': false});
    }
  }

  Future<bool> run(Future<dynamic> Function() q) async {
    setState(() { _error = ''; _busy = true; });
    var ok = true;
    try { await q(); } catch (e) { _error = _err(e); ok = false; }
    if (mounted) setState(() => _busy = false);
    if (ok) _load();
    return ok;
  }

  String crewText(Json m) => m['crew_min'] == null ? '' : m['crew_min'] == m['crew_max'] ? '${m['crew_min']}' : '${m['crew_min']}-${m['crew_max']}';

  Future<void> _crew(Json m, String text) async {
    final v = text.trim();
    final c = v.isEmpty ? null : v.split(RegExp('[-–]')).map((x) => int.tryParse(x.trim())).toList();
    if (c != null && (c.length > 2 || c.any((x) => x == null || x <= 0) || (c.length == 2 && c[0]! > c[1]!))) {
      setState(() => _error = 'Crew: whole people, like 12 or 9-12, or blank.');
      return;
    }
    final lo = c?.first, hi = c?.last;
    if (lo != m['crew_min'] || hi != m['crew_max']) await run(() => db.from('machines').update({'crew_min': lo, 'crew_max': hi}).eq('id', m['id']));
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d != null && d['ready'] != true) return const SizedBox.shrink();
    final t = context.tk;
    return CardBox(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Production teams & machines', style: TextStyle(fontWeight: FontWeight.w700)),
        if (session.branches.length > 1) ...[
          const SizedBox(height: 6),
          SlideRow(children: [for (final b in session.branches) Chip2(b.name, on: _branch == b.id, onTap: () => setState(() { _branch = b.id; _data = null; _load(); }))]),
        ],
        const Tooltip(
          message: "Every batch records its team and machine; who worked is ticked on each batch from the branch's staff (HR › Staff), as teams change day to day. "
              "Retired ones stay on past batches. New ones can also be added in the batch form. A machine's crew (e.g. 9-12) is the people it takes to run, whatever the bags — products without it use their bags a person (Products).",
          child: PlHelp('Teams and machines for batches.'),
        ),
        if (d == null)
          const Skeleton(rows: 3)
        else ...[
          const SizedBox(height: 8),
          const Text('Teams', style: TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.sm)),
          if ((d['teams'] as List).isEmpty) const PlHelp('No teams yet.'),
          for (final tm in d['teams'] as List<Json>) _NameLine(row: tm, canEdit: canEdit, busy: _busy, run: run, offWord: 'Retire', onWord: 'Bring back', offLabel: 'retired'),
          if (canEdit) _AddRow(placeholder: 'New team', busy: _busy, onAdd: (name) => run(() => db.from('production_teams').insert({'organization_id': org, 'branch_id': _branch, 'name': name}))),
          const Divider(height: 22),
          const Text('Machines / lines', style: TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.sm)),
          if ((d['machines'] as List).isEmpty) const PlHelp('No machines yet.'),
          for (final m in d['machines'] as List<Json>) _machine(m, d, t),
          if (canEdit) _AddRow(placeholder: 'New machine or line', busy: _busy, onAdd: (name) => run(() => db.from('machines').insert({'organization_id': org, 'branch_id': _branch, 'name': name}))),
          if (_error.isNotEmpty) PlHelp(_error, color: C.error),
        ],
      ]),
    );
  }

  Widget _machine(Json m, Json d, Tokens t) {
    final products = d['products'] as List<Map<String, String>>;
    final made = [for (final l in (d['links'] as List<Json>).where((l) => l['machine_id'] == m['id'])) ...products.where((p) => p['id'] == '${l['product_id']}')];
    final curing = d['curing'] as List<Json>;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 8),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: t.border)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _NameLine(row: m, canEdit: canEdit, busy: _busy, run: run, offWord: 'Retire', onWord: 'Bring back', offLabel: 'retired'),
        Wrap(spacing: 10, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (m.containsKey('crew_min'))
            Row(mainAxisSize: MainAxisSize.min, children: [
              const PlHelp('crew '),
              SizedBox(width: 70, child: TextFormField(
                  key: ValueKey('crew-${m['id']}-${crewText(m)}'), initialValue: crewText(m), enabled: canEdit && !_busy,
                  decoration: const InputDecoration(isDense: true, hintText: '—'),
                  onFieldSubmitted: (v) => _crew(m, v), onChanged: (v) => m['_crew'] = v,
              )),
              if (canEdit) IconButton(tooltip: 'Save crew', visualDensity: VisualDensity.compact, icon: const Icon(LucideIcons.check, size: 16), onPressed: _busy ? null : () => _crew(m, '${m['_crew'] ?? crewText(m)}')),
            ]),
          // where its batches cure (135) — the batch form takes it; blank = asked on the form
          if (m.containsKey('curing_warehouse_id') && curing.isNotEmpty)
            SizedBox(width: 200, child: DropdownButtonFormField<String>(
              initialValue: '${m['curing_warehouse_id'] ?? ''}', isExpanded: true, decoration: const InputDecoration(isDense: true, labelText: 'Cures in'),
              items: [const DropdownMenuItem(value: '', child: Text('Ask on the form')), for (final w in curing) DropdownMenuItem(value: '${w['id']}', child: Text('${w['name']}', overflow: TextOverflow.ellipsis))],
              onChanged: !canEdit || _busy ? null : (v) => run(() => db.from('machines').update({'curing_warehouse_id': (v ?? '').isEmpty ? null : v}).eq('id', m['id'])),
            )),
        ]),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (made.isEmpty) const PlHelp('Makes any product'),
          for (final p in made)
            InputChip(
              label: Text(p['name']!, style: const TextStyle(fontSize: Fs.xs)), visualDensity: VisualDensity.compact,
              onDeleted: canEdit && !_busy ? () => run(() => db.from('machine_products').delete().eq('machine_id', m['id']).eq('product_id', p['id']!)) : null,
            ),
          if (canEdit && m['status'] == 'active')
            PopupMenuButton<String>(
              enabled: !_busy,
              tooltip: 'A product made on ${m['name']}',
              onSelected: (id) => run(() => db.from('machine_products').insert({'machine_id': m['id'], 'product_id': id, 'organization_id': org})),
              itemBuilder: (_) => [for (final p in products.where((p) => !made.contains(p))) PopupMenuItem(value: p['id'], child: Text(p['name']!))],
              child: const Padding(padding: EdgeInsets.symmetric(horizontal: 8, vertical: 6), child: Text('+ Product…', style: TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w600))),
            ),
        ]),
      ]),
    );
  }
}

// ---- Reject reasons: picked for the rejected pieces at a batch's quality release ----
class _ReasonsCard extends StatefulWidget {
  const _ReasonsCard();
  @override
  State<_ReasonsCard> createState() => _ReasonsCardState();
}

class _ReasonsCardState extends State<_ReasonsCard> {
  List<Json>? _rows;
  bool _busy = false;
  String _error = '';
  bool get canEdit => session.canManage('products.manage');

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final d = _l(await db.from('reject_reasons').select('id, name, status, display_order').order('display_order', ascending: true).order('name', ascending: true));
      if (mounted) setState(() => _rows = [for (final x in d) {...x, '_table': 'reject_reasons'}]);
    } catch (_) {
      if (mounted) setState(() => _rows = []);
    }
  }

  Future<bool> run(Future<dynamic> Function() q) async {
    setState(() { _error = ''; _busy = true; });
    var ok = true;
    try { await q(); } catch (e) { _error = _err(e); ok = false; }
    if (mounted) setState(() => _busy = false);
    if (ok) _load();
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows == null || rows.isEmpty) return const SizedBox.shrink();
    return CardBox(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Reject reasons', style: TextStyle(fontWeight: FontWeight.w700)),
        const PlHelp("Picked for the rejected pieces at a batch's quality release after curing."),
        const SizedBox(height: 6),
        for (final c in rows) _NameLine(row: c, canEdit: canEdit, busy: _busy, run: run, offWord: 'Stop using', onWord: 'Use again', offLabel: 'not in use'),
        if (canEdit)
          _AddRow(placeholder: 'New reason', busy: _busy, onAdd: (name) {
            final orders = [for (final c in rows) if (n(c['display_order']) < 99) n(c['display_order'])];
            final next = (orders.isEmpty ? 0 : orders.reduce((a, b) => a > b ? a : b)) + 1; // "Other" (99) stays last
            return run(() => db.from('reject_reasons').insert({'organization_id': session.organization!['id'], 'name': name, 'display_order': next}));
          }),
        if (_error.isNotEmpty) PlHelp(_error, color: C.error),
      ]),
    );
  }
}
