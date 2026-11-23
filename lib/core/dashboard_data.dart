import 'format.dart';
import 'inventory.dart';
import 'session.dart';

/*
 * Ports of the web's lib/directorBoard.js, lib/dashboard.js and the report loaders the
 * dashboard uses (lib/reports.js loadSales / loadProduction / loadMaterialUse / loadProfit,
 * lib/statements.js stockAtCost). Same queries, same figures.
 */
double _sum<T>(Iterable<T> rows, num? Function(T) f) => rows.fold<double>(0, (t, x) => t + (f(x) ?? 0).toDouble());
bool _inRange(Object? d, String from, String to) => d != null && '$d'.compareTo(from) >= 0 && '$d'.compareTo(to) <= 0;
const _useDays = 14, _lowDays = 7;
String _monthsBack(String m, int k) { final d = DateTime.utc(int.parse(m.substring(0, 4)), int.parse(m.substring(5, 7)) - k); return iso(d).substring(0, 7); }
String _weekStartOf(String d) => shiftDay(d, -(DateTime.parse(d).weekday % 7));
int _daysSinceMonday(String d) { final w = DateTime.parse(d).weekday % 7; return w == 0 ? 0 : w - 1; }
String monthShortOf(String m) => const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][int.parse(m.substring(5, 7)) - 1];
String _monthLongOf(String m) => '${monthLong[int.parse(m.substring(5, 7)) - 1]} ${m.substring(0, 4)}';

class DPeriod {
  const DPeriod(this.key, this.label, this.note, this.from, this.to, this.cFrom, this.cTo, this.cLabel);
  final String key, label, note, from, to, cFrom, cTo, cLabel;
}

/// periodsFor: today first, the days back to Monday, weeks, months, quarters, years
List<DPeriod> periodsFor(String today) {
  final month = today.substring(0, 7);
  String sameDayIn(String m) { final a = '$m-${today.substring(8)}', b = lastOfMonth('$m-01'); return a.compareTo(b) < 0 ? a : b; }
  final y = shiftDay(today, -1);
  final sun = _weekStartOf(today);
  final lastSun = shiftDay(sun, -7);
  final prevM = _monthsBack(month, 1), prevPrev = _monthsBack(month, 2);
  final quarterStart = _monthsBack(month, (int.parse(month.substring(5)) - 1) % 3);
  final prevQ = _monthsBack(quarterStart, 3);
  final year = today.substring(0, 4), lastYear = '${int.parse(year) - 1}';
  final n = _daysSinceMonday(today) - 1;
  return [
    DPeriod('today', 'Today', dateText(today)!, today, today, y, y, 'yesterday'),
    DPeriod('yesterday', 'Yesterday', dateText(y)!, y, y, shiftDay(y, -1), shiftDay(y, -1), 'the day before'),
    for (var i = 0; i < (n > 0 ? n : 0); i++)
      (() { final d = shiftDay(today, -(i + 2)); return DPeriod('day-${i + 2}', weekdayLong[DateTime.parse(d).weekday - 1], dateText(d)!, d, d, shiftDay(d, -1), shiftDay(d, -1), 'the day before'); })(),
    DPeriod('week', 'This week', '${dateText(sun)} – ${dateText(shiftDay(sun, 5))}', sun, today, lastSun, shiftDay(today, -7), 'last week'),
    DPeriod('lastweek', 'Last week', '${dateText(lastSun)} – ${dateText(shiftDay(lastSun, 5))}', lastSun, shiftDay(lastSun, 6), shiftDay(lastSun, -7), shiftDay(lastSun, -1), 'the week before'),
    DPeriod('month', 'This month', _monthLongOf(month), '$month-01', today, '$prevM-01', sameDayIn(prevM), 'same days ${monthShortOf(prevM)}'),
    DPeriod('lastmonth', 'Last month', _monthLongOf(prevM), '$prevM-01', lastOfMonth('$prevM-01'), '$prevPrev-01', lastOfMonth('$prevPrev-01'), monthShortOf(prevPrev)),
    DPeriod('quarter', 'This quarter', '${monthShortOf(quarterStart)} – today', '$quarterStart-01', today, '$prevQ-01', sameDayIn(_monthsBack(month, 3)), 'same days last quarter'),
    DPeriod('lastquarter', 'Last quarter', '${monthShortOf(prevQ)} – ${monthShortOf(_monthsBack(quarterStart, 1))} ${prevQ.substring(0, 4)}', '$prevQ-01',
        lastOfMonth('${_monthsBack(quarterStart, 1)}-01'), '${_monthsBack(prevQ, 3)}-01', lastOfMonth('${_monthsBack(prevQ, 1)}-01'), 'the quarter before'),
    DPeriod('year', 'This year', year, '$year-01-01', today, '$lastYear-01-01', '$lastYear${today.substring(4)}', 'same days $lastYear'),
    DPeriod('lastyear', 'Last year', lastYear, '$lastYear-01-01', '$lastYear-12-31', '${int.parse(lastYear) - 1}-01-01', '${int.parse(lastYear) - 1}-12-31', '${int.parse(lastYear) - 1}'),
  ];
}

