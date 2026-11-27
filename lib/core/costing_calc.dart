import 'session.dart';

/*
 * Advanced costing — a port of web lib/costingCalc.js (2026-11-11, migration 118). Pure sums over
 * costing_outputs() rows: a product's cost a unit in four parts (materials, labour, electricity, overheads),
 * month by month; its standard from the 3 months before; actual − standard split by cause (material prices,
 * materials used, labour, electricity, overheads, yield — they add up exactly); rejects at full cost.
 */
double _n(Object? v) => v == null ? 0 : (v is num ? v.toDouble() : double.tryParse('$v') ?? 0);
String costKey(Json r) => '${r['product_id']}|${r['color_id'] ?? ''}';
const costParts = ['material', 'labour', 'power', 'overhead'];
const partLabel = {'material': 'Materials', 'labour': 'Labour', 'power': 'Electricity', 'overhead': 'Overheads'};

class OutRow {
  OutRow(Json r)
      : batchId = '${r['batch_id']}', batchDate = '${r['batch_date']}', productId = '${r['product_id']}', colorId = r['color_id'] as String?,
        bags = _n(r['bags']), qtyCast = _n(r['qty_cast']), qtyPassed = r['qty_passed'] == null ? null : _n(r['qty_passed']), qtyExpected = r['qty_expected'] == null ? null : _n(r['qty_expected']),
        material = r['material'] == null ? null : _n(r['material']), labour = _n(r['labour']), power = _n(r['power']), overhead = _n(r['overhead']),
        materials = [for (final m in (r['materials'] as List? ?? [])) (id: '${m['material_id']}', used: _n(m['used']), recipe: _n(m['recipe']), cost: _n(m['cost']))];
  final String batchId, batchDate, productId;
  final String? colorId;
  final double bags, qtyCast, labour, power, overhead;
  final double? qtyPassed, qtyExpected, material;
  final List<({String id, double used, double recipe, double cost})> materials;
  String get key => '$productId|${colorId ?? ''}';
  double part(String p) => p == 'material' ? (material ?? 0) : p == 'labour' ? labour : p == 'power' ? power : overhead;
}

Future<List<OutRow>> loadOutputs(String branchId, String from, String to) async =>
    [for (final r in (await db.rpc('costing_outputs', params: {'p_branch': branchId, 'p_from': from, 'p_to': to}) as List? ?? [])) OutRow(Map<String, dynamic>.from(r as Map))];

class CostTotals {
  final Set<String> batches = {};
  double bags = 0, qtyCast = 0, qtyPassed = 0, qtyReleased = 0, qtyExpected = 0;
  final Map<String, double> parts = {for (final p in costParts) p: 0};
  final Map<String, ({double used, double recipe, double cost})> materials = {};
  double get total => parts.values.fold(0, (t, v) => t + v);
  int get count => batches.length;
}

/// totals for a set of rows (only outputs with a material cost — the rest aren't costed yet)
CostTotals totals(Iterable<OutRow> rows) {
  final t = CostTotals();
  for (final r in rows) {
    if (r.material == null || !(r.qtyCast > 0)) continue;
    t.batches.add(r.batchId);
    t.bags += r.bags;
    t.qtyCast += r.qtyCast;
    t.qtyExpected += r.qtyExpected ?? 0;
    if (r.qtyPassed != null) { t.qtyPassed += r.qtyPassed!; t.qtyReleased += r.qtyCast; }
    for (final p in costParts) { t.parts[p] = t.parts[p]! + r.part(p); }
    for (final m in r.materials) {
      final x = t.materials[m.id];
      t.materials[m.id] = (used: (x?.used ?? 0) + m.used, recipe: (x?.recipe ?? 0) + m.recipe, cost: (x?.cost ?? 0) + m.cost);
    }
  }
  return t;
}

/// a cost a unit in its four parts (+ total)
Map<String, double>? perUnit(CostTotals t) => t.qtyCast > 0 ? {for (final p in costParts) p: t.parts[p]! / t.qtyCast, 'total': t.total / t.qtyCast} : null;

/// month by month (yyyy-mm), newest on top
List<({String month, double made, int batches, Map<String, double> unit})> trend(List<OutRow> rows) {
  final by = <String, List<OutRow>>{};
  for (final r in rows) { (by[r.batchDate.substring(0, 7)] ??= []).add(r); }
  final keys = by.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final m in keys)
      () { final t = totals(by[m]!); final u = perUnit(t); return u == null ? null : (month: m, made: t.qtyCast, batches: t.count, unit: u); }(),
  ].whereType<({String month, double made, int batches, Map<String, double> unit})>().toList();
}

