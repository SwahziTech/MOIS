import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/pdf_doc.dart';
import '../core/sales.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../docs/sale_doc.dart';
import '../shell.dart';
import 'deliveries.dart' show confirmDelivery;
import 'payment_proofs.dart';
import 'procurement_actions.dart' show DateField;

/*
 * One sale — a port of web pages/Sales.jsx SaleView, DeliveryModal, CorrectModal and components/sales/
 * SaleProduction.jsx. Status, not stage (2026-11-19): is it paid, have the goods left? Lines with what is short;
 * waiting-for and the production made for it (141); payments with their proofs (105); goods leaving (065/136/139)
 * and delivery notes; EFD; corrections (068). One Next button for the sale's next step, the rest under More.
 */
typedef SaleData = ({Json? sale, List<ProdRow> production, Map<String, Json> proofs});

class SaleView extends StatefulWidget {
  const SaleView({super.key, required this.saleId, required this.refs, required this.initial, required this.reload, required this.accounts,
      required this.buyerOf, required this.customerOf, required this.onEdit});
  final String saleId;
  final Refs refs;
  final SaleData initial;
  final Future<SaleData> Function() reload;
  final List<Json> accounts;
  final String Function(Json) buyerOf;
  final Json? Function(Object?) customerOf;
  final Future<String?> Function(Json sale) onEdit;
  @override
  State<SaleView> createState() => _SaleViewState();
}

class _SaleViewState extends State<SaleView> {
  late SaleData _d = widget.initial;
  Map<String, double>? _free; // product|colour → available (this sale's own hold given back)
  bool _busy = false;
  String _error = '';
  late final _efd = TextEditingController(text: '${_d.sale?['efd_receipt_no'] ?? ''}');

