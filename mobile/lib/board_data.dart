import 'package:supabase_flutter/supabase_flutter.dart';

import 'format.dart';

/*
 * The director's dashboard data — the same figures as the web app's
 * lib/directorBoard.js, read through the same database rules. Read only.
 * Each block loads on its own, so one failing leaves the others standing.
 */
class Need {
  const Need(this.count, this.label, {this.warn = false});
  final int count;
  final String label;
  final bool warn;
}

class TrendMonth {
  const TrendMonth(this.month, this.sales, this.costs);
  final String month;
  final double sales, costs;
}

class BranchLine {
  const BranchLine(this.name, this.sales, this.cash);
  final String name;
  final double sales, cash;
}

class Money {
  const Money({required this.cash, required this.openingUnset, required this.accounts, required this.sales, required this.lastMonth, required this.prevMonth, required this.owedToUs, required this.weOwe, required this.supplierCount, required this.trend, required this.branches});
  final double cash, sales, lastMonth, owedToUs, weOwe;
  final int openingUnset, accounts, supplierCount;
  final String prevMonth;
  final List<TrendMonth> trend;
  final List<BranchLine> branches;
}

class Factory {
  const Factory({required this.bagsToday, required this.bagsMonth, required this.curing, required this.ready, required this.flags, required this.rejected});
  final double bagsToday, bagsMonth, curing, rejected;
  final int ready, flags;
}

class RiskLine {
  const RiskLine(this.name, this.note, {this.warn = false});
  final String name, note;
  final bool warn;
}

class OverdueLine {
  const OverdueLine(this.name, this.amount, this.days);
  final String name;
  final double amount;
  final int days;
}

class Board {
  const Board({this.needs, this.money, this.factory, this.risk, required this.overdueTotal, required this.overdue});
  final List<Need>? needs;
  final Money? money;
  final Factory? factory;
  final List<RiskLine>? risk;
  final double overdueTotal;
  final List<OverdueLine> overdue;
}

class BranchChoice {
  const BranchChoice(this.id, this.name);
  final String id, name;
}

typedef DbRow = Map<String, dynamic>;

const useDays = 14; // recent use a material's days left are worked out from
const lowDays = 7; // fewer days left than this counts as at risk

class BoardLoader {
  BoardLoader(this.db);
  final SupabaseClient db;

  Future<List<BranchChoice>> branches() async {
    final r = await db.from('branches').select('id, name').eq('status', 'active').order('name');
    return [for (final b in r) BranchChoice(b['id'] as String, b['name'] as String)];
  }

  Future<T?> _safe<T>(Future<T> f) async {
    try {
      return await f;
    } catch (_) {
      return null;
    }
  }

  Future<Board> load({String? branchId, required List<BranchChoice> branches, required String today}) async {
    bool inBranch(Object? id) => branchId == null || id == branchId;
    final od = await _safe(db.from('overdue_sales').select('branch_id, customer_id, walk_in_name, balance, days_overdue'));
    final cu = await _safe(db.from('customers').select('id, name'));
    final overdue = [for (final x in od ?? const <DbRow>[]) if (inBranch(x['branch_id'])) x];
    final results = await Future.wait<Object?>([
      _safe(_needs(inBranch, today, overdue.length)),
      _safe(_money(inBranch, branches, today)),
      _safe(_factory(inBranch, today)),
      _safe(_risk(inBranch, today, branchId, branches)),
    ]);
    final names = {for (final c in cu ?? const <DbRow>[]) c['id']: c['name']};
    final by = <String, OverdueLine>{};
    for (final s in overdue) {
      final key = '${s['customer_id'] ?? 'w:${s['walk_in_name'] ?? 'Walk-in'}'}';
      final old = by[key];
      final name = s['customer_id'] != null ? '${names[s['customer_id']] ?? '—'}' : '${s['walk_in_name'] ?? 'Walk-in'}';
      final days = n(s['days_overdue']).round();
      by[key] = OverdueLine(name, (old?.amount ?? 0) + n(s['balance']), days > (old?.days ?? 0) ? days : (old?.days ?? 0));
    }
    return Board(
      needs: results[0] as List<Need>?,
      money: results[1] as Money?,
      factory: results[2] as Factory?,
      risk: results[3] as List<RiskLine>?,
      overdueTotal: overdue.fold(0.0, (t, x) => t + n(x['balance'])),
      overdue: by.values.toList()..sort((a, b) => b.amount.compareTo(a.amount)),
    );
  }

  Future<List<Need>> _needs(bool Function(Object?) inBranch, String today, int overdue) async {
    final ch = await db.from('pending_changes').select('branch_id').eq('status', 'pending');
    final cr = await db.from('cash_requests').select('branch_id').eq('status', 'with_directors');
    final ps = await db.from('pay_sheets').select('branch_id, status, period_end').inFilter('status', ['draft', 'approved']);
    final pay = ps.where((x) => inBranch(x['branch_id']));
    return [
      Need(ch.where((x) => x['branch_id'] == null || inBranch(x['branch_id'])).length, 'approvals waiting'),
      Need(cr.where((x) => inBranch(x['branch_id'])).length, 'weekly cash requests'),
      Need(pay.where((x) => x['status'] == 'draft' && '${x['period_end']}'.compareTo(today) < 0).length, 'pay sheets to approve'),
      Need(pay.where((x) => x['status'] == 'approved').length, 'pay sheets to pay'),
      Need(overdue, 'invoices overdue', warn: true),
    ].where((x) => x.count > 0).toList();
  }