/// The back arrow's path: today, each day back to Monday, last week, last month
List<String> periodSteps(String today) {
  final days = _daysSinceMonday(today);
  return ['today', if (days >= 1) 'yesterday', for (var i = 0; i < (days - 1 > 0 ? days - 1 : 0); i++) 'day-${i + 2}', 'lastweek', 'lastmonth'];
}

// ---- the director's board ---------------------------------------------------------------
class Need {
  const Need(this.key, this.count, this.label, this.to);
  final String key, label, to;
  final int count;
}

Future<List<Json>> loadOrdersToPay() async {
  final res = await Future.wait<dynamic>([
    db.from('purchase_orders').select('id, po_no, branch_id, order_date, request_id, amount_paid, paid_on, supplier:suppliers(id, name, phone, pay_bank, pay_account_no, pay_account_name), lines:purchase_order_lines(line_no, kind, quantity, unit_price, unit_id, material_id, material:materials(name), unit:units(symbol))').eq('status', 'open'),
    db.from('purchases').select('purchase_order_id').eq('status', 'recorded').not('purchase_order_id', 'is', null),
  ]);
  final bought = {for (final x in res[1] as List) x['purchase_order_id']};
  return [
    for (final x in res[0] as List)
      if (!bought.contains(x['id']) && (x['lines'] as List).isNotEmpty && (x['lines'] as List).every((l) => l['kind'] != 'expense'))
        (() {
          final amount = (x['lines'] as List).fold<double>(0, (t, l) => t + n(l['quantity']) * n(l['unit_price']));
          return {...Map<String, dynamic>.from(x), 'amount': amount, 'paid': n(x['amount_paid']), 'toPay': r2(amount - n(x['amount_paid'])),
              'priced': (x['lines'] as List).every((l) => l['unit_price'] != null)};
        })(),
  ].where((x) => n(x['toPay']) > 0.01).toList()
    ..sort((a, b) => '${b['order_date']}'.compareTo('${a['order_date']}'));
}

Future<List<Need>> loadNeeds() async {
  final res = await Future.wait<dynamic>([
    db.from('pending_changes').select('branch_id').eq('status', 'pending'),
    db.from('cash_requests').select('branch_id').inFilter('status', ['with_directors', 'approved']),
    db.from('pay_sheets').select('branch_id, status, period_end, cycle').inFilter('status', ['draft', 'approved']).neq('cycle', 'weekly'),
    db.from('purchase_requests').select('branch_id').eq('status', 'waiting'),
    db.from('sale_payment_proofs').select('branch_id').eq('status', 'waiting'),
    loadOrdersToPay(),
  ]);
  int c(int i, [bool Function(Json)? f]) => (res[i] as List).cast<Json>().where((x) => session.inBranch(x['branch_id']) && (f?.call(x) ?? true)).length;
  return [
    Need('requests', c(3), 'purchase requests waiting', '/orders'),
    Need('orders', c(5), 'orders to pay', '/orders'),
    Need('cash', c(1), 'weekly cash requests', '/weekly-cash'),
    Need('proofs', c(4), 'payments to confirm', '/approvals?tab=payments'),
    Need('approvals', (res[0] as List).where((x) => x['branch_id'] == null || session.inBranch(x['branch_id'])).length, 'approvals waiting', '/approvals'),
    Need('pay-pay', c(2, (x) => x['status'] == 'approved'), 'pay sheets to pay', '/staff?tab=pay'),
  ].where((x) => x.count > 0).toList();
}

