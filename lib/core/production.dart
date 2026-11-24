import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../docs/job_card_doc.dart';
import 'format.dart';
import 'pdf_doc.dart';
import 'inventory.dart';
import 'session.dart';
import 'theme.dart';
import 'ui.dart';

/*
 * Production's shared parts — ports of web lib/inventory.js (materialShortName, breakdownMaterials,
 * estimateBatchCosts), components/production/BatchNotes.jsx (useProductionLists, labourNorm, teamLabel),
 * ProductPicker.jsx, ProductionBreakdown.jsx (LOCKED: a batch is a table — materials across as headers,
 * each cell the quantity with its cost small below; team name + people count, no names) and DaySummary.jsx.
 */
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
double _r2(num v) => (v * 100).roundToDouble() / 100;

/// A material's short name for tiles: its code ("CEM" → "Cem"), else the first word of its name
String materialShortName(Item? item) {
  final code = item?.code;
  if (code != null && code.isNotEmpty) return code[0] + code.substring(1).toLowerCase();
  return (item?.name ?? '').split(RegExp(r'[\s/(]+')).first;
}

class BMat {
  BMat({required this.id, required this.label, required this.name, required this.qty, required this.unit, required this.rank, this.steel = false, this.cost});
  final String id, label, name, unit;
  double qty;
  final int rank;
  final bool steel;
  double? cost;
}

/// A batch's materials as the breakdown shows them (with their cost once the batch is saved)
List<BMat> breakdownMaterials(List<Json> lines, Refs refs) => [
      for (final l in lines)
        () {
          final it = refs.items['m:${l['material_id']}'];
          return BMat(
            id: '${l['material_id']}', label: materialShortName(it), name: it?.name ?? '—', qty: n(l['quantity']).toDouble(), unit: refs.unit('${l['unit_id']}'),
            rank: it?.rank ?? 999, steel: RegExp('steel', caseSensitive: false).hasMatch(it?.materialCategory ?? ''), cost: l['cost'] != null ? n(l['cost']).toDouble() : null,
          );
        }(),
    ].where((m) => m.qty > 0).toList();

double? stockFactorOf(Refs refs, Object? materialId, Object? unitId) {
  final it = refs.items['m:$materialId'];
  return it?.units.where((u) => u.id == unitId).firstOrNull?.factor ?? (unitId == it?.stockUnitId ? 1 : null);
}

/// Material cost of batches not saved yet — an estimate (≈) the way 055 costs a saved batch: today's
/// stock layers oldest first; beyond them the latest cost; batches in order. Shared by the cement each takes.
/// batches: [{ materials: [{material_id, quantity, unit_id}], outputs: [{pieces, perBag, sqm}] }]
Future<List<({double cost, bool complete, List<({double? perPiece, double? perSqm})> outputs})>> estimateBatchCosts(Refs refs, String branchId, List<Json> batches) async {
  final ids = {for (final b in batches) for (final m in _l(b['materials'])) '${m['material_id']}'}.toList();
  final vals = await Future.wait([
    for (final id in ids) db.rpc('material_stock_value', params: {'p_branch_id': branchId, 'p_material_id': id}).then<Map?>((v) => (v as List?)?.firstOrNull as Map?).catchError((_) => null),
  ]);
  final values = {for (var i = 0; i < ids.length; i++) ids[i]: vals[i]};
  final layers = {
    for (final id in ids)
      id: [for (final l in (values[id]?['layers'] as List? ?? [])) if (l['cost'] != null && n(l['quantity']) > 0) [n(l['quantity']).toDouble(), n(l['cost']).toDouble()]],
  };
  return [
    for (final b in batches)
      () {
        var cost = 0.0;
        var complete = true;
        for (final m in _l(b['materials'])) {
          final f = stockFactorOf(refs, m['material_id'], m['unit_id']);
          var need = n(m['quantity']) * (f ?? 0);
          if (need > 0 && f == null) { complete = false; continue; }
          final ls = layers['${m['material_id']}'] ?? [];
          while (need > 1e-12 && ls.isNotEmpty) {
            final take = ls.first[0] < need ? ls.first[0] : need;
            cost += take * ls.first[1];
            need -= take;
            ls.first[0] -= take;
            if (ls.first[0] <= 1e-12) ls.removeAt(0);
          }
          final latest = values['${m['material_id']}']?['last_cost'];
          if (need > 1e-12) {
            if (latest != null) { cost += need * n(latest); } else { complete = false; }
          }
        }
        final outs = _l(b['outputs']);
        final byBag = outs.every((o) => !(n(o['pieces']) > 0) || n(o['perBag']) > 0);
        double w(Json o) => n(o['pieces']) > 0 ? (byBag ? n(o['pieces']) / n(o['perBag']) : n(o['pieces']).toDouble()) : 0;
        final total = outs.fold<double>(0, (s, o) => s + w(o));
        return (
          cost: cost, complete: complete,
          outputs: [
            for (final o in outs)
              () {
                final share = total > 0 ? w(o) / total : 0;
                return (perPiece: n(o['pieces']) > 0 ? cost * share / n(o['pieces']) : null, perSqm: n(o['sqm']) > 0 ? cost * share / n(o['sqm']) : null);
              }(),
          ],
        );
      }(),
  ];
}

