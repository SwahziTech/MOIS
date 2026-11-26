import 'format.dart';
import 'inventory.dart';
import 'session.dart';

/*
 * A port of the web's lib/dailyReport.js: the two-way daily report in the branches' Swahili format.
 *   RIPOTI YA <BRANCH> TAREHE dd/mm/yy · UZALISHAJI WA … · Pcs … Cem … Wastani … · (MABAKI) ·
 *   TEAM WATU … · CEMENT ILIYOPO STORE NI … BAGS · UMEME … ASUBUHI / JIONI / ILIYOTUMIKA
 * loadDayFacts reads what MOIS holds; writeReport writes it; readReport reads a written one back;
 * compareReport lines the two up.
 */
double _num(String v) => double.tryParse(v.replaceAll(',', '')) ?? 0;
String _fmt(num v) {
  final r = (v * 100).round() / 100;
  final whole = formatAmount(r.truncate());
  final frac = ((r.abs() - r.abs().truncate()) * 100).round();
  return frac == 0 ? formatAmount(r) : '$whole.${frac.toString().padLeft(2, '0').replaceAll(RegExp(r'0$'), '')}';
}

Future<Json> loadDayFacts(String branchId, String date, String today, Refs refs) async {
  final res = await Future.wait<dynamic>([
    db.from('production_batches').select('id, cement_bags, worker_ids, outputs:production_batch_outputs(product_id, color_id, is_primary, pieces_cast)').eq('branch_id', branchId).eq('batch_date', date).neq('status', 'void'),
    db.from('power_readings').select('meter_id, slot, reading, read_at').eq('branch_id', branchId).eq('read_on', date).eq('status', 'recorded'),
    db.from('power_daily').select('meter_id, day_units, token_missing').eq('branch_id', branchId).eq('day', date).then<List>((v) => v).catchError((_) => <dynamic>[]),
    db.from('power_meters').select('id, name, status').eq('branch_id', branchId).order('name', ascending: true).then<List>((v) => v).catchError((_) => <dynamic>[]),
    date.compareTo(today) < 0 ? db.rpc('stock_balances_as_of', params: {'p_date': date}) : db.from('stock_balances').select('warehouse_id, material_id, product_id, quantity'),
    db.from('recipe_items').select('material_id, quantity, unit_id'),
  ]);
  final cementIds = {for (final x in res[5] as List) if (refs.unit(x['unit_id']).toLowerCase() == 'bag' && n(x['quantity']) == 1) x['material_id']};
  final byKey = <String, Json>{};
  for (final b in res[0] as List) {
    final outs = (b['outputs'] as List).cast<Map>();
    final main = outs.where((o) => o['is_primary'] == true).firstOrNull;
    if (main == null) continue;
    final k = '${main['product_id']}|${main['color_id'] ?? ''}';
    final e = byKey.putIfAbsent(k, () => {'name': refs.productLabel(main['product_id'], main['color_id']), 'pieces': 0.0, 'cement': 0.0, 'all': 0.0, 'workers': <String>{}, 'leftovers': <String, Json>{}});
    e['pieces'] = n(e['pieces']) + n(main['pieces_cast']);
    e['cement'] = n(e['cement']) + n(b['cement_bags']);
    e['all'] = n(e['all']) + n(main['pieces_cast']);
    (e['workers'] as Set<String>).addAll(((b['worker_ids'] as List?) ?? []).cast<String>());
    for (final o in outs.where((x) => x['is_primary'] != true)) {
      final lk = '${o['product_id']}|${o['color_id'] ?? ''}';
      final lo = e['leftovers'] as Map<String, Json>;
      lo[lk] = {'name': refs.productLabel(o['product_id'], o['color_id']), 'pieces': n(lo[lk]?['pieces']) + n(o['pieces_cast'])};
      e['all'] = n(e['all']) + n(o['pieces_cast']);
    }
  }
  final whs = {for (final w in refs.warehouses.where((w) => w.branchId == branchId)) w.id};
  double? cementStore;
  final names = <String>{};
  for (final r in (res[4] as List).where((x) => x['material_id'] != null && whs.contains(x['warehouse_id']))) {
    final it = refs.items['m:${r['material_id']}'];
    if (it == null || !cementIds.contains(r['material_id'])) continue;
    final bag = it.units.where((u) => refs.unit(u.id).toLowerCase() == 'bag').firstOrNull;
    cementStore = (cementStore ?? 0) + n(r['quantity']) / (bag?.factor ?? 1);
    names.add(it.name);
  }
  final meters = [
    for (final x in (res[3] as List).where((x) => x['status'] == 'active'))
      (() {
        final rd = (res[1] as List).where((y) => y['meter_id'] == x['id']);
        final d = (res[2] as List).where((y) => y['meter_id'] == x['id']).firstOrNull;
        final mo = rd.where((y) => y['slot'] == 'morning').firstOrNull, ev = rd.where((y) => y['slot'] == 'evening').firstOrNull;
        final used = d?['day_units'] != null ? n(d['day_units']) : (mo != null && ev != null ? n(mo['reading']) - n(ev['reading']) : null);
        return <String, dynamic>{'name': x['name'], 'morning': mo == null ? null : n(mo['reading']), 'evening': ev == null ? null : n(ev['reading']), 'used': used, 'tokenMissing': d?['token_missing'] == true};
      })(),
  ];
  return {
    'products': [
      for (final e in byKey.values)
        {
          'name': e['name'], 'pieces': e['pieces'], 'cement': e['cement'],
          'wastani': n(e['cement']) > 0 ? (n(e['all']) / n(e['cement'])).floor() : null,
          'leftovers': (e['leftovers'] as Map<String, Json>).values.toList(),
          'people': (e['workers'] as Set).isEmpty ? null : (e['workers'] as Set).length,
        },
    ],
    'cementStore': cementStore == null ? null : r2(cementStore),
    'cementName': names.join(', '),
    'meters': meters,
  };
}

