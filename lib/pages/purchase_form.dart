import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import 'procurement_actions.dart';

/*
 * Record goods + purchase / Add purchase details / Purchase (change) — a port of web PurchaseModal
 * (pages/Purchases.jsx, 035/120/129/131–133). mode: new | complete (goods already received) | edit.
 * The person says whether the goods arrived now or are coming later; a material's last price, unit and
 * supplier fill the next purchase; an earlier date is a correction (approval for non-admins); a rounding
 * gap under 1% can be taken as paid in full; bought from an order, the order is closed or kept open.
 */
const _autofillAfter = 1;
const _methods = ['Cash', 'Mobile money', 'Bank transfer', 'Cheque'];
const _defaultVat = 18.0;
double _r2(num v) => (v * 100).roundToDouble() / 100;
double? _q3(double? v) => v == null ? null : (v * 1000).roundToDouble() / 1000;
double? _num(String v) => v.trim().isEmpty ? null : double.tryParse(v.trim().replaceAll(',', ''));
String _money(Object? v) => formatMoney(n(v), session.currency);
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];

typedef Past = ({String? date, String? supplierId, String? unitId, double qty, double price, String? method, bool opening});

/// What the form needs from the page: references, purchases (for the price history), the goods received
class PurchaseCtx {
  PurchaseCtx({required this.refs, required this.purchases, required this.txByMove});
  final Refs refs;
  final List<Json> purchases;
  final Map<String, List<Json>> txByMove;
}

/// Order lines bought from Orders (077/129): { orderId, supplierId, branchId, lines, left, paid, paidOn }
typedef FromOrder = ({String orderId, String? supplierId, String? branchId, List<Map<String, String>> lines, Map<String, double> left, double paid, String? paidOn});

Future<bool> openPurchaseForm(BuildContext context, PurchaseCtx ctx, {required String mode, Json? receipt, Json? purchase, String? materialId, FromOrder? fromOrder}) async =>
    await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _PurchaseForm(ctx: ctx, mode: mode, receipt: receipt, purchase: purchase, materialId: materialId, fromOrder: fromOrder))) == true;

class _Line {
  _Line({this.materialId = '', String quantity = '', this.unitId = '', String price = ''}) {
    qty.text = quantity;
    this.price.text = price;
  }
  String materialId, unitId;
  final qty = TextEditingController(), price = TextEditingController();
}

class _PurchaseForm extends StatefulWidget {
  const _PurchaseForm({required this.ctx, required this.mode, this.receipt, this.purchase, this.materialId, this.fromOrder});
  final PurchaseCtx ctx;
  final String mode;
  final Json? receipt, purchase;
  final String? materialId;
  final FromOrder? fromOrder;
  @override
  State<_PurchaseForm> createState() => _PurchaseFormState();
}

class _PurchaseFormState extends State<_PurchaseForm> {
  Refs get refs => widget.ctx.refs;
  String get mode => widget.mode;
  bool get isNew => mode == 'new';
  Json? get purchase => widget.purchase;
  Json? get receipt => widget.receipt;
  FromOrder? get fromOrder => widget.fromOrder;
  String get today => session.today;
  String get branchId => fromOrder?.branchId ?? session.branchId;

  List<Json> _materials = [];
  Map<String, double> _vatRates = {};
  List<Json> _openingCosts = [], _openOrders = [];
  Map<String, List<Past>> _history = {};
  bool _ready = false;