// ---- teams, machines, people and labour norms (056/057/087) ----------------------------------------
class ProductionLists {
  ProductionLists({required this.ready, this.teams = const [], this.machines = const [], this.links = const [], this.people = const [], this.norms = const {}});
  final bool ready;
  final List<Json> teams, machines, links, people;
  final Map<String, ({double min, double max})> norms;
}

Future<ProductionLists> loadProductionLists(String branchId) async {
  try {
    final r = await Future.wait<dynamic>([
      db.from('production_teams').select('id, name, status, members:production_team_members(staff_id, status)').eq('branch_id', branchId).order('name', ascending: true),
      db.from('machines').select('*').eq('branch_id', branchId).order('name', ascending: true),
      db.from('machine_products').select('machine_id, product_id'),
      db.from('production_people').select('*').eq('branch_id', branchId).order('full_name', ascending: true).then<List>((v) => v).catchError((_) => <dynamic>[]),
      db.from('branch_products').select('product_id, bags_per_person_min, bags_per_person_max').eq('branch_id', branchId).then<List>((v) => v).catchError((_) => <dynamic>[]),
    ]);
    final norms = <String, ({double min, double max})>{
      for (final x in r[4] as List)
        if (x['bags_per_person_min'] != null || x['bags_per_person_max'] != null)
          '${x['product_id']}': (min: n(x['bags_per_person_min'] ?? x['bags_per_person_max']).toDouble(), max: n(x['bags_per_person_max'] ?? x['bags_per_person_min']).toDouble()),
    };
    return ProductionLists(ready: true, teams: _l(r[0]), machines: _l(r[1]), links: _l(r[2]), people: _l(r[3]), norms: norms);
  } catch (_) {
    return ProductionLists(ready: false);
  }
}

/// People a day's batches should take by the labour norms (057): a machine with a crew counts it once a day
({int min, int max, int missing}) labourNorm(ProductionLists? lists, List<({String? machineId, String? productId, double bags})> batches) {
  var min = 0.0, max = 0.0;
  var missing = 0;
  final crews = <String>{};
  for (final b in batches) {
    final m = lists?.machines.where((x) => x['id'] == b.machineId).firstOrNull;
    if (m != null && (m['crew_min'] != null || m['crew_max'] != null)) {
      if (crews.add('${m['id']}')) {
        min += n(m['crew_min'] ?? m['crew_max']);
        max += n(m['crew_max'] ?? m['crew_min']);
      }
      continue;
    }
    final nm = lists?.norms[b.productId];
    if (nm == null) { missing += 1; continue; }
    min += b.bags / nm.max;
    max += b.bags / nm.min;
  }
  return (min: (min - 1e-9).ceil(), max: (max - 1e-9).ceil(), missing: missing);
}

/// The team's name and how many worked: "Juma team (5 people)"
String? teamLabel(ProductionLists? lists, String? teamId, List<String>? workerIds) {
  final t = lists?.teams.where((x) => x['id'] == teamId).firstOrNull;
  if (t == null) return null;
  return (workerIds?.isNotEmpty ?? false) ? '${t['name']} (${workerIds!.length} ${workerIds.length == 1 ? 'person' : 'people'})' : '${t['name']}';
}

