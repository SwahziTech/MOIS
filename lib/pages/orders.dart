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
import 'procurement_actions.dart';
import 'purchase_form.dart' show FromOrder;

/*
 * Orders — a port of web components/purchases/ProcurementPanels.jsx RequestsPanel, RequestView, AskModal,
 * OrderModal, EditOrderModal, CloseModal (077/084/128–133): one flow for every request — waiting → the
 * branch manager approves (and makes the order) → ordered → paid by the directors → recorded as purchases
 * or expenses → delivered. Only what is still to buy shows; bought ones are in Purchases / Expenses.
 */
double _r2(num v) => (v * 100).roundToDouble() / 100;
double? _q3(double? v) => v == null ? null : (v * 1000).roundToDouble() / 1000;
double? _num(String v) => v.trim().isEmpty ? null : double.tryParse(v.trim().replaceAll(',', ''));
String _money(Object? v) => formatMoney(n(v), session.currency);
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
const _req = {
  'waiting': ('Waiting', Tone.warning), 'approved': ('Approved', Tone.info), 'rejected': ('Turned down', Tone.error),
  'ordered': ('Ordered', Tone.success), 'done': ('Bought', Tone.success), 'cancelled': ('Cancelled', Tone.neutral),
};

double? stockFactor(Refs refs, Object? materialId, Object? unitId) {
  final it = refs.items['m:$materialId'];
  return it?.units.where((u) => u.id == unitId).firstOrNull?.factor ?? (unitId == it?.stockUnitId ? 1 : null);
}

String lineText(Refs refs, Json l, List<Json> cats) => l['kind'] == 'expense'
    ? '${cats.where((c) => c['id'] == l['category_id']).firstOrNull?['name'] ?? 'Expense'}: ${l['description'] ?? ''}'
        '${l['quantity'] != null ? ' · ${qtyText(n(l['quantity']))} ${l['unit_text'] ?? ''}' : ''}${l['amount'] != null ? ' · ${_money(l['amount'])}' : ''}'
    : '${qtyText(n(l['quantity']))} ${refs.unit('${l['unit_id']}')} ${refs.items['m:${l['material_id']}']?.name ?? '—'}'
        '${l['unit_price'] != null ? ' × ${formatAmount(n(l['unit_price']))} = ${_money(_r2(n(l['quantity']) * n(l['unit_price'])))}' : ''}';

/// The purchases recorded against each order (132)
Future<Map<String, List<Json>>> loadOrderBuys(List<Object?> orderIds) async {
  if (orderIds.isEmpty) return {};
  final d = await db.from('purchases')
      .select('id, purchase_order_id, purchase_date, amount_paid, items:purchase_items(material_id, quantity, unit_id), lines:purchase_lines(item_id, tx:inventory_transactions(material_id, quantity))')
      .inFilter('purchase_order_id', orderIds).eq('status', 'recorded').order('purchase_date', ascending: true);
  final out = <String, List<Json>>{};
  for (final p in _l(d)) { (out['${p['purchase_order_id']}'] ??= []).add(p); }
  return out;
}

/// The directors' proofs: on the order until its purchase is recorded, then on the purchase
Future<Map<String, List<Json>>> loadOrderSlips(List<Object?> orderIds, Map<String, List<Json>> buys) async {
  final pids = [for (final b in buys.values) for (final p in b) p['id']];
  final ids = [...orderIds, ...pids];
  if (ids.isEmpty) return {};
  final d = await db.from('director_payments').select('*').eq('kind', 'supplier').inFilter('ref_id', ids).order('paid_on', ascending: true);
  final orderOf = {for (final e in buys.entries) for (final p in e.value) '${p['id']}': e.key};
  final out = <String, List<Json>>{};
  for (final x in _l(d)) { (out[orderOf['${x['ref_id']}'] ?? '${x['ref_id']}'] ??= []).add(x); }
  return out;
}

/// Per material, in stock units: bought against the order, and delivered so far
({Map<String, double> bought, Map<String, double> came}) boughtOf(List<Json>? buy, Refs refs) {
  final bought = <String, double>{}, came = <String, double>{};
  for (final p in buy ?? <Json>[]) {
    for (final i in _l(p['items'])) {
      bought['${i['material_id']}'] = (bought['${i['material_id']}'] ?? 0) + n(i['quantity']) * (stockFactor(refs, i['material_id'], i['unit_id']) ?? 1);
    }
    for (final l in _l(p['lines'])) {
      final m = l['tx']?['material_id'];
      if (m == null) continue;
      came['$m'] = (came['$m'] ?? 0) + n(l['tx']['quantity']);
      if (l['item_id'] == null) bought['$m'] = (bought['$m'] ?? 0) + n(l['tx']['quantity']);   // received with the purchase
    }
  }
  return (bought: bought, came: came);
}

List<Json> matLines(Json? po) => _l(po?['lines']).where((l) => l['kind'] != 'expense').toList()..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no'])));

/// An order's material lines still to buy, in their own units, ready for the purchase form
List<({String materialId, String unitId, String quantity, double left, String price})> goodsLeftOf(Json po, List<Json>? buy, Refs refs) {
  final b = boughtOf(buy, refs).bought;
  return [
    for (final l in matLines(po))
      () {
        final f = n(l['stock_quantity']) / n(l['quantity']);
        final left = _r2((n(l['stock_quantity']) - (b['${l['material_id']}'] ?? 0)).clamp(0, double.infinity) / f);
        return (materialId: '${l['material_id']}', unitId: '${l['unit_id']}', quantity: p6s(left), left: left, price: l['unit_price'] != null ? p6s(n(l['unit_price'])) : '');
      }(),
  ].where((x) => x.left > 1e-9).toList();
}

double orderValue(Json po) => matLines(po).fold(0.0, (t, l) => t + n(l['quantity']) * n(l['unit_price']));
double recordedPaid(List<Json>? buy) => (buy ?? []).fold(0.0, (t, p) => t + n(p['amount_paid']));

/// The purchase form from an order: what is still to buy, and what the directors paid that is not yet recorded
FromOrder purchaseFromOrder(Json po, List<Json>? buy, Refs refs) {
  final lines = goodsLeftOf(po, buy, refs);
  final paid = _r2(n(po['amount_paid']) - recordedPaid(buy));
  return (
    orderId: '${po['id']}', supplierId: po['supplier_id'] as String?, branchId: po['branch_id'] as String?,
    lines: [for (final l in lines) {'materialId': l.materialId, 'unitId': l.unitId, 'quantity': l.quantity, 'price': l.price}],
    left: {for (final l in lines) l.materialId: l.left},
    paid: paid > 0 ? paid : 0.0, paidOn: po['paid_on'] as String?,
  );
}

