import 'format.dart';
import 'inventory.dart';
import 'session.dart';

/*
 * Reports — a full port of web lib/reports.js (1f, PRD 4.15): read for a date range, filtered to the
 * branches the viewer sees. Each loader returns the plain rows the Reports page lists, totals and
 * exports. (core/dashboard_data.dart keeps its own short versions for the dashboard cards.)
 */
double _sum<T>(Iterable<T> list, num Function(T) f) => list.fold<double>(0, (t, x) => t + f(x));
bool _in(String d, String from, String to) => d.compareTo(from) >= 0 && d.compareTo(to) <= 0;
String _label(Refs refs, Object? pid, Object? cid) => [refs.items['p:$pid']?.name ?? '?', if (cid != null) refs.colour('$cid')].where((x) => x.isNotEmpty).join(' ');

/// Production: per main product (and colour) — batches, cement, pieces, passed, rejected, material cost
Future<Json> rpProduction(Refs refs, String from, String to) async {
  final data = await db.from('production_batches')
      .select('id, branch_id, batch_date, cement_bags, status, material_cost, outputs:production_batch_outputs(product_id, color_id, is_primary, pieces_cast, pieces_passed), rejects:production_batch_rejects(pieces)')
      .gte('batch_date', from).lte('batch_date', to).neq('status', 'void');
  final batches = [for (final b in data) if (session.inBranch(b['branch_id'])) b];
  final by = <String, Json>{};
  for (final b in batches) {
    final outs = [for (final o in (b['outputs'] as List? ?? [])) o as Map];
    final main = outs.where((o) => o['is_primary'] == true).firstOrNull;
    if (main == null) continue;
    final k = '${main['product_id']}|${main['color_id'] ?? ''}';
    final r = by.putIfAbsent(k, () => {'key': k, 'name': _label(refs, main['product_id'], main['color_id']), 'batches': 0.0, 'bags': 0.0, 'pieces': 0.0, 'leftovers': 0.0, 'passed': 0.0, 'released': 0.0, 'rejected': 0.0, 'cost': 0.0, 'curing': 0.0});
    void add(String f, num v) => r[f] = n(r[f]) + v;
    add('batches', 1);
    add('bags', n(b['cement_bags']));
    add('pieces', n(main['pieces_cast']));
    add('leftovers', _sum(outs.where((o) => o['is_primary'] != true), (o) => n(o['pieces_cast'])));
    if (b['status'] == 'released') {
      add('released', n(main['pieces_cast']));
      add('passed', n(main['pieces_passed'] ?? main['pieces_cast']));
      add('rejected', _sum([for (final x in (b['rejects'] as List? ?? [])) x as Map], (x) => n(x['pieces'])));
    }
    if (b['status'] == 'curing') add('curing', n(main['pieces_cast']));
    add('cost', n(b['material_cost']));
  }
  final rows = [
    for (final r in by.values)
      {
        ...r,
        'wastani': n(r['bags']) > 0 ? (n(r['pieces']) + n(r['leftovers'])) / n(r['bags']) : null,
        'rejectPct': n(r['released']) > 0 ? n(r['rejected']) / n(r['released']) * 100 : null,
        'perPiece': n(r['pieces']) > 0 ? n(r['cost']) / (n(r['pieces']) + n(r['leftovers'])) : null,
      },
  ]..sort((a, b) => n(b['pieces']).compareTo(n(a['pieces'])));
  return {'rows': rows, 'batches': batches.length};
}