// ---- ProductPicker: search, category chips, cards with size and wastani; the branch's most cast first ----
Future<String?> pickProduct(BuildContext context, {String title = 'Select primary product', required List<Item> items, required CategoryTools cats,
    Map<String, int> usage = const {}, Map<String, Object?> wastani = const {}, Map<String, Json>? capacity, String Function(Item)? metaOf, List<String> usageLabel = const ['batch', 'batches']}) =>
    Navigator.push<String>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _Picker(title: title, items: items, cats: cats, usage: usage, wastani: wastani, capacity: capacity, metaOf: metaOf, usageLabel: usageLabel)));

String? capOf(Json? c) {
  if (c == null) return null;
  if (c['molds'] != null && n(c['molds']) > 0) return '${qtyText(n(c['molds']))} molds';
  final lo = c['bags_per_day_min'] ?? c['bags_per_day_max'], hi = c['bags_per_day_max'] ?? c['bags_per_day_min'];
  return lo != null ? '${qtyText(n(lo))}${n(hi) != n(lo) ? '–${qtyText(n(hi))}' : ''} bags/day' : null;
}

class _Picker extends StatefulWidget {
  const _Picker({required this.title, required this.items, required this.cats, required this.usage, required this.wastani, this.capacity, this.metaOf, required this.usageLabel});
  final String title;
  final List<Item> items;
  final CategoryTools cats;
  final Map<String, int> usage;
  final Map<String, Object?> wastani;
  final Map<String, Json>? capacity;
  final String Function(Item)? metaOf;
  final List<String> usageLabel;
  @override
  State<_Picker> createState() => _PickerState();
}

class _PickerState extends State<_Picker> {
  String _q = '', _cat = '';
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final cats = widget.cats;
    // chips in the organization's category order
    final chips = {for (final i in widget.items) if (i.categoryId != null) i.categoryId!: i.category ?? ''}.entries.toList()
      ..sort((a, b) {
        final ca = cats.byId[a.key], cb = cats.byId[b.key];
        final c = ca != null && cb != null ? cats.compare(ca, cb) : 0;
        return c != 0 ? c : a.value.compareTo(b.value);
      });
    final order = productOrder(cats);
    final q = _q.trim().toLowerCase();
    final shown = widget.items.where((i) => (_cat.isEmpty || i.categoryId == _cat) && (q.isEmpty || '${i.name} ${i.category ?? ''}'.toLowerCase().contains(q))).toList()
      ..sort((a, b) {
        final c = (widget.usage[b.id] ?? 0).compareTo(widget.usage[a.id] ?? 0);
        return c != 0 ? c : order(a, b);
      });
    return FullPage(title: widget.title, children: [
      const PlHelp('Filter by product name or category.'),
      const SizedBox(height: 8),
      TextField(autofocus: true, onChanged: (v) => setState(() => _q = v), onSubmitted: (_) { if (shown.isNotEmpty) Navigator.pop(context, shown.first.id); },
          decoration: InputDecoration(hintText: 'Search by product name…', prefixIcon: Icon(LucideIcons.search, size: 16, color: t.textMuted))),
      const SizedBox(height: 8),
      SlideRow(children: [Chip2('All', on: _cat.isEmpty, onTap: () => setState(() => _cat = '')), for (final c in chips) Chip2(c.value, on: _cat == c.key, onTap: () => setState(() => _cat = _cat == c.key ? '' : c.key))]),
      const SizedBox(height: 10),
      if (shown.isEmpty) const PlHelp('No product matches.'),
      for (final (k, i) in shown.indexed)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: t.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => Navigator.pop(context, i.id),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text('#${k + 1} ', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                    // products: name on top, category below (LOCKED)
                    Expanded(child: Text(i.name, style: const TextStyle(fontWeight: FontWeight.w700))),
                    if (capOf(widget.capacity?[i.id]) != null) Badge2(widget.capacity![i.id]?['molds'] != null ? capOf(widget.capacity![i.id])! : '~${capOf(widget.capacity![i.id])}'),
                    if ((widget.usage[i.id] ?? 0) > 0) ...[const SizedBox(width: 4), Badge2('${widget.usage[i.id]} ${widget.usage[i.id] == 1 ? widget.usageLabel[0] : widget.usageLabel[1]}', tone: Tone.info)],
                  ]),
                  PlHelp(i.category ?? ''),
                  PlHelp(widget.metaOf != null
                      ? widget.metaOf!(i)
                      : [if ((i.size ?? '').isNotEmpty) 'Size: ${i.size}', n(widget.wastani[i.id]) > 0 ? 'Wastani: ${qtyText(n(widget.wastani[i.id]))} pcs/bag' : 'No wastani set'].join(' • ')),
                ]),
              ),
            ),
          ),
        ),
    ]);
  }
}