/// Where an order stands: Ordered · Part paid · Paid · Part bought · Bought
({double value, double paid, double remaining, Map<String, double> bought, Map<String, double> came, bool boughtAny, bool boughtAll, bool cameAny, bool cameAll, (String, Tone, String)? badge})
    orderState(Json po, List<Json>? buy, Refs refs) {
  final value = _r2(orderValue(po));
  final paid = n(po['amount_paid']).toDouble();
  final bc = boughtOf(buy, refs);
  final ls = matLines(po);
  final boughtAny = ls.any((l) => (bc.bought['${l['material_id']}'] ?? 0) > 1e-9);
  final boughtAll = ls.isNotEmpty && ls.every((l) => (bc.bought['${l['material_id']}'] ?? 0) >= n(l['stock_quantity']) - 1e-9);
  final cameAny = ls.any((l) => (bc.came['${l['material_id']}'] ?? 0) > 1e-9);
  final cameAll = ls.isNotEmpty && ls.every((l) => (bc.came['${l['material_id']}'] ?? 0) >= n(l['stock_quantity']) - 1e-9);
  final badge = boughtAll
      ? ('Bought', Tone.success, 'Everything ordered is recorded as a purchase')
      : boughtAny
          ? ('Part bought', Tone.info, 'Part of the order is recorded as a purchase; the rest is still open')
          : paid >= value - 0.01 && paid > 0
              ? ('Paid', Tone.success, 'The directors paid it — record the purchase')
              : paid > 0 ? ('Part paid', Tone.warning, 'The directors paid part of it') : null;
  final rem = _r2(value - paid);
  return (value: value, paid: paid, remaining: rem > 0 ? rem : 0.0, bought: bc.bought, came: bc.came, boughtAny: boughtAny, boughtAll: boughtAll, cameAny: cameAny, cameAll: cameAll, badge: badge);
}

/// What the branch has of each material now, over its stores, in the stock unit
Future<Map<String, ({double qty, String unit})>> stockNow(String branchId) async {
  if (branchId.isEmpty) return {};
  final r = await Future.wait<dynamic>([
    db.from('stock_balances').select('material_id, quantity').eq('branch_id', branchId).not('material_id', 'is', null),
    db.from('materials').select('id, stock_unit_id'),
    db.from('units').select('id, symbol'),
  ]);
  final sym = {for (final u in r[2] as List) '${u['id']}': '${u['symbol']}'};
  final unitOf = {for (final m in r[1] as List) '${m['id']}': sym['${m['stock_unit_id']}'] ?? ''};
  final out = <String, ({double qty, String unit})>{};
  for (final x in r[0] as List) {
    final s = out['${x['material_id']}'] ?? (qty: 0.0, unit: unitOf['${x['material_id']}'] ?? '');
    out['${x['material_id']}'] = (qty: s.qty + n(x['quantity']), unit: s.unit);
  }
  for (final e in unitOf.entries) { out.putIfAbsent(e.key, () => (qty: 0.0, unit: e.value)); }
  return out;
}

String stockText(({double qty, String unit})? s) => s == null ? '…' : '${qtyText(_r2(s.qty))} ${s.unit}';

Future<bool> _push(BuildContext context, Widget page) async => await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => page)) == true;

/// What the page does once something is bought from an order
class OrderActions {
  const OrderActions({required this.onReceive, required this.onRecordExpense, required this.onRecordToken});
  final Future<void> Function(FromOrder) onReceive;
  final Future<void> Function(Json prefill) onRecordExpense;
  final Future<void> Function(Json request, String meterName) onRecordToken;
}

class RequestsPanel extends StatefulWidget {
  const RequestsPanel({super.key, required this.refs, required this.people, required this.actions, this.openFirst});
  final Refs refs;
  final Map<String, String> people;
  final OrderActions actions;
  final String? openFirst;
  @override
  State<RequestsPanel> createState() => RequestsPanelState();
}

class RequestsPanelState extends State<RequestsPanel> {
  List<Json>? _rows;
  List<Json> _cats = [];
  Map<String, Json> _orders = {};   // request id → its open order
  Map<String, List<Json>> _buys = {}, _slips = {};
  Map<String, String> _people = {};
  DateTime? _savedAt;
  String _error = '';
  Refs get refs => widget.refs;
  String get branchId => session.branchId;

  @override
  void initState() {
    super.initState();
    load().then((_) {
      final first = widget.openFirst == null ? null : _rows?.where((r) => r['id'] == widget.openFirst).firstOrNull;
      if (first != null && mounted) _open(first);
    });
  }

  Future<void> load() async {
    try {
      final (j, at) = await offline.load<Json>('orders', () async {
        final r = await Future.wait<dynamic>([
          db.from('purchase_requests').select('*, lines:purchase_request_lines(*)').order('requested_on', ascending: false).order('request_no', ascending: false),
          db.from('expense_categories').select('id, name, status').order('display_order', ascending: true).order('name', ascending: true),
          db.from('purchase_orders').select('*, lines:purchase_order_lines(*)').eq('status', 'open').not('request_id', 'is', null),
        ]);
        final buys = await loadOrderBuys([for (final o in r[2] as List) o['id']]);
        final slips = await loadOrderSlips([for (final o in r[2] as List) o['id']], buys);
        final ids = {for (final q in r[0] as List) if (q['requested_by'] != null) '${q['requested_by']}'}.toList();
        final ppl = ids.isEmpty ? [] : await db.from('profiles').select('id, first_name, last_name, email').inFilter('id', ids);
        return {'rows': r[0], 'cats': r[1], 'po': r[2], 'buys': buys, 'slips': slips, 'ppl': ppl};
      });
      if (!mounted) return;
      setState(() {
        _rows = _l(j['rows']);
        _cats = _l(j['cats']);
        _orders = {for (final o in _l(j['po'])) '${o['request_id']}': o};
        _buys = {for (final e in (j['buys'] as Map).entries) '${e.key}': _l(e.value)};
        _slips = {for (final e in (j['slips'] as Map).entries) '${e.key}': _l(e.value)};
        _people = {
          ...widget.people,
          for (final p in _l(j['ppl']))
            '${p['id']}': [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ').isEmpty
                ? '${p['email']}'
                : [p['first_name'], p['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' '),
        };
        _savedAt = at;
      });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load purchase requests.");
    }
  }

  bool canBuy(Object? b) => session.canAt('procurement.receive', '$b', null) || session.canAt('cash.approve', '$b', null);
  bool get canAsk => branchId.isNotEmpty && session.canAt('procurement.request', branchId, null);

  Future<void> ask() async { if (await _push(context, _Ask(refs: refs, branchId: branchId, cats: _cats))) load(); }

  Future<void> _open(Json r) async {
    await Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _RequestView(r: r, refs: refs, cats: _cats, people: _people, actions: widget.actions, onChanged: load)));
    load();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    if (_error.isNotEmpty && _rows == null) return ErrorState(_error, onRetry: load);
    final rows = _rows;
    if (rows == null) return const Skeleton(rows: 4);
    // only what is still to buy (2026-11-16): waiting, approved, or ordered with its order still open
    final here = rows.where((r) => session.inBranch(r['branch_id']) && (['waiting', 'approved'].contains(r['status']) || (r['status'] == 'ordered' && _orders['${r['id']}'] != null))).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OfflineNote(_savedAt),
      Stats([
        Stat('Waiting', '${here.where((r) => r['status'] == 'waiting').length}', figureColor: here.any((r) => r['status'] == 'waiting') ? C.warning : null, help: 'for the branch manager'),
        Stat('Approved', '${here.where((r) => r['status'] == 'approved').length}', help: 'to order'),
        Stat('Ordered', '${here.where((r) => r['status'] == 'ordered').length}', help: 'to confirm when bought'),
      ]),
      Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (canAsk) FilledButton.icon(onPressed: ask, icon: const Icon(LucideIcons.plus, size: 15), label: const Text('Ask for materials or expenses')),
        const PlHelp('Open a request to approve and order it.'),
      ]),
      const SizedBox(height: 10),
      if (here.isEmpty) const PlHelp('Nothing waiting to be bought.'),
      for (final r in here)
        Builder(builder: (_) {
          final po = _orders['${r['id']}'];
          final pb = po == null ? null : orderState(po, _buys['${po['id']}'], refs).badge;
          final (label, tone) = pb != null ? (pb.$1, pb.$2) : (_req[r['status']] ?? ('${r['status']}', Tone.neutral));
          final slips = po == null ? <Json>[] : _slips['${po['id']}'] ?? [];
          final left = po == null ? <dynamic>[] : goodsLeftOf(po, _buys['${po['id']}'], refs);
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: t.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
              child: InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => _open(r),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Expanded(child: Text('#${r['request_no']} · ${tableDate(r['requested_on']) ?? ''} · ${_people['${r['requested_by']}'] ?? ''}${r['needed_by'] != null ? ' · needed ${tableDate(r['needed_by'])}' : ''}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted))),
                      Badge2(label, tone: tone),
                    ]),
                    const SizedBox(height: 4),
                    for (final l in _l(r['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no'])))) Text(lineText(refs, l, _cats), style: const TextStyle(fontWeight: FontWeight.w600)),
                    if ('${r['decision_note'] ?? ''}'.isNotEmpty) PlHelp('${r['decision_note']}'),
                    if (slips.isNotEmpty || (po != null && canBuy(r['branch_id']) && left.isNotEmpty))
                      Wrap(spacing: 6, children: [
                        for (final d in slips) TextButton.icon(onPressed: () => showProof(context, d), icon: const Icon(LucideIcons.fileCheck, size: 14), label: Text('${d['file_path'] != null ? 'Slip' : 'SMS'} · ${tableDate(d['paid_on'])}')),
                        if (po != null && canBuy(r['branch_id']) && left.isNotEmpty)
                          FilledButton(onPressed: () async { await widget.actions.onReceive(purchaseFromOrder(po, _buys['${po['id']}'], refs)); load(); }, child: const Text('Record purchase')),
                      ]),
                  ]),
                ),
              ),
            ),
          );
        }),
    ]);
  }
}

