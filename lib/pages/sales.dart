import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/sales.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import 'deliveries.dart';
import 'payment_proofs.dart';
import 'reports.dart' show ReportSheet, RCell;
import 'sale_editor.dart';
import 'sale_view.dart';
import 'sales_settings.dart';

/*
 * Sales — a port of web pages/Sales.jsx (1e, 064–141; approved for the phone 2026-11-26). One document moving
 * Note → Quotation → Order → Invoice (or cancelled). The menu shows it twice: Sales (Sales book · Slips ·
 * Deliveries · Overview) and Invoices (the pipeline: Notes · Quotations · Orders · Invoices). Record sale opens
 * full screen; a sale opens as its own screen (payments, proofs, goods leaving, corrections). Online only;
 * the figures are worked out in the database.
 */
class SalesPage extends StatefulWidget {
  const SalesPage({super.key, this.query = const {}});
  final Map<String, String> query;
  @override
  State<SalesPage> createState() => _SalesPageState();
}

class _SalesPageState extends State<SalesPage> {
  Refs? _refs;
  List<Json>? _sales;
  List<Json> _customers = [], _accounts = [];
  Map<String, Json> _proofs = {};
  Map<String, List<ProdRow>> _prod = {};
  String _error = '', _search = '', _pipe = 'order';
  String? _view;
  Json? _upload; // { at, sales } — sales typed from an uploaded sales book
  bool _openedFromQuery = false;

