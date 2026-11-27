import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/offline.dart';
import '../core/pdf_doc.dart';
import '../core/proof_view.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../docs/purchase_docs.dart';
import '../shell.dart';
import 'electricity.dart';
import 'expense_form.dart';
import 'orders.dart';
import 'stock_history.dart';
import 'suppliers.dart';
import 'procurement_actions.dart';
import 'purchase_form.dart';

/*
 * Procurement — a port of web pages/Purchases.jsx (one page, three menu entries; approved 2026-11-24):
 *   purchases - tabs All · Purchases · Expenses · Suppliers; Purchases has Purchases, Material costs,
 *               Goods received
 *   expenses  - Expenses and Electricity
 *   orders    - what is still to buy
 * One list for all procurement (2026-11-16): search, sort, status and type filters; a tap opens the
 * record with its whole story (payment, delivery, slips) and what can be done next.
 * Online only (2026-11-24, the user: only meter readings save offline).
 */
double _r2(num v) => (v * 100).roundToDouble() / 100;
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
String _money(Object? v) => formatMoney(n(v), session.currency);

/// Where a record stands, one word or two (ProcTable STATUS)
const procStatus = {
  'approval': ('Waiting approval', Tone.warning, 'Sent for approval; nothing is recorded until it is approved'),
  'ordered': ('Ordered', Tone.neutral, 'Bought, nothing paid or delivered yet'),
  'paid_wait': ('Paid · not delivered', Tone.info, 'Paid; the goods are still coming'),
  'part_deliv': ('Part delivered', Tone.info, 'Some of the goods have come'),
  'deliv_due': ('Delivered · not paid', Tone.warning, 'The goods are in; the supplier is still to be paid'),
  'part_paid': ('Part paid', Tone.warning, 'Part of the amount is paid'),
  'not_paid': ('Not paid', Tone.neutral, 'Recorded, nothing paid yet'),
  'done': ('Done', Tone.success, 'Paid and delivered — nothing left to do'),
  'void': ('Void', Tone.neutral, 'Entered wrongly and cancelled; kept on record'),
};

class _Row {
  _Row({required this.key, required this.kind, required this.date, this.ref, required this.items, this.amount, this.source = '', required this.status, this.sub = '', this.kindLabel, required this.onOpen});
  final String key, kind, status, source, sub;
  final String? date, ref, kindLabel;
  final List<({String name, Object? qty, String unit, Object? price})> items;
  final Object? amount;
  final VoidCallback onOpen;
  bool get muted => status == 'void';
}

class ProcurementPage extends StatefulWidget {
  const ProcurementPage({super.key, this.section = 'purchases', this.query = const {}});
  final String section;   // purchases | expenses | orders
  final Map<String, String> query;
  @override
  State<ProcurementPage> createState() => _ProcurementPageState();
}

class _ProcurementPageState extends State<ProcurementPage> {
  late String _top = widget.section == 'expenses' ? 'expenses' : 'purchases';
  String _pTab = 'buy', _q = '', _sortBy = 'new', _stFilter = '', _typeFilter = '';
  late String _eTab = widget.query['tab'] == 'electricity' ? 'electricity' : 'list';
  late String _expFilter = widget.query['tab'] == 'wages' ? 'wages' : '';
  String _period = 'month';
  Refs? _refs;
  List<Json> _purchases = [], _awaiting = [], _pending = [], _expenses = [], _expCats = [];
  Map<String, Json> _totals = {}, _deliv = {};
  Map<String, List<Json>> _txByMove = {}, _slips = {};
  Map<String, String> _people = {};
  bool _loading = true, _buyOpened = false;
  final _supKey = GlobalKey<SuppliersPanelState>();
  String _error = '';
  DateTime? _savedAt;