/// A request, start to end: decide; order; edit the order or confirm what was bought
class _RequestView extends StatefulWidget {
  const _RequestView({required this.r, required this.refs, required this.cats, required this.people, required this.actions, required this.onChanged});
  final Json r;
  final Refs refs;
  final List<Json> cats;
  final Map<String, String> people;
  final OrderActions actions;
  final Future<void> Function() onChanged;
  @override
  State<_RequestView> createState() => _RequestViewState();
}

class _RequestViewState extends State<_RequestView> {
  late Json r = widget.r;
  Refs get refs => widget.refs;
  Json? _po;
  bool _poLoaded = false;
  Map<String, double> _got = {}, _paidFor = {};
  List<Json>? _buy;
  List<Json> _slips = [];
  String _accName = '';
  Map<String, ({double qty, String unit})>? _stock;
  final _note = TextEditingController();
  bool _busy = false;
  String _error = '';

  String get b => '${r['branch_id']}';
  @override
  void initState() {
    super.initState();
    _loadOrder();
    stockNow(b).then((s) { if (mounted) setState(() => _stock = s); }).catchError((_) {});
  }

  Future<void> _reload() async {
    final x = await db.from('purchase_requests').select('*, lines:purchase_request_lines(*)').eq('id', r['id']).maybeSingle();
    if (x != null && mounted) setState(() => r = Map<String, dynamic>.from(x));
    await _loadOrder();
    await widget.onChanged();
  }

  Future<void> _loadOrder() async {
    try {
      final d = await db.from('purchase_orders').select('*, lines:purchase_order_lines(*)').eq('request_id', r['id']).neq('status', 'cancelled').order('created_at', ascending: false).limit(1);
      final o = _l(d).firstOrNull;
      Map<String, double> got = {}, paidFor = {};
      List<Json>? buy;
      List<Json> slips = [];
      var acc = '';
      if (o != null) {
        final rr = await Future.wait<dynamic>([
          db.from('purchase_order_receipts').select('order_line_id, received').eq('order_id', o['id']),
          db.from('expenses').select('order_line_id, amount').inFilter('order_line_id', [for (final l in _l(o['lines'])) l['id']]).eq('status', 'recorded'),
        ]);
        got = {for (final x in rr[0] as List) '${x['order_line_id']}': n(x['received']).toDouble()};
        for (final x in rr[1] as List) { paidFor['${x['order_line_id']}'] = (paidFor['${x['order_line_id']}'] ?? 0) + n(x['amount']); }
        buy = (await loadOrderBuys([o['id']]))['${o['id']}'] ?? [];
        slips = (await loadOrderSlips([o['id']], {'${o['id']}': buy}))['${o['id']}'] ?? [];
        if (o['paid_account_id'] != null) acc = '${(await db.from('payment_accounts').select('name').eq('id', o['paid_account_id']).maybeSingle())?['name'] ?? ''}';
      }
      if (mounted) setState(() { _po = o; _got = got; _paidFor = paidFor; _buy = buy; _slips = slips; _accName = acc; _poLoaded = true; });
    } catch (_) {
      if (mounted) setState(() => _poLoaded = true);
    }
  }