/// Everything the cards and their reports count, once; a period is then only a filter
Future<Json> loadMoneyData() async {
  final res = await Future.wait<dynamic>([
    db.from('sale_payments').select('paid_on, amount, sale:sales!inner(branch_id)'),
    db.from('cash_movements').select('branch_id, day, direction, amount, kind'),
    db.from('cash_requests').select('branch_id, week_ending, status, opening_balance, last_week'),
    db.from('purchases').select('id, branch_id, purchase_date, amount_paid, invoice_reference, supplier:suppliers(name), lines:purchase_lines(line_amount, unit_price, tx:inventory_transactions(entered_quantity, material:materials(name), unit:units!inventory_transactions_entered_unit_id_fkey(symbol)))').neq('status', 'void'),
    db.from('purchase_totals').select('purchase_id, total, amount_paid, balance'),
    db.from('production_batches').select('branch_id, batch_date, cement_bags, status, outputs:production_batch_outputs(is_primary), rejects:production_batch_rejects(pieces)').neq('status', 'void'),
    db.from('sales').select('id, sale_no, branch_id, sale_date, total, lines:sale_lines(line_no, product_id, item_name, color_id, quantity, total), payments:sale_payments(id, account_id, amount, paid_on)').inFilter('stage', ['order', 'invoice']),
    db.from('payment_accounts').select('id, name'),
    db.from('expenses').select('branch_id, paid_on, amount_paid').eq('status', 'recorded').eq('from_weekly_cash', true).gt('amount_paid', 0),
    db.from('purchase_payments').select('paid_on, amount, purchase:purchases!inner(branch_id, status)').eq('from_weekly_cash', true).eq('purchase.status', 'recorded'),
  ]);
  final totals = {for (final t in res[4] as List) t['purchase_id']: t};
  return {
    'received': [for (final p in res[0] as List) {'branch_id': p['sale']['branch_id'], 'day': p['paid_on'], 'amount': n(p['amount'])}],
    'moves': res[1],
    'requests': [for (final r in res[2] as List) if (!['cancelled', 'rejected'].contains(r['status'])) r],
    'purchases': [
      for (final p in res[3] as List)
        {
          'id': p['id'], 'supplier': p['supplier']?['name'] ?? '', 'ref': p['invoice_reference'], 'branch_id': p['branch_id'], 'day': p['purchase_date'],
          'total': n(totals[p['id']]?['total']), 'paid': n(totals[p['id']]?['amount_paid']),
          'toPay': n(totals[p['id']]?['balance']) > 0 ? n(totals[p['id']]?['balance']) : 0.0,
          'items': [
            for (final l in (p['lines'] as List? ?? []))
              if (l['tx']?['material']?['name'] != null)
                {'name': l['tx']['material']['name'], 'unit': l['tx']['unit']?['symbol'] ?? '', 'qty': n(l['tx']['entered_quantity']), 'price': n(l['unit_price']), 'amount': n(l['line_amount'])},
          ],
        },
    ],
    'batches': [for (final b in res[5] as List) if ((b['outputs'] as List).any((o) => o['is_primary'] == true)) b],
    'sales': [
      for (final x in res[6] as List)
        {
          'id': x['id'], 'no': x['sale_no'], 'branch_id': x['branch_id'], 'day': x['sale_date'], 'total': n(x['total']),
          'paid': (x['payments'] as List? ?? []).fold<double>(0, (t, p) => t + n(p['amount'])),
          'payments': x['payments'], 'lines': x['lines'],
          'accounts': {for (final p in (x['payments'] as List? ?? [])) if (p['account_id'] != null) p['account_id']}.toList(),
        },
    ],
    'accountName': {for (final a in res[7] as List) a['id']: a['name']},
    'weeklySpent': [
      for (final e in res[8] as List) if (e['paid_on'] != null) {'branch_id': e['branch_id'], 'day': e['paid_on'], 'amount': n(e['amount_paid'])},
      for (final p in res[9] as List) if (p['paid_on'] != null) {'branch_id': p['purchase']['branch_id'], 'day': p['paid_on'], 'amount': n(p['amount'])},
    ],
  };
}