  Refs get refs => widget.refs;
  Json get sale => _d.sale!;
  String get br => '${sale['branch_id']}';
  String get today => session.today;
  String money(num v) => formatMoney(v, session.currency);
  String accountName(Object? id) => '${widget.accounts.where((a) => a['id'] == id).firstOrNull?['name'] ?? ''}';
  List<Json> get lines => jl(sale['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no'])));
  double get paid => paidOf(sale);
  double get owed => r2(n(sale['total']) - paid);
  bool get live => ['order', 'invoice'].contains(sale['stage']);
  bool get goodsLeft => lines.any((l) => l['product_id'] != null && n(l['quantity']) - doneOf(sale, l['id']) > 1e-9);

  @override
  void initState() {
    super.initState();
    _efd.addListener(() => setState(() {}));
    _loadFree();
  }

  Future<void> _refresh() async {
    final d = await widget.reload();
    if (!mounted) return;
    if (d.sale == null) { Navigator.pop(context); return; }
    setState(() => _d = d);
    _loadFree();
  }

  double inProd(Json l) => _d.production.where((r) => belongsTo(r, l, sale) && r.order['status'] == 'open').fold(0.0, (t, r) => t + math.max(n(r.line['pieces']) - n(r.progress?['passed']), 0));

  /// short of stock (2026-11-22): under each product, what is still to make — before it leaves
  Future<void> _loadFree() async {
    if (!['note', 'quotation', 'order', 'invoice'].contains(sale['stage']) || !goodsLeft) { setState(() => _free = null); return; }
    try {
      final data = jl(await db.rpc('sales_availability', params: {'p_branch_id': br, if (sale['warehouse_id'] != null) 'p_warehouse_id': sale['warehouse_id']}));
      final m = {for (final x in data) '${x['product_id']}|${x['color_id'] ?? ''}': n(x['available']).toDouble()};
      // this order's own hold given back: what is left to collect less what its open production still makes (141)
      if (live) {
        for (final l in lines.where((l) => l['product_id'] != null)) {
          final k = '${l['product_id']}|${l['color_id'] ?? ''}';
          m[k] = (m[k] ?? 0) + math.max(n(l['quantity']) - doneOf(sale, l['id']) - inProd(l), 0);
        }
      }
      if (mounted) setState(() => _free = m);
    } catch (_) {}
  }

  double shortOf(Json l) {
    if (_free == null || l['product_id'] == null) return 0;
    final left = math.max(n(l['quantity']) - doneOf(sale, l['id']), 0.0);
    return math.max(left - math.max(_free!['${l['product_id']}|${l['color_id'] ?? ''}'] ?? 0, 0.0), 0.0);
  }

  Future<bool> _run(Future<dynamic> Function() fn) async {
    setState(() { _error = ''; _busy = true; });
    try {
      await fn();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = dbError(e); });
      return false;
    }
    if (mounted) setState(() => _busy = false);
    await _refresh();
    return true;
  }

  Future<bool> toStage(String stage, [Json p = const {}]) => _run(() => db.rpc('set_sale_stage', params: {'p_sale': sale['id'], 'p_stage': stage, 'p': p}));
  void _doc(String doc, {String? paymentId, String? deliveryId}) =>
      openDoc(context, '${doc[0].toUpperCase()}${doc.substring(1)} #${sale['sale_no']}${paymentId != null ? ' · ${paymentId.substring(0, 6)}' : ''}${deliveryId != null ? ' · ${deliveryId.substring(0, 6)}' : ''}',
          () => saleDocPdf('${sale['id']}', doc, paymentId: paymentId, deliveryId: deliveryId));

  Future<String?> _ask(String title, String label, {String text = '', String ok = 'Save', bool required = true}) {
    final c = TextEditingController(text: text);
    return showDialog<String>(context: context, builder: (ctx) => StatefulBuilder(builder: (ctx, set) => AlertDialog(
          title: Text(title),
          content: TextField(controller: c, autofocus: true, onChanged: (_) => set(() {}), decoration: InputDecoration(labelText: label)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back')),
            FilledButton(onPressed: required && c.text.trim().isEmpty ? null : () => Navigator.pop(ctx, c.text), child: Text(ok)),
          ],
        )));
  }

  Future<void> _pay() async {
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _PayWindow(sale: sale, refs: refs, owed: owed, accounts: widget.accounts.where((a) => a['status'] == 'active').toList())));
    if (ok == true) _refresh();
  }

  Future<void> _hand() async {
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _Delivery(sale: sale, refs: refs, canLeave: r2(math.max(paid - given, 0)))));
    if (ok == true) _refresh();
  }

  /// other items (104) were handed over with the sale
  double get given => jl(sale['deliveries']).fold<double>(0, (t, d) => t + n(d['value'])) + lines.where((l) => l['product_id'] == null).fold<double>(0, (t, l) => t + n(l['total']));

  Future<void> _invoice() async {
    final efd = await showDialog<String>(context: context, builder: (ctx) {
      final c = TextEditingController(text: _efd.text);
      return AlertDialog(
        title: Text('Invoice #${sale['sale_no']}'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('The lines and prices are fixed once invoiced.'),
          const SizedBox(height: 8),
          TextField(controller: c, autofocus: true, decoration: const InputDecoration(labelText: 'EFD receipt number (optional — can be added later)')),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back')), FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text('Invoice ${money(n(sale['total']))}'))],
      );
    });
    if (efd != null) toStage('invoice', {'efd_receipt_no': efd});
  }

  Future<void> _make() async {
    final id = await Navigator.push<Object>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _Make(sale: sale, refs: refs, rows: _d.production, paid: paid, needOf: shortOf)));
    if (id == null || !mounted) return;
    await _refresh();
    _sentToPlanner();
  }

  void _sentToPlanner() => showDialog<void>(context: context, builder: (ctx) => AlertDialog(
        title: const Text('Sent to the Planner'),
        content: const Text('A production order was made for this order. Its progress shows here as batches are cast against it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Stay here')),
          FilledButton.icon(onPressed: () { final shell = Shell.of(context); Navigator.pop(ctx); Navigator.pop(context); shell.go('/production?tab=planner'); }, icon: const Icon(LucideIcons.calendarClock, size: 15), label: const Text('Go to the Planner')),
        ],
      ));

  Future<void> _correct() async {
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _Correct(sale: sale, refs: refs, accounts: widget.accounts, direct: session.canAt('system.manage', br, null))));
    if (ok == true) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final s = sale;
    final stage = '${s['stage']}';
    final buyer = widget.buyerOf(s);
    final customer = widget.customerOf(s['customer_id']);
    final deliveries = jl(s['deliveries'])..sort((a, b) => n(b['delivery_no']).compareTo(n(a['delivery_no'])));
    final canSell = session.canAt('sales.create', br, null);
    final editable = ['note', 'quotation', 'order'].contains(stage) && canSell && deliveries.isEmpty;
    final canHand = live && (canSell || session.canAt('inventory.issue', br, null)) && goodsLeft;
    final canPay = live && owed > 0 && session.canAt('payments.record', br, null);
    final shortAny = lines.any((l) => shortOf(l) > 0);
    final payBadge = !live ? null : owed <= 0.01 ? ('Paid', Tone.success) : paid > 0 ? ('Part paid', Tone.warning) : ('Not paid', Tone.error);
    final goodsBadge = !live || !lines.any((l) => l['product_id'] != null)
        ? null
        : deliveries.any((d) => d['status'] == 'on_the_way')
            ? ('On the way', Tone.warning)
            : !goodsLeft
                ? (deliveries.any((d) => d['kind'] == 'delivery') ? 'Delivered' : 'Collected', Tone.success)
                : deliveries.isNotEmpty ? ('Part collected', Tone.warning) : ('Not collected', Tone.error);
    final docOf = const {'quotation': ('quotation', 'Print quotation'), 'order': ('proforma', 'Print proforma'), 'invoice': ('invoice', 'Print invoice')}[stage];
    // in the order a sale goes: note → quotation → order (make what is short, take the advance) → invoice → paid → goods leave
    final steps = <({String key, String label, VoidCallback run, bool danger})>[
      if (stage == 'note' && canSell) (key: 'quote', label: 'Make quotation', run: () => toStage('quotation'), danger: false),
      if (['note', 'quotation'].contains(stage) && canSell) (key: 'order', label: 'Confirm order', run: () => toStage('order'), danger: false),
      if (live && shortAny && !_d.production.any((r) => r.order['status'] == 'open') && session.canAt('production.plan', br, null)) (key: 'make', label: 'Make in production', run: _make, danger: false),
      if (canPay) (key: 'pay', label: 'Record payment', run: _pay, danger: false),
      if (['quotation', 'order'].contains(stage) && session.canAt('invoices.create', br, null)) (key: 'invoice', label: 'Invoice', run: _invoice, danger: false),
      if (canHand) (key: 'hand', label: 'Deliver / collect', run: _hand, danger: false),
    ];
    final next = stage == 'cancelled' ? null : steps.firstOrNull;
    final more = [
      ...steps.where((a) => a != next && a.key != 'pay'),
      if (docOf != null) (key: 'print', label: docOf.$2, run: () => _doc(docOf.$1), danger: false),
      if (stage == 'quotation') (key: 'proforma', label: 'Print proforma', run: () => _doc('proforma'), danger: false),
      if (!editable && stage != 'cancelled' && (session.canAt('system.manage', br, null) || session.canAt('sales.discount', br, null))) (key: 'correct', label: 'Correct…', run: _correct, danger: false),
      if (stage != 'cancelled' && paid == 0 && canSell && (stage != 'invoice' || session.canAt('sales.discount', br, null)))
        (key: 'cancel', label: 'Cancel sale', danger: true, run: () async { final r = await _ask('Cancel #${s['sale_no']}?', 'Why? (required)', ok: 'Cancel the sale'); if (r != null) toStage('cancelled', {'reason': r}); }),
      if (stage == 'cancelled' && paid == 0 && deliveries.isEmpty && canSell)
        (key: 'delete', label: 'Delete', danger: true, run: () async {
          final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
                title: Text('Delete #${s['sale_no']} for good?'),
                content: Text('The cancelled sale to $buyer (${money(n(s['total']))}) is removed from the list. This can\'t be undone.'),
                actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Back')), FilledButton(style: FilledButton.styleFrom(backgroundColor: C.error), onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete'))],
              ));
          if (ok == true && await _run(() => db.rpc('delete_cancelled_sale', params: {'p_id': s['id']})) && context.mounted) Navigator.pop(context);
        }),
    ];
    final cust = customer != null ? ' · ${customer['phone'] ?? ''}${customer['tin'] != null ? ' · TIN ${customer['tin']}' : ''}' : s['walk_in_phone'] != null ? ' · ${s['walk_in_phone']}' : '';
    final overdueDays = s['due_date'] != null && '${s['due_date']}'.compareTo(today) < 0 ? DateTime.parse(today).difference(DateTime.parse('${s['due_date']}')).inDays : 0;

    return FullPage(
      title: '${saleStages[stage]} #${s['sale_no']} — $buyer',
      footer: [
        if (more.isNotEmpty)
          PopupMenuButton<int>(
            enabled: !_busy,
            onSelected: (i) => more[i].run(),
            itemBuilder: (_) => [for (final (i, a) in more.indexed) PopupMenuItem(value: i, child: Text(a.label, style: TextStyle(color: a.danger ? C.error : null)))],
            child: const Padding(padding: EdgeInsets.symmetric(horizontal: 12, vertical: 10), child: Text('More ▾', style: TextStyle(fontWeight: FontWeight.w600))),
          ),
        if (editable) OutlinedButton(onPressed: () async { final id = await widget.onEdit(s); if (id != null) _refresh(); }, child: const Text('Back')),
        if (next != null) FilledButton(onPressed: _busy ? null : next.run, child: Text('Next: ${next.label}')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (live) ...[
            if (payBadge != null) Badge2(payBadge.$1, tone: payBadge.$2),
            if (goodsBadge != null) Badge2(goodsBadge.$1, tone: goodsBadge.$2),
          ] else
            Badge2(saleStages[stage] ?? '', tone: saleStageTone[stage] ?? Tone.neutral),
          PlHelp('${dateText(s['sale_date'])}$cust'
              '${s['valid_until'] != null && stage == 'quotation' ? ' · valid until ${dateText(s['valid_until'])}' : ''}'
              '${s['site'] != null && '${s['site']}'.isNotEmpty ? ' · site: ${s['site']}' : ''}'
              '${s['efd_receipt_no'] != null ? ' · EFD ${s['efd_receipt_no']}' : ''}'
              '${stage == 'cancelled' ? ' · cancelled (was ${saleStages[s['cancelled_from']] ?? ''}): ${s['cancel_reason'] ?? ''}' : ''}'),
        ]),
        if (s['due_date'] != null && live && owed > 0.01)
          Row(children: [
            Expanded(child: PlHelp('due ${dateText(s['due_date'])}${overdueDays > 0 ? ' — $overdueDays days overdue' : ''}', color: overdueDays > 0 ? C.error : null)),
            if (canSell)
              TextButton(
                onPressed: () async {
                  final d = await showDatePicker(context: context, initialDate: DateTime.parse('${s['due_date']}'), firstDate: DateTime.parse('${s['sale_date']}'), lastDate: DateTime.parse(today).add(const Duration(days: 730)));
                  if (d != null) _run(() => db.rpc('set_sale_due_date', params: {'p_sale': s['id'], 'p_due': iso(d)}));
                },
                child: const Text('change'),
              ),
          ]),
        const SizedBox(height: 8),
        // ---- the lines ----
        for (final l in lines)
          () {
            final it = refs.items['p:${l['product_id']}'];
            final inc = r2(n(l['price']) * (1 + n(l['vat_rate']) / 100));
            final sh = shortOf(l), ip = inProd(l);
            return Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(lineName(refs, l), style: const TextStyle(fontWeight: FontWeight.w600)),
                  PlHelp(l['product_id'] != null ? '${it?.category ?? ''} · ${qtyText(n(l['quantity']))} ${perOf(refs, l['product_id'], piece: 'pc')} × ${money(inc)}' : 'Other item'),
                  if (l['discount_reason'] != null) PlHelp('list ${money(r2(n(l['list_price']) * (1 + n(l['vat_rate']) / 100)))}${n(l['vat_rate']) == 0 ? ' before VAT' : ''} · ${l['discount_reason']}'),
                  if (sh > 0)
                    PlHelp('Short ${qtyText(r2(sh))} ${perOf(refs, l['product_id'], piece: 'pc')}${ip > 0 ? ' · ${qtyText(ip)} pcs in production${sh - ip > 1e-9 ? ' · ${qtyText(r2(sh - ip))} more to make' : ''}' : ' — to make'}', color: C.warning),
                ])),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(money(n(l['total'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                  PlHelp(n(l['vat_rate']) == 0 ? 'no VAT' : 'VAT ${money(n(l['vat']))}'),
                ]),
              ]),
            );
          }(),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(children: [
            Expanded(child: PlHelp('without VAT ${money(n(s['subtotal']))} · ${n(s['vat']) == 0 ? 'no VAT' : 'VAT ${money(n(s['vat']))}'}')),
            Text('Total ${money(n(s['total']))}', style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ),

        // ---- customer orders (141): waiting for, make in production, progress ----
        if (stage != 'invoice' || _d.production.isNotEmpty || (s['waiting_for'] as List? ?? []).isNotEmpty)
          _SaleProduction(sale: s, refs: refs, rows: _d.production, canSell: canSell, canPlan: session.canAt('production.plan', br, null), needOf: shortOf, onChanged: _refresh, onSent: _sentToPlanner),

        // ---- payments ----
        if (!['note', 'quotation', 'cancelled'].contains(stage)) ...[
          const SectionTitle('Payments'),
          if (jl(s['payments']).isEmpty)
            Row(children: [const Expanded(child: PlHelp('No payment yet')), if (canPay) OutlinedButton(onPressed: _pay, child: const Text('Record payment'))])
          else ...[
            for (final p in jl(s['payments'])..sort((a, b) { final c = '${b['paid_on']}'.compareTo('${a['paid_on']}'); return c != 0 ? c : '${b['created_at']}'.compareTo('${a['created_at']}'); }))
              () {
                final pr = _d.proofs['${p['id']}'];
                final st = proofState(p, pr, today);
                final (label, tone) = proofBadge[st]!;
                final acc = accountName(p['account_id']).isNotEmpty ? accountName(p['account_id']) : (payMethods[p['method']] ?? '');
                final canReview = pr != null && pr['status'] != 'confirmed' && session.canAt('sales.confirm_payments', br, null);
                return CardBox(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(child: Text('Paid ${tableDate(p['paid_on'])}', style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(money(n(p['amount'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ]),
                    PlHelp('$acc${p['receipt_no'] != null ? ' · #${p['receipt_no']}' : ''}${p['reference'] != null ? ' · ${p['reference']}' : ''}'),
                    const SizedBox(height: 4),
                    Row(children: [
                      Badge2(label, tone: tone),
                      if (pr?['status'] == 'queried') Expanded(child: PlHelp(' ${pr!['note'] ?? ''}', color: C.error)) else const Spacer(),
                      if (pr != null)
                        TextButton(
                          onPressed: () async {
                            final done = await showModal<bool>(context, title: 'Payment proof · ${money(n(p['amount']))}',
                                body: (ctx) => ProofReview(payment: {...p, 'sale': s}, proof: pr, buyer: buyer, account: acc, canReview: canReview));
                            if (done == true) _refresh();
                          },
                          child: Text(canReview ? 'Check' : 'View'),
                        ),
                      if (pr?['status'] != 'confirmed' && canSell)
                        TextButton(onPressed: () async { if (await addPaymentProof(context, payment: p, sale: s, proof: pr, buyer: buyer)) _refresh(); }, child: Text(pr != null ? 'Replace proof' : 'Add proof')),
                      IconButton(tooltip: 'Print receipt', icon: const Icon(LucideIcons.printer, size: 16), onPressed: () => _doc('receipt', paymentId: '${p['id']}')),
                    ]),
                  ]),
                );
              }(),
            if (owed > 0)
              Row(children: [
                Expanded(child: Text('Owed ${money(owed)}', style: const TextStyle(color: C.warning, fontWeight: FontWeight.w700))),
                if (canPay) OutlinedButton(onPressed: _pay, child: const Text('Record payment')),
              ]),
          ],
        ],

        // ---- goods leaving ----
        if (deliveries.isNotEmpty) ...[
          const SectionTitle('Goods'),
          for (final d in deliveries)
            CardBox(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text('${d['kind'] == 'collection' || d['status'] == 'on_the_way' ? 'Collected' : 'Delivered'} ${tableDate(d['delivered_on'])}', style: const TextStyle(fontWeight: FontWeight.w600))),
                  Text(money(n(d['value'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                ]),
                PlHelp('DN-${d['delivery_no']}${d['driver'] != null ? ' · ${d['driver']}' : ''}${d['vehicle'] != null ? ' · ${d['vehicle']}' : ''}'
                    '${d['kind'] == 'delivery' && d['status'] == 'delivered' && (d['pod_received_by'] ?? d['received_by']) != null ? ' · received by ${d['pod_received_by'] ?? d['received_by']}' : ''}'),
                PlHelp([
                  for (final x in jl(d['lines']))
                    () { final l = lines.where((y) => y['id'] == x['sale_line_id']).firstOrNull; return '${qtyText(n(x['quantity']))} ${perOf(refs, l?['product_id'], piece: 'pc')} ${refs.items['p:${l?['product_id']}']?.name ?? ''}'; }(),
                ].join(', ')),
                Row(children: [
                  if (d['status'] == 'on_the_way') const Badge2('to confirm delivered', tone: Tone.warning),
                  const Spacer(),
                  if (d['status'] == 'on_the_way' && canSell)
                    FilledButton(onPressed: () async { if (await confirmDelivery(context, delivery: d, who: buyer, branchId: br)) _refresh(); }, child: const Text('Delivered…')),
                  IconButton(tooltip: 'Print delivery note', icon: const Icon(LucideIcons.printer, size: 16), onPressed: () => _doc('delivery', deliveryId: '${d['id']}')),
                ]),
              ]),
            ),
        ],

        // ---- EFD on an invoice with VAT ----
        if (stage == 'invoice' && n(s['vat']) > 0 && session.canAt('invoices.create', br, null)) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _efd, decoration: InputDecoration(labelText: s['efd_receipt_no'] == null ? 'EFD (required)' : 'EFD', hintText: 'Number'))),
            if (_efd.text != '${s['efd_receipt_no'] ?? ''}') ...[
              const SizedBox(width: 8),
              OutlinedButton(onPressed: _busy ? null : () => toStage('efd', {'efd_receipt_no': _efd.text}), child: const Text('Save')),
            ],
          ]),
        ],
        if (s['notes'] != null && '${s['notes']}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Note  ${s['notes']}', style: const TextStyle(fontSize: Fs.sm))),
        if (jl(s['corrections']).isNotEmpty) ...[
          const SectionTitle('Corrections'),
          for (final c in jl(s['corrections'])..sort((a, b) => '${b['applied_at']}'.compareTo('${a['applied_at']}')))
            Text('${tableDate(c['applied_at'])} · ${c['reason'] ?? ''}', style: const TextStyle(fontSize: Fs.sm)),
        ],
      ],
    );
  }
}