  Future<Money> _money(bool Function(Object?) inBranch, List<BranchChoice> branches, String today) async {
    final month = today.substring(0, 7);
    final ac = await db.from('payment_accounts').select().eq('status', 'active');
    final mv = await db.from('cash_movements').select('account_id, branch_id, day, direction, amount');
    final sa = await db.from('sales').select('branch_id, stage, sale_date, ordered_on, invoiced_on, total').inFilter('stage', ['order', 'invoice']).gte('sale_date', '${monthsBack(month, 7)}-01');
    final su = await db.from('supplier_balances').select('branch_id, supplier_id, owed');
    final ow = await db.from('sale_balances').select('branch_id, stage, balance').inFilter('stage', ['order', 'invoice']);

    // an account counts from its opening balance and opening date, as on Cash flow
    double cashOf(Iterable<DbRow> accounts) {
      final byId = {for (final a in accounts) a['id']: a};
      var t = accounts.fold(0.0, (s, a) => a['opening_date'] == null || '${a['opening_date']}'.compareTo(today) <= 0 ? s + n(a['opening_balance']) : s);
      for (final x in mv) {
        final a = byId[x['account_id']];
        if (a == null) continue;
        final day = '${x['day']}';
        if (day.compareTo(today) > 0 || (a['opening_date'] != null && day.compareTo('${a['opening_date']}') < 0)) continue;
        t += (x['direction'] == 'in' ? 1 : -1) * n(x['amount']);
      }
      return t;
    }

    String saleDay(DbRow s) => '${s['invoiced_on'] ?? s['ordered_on'] ?? s['sale_date']}';
    final accounts = ac.where((a) => inBranch(a['branch_id'])).toList();
    final sales = sa.where((s) => inBranch(s['branch_id'])).toList();
    double salesBetween(Iterable<DbRow> rows, String from, String to) => rows.where((s) => saleDay(s).compareTo(from) >= 0 && saleDay(s).compareTo(to) <= 0).fold(0.0, (t, s) => t + n(s['total']));

    final prev = monthsBack(month, 1);
    final sameDay = '$prev-${today.substring(8)}';
    final prevTo = sameDay.compareTo(lastDay(prev)) < 0 ? sameDay : lastDay(prev);
    final trend = [
      for (var i = 5; i >= 0; i--)
        () {
          final m = monthsBack(month, i);
          final out = mv.where((x) => inBranch(x['branch_id']) && x['direction'] == 'out' && '${x['day']}'.startsWith(m));
          return TrendMonth(m, salesBetween(sales, '$m-01', lastDay(m)), out.fold(0.0, (t, x) => t + n(x['amount'])));
        }(),
    ];
    final owing = su.where((x) => inBranch(x['branch_id']) && n(x['owed']) > 0).toList();
    return Money(
      cash: cashOf(accounts),
      accounts: accounts.length,
      openingUnset: accounts.where((a) => a['opening_date'] == null).length,
      sales: salesBetween(sales, '$month-01', today),
      lastMonth: salesBetween(sales, '$prev-01', prevTo),
      prevMonth: prev,
      owedToUs: ow.where((x) => inBranch(x['branch_id']) && n(x['balance']) > 0).fold(0.0, (t, x) => t + n(x['balance'])),
      weOwe: owing.fold(0.0, (t, x) => t + n(x['owed'])),
      supplierCount: owing.map((x) => x['supplier_id']).toSet().length,
      trend: trend,
      branches: [
        for (final b in branches)
          BranchLine(b.name, salesBetween(sa.where((s) => s['branch_id'] == b.id), '$month-01', today), cashOf(ac.where((a) => a['branch_id'] == b.id))),
      ],
    );
  }

  Future<Factory> _factory(bool Function(Object?) inBranch, String today) async {
    final rows = await db.from('production_batches').select('branch_id, batch_date, cement_bags, status, outputs:production_batch_outputs(is_primary), rejects:production_batch_rejects(pieces)').gte('batch_date', '${today.substring(0, 7)}-01').lte('batch_date', today).neq('status', 'void');
    final batches = rows.where((b) => inBranch(b['branch_id']) && (b['outputs'] as List).any((o) => o['is_primary'] == true));
    final curing = await db.from('production_batches').select('branch_id, curing_until, outputs:production_batch_outputs(pieces_cast)').eq('status', 'curing');
    final cur = curing.where((b) => inBranch(b['branch_id']));
    final flags = await db.from('review_flags').select('id').eq('status', 'open').eq('reason_code', 'yield_out_of_band');
    return Factory(
      bagsToday: batches.where((b) => b['batch_date'] == today).fold(0.0, (t, b) => t + n(b['cement_bags'])),
      bagsMonth: batches.fold(0.0, (t, b) => t + n(b['cement_bags'])),
      curing: cur.fold(0.0, (t, b) => t + (b['outputs'] as List).fold(0.0, (s, o) => s + n(o['pieces_cast']))),
      ready: cur.where((b) => '${b['curing_until']}'.compareTo(today) <= 0).length,
      flags: flags.length,
      rejected: batches.where((b) => b['status'] == 'released').fold(0.0, (t, b) => t + (b['rejects'] as List).fold(0.0, (s, r) => s + n(r['pieces']))),
    );
  }