  Future<void> _decide(String decision) async {
    setState(() { _error = ''; _busy = true; });
    try {
      await db.rpc('decide_purchase_request', params: {'p_id': r['id'], 'p_decision': decision, 'p_note': _note.text.trim().isEmpty ? null : _note.text});
      _note.clear();
      await _reload();
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  String supplierName(Object? id) => '${refs.suppliers.where((x) => x['id'] == id).firstOrNull?['name'] ?? '—'}';
  bool lineDone(Json l) => l['kind'] == 'expense' ? _paidFor['${l['id']}'] != null : (_got['${l['id']}'] ?? 0) >= n(l['stock_quantity']) - 1e-9;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final po = _po;
    final lines = _l(po?['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no'])));
    final goodsLeft = po == null ? <dynamic>[] : goodsLeftOf(po, _buy, refs);
    final st = po == null ? null : orderState(po, _buy, refs);
    final nothingYet = po != null && !(n(po['amount_paid']) > 0) && (_buy ?? []).isEmpty && !lines.any((l) => l['kind'] == 'expense' ? _paidFor['${l['id']}'] != null : (_got['${l['id']}'] ?? 0) > 0);
    final canConfirm = po != null && po['status'] == 'open' && (session.canAt('procurement.receive', b, null) || session.canAt('cash.approve', b, null));
    final (label, tone) = _req[r['status']] ?? ('${r['status']}', Tone.neutral);
    return FullPage(
      title: 'Request #${r['request_no']}',
      footer: [
        if (['waiting', 'approved'].contains(r['status']) && session.canAt('procurement.request', b, null))
          TextButton(onPressed: _busy ? null : () => _decide('cancelled'), child: const Text('Cancel request')),
        if (r['status'] == 'waiting' && session.canAt('procurement.approve', b, null)) ...[
          OutlinedButton(onPressed: _busy || _note.text.trim().isEmpty ? null : () => _decide('rejected'), child: const Text('Turn down')),
          // approve makes the order (128): the order opens filled from the request, to check and confirm
          FilledButton(
            onPressed: _busy ? null : () async {
              if (session.canAt('procurement.order', b, null)) {
                if (await _push(context, _OrderForm(refs: refs, branchId: b, request: r, approve: true))) _reload();
              } else {
                _decide('approved');
              }
            },
            child: const Text('Approve'),
          ),
        ],
        if (r['status'] == 'approved' && session.canAt('procurement.order', b, null))
          FilledButton(onPressed: () async { if (await _push(context, _OrderForm(refs: refs, branchId: b, request: r))) _reload(); }, child: const Text('Make order')),
        if (r['status'] == 'ordered' && po?['status'] == 'open') ...[
          TextButton.icon(onPressed: () => openDoc(context, 'Purchase order PO #${po!['po_no']}', () => poPdf('${po['id']}')), icon: const Icon(LucideIcons.printer, size: 15), label: const Text('Print order')),
          if (session.canAt('procurement.order', b, null) && nothingYet)
            OutlinedButton(onPressed: () async { if (await _push(context, _EditOrder(po: po, refs: refs))) _reload(); }, child: const Text('Edit order')),
          if (session.canAt('procurement.order', b, null))
            OutlinedButton(onPressed: () async { if (await _push(context, _CloseOrder(po: po!, cancel: nothingYet))) _reload(); }, child: Text(nothingYet ? 'Cancel order…' : 'Close order…')),
        ],
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Badge2(label, tone: tone),
          PlHelp('asked ${dateText(r['requested_on'])}${widget.people['${r['requested_by']}'] != null ? ' by ${widget.people['${r['requested_by']}']}' : ''}'
              '${r['needed_by'] != null ? ' · needed by ${dateText(r['needed_by'])}' : ''}${'${r['decision_note'] ?? ''}'.isNotEmpty ? ' · ${r['decision_note']}' : ''}'),
        ]),
        if ('${r['notes'] ?? ''}'.isNotEmpty) PlHelp('${r['notes']}'),
        if (!_poLoaded) const Skeleton(rows: 2, height: 24),
        if (_poLoaded && po == null) ...[
          if (r['supplier_id'] != null || r['supplier_name'] != null)
            Padding(padding: const EdgeInsets.only(top: 8), child: Text('Supplier: ${r['supplier_id'] != null ? supplierName(r['supplier_id']) : '${r['supplier_name']} (new)'}', style: const TextStyle(fontWeight: FontWeight.w600))),
          const SectionTitle('Asked for'),
          for (final l in _l(r['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no']))))
            Container(
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Row(children: [
                Expanded(child: Text(lineText(refs, l, widget.cats), style: const TextStyle(fontSize: Fs.sm))),
                if (l['kind'] != 'expense') PlHelp('in stock ${_stock == null ? '…' : stockText(_stock!['${l['material_id']}'])}'),
              ]),
            ),
        ],
        if (r['status'] == 'waiting' && session.canAt('procurement.approve', b, null)) ...[
          const SizedBox(height: 10),
          TextField(controller: _note, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Note (needed to turn down)')),
        ],
        if (po != null) ...[
          // where the order stands (132): asked → approved → ordered → paid → recorded → delivered
          if (st != null && matLines(po).isNotEmpty) ...[
            const SizedBox(height: 10),
            SlideRow(spacing: 4, children: [
              for (final (l, c) in [
                ('Asked', 'done'), ('Approved', 'done'), ('Ordered', 'done'),
                (st.paid >= st.value - 0.01 && st.paid > 0 ? 'Paid' : st.paid > 0 ? 'Part paid' : 'Paid', st.paid >= st.value - 0.01 && st.paid > 0 ? 'done' : st.paid > 0 ? 'part' : ''),
                (st.boughtAll ? 'Recorded' : st.boughtAny ? 'Part recorded' : 'Recorded', st.boughtAll ? 'done' : st.boughtAny ? 'part' : ''),
                (st.cameAll ? 'Delivered' : st.cameAny ? 'Part delivered' : 'Delivered', st.cameAll ? 'done' : st.cameAny ? 'part' : ''),
              ])
                Badge2(l, tone: c == 'done' ? Tone.success : c == 'part' ? Tone.warning : Tone.neutral),
            ]),
          ],
          SectionTitle('Order #${po['po_no']}${po['expected_on'] != null ? ' · expected ${dateText(po['expected_on'])}' : ''}${po['status'] != 'open' ? ' · ${po['status']}' : ''}'),
          for (final l in lines)
            Builder(builder: (_) {
              final isExp = l['kind'] == 'expense';
              final u = isExp ? '${l['unit_text'] ?? ''}' : refs.unit('${l['unit_id']}');
              final f = isExp ? 1.0 : n(l['stock_quantity']) / n(l['quantity']);
              final amount = isExp ? (l['amount'] != null ? formatAmount(n(l['amount'])) : '') : l['unit_price'] != null ? formatAmount(_r2(n(l['quantity']) * n(l['unit_price']))) : '';
              Widget bought() {
                if (!isExp && st != null) {
                  final bq = _r2((st.bought['${l['material_id']}'] ?? 0) / f);
                  return bq >= n(l['quantity']) - 1e-9 ? const Badge2('Bought', tone: Tone.success) : PlHelp('${qtyText(bq)} of ${qtyText(n(l['quantity']))} $u');
                }
                if (lineDone(l)) return Badge2(isExp ? 'Recorded ${_money(_paidFor['${l['id']}'])}' : 'Received', tone: Tone.success);
                if (isExp) {
                  return canConfirm
                      ? FilledButton(
                          onPressed: () async {
                            if (l['meter_id'] != null) {
                              await widget.actions.onRecordToken({'id': r['id'], 'requested_on': r['requested_on'], 'lines': [{'meter_id': l['meter_id'], 'quantity': l['quantity'], 'amount': l['amount']}]},
                                  '${l['description'] ?? ''}'.replaceFirst(RegExp('^LUKU top-up — '), ''));
                            } else {
                              await widget.actions.onRecordExpense({'category_id': l['category_id'], 'description': l['description'], 'quantity': l['quantity'], 'amount': l['amount'], 'order_line_id': l['id'], 'request_line_id': l['request_line_id']});
                            }
                            _reload();
                          },
                          child: Text(l['meter_id'] != null ? 'Record token bought' : 'Record expense'),
                        )
                      : const SizedBox.shrink();
                }
                return PlHelp('${qtyText(_r2((_got['${l['id']}'] ?? 0) / f))} of ${qtyText(n(l['quantity']))} $u');
              }

              return Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Expanded(child: Text(isExp ? '${l['description'] ?? ''}' : refs.items['m:${l['material_id']}']?.name ?? '—', style: const TextStyle(fontWeight: FontWeight.w600))),
                    Text(amount, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                  PlHelp([
                    if (l['quantity'] != null) '${qtyText(n(l['quantity']))} $u',
                    if (!isExp && l['unit_price'] != null) '@ ${formatAmount(n(l['unit_price']))}',
                    if (!isExp) 'in stock ${_stock == null ? '…' : stockText(_stock!['${l['material_id']}'])}',
                  ].join(' · ')),
                  Align(alignment: Alignment.centerRight, child: bought()),
                ]),
              );
            }),
          if (st != null && matLines(po).isNotEmpty) ...[
            const SizedBox(height: 10),
            for (final (k, v) in [
              ('Supplier', supplierName(po['supplier_id'])),
              ('Required', _money(st.value)),
              ('Paid', '${_money(st.paid)}${st.paid > 0 && po['paid_on'] != null ? ' · ${dateText(po['paid_on'])}' : ''}'),
              ('Remaining', _money(st.remaining)),
              ('Source', st.paid > 0 ? 'Directors${_accName.isNotEmpty ? ' · $_accName' : ''}' : 'Not paid yet — the directors pay it'),
            ])
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(children: [
                  SizedBox(width: 92, child: Text(k, style: TextStyle(fontSize: Fs.sm, color: t.textMuted))),
                  Expanded(child: Text(v, style: TextStyle(fontWeight: FontWeight.w600, color: k == 'Remaining' && st.remaining > 0.004 ? C.warning : null))),
                ]),
              ),
            if (_slips.isNotEmpty)
              Wrap(spacing: 6, children: [
                for (final d in _slips) TextButton.icon(onPressed: () => showProof(context, d), icon: const Icon(LucideIcons.fileCheck, size: 14), label: Text('${d['file_path'] != null ? 'Slip' : 'SMS'} · ${tableDate(d['paid_on'])} · ${formatAmount(n(d['amount']))}')),
              ]),
          ],
          if ((_buy ?? []).isNotEmpty) ...[
            const SectionTitle('Recorded as purchase'),
            for (final p in _buy!)
              PlHelp('${dateText(p['purchase_date'])} · ${[
                for (final i in _l(p['items'])) '${qtyText(n(i['quantity']))} ${refs.unit('${i['unit_id']}')} ${refs.items['m:${i['material_id']}']?.name ?? ''}',
                for (final x in _l(p['lines'])) if (x['item_id'] == null && x['tx']?['material_id'] != null)
                  '${qtyText(n(x['tx']['quantity']))} ${refs.unit(refs.items['m:${x['tx']['material_id']}']?.stockUnitId)} ${refs.items['m:${x['tx']['material_id']}']?.name ?? ''}',
              ].join(', ')} · paid ${formatAmount(n(p['amount_paid']))}'),
          ],
          if (canConfirm && goodsLeft.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton(onPressed: () async { await widget.actions.onReceive(purchaseFromOrder(po, _buy, refs)); _reload(); }, child: const Text('Record purchase')),
              ),
            ),
        ],
      ],
    );
  }
}