// ======================= Record a payment =======================
class _PayWindow extends StatefulWidget {
  const _PayWindow({required this.sale, required this.refs, required this.owed, required this.accounts});
  final Json sale;
  final Refs refs;
  final double owed;
  final List<Json> accounts;
  @override
  State<_PayWindow> createState() => _PayWindowState();
}

class _PayWindowState extends State<_PayWindow> {
  late final _amount = TextEditingController(text: qtyText(widget.owed).replaceAll(',', ''));
  final _receipt = TextEditingController(), _reference = TextEditingController();
  String _account = '', _method = 'cash', _line = '';
  late String _paidOn = session.today;
  bool _busy = false;
  String _error = '';

  @override
  void initState() { super.initState(); _amount.addListener(() => setState(() {})); }

  Future<void> _save() async {
    setState(() { _error = ''; _busy = true; });
    try {
      await db.rpc('record_sale_payment', params: {'p_sale': widget.sale['id'], 'p': {
        'amount': _amount.text.trim().replaceAll(',', ''), 'method': _method, 'reference': _reference.text, 'paid_on': _paidOn,
        'account_id': _account, 'receipt_no': _receipt.text, 'sale_line_id': _line,
      }});
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sale;
    final ls = jl(s['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no'])));
    final amt = numOf(_amount.text);
    return FullPage(
      title: 'Payment on #${s['sale_no']}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
        FilledButton(onPressed: _busy ? null : _save, child: Text('Record ${amt != null ? formatMoney(amt, session.currency) : ''}')),
      ],
      children: [
        if (widget.accounts.isNotEmpty)
          DropdownButtonFormField<String>(
            initialValue: _account, isExpanded: true, decoration: const InputDecoration(labelText: 'Into account (required)'),
            items: [const DropdownMenuItem(value: '', child: Text('Choose…')), for (final a in widget.accounts) DropdownMenuItem(value: '${a['id']}', child: Text('${a['name']}'))],
            onChanged: (v) => setState(() => _account = v ?? ''),
          )
        else
          SlideRow(children: [for (final e in payMethods.entries) Chip2(e.value, on: _method == e.key, onTap: () => setState(() => _method = e.key))]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Amount (up to ${formatMoney(widget.owed, session.currency)})'))),
          const SizedBox(width: 8),
          Expanded(child: DateField(label: 'Date', value: _paidOn, last: session.today, onChange: (v) => setState(() => _paidOn = v))),
        ]),
        if (ls.length > 1) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _line, isExpanded: true, decoration: const InputDecoration(labelText: 'For'),
            items: [const DropdownMenuItem(value: '', child: Text('The whole order')),
              for (final l in ls) DropdownMenuItem(value: '${l['id']}', child: Text('${lineName(widget.refs, l)} — ${formatMoney(n(l['total']), session.currency)}', overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => _line = v ?? ''),
          ),
        ],
        const SizedBox(height: 10),
        TextField(controller: _receipt, decoration: const InputDecoration(labelText: 'Receipt no. (optional)')),
        if (widget.accounts.isNotEmpty && _account.isEmpty) const PlHelp('Choose the account — it is required.', color: C.warning),
        if (widget.accounts.isEmpty && _method != 'cash') ...[
          const SizedBox(height: 10),
          TextField(controller: _reference, decoration: InputDecoration(labelText: '${_method == 'bank' ? 'Bank' : 'Mobile money'} reference (required)')),
        ],
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
      ],
    );
  }
}