  String get branchId => session.branchId;
  String get today => session.today;
  String get view => _view ?? widget.query['tab'] ?? 'book';
  bool get onInvoices => view == 'list';
  bool get canSell => branchId.isNotEmpty && session.canAt('sales.create', branchId, null);
  String get uploadKey => 'mois.upload.sales.${session.organization?['id']}.$branchId';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SalesPage old) {
    super.didUpdateWidget(old);
    if (old.query['tab'] != widget.query['tab']) _view = null;
  }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final r = await Future.wait<dynamic>([
        Refs.load(),
        db.from('sales').select('*, lines:sale_lines(*), payments:sale_payments(*), deliveries:sale_deliveries(*, lines:sale_delivery_lines(*)), corrections:sale_corrections(*)')
            .order('sale_date', ascending: false).order('sale_no', ascending: false).limit(500),
        db.from('customers').select('*').order('name', ascending: true),
        db.from('payment_accounts').select('*').order('display_order', ascending: true).order('name', ascending: true),
        loadProofs().catchError((_) => <String, Json>{}),
      ]);
      final sales = jl(r[1]);
      final prod = await loadSaleProduction([for (final x in sales) if (x['stage'] == 'order' || x['stage'] == 'invoice') '${x['id']}']);
      if (!mounted) return;
      setState(() {
        _refs = r[0] as Refs;
        _sales = sales;
        _customers = jl(r[2]);
        _accounts = jl(r[3]);
        _proofs = r[4] as Map<String, Json>;
        _prod = prod;
      });
      await _readUpload();
      // opened on one sale (?sale=, from the Director view or Slips)
      final id = widget.query['sale'];
      if (!_openedFromQuery && id != null && sales.any((x) => x['id'] == id)) { _openedFromQuery = true; _openSale(id); }
      // opened from a lead (Customers › Leads › Make quotation, 095): a new quotation for its customer
      final cid = widget.query['quote_for'];
      if (!_openedFromQuery && cid != null && _customers.any((c) => c['id'] == cid)) { _openedFromQuery = true; _quoteForLead(cid, widget.query['lead']); }
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load sales. Please try again.");
    }
  }

  Future<void> _quoteForLead(String cid, String? leadId) async {
    Json? lead;
    try { if (leadId != null) lead = await db.from('leads').select('site, interest').eq('id', leadId).maybeSingle(); } catch (_) {}
    if (!mounted) return;
    final id = await _edit(prefill: {'customer_id': cid, 'site': lead?['site'] ?? '', 'notes': lead?['interest'] != null ? 'Enquiry: ${lead!['interest']}' : ''});
    if (id == null || id.isEmpty) return;
    // the lead points to its quotation and is quoted
    if (leadId != null) { try { await db.from('leads').update({'sale_id': id, 'stage': 'quoted'}).eq('id', leadId); } catch (_) {} }
    await _load();
    _openSale(id);
  }

  // ---- sales typed from an uploaded sales book: each opens in Record sale in turn ----
  Future<void> _readUpload() async {
    if (!canSell) return;
    try {
      final p = await SharedPreferences.getInstance();
      final q = jsonDecode(p.getString(uploadKey) ?? 'null') as Map?;
      final list = q?['sales'] as List? ?? [];
      final at = n(q?['at']).toInt();
      if (list.isEmpty || at >= list.length) { setState(() => _upload = null); return; }
      final first = _upload == null;
      setState(() { _upload = Map<String, dynamic>.from(q!); _view = 'book'; });
      if (first) _openUpload();
    } catch (_) {}
  }

  Future<void> _storeUpload(Json? q) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (q == null) {
        await p.remove(uploadKey);
      } else {
        await p.setString(uploadKey, jsonEncode(q));
      }
    } catch (_) {}
  }

  Json? _stepUpload() {
    final u = _upload;
    if (u == null) return null;
    final q = {...u, 'at': n(u['at']).toInt() + 1};
    if (q['at'] >= (q['sales'] as List).length) { _storeUpload(null); setState(() => _upload = null); return null; }
    _storeUpload(q);
    setState(() => _upload = q);
    return q;
  }

  Future<void> _openUpload() async {
    final u = _upload;
    if (u == null) return;
    final at = n(u['at']).toInt();
    final saved = await _edit(book: true, prefill: Map<String, dynamic>.from((u['sales'] as List)[at] as Map));
    if (saved != null) {
      await _load();
      if (_stepUpload() != null && mounted) _openUpload();
    }
  }

  String buyerOf(Json s) => '${_customers.where((c) => c['id'] == s['customer_id']).firstOrNull?['name'] ?? s['walk_in_name'] ?? 'Walk-in'}';

  /// what sells most at the branch (last 90 days) — the product picker lists it first
  Map<String, int> get soldCount {
    final since = iso(DateTime.parse(today).subtract(const Duration(days: 90)));
    final c = <String, int>{};
    for (final x in _sales ?? <Json>[]) {
      if (x['branch_id'] != branchId || ['note', 'quotation', 'cancelled'].contains(x['stage']) || '${x['sale_date']}'.compareTo(since) < 0) continue;
      for (final l in jl(x['lines'])) { if (l['product_id'] != null) c['${l['product_id']}'] = (c['${l['product_id']}'] ?? 0) + 1; }
    }
    return c;
  }

  /// walk-in buyers seen before: one entry a phone (digits), else a name — with how many sales
  List<WalkIn> get walkIns {
    final m = <String, WalkIn>{};
    for (final x in _sales ?? <Json>[]) {
      if (x['customer_id'] != null || x['stage'] == 'cancelled' || (x['walk_in_name'] == null && x['walk_in_phone'] == null)) continue;
      final digits = '${x['walk_in_phone'] ?? ''}'.replaceAll(RegExp(r'\D'), '');
      final k = digits.isNotEmpty ? digits : 'n:${'${x['walk_in_name'] ?? ''}'.trim().toLowerCase()}';
      final e = m.putIfAbsent(k, () => WalkIn(k, '${x['walk_in_name'] ?? ''}', '${x['walk_in_phone'] ?? ''}', '${x['site'] ?? ''}'));
      e.count++;
      if (e.name.isEmpty && x['walk_in_name'] != null) e.name = '${x['walk_in_name']}';
    }
    return m.values.toList()..sort((a, b) => b.count - a.count);
  }

  /// opens Record sale / a quotation / a note / an edit; returns the saved sale id ('' for the day's list)
  Future<String?> _edit({Json? sale, bool book = false, bool note = false, Json? prefill}) {
    final br = '${sale?['branch_id'] ?? branchId}';
    return Navigator.push<String>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => SaleEditor(
          sale: sale, prefill: prefill, note: note, book: book, sold: soldCount, walkIns: walkIns,
          accounts: _accounts.where((a) => a['branch_id'] == br).toList(), branchId: br, refs: _refs!, customers: _customers,
          canDiscount: session.canAt('sales.discount', br, null), canOther: session.canAt('sales.other_items', br, null),
        )));
  }

  Future<void> _new({bool book = false, bool note = false}) async {
    final id = await _edit(book: book, note: note);
    if (id == null) return;
    await _load();
    if (id.isNotEmpty) _openSale(id);
  }

  Future<void> _openSale(String id) async {
    final s = _sales?.where((x) => x['id'] == id).firstOrNull;
    if (s == null || _refs == null) return;
    await Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => SaleView(
          saleId: id, refs: _refs!,
          initial: (sale: s, production: _prod[id] ?? <ProdRow>[], proofs: _proofs),
          reload: () async { await _load(); return (sale: _sales?.where((x) => x['id'] == id).firstOrNull, production: _prod[id] ?? <ProdRow>[], proofs: _proofs); },
          accounts: _accounts.where((a) => a['branch_id'] == s['branch_id']).toList(),
          buyerOf: buyerOf, customerOf: (cid) => _customers.where((c) => c['id'] == cid).firstOrNull,
          onEdit: (sale) => _edit(sale: sale),
        )));
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final refs = _refs;
    if (_error.isNotEmpty && refs == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    if (refs == null || _sales == null) return ListView(padding: const EdgeInsets.all(14), children: const [Skeleton(rows: 6)]);
    final here = _sales!.where((x) => session.inBranch(x['branch_id'])).toList();

    final header = <Widget>[
      Row(children: [
        Expanded(child: PlHelp(branchId.isNotEmpty ? (session.branchName ?? '') : 'All branches')),
        // ⚙ beside the heading, as on the web: payment terms and receiving accounts
        IconButton(tooltip: 'Sales settings', visualDensity: VisualDensity.compact, icon: const Icon(LucideIcons.settings, size: 18),
            onPressed: () async { await openSalesSettings(context); _load(); }),
      ]),
      if (!onInvoices)
        PageTabs<String>(
          tabs: const [('book', 'Sales book'), ('receipts', 'Slips'), ('deliveries', 'Deliveries'), ('overview', 'Overview')],
          value: view, onChange: (v) => setState(() => _view = v),
        ),
      if (_upload != null)
        Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: BoxDecoration(color: context.tk.bgInfo, borderRadius: BorderRadius.circular(8)),
          child: Row(children: [
            Expanded(child: Text('Uploaded sales: ${n(_upload!['at']).toInt() + 1} of ${(_upload!['sales'] as List).length} waiting.', style: const TextStyle(fontSize: Fs.sm))),
            TextButton(onPressed: _openUpload, child: const Text('Continue')),
            TextButton(onPressed: () { if (_stepUpload() != null) _openUpload(); }, child: const Text('Skip')),
            TextButton(onPressed: () { _storeUpload(null); setState(() => _upload = null); }, child: const Text('Stop')),
          ]),
        ),
    ];

    // Slips and Deliveries keep their own lists (and their own refresh)
    if (view == 'receipts' || view == 'deliveries') {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: header)),
        Expanded(
          child: view == 'receipts'
              ? PaymentProofsList(directorView: !canSell && session.canAt('sales.confirm_payments', branchId, null), onOpenSale: (id) => _openSale(id))
              : DeliveriesPanel(canAct: canSell, onChanged: _load),
        ),
      ]);
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: !canSell ? null : onInvoices ? _invoiceFab() : FloatingActionButton.extended(onPressed: () => _new(book: true), icon: const Icon(LucideIcons.plus), label: const Text('Record sale')),
      body: RefreshIndicator(
        onRefresh: () async { await Refs.load(fresh: true); await _load(); },
        child: PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 88), children: [
          ...header,
          if (view == 'book')
            _SalesBook(
              sales: here.where((x) => !['note', 'quotation', 'cancelled'].contains(x['stage'])).toList(), refs: refs,
              accounts: _accounts.where((a) => session.inBranch(a['branch_id'])).toList(), buyerOf: buyerOf, proofs: _proofs, onOpen: _openSale,
              query: widget.query,
            )
          else if (view == 'overview')
            _SalesOverview(sales: here, refs: refs, buyerOf: buyerOf)
          else
            ..._invoices(here, refs),
        ]),
      ),
    );
  }

  Widget _invoiceFab() => FloatingActionButton.extended(
        onPressed: () async {
          final v = await showModalBottomSheet<String>(
            context: context,
            builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
              ListTile(leading: const Icon(LucideIcons.fileText), title: const Text('New quotation'), onTap: () => Navigator.pop(ctx, 'quotation')),
              ListTile(leading: const Icon(LucideIcons.stickyNote), title: const Text('New note'), subtitle: const Text("A customer's wish written down — nothing confirmed yet"), onTap: () => Navigator.pop(ctx, 'note')),
            ])),
          );
          if (v != null) _new(note: v == 'note');
        },
        icon: const Icon(LucideIcons.plus), label: const Text('New'),
      );

  // ---- Invoices: the pipeline ----
  List<Widget> _invoices(List<Json> here, Refs refs) {
    final t = context.tk;
    final q = _search.trim().toLowerCase();
    bool inPipe(Json s) => s['stage'] == _pipe || (s['stage'] == 'cancelled' && s['cancelled_from'] == _pipe);
    final shown = here.where((s) => inPipe(s) && (q.isEmpty || '${s['sale_no']} ${buyerOf(s)} ${s['walk_in_phone'] ?? ''} ${s['efd_receipt_no'] ?? ''}'.toLowerCase().contains(q))).toList();
    final label = salePipe.where((p) => p.$1 == _pipe).first.$2;
    return [
      ListToolbar(placeholder: 'Search number, customer, phone or EFD receipt…', onSearch: (v) => setState(() => _search = v)),
      PageTabs<String>(tabs: [for (final (k, l) in salePipe) (k, '$l (${here.where((x) => x['stage'] == k).length})')], value: _pipe, onChange: (v) => setState(() => _pipe = v)),
      Row(children: [Text('$label (${shown.length})', style: const TextStyle(fontWeight: FontWeight.w700)), const Spacer(), const PlHelp('newest first')]),
      const SizedBox(height: 6),
      if (shown.isEmpty)
        EmptyState(icon: LucideIcons.receipt, title: 'No ${label.toLowerCase()} yet', description: const {
          'note': "A customer's wish written down — New note.", 'quotation': 'Prices offered while you agree — New quotation.',
          'order': 'A confirmed order: made in production if stock is short, delivered as it is paid.', 'invoice': 'Final bills appear here.',
        }[_pipe]!)
      else
        for (final s in shown)
          () {
            final paid = paidOf(s);
            final total = n(s['total']).toDouble();
            final p = productionSummary(_prod['${s['id']}']);
            final overdue = s['due_date'] != null && ['order', 'invoice'].contains(s['stage']) && total - paid > 0.01 && '${s['due_date']}'.compareTo(today) < 0;
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: t.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _openSale('${s['id']}'),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(buyerOf(s), style: const TextStyle(fontWeight: FontWeight.w700)),
                          PlHelp('#${s['sale_no']} · ${dateText(s['sale_date'])}${s['efd_receipt_no'] != null ? ' · EFD ${s['efd_receipt_no']}' : ''}'),
                          if (overdue) PlHelp('overdue since ${dateText(s['due_date'])}', color: C.error),
                        ])),
                        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text(formatMoney(total, session.currency), style: const TextStyle(fontWeight: FontWeight.w700)),
                          PlHelp('${jl(s['lines']).length} line${jl(s['lines']).length == 1 ? '' : 's'}${n(s['vat']) > 0 ? ' · with VAT' : ''}'),
                        ]),
                      ]),
                      const SizedBox(height: 6),
                      Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        Badge2(saleStages[s['stage']] ?? '', tone: saleStageTone[s['stage']] ?? Tone.neutral),
                        if (s['stage'] != 'cancelled')
                          for (final (k, l) in saleWaiting) if ((s['waiting_for'] as List? ?? []).contains(k)) Badge2(l, tone: Tone.warning),
                        if (p != null) PlHelp('made ${qtyText(p.ready)} / ${qtyText(p.planned)} · cast ${qtyText(p.cast)}'),
                        if (s['stage'] == 'order' && total > 0 && paid / total < saleAdvance - 1e-9) PlHelp('under ${(saleAdvance * 100).round()}% paid', color: C.warning),
                        if (!['note', 'cancelled', 'quotation'].contains(s['stage']))
                          PlHelp('paid ${formatMoney(paid, session.currency)}${total - paid > 0.004 ? ' · ${formatMoney(r2(total - paid), session.currency)} owed' : ' · paid in full'}'),
                        if (s['stage'] == 'cancelled') PlHelp('${s['cancel_reason'] ?? ''}'),
                        if (jl(s['deliveries']).isNotEmpty) PlHelp('delivered ${formatMoney(jl(s['deliveries']).fold<double>(0, (t, d) => t + n(d['value'])), session.currency)}'),
                      ]),
                    ]),
                  ),
                ),
              ),
            );
          }(),
    ];
  }
}

