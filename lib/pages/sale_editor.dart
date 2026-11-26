import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/production.dart' show pickProduct;
import '../core/sales.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import 'payment_proofs.dart' show proofWindow;
import 'procurement_actions.dart' show DateField;
import 'sales.dart' show WalkIn;

/*
 * Record a sale / a quotation / a note — a port of web pages/Sales.jsx SaleEditor (064–141). Buyer (walk-in or
 * customer; a walk-in's third purchase makes them a customer, 069), the store it is sold from (135), lines priced
 * from the price list (as paid, per m² or piece; a manager's price change needs a reason; the VAT box unticks
 * itself off the list price, 110), what is available, other items (104); in Record sale the money too — one
 * payment or one per item (070), its account (required), its proof (105), the EFD. Record sale builds the day's
 * list (111): sales added one by one, kept on this phone until Save all (checked first), one slip for several.
 * Online only; the database works out the real figures.
 */
class _Line {
  _Line({this.other = false, this.productId = '', this.colorId = '', String quantity = '', String price = '', String reason = '', String name = '', this.vat})
      : quantity = TextEditingController(text: quantity), price = TextEditingController(text: price), reason = TextEditingController(text: reason), name = TextEditingController(text: name);
  final bool other;
  String productId, colorId;
  final TextEditingController quantity, price, reason, name;
  bool? vat;
  Json toJson() => {'other': other, 'productId': productId, 'colorId': colorId, 'quantity': quantity.text, 'price': price.text, 'reason': reason.text, 'name': name.text, 'vat': vat};
  static _Line from(Json j) => _Line(other: j['other'] == true, productId: '${j['productId'] ?? ''}', colorId: '${j['colorId'] ?? ''}', quantity: '${j['quantity'] ?? ''}',
      price: '${j['price'] ?? ''}', reason: '${j['reason'] ?? ''}', name: '${j['name'] ?? ''}', vat: j['vat'] as bool?);
}

class _Pay {
  _Pay({this.accountId = '', String amount = '', this.receiptNo = '', this.auto = false}) : amount = TextEditingController(text: amount);
  String accountId, receiptNo;
  final TextEditingController amount;
  bool auto; // follows the total until typed
  Json toJson() => {'accountId': accountId, 'amount': amount.text, 'receiptNo': receiptNo, 'auto': auto};
  static _Pay from(Json j) => _Pay(accountId: '${j['accountId'] ?? ''}', amount: '${j['amount'] ?? ''}', receiptNo: '${j['receiptNo'] ?? ''}', auto: j['auto'] == true);
}

typedef _Preview = ({double? listInc, double? inc, double? total, double ex, double rate, bool off, bool vatOn, double discount});

class SaleEditor extends StatefulWidget {
  const SaleEditor({super.key, this.sale, this.prefill, this.note = false, this.book = false, this.sold = const {}, this.walkIns = const [], this.accounts = const [],
      required this.branchId, required this.refs, required this.customers, this.canDiscount = false, this.canOther = false});
  final Json? sale, prefill;
  final bool note, book, canDiscount, canOther;
  final Map<String, int> sold;
  final List<WalkIn> walkIns;
  final List<Json> accounts, customers;
  final String branchId;
  final Refs refs;
  @override
  State<SaleEditor> createState() => _SaleEditorState();
}

class _SaleEditorState extends State<SaleEditor> {
  Json? get sale => widget.sale;
  Json? get prefill => widget.prefill;
  Refs get refs => widget.refs;
  String get branchId => widget.branchId;
  String get today => session.today;
  String money(num v) => formatMoney(v, session.currency);