const _spent = {'purchase', 'expense', 'wages', 'statutory'};

class Cards {
  Cards(this.sales, this.salesCount, this.salesBefore, this.sent, this.spent, this.left, this.hasRequests, this.bought, this.paid, this.toPay);
  final double sales, sent, spent, left, bought, paid, toPay;
  final double? salesBefore;
  final int salesCount;
  final bool hasRequests;
}

Cards cardsFor(Json data, DPeriod p) {
  bool inB(Object? id) => session.inBranch(id);
  final sales = (data['sales'] as List).cast<Map>();
  double made(String a, String b) => _sum(sales.where((x) => inB(x['branch_id']) && _inRange(x['day'], a, b)), (x) => n(x['total']));
  final moves = (data['moves'] as List).cast<Map>().where((x) => inB(x['branch_id'])).toList();
  final purchases = (data['purchases'] as List).cast<Map>();
  return Cards(
    made(p.from, p.to),
    sales.where((x) => inB(x['branch_id']) && _inRange(x['day'], p.from, p.to)).length,
    made(p.cFrom, p.cTo),
    _sum(moves.where((x) => x['kind'] == 'topup' && _inRange(x['day'], p.from, p.to)), (x) => n(x['amount'])),
    _sum((data['weeklySpent'] as List).cast<Map>().where((x) => inB(x['branch_id']) && _inRange(x['day'], p.from, p.to)), (x) => n(x['amount'])),
    _weeklyCashLeft(data, p.to),
    (data['requests'] as List).cast<Map>().any((r) => inB(r['branch_id'])),
    _sum(purchases.where((x) => inB(x['branch_id']) && _inRange(x['day'], p.from, p.to)), (x) => n(x['total'])),
    _sum(moves.where((x) => x['kind'] == 'purchase' && _inRange(x['day'], p.from, p.to)), (x) => n(x['amount'])),
    _sum(purchases.where((x) => inB(x['branch_id']) && x['day'] != null && '${x['day']}'.compareTo(p.to) <= 0), (x) => n(x['toPay'])),
  );
}

double _weeklyCashLeft(Json data, String upTo) {
  final byBranch = <String, List<Map>>{};
  for (final r in (data['requests'] as List).cast<Map>()) {
    if (session.inBranch(r['branch_id'])) byBranch.putIfAbsent(r['branch_id'], () => []).add(r);
  }
  var left = 0.0;
  for (final e in byBranch.entries) {
    final sorted = [...e.value]..sort((a, b) => '${a['week_ending']}'.compareTo('${b['week_ending']}'));
    final started = sorted.where((r) => shiftDay('${r['week_ending']}', -6).compareTo(upTo) <= 0).toList();
    if (started.isEmpty) continue;
    final base = started.reversed.where((r) => r['opening_balance'] != null).firstOrNull ?? started.first;
    final start = '${base['week_ending']}';
    final sent = _sum((data['moves'] as List).cast<Map>().where((x) => x['branch_id'] == e.key && x['kind'] == 'topup' && _inRange(x['day'], start, upTo)), (x) => n(x['amount']));
    final out = _sum((data['weeklySpent'] as List).cast<Map>().where((x) => x['branch_id'] == e.key && _inRange(x['day'], start, upTo)), (x) => n(x['amount']));
    left += n(base['opening_balance']) + sent - out;
  }
  return left;
}