  String get branchId => session.branchId;
  bool canRecordAt(Object? id) => id != null && '$id'.isNotEmpty && session.canAt('procurement.receive', '$id', null);
  String get tab => widget.section == 'orders'
      ? 'requests'
      : _top == 'all' ? 'all' : _top == 'suppliers' ? 'suppliers' : _top == 'expenses' ? (_eTab == 'electricity' ? 'electricity' : 'expenses') : _pTab == 'buy' ? 'purchases' : _pTab;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final refs = await Refs.load();
      final (j, at) = await offline.load<Json>('procurement:$branchId', () async {
        dynamic byBranch(dynamic q) => branchId.isNotEmpty ? q.eq('branch_id', branchId) : q;
        final r = await Future.wait<dynamic>([
          byBranch(db.from('purchases').select('id, branch_id, movement_id, warehouse_id, supplier_id, purchase_date, invoice_reference, transport_charge, '
              'vat_amount, prices_include_vat, amount_paid, payment_method, paid_on, status, void_reason, notes, created_by, purchase_order_id, '
              'lines:purchase_lines(id, transaction_id, unit_price, line_amount), items:purchase_items(id, line_no, material_id, unit_id, quantity, unit_price, line_amount), '
              'deliveries:purchase_deliveries(id, movement_id, delivered_on, received_by)')).order('purchase_date', ascending: false).limit(300),
          byBranch(db.from('purchase_totals').select('*')),
          byBranch(db.from('receipts_awaiting_purchase').select('*')).order('movement_date', ascending: false),
          byBranch(db.from('pending_changes').select('id, branch_id, summary, payload, requested_by, requested_at').eq('kind', 'purchase').eq('status', 'pending')).order('requested_at', ascending: false),
          byBranch(db.from('purchase_delivery_status').select('*')).then<List>((v) => v as List).catchError((_) => <dynamic>[]),
          db.from('expense_categories').select('*').order('display_order', ascending: true).order('name', ascending: true),
          byBranch(db.from('expenses').select('*')).order('expense_date', ascending: false).order('created_at', ascending: false).limit(500),
          db.from('director_payments').select('*').inFilter('kind', ['supplier', 'expense']).then<List>((v) => v).catchError((_) => <dynamic>[]),
          db.from('procurement_proofs').select('*').then<List>((v) => v).catchError((_) => <dynamic>[]),
        ]);
        final moveIds = {for (final p in [...r[0] as List, ...r[2] as List]) if (p['movement_id'] != null) '${p['movement_id']}'}.toList();
        final tx = moveIds.isEmpty
            ? []
            : await db.from('inventory_transactions').select('id, movement_id, material_id, product_id, quantity, stock_unit_id, entered_quantity, entered_unit_id, warehouse_id')
                .inFilter('movement_id', moveIds).eq('transaction_type', 'receipt');
        final ids = {for (final x in [...r[0] as List, ...r[2] as List]) if (x['created_by'] != null) '${x['created_by']}', for (final x in r[3] as List) if (x['requested_by'] != null) '${x['requested_by']}'}.toList();
        final ppl = ids.isEmpty ? [] : await db.from('profiles').select('id, first_name, last_name, email').inFilter('id', ids);
        return {'pu': r[0], 'tot': r[1], 'aw': r[2], 'pr': r[3], 'ds': r[4], 'ec': r[5], 'ex': r[6], 'dp': r[7], 'pp': r[8], 'tx': tx, 'ppl': ppl};
      });
      if (!mounted) return;
      final byMove = <String, List<Json>>{};
      for (final t in _l(j['tx'])) { (byMove['${t['movement_id']}'] ??= []).add(t); }
      final slips = <String, List<Json>>{};
      for (final d in _l(j['dp'])) { (slips['${d['ref_id']}'] ??= []).add(d); }
      for (final d in _l(j['pp'])) {
        (slips['${d['ref_id']}'] ??= []).add({...d, 'kind': d['kind'] == 'purchase' ? 'supplier' : 'expense', 'amount': d['amount'] ?? 0, 'bucket': 'payment-proofs'});
      }
      for (final v in slips.values) { v.sort((a, b) => '${a['paid_on'] ?? ''}'.compareTo('${b['paid_on'] ?? ''}')); }
      setState(() {
        _refs = refs;
        _purchases = _l(j['pu']);
        _totals = {for (final t in _l(j['tot'])) '${t['purchase_id']}': t};
        _awaiting = _l(j['aw']);
        _pending = _l(j['pr']);
        _deliv = {for (final d in _l(j['ds'])) '${d['purchase_id']}': d};
        _expCats = _l(j['ec']);
        _expenses = _l(j['ex']);
        _txByMove = byMove;
        _slips = slips;
        _people = {
          for (final p in _l(j['ppl']))
            '${p['id']}': () {
              final nm = [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ');
              return nm.isNotEmpty ? nm : '${p['email']}';
            }(),
        };
        _loading = false;
        _savedAt = at;
      });
      // Materials' "Intake" opens a new purchase for that material (?buy=<material id>)
      final buy = widget.query['buy'];
      if (buy != null && !_buyOpened) {
        _buyOpened = true;
        _record(mode: 'new', materialId: buy);
      }
    } catch (_) {
      if (mounted) setState(() { _error = "We couldn't load purchases. Please try again."; _loading = false; });
    }
  }

  String supplierName(Object? id) => '${_refs?.suppliers.where((s) => s['id'] == id).firstOrNull?['name'] ?? '—'}';
  String? delivOf(Json p) => p['status'] == 'recorded' ? '${_deliv['${p['id']}']?['delivery_status'] ?? 'delivered'}' : null;
  String purchaseStatus(Json p) {
    if (p['status'] != 'recorded') return 'void';
    final pay = _totals['${p['id']}']?['payment_status'];
    final d = delivOf(p);
    if (d == 'delivered') return pay == 'paid' ? 'done' : pay == 'part_paid' ? 'part_paid' : 'deliv_due';
    if (d == 'part') return 'part_deliv';
    return pay == 'paid' ? 'paid_wait' : pay == 'part_paid' ? 'part_paid' : 'ordered';
  }

  String expensePay(Json e) => e['status'] == 'void' ? 'void' : n(e['amount_paid']) >= n(e['amount']) ? 'paid' : n(e['amount_paid']) > 0 ? 'part_paid' : 'unpaid';
  String expenseStatus(Json e) => e['status'] == 'void' ? 'void' : expensePay(e) == 'paid' ? 'done' : expensePay(e) == 'part_paid' ? 'part_paid' : 'not_paid';
  String catName(Object? id) => '${_expCats.where((c) => c['id'] == id).firstOrNull?['name'] ?? '—'}';
  bool inPeriod(Object? d) {
    final (from, to) = periodRange(_period, session.today);
    final s = '$d';
    return s.compareTo(from) >= 0 && s.compareTo(to) <= 0;
  }

  List<({String materialId, double qty, String unitId, Object? price})> linesOf(Json p) {
    final items = _l(p['items']);
    if (items.isNotEmpty) {
      items.sort((a, b) => n(a['line_no']).compareTo(n(b['line_no'])));
      return [for (final i in items) (materialId: '${i['material_id']}', qty: n(i['quantity']).toDouble(), unitId: '${i['unit_id']}', price: i['unit_price'])];
    }
    final priceOfTx = {for (final l in _l(p['lines'])) '${l['transaction_id']}': l['unit_price']};
    return [
      for (final x in _txByMove['${p['movement_id']}'] ?? <Json>[])
        if (x['material_id'] != null) (materialId: '${x['material_id']}', qty: n(x['entered_quantity']).toDouble(), unitId: '${x['entered_unit_id']}', price: priceOfTx['${x['id']}']),
    ];
  }

  ({String name, Object? qty, String unit, Object? price}) itemOf(({String materialId, double qty, String unitId, Object? price}) l) =>
      (name: _refs?.items['m:${l.materialId}']?.name ?? '—', qty: l.qty, unit: _refs?.unit(l.unitId) ?? '', price: l.price);

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    if (_error.isNotEmpty && _refs == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    if (_refs == null) return ListView(padding: const EdgeInsets.all(14), children: const [Skeleton(rows: 6)]);
    final refs = _refs!;
    final purchasesHere = _purchases.where((p) => session.inBranch(p['branch_id'])).toList();
    final pendingHere = _pending.where((p) => session.inBranch(p['branch_id'])).toList();
    final waitingHere = _awaiting.where((a) => session.inBranch(a['branch_id'])).toList();
    final catLow = {for (final c in _expCats) '${c['id']}': '${c['name']}'.toLowerCase()};
    final expensesHere = _expenses.where((e) => session.inBranch(e['branch_id']) && (_expFilter.isEmpty || (catLow['${e['category_id']}'] ?? '').startsWith(_expFilter))).toList();

    final purchaseRows = <_Row>[
      for (final p in pendingHere)
        () {
          final rl = _l(p['payload']?['receipt']?['lines']);
          Object? priceOf(Object? m) => _l(p['payload']?['lines']).where((l) => l['material_id'] == m).firstOrNull?['unit_price'];
          return _Row(
            key: 'a${p['id']}', kind: 'purchase', date: '${p['payload']?['receipt']?['movement_date'] ?? p['payload']?['purchase_date'] ?? ''}', status: 'approval',
            items: rl.isNotEmpty
                ? [for (final l in rl) itemOf((materialId: '${l['material_id']}', qty: n(l['quantity']).toDouble(), unitId: '${l['unit_id']}', price: priceOf(l['material_id'])))]
                : [(name: '${p['summary']}', qty: null, unit: '', price: null)],
            amount: rl.fold<double>(0, (t, l) => t + n(l['quantity']) * n(priceOf(l['material_id']))) + n(p['payload']?['transport_charge']),
            source: p['payload']?['supplier_id'] != null ? supplierName(p['payload']['supplier_id']) : '${p['payload']?['new_supplier_name'] ?? ''}',
            sub: _people['${p['requested_by']}'] ?? '',
            onOpen: () => Shell.of(context).go('/approvals'),
          );
        }(),
      for (final p in purchasesHere.where((p) => inPeriod(p['purchase_date'])))
        () {
          final tt = _totals['${p['id']}'];
          final st = purchaseStatus(p);
          final ds = _deliv['${p['id']}'];
          final dsItems = _l(ds?['items']);
          final one = dsItems.length == 1 ? dsItems.first : null;
          return _Row(
            key: 'p${p['id']}', kind: 'purchase', date: '${p['purchase_date']}', ref: p['invoice_reference'], items: [for (final l in linesOf(p)) itemOf(l)], amount: tt?['total'],
            source: supplierName(p['supplier_id']), status: st,
            sub: st == 'void'
                ? '${p['void_reason'] ?? ''}'
                : st == 'part_paid' || st == 'deliv_due'
                    ? (tt != null ? '${_money(tt['balance'])} to pay' : '')
                    : (st == 'part_deliv' || st == 'paid_wait') && one != null
                        ? '${qtyText(_r2(n(one['delivered'])))} of ${qtyText(n(one['quantity']))} ${refs.unit('${one['unit_id']}')} in'
                        : '',
            onOpen: () => _openPurchase(p),
          );
        }(),
    ];
    final expenseRows = <_Row>[
      for (final e in expensesHere.where((e) => inPeriod(e['expense_date'])))
        () {
          final st = expenseStatus(e);
          return _Row(
            key: 'e${e['id']}', kind: 'expense', date: '${e['expense_date']}', kindLabel: catName(e['category_id']),
            items: [(name: '${e['description'] ?? ''}', qty: e['quantity'] != null ? n(e['quantity']) : null, unit: '', price: e['unit_price'])], amount: e['amount'],
            source: e['supplier_id'] != null ? supplierName(e['supplier_id']) : '', status: st,
            sub: st == 'void' ? '${e['void_reason'] ?? ''}' : st == 'part_paid' ? '${_money(_r2(n(e['amount']) - n(e['amount_paid'])))} to pay' : '',
            onOpen: () => _openExpense(e),
          );
        }(),
    ];
    String words(_Row r) => [r.ref, r.source, r.kindLabel, ...r.items.map((x) => x.name)].where((x) => x != null && x.isNotEmpty).join(' ').toLowerCase();
    final q = _q.trim().toLowerCase();
    final procRows = (tab == 'all' ? [...purchaseRows, ...expenseRows] : tab == 'purchases' ? purchaseRows : tab == 'expenses' ? expenseRows : <_Row>[])
        .where((r) => (q.isEmpty || words(r).contains(q)) && (_stFilter.isEmpty || r.status == _stFilter) && (_typeFilter.isEmpty || r.kind == _typeFilter))
        .toList()
      ..sort((a, b) => _sortBy == 'old'
          ? '${a.date}'.compareTo('${b.date}')
          : _sortBy == 'amount'
              ? n(b.amount).compareTo(n(a.amount))
              : _sortBy == 'item'
                  ? (a.items.firstOrNull?.name ?? '').compareTo(b.items.firstOrNull?.name ?? '')
                  : '${b.date}'.compareTo('${a.date}'));
    final owed = purchasesHere.where((p) => p['status'] == 'recorded').fold<double>(0, (s, p) => s + (n(_totals['${p['id']}']?['balance']) > 0 ? n(_totals['${p['id']}']?['balance']).toDouble() : 0));
    final statusOptions = [('', 'All'), for (final e in procStatus.entries) (e.key, e.value.$1)]
        .where((o) => o.$1.isEmpty || (tab == 'expenses' ? ['part_paid', 'not_paid', 'done', 'void'].contains(o.$1) : tab == 'purchases' ? o.$1 != 'not_paid' : true))
        .toList();

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: _fab(),
      body: RefreshIndicator(
      onRefresh: () async { await Refs.load(fresh: true); await _load(); },
      child: PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 88), children: [
        OfflineNote(_savedAt),
        if (widget.section != 'orders') ...[
          PageTabs<String>(
            tabs: [('all', 'All'), ('purchases', 'Purchases${pendingHere.isNotEmpty ? ' (${pendingHere.length} waiting for approval)' : ''}'), ('expenses', 'Expenses'), ('suppliers', 'Suppliers')],
            value: _top, onChange: (v) => setState(() => _top = v),
          ),
          if (['all', 'purchases', 'expenses'].contains(tab))
            ListToolbar(
              key: ValueKey('tb$tab'),
              placeholder: tab == 'expenses' ? 'Search expenses…' : tab == 'purchases' ? 'Search purchases…' : 'Search purchases and expenses…',
              onSearch: (v) => setState(() => _q = v),
              sort: SortSpec(value: _sortBy, onChange: (v) => setState(() => _sortBy = v), options: const [('new', 'Newest first'), ('old', 'Oldest first'), ('amount', 'Amount, highest first'), ('item', 'Item, A to Z')]),
              filters: [
                FilterSpec(key: 'status', label: 'Status', value: _stFilter, onChange: (v) => setState(() => _stFilter = v), options: statusOptions),
                if (tab == 'all') FilterSpec(key: 'type', label: 'Type', value: _typeFilter, onChange: (v) => setState(() => _typeFilter = v), options: const [('', 'All'), ('purchase', 'Purchases'), ('expense', 'Expenses')]),
                if (tab != 'purchases')
                  FilterSpec(key: 'cat', label: 'Expense', value: _expFilter, onChange: (v) => setState(() => _expFilter = v),
                      options: const [('', 'All'), ('wages', 'Wages'), ('salaries', 'Salaries'), ('transport', 'Transport'), ('electricity', 'Electricity'), ('expense', 'Expense')]),
              ],
            ),
          if (_top == 'purchases')
            SlideRow(children: [
              for (final (k, l) in [('buy', 'Purchases'), ('costs', 'Material costs'), ('waiting', 'Goods received (${waitingHere.length})')]) Chip2(l, on: _pTab == k, onTap: () => setState(() => _pTab = k)),
            ]),
          if (_top == 'expenses')
            SlideRow(children: [for (final (k, l) in [('list', 'Expenses'), ('electricity', 'Electricity')]) Chip2(l, on: _eTab == k, onTap: () => setState(() => _eTab = k))]),
          const SizedBox(height: 8),
        ],
        if (tab == 'purchases' && owed > 0)
          Align(alignment: Alignment.centerRight, child: Text.rich(TextSpan(style: TextStyle(fontSize: Fs.sm, color: t.textMuted), children: [const TextSpan(text: 'Still to pay: '), TextSpan(text: _money(_r2(owed)), style: TextStyle(fontWeight: FontWeight.w700, color: t.textPrimary))]))),
        if (_error.isNotEmpty) ErrorState(_error, onRetry: _load),
        if (['all', 'purchases', 'expenses'].contains(tab)) ...[
          PeriodBar(value: _period, onChange: (v) => setState(() => _period = v), extra: const [('all', 'All time')]),
          const SizedBox(height: 10),
          if (_loading)
            const Skeleton(rows: 5)
          else if (procRows.isEmpty)
            const EmptyState(icon: LucideIcons.shoppingCart, title: 'Nothing recorded in this period.')
          else ...[
            for (final r in procRows) _card(context, r),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(children: [
                const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700))),
                Text(_money(procRows.where((r) => r.status != 'void' && r.status != 'approval').fold<double>(0, (s, r) => s + n(r.amount))), style: const TextStyle(fontWeight: FontWeight.w700)),
              ]),
            ),
          ],
        ] else if (tab == 'waiting') ...[
          if (waitingHere.isEmpty)
            const EmptyState(icon: LucideIcons.shoppingCart, title: 'Nothing waiting', description: 'Materials the storekeeper receives appear here until the supplier, cost and payment are added.')
          else
            for (final a in waitingHere)
              CardBox(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${tableDate(a['movement_date']) ?? ''}${'${a['reference'] ?? ''}'.isNotEmpty ? ' · ${a['reference']}' : ''}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                  Text(_describe(_txByMove['${a['movement_id']}']), style: const TextStyle(fontWeight: FontWeight.w600)),
                  PlHelp('${warehouseLabel(refs.store('${a['warehouse_id']}'))} · ${_people['${a['created_by']}'] ?? '—'}'),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(spacing: 6, children: [
                      if (canRecordAt(a['branch_id'])) FilledButton(onPressed: () => _record(mode: 'complete', receipt: a), child: const Text('Add purchase details')),
                      TextButton(onPressed: () => openDoc(context, 'Goods received note GRN-${'${a['movement_id']}'.substring(0, 8).toUpperCase()}', () => grnPdf('${a['movement_id']}')), child: const Text('GRN')),
                    ]),
                  ),
                ]),
              ),
        ] else if (tab == 'costs')
          _MaterialCosts(refs: refs)
        else if (tab == 'suppliers')
          SuppliersPanel(key: _supKey)
        else if (tab == 'electricity')
          ElectricityPanel(branchId: branchId, onOrder: (q) => Shell.of(context).go('/orders?open=${q['id']}'))
        else
          RequestsPanel(
            refs: refs, people: _people, openFirst: widget.query['open'],
            actions: OrderActions(
              onReceive: (fromOrder) async { if (await openPurchaseForm(context, _ctx, mode: 'new', fromOrder: fromOrder)) _load(); },
              onRecordExpense: (prefill) async { if (await openExpenseForm(context, prefill: prefill, categories: _expCats, suppliers: refs.suppliers)) _load(); },
              onRecordToken: (q, meterName) async { if (await buyTopup(context, q, meterName)) _load(); },
            ),
          ),
      ]),
      ),
    );
  }

  PurchaseCtx get _ctx => PurchaseCtx(refs: _refs!, purchases: _purchases, txByMove: _txByMove);

  Future<void> _record({required String mode, Json? receipt, String? materialId}) async {
    if (await openPurchaseForm(context, _ctx, mode: mode, receipt: receipt, materialId: materialId)) _load();
  }

  Future<bool> editPurchase(BuildContext context, Json p) => openPurchaseForm(context, _ctx, mode: 'edit', purchase: p);

  Future<bool> editExpense(BuildContext context, Json e) => openExpenseForm(context, expense: e, categories: _expCats, suppliers: _refs!.suppliers);

  /// one golden button, following the open tab (2026-11-16): expenses → Record expense, else Record purchase
  Widget? _fab() {
    final t = context.tk;
    if (widget.section == 'orders' || _refs == null) return null;
    if (_top == 'suppliers') {
      return !session.canManage('materials.manage')
          ? null
          : FloatingActionButton.extended(
              backgroundColor: t.dark ? C.khaki : C.charcoal, foregroundColor: t.dark ? C.charcoal : Colors.white,
              onPressed: () => _supKey.currentState?.newSupplier(), icon: const Icon(LucideIcons.plus), label: const Text('New Supplier'),
            );
    }
    final expenses = _top == 'expenses';
    if (expenses ? (_expCats.isEmpty || (branchId.isNotEmpty && !canRecordAt(branchId))) : !canRecordAt(branchId)) return null;
    return FloatingActionButton.extended(
      backgroundColor: t.dark ? C.khaki : C.charcoal,
      foregroundColor: t.dark ? C.charcoal : Colors.white,
      onPressed: () async {
        if (expenses) {
          if (await openExpenseForm(context, categories: _expCats, suppliers: _refs!.suppliers)) _load();
        } else {
          _record(mode: 'new');
        }
      },
      icon: const Icon(LucideIcons.plus),
      label: Text(expenses ? 'Record expense' : 'Record purchase'),
    );
  }


  String _describe(List<Json>? lines) => [
        for (final x in lines ?? <Json>[])
          if (x['material_id'] != null) '${qtyText(n(x['entered_quantity']))} ${_refs!.unit('${x['entered_unit_id']}')} ${_refs!.items['m:${x['material_id']}']?.name ?? ''}',
      ].join(', ');

  Widget _card(BuildContext context, _Row r) {
    final t = context.tk;
    final (label, tone, _) = procStatus[r.status] ?? ('—', Tone.neutral, '');
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: r.muted ? 0.6 : 1,
        child: Material(
          color: t.surface,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: r.onOpen,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${tableDate(r.date) ?? '—'}${(r.ref ?? '').isNotEmpty ? ' · ${r.ref}' : ''}${r.source.isNotEmpty ? ' · ${r.source}' : ''}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted))),
                  Badge2(label, tone: tone),
                ]),
                const SizedBox(height: 4),
                for (final x in r.items)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: Text(x.name, style: const TextStyle(fontWeight: FontWeight.w600))),
                    if (x.qty != null) Text('${x.qty is num ? formatAmount(x.qty as num) : x.qty} ${x.unit}', style: TextStyle(fontSize: Fs.sm, color: t.textSecondary)),
                    if (x.price != null) Text(' @ ${formatAmount(n(x.price))}', style: TextStyle(fontSize: Fs.sm, color: t.textMuted)),
                  ]),
                Row(children: [
                  Expanded(child: PlHelp([if (r.kindLabel != null) r.kindLabel!, if (r.sub.isNotEmpty) r.sub].join(' · '))),
                  Text(r.amount != null ? _money(r.amount) : '—', style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  // ---- a purchase opened from the list: its story and what can be done next ----
  void _openPurchase(Json p) {
    final refs = _refs!;
    final tt = _totals['${p['id']}'];
    final st = purchaseStatus(p);
    final ds = _deliv['${p['id']}'];
    final (label, tone, help) = procStatus[st]!;
    final bal = tt != null ? n(tt['balance']) : 0;
    final slips = _slips['${p['id']}'] ?? [];
    final can = p['status'] == 'recorded' && canRecordAt(p['branch_id']);
    // bought from an order and delivered in portions (133): Change changes only the deliveries
    final fromOrder = p['purchase_order_id'] != null && _l(p['items']).isNotEmpty;
    Future<void> then(BuildContext ctx, Future<bool> Function() act) async {
      Navigator.pop(ctx);
      if (await act()) _load();
    }

    Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (ctx) {
      final t = ctx.tk;
      return FullPage(
        title: 'Purchase · ${dateText(p['purchase_date'])}',
        footer: [
          if (p['status'] == 'void' && session.canManage('system.manage'))
            TextButton(onPressed: () => then(ctx, () => deletePurchase(context, purchase: p, goods: _describe(_txByMove['${p['movement_id']}']))), child: const Text('Delete…')),
          if (p['status'] == 'recorded' && p['movement_id'] != null)
            TextButton(onPressed: () => openDoc(ctx, 'Goods received note GRN-${'${p['movement_id']}'.substring(0, 8).toUpperCase()}', () => grnPdf('${p['movement_id']}')), child: const Text('Goods received note')),
          if (can && !fromOrder) OutlinedButton(onPressed: () => then(ctx, () => editPurchase(context, p)), child: const Text('Change')),
          if (can && delivOf(p) != 'delivered') FilledButton(onPressed: () => then(ctx, () => recordDelivery(context, purchase: p, status: ds, refs: refs)), child: const Text('Record delivery')),
          // a rounding gap is settled when the purchase is recorded, not here (2026-11-16, the user)
          if (can && tt != null && bal >= 1) FilledButton(onPressed: () => then(ctx, () => payPurchase(context, purchase: p, total: tt['total'], supplierName: supplierName(p['supplier_id']))), child: const Text('Pay')),
          if (slips.isNotEmpty)
            TextButton.icon(onPressed: () => showProof(ctx, slips.last), icon: const Icon(LucideIcons.eye, size: 15), label: const Text('View proof'))
          else if (can)
            TextButton.icon(
              onPressed: () => then(ctx, () => addProcurementProof(context, kind: 'purchase', id: p['id'], branchId: p['branch_id'], amount: tt?['amount_paid'], paidOn: p['paid_on'], who: supplierName(p['supplier_id']))),
              icon: const Icon(LucideIcons.paperclip, size: 15), label: const Text('Add proof'),
            ),
          OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
        children: [
          Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [Badge2(label, tone: tone), PlHelp(help)]),
          if (p['status'] == 'void' && p['void_reason'] != null) PlHelp('${p['void_reason']}'),
          const SizedBox(height: 10),
          _kv(ctx, 'Supplier', '${supplierName(p['supplier_id'])}${'${p['invoice_reference'] ?? ''}'.isNotEmpty ? ' · ${p['invoice_reference']}' : ''}'),
          _kv(ctx, 'Total', tt != null ? _money(tt['total']) : '—'),
          _kv(ctx, 'Paid', tt != null ? '${_money(tt['amount_paid'])}${bal >= 1 ? ' · ${_money(bal)} to pay' : ''}' : '—'),
          const SectionTitle('Items'),
          for (final l in linesOf(p))
            Builder(builder: (_) {
              final di = _l(ds?['items']).where((x) => x['material_id'] == l.materialId).firstOrNull;
              final u = refs.unit(l.unitId);
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
                child: Row(children: [
                  Expanded(child: Text(refs.items['m:${l.materialId}']?.name ?? '—', style: const TextStyle(fontWeight: FontWeight.w600))),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text('${qtyText(l.qty)} $u${l.price != null ? ' @ ${formatAmount(n(l.price))}' : ''}', style: const TextStyle(fontSize: Fs.sm)),
                    PlHelp('delivered ${p['status'] != 'recorded' ? '—' : di != null ? '${qtyText(_r2(n(di['delivered'])))} $u' : delivOf(p) == 'delivered' ? 'All' : '—'}'),
                  ]),
                ]),
              );
            }),
          if (p['status'] == 'recorded' && _l(p['items']).isNotEmpty)
            PurchaseDeliveries(purchase: p, refs: refs, canEdit: can && fromOrder, onChanged: _load),
          if (slips.isNotEmpty) ...[
            const SectionTitle('Proof'),
            Wrap(spacing: 6, children: [for (final d in slips) OutlinedButton(onPressed: () => showProof(ctx, d), child: Text('${d['file_path'] != null ? 'Slip' : 'SMS'} · ${tableDate(d['paid_on']) ?? ''}'))]),
          ],
        ],
      );
    }));
  }

  void _openExpense(Json e) {
    final st = expenseStatus(e);
    final (label, tone, help0) = procStatus[st]!;
    final help = st == 'done' ? 'Paid in full — nothing left to do' : help0;
    final due = _r2(n(e['amount']) - n(e['amount_paid']));
    final slips = _slips['${e['id']}'] ?? [];
    final can = e['status'] == 'recorded' && canRecordAt(e['branch_id']);
    Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (ctx) => FullPage(
          title: 'Expense · ${dateText(e['expense_date'])}',
          footer: [
            if (slips.isNotEmpty)
              TextButton.icon(onPressed: () => showProof(ctx, slips.last), icon: const Icon(LucideIcons.eye, size: 15), label: const Text('View proof'))
            else if (can)
              TextButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  if (await addProcurementProof(context, kind: 'expense', id: e['id'], branchId: e['branch_id'], amount: e['amount_paid'], paidOn: e['paid_on'] ?? e['expense_date'], who: '${e['description'] ?? ''}')) _load();
                },
                icon: const Icon(LucideIcons.paperclip, size: 15), label: const Text('Add proof'),
              ),
            if (can)
              OutlinedButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  if (await editExpense(context, e)) _load();
                },
                child: const Text('Change'),
              ),
            OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
          children: [
            Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [Badge2(label, tone: tone), PlHelp(help)]),
            if (e['status'] == 'void' && e['void_reason'] != null) PlHelp('${e['void_reason']}'),
            const SizedBox(height: 10),
            _kv(ctx, 'Item', '${e['description'] ?? ''}'),
            _kv(ctx, 'Category', catName(e['category_id'])),
            if (e['quantity'] != null) _kv(ctx, 'Qty × price', '${qtyText(n(e['quantity']))}${e['unit_price'] != null ? ' × ${_money(e['unit_price'])}' : ''}'),
            _kv(ctx, 'Amount', '${_money(e['amount'])}${n(e['vat_amount']) > 0 ? ' · VAT ${_money(e['vat_amount'])}' : ''}'),
            _kv(ctx, 'Paid', '${_money(e['amount_paid'])}${due > 0.004 ? ' · ${_money(due)} to pay' : ''}${e['paid_on'] != null ? ' · ${dateText(e['paid_on'])}' : ''}'),
            _kv(ctx, 'Paid from', e['from_weekly_cash'] == true ? 'Weekly cash' : '${e['payment_method'] ?? '—'}'),
            if (e['supplier_id'] != null) _kv(ctx, 'Supplier', supplierName(e['supplier_id'])),
            if ('${e['notes'] ?? ''}'.isNotEmpty) _kv(ctx, 'Notes', '${e['notes']}'),
            if (slips.isNotEmpty) ...[
              const SectionTitle('Proof'),
              Wrap(spacing: 6, children: [for (final d in slips) OutlinedButton(onPressed: () => showProof(ctx, d), child: Text('${d['file_path'] != null ? 'Slip' : 'SMS'} · ${tableDate(d['paid_on']) ?? ''}'))]),
            ],
          ],
        )));
  }

  Widget _kv(BuildContext context, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 92, child: Text(k, style: TextStyle(fontSize: Fs.sm, color: context.tk.textMuted))),
          Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      );
}