  late String _buyer = sale?['customer_id'] != null || prefill?['customer_id'] != null ? 'customer' : 'walkin';
  late String _customerId = '${sale?['customer_id'] ?? prefill?['customer_id'] ?? ''}';
  late final _walkName = TextEditingController(text: '${sale?['walk_in_name'] ?? prefill?['walk_in_name'] ?? ''}');
  late final _walkPhone = TextEditingController(text: '${sale?['walk_in_phone'] ?? prefill?['walk_in_phone'] ?? ''}');
  Map<String, TextEditingController>? _newCust; // name, phone, tin while adding one
  Map<String, TextEditingController>? _promote; // a walk-in buyer's third purchase (069)
  late String _date = '${sale?['sale_date'] ?? prefill?['sale_date'] ?? today}';
  late String _validUntil = '${sale?['valid_until'] ?? ''}';
  late final _notes = TextEditingController(text: '${sale?['notes'] ?? prefill?['notes'] ?? ''}');
  late final _site = TextEditingController(text: '${sale?['site'] ?? prefill?['site'] ?? ''}');
  late final _efd = TextEditingController(text: '${prefill?['efd_receipt_no'] ?? ''}');
  late List<_Pay> _pays = (prefill?['payments'] as List?)?.isNotEmpty == true
      ? [for (final x in jl(prefill!['payments'])) _Pay(accountId: '${x['accountId'] ?? ''}', amount: '${x['amount'] ?? ''}', receiptNo: '${x['receiptNo'] ?? ''}')]
      : [_Pay(auto: true)];
  String _payMode = 'order'; // order | items (070)
  Map<int, _Pay> _itemPays = {};
  late List<_Line> _lines = sale == null && prefill?['lines'] != null
      ? [for (final l in jl(prefill!['lines'])) _Line(productId: '${l['productId']}', colorId: '${l['colorId'] ?? ''}', quantity: '${l['quantity'] ?? ''}', price: '${l['price'] ?? ''}')]
      : [
          for (final l in jl(sale?['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no']))))
            l['product_id'] == null
                ? _Line(other: true, name: '${l['item_name'] ?? ''}', price: qtyText(n(l['total'])).replaceAll(',', ''))
                : _Line(productId: '${l['product_id']}', colorId: '${l['color_id'] ?? ''}', quantity: qtyText(n(l['quantity'])).replaceAll(',', ''),
                    price: n(l['price']) != n(l['list_price']) ? '${r2(n(l['price']) * (1 + n(l['vat_rate']) / 100))}' : '', reason: '${l['discount_reason'] ?? ''}'),
        ];
  final Map<String, ({double? ex, double rate})?> _prices = {}; // product|colour → price list without VAT + its rate
  Map<String, ({double min, double max})> _listPrices = {};
  Map<String, double> _avail = {};
  Map<String, ({double onHand, double held})> _stockInfo = {};
  // the store it is sold from (135): yard or shop — kept per branch on this phone; asked only when the branch has several
  late final List<Store> _saleStores = refs.warehouses.where((w) => w.status == 'active' && w.branchId == branchId && w.type == 'finished_goods').toList()
    ..sort((a, b) => a.receivesProduction != b.receivesProduction ? (a.receivesProduction ? -1 : 1) : a.name.compareTo(b.name));
  String _store = '';
  bool get storeOn => _saleStores.length > 1 && _saleStores.first.row.containsKey('receives_production');
  bool _busy = false;
  String _error = '';
  Map<int, PayProof> _payProofs = {};
  // the day's list (111)
  bool get dayOn => widget.book && sale == null && prefill == null;
  String get dayKey => 'mois.daySales.$branchId';
  List<Json> _dayList = [];
  final Map<String, ({List<PayProof> proofs, String buyer, Map<int, PayProof> raw})> _dayFiles = {};
  final List<({List<String> ids, PayProof slip})> _slipGroups = [];
  int? _dayBad;
  String _dayErr = '';
  bool _choosing = false;
  final Set<String> _daySel = {};

  List<Json> get activeAccounts => widget.accounts.where((a) => a['status'] == 'active').toList();
  CategoryTools get cats => CategoryTools(refs.categoryRows);
  List<Item> get carried => refs.items.values.where((i) => i.kind == 'product' && i.status == 'active' && (refs.carriedByBranch[branchId]?.contains(i.id) ?? false)).toList()..sort(productOrder(cats));
  String unitOf(String id) => refs.unit(refs.items['p:$id']?.stockUnitId);
  String per(String id) => unitOf(id).toUpperCase() == 'SQM' ? 'm²' : 'pc';
  String key(_Line l) => '${l.productId}|${l.colorId}';
  String digits(String v) => v.replaceAll(RegExp(r'\D'), '');

  @override
  void initState() {
    super.initState();
    for (final c in [_walkName, _walkPhone, _efd]) { c.addListener(() => setState(() {})); }
    _init();
  }

  Future<void> _init() async {
    String last = '';
    try {
      final p = await SharedPreferences.getInstance();
      last = p.getString('mois.saleStore.$branchId') ?? '';
      if (dayOn) {
        _dayList = jl(jsonDecode(p.getString(dayKey) ?? '[]'));
        // one sheet = one date: a kept list brings its date back
        if (_dayList.isNotEmpty && _dayList.first['payload']?['sale_date'] != null) _date = '${_dayList.first['payload']['sale_date']}';
      }
    } catch (_) {}
    _store = [sale?['warehouse_id'], prefill?['warehouse_id'], last].where((id) => id != null && '$id'.isNotEmpty && _saleStores.any((w) => w.id == id)).firstOrNull?.toString() ?? _saleStores.firstOrNull?.id ?? '';
    if (mounted) setState(() {});
    _loadListPrices();
    _loadAvail();
    _loadPrices();
  }

  Future<void> _keepDay() async {
    if (!dayOn) return;
    try {
      final p = await SharedPreferences.getInstance();
      if (_dayList.isEmpty) {
        await p.remove(dayKey);
      } else {
        await p.setString(dayKey, jsonEncode(_dayList));
      }
    } catch (_) {}
  }

  Future<void> _loadListPrices() async {
    try {
      final d = jl(await db.from('product_branch_pricing').select('product_id, price_per_sqm_inclusive, price_per_unit_inclusive, is_available').eq('branch_id', branchId));
      final m = <String, ({double min, double max})>{};
      for (final x in d) {
        if (x['is_available'] != true) continue;
        final sqm = unitOf('${x['product_id']}').toUpperCase() == 'SQM';
        final v = n(sqm ? x['price_per_sqm_inclusive'] : x['price_per_unit_inclusive']).toDouble();
        if (!(v > 0)) continue;
        final e = m['${x['product_id']}'];
        m['${x['product_id']}'] = e == null ? (min: v, max: v) : (min: math.min(e.min, v), max: math.max(e.max, v));
      }
      if (mounted) setState(() => _listPrices = m);
    } catch (_) {}
  }

  Future<void> _loadAvail() async {
    try {
      final d = jl(await db.rpc('sales_availability', params: {'p_branch_id': branchId, if (storeOn && _store.isNotEmpty) 'p_warehouse_id': _store}));
      if (!mounted) return;
      setState(() {
        _avail = {for (final x in d) '${x['product_id']}|${x['color_id'] ?? ''}': n(x['available']).toDouble()};
        _stockInfo = {for (final x in d) '${x['product_id']}|${x['color_id'] ?? ''}': (onHand: n(x['on_hand']).toDouble(), held: n(x['reserved']).toDouble())};
      });
    } catch (_) {}
  }

  /// the price list's price (without VAT) and its VAT rate for each product and colour on the sale
  void _loadPrices() {
    for (final l in _lines) {
      final k = key(l);
      if (l.other || l.productId.isEmpty || _prices.containsKey(k)) continue;
      final it = refs.items['p:${l.productId}'];
      if ((it?.colorIds.isNotEmpty ?? false) && l.colorId.isEmpty) continue;
      _prices[k] = null;
      Future.wait<dynamic>([
        db.rpc('product_price_ex_vat', params: {'p_branch_id': branchId, 'p_product_id': l.productId, 'p_color_id': l.colorId.isEmpty ? null : l.colorId}),
        db.rpc('product_price_vat_rate', params: {'p_branch_id': branchId, 'p_product_id': l.productId, 'p_color_id': l.colorId.isEmpty ? null : l.colorId}),
      ]).then((r) {
        final row = r[0] is List ? ((r[0] as List).isNotEmpty ? (r[0] as List).first : null) : r[0];
        if (mounted) setState(() => _prices[k] = (ex: row?['price'] != null ? n(row['price']).toDouble() : null, rate: n(r[1]).toDouble()));
      }).catchError((_) {});
    }
  }

  /// preview — the database works out the real figures the same way
  _Preview? preview(_Line l) {
    if (l.other) {
      final t = numOf(l.price.text);
      return (listInc: null, inc: t, total: t, ex: t ?? 0, rate: 0, off: false, vatOn: false, discount: 0);
    }
    final pr = _prices[key(l)];
    if (pr == null) return null;
    final listInc = pr.ex != null ? r2(pr.ex! * (1 + pr.rate / 100)) : null;
    final inc = numOf(l.price.text) ?? listInc;
    final q = numOf(l.quantity.text) ?? 0;
    if (inc == null) return (listInc: listInc, inc: null, total: null, ex: 0, rate: 0, off: true, vatOn: false, discount: 0);
    // a price other than the list's is a discount; the VAT box unticks itself for it unless ticked (110)
    final off = listInc == null || inc != listInc;
    final vatOn = l.vat ?? (!off && pr.rate > 0);
    final rate = vatOn ? (pr.rate > 0 ? pr.rate : 18.0) : 0.0;
    // 112: the price as typed to 3 decimals; the line total in whole shillings
    final total = (q * ((inc * 1000).roundToDouble() / 1000)).roundToDouble();
    return (listInc: listInc, inc: inc, total: total, ex: r2(total / (1 + rate / 100)), rate: rate, off: off, vatOn: vatOn, discount: listInc != null && inc < listInc ? r2((listInc - inc) * q) : 0);
  }

  ({double total, double ex}) get totals {
    var t = 0.0, e = 0.0;
    for (final l in _lines) { final p = preview(l); if (p?.total != null) { t += p!.total!; e += p.ex; } }
    return (total: t, ex: e);
  }

  /// what is available, with this sale's own hold given back when it is edited
  double? availOf(String k) {
    if (_avail[k] == null) return null;
    var own = 0.0;
    if (sale != null && ['order', 'invoice'].contains(sale!['stage'])) {
      for (final l in jl(sale!['lines'])) { if ('${l['product_id']}|${l['color_id'] ?? ''}' == k) own += n(l['quantity']); }
    }
    return _avail[k]! + own;
  }

  WalkIn? get known {
    if (sale != null) return null;
    final ph = digits(_walkPhone.text), nm = _walkName.text.trim().toLowerCase();
    return widget.walkIns.where((w) => (ph.isNotEmpty && digits(w.phone) == ph) || (ph.isEmpty && nm.isNotEmpty && w.key == 'n:$nm')).firstOrNull;
  }

  String buyerName(Object? cust) => (cust != null ? '${widget.customers.where((c) => c['id'] == cust).firstOrNull?['name'] ?? ''}' : _walkName.text.trim()).ifEmpty('Walk-in');

  List<PayProof> proofsFor(List<Json> payments) => [
        for (final (i, p) in payments.indexed)
          if (_payProofs[i]?.has == true && p['line_no'] == null) PayProof(accountId: '${p['account_id'] ?? ''}', amount: n(p['amount']).toDouble(), file: _payProofs[i]!.file, text: _payProofs[i]!.text),
      ];

  // ---- save ----
  Future<void> _save({bool toList = false}) async {
    setState(() => _error = '');
    String? fail(String m) { setState(() => _error = m); return null; }
    if (_lines.isEmpty) { fail('Add at least one product.'); return; }
    if (toList && ((_buyer == 'customer' && _newCust != null) || (_buyer == 'walkin' && _promote != null))) { fail('This buyer becomes a new customer: record this sale on its own (Record sale).'); return; }
    if (_lines.any((l) => l.other && (l.name.text.trim().isEmpty || !((numOf(l.price.text) ?? 0) > 0)))) { fail('Write what each other item is, and its price.'); return; }
    String? cust = _buyer == 'customer' && _customerId.isNotEmpty ? _customerId : null;
    if (_buyer == 'customer' && _newCust != null) {
      if (_newCust!['name']!.text.trim().isEmpty) { fail("Enter the new customer's name."); return; }
      setState(() => _busy = true);
      try {
        final d = await db.from('customers').insert({'organization_id': session.organization!['id'], 'branch_id': branchId, 'name': _newCust!['name']!.text.trim(),
          'phone': _newCust!['phone']!.text.trim().isEmpty ? null : _newCust!['phone']!.text.trim(), 'tin': _newCust!['tin']!.text.trim().isEmpty ? null : _newCust!['tin']!.text.trim()}).select('id').single();
        cust = '${d['id']}';
      } catch (e) {
        setState(() { _busy = false; _error = dbError(e); });
        return;
      }
      setState(() => _busy = false);
    }
    // the third purchase of a walk-in buyer: make them a customer first (their earlier sales follow)
    if (_buyer == 'walkin' && _promote != null) {
      if (_promote!['name']!.text.trim().isEmpty) { fail("Enter the customer's name."); return; }
      setState(() => _busy = true);
      try {
        final id = await db.rpc('promote_walk_in', params: {'p': {for (final e in _promote!.entries) e.key: e.value.text, 'match_name': _walkName.text, 'match_phone': _walkPhone.text}});
        cust = '$id';
      } catch (e) {
        setState(() { _busy = false; _error = dbError(e); });
        return;
      }
      setState(() => _busy = false);
    }
    if (_buyer == 'walkin' && _promote == null && _walkName.text.trim().isEmpty) { fail("Enter the buyer's name."); return; }
    if (_buyer == 'customer' && cust == null) { fail('Choose the customer, or sell to a walk-in buyer.'); return; }
    final noReason = _lines.indexWhere((l) => !l.other && preview(l)?.off == true && preview(l)?.listInc != null && l.reason.text.trim().isEmpty);
    if (noReason >= 0) { fail('${refs.items['p:${_lines[noReason].productId}']?.name}: give the reason for the price change.'); return; }
    final tt = totals;
    final payload = <String, dynamic>{
      if (sale?['id'] != null) 'id': sale!['id'], 'branch_id': branchId, 'sale_date': _date, 'valid_until': _validUntil.isEmpty ? null : _validUntil, 'notes': _notes.text,
      if (widget.note && sale == null) 'as_note': true,
      if (cust != null) 'customer_id': cust else ...{'walk_in_name': _walkName.text, 'walk_in_phone': _walkPhone.text},
      'lines': [
        for (final l in _lines)
          l.other
              ? {'item_name': l.name.text.trim(), 'price': numOf(l.price.text)}
              : {'product_id': l.productId, 'color_id': l.colorId.isEmpty ? null : l.colorId, 'quantity': numOf(l.quantity.text), 'vat': preview(l)?.vatOn ?? false,
                  if (numOf(l.price.text) != null && _prices[key(l)] != null) ...{'price': numOf(l.price.text), 'discount_reason': l.reason.text}},
      ],
    };
    if (widget.book && _payMode == 'items' && _lines.length > 1) {
      final ps = [
        for (final (i, l) in _lines.indexed)
          () { final x = _itemPays[i]; final v = x == null || x.amount.text.isEmpty ? (preview(l)?.total ?? 0) : (numOf(x.amount.text) ?? 0); return (lineNo: i + 1, accountId: x?.accountId ?? '', value: v, receiptNo: x?.receiptNo ?? ''); }(),
      ].where((x) => x.value > 0).toList();
      if (activeAccounts.isEmpty && ps.isNotEmpty) { fail('Add the receiving accounts first (Sales ⚙) — a payment must name its account.'); return; }
      if (ps.any((x) => x.accountId.isEmpty)) { fail('Choose the account each item was paid into — it is required.'); return; }
      payload['site'] = _site.text;
      payload['efd_receipt_no'] = _efd.text;
      payload['payments'] = [for (final x in ps) {'line_no': x.lineNo, 'account_id': x.accountId, 'amount': x.value, 'receipt_no': x.receiptNo}];
    } else if (widget.book) {
      final ps = [for (final x in _pays) (x: x, value: x.auto && _pays.length == 1 ? r2(tt.total) : (numOf(x.amount.text) ?? 0))].where((p) => p.value > 0).toList();
      if (ps.any((p) => p.x.accountId.isEmpty) && activeAccounts.isNotEmpty) { fail('Choose the account this payment went into — it is required.'); return; }
      if (ps.isNotEmpty && activeAccounts.isEmpty) { fail('Add the receiving accounts first (Sales ⚙) — a payment must name its account.'); return; }
      if (r2(ps.fold<double>(0, (t, p) => t + p.value)) > r2(tt.total) + 0.01) { fail('The payments are more than the total.'); return; }
      payload['site'] = _site.text;
      payload['efd_receipt_no'] = _efd.text;
      payload['payments'] = [for (final p in ps) {'account_id': p.x.accountId.isEmpty ? null : p.x.accountId, 'amount': p.value, 'receipt_no': p.x.receiptNo, if (p.x.accountId.isEmpty) 'method': 'cash'}];
    } else {
      payload['site'] = _site.text;
    }
    if (storeOn && _store.isNotEmpty) payload['warehouse_id'] = _store; // set with set_sale_store after saving (135)
    if (toList) { _addToDay(payload, cust); return; }
    setState(() => _busy = true);
    try {
      final data = widget.book ? await db.rpc('record_sale', params: {'p': payload}) : await db.rpc('save_sale', params: {'p': payload});
      final id = '${sale?['id'] ?? data}';
      if (!widget.book && ((sale != null && _site.text != '${sale!['site'] ?? ''}') || (sale == null && _site.text.isNotEmpty))) await db.rpc('set_sale_site', params: {'p_sale': id, 'p_site': _site.text});
      if (storeOn && _store.isNotEmpty && _store != '${sale?['warehouse_id'] ?? ''}') await db.rpc('set_sale_store', params: {'p_sale': id, 'p_warehouse': _store});
      if (widget.book && data != null) {
        final failed = await postSaleProofs('$data', proofsFor(jl(payload['payments'])), buyer: buyerName(payload['customer_id']));
        if (failed > 0 && mounted) toast(context, 'The sale is saved, but a proof could not be posted. Add it in Sales › Slips.', error: true);
      }
      if (mounted) Navigator.pop(context, id);
      return;
    } catch (e) {
      _error = dbError(e, "We couldn't save this sale. Please try again.");
    }
    if (mounted) setState(() => _busy = false);
  }

  void _reset() {
    _lines = [];
    _walkName.clear(); _walkPhone.clear(); _customerId = ''; _site.clear(); _efd.clear(); _notes.clear();
    _pays = [_Pay(auto: true)]; _payMode = 'order'; _itemPays = {}; _payProofs = {}; _error = '';
  }

  // the sale in the form goes to the day's list; the form clears for the next one (the date stays)
  void _addToDay(Json payload, String? cust) {
    String accName(Object? id) => '${activeAccounts.where((a) => a['id'] == id).firstOrNull?['name'] ?? 'Cash'}';
    final tt = totals;
    final pays = jl(payload['payments']);
    final view = {
      'name': cust != null ? '${widget.customers.where((c) => c['id'] == cust).firstOrNull?['name'] ?? ''}' : _walkName.text.trim(),
      'date': _date,
      'rows': [
        for (final l in _lines)
          {'product': l.other ? l.name.text.trim() : lineName(refs, {'product_id': l.productId, 'color_id': l.colorId.isEmpty ? null : l.colorId}),
            'qty': l.other ? null : numOf(l.quantity.text), 'unit': l.other ? '' : per(l.productId), 'amount': preview(l)?.total ?? 0},
      ],
      'acc': {for (final x in pays) accName(x['account_id'])}.join(', ').ifEmpty('Not paid'),
      'paid': r2(pays.fold<double>(0, (t, x) => t + n(x['amount']))),
      'total': r2(tt.total),
    };
    final form = {
      'buyer': _buyer, 'customerId': _customerId, 'walkName': _walkName.text, 'walkPhone': _walkPhone.text, 'date': _date, 'notes': _notes.text, 'site': _site.text, 'efd': _efd.text,
      'pays': [for (final p in _pays) p.toJson()], 'payMode': _payMode, 'itemPays': {for (final e in _itemPays.entries) '${e.key}': e.value.toJson()}, 'lines': [for (final l in _lines) l.toJson()],
    };
    final id = '${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(9999)}';
    final proofs = proofsFor(pays);
    view['proofs'] = proofs.length;
    if (proofs.isNotEmpty) _dayFiles[id] = (proofs: proofs, buyer: buyerName(cust), raw: Map.of(_payProofs));
    setState(() {
      _dayList = [..._dayList, {'id': id, 'payload': payload, 'view': view, 'form': form}];
      _dayBad = null;
      _reset();
    });
    _keepDay();
  }

  // a row goes back into the form to fix
  void _editDay(int i) {
    if (_lines.isNotEmpty) { setState(() => _error = 'Add the sale in the form to the list first, or remove its items.'); return; }
    final x = Map<String, dynamic>.from(_dayList[i]['form'] as Map);
    setState(() {
      _buyer = '${x['buyer']}'; _customerId = '${x['customerId'] ?? ''}'; _walkName.text = '${x['walkName'] ?? ''}'; _walkPhone.text = '${x['walkPhone'] ?? ''}';
      _date = '${x['date']}'; _notes.text = '${x['notes'] ?? ''}'; _site.text = '${x['site'] ?? ''}'; _efd.text = '${x['efd'] ?? ''}';
      _pays = [for (final p in jl(x['pays'])) _Pay.from(p)];
      _payMode = '${x['payMode'] ?? 'order'}';
      _itemPays = {for (final e in ((x['itemPays'] as Map?) ?? {}).entries) int.parse('${e.key}'): _Pay.from(Map<String, dynamic>.from(e.value as Map))};
      _lines = [for (final l in jl(x['lines'])) _Line.from(l)];
      _payProofs = Map.of(_dayFiles['${_dayList[i]['id']}']?.raw ?? {});
      _removeDay(i, keepFiles: true);
      _error = '';
    });
    _loadPrices();
  }

  void _removeDay(int i, {bool keepFiles = false}) {
    final id = '${_dayList[i]['id']}';
    _dayList = [..._dayList]..removeAt(i);
    _dayBad = null;
    _daySel.remove(id);
    if (!keepFiles) _dayFiles.remove(id);
    for (var g = _slipGroups.length - 1; g >= 0; g--) {
      _slipGroups[g].ids.remove(id);
      if (_slipGroups[g].ids.isEmpty) _slipGroups.removeAt(g);
    }
    _keepDay();
  }

  int groupOf(String id) => _slipGroups.indexWhere((g) => g.ids.contains(id));
  Json viewOf(Json x) => Map<String, dynamic>.from(x['view'] as Map);

  void _changeDate(String v) {
    setState(() {
      _date = v;
      if (dayOn) {
        _dayList = [
          for (final x in _dayList) {...x, 'payload': {...(x['payload'] as Map), 'sale_date': v}, 'view': {...(x['view'] as Map), 'date': v}, 'form': {...(x['form'] as Map), 'date': v}},
        ];
      }
    });
    _keepDay();
  }

  Future<void> _slipFor(Set<String> ids) async {
    final ticked = _dayList.where((x) => ids.contains(x['id'])).toList();
    final own = ids.length == 1 ? _dayFiles[ids.first]?.proofs.firstOrNull : null;
    final shared = _slipGroups.where((g) => g.ids.length == ids.length && ids.every(g.ids.contains)).firstOrNull;
    final names = ticked.map((x) => viewOf(x)['name']).join(', ');
    final amount = r2(ticked.fold<double>(0, (t, x) => t + n(viewOf(x)['paid'])));
    final v = await proofWindow(context, amount: amount, start: own ?? shared?.slip,
        note: own != null ? 'The proof added with this sale: keep it or replace it.' : 'One slip for ${ids.length} sale${ids.length == 1 ? '' : 's'}: $names. Their own proofs give way to it.');
    if (v == null || !mounted) return;
    setState(() {
      // their own proofs give way to this slip
      for (final id in ids) {
        if (_dayFiles.remove(id) != null || n(viewOf(_dayList.firstWhere((x) => x['id'] == id))['proofs']) > 0) {
          _dayList = [for (final x in _dayList) x['id'] == id ? {...x, 'view': {...(x['view'] as Map), 'proofs': 0}} : x];
        }
      }
      for (var g = _slipGroups.length - 1; g >= 0; g--) {
        _slipGroups[g].ids.removeWhere(ids.contains);
        if (_slipGroups[g].ids.isEmpty) _slipGroups.removeAt(g);
      }
      _slipGroups.add((ids: [...ids], slip: v));
      _daySel.clear();
      _choosing = false;
    });
    _keepDay();
  }

  // Save all shows every sale first and saves only on Confirm (2026-11-11)
  Future<void> _askSaveDay() async {
    setState(() { _error = ''; _dayErr = ''; });
    if (_lines.isNotEmpty) { setState(() => _dayErr = 'The form above still has a sale: add it to the list, or remove its items.'); return; }
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _CheckDay(list: _dayList, files: _dayFiles, groups: _slipGroups, accounts: activeAccounts, date: _date)));
    if (ok == true) _saveDay();
  }

  Future<void> _saveDay() async {
    setState(() => _busy = true);
    List<dynamic>? ids;
    try {
      ids = await db.rpc('record_sales_day', params: {'p_sales': [for (final x in _dayList) x['payload']]}) as List?;
    } catch (e) {
      final m = RegExp(r'Sale (\d+): ').firstMatch('$e');
      setState(() {
        if (m != null) _dayBad = int.parse(m[1]!) - 1;
        _dayErr = dbError(e, "We couldn't save the day's sales. Nothing was saved.");
        _busy = false;
      });
      return;
    }
    var failed = 0;
    // the store each was sold from (135)
    for (final (k, x) in _dayList.indexed) {
      final w = (x['payload'] as Map)['warehouse_id'];
      if (w != null && ids != null && k < ids.length) { try { await db.rpc('set_sale_store', params: {'p_sale': ids[k], 'p_warehouse': w}); } catch (_) {} }
    }
    // the sales are saved: now their proofs
    for (final (k, x) in _dayList.indexed) {
      final pf = _dayFiles['${x['id']}'];
      if (pf != null && ids != null && k < ids.length) failed += await postSaleProofs('${ids[k]}', pf.proofs, buyer: pf.buyer);
    }
    // one slip a group: every saved payment it covers that has no proof of its own
    if (_slipGroups.isNotEmpty && ids != null && ids.isNotEmpty) {
      try {
        final pays = jl(await db.from('sale_payments').select('id, amount, paid_on, account_id, sale:sales!inner(id, sale_no, branch_id)').inFilter('sale_id', ids));
        final had = jl(await db.from('sale_payment_proofs').select('payment_id').inFilter('payment_id', [for (final p in pays) p['id']]));
        final taken = {for (final h in had) h['payment_id']};
        for (final g in _slipGroups) {
          final saleIds = [for (final id in g.ids) () { final i = _dayList.indexWhere((x) => x['id'] == id); return i >= 0 && i < ids!.length ? ids[i] : null; }()].whereType<Object>().toList();
          final covered = pays.where((p) => saleIds.contains(p['sale']['id']) && !taken.contains(p['id'])).toList();
          final names = [for (final id in g.ids) _dayList.where((x) => x['id'] == id).firstOrNull?['view']?['name']].whereType<Object>().map((e) => '$e').toList();
          failed += await postSharedSlip(covered, g.slip, who: names.length > 2 ? '${names[0]}-and-${names.length - 1}-more' : names.join('-'));
        }
      } catch (_) {
        failed++;
      }
    }
    _dayList = [];
    _dayFiles.clear();
    _slipGroups.clear();
    await _keepDay();
    if (!mounted) return;
    if (failed > 0) toast(context, 'The sales are saved, but $failed proof${failed == 1 ? '' : 's'} could not be posted. Add ${failed == 1 ? 'it' : 'them'} in Sales › Slips.', error: true);
    Navigator.pop(context, '');
  }

  Future<void> _addProduct() async {
    final id = await pickProduct(context, title: 'Add a product', items: carried, cats: cats, usage: widget.sold, usageLabel: const ['sale', 'sales'],
        metaOf: (i) {
          // sales: what is available (all colours) and the price, not the wastani
          final av = _avail.entries.where((e) => e.key.startsWith('${i.id}|')).fold<double>(0, (t, e) => t + math.max(e.value, 0));
          final lp = _listPrices[i.id];
          return ['${qtyText(r2(av))} ${unitOf(i.id).toUpperCase() == 'SQM' ? 'm²' : 'pcs'} available',
            lp != null ? '${lp.min != lp.max || i.colorIds.length > 1 ? 'from ' : ''}${money(lp.min)} /${per(i.id)}' : 'no price'].join(' • ');
        });
    if (id == null) return;
    setState(() => _lines = [..._lines, _Line(productId: id)]);
    _loadPrices();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final tt = totals;
    final hasVat = _lines.any((l) => preview(l)?.vatOn == true);
    final wanted = <String, double>{};
    for (final l in _lines) { if (!l.other && l.productId.isNotEmpty && (numOf(l.quantity.text) ?? 0) > 0) wanted[key(l)] = (wanted[key(l)] ?? 0) + numOf(l.quantity.text)!; }
    final kn = _buyer == 'walkin' ? known : null;
    final title = sale != null ? '${saleStages[sale!['stage']]} #${sale!['sale_no']}' : widget.book ? 'Record a sale' : widget.note ? 'New note' : 'New quotation';

    return FullPage(
      title: title,
      footer: dayOn
          ? [
              OutlinedButton(onPressed: _busy ? null : () => setState(_reset), child: const Text('Reset')),
              FilledButton.icon(onPressed: _busy ? null : () => _save(toList: true), icon: const Icon(LucideIcons.plus, size: 16), label: const Text('Add Sale to Daily Sales')),
            ]
          : [
              OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
              FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : sale != null ? 'Save' : widget.book ? 'Record sale' : widget.note ? 'Save note' : 'Save quotation')),
            ],
      children: [
        if (prefill?['banner'] != null) Alert('${prefill!['banner']}', tone: Tone.info),
        DateField(label: dayOn && _dayList.isNotEmpty ? 'Date (every sale in the list)' : 'Date', value: _date, last: today, onChange: _changeDate),
        const SizedBox(height: 10),
        Row(children: [
          Chip2('Walk-in buyer', on: _buyer == 'walkin', onTap: () => setState(() => _buyer = 'walkin')),
          const SizedBox(width: 6),
          Chip2('Customer', on: _buyer == 'customer', onTap: () => setState(() => _buyer = 'customer')),
        ]),
        if (storeOn) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _store, isExpanded: true, decoration: const InputDecoration(labelText: 'Sold from', isDense: true),
            items: [for (final w in _saleStores) DropdownMenuItem(value: w.id, child: Text(w.name))],
            onChanged: (v) async {
              if (v == null) return;
              setState(() => _store = v);
              try { (await SharedPreferences.getInstance()).setString('mois.saleStore.$branchId', v); } catch (_) {}
              _loadAvail();
            },
          ),
        ],
        const SizedBox(height: 10),
        if (_buyer == 'walkin') ...[
          Autocomplete<WalkIn>(
            initialValue: _walkName.value,
            displayStringForOption: (w) => w.name,
            optionsBuilder: (v) => v.text.trim().isEmpty ? const [] : widget.walkIns.where((w) => w.name.isNotEmpty && w.name.toLowerCase().contains(v.text.toLowerCase())).take(8),
            onSelected: (w) => setState(() { _walkName.text = w.name; _walkPhone.text = w.phone; if (_site.text.isEmpty && w.site.isNotEmpty) _site.text = w.site; }),
            fieldViewBuilder: (ctx, c, focus, submit) => TextField(controller: c, focusNode: focus, onChanged: (v) => _walkName.text = v, decoration: const InputDecoration(labelText: 'Name')),
          ),
          const SizedBox(height: 8),
          Autocomplete<WalkIn>(
            initialValue: _walkPhone.value,
            displayStringForOption: (w) => w.phone,
            optionsBuilder: (v) => digits(v.text).length < 3 ? const [] : widget.walkIns.where((w) => digits(w.phone).contains(digits(v.text))).take(8),
            onSelected: (w) => setState(() { _walkName.text = w.name; _walkPhone.text = w.phone; if (_site.text.isEmpty && w.site.isNotEmpty) _site.text = w.site; }),
            optionsViewBuilder: null,
            fieldViewBuilder: (ctx, c, focus, submit) => TextField(controller: c, focusNode: focus, keyboardType: TextInputType.phone, onChanged: (v) => _walkPhone.text = v, decoration: const InputDecoration(labelText: 'Phone (optional)')),
          ),
          if (kn != null)
            kn.count >= 2
                ? Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: t.bgInfo, borderRadius: BorderRadius.circular(8)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Text('${kn.name.ifEmpty(kn.phone)} is buying for the ${kn.count + 1}${kn.count + 1 == 3 ? 'rd' : 'th'} time — save them as a customer (their ${kn.count} earlier sale${kn.count == 1 ? '' : 's'} move with them).', style: const TextStyle(fontSize: Fs.sm)),
                      const SizedBox(height: 6),
                      if (_promote == null)
                        Align(alignment: Alignment.centerLeft, child: OutlinedButton(
                          onPressed: () => setState(() => _promote = {'name': TextEditingController(text: _walkName.text.ifEmpty(kn.name)), 'phone': TextEditingController(text: _walkPhone.text.ifEmpty(kn.phone)), 'tin': TextEditingController(), 'address': TextEditingController()}),
                          child: const Text('Add their details'),
                        ))
                      else ...[
                        for (final (k, l) in const [('name', 'Name'), ('phone', 'Phone'), ('tin', 'TIN (optional)'), ('address', 'Address (optional)')])
                          Padding(padding: const EdgeInsets.only(bottom: 6), child: TextField(controller: _promote![k], decoration: InputDecoration(isDense: true, labelText: l))),
                        Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => setState(() => _promote = null), child: const Text('Not now'))),
                      ],
                    ]),
                  )
                : PlHelp('Bought before (${kn.count})'),
        ] else if (_newCust != null) ...[
          TextField(controller: _newCust!['name'], autofocus: true, decoration: const InputDecoration(labelText: 'New customer')),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _newCust!['phone'], keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _newCust!['tin'], decoration: const InputDecoration(labelText: 'TIN (optional)'))),
          ]),
          Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => setState(() => _newCust = null), child: const Text('Pick existing'))),
        ] else ...[
          DropdownButtonFormField<String>(
            initialValue: _customerId, isExpanded: true, decoration: const InputDecoration(labelText: 'Customer'),
            items: [const DropdownMenuItem(value: '', child: Text('Choose…')),
              for (final c in widget.customers.where((c) => c['status'] == 'active' || c['id'] == _customerId))
                DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}${c['phone'] != null ? ' · ${c['phone']}' : ''}', overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _customerId = v ?? ''),
          ),
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(
            onPressed: () => setState(() => _newCust = {'name': TextEditingController(), 'phone': TextEditingController(), 'tin': TextEditingController()}),
            icon: const Icon(LucideIcons.plus, size: 14), label: const Text('New customer'),
          )),
        ],
        const SizedBox(height: 8),
        TextField(controller: _site, decoration: const InputDecoration(labelText: 'Site (where the goods go)', hintText: "e.g. the customer's site")),
        if (!widget.book && (sale == null || sale!['stage'] == 'quotation')) ...[
          const SizedBox(height: 8),
          DateField(label: 'Quotation valid until (optional)', value: _validUntil, first: _date, onChange: (v) => setState(() => _validUntil = v)),
        ],

        // ---- the lines ----
        const SectionTitle('Products'),
        for (final (i, l) in _lines.indexed) _lineCard(i, l, wanted),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(onPressed: _addProduct, icon: const Icon(LucideIcons.plus, size: 15), label: const Text('Add product')),
          if (widget.canOther)
            OutlinedButton.icon(onPressed: () => setState(() => _lines = [..._lines, _Line(other: true)]), icon: const Icon(LucideIcons.plus, size: 15), label: const Text('Add other item')),
        ]),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: PlHelp('without VAT ${money(r2(tt.ex))} · VAT ${money(r2(tt.total - tt.ex))}')),
          Text('Total ${money(r2(tt.total))}', style: const TextStyle(fontWeight: FontWeight.w700)),
        ]),

        // ---- the money (Record sale) ----
        if (widget.book) ..._payments(tt.total),
        if (widget.book) ...[
          const SizedBox(height: 8),
          TextField(controller: _efd, decoration: InputDecoration(
            labelText: 'EFD receipt no. ${hasVat ? '(required)' : '(if any)'}', hintText: hasVat ? 'Add it now or later' : null,
            labelStyle: hasVat && _efd.text.trim().isEmpty ? const TextStyle(color: C.warning) : null,
          )),
          // the proof of each payment (2026-11-08)
          if (!(_payMode == 'items' && _lines.length > 1))
            for (final (i, x) in _pays.indexed)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: OutlinedButton.icon(
                  onPressed: () async {
                    final v = await proofWindow(context, amount: x.auto && _pays.length == 1 ? tt.total : (numOf(x.amount.text) ?? 0), start: _payProofs[i]);
                    if (v != null) setState(() => _payProofs[i] = v);
                  },
                  icon: Icon(_payProofs[i]?.has == true ? LucideIcons.check : LucideIcons.plus, size: 15),
                  label: Text('${_payProofs[i]?.has == true ? 'Proof/slip added' : 'Add proof/slip'}${_pays.length > 1 ? ' · ${activeAccounts.where((a) => a['id'] == x.accountId).firstOrNull?['name'] ?? 'payment ${i + 1}'}' : ''}'),
                ),
              ),
        ],
        const SizedBox(height: 8),
        TextField(controller: _notes, decoration: const InputDecoration(labelText: 'Notes (optional)')),
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),

        // ---- the day's list (Daily Sales Ledger) ----
        if (dayOn && _dayList.isNotEmpty) _dayCard(),
      ],
    );
  }

  Widget _lineCard(int i, _Line l, Map<String, double> wanted) {
    final t = context.tk;
    void remove() => setState(() { _lines = [..._lines]..removeAt(i); _payProofs = {}; });
    if (l.other) {
      return CardBox(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: TextField(controller: l.name, onChanged: (_) => setState(() {}), decoration: const InputDecoration(isDense: true, labelText: 'Other item', hintText: 'What is it? e.g. vipande 4"'))),
            IconButton(tooltip: 'Remove line', onPressed: remove, icon: const Icon(LucideIcons.trash2, size: 16)),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: TextField(controller: l.price, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, labelText: 'Price'))),
            const SizedBox(width: 8),
            Text((numOf(l.price.text) ?? 0) > 0 ? money(numOf(l.price.text)!) : '—', style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
          const PlHelp('Price agreed with the buyer · no stock, no VAT'),
        ]),
      );
    }
    final it = refs.items['p:${l.productId}'];
    final p = preview(l);
    final k = key(l);
    final av = availOf(k);
    final si = _stockInfo[k];
    final changed = numOf(l.price.text) != null && p?.listInc != null && numOf(l.price.text) != p!.listInc;
    return CardBox(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(it?.name ?? '—', style: const TextStyle(fontWeight: FontWeight.w700)),
            PlHelp(it?.category ?? ''),
          ])),
          IconButton(tooltip: 'Remove line', onPressed: remove, icon: const Icon(LucideIcons.trash2, size: 16)),
        ]),
        if (it?.colorIds.isNotEmpty ?? false) ...[
          SlideRow(children: [for (final c in it!.colorIds) Chip2(refs.colour(c), on: l.colorId == c, onTap: () { setState(() { l.colorId = c; l.price.clear(); l.reason.clear(); }); _loadPrices(); })]),
          const SizedBox(height: 6),
        ],
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: TextField(controller: l.quantity, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(isDense: true, labelText: 'Quantity (${per(l.productId)})'))),
          const SizedBox(width: 8),
          Expanded(child: p == null
              ? Padding(padding: const EdgeInsets.only(top: 10), child: PlHelp((it?.colorIds.isNotEmpty ?? false) && l.colorId.isEmpty ? 'pick a colour' : '…'))
              : widget.canDiscount
                  ? TextField(controller: l.price, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(isDense: true, labelText: 'Price', hintText: p.listInc != null ? qtyText(p.listInc!) : 'No price'))
                  : Padding(padding: const EdgeInsets.only(top: 10), child: p.listInc != null
                      ? Text('${money(p.listInc!)} /${per(l.productId)}', style: const TextStyle(fontWeight: FontWeight.w600))
                      : const PlHelp('No price — set it in Pricing', color: C.warning))),
        ]),
        if (av != null)
          PlHelp('${qtyText(r2(math.max(av, 0)))} ${unitOf(l.productId)} available${(si?.held ?? 0) > 0 ? ' · ${qtyText(r2(si!.onHand))} in store' : ''}'),
        if (av != null && (wanted[k] ?? 0) > av + 1e-9)
          PlHelp('Short ${qtyText(r2((wanted[k] ?? 0) - math.max(av, 0)))} ${unitOf(l.productId)} — to make', color: C.warning),
        if (p != null && widget.canDiscount) ...[
          PlHelp(p.listInc != null ? 'list ${money(p.listInc!)} /${per(l.productId)}' : 'no list price'),
          if (p.off && p.discount > 0) PlHelp('discount ${money(p.discount)}', color: C.warning),
          if (p.off && !(p.discount > 0) && p.listInc != null) const PlHelp('not the list price'),
          if (changed) Padding(padding: const EdgeInsets.only(top: 6), child: TextField(controller: l.reason, onChanged: (_) => setState(() {}), decoration: const InputDecoration(isDense: true, labelText: 'Reason for the price (required)'))),
        ],
        if (p?.total != null)
          Row(children: [
            Checkbox(value: p!.vatOn, onChanged: (v) => setState(() => l.vat = v)),
            Text('VAT', style: TextStyle(fontSize: Fs.sm, color: t.textSecondary)),
            const Spacer(),
            Text(money(p.total!), style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
      ]),
    );
  }

  List<Widget> _payments(double total) {
    final items = _payMode == 'items' && _lines.length > 1;
    return [
      const SectionTitle('Payments'),
      if (_lines.length > 1)
        SlideRow(children: [
          Chip2('One payment for the whole order', on: _payMode == 'order', onTap: () => setState(() => _payMode = 'order')),
          Chip2('Separately per item', on: _payMode == 'items', onTap: () => setState(() => _payMode = 'items')),
        ]),
      const SizedBox(height: 6),
      if (items)
        for (final (i, l) in _lines.indexed)
          () {
            final x = _itemPays.putIfAbsent(i, () => _Pay());
            return CardBox(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(l.other ? l.name.text.ifEmpty('Other item') : lineName(refs, {'product_id': l.productId, 'color_id': l.colorId.isEmpty ? null : l.colorId}), style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(child: TextField(controller: x.amount, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(isDense: true, labelText: 'Amount', hintText: qtyText(preview(l)?.total ?? 0)))),
                  const SizedBox(width: 8),
                  Expanded(child: DropdownButtonFormField<String>(
                    initialValue: x.accountId, isExpanded: true, decoration: const InputDecoration(isDense: true, labelText: 'Into account (required)'),
                    items: [const DropdownMenuItem(value: '', child: Text('Choose…')), for (final a in activeAccounts) DropdownMenuItem(value: '${a['id']}', child: Text('${a['name']}', overflow: TextOverflow.ellipsis))],
                    onChanged: (v) => setState(() => x.accountId = v ?? ''),
                  )),
                ]),
              ]),
            );
          }()
      else ...[
        if (activeAccounts.isEmpty) const PlHelp('No accounts yet (Sales ⚙) — recorded as cash.'),
        for (final (i, x) in _pays.indexed)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(children: [
              if (activeAccounts.isNotEmpty) ...[
                Expanded(child: DropdownButtonFormField<String>(
                  initialValue: x.accountId, isExpanded: true, decoration: const InputDecoration(isDense: true, labelText: 'Into account (required)'),
                  items: [const DropdownMenuItem(value: '', child: Text('Choose…')), for (final a in activeAccounts) DropdownMenuItem(value: '${a['id']}', child: Text('${a['name']}', overflow: TextOverflow.ellipsis))],
                  onChanged: (v) => setState(() => x.accountId = v ?? ''),
                )),
                const SizedBox(width: 8),
              ],
              Expanded(child: x.auto && _pays.length == 1
                  ? InkWell(
                      onTap: () => setState(() { x.amount.text = qtyText(r2(total)).replaceAll(',', ''); x.auto = false; }),
                      child: InputDecorator(decoration: const InputDecoration(isDense: true, labelText: 'Amount'), child: Text(qtyText(r2(total)))),
                    )
                  : TextField(controller: x.amount, onChanged: (_) => setState(() => x.auto = false), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, labelText: 'Amount'))),
              if (_pays.length > 1) IconButton(tooltip: 'Remove payment', onPressed: () => setState(() { _pays = [..._pays]..removeAt(i); _payProofs = {}; }), icon: const Icon(LucideIcons.trash2, size: 16)),
            ]),
          ),
        Row(children: [
          TextButton.icon(
            onPressed: () => setState(() {
              for (final y in _pays) { if (y.auto) { y.amount.text = qtyText(r2(total)).replaceAll(',', ''); y.auto = false; } }
              _pays = [..._pays, _Pay()];
            }),
            icon: const Icon(LucideIcons.plus, size: 14), label: const Text('Split into another account'),
          ),
          const Spacer(),
          const PlHelp('Not paid yet? Amount 0.'),
        ]),
      ],
    ];
  }

  Widget _dayCard() {
    final t = context.tk;
    final total = r2(_dayList.fold<double>(0, (s, x) => s + n(viewOf(x)['total'])));
    final byAcc = <String, ({String name, double amount})>{};
    for (final x in _dayList) {
      for (final p in jl((x['payload'] as Map)['payments'])) {
        final k = '${p['account_id'] ?? ''}';
        final e = byAcc[k];
        byAcc[k] = (name: '${activeAccounts.where((a) => a['id'] == p['account_id']).firstOrNull?['name'] ?? 'Cash'}', amount: r2((e?.amount ?? 0) + n(p['amount'])));
      }
    }
    final unpaid = r2(_dayList.fold<double>(0, (s, x) => s + math.max(n(viewOf(x)['total']) - n(viewOf(x)['paid']), 0)));
    return Container(
      margin: const EdgeInsets.only(top: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(12), border: Border.all(color: C.khaki, width: 1.5)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          const Expanded(child: Text('Daily Sales Ledger', style: TextStyle(fontWeight: FontWeight.w700))),
          Badge2('${_dayList.length} sale${_dayList.length == 1 ? '' : 's'} · ${money(total)}'),
        ]),
        const SizedBox(height: 6),
        // newest on top (2026-11-13); saved in the order they were added
        for (final (i, x) in _dayList.indexed.toList().reversed)
          () {
            final v = viewOf(x);
            final id = '${x['id']}';
            final g = groupOf(id);
            final hasProof = n(v['proofs']) > 0 || g >= 0;
            return InkWell(
              onTap: () => _previewDay(i),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(color: _dayBad == i ? C.error.withValues(alpha: .08) : null, border: Border(bottom: BorderSide(color: t.border))),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (_choosing)
                    Checkbox(value: _daySel.contains(id), onChanged: !(n(v['paid']) > 0) ? null : (c) => setState(() { if (c == true) { _daySel.add(id); } else { _daySel.remove(id); } }))
                  else
                    IconButton(
                      tooltip: n(v['paid']) > 0 ? (hasProof ? 'Its proof — keep or replace it' : 'Add its proof/slip') : 'Nothing paid yet',
                      onPressed: !(n(v['paid']) > 0) ? null : () => _slipFor({id}),
                      icon: Icon(LucideIcons.paperclip, size: 16, color: hasProof ? C.success : null),
                    ),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${v['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                    for (final r in jl(v['rows'])) PlHelp('${r['product']}${r['qty'] != null ? ' · ${qtyText(n(r['qty']))} ${r['unit']}' : ''} · ${formatAmount(n(r['amount']))}'),
                    PlHelp('${v['acc']}${n(v['paid']) < n(v['total']) - 0.01 ? ' · ${formatAmount(r2(n(v['total']) - n(v['paid'])))} not paid' : ''}'
                        '${g >= 0 ? ' · + shared slip${_slipGroups.length > 1 ? ' ${g + 1}' : ''}' : ''}'
                        '${n(v['proofs']) > 0 ? (_dayFiles[id] != null ? ' · + proof' : ' · proof: add it again') : ''}'),
                  ])),
                  PopupMenuButton<String>(
                    icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
                    onSelected: (a) => a == 'edit' ? _editDay(i) : setState(() => _removeDay(i)),
                    itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('Edit it in the form')), PopupMenuItem(value: 'remove', child: Text('Remove from the list'))],
                  ),
                ]),
              ),
            );
          }(),
        const SizedBox(height: 6),
        Wrap(spacing: 10, runSpacing: 4, children: [
          for (final v in byAcc.values) Text.rich(TextSpan(children: [TextSpan(text: '${v.name} ', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)), TextSpan(text: formatAmount(v.amount), style: const TextStyle(fontWeight: FontWeight.w700))])),
          if (unpaid > 0) Text.rich(TextSpan(children: [TextSpan(text: 'Not paid ', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)), TextSpan(text: formatAmount(unpaid), style: const TextStyle(fontWeight: FontWeight.w700, color: C.warning))])),
        ]),
        if (_choosing)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
            decoration: BoxDecoration(color: t.soft, borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Expanded(child: Text(_daySel.isEmpty ? 'Tick the sales this proof/slip is for.' : '${_daySel.length} ticked · ${money(r2(_dayList.where((x) => _daySel.contains(x['id'])).fold<double>(0, (s, x) => s + n(viewOf(x)['paid']))))} paid', style: const TextStyle(fontSize: Fs.sm))),
              FilledButton(onPressed: _daySel.isEmpty ? null : () => _slipFor({..._daySel}), child: const Text('Add the proof/slip')),
              TextButton(onPressed: () => setState(() { _daySel.clear(); _choosing = false; }), child: const Text('Cancel')),
            ]),
          ),
        if (_dayErr.isNotEmpty) Alert(_dayErr, tone: Tone.error),
        const SizedBox(height: 8),
        Row(children: [
          if (!_choosing)
            OutlinedButton.icon(
              onPressed: () => setState(() { _daySel.clear(); _choosing = true; }),
              icon: const Icon(LucideIcons.plus, size: 15), label: Text('Add proof/slip${_slipGroups.isNotEmpty ? ' (${_slipGroups.length})' : ''}'),
            ),
          const Spacer(),
          FilledButton(onPressed: _busy ? null : _askSaveDay, child: Text(_busy ? 'Saving…' : 'Save all · ${_dayList.length} sale${_dayList.length == 1 ? '' : 's'}')),
        ]),
      ]),
    );
  }

  Future<void> _previewDay(int i) async {
    final x = _dayList[i];
    final v = viewOf(x);
    final id = '${x['id']}';
    final a = await showModal<String>(context, title: '${v['name']} · ${dateText(v['date'])}',
        body: (_) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final r in jl(v['rows']))
                Row(children: [Expanded(child: Text('${r['product']}', style: const TextStyle(fontSize: Fs.sm))), PlHelp(r['qty'] != null ? '${qtyText(n(r['qty']))} ${r['unit']}  ' : ''), Text(formatAmount(n(r['amount'])))]),
              const Divider(),
              Row(children: [const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700))), Text(money(n(v['total'])), style: const TextStyle(fontWeight: FontWeight.w700))]),
              const SizedBox(height: 6),
              n(v['paid']) > 0
                  ? Text('Paid ${money(n(v['paid']))} into ${v['acc']}${n(v['paid']) < n(v['total']) - 0.01 ? ' · ${money(r2(n(v['total']) - n(v['paid'])))} not paid' : ''}')
                  : const Text('Not paid', style: TextStyle(color: C.warning)),
              PlHelp([
                if ((_dayFiles[id]?.proofs ?? []).isNotEmpty) 'proof added',
                if (groupOf(id) >= 0) 'shared slip',
                if (n(v['proofs']) > 0 && _dayFiles[id] == null) 'proof lost — add it again',
              ].join(' · ')),
            ]),
        footer: (ctx) => Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
              TextButton.icon(onPressed: () => Navigator.pop(ctx, 'remove'), icon: const Icon(LucideIcons.trash2, size: 15), label: const Text('Remove')),
              if (n(v['paid']) > 0) OutlinedButton.icon(onPressed: () => Navigator.pop(ctx, 'slip'), icon: const Icon(LucideIcons.paperclip, size: 15), label: const Text('Proof/slip')),
              FilledButton.icon(onPressed: () => Navigator.pop(ctx, 'edit'), icon: const Icon(LucideIcons.pencil, size: 15), label: const Text('Edit')),
            ]));
    if (!mounted) return;
    if (a == 'remove') setState(() => _removeDay(i));
    if (a == 'edit') _editDay(i);
    if (a == 'slip') _slipFor({id});
  }
}