({double bagsToday, double bags, double rejected}) productionFor(Json data, DPeriod p, String today, [bool Function(Object?)? inB]) {
  final f = inB ?? session.inBranch;
  final batches = (data['batches'] as List).cast<Map>().where((b) => f(b['branch_id'])).toList();
  final inPeriod = batches.where((b) => _inRange(b['batch_date'], p.from, p.to));
  return (
    bagsToday: _sum(batches.where((b) => b['batch_date'] == today), (b) => n(b['cement_bags'])),
    bags: _sum(inPeriod, (b) => n(b['cement_bags'])),
    rejected: _sum(inPeriod.where((b) => b['status'] == 'released'), (b) => _sum((b['rejects'] as List).cast<Map>(), (r) => n(r['pieces']))),
  );
}

/// Six months of money in (sale payments) against money out (everything paid)
List<({String month, double inn, double out})> trendFrom(Json data, String today) {
  final month = today.substring(0, 7);
  final moves = (data['moves'] as List).cast<Map>().where((x) => session.inBranch(x['branch_id']));
  return [
    for (var i = 0; i < 6; i++)
      (() {
        final m = _monthsBack(month, 5 - i);
        return (
          month: m,
          inn: _sum((data['received'] as List).cast<Map>().where((x) => session.inBranch(x['branch_id']) && '${x['day']}'.startsWith(m)), (x) => n(x['amount'])),
          out: _sum(moves.where((x) => _spent.contains(x['kind']) && '${x['day']}'.startsWith(m)), (x) => n(x['amount'])),
        );
      })(),
  ];
}

// ---- dashboard.js -----------------------------------------------------------------------
Future<Json> loadCuring(Refs refs, String today) async {
  final data = await db.from('production_batches').select('id, branch_id, batch_date, curing_until, outputs:production_batch_outputs(product_id, color_id, is_primary, pieces_cast)').eq('status', 'curing').order('curing_until');
  final rows = [
    for (final b in data)
      if (session.inBranch(b['branch_id']))
        (() {
          final main = (b['outputs'] as List).where((o) => o['is_primary'] == true).firstOrNull;
          return {
            'id': b['id'], 'date': b['batch_date'], 'until': b['curing_until'], 'ready': '${b['curing_until']}'.compareTo(today) <= 0,
            'name': main == null ? '?' : refs.productLabel(main['product_id'], main['color_id']),
            'pieces': (b['outputs'] as List).fold<double>(0, (t, o) => t + n(o['pieces_cast'])),
          };
        })(),
  ];
  return {'rows': rows, 'pieces': _sum(rows, (r) => n(r['pieces'])), 'ready': rows.where((r) => r['ready'] == true).toList()};
}

Future<Json> loadOpenOrders(String today) async {
  try {
    final data = await db.from('production_orders').select('id, branch_id, order_no, reference, due_date, status, lines:production_order_lines(id)').eq('status', 'open').order('due_date', nullsFirst: false);
    final orders = [for (final o in data) if (session.inBranch(o['branch_id'])) o];
    final ids = [for (final o in orders) for (final l in o['lines'] as List) l['id']];
    final pr = ids.isEmpty ? <dynamic>[] : await db.from('production_order_line_progress').select('*').inFilter('line_id', ids);
    final soon = shiftDay(today, 7);
    final rows = [
      for (final o in orders)
        (() {
          final ls = pr.where((p) => p['order_id'] == o['id']);
          return {
            'id': o['id'], 'no': o['order_no'], 'reference': o['reference'], 'due': o['due_date'],
            'planned': _sum(ls, (p) => n(p['planned'])), 'cast': _sum(ls, (p) => n(p['cast_pieces'])),
            'passed': _sum(ls, (p) => n(p['passed'])), 'late': o['due_date'] != null && '${o['due_date']}'.compareTo(today) < 0,
          };
        })(),
    ];
    return {'rows': rows, 'dueSoon': rows.where((r) => r['due'] != null && '${r['due']}'.compareTo(soon) <= 0).length};
  } catch (_) {
    return {'rows': <Json>[], 'dueSoon': 0};
  }
}