  late final String? movementId = '${receipt?['movement_id'] ?? purchase?['movement_id'] ?? ''}'.isEmpty ? null : '${receipt?['movement_id'] ?? purchase?['movement_id']}';
  late final List<Json> receiptLines = [for (final t in widget.ctx.txByMove['$movementId'] ?? <Json>[]) if (t['material_id'] != null) t];
  late final List<Store> stores = refs.warehouses
      .where((w) => w.status == 'active' && w.branchId == branchId && session.canAt('inventory.receive', w.branchId, w.id) && session.canAt('procurement.receive', w.branchId, w.id))
      .toList();
  late String _warehouseId = (stores.where((w) => w.type == 'raw_materials').firstOrNull ?? stores.firstOrNull)?.id ?? '';
  late List<_Line> _newLines = fromOrder?.lines.isNotEmpty == true
      ? [for (final l in fromOrder!.lines) _Line(materialId: l['materialId'] ?? '', quantity: l['quantity'] ?? '', unitId: l['unitId'] ?? '', price: l['price'] ?? '')]
      : [_Line()];
  final Map<String, TextEditingController> _prices = {};
  late String _supplierId = '${purchase?['supplier_id'] ?? receipt?['supplier_id'] ?? fromOrder?.supplierId ?? ''}';
  late String _orderId = '${purchase?['purchase_order_id'] ?? fromOrder?.orderId ?? ''}';
  final _newSupplier = TextEditingController();
  late final _invoice = TextEditingController(text: '${purchase?['invoice_reference'] ?? receipt?['reference'] ?? ''}');
  late final _transport = TextEditingController(text: n(purchase?['transport_charge']) != 0 ? p6s(n(purchase!['transport_charge'])) : '');
  late bool _vatShown = purchase?['vat_amount'] != null;
  late final _paid = TextEditingController(text: purchase != null ? p6s(n(purchase!['amount_paid'])) : (fromOrder?.paid ?? 0) > 0 ? p6s(fromOrder!.paid) : '');
  late String _method = '${purchase?['payment_method'] ?? ''}';
  late String _paidOn = '${purchase?['paid_on'] ?? fromOrder?.paidOn ?? receipt?['movement_date'] ?? today}';
  late bool _paidOnSet = purchase?['paid_on'] != null || fromOrder?.paidOn != null;
  late final _notes = TextEditingController(text: '${purchase?['notes'] ?? ''}');
  late String _date = today;
  String _arrival = '';   // '' | now | later — the person says which
  bool _settle = false;
  String _orderAfter = '';   // open | close (132)
  late bool? _weekly = (fromOrder?.paid ?? 0) > 0 ? false : null;
  bool _submitted = false, _voiding = false, _busy = false;
  final _voidReason = TextEditingController();
  String _error = '';