/// Sales: orders and invoices dated in the range — per product and per customer; payments received in the range
Future<Json> rpSales(Refs refs, String from, String to) async {
  final r = await Future.wait<dynamic>([
    db.from('sales').select('id, branch_id, stage, customer_id, walk_in_name, sale_date, ordered_on, invoiced_on, subtotal, vat, total, lines:sale_lines(product_id, item_name, color_id, quantity, unit_id, amount, vat, total)')
        .inFilter('stage', ['order', 'invoice']),
    db.from('sale_payments').select('amount, paid_on, sale:sales!inner(branch_id)').gte('paid_on', from).lte('paid_on', to),
    db.from('customers').select('id, name'),
    db.from('sale_balances').select('branch_id, stage, balance').inFilter('stage', ['order', 'invoice']),
  ]);
  String dateOf(Map x) => '${x['invoiced_on'] ?? x['ordered_on'] ?? x['sale_date']}';
  final sales = [for (final x in r[0] as List) if (session.inBranch(x['branch_id']) && _in(dateOf(x), from, to)) x as Map];
  final custName = {for (final c in r[2] as List) '${c['id']}': '${c['name']}'};
  final prod = <String, Json>{}, cust = <String, Json>{};
  for (final x in sales) {
    final who = x['customer_id'] != null ? custName['${x['customer_id']}'] ?? '?' : ('${x['walk_in_name'] ?? ''}'.isEmpty ? 'Walk-in' : '${x['walk_in_name']}');
    final cr = cust.putIfAbsent(who, () => {'name': who, 'docs': 0.0, 'amount': 0.0, 'vat': 0.0, 'total': 0.0});
    cr['docs'] = n(cr['docs']) + 1;
    cr['amount'] = n(cr['amount']) + n(x['subtotal']);
    cr['vat'] = n(cr['vat']) + n(x['vat']);
    cr['total'] = n(cr['total']) + n(x['total']);
    for (final l in (x['lines'] as List? ?? [])) {
      // other items (104) by their name
      final k = l['product_id'] != null ? '${l['product_id']}|${l['color_id'] ?? ''}' : 'other|${'${l['item_name'] ?? ''}'.trim().toLowerCase()}';
      final pr = prod.putIfAbsent(k, () => {
            'key': k, 'name': l['product_id'] != null ? _label(refs, l['product_id'], l['color_id']) : '${l['item_name']} (other item)',
            'unit': refs.unit(l['unit_id']), 'quantity': 0.0, 'amount': 0.0, 'vat': 0.0, 'total': 0.0,
          });
      for (final f in ['quantity', 'amount', 'vat', 'total']) {
        pr[f] = n(pr[f]) + n(l[f]);
      }
    }
  }
  return {
    'docs': sales.length, 'amount': _sum(sales, (x) => n(x['subtotal'])), 'vat': _sum(sales, (x) => n(x['vat'])), 'total': _sum(sales, (x) => n(x['total'])),
    'received': _sum([for (final x in r[1] as List) if (session.inBranch(x['sale']['branch_id'])) x as Map], (x) => n(x['amount'])),
    'owed': _sum([for (final x in r[3] as List) if (session.inBranch(x['branch_id']) && n(x['balance']) > 0) x as Map], (x) => n(x['balance'])),
    'products': prod.values.toList()..sort((a, b) => n(b['total']).compareTo(n(a['total']))),
    'customers': cust.values.toList()..sort((a, b) => n(b['total']).compareTo(n(a['total']))),
  };
}

/// Purchases by supplier and expenses by category, dated in the range
Future<Json> rpSpending(String from, String to) async {
  final r = await Future.wait<dynamic>([
    db.from('purchases').select('id, branch_id, supplier_id, purchase_date, status').eq('status', 'recorded').gte('purchase_date', from).lte('purchase_date', to),
    db.from('expenses').select('branch_id, category_id, amount, amount_paid, expense_date, status').eq('status', 'recorded').gte('expense_date', from).lte('expense_date', to),
    db.from('suppliers').select('id, name'),
    db.from('expense_categories').select('id, name'),
  ]);
  final buys = [for (final x in r[0] as List) if (session.inBranch(x['branch_id'])) x as Map];
  final t = buys.isEmpty ? <dynamic>[] : await db.from('purchase_totals').select('purchase_id, total, amount_paid, balance').inFilter('purchase_id', [for (final x in buys) x['id']]);
  final totals = {for (final x in t) '${x['purchase_id']}': x as Map};
  final supName = {for (final s in r[2] as List) '${s['id']}': '${s['name']}'};
  final catName = {for (final c in r[3] as List) '${c['id']}': '${c['name']}'};
  final bySup = <String, Json>{}, byCat = <String, Json>{};
  for (final x in buys) {
    final nm = supName['${x['supplier_id']}'] ?? 'No supplier';
    final row = bySup.putIfAbsent(nm, () => {'name': nm, 'count': 0.0, 'total': 0.0, 'paid': 0.0, 'owed': 0.0});
    final tt = totals['${x['id']}'] ?? {};
    row['count'] = n(row['count']) + 1;
    row['total'] = n(row['total']) + n(tt['total']);
    row['paid'] = n(row['paid']) + n(tt['amount_paid']);
    row['owed'] = n(row['owed']) + n(tt['balance']);
  }
  for (final x in [for (final e in r[1] as List) if (session.inBranch(e['branch_id'])) e as Map]) {
    final nm = catName['${x['category_id']}'] ?? 'No category';
    final row = byCat.putIfAbsent(nm, () => {'name': nm, 'count': 0.0, 'total': 0.0, 'paid': 0.0, 'owed': 0.0});
    row['count'] = n(row['count']) + 1;
    row['total'] = n(row['total']) + n(x['amount']);
    row['paid'] = n(row['paid']) + n(x['amount_paid']);
    row['owed'] = n(row['owed']) + n(x['amount']) - n(x['amount_paid']);
  }
  final suppliers = bySup.values.toList()..sort((a, b) => n(b['total']).compareTo(n(a['total'])));
  final categories = byCat.values.toList()..sort((a, b) => n(b['total']).compareTo(n(a['total'])));
  return {
    'suppliers': suppliers, 'categories': categories,
    'purchases': _sum(suppliers, (x) => n(x['total'])), 'expenses': _sum(categories, (x) => n(x['total'])),
    'owed': _sum(suppliers, (x) => n(x['owed'])) + _sum(categories, (x) => n(x['owed'])),
  };
}