// ---- Change an order before anything comes: expected date, notes, quantities, prices ----
class _EditOrder extends StatefulWidget {
  const _EditOrder({required this.po, required this.refs});
  final Json po;
  final Refs refs;
  @override
  State<_EditOrder> createState() => _EditOrderState();
}

class _EditOrderState extends State<_EditOrder> {
  late String _expected = '${widget.po['expected_on'] ?? ''}';
  late final _notes = TextEditingController(text: '${widget.po['notes'] ?? ''}');
  late final List<({Json l, TextEditingController qty, TextEditingController price})> _ls = [
    for (final l in _l(widget.po['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no']))))
      (
        l: l,
        qty: TextEditingController(text: l['quantity'] != null ? p6s(n(l['quantity'])) : ''),
        price: TextEditingController(text: l['kind'] == 'expense' ? (l['amount'] != null ? p6s(n(l['amount'])) : '') : l['unit_price'] != null ? p6s(n(l['unit_price'])) : ''),
      ),
  ];
  bool _busy = false;
  String _error = '';

  @override
  Widget build(BuildContext context) => FullPage(
        title: 'Edit order #${widget.po['po_no']}',
        footer: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() { _busy = true; _error = ''; });
                    try {
                      await db.rpc('update_purchase_order', params: {'p_id': widget.po['id'], 'p': {
                        'expected_on': _expected.isEmpty ? null : _expected, 'notes': _notes.text,
                        'lines': [for (final x in _ls) {'id': x.l['id'], 'quantity': _q3(_num(x.qty.text)), if (x.l['kind'] == 'expense') 'amount': _num(x.price.text) else 'unit_price': _num(x.price.text)}],
                      }});
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (e) {
                      setState(() { _busy = false; _error = dbError(e); });
                    }
                  },
            child: const Text('Save'),
          ),
        ],
        children: [
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
          for (final x in _ls)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(x.l['kind'] == 'expense' ? '${x.l['description'] ?? ''}' : widget.refs.items['m:${x.l['material_id']}']?.name ?? '—', style: const TextStyle(fontWeight: FontWeight.w600)),
                Row(children: [
                  Expanded(child: TextField(controller: x.qty, keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: 'Quantity', suffixText: x.l['kind'] == 'expense' ? '${x.l['unit_text'] ?? ''}' : widget.refs.unit('${x.l['unit_id']}')))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: x.price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Price / amount (TZS)'))),
                ]),
              ]),
            ),
          DateField(label: 'Expected', value: _expected.isEmpty ? session.today : _expected, onChange: (v) => setState(() => _expected = v)),
          const SizedBox(height: 12),
          TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes')),
        ],
      );
}

class _CloseOrder extends StatefulWidget {
  const _CloseOrder({required this.po, required this.cancel});
  final Json po;
  final bool cancel;
  @override
  State<_CloseOrder> createState() => _CloseOrderState();
}

class _CloseOrderState extends State<_CloseOrder> {
  final _reason = TextEditingController();
  bool _busy = false;
  String _error = '';
  @override
  Widget build(BuildContext context) => FullPage(
        title: '${widget.cancel ? 'Cancel' : 'Close'} order #${widget.po['po_no']}',
        footer: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: C.error),
            onPressed: _busy || (widget.cancel && _reason.text.trim().isEmpty)
                ? null
                : () async {
                    setState(() { _busy = true; _error = ''; });
                    try {
                      await db.rpc('close_purchase_order', params: {'p_id': widget.po['id'], 'p_cancel': widget.cancel, 'p_reason': _reason.text});
                      if (context.mounted) Navigator.pop(context, true);
                    } catch (e) {
                      setState(() { _busy = false; _error = dbError(e); });
                    }
                  },
            child: Text(widget.cancel ? 'Cancel order' : 'Close order'),
          ),
        ],
        children: [
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
          TextField(controller: _reason, autofocus: true, onChanged: (_) => setState(() {}),
              decoration: InputDecoration(labelText: widget.cancel ? 'Why is it cancelled?' : 'Note (optional) — e.g. the rest is not coming')),
        ],
      );
}