  bool get later => isNew && _arrival == 'later';
  bool get itemMode => mode == 'edit' && _l(purchase?['items']).isNotEmpty;
  Store? get wh => refs.store(_warehouseId);
  String get recBranch => '${receipt?['branch_id'] ?? branchId}';
  double get vatRate => _vatRates[isNew ? (wh?.branchId ?? branchId) : '${receipt?['branch_id'] ?? purchase?['branch_id'] ?? branchId}'] ?? _defaultVat;
  bool get canBackdate => wh != null && (session.canAt('inventory.adjust', wh!.branchId, wh!.id) || _arrival == 'later');
  bool get backdated => isNew && _date.compareTo(today) < 0 && _arrival != 'later';
  bool get needsApproval => backdated && !session.canManage('inventory.adjust');
  List<Past> pastOf(String b, String m) => _history['$b|$m'] ?? [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait<dynamic>([
        db.from('materials').select('id, name, status, branch_id, category:material_categories(display_order)').order('name', ascending: true),
        db.from('branches').select('id, vat_rate'),
        db.from('inventory_transactions').select('material_id, entered_unit_id, entered_quantity, unit_cost, transaction_date, warehouse:warehouses(branch_id)')
            .eq('transaction_type', 'opening_balance').not('material_id', 'is', null).not('unit_cost', 'is', null),
      ]);
      _materials = _l(r[0])..sort((a, b) {
          final c = n(a['category']?['display_order'] ?? 999).compareTo(n(b['category']?['display_order'] ?? 999));
          return c != 0 ? c : '${a['name']}'.compareTo('${b['name']}');
        });
      _vatRates = {for (final b in r[1] as List) if (b['vat_rate'] != null) '${b['id']}': n(b['vat_rate']).toDouble()};
      _openingCosts = _l(r[2]);
    } catch (_) {}
    _buildHistory();
    // prices as saved, or (adding details) filled from the latest purchase in the same unit
    final priceOf = {
      for (final l in _l(purchase?['lines'])) '${l['transaction_id']}': '${l['unit_price']}',
      for (final i in _l(purchase?['items'])) '${i['id']}': '${i['unit_price']}',
    };
    for (final t in receiptLines) {
      final p = pastOf(recBranch, '${t['material_id']}');
      final filled = mode == 'complete' && p.length >= _autofillAfter && p.first.unitId == '${t['entered_unit_id']}' ? p6s(p.first.price) : '';
      _prices['${t['id']}'] = TextEditingController(text: priceOf['${t['id']}'] != null ? p6s(n(double.tryParse(priceOf['${t['id']}']!))) : filled);
    }
    for (final i in _l(purchase?['items'])) {
      _prices['${i['id']}'] = TextEditingController(text: priceOf['${i['id']}'] != null ? p6s(n(double.tryParse(priceOf['${i['id']}']!))) : '');
    }
    if (mode == 'complete' && _supplierId.isEmpty) {
      final firstPast = receiptLines.map((t) => pastOf(recBranch, '${t['material_id']}')).where((p) => p.length >= _autofillAfter).firstOrNull;
      if (firstPast != null) {
        _supplierId = firstPast.first.supplierId ?? '';
        if (_method.isEmpty) _method = firstPast.first.method ?? '';
      }
    }
    if (mounted) setState(() => _ready = true);
    _loadOrders();
    // opened from a material's Intake: that material is on the first line
    if (isNew && widget.materialId != null) _pickMaterial(0, widget.materialId!);
  }

  /// Each material's recorded purchases per branch, newest first; a never-bought one from its opening cost
  void _buildHistory() {
    final h = <String, List<Past>>{};
    for (final p in widget.ctx.purchases) {
      if (p['status'] != 'recorded') continue;
      for (final l in _l(p['lines'])) {
        final t = (widget.ctx.txByMove['${p['movement_id']}'] ?? []).where((x) => x['id'] == l['transaction_id']).firstOrNull;
        if (t?['material_id'] == null) continue;
        (h['${p['branch_id']}|${t!['material_id']}'] ??= []).add((date: '${p['purchase_date']}', supplierId: p['supplier_id'], unitId: t['entered_unit_id'],
            qty: n(t['entered_quantity']).toDouble(), price: n(l['unit_price']).toDouble(), method: p['payment_method'], opening: false));
      }
      for (final i in _l(p['items'])) {
        (h['${p['branch_id']}|${i['material_id']}'] ??= []).add((date: '${p['purchase_date']}', supplierId: p['supplier_id'], unitId: i['unit_id'],
            qty: n(i['quantity']).toDouble(), price: n(i['unit_price']).toDouble(), method: p['payment_method'], opening: false));
      }
    }
    for (final v in h.values) { v.sort((a, b) => '${b.date}'.compareTo('${a.date}')); }
    for (final o in _openingCosts) {
      final k = '${o['warehouse']?['branch_id']}|${o['material_id']}';
      if (h[k]?.any((x) => !x.opening) ?? false) continue;   // a real purchase always wins
      (h[k] ??= []).add((date: '${o['transaction_date']}', supplierId: null, unitId: o['entered_unit_id'], qty: n(o['entered_quantity']).toDouble(), price: n(o['unit_cost']).toDouble(), method: null, opening: true));
    }
    _history = h;
  }

  Future<void> _loadOrders() async {
    if (_supplierId.isEmpty) { setState(() => _openOrders = []); return; }
    try {
      final d = await db.from('purchase_orders').select('id, po_no, order_date, branch_id, status').eq('supplier_id', _supplierId).eq('status', 'open').order('order_date', ascending: false);
      if (mounted) setState(() => _openOrders = _l(d));
    } catch (_) {}
  }

  void _pickMaterial(int i, String materialId) {
    final l = _newLines[i];
    l.materialId = materialId;
    final item = refs.items['m:$materialId'];
    final past = pastOf(wh?.branchId ?? branchId, materialId);
    if (past.length >= _autofillAfter && (item?.units.any((u) => u.id == past.first.unitId) ?? false)) {
      l.unitId = past.first.unitId!;
      l.price.text = p6s(past.first.price);
    } else {
      l.unitId = item?.mainUnitId ?? item?.stockUnitId ?? '';   // its main unit (051)
    }
    if (past.length >= _autofillAfter) {
      if (_supplierId.isEmpty && _newSupplier.text.trim().isEmpty && past.first.supplierId != null) { _supplierId = past.first.supplierId!; _loadOrders(); }
      if (_method.isEmpty && past.first.method != null) _method = past.first.method!;
    }
    setState(() {});
  }

  /// lines with the amount as bought and the quantity in the stock unit (for the per-unit cost)
  List<({String key, String? materialId, String? itemId, String? txId, String? name, double? qty, String unitId, double? stockQty, String? stockUnitId, double? price})> get lines {
    if (isNew) {
      return [
        for (final (i, l) in _newLines.indexed)
          () {
            final item = refs.items['m:${l.materialId}'];
            final factor = item?.units.where((u) => u.id == l.unitId).firstOrNull?.factor;
            final q = _q3(_num(l.qty.text));
            return (key: '$i', materialId: l.materialId, itemId: null, txId: null, name: item?.name, qty: q, unitId: l.unitId,
                stockQty: q != null && factor != null ? q * factor : null, stockUnitId: item?.stockUnitId, price: _num(l.price.text));
          }(),
      ];
    }
    if (itemMode) {
      final items = _l(purchase!['items'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no'])));
      return [
        for (final i in items)
          () {
            final item = refs.items['m:${i['material_id']}'];
            final factor = item?.units.where((u) => u.id == i['unit_id']).firstOrNull?.factor;
            return (key: '${i['id']}', materialId: '${i['material_id']}', itemId: '${i['id']}', txId: null, name: item?.name, qty: n(i['quantity']).toDouble(), unitId: '${i['unit_id']}',
                stockQty: factor != null ? n(i['quantity']) * factor : null, stockUnitId: item?.stockUnitId, price: _num(_prices['${i['id']}']?.text ?? ''));
          }(),
      ];
    }
    return [
      for (final t in receiptLines)
        (key: '${t['id']}', materialId: '${t['material_id']}', itemId: null, txId: '${t['id']}', name: refs.items['m:${t['material_id']}']?.name, qty: n(t['entered_quantity']).toDouble(),
            unitId: '${t['entered_unit_id']}', stockQty: n(t['quantity']).toDouble(), stockUnitId: '${t['stock_unit_id']}', price: _num(_prices['${t['id']}']?.text ?? '')),
    ];
  }

  Future<void> _save() async {
    setState(() => _error = '');
    void fail(String m) => setState(() { _busy = false; _error = m; });
    final ls = lines;
    double? amount(l) => l.price != null && l.qty != null ? (l.price! * l.qty!).roundToDouble() : null;   // whole shillings
    final subtotal = ls.fold<double>(0, (s, l) => s + (amount(l) ?? 0));
    final vat = _vatShown ? _r2(subtotal * vatRate / (100 + vatRate)) : 0.0;
    final total = subtotal + (_num(_transport.text) ?? 0);
    final paid = _num(_paid.text);
    final gap = (paid ?? 0) > 0 ? total.roundToDouble() - paid! : 0.0;
    final partOfOrder = _partOfOrder;
    if (_supplierId.isEmpty && _newSupplier.text.trim().isEmpty) return fail('Choose the supplier, or name a new one.');
    if (ls.any((l) => l.price == null || !(l.price! >= 0))) return fail('Enter the price of each material (zero or more).');
    if (isNew) {
      if (_arrival.isEmpty) return fail('Say whether the goods arrived now or are coming later.');
      if (_warehouseId.isEmpty) return fail('Choose the store.');
      if (_newLines.any((l) => l.materialId.isEmpty || !((_num(l.qty.text) ?? 0) > 0) || l.unitId.isEmpty)) return fail('Each line needs a material, a quantity above zero and a unit.');
      if (_newLines.map((l) => l.materialId).toSet().length != _newLines.length) return fail('A material appears twice — combine the lines.');
    }
    if (paid != null && paid > _r2(total)) return fail('Amount paid is more than the total.');
    if (mode != 'edit' && (paid ?? 0) > 0 && _weekly == null) return fail('Say where the money came from: the weekly cash, or the directors · bank.');
    if (isNew && _date.compareTo(today) > 0) return fail('Choose a date up to today.');
    if (partOfOrder && _orderAfter.isEmpty) return fail('Say whether the order stays open for the rest, or is closed.');
    final header = {
      if (_supplierId.isNotEmpty) 'supplier_id': _supplierId else 'new_supplier_name': _newSupplier.text.trim(),
      'invoice_reference': _invoice.text.trim().isEmpty ? null : _invoice.text.trim(), 'transport_charge': _num(_transport.text) ?? 0,
      'vat_amount': _vatShown ? vat : null, 'prices_include_vat': _vatShown,
      'amount_paid': paid ?? 0, 'payment_method': _method.trim().isEmpty ? null : _method.trim(), 'paid_on': (paid ?? 0) > 0 ? _paidOn : null,
      'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
    };
    setState(() => _busy = true);
    try {
      Object? res;
      if (mode == 'edit') {
        res = await db.rpc('update_purchase', params: {'p_id': purchase!['id'], 'p': {
          ...header,
          if (itemMode) 'items': [for (final l in ls) {'id': l.itemId, 'unit_price': l.price}] else 'lines': [for (final l in ls) {'transaction_id': l.txId, 'unit_price': l.price}],
        }});
      } else if (later) {
        // coming later (120): the purchase and its payment now; the goods are recorded as they arrive
        res = await db.rpc('record_purchase', params: {'p': {
          ...header, 'coming_later': true, 'warehouse_id': _warehouseId, 'purchase_date': _date,
          'items': [for (final l in _newLines) {'material_id': l.materialId, 'quantity': _q3(_num(l.qty.text)), 'unit_id': l.unitId, 'unit_price': _num(l.price.text)}],
        }});
      } else if (mode == 'complete') {
        res = await db.rpc('record_purchase', params: {'p': {...header, 'movement_id': movementId, 'lines': [for (final l in ls) {'transaction_id': l.txId, 'unit_price': l.price}]}});
      } else {
        final payload = {
          ...header,
          'receipt': {'type': 'receipt', 'warehouse_id': _warehouseId, 'movement_date': _date, 'reference': _invoice.text.trim().isEmpty ? null : _invoice.text.trim(),
              'lines': [for (final l in _newLines) {'material_id': l.materialId, 'quantity': _q3(_num(l.qty.text)), 'unit_id': l.unitId}]},
          'lines': [for (final l in _newLines) {'material_id': l.materialId, 'unit_price': _num(l.price.text)}],
        };
        if (needsApproval) {
          final supplierLabel = _supplierId.isNotEmpty ? '${refs.suppliers.where((s) => s['id'] == _supplierId).firstOrNull?['name'] ?? ''}' : _newSupplier.text.trim();
          final goods = ls.map((l) => '${qtyText(l.qty)} ${refs.unit(l.unitId)} ${l.name ?? ''}').join(', ');
          try {
            await db.rpc('request_change', params: {'p_kind': 'purchase', 'p_branch_id': null, 'p_payload': payload,
              'p_summary': 'Purchase dated ${dateText(_date)} at ${warehouseLabel(wh)}: $goods from $supplierLabel — ${_money(_r2(total))}'});
          } catch (e) {
            return fail(dbError(e, "We couldn't send this for approval. Nothing was recorded."));
          }
          return setState(() { _busy = false; _submitted = true; });
        }
        res = await db.rpc('record_purchase', params: {'p': payload});
      }
      final pid = mode == 'edit' ? purchase!['id'] : res;
      if (pid != null && (_orderId.isNotEmpty || purchase?['purchase_order_id'] != null) && _orderId != '${purchase?['purchase_order_id'] ?? ''}') {
        await db.rpc('set_purchase_order', params: {'p_purchase': pid, 'p_order': _orderId.isEmpty ? null : _orderId});
      }
      if (mode != 'edit' && (paid ?? 0) > 0 && res != null) await saveWeeklyCash('purchase', res, _weekly);
      if (_settle && gap > 0 && pid != null) await db.rpc('settle_purchase', params: {'p_id': pid});
      // from an order (132): closed when everything is bought, or when the person says the rest is not needed
      if (isNew && fromOrder != null && _orderId == fromOrder!.orderId && (!partOfOrder || _orderAfter == 'close')) {
        final o = await db.from('purchase_orders').select('status').eq('id', _orderId).maybeSingle();
        if (o?['status'] == 'open') {
          await db.rpc('close_purchase_order', params: {'p_id': _orderId, 'p_cancel': false, 'p_reason': partOfOrder ? 'Closed: the rest is not needed' : 'Bought in full'});
        }
      }
    } catch (e) {
      return fail(dbError(e, "We couldn't save the purchase. Nothing was recorded."));
    }
    if (mounted) Navigator.pop(context, true);
  }

  bool get _partOfOrder => isNew && fromOrder != null && fromOrder!.left.isNotEmpty && _orderId == fromOrder!.orderId &&
      fromOrder!.left.entries.any((e) => _newLines.where((l) => l.materialId == e.key).fold<double>(0, (t, l) => t + (_num(l.qty.text) ?? 0)) < e.value - 1e-9);

  Future<void> _voidIt() async {
    setState(() => _error = '');
    if (_voidReason.text.trim().isEmpty) return setState(() => _error = 'Give a reason.');
    setState(() => _busy = true);
    try {
      await db.rpc('void_purchase', params: {'p_id': purchase!['id'], 'p_reason': _voidReason.text.trim()});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e); });
    }
  }

  /// "Filled from the last 2 purchases: …" under a line
  Widget? _pastHint(String b, String? materialId) {
    if (materialId == null || materialId.isEmpty) return null;
    final past = pastOf(b, materialId);
    if (past.length < _autofillAfter) return null;
    final a = past.first;
    final z = past.length > 1 ? past[1] : null;
    String name(String? id) => '${refs.suppliers.where((s) => s['id'] == id).firstOrNull?['name'] ?? '—'}';
    String one(Past p) => '${dateText(p.date)} · ${name(p.supplierId)} · ${qtyText(p.qty)} ${refs.unit(p.unitId)} at ${_money(p.price)}';
    if (a.opening) return PlHelp('From opening stock cost: ${_money(a.price)} per ${refs.unit(a.unitId).isEmpty ? 'unit' : refs.unit(a.unitId)} (${dateText(a.date)}).');
    return PlHelp('Filled from the last ${z != null ? '2 purchases' : 'purchase'}: ${[a, ?z].map(one).join('; ')}.'
        '${z != null && a.price != z.price && a.unitId == z.unitId ? ' The price changed from ${_money(z.price)} to ${_money(a.price)}.' : ''} Change anything that is different this time.');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    if (_submitted) {
      return FullPage(
        title: 'Record goods + purchase',
        footer: [FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done'))],
        children: [Text("Sent for an admin's approval. The goods and the purchase are recorded, dated ${dateText(_date)}, once it is approved — follow it under Approvals.")],
      );
    }
    if (!_ready) return const FullPage(title: 'Purchase', children: [Skeleton(rows: 6)]);
    final ls = lines;
    double? amount(l) => l.price != null && l.qty != null ? (l.price! * l.qty!).roundToDouble() : null;
    final subtotal = ls.fold<double>(0, (s, l) => s + (amount(l) ?? 0));
    final vat = _vatShown ? _r2(subtotal * vatRate / (100 + vatRate)) : 0.0;
    final transport = _num(_transport.text) ?? 0;
    final total = subtotal + transport;
    final vatFactor = _vatShown && subtotal > 0 ? (subtotal - vat) / subtotal : 1.0;
    final paid = _num(_paid.text);
    final gap = (paid ?? 0) > 0 ? total.roundToDouble() - paid! : 0.0;
    final smallGap = gap > 0 && gap <= total.roundToDouble() * 0.01;
    double? landed(l) => amount(l) != null && (l.stockQty ?? 0) > 0 && subtotal > 0 ? (amount(l)! * vatFactor + transport * amount(l)! / subtotal) / l.stockQty! : null;
    final activeSuppliers = refs.suppliers.where((s) => s['status'] == 'active' || s['id'] == purchase?['supplier_id']).toList();
    final lineMaterials = [for (final l in ls) if ((l.materialId ?? '').isNotEmpty) l.materialId!];
    final suppliedBefore = {for (final m in lineMaterials) for (final p in pastOf(recBranch, m)) if (p.supplierId != null) p.supplierId!};
    final usable = _materials.where((m) => m['status'] == 'active' && (m['branch_id'] == null || m['branch_id'] == (wh?.branchId ?? branchId))).toList();
    Widget gap12() => const SizedBox(height: 12);

    return FullPage(
      title: mode == 'edit' ? 'Purchase' : mode == 'complete' ? 'Add purchase details' : 'Record goods + purchase',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(mode == 'edit' ? 'Save changes' : needsApproval ? 'Submit for approval' : 'Record purchase')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        if (isNew) ...[
          // the person says it — nothing is assumed (2026-11-13, the user)
          Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            const Text('The goods', style: TextStyle(fontWeight: FontWeight.w600)),
            Chip2('Arrived now', on: _arrival == 'now', onTap: () => setState(() => _arrival = 'now')),
            Chip2('Coming later', on: _arrival == 'later', onTap: () => setState(() => _arrival = 'later')),
          ]),
          gap12(),
          DropdownButtonFormField<String>(
            initialValue: _warehouseId.isEmpty ? null : _warehouseId, isExpanded: true,
            decoration: InputDecoration(labelText: later ? 'Store the goods will come to' : 'Store receiving the goods'),
            items: [for (final w in stores) DropdownMenuItem(value: w.id, child: Text(warehouseLabel(w), overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _warehouseId = v ?? ''),
          ),
          gap12(),
          DateField(label: later ? 'Date of the purchase' : 'Date received', value: _date, last: today, enabled: canBackdate,
              onChange: (v) => setState(() { _date = v; if (!_paidOnSet) _paidOn = v; })),
          PlHelp(later
              ? 'Nothing goes into stock now — record each delivery when it comes.'
              : !canBackdate
                  ? 'Today only — earlier dates need stock-adjustment permission (ask the branch manager).'
                  : needsApproval
                      ? 'Earlier date: this goes to an admin for approval and is recorded once approved.'
                      : _date.compareTo(today) < 0 ? 'Earlier date: recorded as of then.' : 'Today, or an earlier date if the goods came before.'),
          const SectionTitle('Goods'),
          for (final (i, l) in _newLines.indexed) _goodsLine(i, l, usable),
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => setState(() => _newLines = [..._newLines, _Line()]), icon: const Icon(LucideIcons.plus, size: 14), label: const Text('Add material'))),
        ] else ...[
          SectionTitle(itemMode ? 'Goods bought ${dateText(purchase!['purchase_date'])}' : 'Goods received ${dateText(receipt?['movement_date']) ?? dateText(purchase?['purchase_date']) ?? ''}'),
          for (final l in ls)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text('${qtyText(l.qty)} ${refs.unit(l.unitId)} ${l.name ?? ''}', style: const TextStyle(fontWeight: FontWeight.w600))),
                  SizedBox(
                    width: 150,
                    child: TextField(controller: _prices[l.txId ?? l.itemId], onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(labelText: 'Price per ${refs.unit(l.unitId).isEmpty ? 'unit' : refs.unit(l.unitId)}')),
                  ),
                ]),
                if (mode == 'complete') ?_pastHint(recBranch, l.materialId),
              ]),
            ),
        ],
        gap12(),
        DropdownButtonFormField<String>(
          key: ValueKey('sup$_supplierId'),
          initialValue: _supplierId, isExpanded: true,
          decoration: const InputDecoration(labelText: 'Supplier'),
          items: [
            DropdownMenuItem(value: '', child: Text(mode == 'edit' ? 'Choose…' : 'New supplier…')),
            // who supplied these materials before — offered first, never assumed for other materials
            for (final s in activeSuppliers.where((s) => suppliedBefore.contains(s['id']))) DropdownMenuItem(value: '${s['id']}', child: Text('${s['name']} · supplied these before', overflow: TextOverflow.ellipsis)),
            for (final s in activeSuppliers.where((s) => !suppliedBefore.contains(s['id']))) DropdownMenuItem(value: '${s['id']}', child: Text('${s['name']}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) { setState(() => _supplierId = v ?? ''); _loadOrders(); },
        ),
        if (_supplierId.isEmpty && mode != 'edit') ...[const SizedBox(height: 8), TextField(controller: _newSupplier, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: "Supplier's name"))],
        if (_supplierId.isNotEmpty && (_openOrders.isNotEmpty || _orderId.isNotEmpty)) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _openOrders.any((o) => o['id'] == _orderId) || _orderId.isEmpty ? _orderId : '', isExpanded: true,
            decoration: const InputDecoration(labelText: 'Against purchase order'),
            items: [const DropdownMenuItem(value: '', child: Text('No purchase order')), for (final o in _openOrders) DropdownMenuItem(value: '${o['id']}', child: Text('Against PO #${o['po_no']} · ${dateText(o['order_date'])}'))],
            onChanged: (v) => setState(() => _orderId = v ?? ''),
          ),
        ],
        if (_partOfOrder) ...[
          gap12(),
          const PlLabel('Part of the order — the rest:'),
          const SizedBox(height: 6),
          Wrap(spacing: 6, children: [
            Chip2('Keep the order open', on: _orderAfter == 'open', onTap: () => setState(() => _orderAfter = 'open')),
            Chip2('Close the order', on: _orderAfter == 'close', onTap: () => setState(() => _orderAfter = 'close')),
          ]),
        ],
        gap12(),
        TextField(controller: _invoice, decoration: const InputDecoration(labelText: "Supplier's invoice / receipt no.", hintText: 'Optional')),
        gap12(),
        TextField(controller: _transport, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Transport / other charges', hintText: '0')),
        const PlHelp("Added to the materials' cost."),
        // a branch that is not VAT-registered (rate 0) has no VAT to tick
        if (vatRate > 0 || _vatShown)
          CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: _vatShown, onChanged: (v) => setState(() => _vatShown = v ?? false),
              title: Text('VAT (${p6s(vatRate)}%) is included in the prices')),
        if (_vatShown) ...[
          Text('VAT: ${_money(vat)} = ${_money(_r2(subtotal))} × ${p6s(vatRate)}/${p6s(100 + vatRate)}', style: const TextStyle(fontSize: Fs.sm)),
          const PlHelp('From the goods amount; not in material cost.'),
        ],
        gap12(),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: t.soft, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Goods: ${_money(_r2(subtotal))}${transport != 0 ? ' · transport ${_money(transport)}' : ''}${_vatShown && vat != 0 ? ' · VAT ${_money(vat)} (included)' : ''}', style: const TextStyle(fontSize: Fs.sm)),
            Text.rich(TextSpan(children: [const TextSpan(text: 'Total to pay: '), TextSpan(text: _money(_r2(total)), style: const TextStyle(fontWeight: FontWeight.w700))])),
            if (ls.any((l) => landed(l) != null))
              PlHelp('Cost: ${ls.where((l) => landed(l) != null).map((l) => '${l.name} ${_money(_r2(landed(l)!))} per ${refs.unit(l.stockUnitId).isEmpty ? 'unit' : refs.unit(l.stockUnitId)}').join(' · ')}'),
          ]),
        ),
        const SectionTitle('Payment'),
        Row(children: [
          Expanded(child: TextField(controller: _paid, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount paid', hintText: '0 = not paid yet'))),
          TextButton(onPressed: () => setState(() => _paid.text = '${total.round()}'), child: const Text('Paid in full')),
        ]),
        if (gap > 0 && smallGap)
          CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: _settle, onChanged: (v) => setState(() => _settle = v ?? false),
              title: Text('Take as paid in full — ${_money(gap)} left from rounding')),
        gap12(),
        DropdownButtonFormField<String>(
          initialValue: _method, isExpanded: true, decoration: const InputDecoration(labelText: 'How'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Choose…')),
            for (final m in [if (_method.isNotEmpty && !_methods.contains(_method)) _method, ..._methods]) DropdownMenuItem(value: m, child: Text(m)),
          ],
          onChanged: (v) => setState(() => _method = v ?? ''),
        ),
        if ((paid ?? 0) > 0) ...[gap12(), DateField(label: 'Paid on', value: _paidOn, last: today, onChange: (v) => setState(() { _paidOn = v; _paidOnSet = true; }))],
        if (mode != 'edit' && (paid ?? 0) > 0) ...[gap12(), PaidFrom(value: _weekly, onChange: (v) => setState(() => _weekly = v))],
        gap12(),
        TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes')),
        if (mode == 'edit') ...[
          const SectionTitle('Entered wrongly?'),
          if (_voiding) ...[
            const PlHelp('Back to "Waiting for details". Goods stay in stock.'),
            const SizedBox(height: 6),
            TextField(controller: _voidReason, decoration: const InputDecoration(hintText: 'Reason')),
            Row(children: [
              OutlinedButton(onPressed: _busy ? null : _voidIt, child: const Text('Void purchase')),
              TextButton(onPressed: () => setState(() => _voiding = false), child: const Text('Keep it')),
            ]),
          ] else
            Wrap(spacing: 6, children: [
              TextButton(onPressed: () => setState(() => _voiding = true), child: const Text('Void this purchase…')),
              if (session.canManage('system.manage'))
                TextButton(
                  style: TextButton.styleFrom(foregroundColor: C.error),
                  onPressed: () async {
                    final goods = receiptLines.map((x) => '${qtyText(n(x['entered_quantity']))} ${refs.unit('${x['entered_unit_id']}')} ${refs.items['m:${x['material_id']}']?.name ?? ''}').join(', ');
                    if (await deletePurchase(context, purchase: purchase!, goods: goods) && context.mounted) Navigator.pop(context, true);
                  },
                  child: const Text('Delete this purchase…'),
                ),
            ]),
        ],
      ],
    );
  }

  Widget _goodsLine(int i, _Line l, List<Json> usable) {
    final t = context.tk;
    final item = refs.items['m:${l.materialId}'];
    final q = _num(l.qty.text), p = _num(l.price.text);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 10, 4, 8),
      decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey('m$i${l.materialId}'),
              initialValue: l.materialId.isEmpty ? null : l.materialId, isExpanded: true,
              decoration: const InputDecoration(labelText: 'Material'),
              items: [for (final m in usable) DropdownMenuItem(value: '${m['id']}', child: Text('${m['name']}', overflow: TextOverflow.ellipsis))],
              onChanged: (v) => _pickMaterial(i, v ?? ''),
            ),
          ),
          IconButton(tooltip: 'Remove line', onPressed: _newLines.length == 1 ? null : () => setState(() => _newLines = [..._newLines]..removeAt(i)), icon: const Icon(LucideIcons.trash2, size: 16)),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: l.qty, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Qty'))),
          const SizedBox(width: 6),
          SizedBox(
            width: 96,
            child: DropdownButtonFormField<String>(
              key: ValueKey('u$i${l.materialId}${l.unitId}'),
              initialValue: (item?.units.any((u) => u.id == l.unitId) ?? false) ? l.unitId : null,
              decoration: const InputDecoration(labelText: 'Unit'),
              items: [for (final u in item?.units ?? <UnitF>[]) DropdownMenuItem(value: u.id, child: Text(refs.unit(u.id)))],
              onChanged: (v) => setState(() => l.unitId = v ?? ''),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(child: TextField(controller: l.price, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Price / unit'))),
        ]),
        // the line's total, right by its qty and price (2026-11-16, the user)
        if (q != null && p != null) Align(alignment: Alignment.centerRight, child: Padding(padding: const EdgeInsets.only(top: 4, right: 8), child: Text('= ${formatAmount((_q3(q)! * p).roundToDouble())}', style: const TextStyle(fontWeight: FontWeight.w600)))),
        ?_pastHint(wh?.branchId ?? branchId, l.materialId),
      ]),
    );
  }
}