// ---- ProductionBreakdown: a batch as a table (LOCKED 2026-11-20) ------------------------------------
class BOut {
  BOut({required this.name, this.pieces, this.passed, this.residual = false, this.perBag, this.perPiece, this.perSqm});
  final String name;
  final num? pieces, passed, perBag;
  final bool residual;
  double? perPiece, perSqm;
}

class BBatch {
  BBatch({required this.n, required this.bags, required this.outputs, required this.materials, this.stage, this.cost, this.costComplete, this.estimate = false,
      this.team, this.people, this.machine, this.consumables, this.qcTags = const [], this.qcNote, this.id, this.onJobCard});
  final int n;
  final double bags;
  final List<BOut> outputs;
  final List<BMat> materials;
  final String? stage, team, machine, qcNote, id;
  double? cost;
  bool? costComplete;
  bool estimate;
  final int? people;
  final double? consumables;
  final List<String> qcTags;
  final VoidCallback? onJobCard;
}

int _byRank(BMat a, BMat b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : a.name.compareTo(b.name);

class ProductionBreakdown extends StatelessWidget {
  const ProductionBreakdown({super.key, required this.batches, this.dayTotal = true, this.stageBadge});
  final List<BBatch> batches;
  final bool dayTotal;
  final Widget Function(String stage)? stageBadge;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final costed = batches.any((b) => b.cost != null);
    String money(num v) => formatMoney(v, session.currency);
    Widget unitCost(BOut o, bool est) => o.perPiece == null
        ? const PlHelp('—')
        : Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('${est ? '≈ ' : ''}${money(o.perPiece!)} /pc', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: Fs.xs)),
            if (o.perSqm != null) PlHelp('${money(o.perSqm!)} /m²'),
          ]);
    final live = batches.where((b) => b.stage != 'Void').toList();
    double pcs(BBatch b) => b.outputs.fold(0, (s, o) => s + n(o.pieces));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final b in batches)
        Opacity(
          opacity: b.stage == 'Void' ? 0.55 : 1,
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(10)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('Batch ${b.n}', style: const TextStyle(fontWeight: FontWeight.w700)),
                // the team's name and how many worked — not their names (2026-11-20, the user)
                PlHelp('${qtyText(_r2(b.bags))} bags${b.outputs.length > 1 ? ' · ${qtyText(pcs(b))} pcs' : ''}${b.team != null ? ' · ${b.team!.split(' (').first}' : ''}'
                    '${b.people != null ? ' · ${b.people} ${b.people == 1 ? 'person' : 'people'}' : ''}${b.machine != null ? ' · ${b.machine}' : ''}'),
                if (b.cost != null)
                  Text.rich(TextSpan(style: const TextStyle(fontSize: Fs.xs), children: [
                    const TextSpan(text: 'material cost '),
                    TextSpan(text: '${b.estimate ? '≈ ' : ''}${money(b.cost!)}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    if (b.costComplete == false) const TextSpan(text: ' · part not costed'),
                    if ((b.consumables ?? 0) > 0) TextSpan(text: ' · consumables ${money(b.consumables!)}'),
                  ])),
                if (b.stage != null && stageBadge != null) stageBadge!(b.stage!),
                // a saved batch's job card, A4 (2026-11-20, the user): one card a batch
                if (b.onJobCard != null || b.id != null) IconButton(tooltip: 'View job card', onPressed: b.onJobCard ?? () => openDoc(context, 'Job card PJC batch ${b.n} · ${b.id!.substring(0, 8)}', () => jobCardPdf(b.id!)), icon: const Icon(LucideIcons.fileText, size: 16), visualDensity: VisualDensity.compact),
              ]),
              const SizedBox(height: 6),
              _MaterialTable(
                mats: [...b.materials]..sort(_byRank), costed: costed,
                rows: [
                  if (b.outputs.isNotEmpty)
                    () {
                      final main = b.outputs.where((o) => !o.residual).firstOrNull ?? b.outputs.first;
                      return [
                        _Row(name: main.name, pieces: main.pieces, passed: main.passed, mats: [...b.materials]..sort(_byRank), perBag: b.bags > 0 ? n(main.pieces) / b.bags : null, cost: unitCost(main, b.estimate)),
                        for (final o in b.outputs.where((o) => o != main))
                          _Row(name: '+ ${o.name}', pieces: o.pieces, passed: o.passed, residual: true, sameMix: 'residual · same mix as ${main.name}', cost: unitCost(o, b.estimate)),
                      ];
                    }(),
                ].expand((x) => x).toList(),
              ),
              if (b.qcTags.isNotEmpty || (b.qcNote ?? '').isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 4), child: PlHelp('QC ${b.qcTags.join(', ')}${(b.qcNote ?? '').isNotEmpty ? ' — ${b.qcNote}' : ''}')),
            ]),
          ),
        ),
      if (dayTotal && batches.length > 1)
        Builder(builder: (_) {
          final sum = <String, BMat>{};
          for (final b in live) {
            for (final m in b.materials) {
              final k = '${m.id}|${m.unit}';
              sum[k] ??= BMat(id: m.id, label: m.label, name: m.name, qty: 0, unit: m.unit, rank: m.rank, steel: m.steel, cost: 0);
              sum[k]!.qty += m.qty;
            }
          }
          final allCosted = live.every((b) => b.materials.every((x) => x.cost != null));
          for (final s in sum.values) {
            s.cost = allCosted ? live.fold<double>(0, (t2, b) => t2 + b.materials.where((x) => x.id == s.id && x.unit == s.unit).fold<double>(0, (u, x) => u + (x.cost ?? 0))) : null;
          }
          final all = sum.values.toList()..sort(_byRank);
          return Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: t.soft, border: Border.all(color: t.borderStrong), borderRadius: BorderRadius.circular(10)),
            child: _MaterialTable(mats: all, costed: costed, rows: [
              _Row(name: 'Day total · ${live.length} batch${live.length == 1 ? '' : 'es'}', pieces: live.fold<double>(0, (s, b) => s + pcs(b)), mats: all, bold: true,
                  cost: Text('${live.any((b) => b.estimate) ? '≈ ' : ''}${money(live.fold<double>(0, (s, b) => s + (b.cost ?? 0)))}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: Fs.xs))),
            ]),
          );
        }),
    ]);
  }
}