/// Suppliers who supplied these before, most purchases first, the latest breaking a tie
List<String> _rank(Iterable<({String s, String d})> hs) {
  final score = <String, ({int n, String d})>{};
  for (final h in hs) {
    final x = score[h.s] ?? (n: 0, d: '');
    score[h.s] = (n: x.n + 1, d: h.d.compareTo(x.d) > 0 ? h.d : x.d);
  }
  return (score.entries.toList()..sort((a, b) => b.value.n != a.value.n ? b.value.n.compareTo(a.value.n) : b.value.d.compareTo(a.value.d))).map((e) => e.key).toList();
}

Future<Map<String, List<({String s, String d})>>> _pastByMaterial(String branchId) async {
  final d = await db.from('purchases').select('supplier_id, purchase_date, lines:purchase_lines(tx:inventory_transactions(material_id))').eq('status', 'recorded').eq('branch_id', branchId);
  final m = <String, List<({String s, String d})>>{};
  for (final x in _l(d)) {
    for (final l in _l(x['lines'])) {
      if (l['tx']?['material_id'] != null && x['supplier_id'] != null) (m['${l['tx']['material_id']}'] ??= []).add((s: '${x['supplier_id']}', d: '${x['purchase_date']}'));
    }
  }
  return m;
}

List<Item> _mats(Refs refs, String branchId) =>
    refs.items.values.where((i) => i.kind == 'material' && i.status == 'active' && (i.branchId == null || i.branchId == branchId)).toList()..sort(byMaterialOrder);

class _AskLine {
  String kind = 'material', materialId = '', supplierId = '', unitId = '', categoryId = '';
  bool supTouched = false;
  final newSupplier = TextEditingController(), quantity = TextEditingController(), price = TextEditingController(), description = TextEditingController(),
      unitText = TextEditingController(), amount = TextEditingController();
  double? get total => kind == 'expense' ? _num(amount.text) : (_num(quantity.text) != null && _num(price.text) != null ? _num(quantity.text)! * _num(price.text)! : null);
}

// ---- Ask for materials or expenses (084/128): one request per supplier ----
class _Ask extends StatefulWidget {
  const _Ask({required this.refs, required this.branchId, required this.cats});
  final Refs refs;
  final String branchId;
  final List<Json> cats;
  @override
  State<_Ask> createState() => _AskState();
}

class _AskState extends State<_Ask> {
  List<_AskLine> _lines = [_AskLine()];
  Map<String, List<({String s, String d})>> _past = {};
  String _neededBy = '';
  final _notes = TextEditingController();
  bool _busy = false;
  String _error = '';
  Refs get refs => widget.refs;
  late final active = refs.suppliers.where((x) => x['status'] == 'active').toList()..sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
  List<String> suggestFor(String m) => _rank(_past[m] ?? const []).where((id) => active.any((x) => x['id'] == id)).toList();

  @override
  void initState() {
    super.initState();
    _pastByMaterial(widget.branchId).then((p) {
      if (!mounted) return;
      setState(() {
        _past = p;
        // history arriving after a material was chosen: fill the lines not picked by hand
        for (final l in _lines) {
          if (l.kind == 'material' && l.materialId.isNotEmpty && !l.supTouched && l.supplierId.isEmpty) l.supplierId = suggestFor(l.materialId).firstOrNull ?? '';
        }
      });
    }).catchError((_) {});
  }

  String supKey(_AskLine l) => l.supplierId == '__new' ? 'n:${l.newSupplier.text.trim().toLowerCase()}' : l.supplierId;