// ======================= Goods leaving =======================
class _Delivery extends StatefulWidget {
  const _Delivery({required this.sale, required this.refs, required this.canLeave});
  final Json sale;
  final Refs refs;
  final double canLeave;
  @override
  State<_Delivery> createState() => _DeliveryState();
}

class _DeliveryState extends State<_Delivery> {
  Json get sale => widget.sale;
  Refs get refs => widget.refs;
  // the yard first, the shop below it; the store is chosen every time when there are several (2026-11-19)
  late final List<Store> stores = refs.warehouses.where((w) => w.status == 'active' && w.branchId == sale['branch_id'] && w.type == 'finished_goods').toList()
    ..sort((a, b) => a.receivesProduction != b.receivesProduction ? (a.receivesProduction ? -1 : 1) : a.name.compareTo(b.name));
  late String _storeId = stores.firstOrNull?.id ?? '';
  late bool _storePicked = stores.length <= 1;
  // the day they left (136): from the sale's day to today
  late String _leftOn = '${sale['sale_date']}'.compareTo(session.today) <= 0 ? '${sale['sale_date']}' : session.today;
  Map<String, double>? _inStore;
  String _kind = 'collection', _error = '';
  final Map<String, TextEditingController> _qty = {}, _broken = {};
  late final _efd = TextEditingController(text: '${sale['efd_receipt_no'] ?? ''}');
  late final _receivedBy = TextEditingController(text: '${sale['walk_in_name'] ?? ''}');
  final _vehicle = TextEditingController(), _driver = TextEditingController();
  bool _checked = false, _busy = false;