  Future<List<RiskLine>> _risk(bool Function(Object?) inBranch, String today, String? branchId, List<BranchChoice> branches) async {
    final d = DateTime.parse(today).subtract(const Duration(days: useDays - 1));
    final used = await db.from('production_batch_materials').select('material_id, stock_quantity, batch:production_batches!inner(branch_id, batch_date, status)').gte('batch.batch_date', isoDay(d)).lte('batch.batch_date', today).neq('batch.status', 'void');
    final bal = await db.from('stock_balances').select('branch_id, material_id, product_id, quantity');
    final mats = await db.from('materials').select('id, name');
    final prods = await db.from('products').select('id, canonical_name');
    final levels = await db.from('branch_products').select('branch_id, product_id, reorder_level').eq('status', 'active').not('reorder_level', 'is', null);
    final matName = {for (final m in mats) m['id']: m['name']};
    final prodName = {for (final p in prods) p['id']: p['canonical_name']};

    final use = <Object?, double>{};
    for (final u in used) {
      if (inBranch(u['batch']['branch_id'])) use[u['material_id']] = (use[u['material_id']] ?? 0) + n(u['stock_quantity']);
    }
    final onHand = <Object?, double>{};
    final stock = <String, double>{};
    for (final b in bal) {
      if (b['material_id'] != null && inBranch(b['branch_id'])) onHand[b['material_id']] = (onHand[b['material_id']] ?? 0) + n(b['quantity']);
      if (b['product_id'] != null) stock['${b['branch_id']}|${b['product_id']}'] = (stock['${b['branch_id']}|${b['product_id']}'] ?? 0) + n(b['quantity']);
    }
    final low = <(int, String)>[];
    use.forEach((id, total) {
      if (total <= 0) return;
      final left = (onHand[id] ?? 0) < 0 ? 0.0 : (onHand[id] ?? 0);
      final days = (left / (total / useDays)).floor();
      if (days < lowDays) low.add((days, '${matName[id] ?? '?'}'));
    });
    low.sort((a, b) => a.$1.compareTo(b.$1));
    return [
      for (final m in low) RiskLine(m.$2, 'about ${m.$1} day${m.$1 == 1 ? '' : 's'} left', warn: true),
      for (final l in levels)
        if (inBranch(l['branch_id']) && (stock['${l['branch_id']}|${l['product_id']}'] ?? 0) < n(l['reorder_level'])) RiskLine('${prodName[l['product_id']] ?? '?'}', 'below reorder'),
    ];
  }
}

/// Made-up figures, to check the layout without signing in (--dart-define=DEMO=true).
Board demoBoard() => const Board(
      needs: [Need(3, 'approvals waiting'), Need(1, 'weekly cash requests'), Need(2, 'pay sheets to approve'), Need(6, 'invoices overdue', warn: true)],
      money: Money(
        cash: 48200000,
        openingUnset: 0,
        accounts: 4,
        sales: 126000000,
        lastMonth: 112000000,
        prevMonth: '2026-09',
        owedToUs: 31500000,
        weOwe: 18700000,
        supplierCount: 7,
        trend: [TrendMonth('2026-05', 72e6, 61e6), TrendMonth('2026-06', 83e6, 66e6), TrendMonth('2026-07', 77e6, 69e6), TrendMonth('2026-08', 92e6, 72e6), TrendMonth('2026-09', 112e6, 75e6), TrendMonth('2026-10', 126e6, 78e6)],
        branches: [BranchLine('Branch 1', 78e6, 29e6), BranchLine('Branch 2', 31e6, 12e6), BranchLine('Branch 3', 17e6, 7e6)],
      ),
      factory: Factory(bagsToday: 142, bagsMonth: 3480, curing: 18200, ready: 2, flags: 5, rejected: 120),
      risk: [RiskLine('Material A', 'about 3 days left', warn: true), RiskLine('Material B', 'about 5 days left', warn: true), RiskLine('Product A', 'below reorder'), RiskLine('Product B', 'below reorder'), RiskLine('Product C', 'below reorder')],
      overdueTotal: 9400000,
      overdue: [OverdueLine('Customer A', 3800000, 45), OverdueLine('Customer B', 2100000, 31), OverdueLine('Customer C', 1600000, 18), OverdueLine('Customer D', 1100000, 12), OverdueLine('Customer E', 800000, 6)],
    );