String writeReport(Json facts, String branchName, String date) {
  final p = date.split('-');
  final out = <String>['RIPOTI YA ${branchName.toUpperCase()} TAREHE ${p[2]}/${p[1]}/${p[0].substring(2)}', ''];
  final products = (facts['products'] as List).cast<Map>();
  if (products.isEmpty) out.addAll(['HAKUNA UZALISHAJI', '']);
  for (final x in products) {
    out.add('UZALISHAJI WA ${'${x['name']}'.toUpperCase()}');
    out.add('Pcs ${_fmt(n(x['pieces']))} Cem ${_fmt(n(x['cement']))}${x['wastani'] != null ? ' Wastani ${x['wastani']}' : ''}');
    for (final l in (x['leftovers'] as List)) { out.add('${'${l['name']}'.toUpperCase()} Pcs ${_fmt(n(l['pieces']))} (MABAKI)'); }
    if (x['people'] != null) out.add('TEAM WATU ${x['people']}');
    out.add('');
  }
  if (facts['cementStore'] != null) out.addAll(['CEMENT ILIYOPO STORE NI ${_fmt(n(facts['cementStore']))} BAGS', '']);
  for (final m in (facts['meters'] as List)) {
    out.add('UMEME ${'${m['name']}'.toUpperCase()}');
    out.add('ASUBUHI - ${m['morning'] != null ? _fmt(n(m['morning'])) : '—'}');
    out.add('JIONI - ${m['evening'] != null ? _fmt(n(m['evening'])) : '—'}');
    out.add('ILIYOTUMIKA - ${m['used'] != null ? _fmt(n(m['used'])) : '—'}');
    out.add('');
  }
  return out.join('\n').trim();
}

String? readDate(String text) {
  final m = RegExp(r'TAREHE\s*[:.]?\s*(\d{1,2})\s*[/.-]\s*(\d{1,2})\s*[/.-]\s*(\d{2,4})').firstMatch(text.toUpperCase());
  if (m == null) return null;
  final y = m[3]!.length == 2 ? 2000 + int.parse(m[3]!) : int.parse(m[3]!);
  final s = '$y-${m[2]!.padLeft(2, '0')}-${m[1]!.padLeft(2, '0')}';
  final d = DateTime.tryParse(s);
  return d == null || iso(d) != s ? null : s;
}

Json readReport(String text) {
  final res = <String, dynamic>{'date': readDate(text), 'products': <Json>[], 'cementStore': null, 'meters': <Json>[]};
  Json? prod, meter;
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    final u = line.toUpperCase();
    final pcs = RegExp(r'PCS\s*[:.]?\s*([\d,]+)').firstMatch(u);
    final cem = RegExp(r'CEM\w*\s*[:.]?\s*([\d.,]+)').firstMatch(u);
    final head = RegExp(r'^UZALISHAJI\s+WA\s+(.+?)(?=\s+PCS\b|$)').firstMatch(u);
    if (head != null) {
      prod = {'name': head[1]!.trim(), 'pieces': pcs != null ? _num(pcs[1]!) : null, 'cement': cem != null ? _num(cem[1]!) : null, 'leftovers': <Json>[], 'people': null};
      (res['products'] as List).add(prod);
      meter = null;
      continue;
    }
    if (RegExp(r'^UMEME\b').hasMatch(u)) {
      meter = {'name': line.replaceFirst(RegExp(r'^umeme\s*', caseSensitive: false), '').trim(), 'morning': null, 'evening': null, 'used': null};
      (res['meters'] as List).add(meter);
      prod = null;
      continue;
    }
    final store = RegExp(r'CEMENT.*STORE[^\d]*([\d.,]+)').firstMatch(u);
    if (store != null) { res['cementStore'] = _num(store[1]!); prod = null; meter = null; continue; }
    if (meter != null) {
      final v = RegExp(r'([\d.,]+)\s*$').firstMatch(u);
      if (u.contains('ASUBUHI') && v != null) {
        meter['morning'] = _num(v[1]!);
      } else if (u.contains('JIONI') && v != null) {
        meter['evening'] = _num(v[1]!);
      } else if ((u.contains('ILIYOTUMIKA') || u.contains('IMETUMIKA')) && v != null) {
        meter['used'] = _num(v[1]!);
      }
      continue;
    }
    if (prod == null) continue;
    final team = RegExp(r'TEAM\s+WATU\s*(\d+)').firstMatch(u) ?? RegExp(r'WATU\s*(\d+)').firstMatch(u);
    if (team != null) { prod['people'] = _num(team[1]!); continue; }
    if (u.contains('MABAKI') && pcs != null) {
      (prod['leftovers'] as List).add({'name': u.substring(0, u.indexOf('PCS')).replaceAll(RegExp(r'\(?MABAKI\)?'), '').trim(), 'pieces': _num(pcs[1]!)});
      continue;
    }
    if (pcs != null && prod['pieces'] == null) { prod['pieces'] = _num(pcs[1]!); if (cem != null) prod['cement'] = _num(cem[1]!); }
  }
  return res;
}