/// Material costs at the branch: the cost of the stock left (oldest used first), the latest cost, costed stock;
/// a tap shows the material's purchases (web Purchases.jsx, tab costs)
class _MaterialCosts extends StatefulWidget {
  const _MaterialCosts({required this.refs});
  final Refs refs;
  @override
  State<_MaterialCosts> createState() => _MaterialCostsState();
}

class _MaterialCostsState extends State<_MaterialCosts> {
  List<({Json m, Object? avg, Object? last, Object? lastDate, Object? costed, Object? uncosted})>? _rows;
  String get branchId => session.branchId;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    if (branchId.isEmpty) return;
    try {
      final mats = _l(await db.from('materials').select('id, name, status, branch_id, category:material_categories(display_order)').order('name', ascending: true))
          .where((m) => m['status'] == 'active' && (m['branch_id'] == null || m['branch_id'] == branchId)).toList()
        ..sort((a, b) {
          final c = n(a['category']?['display_order'] ?? 999).compareTo(n(b['category']?['display_order'] ?? 999));
          return c != 0 ? c : '${a['name']}'.compareTo('${b['name']}');
        });
      final vals = await Future.wait([
        for (final m in mats) db.rpc('material_stock_value', params: {'p_branch_id': branchId, 'p_material_id': m['id']}).then<Map?>((v) => (v as List?)?.firstOrNull as Map?).catchError((_) => null),
      ]);
      if (!mounted) return;
      setState(() => _rows = [
            for (var i = 0; i < mats.length; i++)
              (
                m: mats[i], avg: vals[i]?['unit_cost'], last: vals[i]?['last_cost'], lastDate: vals[i]?['last_date'],
                costed: vals[i]?['costed_quantity'] ?? (vals[i]?['on_hand'] != null ? n(vals[i]!['on_hand']) - n(vals[i]!['uncosted_quantity']) : null),
                uncosted: vals[i]?['uncosted_quantity'] ?? 0,
              ),
          ]);
    } catch (_) {
      if (mounted) setState(() => _rows = []);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    if (branchId.isEmpty) return const EmptyState(icon: LucideIcons.shoppingCart, title: 'Pick a branch', description: 'Material costs are per branch — pick one in the menu.');
    final rows = _rows;
    if (rows == null) return const Skeleton(rows: 5);
    final refs = widget.refs;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final c in rows)
        Builder(builder: (_) {
          final it = refs.items['m:${c.m['id']}'];
          final unit = refs.unit(it?.stockUnitId);
          return InkWell(
            onTap: it == null
                ? null
                : () {
                    final mu = it.mainUnitId != null ? it.units.where((u) => u.id == it.mainUnitId).firstOrNull : null;
                    Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => FullPage(
                          title: '${c.m['name']} — purchases',
                          footer: [OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
                          children: [ItemHistoryList(item: it, branchId: branchId, refs: refs, mode: 'purchases', factor: mu?.factor ?? 1, symbol: refs.unit(mu?.id ?? it.stockUnitId), stockSymbol: unit)],
                        )));
                  },
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${c.m['name']}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    PlHelp('${n(c.costed) > 0 ? 'costed ${qtyText(n(c.costed))} $unit' : 'costed —'}${n(c.uncosted) > 0 ? ' · ${qtyText(n(c.uncosted))} $unit with no cost' : ''}'),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(c.avg != null ? '${_money(_r2(n(c.avg)))} / $unit' : 'no cost yet', style: TextStyle(fontWeight: FontWeight.w700, color: c.avg == null ? t.textMuted : null)),
                  PlHelp(c.last != null ? 'latest ${_money(_r2(n(c.last)))} · ${tableDate(c.lastDate) ?? ''}' : 'latest —'),
                ]),
              ]),
            ),
          );
        }),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: PlHelp('Cost of the stock left at ${session.branchName} — oldest stock is used first; price plus transport, VAT apart. Stock received before its first purchase has no cost and is left out.'),
      ),
    ]);
  }
}