Future<Json> loadLowStock(Refs refs, String branchId) async {
  if (branchId.isEmpty) return {'rows': <Json>[], 'inStock': 0};
  final whs = {for (final w in refs.warehouses.where((w) => w.branchId == branchId)) w.id};
  final res = await Future.wait<dynamic>([
    db.from('stock_balances').select('warehouse_id, product_id, quantity').not('product_id', 'is', null),
    db.from('branch_products').select('product_id, reorder_level').eq('branch_id', branchId).eq('status', 'active'),
  ]);
  final qty = <String, double>{};
  for (final r in (res[0] as List).where((x) => whs.contains(x['warehouse_id']))) {
    qty[r['product_id']] = (qty[r['product_id']] ?? 0) + n(r['quantity']);
  }
  final rows = [
    for (final x in res[1] as List)
      if (x['reorder_level'] != null && (qty[x['product_id']] ?? 0) < n(x['reorder_level']))
        {'id': x['product_id'], 'name': refs.items['p:${x['product_id']}']?.name ?? '?', 'unit': refs.unit(refs.items['p:${x['product_id']}']?.stockUnitId),
            'qty': qty[x['product_id']] ?? 0, 'level': n(x['reorder_level'])},
  ]..sort((a, b) => (n(a['qty']) / (n(a['level']) == 0 ? 1 : n(a['level']))).compareTo(n(b['qty']) / (n(b['level']) == 0 ? 1 : n(b['level']))));
  return {'rows': rows, 'inStock': qty.values.where((v) => v > 0).length};
}

Future<double?> loadPayables() async {
  try {
    final data = await db.from('supplier_balances').select('branch_id, owed');
    return _sum((data as List).where((x) => session.inBranch(x['branch_id'])), (x) => n(x['owed']) > 0 ? n(x['owed']) : 0);
  } catch (_) {
    return null;
  }
}

Future<List<Json>> loadRecentSales() async {
  final res = await Future.wait<dynamic>([
    db.from('sales').select('id, branch_id, sale_no, stage, customer_id, walk_in_name, sale_date, ordered_on, invoiced_on, total').inFilter('stage', ['order', 'invoice']).order('created_at', ascending: false).limit(40),
    db.from('sale_balances').select('sale_id, balance'),
    db.from('customers').select('id, name'),
  ]);
  final bal = {for (final b in res[1] as List) b['sale_id']: n(b['balance'])};
  final cust = {for (final c in res[2] as List) c['id']: c['name']};
  return [
    for (final x in (res[0] as List).where((x) => session.inBranch(x['branch_id'])).take(8))
      {
        'id': x['id'], 'no': x['sale_no'], 'stage': x['stage'], 'date': x['invoiced_on'] ?? x['ordered_on'] ?? x['sale_date'],
        'who': x['customer_id'] != null ? (cust[x['customer_id']] ?? '?') : (x['walk_in_name'] ?? 'Walk-in'),
        'total': n(x['total']), 'balance': bal[x['id']] ?? 0,
      },
  ];
}

Future<Json> loadWaiting(String today) async {
  Future<List> safe(Future<dynamic> f) => f.then<List>((v) => v as List).catchError((_) => <dynamic>[]);
  final res = await Future.wait<List>([
    safe(db.from('pay_sheets').select('branch_id, status').inFilter('status', ['draft', 'approved'])),
    safe(db.from('purchase_requests').select('branch_id, status').eq('status', 'waiting')),
    safe(db.from('review_flags').select('id').eq('status', 'open')),
    safe(db.from('leads').select('branch_id, next_follow_up, stage').not('stage', 'in', '(won,lost)').lte('next_follow_up', today)),
  ]);
  final ps = res[0].where((x) => session.inBranch(x['branch_id']));
  return {
    'payToApprove': ps.where((x) => x['status'] == 'draft').length,
    'payToPay': ps.where((x) => x['status'] == 'approved').length,
    'requests': res[1].where((x) => session.inBranch(x['branch_id'])).length,
    'flags': res[2].length,
    'followUps': res[3].where((x) => session.inBranch(x['branch_id'])).length,
  };
}