class _Row {
  _Row({required this.name, this.pieces, this.passed, this.mats = const [], this.perBag, this.cost, this.residual = false, this.sameMix, this.bold = false});
  final String name;
  final num? pieces, passed, perBag;
  final List<BMat> mats;
  final Widget? cost;
  final bool residual, bold;
  final String? sameMix;
}

/// The materials across as headers; each cell the quantity used with its cost small below
class _MaterialTable extends StatelessWidget {
  const _MaterialTable({required this.mats, required this.rows, required this.costed});
  final List<BMat> mats;
  final List<_Row> rows;
  final bool costed;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final seen = <String, Set<String>>{};
    for (final m in mats) { (seen[m.label] ??= {}).add(m.id); }
    String labelOf(BMat m) => (seen[m.label]?.length ?? 0) > 1 ? m.name : m.label;
    const w = 74.0;
    Widget head(String s, {String? unit, double width = w, bool left = false}) => Container(
          width: width, padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          alignment: left ? Alignment.centerLeft : Alignment.centerRight,
          child: Text.rich(TextSpan(children: [
            TextSpan(text: s, style: TextStyle(fontSize: Fs.xs, fontWeight: FontWeight.w700, color: t.textMuted)),
            if (unit != null) TextSpan(text: ' $unit', style: TextStyle(fontSize: 10, color: t.textMuted)),
          ]), maxLines: 2, textAlign: left ? TextAlign.left : TextAlign.right),
        );
    Widget cell(Widget c, {double width = w, bool left = false}) => Container(width: width, padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5), alignment: left ? Alignment.topLeft : Alignment.topRight, child: c);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.borderStrong))),
          child: Row(children: [
            head('Product', width: 130, left: true), head('Qty'),
            for (final m in mats) head(labelOf(m), unit: m.unit),
            head('Pcs/bag'), if (costed) head('Cost', width: 96),
          ]),
        ),
        for (final r in rows)
          Container(
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              cell(Text(r.name, style: TextStyle(fontSize: Fs.sm, fontWeight: r.residual ? FontWeight.w400 : FontWeight.w600, color: r.residual ? t.textSecondary : null)), width: 130, left: true),
              cell(Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text('${qtyText(n(r.pieces))} pcs', style: const TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w700)),
                if (r.passed != null) PlHelp('${qtyText(n(r.passed))} passed'),
              ])),
              if (r.sameMix != null)
                cell(PlHelp(r.sameMix!), width: w * (mats.isEmpty ? 1 : mats.length), left: true)
              else
                for (final m in mats)
                  cell(Builder(builder: (_) {
                    final x = r.mats.where((y) => y.id == m.id && y.unit == m.unit).firstOrNull;
                    if (x == null) return const SizedBox.shrink();
                    return Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(qtyText(_r2(x.qty)), style: const TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w700)),
                      if (x.cost != null) Text(formatAmount(x.cost!.roundToDouble()), style: TextStyle(fontSize: 10, color: t.textMuted)),
                    ]);
                  })),
              cell(Text(r.perBag != null ? qtyText(_r2(r.perBag!)) : '', style: const TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w700))),
              if (costed) cell(r.cost ?? const SizedBox.shrink(), width: 96),
            ]),
          ),
      ]),
    );
  }
}