List<String> _words(String s) => s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ').split(RegExp(r'\s+')).where((w) => w.isNotEmpty && w != 'cm' && w != 'pcs').toList();
Json? _bestMatch(String name, List<Json> list) {
  final a = _words(name);
  Json? best;
  var score = 0;
  for (final x in list) {
    final b = _words('${x['name']}');
    final s = a.where((w) => b.any((v) => v == w || (RegExp(r'^\d+$').hasMatch(w) && v.replaceAll(RegExp(r'(cm|mm)$'), '') == w) || (w.length >= 3 && (v.startsWith(w) || w.startsWith(v)))))
        .fold<int>(0, (t, w) => t + w.length);
    if (s > score) { best = x; score = s; }
  }
  return best;
}

/// Report vs MOIS → rows { section, item, report, mois }
List<Json> compareReport(Json read, Json facts) {
  final rows = <Json>[];
  final used = <Json>{};
  final fp = (facts['products'] as List).cast<Json>();
  for (final p in (read['products'] as List).cast<Json>()) {
    final m = _bestMatch('${p['name']}', fp.where((x) => !used.contains(x)).toList());
    if (m != null) used.add(m);
    final item = m != null ? '${p['name']} ↔ ${m['name']}' : '${p['name']}';
    rows.add({'section': 'Production', 'item': '$item · pieces', 'report': p['pieces'], 'mois': m?['pieces']});
    rows.add({'section': 'Production', 'item': '$item · cement', 'report': p['cement'], 'mois': m?['cement']});
    final lr = (p['leftovers'] as List).fold<double>(0, (t, l) => t + n(l['pieces']));
    final lm = m == null ? null : (m['leftovers'] as List).fold<double>(0, (t, l) => t + n(l['pieces']));
    if (lr > 0 || (lm ?? 0) > 0) rows.add({'section': 'Production', 'item': '$item · leftovers (mabaki)', 'report': lr > 0 ? lr : null, 'mois': lm});
    if (p['people'] != null || m?['people'] != null) rows.add({'section': 'Production', 'item': '$item · team', 'report': p['people'], 'mois': m?['people']});
  }
  for (final m in fp.where((x) => !used.contains(x))) {
    rows.add({'section': 'Production', 'item': '${m['name']} · pieces (not in the report)', 'report': null, 'mois': m['pieces']});
  }
  rows.add({'section': 'Cement', 'item': 'Cement in store (bags)', 'report': read['cementStore'], 'mois': facts['cementStore']});
  final usedM = <Json>{};
  final fm = (facts['meters'] as List).cast<Json>();
  for (final r in (read['meters'] as List).cast<Json>()) {
    final m = _bestMatch('${r['name']}', fm.where((x) => !usedM.contains(x)).toList());
    if (m != null) usedM.add(m);
    final item = m != null ? '${m['name']}' : '${r['name']}';
    rows.add({'section': 'Electricity', 'item': '$item · morning', 'report': r['morning'], 'mois': m?['morning']});
    rows.add({'section': 'Electricity', 'item': '$item · evening', 'report': r['evening'], 'mois': m?['evening']});
    rows.add({'section': 'Electricity', 'item': '$item · used', 'report': r['used'], 'mois': m?['used']});
  }
  for (final m in fm.where((x) => !usedM.contains(x))) {
    rows.add({'section': 'Electricity', 'item': '${m['name']} · used (not in the report)', 'report': null, 'mois': m['used']});
  }
  return rows;
}

/// the closest name in [list] (each with 'name'), as the web's bestMatch; null when nothing shares a word
Json? bestMatch(String name, List<Json> list) => _bestMatch(name, list);

/// a name's words, lower case, as the web's words()
List<String> words(String s) => _words(s);