// ---- reports.js -------------------------------------------------------------------------
Future<Json> loadSalesReport(Refs refs, String from, String to) async {
  final res = await Future.wait<dynamic>([
    db.from('sales').select('id, branch_id, stage, customer_id, walk_in_name, sale_date, ordered_on, invoiced_on, subtotal, vat, total').inFilter('stage', ['order', 'invoice']),
    db.from('sale_payments').select('amount, paid_on, sale:sales!inner(branch_id)').gte('paid_on', from).lte('paid_on', to),
    db.from('sale_balances').select('branch_id, stage, balance').inFilter('stage', ['order', 'invoice']),
  ]);
  String dateOf(Map x) => '${x['invoiced_on'] ?? x['ordered_on'] ?? x['sale_date']}';
  final sales = (res[0] as List).cast<Map>().where((x) => session.inBranch(x['branch_id']) && _inRange(dateOf(x), from, to)).toList();
  return {
    'docs': sales.length, 'amount': _sum(sales, (x) => n(x['subtotal'])), 'vat': _sum(sales, (x) => n(x['vat'])), 'total': _sum(sales, (x) => n(x['total'])),
    'received': _sum((res[1] as List).cast<Map>().where((x) => session.inBranch(x['sale']['branch_id'])), (x) => n(x['amount'])),
    'owed': _sum((res[2] as List).cast<Map>().where((x) => session.inBranch(x['branch_id']) && n(x['balance']) > 0), (x) => n(x['balance'])),
  };
}

Future<Json> loadProductionReport(String from, String to) async {
  final data = await db.from('production_batches').select('id, branch_id, batch_date, cement_bags, status, material_cost, outputs:production_batch_outputs(product_id, color_id, is_primary, pieces_cast, pieces_passed), rejects:production_batch_rejects(pieces)')
      .gte('batch_date', from).lte('batch_date', to).neq('status', 'void');
  final batches = (data as List).cast<Map>().where((b) => session.inBranch(b['branch_id'])).toList();
  double pieces = 0, bags = 0, leftovers = 0, released = 0, rejected = 0;
  for (final b in batches) {
    final outs = (b['outputs'] as List).cast<Map>();
    final main = outs.where((o) => o['is_primary'] == true).firstOrNull;
    if (main == null) continue;
    bags += n(b['cement_bags']);
    pieces += n(main['pieces_cast']);
    leftovers += _sum(outs.where((o) => o['is_primary'] != true), (o) => n(o['pieces_cast']));
    if (b['status'] == 'released') { released += n(main['pieces_cast']); rejected += _sum((b['rejects'] as List).cast<Map>(), (r) => n(r['pieces'])); }
  }
  return {'batches': batches.length, 'pieces': pieces, 'bags': bags, 'leftovers': leftovers, 'released': released, 'rejected': rejected};
}

Future<List<Json>> loadMaterialUse(Refs refs, String from, String to) async {
  final data = await db.from('production_batch_materials')
      .select('material_id, quantity, unit_id, stock_quantity, standard_quantity, source, cost, batch:production_batches!inner(branch_id, batch_date, status)')
      .gte('batch.batch_date', from).lte('batch.batch_date', to).neq('batch.status', 'void');
  final by = <String, Json>{};
  for (final m in (data as List).where((x) => session.inBranch(x['batch']['branch_id']))) {
    final it = refs.items['m:${m['material_id']}'];
    final factor = it?.units.where((u) => u.id == m['unit_id']).firstOrNull?.factor ?? 1;
    final r = by.putIfAbsent(m['material_id'], () => {'id': m['material_id'], 'name': it?.name ?? '?', 'category': it?.materialCategory ?? '', 'rank': it?.rank ?? 999,
        'unit': refs.unit(it?.stockUnitId), 'actual': 0.0, 'standard': 0.0, 'cost': 0.0});
    r['actual'] = n(r['actual']) + n(m['stock_quantity']);
    if (m['standard_quantity'] != null) r['standard'] = n(r['standard']) + n(m['standard_quantity']) * factor;
    if (m['cost'] != null) r['cost'] = n(r['cost']) + n(m['cost']);
  }
  return [
    for (final r in by.values)
      {...r, 'diffPct': n(r['standard']) > 0 ? (n(r['actual']) - n(r['standard'])) / n(r['standard']) * 100 : null},
  ]..sort((a, b) => n(a['rank']).compareTo(n(b['rank'])) != 0 ? n(a['rank']).compareTo(n(b['rank'])) : '${a['name']}'.compareTo('${b['name']}'));
}