  late final List<Json> lines = [
    for (final l in jl(sale['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no']))))
      if (l['product_id'] != null && r2(n(l['quantity']) - doneOf(sale, l['id'])) > 0) {...l, 'left': r2(n(l['quantity']) - doneOf(sale, l['id']))},
  ];
  double unitInc(Json l) => n(l['total']) / n(l['quantity']);
  String key(Json l) => '${l['product_id']}|${l['color_id'] ?? ''}';

  @override
  void initState() {
    super.initState();
    // filled in from the start: everything still to deliver, as far as the payments cover it
    var room = widget.canLeave;
    for (final l in lines) {
      final unit = unitInc(l);
      final q = math.max(0.0, math.min(n(l['left']).toDouble(), (room / unit * 100).floorToDouble() / 100));
      _qty['${l['id']}'] = TextEditingController(text: q > 0 ? qtyText(q).replaceAll(',', '') : '');
      _broken['${l['id']}'] = TextEditingController();
      room -= (unit * q * 100).roundToDouble() / 100;
    }
    _loadStore();
  }

  Future<void> _loadStore() async {
    if (_storeId.isEmpty) { setState(() => _inStore = null); return; }
    setState(() => _inStore = null);
    try {
      final d = jl(await db.rpc('sales_availability', params: {'p_branch_id': sale['branch_id'], 'p_warehouse_id': _storeId}));
      if (mounted) setState(() => _inStore = {for (final x in d) '${x['product_id']}|${x['color_id'] ?? ''}': n(x['on_hand']).toDouble()});
    } catch (_) {}
  }

  double q(Json l) => numOf(_qty['${l['id']}']!.text) ?? 0;
  double b(Json l) => numOf(_broken['${l['id']}']!.text) ?? 0;

  Future<void> _save(double value, List<({String k, double q, double store, String name})> tooMuch) async {
    final needEfd = n(sale['vat']) > 0;
    String? err;
    if (_storeId.isEmpty || !_storePicked) {
      err = 'Choose the store the goods leave from.';
    } else if (value <= 0) {
      err = 'Enter what leaves.';
    } else if (lines.any((l) => b(l) < 0)) {
      err = 'Broken pieces are zero or more.';
    } else if (lines.any((l) => b(l) > 0 && !(q(l) > 0))) {
      err = 'Broken pieces go with what is loaded on that line.';
    } else if (_leftOn.compareTo(session.today) > 0 || _leftOn.compareTo('${sale['sale_date']}') < 0) {
      err = 'The date is from the sale (${tableDate(sale['sale_date'])}) to today.';
    } else if (tooMuch.isNotEmpty) {
      err = 'Not enough in the store: ${tooMuch.map((x) => '${x.name} — ${qtyText(x.q)} leaving, ${qtyText(x.store)} in store').join('; ')}.';
    } else if (value > widget.canLeave + 0.01) {
      err = 'Goods worth ${formatMoney(widget.canLeave, session.currency)} can leave — record a payment first.';
    } else if (needEfd && _efd.text.trim().isEmpty) {
      err = 'This sale carries VAT — enter the EFD receipt number.';
    } else if (needEfd && !_checked) {
      err = 'Check the EFD receipt shows these amounts, then tick the box.';
    }
    if (err != null) { setState(() => _error = err!); return; }
    setState(() { _error = ''; _busy = true; });
    try {
      // a delivery: who receives it is asked when it is confirmed delivered, not now
      final did = await db.rpc('record_sale_delivery', params: {'p_sale': sale['id'], 'p': {
        'kind': _kind, 'warehouse_id': _storeId, 'delivered_on': _leftOn, 'received_by': _kind == 'collection' ? _receivedBy.text : '', 'vehicle': _vehicle.text,
        if (needEfd) 'efd_receipt_no': _efd.text.trim(),
        'lines': [for (final l in lines) if (q(l) > 0) {'sale_line_id': l['id'], 'quantity': q(l), if (b(l) > 0) 'broken': b(l)}],
      }});
      if (_kind == 'delivery' && _driver.text.trim().isNotEmpty && did != null) await db.rpc('set_delivery_trip', params: {'p_delivery': did, 'p': {'driver': _driver.text.trim()}});
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      _error = dbError(e, "We couldn't record this. Please try again.");
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final value = lines.fold<double>(0, (t, l) => t + r2(unitInc(l) * q(l)));
    final leaving = <String, double>{};
    for (final l in lines) { leaving[key(l)] = (leaving[key(l)] ?? 0) + q(l) + b(l); } // loaded + broken both leave the store
    final tooMuch = _inStore == null
        ? <({String k, double q, double store, String name})>[]
        : [
            for (final e in leaving.entries)
              if (e.value > (_inStore![e.key] ?? 0) + 1e-9)
                (k: e.key, q: e.value, store: math.max(_inStore![e.key] ?? 0, 0.0), name: lineName(refs, lines.firstWhere((y) => key(y) == e.key))),
          ];
    String per(Json l) => perOf(refs, l['product_id'], piece: 'pc');
    final needEfd = n(sale['vat']) > 0;
    return FullPage(
      title: 'Goods leaving on #${sale['sale_no']}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
        FilledButton(onPressed: _busy || tooMuch.isNotEmpty || (_storeId.isNotEmpty && _inStore == null) ? null : () => _save(value, tooMuch), child: Text(_busy ? 'Saving…' : 'Confirm')),
      ],
      children: [
        SlideRow(children: [
          Chip2('Collected by the customer', on: _kind == 'collection', onTap: () => setState(() => _kind = 'collection')),
          Chip2('We deliver', on: _kind == 'delivery', onTap: () => setState(() => _kind = 'delivery')),
        ]),
        PlHelp('Paid for, not yet taken: ${formatMoney(widget.canLeave, session.currency)}'),
        const SizedBox(height: 10),
        // the details first (2026-11-21): date, store, who collected and the truck — then what leaves
        DateField(label: 'Date', value: _leftOn, first: '${sale['sale_date']}', last: session.today, onChange: (v) => setState(() => _leftOn = v)),
        if (stores.length > 1) ...[
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: _storePicked ? _storeId : '', isExpanded: true,
            decoration: InputDecoration(labelText: 'Leaving from${_storePicked ? '' : ' (choose)'}', errorText: _storePicked ? null : ''),
            items: [if (!_storePicked) const DropdownMenuItem(value: '', child: Text('Choose the store…')),
              for (final w in stores) DropdownMenuItem(value: w.id, child: Text('${w.name}${w.id == sale['warehouse_id'] ? ' (sold from)' : ''}'))],
            onChanged: (v) { if (v == null || v.isEmpty) return; setState(() { _storeId = v; _storePicked = true; _error = ''; }); _loadStore(); },
          ),
        ],
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _kind == 'collection'
              ? TextField(controller: _receivedBy, decoration: const InputDecoration(labelText: 'Collected by'))
              : TextField(controller: _driver, decoration: const InputDecoration(labelText: 'Driver'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _vehicle, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Truck plate no.', hintText: 'e.g. T 123 ABC'))),
        ]),
        const SectionTitle('What leaves'),
        for (final l in lines)
          () {
            final rest = r2(n(l['left']) - q(l));
            final short = tooMuch.any((x) => x.k == key(l));
            return CardBox(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(lineName(refs, l), style: const TextStyle(fontWeight: FontWeight.w700)),
                PlHelp('${qtyText(n(l['left']))} ${per(l)} to deliver · ${_storeId.isEmpty ? '—' : _inStore != null ? '${qtyText(r2(math.max(_inStore![key(l)] ?? 0, 0)))} in store' : '…'}', color: short ? C.error : null),
                const SizedBox(height: 6),
                Row(children: [
                  Expanded(child: TextField(controller: _qty['${l['id']}'], onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(isDense: true, labelText: 'Qty (${per(l)})'))),
                  const SizedBox(width: 8),
                  // broken while loading (139): out of the store into Rejects, for this sale
                  Expanded(child: TextField(controller: _broken['${l['id']}'], onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, labelText: 'Broken', hintText: '0'))),
                ]),
                const SizedBox(height: 4),
                Row(children: [
                  PlHelp(q(l) > 0 ? formatMoney(r2(unitInc(l) * q(l)), session.currency) : '—'),
                  const Spacer(),
                  PlHelp(rest > 0 ? '${qtyText(rest)} ${per(l)} remaining' : 'nothing remaining', color: rest > 0 ? C.warning : null),
                ]),
              ]),
            );
          }(),
        if (lines.any((l) => b(l) > 0))
          PlHelp('Broken: ${lines.where((l) => b(l) > 0).map((l) => '${qtyText(b(l))} ${per(l)} ${refs.items['p:${l['product_id']}']?.name ?? ''}').join(', ')} — out of ${stores.where((w) => w.id == _storeId).firstOrNull?.name ?? 'the store'} into Rejects, marked for sale #${sale['sale_no']}.'),
        if (tooMuch.isNotEmpty)
          Alert('Not enough in the store — ${tooMuch.map((x) => '${x.name}: ${qtyText(r2(x.q))} leaving, ${qtyText(r2(x.store))} in store').join('; ')}. Lower the quantity, or wait for stock (curing to be released).', tone: Tone.error),
        if (needEfd) ...[
          const SizedBox(height: 8),
          TextField(controller: _efd, decoration: const InputDecoration(labelText: 'EFD receipt no. (required — this sale carries VAT)')),
          const SizedBox(height: 6),
          Text('Check the EFD receipt shows: total ${formatMoney(n(sale['total']), session.currency)} · VAT ${formatMoney(n(sale['vat']), session.currency)} · without VAT ${formatMoney(n(sale['subtotal']), session.currency)}', style: const TextStyle(fontSize: Fs.sm)),
          CheckboxListTile(value: _checked, onChanged: (v) => setState(() => _checked = v ?? false), contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, title: const Text('The EFD receipt shows these amounts', style: TextStyle(fontSize: Fs.sm))),
        ],
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
      ],
    );
  }
}

// ======================= Correct a sale (068) =======================
class _CLine {
  _CLine(this.l, String quantity, String price, this.done) : quantity = TextEditingController(text: quantity), price = TextEditingController(text: price);
  final Json l;
  final TextEditingController quantity, price;
  final double done;
  bool remove = false;
}

class _CPay {
  _CPay(this.pm) : amount = TextEditingController(text: qtyText(n(pm['amount'])).replaceAll(',', '')), receipt = TextEditingController(text: '${pm['receipt_no'] ?? ''}'),
        accountId = '${pm['account_id'] ?? ''}', paidOn = '${pm['paid_on']}';
  final Json pm;
  final TextEditingController amount, receipt;
  String accountId, paidOn;
  bool remove = false;
}

class _Correct extends StatefulWidget {
  const _Correct({required this.sale, required this.refs, required this.accounts, required this.direct});
  final Json sale;
  final Refs refs;
  final List<Json> accounts;
  final bool direct;
  @override
  State<_Correct> createState() => _CorrectState();
}

class _CorrectState extends State<_Correct> {
  Json get sale => widget.sale;
  double inc(Json l) => r2(n(l['price']) * (1 + n(l['vat_rate']) / 100));
  late String _date = '${sale['sale_date']}';
  late final _name = TextEditingController(text: '${sale['walk_in_name'] ?? ''}'), _phone = TextEditingController(text: '${sale['walk_in_phone'] ?? ''}'),
      _site = TextEditingController(text: '${sale['site'] ?? ''}'), _efd = TextEditingController(text: '${sale['efd_receipt_no'] ?? ''}'), _reason = TextEditingController();
  late final List<_CLine> _lines = [
    for (final l in jl(sale['lines'])..sort((a, b) => n(a['line_no']).compareTo(n(b['line_no']))))
      _CLine(l, qtyText(n(l['quantity'])).replaceAll(',', ''), '${inc(l)}', doneOf(sale, l['id'])),
  ];
  late final List<_CPay> _pays = [for (final pm in jl(sale['payments'])) _CPay(pm)];
  final List<({TextEditingController name, TextEditingController price})> _added = [];
  // one transaction (2026-11-03): a sale with one payment is paid as one — its amount follows the corrected total
  late bool _oneTx = jl(sale['payments']).length == 1;
  bool _busy = false, _sent = false;
  String _error = '';

  double get newTotal => r2(_lines.where((x) => !x.remove).fold<double>(0, (t, x) => t + (x.l['product_id'] != null ? (numOf(x.quantity.text) ?? 0) * (numOf(x.price.text) ?? 0) : (numOf(x.price.text) ?? 0))) +
      _added.fold<double>(0, (t, a) => t + (numOf(a.price.text) ?? 0)));
  String payAmount(_CPay x) => _oneTx && _pays.length == 1 && !x.remove ? '$newTotal' : x.amount.text;