class Std {
  Std(this.matPerBag, this.yieldPerBag, this.parts, this.batches);
  final double matPerBag, yieldPerBag;
  final Map<String, double> parts;
  final int batches;
  double get unit => parts.values.fold(0, (t, v) => t + v);
}

class Standards {
  Standards(this.price, this.conv, this.byKey);
  final Map<String, double> price, conv;
  final Map<String, Std> byKey;
}

/// standards from the rows of the 3 months before
Standards standards(List<OutRow> rows) {
  final all = totals(rows);
  final price = {for (final e in all.materials.entries) if (e.value.used > 0) e.key: e.value.cost / e.value.used};
  final conv = all.bags > 0
      ? {'labour': all.parts['labour']! / all.bags, 'power': all.parts['power']! / all.bags, 'overhead': all.parts['overhead']! / all.bags}
      : {'labour': 0.0, 'power': 0.0, 'overhead': 0.0};
  final groups = <String, List<OutRow>>{};
  for (final r in rows) { (groups[r.key] ??= []).add(r); }
  final byKey = <String, Std>{};
  for (final e in groups.entries) {
    final t = totals(e.value);
    if (!(t.bags > 0) || !(t.qtyExpected > 0)) continue;
    var matPerBag = 0.0;
    for (final m in t.materials.entries) {
      if (price[m.key] == null) continue;
      matPerBag += (m.value.recipe / t.bags) * price[m.key]!;
    }
    final y = t.qtyExpected / t.bags;
    byKey[e.key] = Std(matPerBag, y, {'material': matPerBag / y, 'labour': conv['labour']! / y, 'power': conv['power']! / y, 'overhead': conv['overhead']! / y}, t.count);
  }
  return Standards(price, conv, byKey);
}

class Variance {
  Variance(this.stdTotal, this.actualTotal, this.stdUnit, this.actualUnit, this.causes, this.rejectQty, this.rejectCost);
  final double stdTotal, actualTotal, stdUnit, actualUnit, rejectQty, rejectCost;
  final Map<String, double> causes;
  double get diff => actualTotal - stdTotal;
}

/// actual against standard for what was made; the causes add up to actual − standard exactly
Variance? variance(CostTotals t, Std? std, Standards s) {
  if (std == null || !(t.qtyCast > 0)) return null;
  var matPrice = 0.0, matUsage = 0.0, recipeMix = 0.0;
  for (final e in t.materials.entries) {
    final m = e.value;
    final p = s.price[e.key] ?? (m.used > 0 ? m.cost / m.used : 0); // no history: this period's own price
    matPrice += m.cost - m.used * p;
    matUsage += (m.used - m.recipe) * p;
    recipeMix += m.recipe * p;
  }
  recipeMix -= t.bags * std.matPerBag; // a recipe that changed in between
  final causes = {
    'matPrice': matPrice,
    'matUsage': matUsage + recipeMix,
    'labour': t.parts['labour']! - t.bags * s.conv['labour']!,
    'power': t.parts['power']! - t.bags * s.conv['power']!,
    'overhead': t.parts['overhead']! - t.bags * s.conv['overhead']!,
    'yield': std.unit * (t.bags * std.yieldPerBag - t.qtyCast),
  };
  final rq = t.qtyReleased - t.qtyPassed > 0 ? t.qtyReleased - t.qtyPassed : 0.0;
  return Variance(t.qtyCast * std.unit, t.total, std.unit, t.total / t.qtyCast, causes, rq, rq * (t.total / t.qtyCast));
}

const causeLabel = {'matPrice': 'Material prices', 'matUsage': 'Materials used', 'labour': 'Labour', 'power': 'Electricity', 'overhead': 'Overheads', 'yield': 'Yield'};
const causeHelp = {
  'matPrice': 'Paid more (+) or less (−) for the materials than their average over the 3 months before',
  'matUsage': 'Used more (+) or less (−) material than the recipe calls for, at the average price',
  'labour': 'Labour a cement bag above (+) or below (−) the 3-month average',
  'power': 'Electricity a cement bag above (+) or below (−) the 3-month average',
  'overhead': 'Production overheads a cement bag above (+) or below (−) the 3-month average',
  'yield': 'Fewer (+) or more (−) pieces / m² from the bags than the usual yield',
};

/// the 3 full months before a period's first day: (from, to)
(String, String) standardWindow(String from) {
  final d = DateTime.parse(from);
  final end = d.subtract(const Duration(days: 1));
  final start = DateTime.utc(d.year, d.month - 3, 1);
  String iso(DateTime x) => '${x.year.toString().padLeft(4, '0')}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
  return (iso(start), iso(end));
}