class WalkIn {
  WalkIn(this.key, this.name, this.phone, this.site);
  final String key;
  String name, phone, site;
  int count = 0;
}

// ======================= The sales book =======================
class _SalesBook extends StatefulWidget {
  const _SalesBook({required this.sales, required this.refs, required this.accounts, required this.buyerOf, required this.proofs, required this.onOpen, required this.query});
  final List<Json> sales, accounts;
  final Refs refs;
  final String Function(Json) buyerOf;
  final Map<String, Json> proofs;
  final ValueChanged<String> onOpen;
  final Map<String, String> query;
  @override
  State<_SalesBook> createState() => _SalesBookState();
}

class _SalesBookState extends State<_SalesBook> {
  final _rp = RangePeriod('sales-book');
  String _search = '', _sortBy = 'newest', _delivery = '', _payment = '', _account = '', _vat = '';

  @override
  void initState() {
    super.initState();
    // opened from a dashboard card: that card's period (?from=&to=)
    final f = widget.query['from'], to = widget.query['to'];
    if (f != null && to != null) _rp.set('custom', (f, to));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final refs = widget.refs;
    final from = _rp.from, to = _rp.to;
    String accName(Object? id) => '${widget.accounts.where((a) => a['id'] == id).firstOrNull?['name'] ?? ''}';
    final q = _search.trim().toLowerCase();
    bool matches(Json x) => q.isEmpty || [
          '#${x['sale_no']}', '${x['sale_no']}', widget.buyerOf(x), x['walk_in_phone'], x['site'], x['efd_receipt_no'],
          for (final l in jl(x['lines'])) lineName(refs, l),
          for (final pm in jl(x['payments'])) ...[pm['receipt_no'], accName(pm['account_id'])],
        ].where((s) => s != null && '$s'.isNotEmpty).any((s) => '$s'.toLowerCase().contains(q));
    bool lineOk(Json x, Json l) => (_delivery.isEmpty || goodsStateOf(x, l) == _delivery) && (_vat.isEmpty || (_vat == 'with') == (n(l['vat_rate']) > 0));
    final inPeriod = widget.sales.where((x) =>
        '${x['sale_date']}'.compareTo(from) >= 0 && '${x['sale_date']}'.compareTo(to) <= 0 && matches(x) &&
        (_payment.isEmpty || (_payment == 'owed') == (n(x['total']) - paidOf(x) > 0.004)) &&
        (_account.isEmpty || jl(x['payments']).any((pm) => pm['account_id'] == _account)) &&
        jl(x['lines']).any((l) => lineOk(x, l))).toList()
      ..sort((a, b) {
        if (_sortBy == 'amount') { final c = n(b['total']).compareTo(n(a['total'])); if (c != 0) return c; }
        if (_sortBy == 'oldest') { final c = '${a['sale_date']}'.compareTo('${b['sale_date']}'); return c != 0 ? c : n(a['sale_no']).compareTo(n(b['sale_no'])); }
        final c = '${b['sale_date']}'.compareTo('${a['sale_date']}');
        return c != 0 ? c : n(b['sale_no']).compareTo(n(a['sale_no']));
      });
    String slips(Json x) => [for (final pm in jl(x['payments'])) if (pm['receipt_no'] != null && '${pm['receipt_no']}'.isNotEmpty) '${pm['receipt_no']}'].join(', ');
    final lineRows = [for (final x in inPeriod) for (final l in jl(x['lines']).where((l) => lineOk(x, l))) l];
    final total = lineRows.fold<double>(0, (s, l) => s + n(l['total']));
    final vat = lineRows.fold<double>(0, (s, l) => s + (n(l['vat_rate']) > 0 ? n(l['vat']) : 0));
    final paid = inPeriod.fold<double>(0, (s, x) => s + paidOf(x));
    final owed = inPeriod.fold<double>(0, (s, x) => s + (n(x['total']) - paidOf(x) > 0.004 ? n(x['total']) - paidOf(x) : 0));
    String money(num v) => formatMoneyShort(v, session.currency);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Stats([
        Stat('Sold', money(r2(total)), help: '${inPeriod.length} sale${inPeriod.length == 1 ? '' : 's'} · VAT ${money(r2(vat))}'),
        Stat('Paid', money(r2(paid)), help: 'into the accounts'),
        Stat('Owed', money(r2(owed)), figureColor: owed > 0.004 ? C.warning : null, help: 'on these sales'),
      ]),
      _rp.bar(context, () => setState(() {})),
      const SizedBox(height: 8),
      ListToolbar(
        placeholder: 'Search customer, item, site, receipt no., account, phone or #…',
        onSearch: (v) => setState(() => _search = v),
        sort: SortSpec(value: _sortBy, onChange: (v) => setState(() => _sortBy = v), options: const [('newest', 'Newest first'), ('oldest', 'Oldest first'), ('amount', 'Largest sale first')]),
        filters: [
          FilterSpec(key: 'delivery', label: 'Goods', value: _delivery, onChange: (v) => setState(() => _delivery = v),
              options: const [('', 'All'), ('not', 'Not collected'), ('part', 'Part collected'), ('collected', 'Collected'), ('done', 'Delivered')]),
          FilterSpec(key: 'payment', label: 'Paid', value: _payment, onChange: (v) => setState(() => _payment = v), options: const [('', 'All'), ('owed', 'Still owed'), ('paid', 'Paid in full')]),
          if (widget.accounts.isNotEmpty)
            FilterSpec(key: 'account', label: 'Account', value: _account, onChange: (v) => setState(() => _account = v), options: [('', 'All accounts'), for (final a in widget.accounts) ('${a['id']}', '${a['name']}')]),
          FilterSpec(key: 'vat', label: 'VAT', value: _vat, onChange: (v) => setState(() => _vat = v), options: const [('', 'All'), ('with', 'With VAT'), ('without', 'Without VAT')]),
        ],
      ),
      if (inPeriod.isEmpty)
        CardBox(child: PlHelp(q.isNotEmpty || _delivery.isNotEmpty || _payment.isNotEmpty || _account.isNotEmpty || _vat.isNotEmpty ? 'Nothing matches — change the search or filters.' : 'No sales in this period.'))
      else
        // one card a sale — items, total, paid, goods (the web's phone layout)
        for (final x in inPeriod)
          () {
            final lines = jl(x['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no'])));
            final shown = lines.where((l) => lineOk(x, l)).toList();
            final p = paidOf(x), ow = r2(n(x['total']) - p);
            final accs = {for (final pm in jl(x['payments'])) accName(pm['account_id']).isNotEmpty ? accName(pm['account_id']) : 'Other'}.join(', ');
            final a = saleApproval(x, widget.proofs, session.today);
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: t.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => widget.onOpen('${x['id']}'),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Row(children: [
                        Expanded(child: PlHelp('${tableDate(x['sale_date'])} · #${x['sale_no']}')),
                        Text(formatAmount(n(x['total'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                      ]),
                      Text.rich(TextSpan(children: [
                        TextSpan(text: widget.buyerOf(x), style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (x['site'] != null && '${x['site']}'.isNotEmpty) TextSpan(text: ' · ${x['site']}', style: TextStyle(fontSize: Fs.sm, color: t.textSecondary)),
                      ])),
                      const SizedBox(height: 4),
                      for (final l in shown)
                        () {
                          final st = goodsStateOf(x, l);
                          final out = st == 'done' || st == 'collected';
                          return Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Expanded(child: Text.rich(TextSpan(style: const TextStyle(fontSize: Fs.sm), children: [
                                TextSpan(text: lineName(refs, l)),
                                if (l['product_id'] != null) ...[
                                  TextSpan(text: ' · ${qtyText(n(l['quantity']))} ', style: TextStyle(color: t.textSecondary)),
                                  // the unit red until the goods have all left (2026-11-19)
                                  TextSpan(text: perOf(refs, l['product_id']), style: TextStyle(color: out ? t.textSecondary : C.error, fontWeight: out ? null : FontWeight.w600)),
                                  TextSpan(text: ' × ${formatAmount(r2(n(l['total']) / n(l['quantity'])))}', style: TextStyle(color: t.textSecondary)),
                                  if (!out) TextSpan(text: st == 'part' ? '  Part — ${qtyText(r2(doneOf(x, l['id'])))} left' : '  Not collected', style: TextStyle(color: st == 'part' ? C.warning : C.error, fontSize: Fs.xs, fontWeight: FontWeight.w600)),
                                ] else
                                  TextSpan(text: ' · other item', style: TextStyle(color: t.textSecondary)),
                              ]))),
                              Text(formatAmount(n(l['total'])), style: const TextStyle(fontSize: Fs.sm)),
                            ]),
                          );
                        }(),
                      const SizedBox(height: 4),
                      Row(children: [
                        Expanded(child: PlHelp('${p > 0 ? 'Paid ${formatAmount(r2(p))}${accs.isNotEmpty ? ' · $accs' : ''}' : 'Not paid'}${slips(x).isNotEmpty ? ' · ${slips(x)}' : ''}')),
                        if (ow > 0.004) Text('Owes ${formatAmount(ow)}', style: const TextStyle(fontSize: Fs.sm, color: C.warning, fontWeight: FontWeight.w600)),
                      ]),
                      if (['proof', 'waiting'].contains(a.state) || (n(x['vat']) > 0 && x['efd_receipt_no'] == null))
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Wrap(spacing: 4, children: [
                            if (['proof', 'waiting'].contains(a.state)) Badge2(a.label, tone: a.tone),
                            if (n(x['vat']) > 0 && x['efd_receipt_no'] == null) const Badge2('EFD to fill', tone: Tone.warning),
                          ]),
                        ),
                    ]),
                  ),
                ),
              ),
            );
          }(),
      if (lineRows.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(spacing: 12, children: [
            Text('Total ${formatMoney(r2(total), session.currency)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            PlHelp('VAT ${formatMoney(r2(vat), session.currency)}'),
            PlHelp('Paid ${formatMoney(r2(paid), session.currency)}'),
          ]),
        ),
    ]);
  }
}