  Future<void> _save() async {
    setState(() => _error = '');
    if (_reason.text.trim().isEmpty) { setState(() => _error = 'Give the reason for the correction.'); return; }
    final ch = <String, dynamic>{};
    if (_date != sale['sale_date']) ch['sale_date'] = _date;
    if (sale['customer_id'] == null && (_name.text != '${sale['walk_in_name'] ?? ''}' || _phone.text != '${sale['walk_in_phone'] ?? ''}')) { ch['walk_in_name'] = _name.text; ch['walk_in_phone'] = _phone.text; }
    if (_site.text != '${sale['site'] ?? ''}') ch['site'] = _site.text;
    if (_efd.text != '${sale['efd_receipt_no'] ?? ''}') ch['efd_receipt_no'] = _efd.text;
    final lc = <Json>[
      for (final x in _lines)
        if (x.remove || numOf(x.quantity.text) != n(x.l['quantity']) || numOf(x.price.text) != inc(x.l))
          x.remove ? {'id': x.l['id'], 'remove': true} : {'id': x.l['id'], 'product_id': x.l['product_id'], 'color_id': x.l['color_id'], 'quantity': numOf(x.quantity.text), 'price': numOf(x.price.text)},
    ];
    if (_added.any((a) => a.name.text.trim().isEmpty || !((numOf(a.price.text) ?? 0) > 0))) { setState(() => _error = 'Write what each added item is, and its price.'); return; }
    lc.addAll([for (final a in _added) {'item_name': a.name.text.trim(), 'price': numOf(a.price.text)}]);
    if (lc.isNotEmpty) ch['lines'] = lc;
    final pc = <Json>[
      for (final x in _pays)
        if (x.remove || numOf(payAmount(x)) != n(x.pm['amount']) || x.accountId != '${x.pm['account_id'] ?? ''}' || x.paidOn != x.pm['paid_on'] || x.receipt.text != '${x.pm['receipt_no'] ?? ''}')
          x.remove ? {'id': x.pm['id'], 'remove': true} : {'id': x.pm['id'], 'amount': numOf(payAmount(x)), if (x.accountId.isNotEmpty) 'account_id': x.accountId, 'paid_on': x.paidOn, 'receipt_no': x.receipt.text},
    ];
    if (pc.isNotEmpty) ch['payments'] = pc;
    if (ch.isEmpty) { setState(() => _error = 'Nothing has changed.'); return; }
    setState(() => _busy = true);
    try {
      final data = await db.rpc('correct_sale', params: {'p_sale': sale['id'], 'p_changes': ch, 'p_reason': _reason.text.trim()});
      if (data is Map && data['request_id'] != null) {
        setState(() { _sent = true; _busy = false; });
        return;
      }
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      _error = dbError(e, "We couldn't correct this sale. Please try again.");
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final refs = widget.refs;
    if (_sent) {
      return FullPage(title: 'Correction of #${sale['sale_no']}', footer: [FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done'))],
          children: const [Text('Sent for approval — the sale changes once an admin approves it under Approvals.')]);
    }
    return FullPage(
      title: 'Correct #${sale['sale_no']}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Back')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : widget.direct ? 'Correct' : 'Send for approval')),
      ],
      children: [
        PlHelp('${widget.direct ? 'Applies at once.' : 'Goes to Approvals.'} The old version is kept.'),
        const SizedBox(height: 8),
        DateField(label: 'Date', value: _date, last: session.today, onChange: (v) => setState(() => _date = v)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextField(controller: _site, decoration: const InputDecoration(labelText: 'Site'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _efd, decoration: const InputDecoration(labelText: 'EFD receipt'))),
        ]),
        if (sale['customer_id'] == null) ...[
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'Buyer'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone'))),
          ]),
        ],
        const SectionTitle('Lines'),
        for (final x in _lines)
          CardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(lineName(refs, x.l), style: TextStyle(fontWeight: FontWeight.w700, color: x.remove ? context.tk.textMuted : null)),
              const SizedBox(height: 6),
              Row(children: [
                if (x.l['product_id'] != null) ...[
                  Expanded(child: TextField(controller: x.quantity, enabled: !x.remove, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(isDense: true, labelText: 'Quantity (${perOf(refs, x.l['product_id'], piece: 'pc')})'))),
                  const SizedBox(width: 8),
                ],
                Expanded(child: TextField(controller: x.price, enabled: !x.remove, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, labelText: 'Price'))),
              ]),
              Row(children: [
                PlHelp(x.done > 0 ? 'delivered ${qtyText(x.done)} ${perOf(refs, x.l['product_id'], piece: 'pc')}' : x.l['product_id'] == null ? 'other item' : 'nothing delivered'),
                const Spacer(),
                if (x.done == 0) Row(children: [Checkbox(value: x.remove, onChanged: (v) => setState(() => x.remove = v ?? false)), const Text('remove', style: TextStyle(fontSize: Fs.sm))]),
              ]),
            ]),
          ),
        for (final a in _added)
          CardBox(
            child: Row(children: [
              Expanded(flex: 3, child: TextField(controller: a.name, decoration: const InputDecoration(isDense: true, labelText: 'Other item', hintText: 'e.g. vipande'))),
              const SizedBox(width: 8),
              Expanded(flex: 2, child: TextField(controller: a.price, onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, labelText: 'Price'))),
              IconButton(tooltip: 'Remove added item', onPressed: () => setState(() => _added.remove(a)), icon: const Icon(LucideIcons.trash2, size: 16)),
            ]),
          ),
        Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(onPressed: () => setState(() => _added.add((name: TextEditingController(), price: TextEditingController()))), icon: const Icon(LucideIcons.plus, size: 15), label: const Text('Add other item'))),
        if (_pays.isNotEmpty) ...[
          const SectionTitle('Payments'),
          if (_pays.length == 1)
            CheckboxListTile(value: _oneTx, onChanged: (v) => setState(() => _oneTx = v ?? false), contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading,
                title: Text('Paid as one transaction — the payment follows the total (${formatMoney(newTotal, session.currency)})', style: const TextStyle(fontSize: Fs.sm))),
          for (final x in _pays)
            CardBox(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: TextField(
                    controller: _oneTx && _pays.length == 1 && !x.remove ? TextEditingController(text: payAmount(x)) : x.amount, enabled: !x.remove && !(_oneTx && _pays.length == 1),
                    onChanged: (_) => setState(() {}), keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(isDense: true, labelText: 'Amount'),
                  )),
                  const SizedBox(width: 8),
                  Expanded(child: DateField(label: 'Date', value: x.paidOn, last: session.today, enabled: !x.remove, onChange: (v) => setState(() => x.paidOn = v))),
                ]),
                const SizedBox(height: 8),
                Row(children: [
                  if (widget.accounts.isNotEmpty) ...[
                    Expanded(child: DropdownButtonFormField<String>(
                      initialValue: x.accountId, isExpanded: true, decoration: const InputDecoration(isDense: true, labelText: 'Into'),
                      items: [DropdownMenuItem(value: '', child: Text(payMethods[x.pm['method']] ?? '—')), for (final a in widget.accounts) DropdownMenuItem(value: '${a['id']}', child: Text('${a['name']}', overflow: TextOverflow.ellipsis))],
                      onChanged: x.remove ? null : (v) => setState(() => x.accountId = v ?? ''),
                    )),
                    const SizedBox(width: 8),
                  ],
                  Expanded(child: TextField(controller: x.receipt, enabled: !x.remove, decoration: const InputDecoration(isDense: true, labelText: 'Receipt no.'))),
                ]),
                Row(children: [const Spacer(), Checkbox(value: x.remove, onChanged: (v) => setState(() => x.remove = v ?? false)), const Text('remove', style: TextStyle(fontSize: Fs.sm))]),
              ]),
            ),
        ],
        const SizedBox(height: 8),
        TextField(controller: _reason, decoration: const InputDecoration(labelText: 'Reason (required)', hintText: 'e.g. quantity typed wrong')),
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
      ],
    );
  }
}

// ======================= Customer orders (141) =======================
class _SaleProduction extends StatefulWidget {
  const _SaleProduction({required this.sale, required this.refs, required this.rows, required this.canSell, required this.canPlan, required this.needOf, required this.onChanged, required this.onSent});
  final Json sale;
  final Refs refs;
  final List<ProdRow> rows;
  final bool canSell, canPlan;
  final double Function(Json) needOf;
  final Future<void> Function() onChanged;
  final VoidCallback onSent;
  @override
  State<_SaleProduction> createState() => _SaleProductionState();
}