/// Save all: every sale shown first — items, payments, proofs — saved only on Confirm (2026-11-11)
class _CheckDay extends StatelessWidget {
  const _CheckDay({required this.list, required this.files, required this.groups, required this.accounts, required this.date});
  final List<Json> list;
  final Map<String, ({List<PayProof> proofs, String buyer, Map<int, PayProof> raw})> files;
  final List<({List<String> ids, PayProof slip})> groups;
  final List<Json> accounts;
  final String date;

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final lost = list.where((x) => n(x['view']['proofs']) > 0 && files['${x['id']}'] == null).toList();
    final total = r2(list.fold<double>(0, (s, x) => s + n(x['view']['total'])));
    return FullPage(
      title: 'Save ${list.length} sale${list.length == 1 ? '' : 's'} · ${dateText(date)}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context, false), child: const Text('Back to the list')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Confirm and save')),
      ],
      children: [
        const PlHelp('Check each sale. Nothing is saved until you confirm.'),
        if (lost.isNotEmpty) Alert('The proof of ${lost.map((x) => x['view']['name']).join(', ')} is no longer here. Go back and add it again, or save and add it later in Slips.', tone: Tone.warning),
        const SizedBox(height: 6),
        for (final x in list)
          () {
            final v = x['view'] as Map;
            final id = '${x['id']}';
            final g = groups.indexWhere((gr) => gr.ids.contains(id));
            final own = files[id]?.proofs ?? const <PayProof>[];
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${v['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                for (final r in jl(v['rows'])) PlHelp('${r['product']}${r['qty'] != null ? ' · ${qtyText(n(r['qty']))} ${r['unit']}' : ''} · ${formatAmount(n(r['amount']))}'),
                n(v['paid']) > 0
                    ? PlHelp('${v['acc']} · ${formatAmount(n(v['paid']))}${n(v['paid']) < n(v['total']) - 0.01 ? ' · ${formatAmount(r2(n(v['total']) - n(v['paid'])))} not paid' : ''}')
                    : const PlHelp('Not paid', color: C.warning),
                PlHelp([
                  if (own.isNotEmpty) own.any((p) => p.file != null) ? 'photo' : 'SMS',
                  if (g >= 0) 'shared ${groups[g].slip.file != null ? 'slip' : 'SMS'}${groups.length > 1 ? ' ${g + 1}' : ''}',
                  if (n(v['proofs']) > 0 && files[id] == null) 'Lost — add again',
                  if (own.isEmpty && g < 0 && !(n(v['proofs']) > 0) && n(v['paid']) > 0) 'No proof',
                ].join(' · '), color: own.isEmpty && g < 0 && n(v['paid']) > 0 ? C.warning : null),
              ]),
            );
          }(),
        const SizedBox(height: 8),
        Text('Total ${formatMoney(total, session.currency)} · ${list.length} sale${list.length == 1 ? '' : 's'}', style: const TextStyle(fontWeight: FontWeight.w700)),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