// ======================= Overview =======================
class _SalesOverview extends StatefulWidget {
  const _SalesOverview({required this.sales, required this.refs, required this.buyerOf});
  final List<Json> sales;
  final Refs refs;
  final String Function(Json) buyerOf;
  @override
  State<_SalesOverview> createState() => _SalesOverviewState();
}

class _SalesOverviewState extends State<_SalesOverview> {
  final _rp = RangePeriod('sales-overview');

  @override
  Widget build(BuildContext context) {
    final refs = widget.refs;
    final from = _rp.from, to = _rp.to;
    bool inP(Object? d) => '$d'.compareTo(from) >= 0 && '$d'.compareTo(to) <= 0;
    final live = widget.sales.where((x) => x['stage'] == 'order' || x['stage'] == 'invoice').toList();
    final sold = live.where((x) => inP(x['sale_date'])).toList();
    final payments = [for (final x in live) for (final pm in jl(x['payments'])) if (inP(pm['paid_on'])) {...pm, 'sale': x}];
    final deliveries = [for (final x in live) for (final d in jl(x['deliveries'])) if (inP(d['delivered_on'])) {...d, 'sale': x}];
    final owed = live.fold<double>(0, (t, x) => t + n(x['total']) - paidOf(x));
    final lineOf = {for (final x in live) for (final l in jl(x['lines'])) '${l['id']}': l};
    final dl = [for (final d in deliveries) for (final x in jl(d['lines'])) {...x, 'line': lineOf['${x['sale_line_id']}'], 'sale': d['sale']}];
    double exOf(Json x) => n(x['value']) / (1 + n((x['line'] as Json?)?['vat_rate']) / 100);
    final dValue = deliveries.fold<double>(0, (t, d) => t + n(d['value']));
    final dEx = dl.fold<double>(0, (t, x) => t + exOf(x));
    final dCost = dl.fold<double>(0, (t, x) => t + n(x['cost']));
    final dEst = dl.fold<double>(0, (t, x) => t + n(x['estimated_cost']));
    final queued = widget.sales.where((x) => x['stage'] == 'quotation' && inP(x['sale_date'])).toList();
    String money(num v) => formatMoney(v, session.currency);

    // by product: sold, delivered, margin on delivered
    final byProduct = <String, Map<String, dynamic>>{};
    Map<String, dynamic> prow(Json l) => byProduct.putIfAbsent(
        l['product_id'] != null ? '${l['product_id']}|${l['color_id'] ?? ''}' : 'other|${'${l['item_name'] ?? ''}'.trim().toLowerCase()}',
        () => {'name': l['product_id'] != null ? lineName(refs, l) : '${l['item_name']} (other item)', 'unit': l['product_id'] == null ? '' : perOf(refs, l['product_id']), 'qty': 0.0, 'value': 0.0, 'dqty': 0.0, 'ex': 0.0, 'cost': 0.0, 'est': 0.0});
    for (final x in sold) {
      for (final l in jl(x['lines'])) { final pr = prow(l); pr['qty'] += n(l['quantity']); pr['value'] += n(l['total']); }
    }
    for (final x in dl) {
      final line = x['line'] as Json?;
      if (line == null) continue;
      final pr = prow(line);
      pr['dqty'] += n(x['quantity']); pr['ex'] += exOf(x); pr['cost'] += n(x['cost']); pr['est'] += n(x['estimated_cost']);
    }
    // by customer: sold, paid, owed (all open)
    final byCustomer = <String, Map<String, dynamic>>{};
    Map<String, dynamic> crow(Json x) => byCustomer.putIfAbsent('${x['customer_id'] ?? 'walk:${x['walk_in_name'] ?? ''}'}', () => {'name': widget.buyerOf(x), 'sold': 0.0, 'paid': 0.0, 'owed': 0.0});
    for (final x in sold) { crow(x)['sold'] += n(x['total']); }
    for (final pm in payments) { crow(pm['sale'] as Json)['paid'] += n(pm['amount']); }
    for (final x in live) { final o = n(x['total']) - paidOf(x); if (o > 0.004) crow(x)['owed'] += o; }
    String pct(double a, double b) => b > 0 ? ' · ${(a / b * 100).round()}%' : '';
    final prods = byProduct.values.toList()..sort((a, b) => (b['value'] as double).compareTo(a['value'] as double));
    final custs = byCustomer.values.toList()..sort((a, b) { final c = (b['sold'] as double).compareTo(a['sold'] as double); return c != 0 ? c : (b['owed'] as double).compareTo(a['owed'] as double); });

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Stats([
        Stat('Sold', formatMoneyShort(sold.fold<double>(0, (t, x) => t + n(x['total'])), session.currency), help: '${sold.length} sale${sold.length == 1 ? '' : 's'} · with VAT'),
        Stat('Paid in', formatMoneyShort(payments.fold<double>(0, (t, p) => t + n(p['amount'])), session.currency), help: '${payments.length} payment${payments.length == 1 ? '' : 's'}'),
        Stat('Owed now', formatMoneyShort(owed > 0 ? owed : 0, session.currency), figureColor: owed > 0.004 ? C.warning : null, help: 'open orders & invoices'),
        Stat('Delivered', formatMoneyShort(dValue, session.currency), help: 'margin ${formatMoneyShort(dEx - dCost, session.currency)}${pct(dEx - dCost, dEx)}${dEst > 0.5 ? ' · est.' : ''}'),
      ]),
      _rp.bar(context, () => setState(() {})),
      if (queued.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: PlHelp('${queued.length} quotation${queued.length == 1 ? '' : 's'} not ordered · ${money(queued.fold<double>(0, (t, x) => t + n(x['total'])))}')),
      const SectionTitle('By product'),
      if (prods.isEmpty)
        const PlHelp('Nothing sold in this period.')
      else
        ReportSheet(
          firstWidth: 150,
          head: const ['Product', 'Sold', 'Value (TZS)', 'Delivered', 'Margin (TZS)'],
          rows: [
            for (final x in prods)
              [
                '${x['name']}', '${qtyText(r2(x['qty']))} ${x['unit']}', formatAmount(r2(x['value'])),
                x['dqty'] > 0 ? '${qtyText(r2(x['dqty']))} ${x['unit']}' : '—',
                x['dqty'] > 0 ? RCell(formatAmount(r2(x['ex'] - x['cost'])), sub: x['est'] > 0.5 ? 'cost partly estimated' : null) : '—',
              ],
          ],
        ),
      const SectionTitle('By customer'),
      if (custs.isEmpty)
        const PlHelp('No customers in this period.')
      else
        ReportSheet(
          firstWidth: 150,
          head: const ['Customer', 'Sold (TZS)', 'Paid (TZS)', 'Owed now (TZS)'],
          rows: [
            for (final x in custs)
              ['${x['name']}', formatAmount(r2(x['sold'])), formatAmount(r2(x['paid'])), x['owed'] > 0.004 ? RCell(formatAmount(r2(x['owed'])), warn: true) : '—'],
          ],
        ),
    ]);
  }
}