/// Materials used by production: recipe (standard) vs actual, in stock units, and their cost
Future<List<Json>> rpMaterialUse(Refs refs, String from, String to) async {
  final data = await db.from('production_batch_materials')
      .select('material_id, quantity, unit_id, stock_quantity, standard_quantity, source, cost, batch:production_batches!inner(branch_id, batch_date, status)')
      .gte('batch.batch_date', from).lte('batch.batch_date', to).neq('batch.status', 'void');
  final by = <String, Json>{};
  for (final m in [for (final x in data) if (session.inBranch(x['batch']['branch_id'])) x]) {
    final it = refs.items['m:${m['material_id']}'];
    final factor = it?.units.where((u) => u.id == m['unit_id']).firstOrNull?.factor ?? 1;
    final r = by.putIfAbsent('${m['material_id']}', () => {
          'id': m['material_id'], 'name': it?.name ?? '?', 'category': it?.materialCategory ?? '', 'rank': it?.rank ?? 999,
          'unit': refs.unit(it?.stockUnitId), 'actual': 0.0, 'standard': 0.0, 'counted': 0.0, 'cost': 0.0, 'costKnown': true,
        });
    r['actual'] = n(r['actual']) + n(m['stock_quantity']);
    if (m['standard_quantity'] != null) r['standard'] = n(r['standard']) + n(m['standard_quantity']) * factor;
    if (m['source'] == 'counted') r['counted'] = n(r['counted']) + n(m['stock_quantity']);
    if (m['cost'] == null) {
      r['costKnown'] = false;
    } else {
      r['cost'] = n(r['cost']) + n(m['cost']);
    }
  }
  return [
    for (final r in by.values)
      {
        ...r,
        'diff': n(r['standard']) != 0 ? n(r['actual']) - n(r['standard']) : null,
        'diffPct': n(r['standard']) != 0 ? (n(r['actual']) - n(r['standard'])) / n(r['standard']) * 100 : null,
      },
  ]..sort((a, b) {
      final c = n(a['rank']).compareTo(n(b['rank']));
      return c != 0 ? c : '${a['name']}'.compareTo('${b['name']}');
    });
}