  Future<void> _save() async {
    setState(() => _error = '');
    void fail(String m) => setState(() { _busy = false; _error = m; });
    if (_lines.any((l) => l.kind == 'material' && (l.materialId.isEmpty || !((_num(l.quantity.text) ?? 0) > 0) || l.unitId.isEmpty))) return fail('Each material line needs the material, a quantity above zero and a unit.');
    if (_lines.any((l) => l.kind == 'expense' && (l.categoryId.isEmpty || l.description.text.trim().isEmpty))) return fail('Each expense line needs its kind and what it is.');
    if (_lines.any((l) => l.kind == 'material' && (l.supplierId.isEmpty || (l.supplierId == '__new' && l.newSupplier.text.trim().isEmpty)))) return fail('Choose the supplier for each material, or name a new one.');
    if (_lines.any((l) => l.kind == 'expense' && l.supplierId == '__new' && l.newSupplier.text.trim().isEmpty)) return fail('Name the new supplier.');
    if (_lines.any((l) => l.kind == 'material' && _num(l.price.text) == null)) return fail('Enter the price a unit for each material.');
    // one request per supplier; expense lines with no supplier go with the first one
    final groups = <({String key, _AskLine? sample, List<_AskLine> lines})>[];
    for (final l in _lines) {
      final k = supKey(l);
      if (k.isEmpty) continue;
      final g = groups.where((x) => x.key == k).firstOrNull;
      if (g == null) {
        groups.add((key: k, sample: l, lines: [l]));
      } else {
        g.lines.add(l);
      }
    }
    final loose = _lines.where((l) => supKey(l).isEmpty).toList();
    if (loose.isNotEmpty) {
      if (groups.isNotEmpty) {
        groups.first.lines.addAll(loose);
      } else {
        groups.add((key: '', sample: null, lines: loose));
      }
    }
    setState(() => _busy = true);
    var done = 0;
    for (final g in groups) {
      final x = g.sample;
      try {
        await db.rpc('submit_purchase_request', params: {'p': {
          'branch_id': widget.branchId, 'needed_by': _neededBy.isEmpty ? null : _neededBy, 'notes': _notes.text,
          if (x != null) ...(x.supplierId == '__new' ? {'supplier_name': x.newSupplier.text.trim()} : {'supplier_id': x.supplierId}),
          'lines': [
            for (final l in g.lines)
              l.kind == 'expense'
                  ? {'kind': 'expense', 'category_id': l.categoryId, 'description': l.description.text, 'quantity': _q3(_num(l.quantity.text)), 'unit_text': l.unitText.text, 'amount': _num(l.amount.text)}
                  : {'kind': 'material', 'material_id': l.materialId, 'quantity': _q3(_num(l.quantity.text)), 'unit_id': l.unitId, 'unit_price': _num(l.price.text)},
          ],
        }});
        done += 1;
      } catch (e) {
        if (done > 0) setState(() => _lines = _lines.where((l) => !groups.take(done).any((gg) => gg.lines.contains(l))).toList());
        return fail('${done > 0 ? '$done of ${groups.length} requests sent; the next failed: ' : ''}${dbError(e)}');
      }
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final mats = _mats(refs, widget.branchId);
    final used = {for (final l in _lines) if (supKey(l).isNotEmpty) supKey(l)}.length;
    final total = _lines.fold<double>(0, (s, l) => s + (l.total ?? 0));
    return FullPage(
      title: 'Ask for materials or expenses',
      footer: [
        if (used > 1) PlHelp('$used suppliers: one request for each'),
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Send for approval')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        for (final (i, l) in _lines.indexed)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 10),
            decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(8)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Chip2('Material', on: l.kind == 'material', onTap: () => setState(() => l.kind = 'material')),
                const SizedBox(width: 6),
                Chip2('Expense', on: l.kind == 'expense', onTap: () => setState(() => l.kind = 'expense')),
                const Spacer(),
                if (l.total != null) Text(formatAmount(_r2(l.total!)), style: const TextStyle(fontWeight: FontWeight.w700)),
                if (_lines.length > 1) IconButton(tooltip: 'Remove line', onPressed: () => setState(() => _lines = [..._lines]..removeAt(i)), icon: const Icon(LucideIcons.trash2, size: 16)),
              ]),
              const SizedBox(height: 8),
              if (l.kind == 'material')
                DropdownButtonFormField<String>(
                  key: ValueKey('am$i${l.materialId}'),
                  initialValue: l.materialId.isEmpty ? null : l.materialId, isExpanded: true, decoration: const InputDecoration(labelText: 'Material'),
                  items: [for (final m in mats) DropdownMenuItem(value: m.id, child: Text('${m.materialCategory != null ? '${m.materialCategory} · ' : ''}${m.name}', overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setState(() {
                    final m = refs.items['m:$v'];
                    l.materialId = v ?? '';
                    l.unitId = m?.mainUnitId ?? m?.stockUnitId ?? '';
                    // each material its own supplier: who supplied it before, unless picked by hand
                    if (!l.supTouched) l.supplierId = suggestFor(l.materialId).firstOrNull ?? '';
                  }),
                )
              else ...[
                DropdownButtonFormField<String>(
                  initialValue: l.categoryId.isEmpty ? null : l.categoryId, isExpanded: true, decoration: const InputDecoration(labelText: 'What kind…'),
                  items: [for (final c in widget.cats.where((c) => c['status'] == 'active')) DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}'))],
                  onChanged: (v) => setState(() => l.categoryId = v ?? ''),
                ),
                const SizedBox(height: 8),
                TextField(controller: l.description, decoration: const InputDecoration(labelText: 'What', hintText: 'e.g. LUKU for Makina')),
              ],
              const SizedBox(height: 8),
              Builder(builder: (_) {
                final sug = l.kind == 'material' ? suggestFor(l.materialId) : <String>[];
                return DropdownButtonFormField<String>(
                  key: ValueKey('as$i${l.supplierId}'),
                  initialValue: l.supplierId, isExpanded: true, decoration: const InputDecoration(labelText: 'Supplier'),
                  items: [
                    DropdownMenuItem(value: '', child: Text(l.kind == 'expense' ? 'Optional…' : 'Choose…')),
                    for (final id in sug) DropdownMenuItem(value: id, child: Text('${active.where((x) => x['id'] == id).firstOrNull?['name'] ?? ''} · supplied this before', overflow: TextOverflow.ellipsis)),
                    for (final x in active.where((x) => !sug.contains(x['id']))) DropdownMenuItem(value: '${x['id']}', child: Text('${x['name']}', overflow: TextOverflow.ellipsis)),
                    const DropdownMenuItem(value: '__new', child: Text('New supplier…')),
                  ],
                  onChanged: (v) => setState(() { l.supplierId = v ?? ''; l.supTouched = true; }),
                );
              }),
              if (l.supplierId == '__new') ...[const SizedBox(height: 8), TextField(controller: l.newSupplier, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: "The supplier's name"))],
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: l.quantity, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Quantity', hintText: l.kind == 'expense' ? 'optional' : null))),
                const SizedBox(width: 6),
                SizedBox(
                  width: 96,
                  child: l.kind == 'material'
                      ? DropdownButtonFormField<String>(
                          key: ValueKey('au$i${l.materialId}${l.unitId}'),
                          initialValue: (refs.items['m:${l.materialId}']?.units.any((u) => u.id == l.unitId) ?? false) ? l.unitId : null,
                          decoration: const InputDecoration(labelText: 'Unit'),
                          items: [for (final u in refs.items['m:${l.materialId}']?.units ?? <UnitF>[]) DropdownMenuItem(value: u.id, child: Text(refs.unit(u.id)))],
                          onChanged: (v) => setState(() => l.unitId = v ?? ''),
                        )
                      : TextField(controller: l.unitText, decoration: const InputDecoration(labelText: 'Units')),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: TextField(controller: l.kind == 'expense' ? l.amount : l.price, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(labelText: l.kind == 'expense' ? 'Amount (optional)' : 'Price a unit')),
                ),
              ]),
            ]),
          ),
        if (_lines.length > 1) Align(alignment: Alignment.centerRight, child: Text('Total ${formatAmount(_r2(total))}', style: const TextStyle(fontWeight: FontWeight.w700))),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: () => setState(() => _lines = [..._lines, _AskLine()..kind = _lines.last.kind]), icon: const Icon(LucideIcons.plus, size: 14), label: const Text('Add a line')),
        ),
        const SizedBox(height: 8),
        DateField(label: 'Needed by (optional)', value: _neededBy.isEmpty ? session.today : _neededBy, onChange: (v) => setState(() => _neededBy = v)),
        const SizedBox(height: 12),
        TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Why / notes (optional)')),
      ],
    );
  }
}

// ---- The purchase order for a request (approve & make order, 128) ----
class _OrderForm extends StatefulWidget {
  const _OrderForm({required this.refs, required this.branchId, required this.request, this.approve = false});
  final Refs refs;
  final String branchId;
  final Json request;
  final bool approve;
  @override
  State<_OrderForm> createState() => _OrderFormState();
}

class _OrderLine {
  _OrderLine(this.materialId, String q, this.unitId, String p) {
    qty.text = q;
    price.text = p;
  }
  String materialId, unitId;
  final qty = TextEditingController(), price = TextEditingController();
}