class _SaleProductionState extends State<_SaleProduction> {
  Map<String, double> _perSqm = {};
  bool _busy = false;
  String _error = '', _relinked = '';
  Json get sale => widget.sale;
  Refs get refs => widget.refs;

  @override
  void initState() { super.initState(); _loadSqm(); }

  @override
  void didUpdateWidget(_SaleProduction old) {
    super.didUpdateWidget(old);
    if (old.rows.length != widget.rows.length) _loadSqm();
  }

  Future<void> _loadSqm() async {
    final ids = {for (final l in jl(sale['lines'])) if (l['product_id'] != null) '${l['product_id']}'}.toList();
    if (ids.isEmpty || widget.rows.isEmpty) return;
    try {
      final d = jl(await db.from('product_specs').select('product_id, pcs_per_sqm').inFilter('product_id', ids));
      if (mounted) setState(() => _perSqm = {for (final x in d) if (n(x['pcs_per_sqm']) > 0) '${x['product_id']}': n(x['pcs_per_sqm']).toDouble()});
    } catch (_) {}
  }

  bool isSqm(Object? id) => perOf(refs, id) == 'm²';
  double? pcsOf(Json l, double q) => isSqm(l['product_id']) ? (_perSqm['${l['product_id']}'] != null ? (q * _perSqm['${l['product_id']}']!).ceilToDouble() : null) : q.ceilToDouble();
  String nameOf(Object? p, Object? c) => '${refs.items['p:$p']?.name ?? '—'}${c != null ? ' ${refs.colour('$c')}' : ''}';

  Future<void> _call(Future<dynamic> Function() q, {bool sent = false}) async {
    setState(() { _error = ''; _busy = true; });
    try {
      final r = await q();
      if (mounted) setState(() => _busy = false);
      await widget.onChanged();
      if (sent && r != null) widget.onSent();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = dbError(e, "We couldn't change production. Please try again."); });
    }
  }

  Future<void> _toggle(String k) async {
    final waiting = [for (final x in (sale['waiting_for'] as List? ?? [])) '$x'];
    final next = waiting.contains(k) ? waiting.where((x) => x != k).toList() : [...waiting, k];
    await _call(() => db.rpc('set_sale_waiting', params: {'p_sale': sale['id'], 'p_for': next}));
  }

  /// a product taken out of the order: remove it from the production order (the Planner's writer keeps its rules)
  Future<void> _removeLine(Json order, Json line) async {
    setState(() { _error = ''; _busy = true; });
    try {
      final o = await db.from('production_orders').select('id, reference, due_date, notes, lines:production_order_lines(id, product_id, color_id, pieces, sqm, display_order)').eq('id', order['id']).single();
      final rest = jl(o['lines']).where((x) => x['id'] != line['id']).toList()..sort((a, b) => n(a['display_order']).compareTo(n(b['display_order'])));
      if (rest.isEmpty) {
        setState(() { _busy = false; _error = 'It is the only product in production #${order['order_no']} — cancel that order in the Planner instead'; });
        return;
      }
      await db.rpc('save_production_order', params: {'p': {'id': o['id'], 'reference': o['reference'], 'due_date': o['due_date'], 'notes': o['notes'],
        'lines': [for (final x in rest) {'product_id': x['product_id'], 'color_id': x['color_id'], 'pieces': x['pieces'], 'sqm': x['sqm']}]}});
      if (mounted) setState(() => _busy = false);
      await widget.onChanged();
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = dbError(e, "We couldn't change production. Please try again."); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final live = sale['stage'] != 'cancelled';
    final waiting = [for (final x in (sale['waiting_for'] as List? ?? [])) '$x'];
    final rows = widget.rows;
    final open = rows.where((r) => r.order['status'] == 'open').toList();
    final openOrder = open.firstOrNull?.order;
    final saleLineIds = {for (final l in jl(sale['lines'])) l['id']};
    final productLines = jl(sale['lines']).where((x) => x['product_id'] != null).toList();
    // only an edit of the order is a change (2026-11-22): saving an edited order replaces its lines
    final edited = open.any((r) => !saleLineIds.contains(r.line['sale_line_id']) && productLines.any((l) => belongsTo(r, l, sale)));
    final gone = open.where((r) => !productLines.any((l) => belongsTo(r, l, sale))).toList();
    final changes = <({String key, String kind, String text, Json order, Json? l, Json? line, double pieces, double extra})>[];
    if (live && openOrder != null && widget.canPlan && edited) {
      for (final l in productLines) {
        final r = open.where((x) => belongsTo(x, l, sale)).firstOrNull;
        final need = pcsOf(l, widget.needOf(l));
        if (need == null) continue;
        final left = r != null ? math.max(n(r.line['pieces']) - n(r.progress?['passed']), 0.0) : 0.0;
        final cast = r != null ? n(r.progress?['cast_pieces']).toDouble() : 0.0;
        final nm = nameOf(l['product_id'], l['color_id']);
        if (r != null && need > left) {
          changes.add((key: '${l['id']}', kind: 'more', text: '$nm: the order needs ${qtyText(need - left)} pcs more than production #${r.order['order_no']} makes', order: r.order, l: l, line: null, pieces: n(r.line['pieces']) + (need - left), extra: need - left));
        } else if (r != null && left > need) {
          final to = math.max(math.max(n(r.line['pieces']) - (left - need), cast), 1.0);
          if (to < n(r.line['pieces'])) changes.add((key: '${l['id']}', kind: 'less', text: '$nm: production #${r.order['order_no']} makes ${qtyText(left - need)} pcs more than the order now needs${cast > to - 1 && cast > 0 ? ' (${qtyText(cast)} already cast)' : ''}', order: r.order, l: l, line: null, pieces: to, extra: 0));
        } else if (r == null && need > 0) {
          changes.add((key: '${l['id']}', kind: 'new', text: '$nm: ${qtyText(need)} pcs short and not in production', order: openOrder, l: l, line: null, pieces: need, extra: 0));
        }
      }
    }
    if (live && openOrder != null && widget.canPlan) {
      for (final r in gone) {
        changes.add((key: 'gone:${r.line['id']}', kind: 'gone', text: '${nameOf(r.line['product_id'], r.line['color_id'])} is no longer in the order; production #${r.order['order_no']} still makes ${qtyText(math.max(n(r.line['pieces']) - n(r.progress?['cast_pieces']), 0))} pcs of it', order: r.order, l: null, line: r.line, pieces: 0, extra: 0));
      }
      if (sale['due_date'] != null && openOrder['due_date'] != null && sale['due_date'] != openOrder['due_date']) {
        changes.add((key: 'due', kind: 'due', text: 'The order is due ${dateText(sale['due_date'])}; production #${openOrder['order_no']} is due ${dateText(openOrder['due_date'])}', order: openOrder, l: null, line: null, pieces: 0, extra: 0));
      }
    }
    // edited but nothing to change: link production to the new lines quietly, so it isn't asked again
    final lineChanges = changes.where((c) => ['more', 'less', 'new'].contains(c.kind)).length;
    final sig = '${openOrder?['id']}${saleLineIds.join()}';
    if (edited && lineChanges == 0 && openOrder != null && widget.canPlan && _relinked != sig) {
      _relinked = sig;
      WidgetsBinding.instance.addPostFrameCallback((_) => db.rpc('update_production_for_sale', params: {'p_sale': sale['id'], 'p': {'order_id': openOrder['id'], 'lines': []}}).then((_) => widget.onChanged()).catchError((_) {}));
    }

    Future<void> apply(({String key, String kind, String text, Json order, Json? l, Json? line, double pieces, double extra}) c, String how) => _call(
        () => how == 'separate'
            ? db.rpc('make_production_for_sale', params: {'p_sale': sale['id'], 'p': {'lines': [{'sale_line_id': c.l!['id'], 'pieces': c.kind == 'more' ? c.extra : c.pieces}]}})
            : db.rpc('update_production_for_sale', params: {'p_sale': sale['id'], 'p': {'order_id': c.order['id'], ...(c.kind == 'due' ? {'due_date': sale['due_date'], 'lines': []} : {'lines': [{'sale_line_id': c.l!['id'], 'pieces': c.pieces}]})}}),
        sent: how == 'separate');

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (live) ...[
        const SizedBox(height: 6),
        Row(children: [
          const PlLabel('Waiting for'),
          const SizedBox(width: 8),
          Expanded(child: SlideRow(children: [
            for (final (k, l) in saleWaiting) Chip2(l, on: waiting.contains(k), onTap: () { if (widget.canSell && !_busy) _toggle(k); }),
          ])),
        ]),
      ],
      if (_error.isNotEmpty) PlHelp(_error, color: C.error),
      if (changes.isNotEmpty)
        Container(
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: t.bgWarning, borderRadius: BorderRadius.circular(8)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('The order changed since production was planned', style: TextStyle(fontWeight: FontWeight.w700)),
            for (final c in changes) ...[
              const SizedBox(height: 6),
              Text('${c.text}.', style: const TextStyle(fontSize: Fs.sm)),
              Wrap(spacing: 6, children: [
                if (c.kind == 'more') ...[
                  FilledButton(onPressed: _busy ? null : () => apply(c, 'update'), child: Text('Update #${c.order['order_no']} to ${qtyText(c.pieces)}')),
                  OutlinedButton(onPressed: _busy ? null : () => apply(c, 'separate'), child: Text('New order for ${qtyText(c.extra)}')),
                ],
                if (c.kind == 'less') FilledButton(onPressed: _busy ? null : () => apply(c, 'update'), child: Text('Reduce #${c.order['order_no']} to ${qtyText(c.pieces)}')),
                if (c.kind == 'new') ...[
                  FilledButton(onPressed: _busy ? null : () => apply(c, 'update'), child: Text('Add to #${c.order['order_no']}')),
                  OutlinedButton(onPressed: _busy ? null : () => apply(c, 'separate'), child: const Text('New production order')),
                ],
                if (c.kind == 'gone') FilledButton(onPressed: _busy ? null : () => _removeLine(c.order, c.line!), child: Text('Remove from #${c.order['order_no']}')),
                if (c.kind == 'due') FilledButton(onPressed: _busy ? null : () => apply(c, 'update'), child: Text('Move #${c.order['order_no']} to ${tableDate(sale['due_date'])}')),
              ]),
            ],
            const PlHelp('Or leave it as it is — change it later here or in the Planner.'),
          ]),
        ),
      if (rows.isNotEmpty) ...[
        const SectionTitle('Made for this order'),
        for (final r in rows)
          CardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(nameOf(r.line['product_id'], r.line['color_id']), style: const TextStyle(fontWeight: FontWeight.w700))),
                IconButton(tooltip: 'Open the Planner', icon: const Icon(LucideIcons.calendarClock, size: 16), onPressed: () { final shell = Shell.of(context); Navigator.pop(context); shell.go('/production?tab=planner'); }),
              ]),
              PlHelp('#${r.order['order_no']} · ${r.order['status']}${r.order['due_date'] != null ? ' · due ${tableDate(r.order['due_date'])}' : ''}'),
              const SizedBox(height: 4),
              Row(children: [
                for (final (label, v, bold) in [
                  ('Planned', n(r.line['pieces']), false), ('Made', n(r.progress?['cast_pieces']), false), ('Curing', n(r.progress?['curing']), false),
                  ('Ready', n(r.progress?['passed']), true), ('Left', math.max(n(r.line['pieces']) - n(r.progress?['cast_pieces']), 0), false),
                ])
                  Expanded(child: Column(children: [
                    Text(label, style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                    Text(qtyText(v), style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w500, fontSize: Fs.sm, color: bold && n(r.progress?['passed']) >= n(r.line['pieces']) ? C.success : null)),
                  ])),
              ]),
            ]),
          ),
      ],
    ]);
  }
}