/// Basic profit: goods delivered (without VAT) less their production cost = gross margin; less the expenses
/// not already in product cost (not ticked into it, not electricity, not wages/statutory) and office pay
Future<Json> rpProfit(String from, String to) async {
  final r = await Future.wait<dynamic>([
    db.from('sale_delivery_lines').select('value, cost, estimated_cost, line:sale_lines!inner(amount, total), delivery:sale_deliveries!inner(delivered_on, sale:sales!inner(branch_id))')
        .gte('delivery.delivered_on', from).lte('delivery.delivered_on', to),
    db.from('expenses').select('branch_id, category_id, amount, status, expense_date').eq('status', 'recorded').gte('expense_date', from).lte('expense_date', to),
    db.from('expense_categories').select('*'),
    db.from('pay_sheet_lines').select('*, sheet:pay_sheets!inner(branch_id, status, paid_on)').eq('sheet.status', 'paid').gte('sheet.paid_on', from).lte('sheet.paid_on', to)
        .then<List?>((v) => v).catchError((_) => null),
    db.from('staff').select('id, in_production_cost'),
  ]);
  final lines = [for (final x in r[0] as List) if (session.inBranch(x['delivery']['sale']['branch_id'])) x as Map];
  double exVat(Map x) => n(x['line']['total']) != 0 ? n(x['value']) * n(x['line']['amount']) / n(x['line']['total']) : n(x['value']).toDouble();
  final sales = _sum(lines, exVat);
  final cost = _sum(lines, (x) => n(x['cost']));
  final noCost = lines.where((x) => x['cost'] == null).length;
  final estimated = _sum(lines, (x) => n(x['estimated_cost']));
  bool skip(Map? c) => c == null || c['in_production_cost'] == true || RegExp('electric|luku|umeme|wages|statutory', caseSensitive: false).hasMatch('${c['name']}');
  final byCat = <String, Json>{};
  for (final x in [for (final e in r[1] as List) if (session.inBranch(e['branch_id'])) e as Map]) {
    final c = (r[2] as List).where((k) => k['id'] == x['category_id']).firstOrNull as Map?;
    if (skip(c)) continue;
    final row = byCat.putIfAbsent('${c!['name']}', () => {'name': c['name'], 'total': 0.0});
    row['total'] = n(row['total']) + n(x['amount']);
  }
  final office = {for (final s in r[4] as List) if (s['in_production_cost'] != true) '${s['id']}'};
  final pay = r[3] as List?;
  final officePay = pay == null
      ? null
      : _sum([for (final l in pay) if (session.inBranch(l['sheet']['branch_id']) && office.contains('${l['staff_id']}')) l as Map],
          (l) => n(l['gross'] ?? l['amount']) + n(l['nssf_employer']) + n(l['wcf']) + n(l['sdl']));
  final expenses = byCat.values.toList()..sort((a, b) => n(b['total']).compareTo(n(a['total'])));
  final other = _sum(expenses, (x) => n(x['total'])) + (officePay ?? 0);
  return {
    'sales': sales, 'cost': cost, 'margin': sales - cost, 'noCost': noCost, 'estimated': estimated, 'expenses': expenses,
    'officePay': officePay, 'net': sales - cost - other, 'deliveries': lines.length,
  };
}

/// Each branch side by side: production, sales, purchases, expenses
Future<List<Json>> rpBranches(String from, String to) async {
  final r = await Future.wait<dynamic>([
    db.from('production_batches').select('branch_id, cement_bags, outputs:production_batch_outputs(is_primary, pieces_cast)').gte('batch_date', from).lte('batch_date', to).neq('status', 'void'),
    db.from('sales').select('branch_id, stage, sale_date, ordered_on, invoiced_on, total').inFilter('stage', ['order', 'invoice']),
    db.from('purchases').select('id, branch_id').eq('status', 'recorded').gte('purchase_date', from).lte('purchase_date', to),
    db.from('expenses').select('branch_id, amount').eq('status', 'recorded').gte('expense_date', from).lte('expense_date', to),
  ]);
  final buys = r[2] as List;
  final t = buys.isEmpty ? <dynamic>[] : await db.from('purchase_totals').select('purchase_id, branch_id, total').inFilter('purchase_id', [for (final x in buys) x['id']]);
  String dateOf(Map x) => '${x['invoiced_on'] ?? x['ordered_on'] ?? x['sale_date']}';
  return [
    for (final br in session.branches.where((b) => session.inBranch(b.id)))
      () {
        final bb = [for (final x in r[0] as List) if (x['branch_id'] == br.id) x as Map];
        return <String, dynamic>{
          'id': br.id, 'name': br.name,
          'batches': bb.length, 'bags': _sum(bb, (x) => n(x['cement_bags'])),
          'pieces': _sum(bb, (x) => _sum([for (final o in (x['outputs'] as List? ?? [])) if (o['is_primary'] == true) o as Map], (o) => n(o['pieces_cast']))),
          'sales': _sum([for (final x in r[1] as List) if (x['branch_id'] == br.id && _in(dateOf(x), from, to)) x as Map], (x) => n(x['total'])),
          'purchases': _sum([for (final x in t) if (x['branch_id'] == br.id) x as Map], (x) => n(x['total'])),
          'expenses': _sum([for (final x in r[3] as List) if (x['branch_id'] == br.id) x as Map], (x) => n(x['amount'])),
        };
      }(),
  ];
}