Future<Json?> loadProfit(String from, String to) async {
  try {
    final data = await db.from('sale_delivery_lines').select('value, cost, line:sale_lines!inner(amount, total), delivery:sale_deliveries!inner(delivered_on, sale:sales!inner(branch_id))')
        .gte('delivery.delivered_on', from).lte('delivery.delivered_on', to);
    final lines = (data as List).cast<Map>().where((x) => session.inBranch(x['delivery']['sale']['branch_id']));
    double exVat(Map x) => n(x['line']['total']) != 0 ? n(x['value']) * n(x['line']['amount']) / n(x['line']['total']) : n(x['value']);
    final sales = _sum(lines, exVat), cost = _sum(lines, (x) => n(x['cost']));
    return {'sales': sales, 'margin': sales - cost};
  } catch (_) {
    return null;
  }
}

/// stockAtCost (statements.js) + days left and products below reorder (directorBoard loadStockBlock)
Future<Json> loadStockBlock(Refs refs, String today) async {
  final ids = session.branchId.isNotEmpty ? [session.branchId] : session.branches.map((b) => b.id).toList();
  final used = await loadMaterialUse(refs, shiftDay(today, -_useDays + 1), today);
  final bal = await db.from('stock_balances').select('branch_id, material_id, quantity').not('material_id', 'is', null);
  final onHand = <String, double>{};
  for (final b in (bal as List).where((x) => session.inBranch(x['branch_id']))) {
    onHand[b['material_id']] = (onHand[b['material_id']] ?? 0) + n(b['quantity']);
  }
  final materials = [
    for (final m in used.where((m) => n(m['actual']) > 0))
      {'id': m['id'], 'name': m['name'], 'days': ((onHand[m['id']] ?? 0).clamp(0, double.infinity) / (n(m['actual']) / _useDays)).floor()},
  ].where((m) => (m['days'] as int) < _lowDays).toList()..sort((a, b) => (a['days'] as int).compareTo(b['days'] as int));
  final products = <Json>[];
  for (final id in ids) {
    final low = await loadLowStock(refs, id);
    products.addAll([for (final r in low['rows'] as List) {...r, 'key': '$id|${r['id']}'}]);
  }
  double finished = 0, matValue = 0;
  var uncosted = 0;
  for (final b in ids) {
    try {
      final pc = await db.rpc('product_costing', params: {'p_branch_id': b});
      for (final r in pc as List) { finished += n(r['value']); if (n(r['uncosted_quantity']) > 0) uncosted += 1; }
    } catch (_) {}
    final mats = {for (final x in bal.where((x) => x['branch_id'] == b && n(x['quantity']) > 0)) x['material_id']}.toList();
    final vals = await Future.wait([for (final m in mats) db.rpc('material_stock_value', params: {'p_branch_id': b, 'p_material_id': m}).catchError((_) => <dynamic>[])]);
    for (final v in vals) {
      final r = (v as List).firstOrNull;
      if (r != null) { matValue += n(r['value']); if (n(r['uncosted_quantity']) > 0) uncosted += 1; }
    }
  }
  return {'finished': finished, 'materials_value': matValue, 'uncosted': uncosted, 'materials': materials, 'products': products};
}

Future<Json> loadCuringNow(Refs refs, String today) async {
  final res = await Future.wait<dynamic>([
    loadCuring(refs, today),
    db.from('review_flags').select('id').eq('status', 'open').eq('reason_code', 'yield_out_of_band').then<List>((v) => v).catchError((_) => <dynamic>[]),
  ]);
  return {'curing': (res[0] as Json)['pieces'], 'ready': ((res[0] as Json)['ready'] as List).length, 'flags': (res[1] as List).length};
}