/// Make in production: the shortfall a line becomes a Planner production order linked to the sale
class _Make extends StatefulWidget {
  const _Make({required this.sale, required this.refs, required this.rows, required this.paid, required this.needOf});
  final Json sale;
  final Refs refs;
  final List<ProdRow> rows;
  final double paid;
  final double Function(Json) needOf;
  @override
  State<_Make> createState() => _MakeState();
}

class _MakeState extends State<_Make> {
  Json get sale => widget.sale;
  late final List<Json> lines = jl(sale['lines']).where((l) => l['product_id'] != null).toList();
  Map<String, double>? _inStore;
  Map<String, double> _perSqm = {};
  final Map<String, TextEditingController> _pcs = {};
  late String _due = '${sale['due_date'] ?? ''}';
  bool _busy = false;
  String _error = '';

  bool isSqm(Object? id) => perOf(widget.refs, id) == 'm²';
  double making(Json l) => widget.rows.where((r) => belongsTo(r, l, sale) && r.order['status'] == 'open').fold(0.0, (t, r) => t + math.max(n(r.line['pieces']) - n(r.progress?['passed']), 0));
  double? toPcs(Json l, double q) => isSqm(l['product_id']) ? (_perSqm['${l['product_id']}'] != null ? (q * _perSqm['${l['product_id']}']!).ceilToDouble() : null) : q.ceilToDouble();

  @override
  void initState() {
    super.initState();
    for (final l in lines) { _pcs['${l['id']}'] = TextEditingController(); }
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Future.wait<dynamic>([
        db.rpc('sales_availability', params: {'p_branch_id': sale['branch_id'], if (sale['warehouse_id'] != null) 'p_warehouse_id': sale['warehouse_id']}),
        db.from('product_specs').select('product_id, pcs_per_sqm').inFilter('product_id', [for (final l in lines) l['product_id']]),
      ]);
      if (!mounted) return;
      setState(() {
        _inStore = {for (final x in jl(r[0])) '${x['product_id']}|${x['color_id'] ?? ''}': n(x['on_hand']).toDouble()};
        _perSqm = {for (final x in jl(r[1])) if (n(x['pcs_per_sqm']) > 0) '${x['product_id']}': n(x['pcs_per_sqm']).toDouble()};
        // the same shortage the sale shows, in pieces, less what is already being made
        for (final l in lines) {
          final p = toPcs(l, widget.needOf(l));
          _pcs['${l['id']}']!.text = p == null ? '' : '${math.max(p - making(l), 0).round()}';
        }
      });
    } catch (_) {}
  }

  Future<void> _save() async {
    final out = [for (final l in lines) if ((numOf(_pcs['${l['id']}']!.text) ?? 0).round() > 0) {'sale_line_id': l['id'], 'pieces': (numOf(_pcs['${l['id']}']!.text) ?? 0).round()}];
    if (out.isEmpty) { setState(() => _error = 'Enter the pieces to make.'); return; }
    setState(() { _error = ''; _busy = true; });
    try {
      final id = await db.rpc('make_production_for_sale', params: {'p_sale': sale['id'], 'p': {'due_date': _due.isEmpty ? null : _due, 'lines': out}});
      if (mounted) Navigator.pop(context, id ?? true);
      return;
    } catch (e) {
      _error = dbError(e, "We couldn't start production. Please try again.");
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final advance = n(sale['total']) > 0 ? widget.paid / n(sale['total']) : 1.0;
    return FullPage(
      title: 'Make in production · order #${sale['sale_no']}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Send to the Planner')),
      ],
      children: [
        if (advance < saleAdvance - 1e-9) Alert('Paid ${(advance * 100).round()}% — production usually starts after a ${(saleAdvance * 100).round()}% advance.', tone: Tone.warning),
        for (final l in lines)
          () {
            final u = isSqm(l['product_id']) ? 'm²' : 'pcs';
            final k = '${l['product_id']}|${l['color_id'] ?? ''}';
            return CardBox(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(lineName(widget.refs, l), style: const TextStyle(fontWeight: FontWeight.w700)),
                PlHelp('left to deliver ${qtyText(math.max(n(l['quantity']) - doneOf(sale, l['id']), 0))} $u · in store ${_inStore != null ? '${qtyText(math.max(_inStore![k] ?? 0, 0))} $u' : '…'}'
                    '${making(l) > 0 ? ' · being made ${qtyText(making(l))} pcs' : ''}'),
                const SizedBox(height: 6),
                TextField(controller: _pcs['${l['id']}'], keyboardType: TextInputType.number, decoration: const InputDecoration(isDense: true, labelText: 'Make (pcs)')),
              ]),
            );
          }(),
        DateField(label: 'Needed by', value: _due, first: session.today, onChange: (v) => setState(() => _due = v)),
        const PlHelp('It becomes a production order in the Planner, named for this order; batches cast against it show here. Pieces made join the general stock.'),
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
      ],
    );
  }
}