class _OrderFormState extends State<_OrderForm> {
  Json get rq => widget.request;
  Refs get refs => widget.refs;
  late String _supplierId = '${rq['supplier_id'] ?? (rq['supplier_name'] != null ? '__new' : '')}';
  late final _newSupplier = TextEditingController(text: '${rq['supplier_name'] ?? ''}');
  late List<_OrderLine> _lines = [
    for (final l in _l(rq['lines']).where((l) => l['kind'] != 'expense').toList()..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no']))))
      _OrderLine('${l['material_id']}', p6s(n(l['quantity'])), '${l['unit_id']}', l['unit_price'] != null ? p6s(n(l['unit_price'])) : ''),
  ];
  // the request's expense lines (LUKU top-up, tools…): what it is and about how much
  late final List<({Json l, TextEditingController amount})> _exp = [
    for (final l in _l(rq['lines']).where((l) => l['kind'] == 'expense').toList()..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no']))))
      (l: l, amount: TextEditingController(text: l['amount'] != null ? p6s(n(l['amount'])) : '')),
  ];
  String _expected = '';
  final _notes = TextEditingController();
  bool _sent = false, _busy = false;
  String _error = '';
  List<String> _suggested = [];
  // LUKU is bought from TANESCO only (083)
  bool get isLuku => _exp.any((x) => x.l['meter_id'] != null);
  Json? get tanesco => refs.suppliers.where((x) => RegExp('tanesco', caseSensitive: false).hasMatch('${x['name']}')).firstOrNull;
  late final active = refs.suppliers.where((x) => x['status'] == 'active').toList();

  @override
  void initState() {
    super.initState();
    if (!isLuku) _loadPast();
  }

  // who supplied these before: materials (purchases) and expense kinds (expenses) — offered first, preselected when one stands out
  Future<void> _loadPast() async {
    try {
      final byMat = await _pastByMaterial(widget.branchId);
      final e = await db.from('expenses').select('supplier_id, category_id, expense_date').eq('status', 'recorded').not('supplier_id', 'is', null).eq('branch_id', widget.branchId);
      final byCat = <String, List<({String s, String d})>>{};
      for (final x in _l(e)) { (byCat['${x['category_id']}'] ??= []).add((s: '${x['supplier_id']}', d: '${x['expense_date']}')); }
      final hs = [for (final l in _lines) ...?byMat[l.materialId], for (final x in _exp) ...?byCat['${x.l['category_id']}']];
      if (!mounted) return;
      setState(() {
        _suggested = _rank(hs);
        if (_supplierId.isEmpty && _suggested.isNotEmpty) _supplierId = _suggested.first;
      });
    } catch (_) {}
  }

  Future<void> _save() async {
    setState(() => _error = '');
    void fail(String m) => setState(() { _busy = false; _error = m; });
    if (!isLuku && (_supplierId.isEmpty || (_supplierId == '__new' && _newSupplier.text.trim().isEmpty))) return fail('Choose the supplier, or name a new one.');
    if (_lines.any((l) => l.materialId.isEmpty || !((_num(l.qty.text) ?? 0) > 0) || l.unitId.isEmpty)) return fail('Each material line needs a material, a quantity above zero and a unit.');
    if (_lines.isEmpty && _exp.isEmpty) return fail('Add what is ordered.');
    setState(() => _busy = true);
    try {
      if (widget.approve && rq['status'] == 'waiting') await db.rpc('decide_purchase_request', params: {'p_id': rq['id'], 'p_decision': 'approved', 'p_note': null});
      await db.rpc('create_purchase_order', params: {'p': {
        'branch_id': widget.branchId,
        ...(isLuku ? (tanesco != null ? {'supplier_id': tanesco!['id']} : {'new_supplier_name': 'TANESCO'}) : _supplierId == '__new' ? {'new_supplier_name': _newSupplier.text.trim()} : {'supplier_id': _supplierId}),
        'request_id': rq['id'], 'expected_on': _expected.isEmpty ? null : _expected, 'notes': _notes.text, 'sent_to_supplier': _sent,
        'lines': [
          for (final l in _lines) {'material_id': l.materialId, 'quantity': _q3(_num(l.qty.text)), 'unit_id': l.unitId, 'unit_price': _num(l.price.text)},
          for (final x in _exp)
            {'kind': 'expense', 'category_id': x.l['category_id'], 'meter_id': x.l['meter_id'], 'description': x.l['description'], 'quantity': x.l['quantity'] != null ? _q3(n(x.l['quantity']).toDouble()) : null,
              'unit_text': x.l['unit_text'], 'amount': _num(x.amount.text), 'request_line_id': x.l['id']},
        ],
      }});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      fail(dbError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final mats = _mats(refs, widget.branchId);
    return FullPage(
      title: 'Purchase order for request #${rq['request_no']}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(widget.approve ? 'Approve & make order' : 'Make order')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        if (isLuku) ...[
          const PlLabel('Supplier'),
          Text('${tanesco?['name'] ?? 'TANESCO'}', style: const TextStyle(fontWeight: FontWeight.w700)),
          const PlHelp('LUKU is bought from TANESCO only.'),
        ] else ...[
          DropdownButtonFormField<String>(
            key: ValueKey('os$_supplierId'),
            initialValue: _supplierId, isExpanded: true, decoration: const InputDecoration(labelText: 'Supplier'),
            items: [
              const DropdownMenuItem(value: '', child: Text('Choose…')),
              for (final id in _suggested)
                if (active.any((x) => x['id'] == id)) DropdownMenuItem(value: id, child: Text('${active.firstWhere((x) => x['id'] == id)['name']} · supplied these before', overflow: TextOverflow.ellipsis)),
              for (final x in active.where((x) => !_suggested.contains(x['id']))) DropdownMenuItem(value: '${x['id']}', child: Text('${x['name']}', overflow: TextOverflow.ellipsis)),
              const DropdownMenuItem(value: '__new', child: Text('New supplier…')),
            ],
            onChanged: (v) => setState(() => _supplierId = v ?? ''),
          ),
          if (_supplierId == '__new') ...[const SizedBox(height: 8), TextField(controller: _newSupplier, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: "The supplier's name"))],
        ],
        const SizedBox(height: 12),
        DateField(label: 'Expected (optional)', value: _expected.isEmpty ? session.today : _expected, onChange: (v) => setState(() => _expected = v)),
        if (_lines.isNotEmpty) const SectionTitle('Materials'),
        for (final (i, l) in _lines.indexed)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
            decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(8)),
            child: Column(children: [
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('om$i${l.materialId}'),
                    initialValue: l.materialId.isEmpty ? null : l.materialId, isExpanded: true, decoration: const InputDecoration(labelText: 'Material'),
                    items: [for (final m in mats) DropdownMenuItem(value: m.id, child: Text('${m.materialCategory != null ? '${m.materialCategory} · ' : ''}${m.name}', overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => setState(() { final m = refs.items['m:$v']; l.materialId = v ?? ''; l.unitId = m?.mainUnitId ?? m?.stockUnitId ?? ''; }),
                  ),
                ),
                if (_lines.length > 1) IconButton(tooltip: 'Remove line', onPressed: () => setState(() => _lines = [..._lines]..removeAt(i)), icon: const Icon(LucideIcons.trash2, size: 16)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextField(controller: l.qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Quantity'))),
                const SizedBox(width: 6),
                SizedBox(
                  width: 96,
                  child: DropdownButtonFormField<String>(
                    key: ValueKey('ou$i${l.materialId}${l.unitId}'),
                    initialValue: (refs.items['m:${l.materialId}']?.units.any((u) => u.id == l.unitId) ?? false) ? l.unitId : null,
                    decoration: const InputDecoration(labelText: 'Unit'),
                    items: [for (final u in refs.items['m:${l.materialId}']?.units ?? <UnitF>[]) DropdownMenuItem(value: u.id, child: Text(refs.unit(u.id)))],
                    onChanged: (v) => setState(() => l.unitId = v ?? ''),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(child: TextField(controller: l.price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Price a unit', hintText: 'optional'))),
              ]),
            ]),
          ),
        if (_exp.isNotEmpty) ...[
          const SectionTitle('Expenses'),
          for (final x in _exp)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(child: Text('${x.l['description'] ?? ''}${x.l['quantity'] != null ? ' · ${p6s(n(x.l['quantity']))} ${x.l['unit_text'] ?? ''}' : ''}', style: const TextStyle(fontWeight: FontWeight.w600))),
                SizedBox(width: 140, child: TextField(controller: x.amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount (TZS)'))),
              ]),
            ),
        ],
        const SizedBox(height: 8),
        TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes (optional — printed on the order)')),
        CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: _sent, onChanged: (v) => setState(() => _sent = v ?? false), title: const Text('Sent to the supplier')),
      ],
    );
  }
}