/// A day's production at a glance (DaySummary): the head, the breakdown, what is left in the store
class DaySummary extends StatelessWidget {
  const DaySummary({super.key, required this.date, required this.branchName, required this.batches, this.curingUntil, this.curingDays, this.people, this.norm, this.left = const []});
  final String date, branchName;
  final List<BBatch> batches;
  final String? curingUntil;
  final int? curingDays, people;
  final ({int min, int max, int missing})? norm;
  final List<({String name, String label, double left, String unit, bool short, int rank})> left;
  @override
  Widget build(BuildContext context) {
    final bags = batches.fold<double>(0, (s, b) => s + b.bags);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 12, runSpacing: 4, children: [
        Text('${dateText(date)} · $branchName', style: const TextStyle(fontWeight: FontWeight.w700)),
        Text('${batches.length} batch${batches.length == 1 ? '' : 'es'} · ${qtyText(_r2(bags))} bags'),
        if (people != null)
          Text.rich(TextSpan(children: [
            TextSpan(text: '$people', style: const TextStyle(fontWeight: FontWeight.w700)),
            TextSpan(text: ' ${people == 1 ? 'person' : 'people'}'),
            if (norm != null && norm!.max > 0)
              TextSpan(text: ' · norm ${norm!.min == norm!.max ? norm!.min : '${norm!.min}–${norm!.max}'}${norm!.missing > 0 ? ' (${norm!.missing} batch${norm!.missing == 1 ? '' : 'es'} without a norm)' : ''}',
                  style: TextStyle(color: people! < norm!.min ? C.warning : null, fontSize: Fs.xs)),
          ])),
        if (curingUntil != null) Text('Curing until ${dateText(curingUntil)}${curingDays != null ? ' ($curingDays days)' : ''}'),
      ]),
      const SizedBox(height: 10),
      ProductionBreakdown(batches: batches),
      if (left.isNotEmpty) ...[
        const SizedBox(height: 6),
        const PlLabel('Left in store after this'),
        const SizedBox(height: 4),
        Wrap(spacing: 12, runSpacing: 6, children: [
          for (final m in [...left]..sort((a, b) => a.rank.compareTo(b.rank)))
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              PlHelp(m.label),
              Text('${qtyText(_r2(m.left))} ${m.unit}', style: TextStyle(fontWeight: FontWeight.w700, color: m.short ? C.error : null)),
            ]),
        ]),
        if (left.any((m) => m.short)) PlHelp('Short: ${left.where((m) => m.short).map((m) => m.name).join(', ')}', color: C.error),
      ],
    ]);
  }
}
