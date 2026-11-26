import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/proof_box.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';

/*
 * What can be done to a purchase or an expense — ports of web PayPurchaseModal + PaidFrom/saveWeeklyCash
 * (components/purchases/ProcurementPanels.jsx, PaidFrom.jsx), DeliveryModal, PurchaseDeliveries and
 * DeletePurchase (pages/Purchases.jsx) and AddProofModal. Each opens full screen and returns true when saved.
 */
double _r2(num v) => (v * 100).roundToDouble() / 100;
double? _num(String v) => v.trim().isEmpty ? null : double.tryParse(v.trim().replaceAll(',', ''));
String _money(Object? v) => formatMoney(n(v), session.currency);
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];

Future<bool> _push(BuildContext context, Widget page) async => await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => page)) == true;

/// A date field that opens the date picker
class DateField extends StatelessWidget {
  const DateField({super.key, required this.label, required this.value, required this.onChange, this.first, this.last, this.enabled = true});
  final String label, value;
  final ValueChanged<String> onChange;
  final String? first, last;
  final bool enabled;
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: !enabled
            ? null
            : () async {
                final lo = DateTime.parse(first ?? '2020-01-01'), hi = DateTime.parse(last ?? '2100-12-31');
                // an empty date opens on today, kept inside first..last
                var start = DateTime.tryParse(value) ?? DateTime.parse(session.today);
                if (start.isBefore(lo)) start = lo;
                if (start.isAfter(hi)) start = hi;
                final d = await showDatePicker(context: context, initialDate: start, firstDate: lo, lastDate: hi);
                if (d != null) onChange(iso(d));
              },
        child: InputDecorator(decoration: InputDecoration(labelText: label, enabled: enabled), child: Text(value.isEmpty ? '—' : (tableDate(value) ?? value))),
      );
}

/// Where the money came from (121): the branch's weekly cash, or the directors / a bank — the person says which
class PaidFrom extends StatelessWidget {
  const PaidFrom({super.key, required this.value, required this.onChange});
  final bool? value;
  final ValueChanged<bool> onChange;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const PlLabel('Money from'),
        const SizedBox(height: 6),
        Wrap(spacing: 6, children: [
          Chip2('Weekly cash (branch)', on: value == true, onTap: () => onChange(true)),
          Chip2('Directors · bank', on: value == false, onTap: () => onChange(false)),
        ]),
      ]);
}

/// Save the weekly-cash choice (121)
Future<void> saveWeeklyCash(String kind, Object? id, bool? on) async {
  if (id == null || on == null) return;
  try {
    await db.rpc('set_weekly_cash', params: {'p_kind': kind, 'p_id': id, 'p_on': on});
  } catch (_) {}
}

// ---- Pay a purchase ----------------------------------------------------------------------------
Future<bool> payPurchase(BuildContext context, {required Json purchase, required Object? total, required String supplierName}) =>
    _push(context, _PayPurchase(purchase: purchase, total: n(total).toDouble(), supplierName: supplierName));

class _PayPurchase extends StatefulWidget {
  const _PayPurchase({required this.purchase, required this.total, required this.supplierName});
  final Json purchase;
  final double total;
  final String supplierName;
  @override
  State<_PayPurchase> createState() => _PayPurchaseState();
}

class _PayPurchaseState extends State<_PayPurchase> {
  Json get p => widget.purchase;
  late final double owedAtStart = _r2(widget.total - n(p['amount_paid']));
  late final _amount = TextEditingController(text: owedAtStart > 0 ? p6s(owedAtStart) : '');
  late String _paidOn = session.today;
  String _accountId = '', _method = 'cash';
  final _reference = TextEditingController();
  // a director's payment carries its proof (106)
  late final bool withProof = session.canAt('finance.pay', '${p['branch_id']}', null);
  late bool? _weekly = withProof ? false : null;
  ProofFile? _file;
  final _sms = TextEditingController();
  List<Json> _payments = [], _accounts = [];
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    Future.wait<dynamic>([
      db.from('purchase_payments').select('*').eq('purchase_id', p['id']).order('paid_on', ascending: true),
      db.from('payment_accounts').select('id, name, branch_id, status').eq('status', 'active').eq('branch_id', p['branch_id']).order('display_order', ascending: true),
    ]).then((r) { if (mounted) setState(() { _payments = _l(r[0]); _accounts = _l(r[1]); }); }).catchError((_) {});
  }

  Future<void> _save() async {
    setState(() => _error = '');
    final amount = _num(_amount.text);
    if (!(amount != null && amount > 0)) return setState(() => _error = 'Enter the amount paid.');
    if (withProof && _file == null && _sms.text.trim().isEmpty) return setState(() => _error = 'Add the proof: a photo or the SMS.');
    if (_weekly == null) return setState(() => _error = 'Say where the money came from: the weekly cash, or the directors · bank.');
    setState(() => _busy = true);
    Object? payId;
    try {
      payId = await db.rpc('record_purchase_payment', params: {'p_purchase': p['id'], 'p': {'amount': amount, 'paid_on': _paidOn, 'account_id': _accountId.isEmpty ? null : _accountId, 'method': _accountId.isEmpty ? _method : null, 'reference': _reference.text}});
    } catch (e) {
      return setState(() { _busy = false; _error = dbError(e); });
    }
    await saveWeeklyCash('purchase_payment', payId, _weekly);
    if (withProof) {
      try {
        final path = _file == null ? null : await uploadProof('director-proofs', '${p['branch_id']}', 'dp', _file!);
        await db.rpc('post_director_payment', params: {'p': {
          'branch_id': p['branch_id'], 'kind': 'supplier', 'ref_id': p['id'], 'description': widget.supplierName, 'amount': amount,
          'account_id': _accountId.isEmpty ? null : _accountId, 'paid_on': _paidOn, 'file_path': path,
          'file_name': _file == null ? null : proofName(kind: 'Paid-Supplier', who: widget.supplierName, amount: amount, date: _paidOn, ext: _file!.ext),
          'sms_text': _sms.text.trim().isEmpty ? null : _sms.text.trim(),
        }});
      } catch (e) {
        return setState(() { _busy = false; _error = 'Paid, but the proof was not kept: ${dbError(e)}'; });
      }
    }
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final paid = n(p['amount_paid']).toDouble();
    final owed = _r2(widget.total - paid);
    return FullPage(
      title: 'Pay ${widget.supplierName} — purchase of ${dateText(p['purchase_date'])}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy || owed <= 0 ? null : _save, child: const Text('Record payment')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        Text.rich(TextSpan(children: [
          const TextSpan(text: 'Total '), TextSpan(text: _money(widget.total), style: const TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: ' · paid ${_money(paid)} · '),
          TextSpan(text: '${_money(owed)} owed', style: TextStyle(fontWeight: FontWeight.w700, color: owed > 0 ? C.warning : null)),
        ])),
        if (_payments.isNotEmpty) PlHelp(_payments.map((x) => '${dateText(x['paid_on'])}: ${_money(x['amount'])}${x['kind'] == 'at_purchase' ? ' (with the purchase)' : ''}').join(' · ')),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: _amount, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount'))),
          const SizedBox(width: 8),
          Expanded(child: DateField(label: 'Paid on', value: _paidOn, last: session.today, onChange: (v) => setState(() => _paidOn = v))),
        ]),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: _accountId, isExpanded: true, decoration: const InputDecoration(labelText: 'Paid from'),
          items: [const DropdownMenuItem(value: '', child: Text('— a method —')), for (final a in _accounts) DropdownMenuItem(value: '${a['id']}', child: Text('${a['name']}'))],
          onChanged: (v) => setState(() => _accountId = v ?? ''),
        ),
        if (_accountId.isEmpty) ...[
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _method, decoration: const InputDecoration(labelText: 'Method'),
            items: const [DropdownMenuItem(value: 'cash', child: Text('Cash')), DropdownMenuItem(value: 'bank', child: Text('Bank')), DropdownMenuItem(value: 'mobile_money', child: Text('Mobile money'))],
            onChanged: (v) => setState(() => _method = v ?? 'cash'),
          ),
        ],
        const SizedBox(height: 12),
        TextField(controller: _reference, decoration: const InputDecoration(labelText: 'Reference (optional)')),
        if (!withProof) ...[const SizedBox(height: 12), PaidFrom(value: _weekly, onChange: (v) => setState(() => _weekly = v))],
        if (withProof) ...[const SizedBox(height: 12), ProofBox(file: _file, onFile: (f) => setState(() => _file = f), text: _sms, onText: () => setState(() {}))],
      ],
    );
  }
}

String p6s(num v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

// ---- Record a delivery -------------------------------------------------------------------------
Future<bool> recordDelivery(BuildContext context, {required Json purchase, required Json? status, required Refs refs}) =>
    _push(context, _Delivery(purchase: purchase, status: status, refs: refs));

class _Delivery extends StatefulWidget {
  const _Delivery({required this.purchase, required this.status, required this.refs});
  final Json purchase;
  final Json? status;
  final Refs refs;
  @override
  State<_Delivery> createState() => _DeliveryState();
}

class _DeliveryState extends State<_Delivery> {
  late final List<Json> items = _l(widget.status?['items']);
  double left(Json i) => ((n(i['quantity']) - n(i['delivered'])) * 10000).roundToDouble() / 10000 > 0 ? ((n(i['quantity']) - n(i['delivered'])) * 10000).roundToDouble() / 10000 : 0;
  late final Map<String, TextEditingController> _qty = {for (final i in items) '${i['item_id']}': TextEditingController(text: left(i) > 0 ? p6s(left(i)) : '')};
  late String _date = session.today;
  final _who = TextEditingController();
  bool _busy = false;
  String _error = '';

  Future<void> _save() async {
    setState(() => _error = '');
    final lines = [for (final i in items) if ((_num(_qty['${i['item_id']}']!.text) ?? 0) > 0) {'item_id': i['item_id'], 'quantity': _num(_qty['${i['item_id']}']!.text)}];
    if (lines.isEmpty) return setState(() => _error = 'Enter what came.');
    final over = items.where((i) => (_num(_qty['${i['item_id']}']!.text) ?? 0) > left(i) + 1e-9).firstOrNull;
    if (over != null) return setState(() => _error = '${widget.refs.items['m:${over['material_id']}']?.name}: only ${qtyText(left(over))} more to come.');
    setState(() => _busy = true);
    try {
      await db.rpc('record_purchase_delivery', params: {'p_purchase': widget.purchase['id'], 'p': {'delivered_on': _date, 'received_by': _who.text.trim().isEmpty ? null : _who.text.trim(), 'lines': lines}});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e, "We couldn't record the delivery."); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final p = widget.purchase;
    final before = _l(p['deliveries'])..sort((a, b) => '${b['delivered_on']}'.compareTo('${a['delivered_on']}'));
    return FullPage(
      title: 'Delivery · purchase of ${dateText(p['purchase_date'])}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Record delivery')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        for (final i in items)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(widget.refs.items['m:${i['material_id']}']?.name ?? '—', style: const TextStyle(fontWeight: FontWeight.w600)),
                  PlHelp('Bought ${qtyText(n(i['quantity']))} ${widget.refs.unit('${i['unit_id']}')} · came before ${n(i['delivered']) > 0 ? '${qtyText(_r2(n(i['delivered'])))} ${widget.refs.unit('${i['unit_id']}')}' : '—'}'),
                ]),
              ),
              SizedBox(
                width: 110,
                child: left(i) > 0
                    ? TextField(controller: _qty['${i['item_id']}'], keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Came now', suffixText: widget.refs.unit('${i['unit_id']}')))
                    : const PlHelp('all came'),
              ),
            ]),
          ),
        const SizedBox(height: 12),
        Row(children: [
          // for testing (126): whoever receives may date a delivery back to the purchase day
          Expanded(child: DateField(label: 'Date it came', value: _date, first: '${p['purchase_date']}', last: session.today, onChange: (v) => setState(() => _date = v))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _who, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Received by'))),
        ]),
        if (before.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: PlHelp('Came before: ${before.map((d) => '${dateText(d['delivered_on'])}${'${d['received_by'] ?? ''}'.isNotEmpty ? ' (${d['received_by']})' : ''}').join(' · ')}')),
      ],
    );
  }
}

// ---- A purchase's deliveries (133): each one's date, what came, who received it; Change for one bought from an order ----
class PurchaseDeliveries extends StatefulWidget {
  const PurchaseDeliveries({super.key, required this.purchase, required this.refs, required this.canEdit, required this.onChanged});
  final Json purchase;
  final Refs refs;
  final bool canEdit;
  final VoidCallback onChanged;
  @override
  State<PurchaseDeliveries> createState() => _PurchaseDeliveriesState();
}

class _PurchaseDeliveriesState extends State<PurchaseDeliveries> {
  List<({String id, String date, String by, List<({String itemId, String materialId, String unitId, double qty})> items})>? _rows;
  final Map<String, ({String date, Map<String, TextEditingController> qty})> _drafts = {};
  bool _editing = false;
  String _busy = '', _error = '';

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final ds = await db.from('purchase_deliveries').select('id, delivered_on, received_by, movement_id').eq('purchase_id', widget.purchase['id']).order('delivered_on', ascending: true);
      final mids = [for (final d in ds) if (d['movement_id'] != null) d['movement_id']];
      final r = await Future.wait<dynamic>([
        mids.isEmpty ? Future.value(<dynamic>[]) : db.from('inventory_transactions').select('id, movement_id, material_id, entered_quantity, entered_unit_id').inFilter('movement_id', mids).not('material_id', 'is', null),
        db.from('purchase_lines').select('transaction_id, item_id').eq('purchase_id', widget.purchase['id']),
      ]);
      final itemOfTx = {for (final x in r[1] as List) '${x['transaction_id']}': '${x['item_id']}'};
      if (!mounted) return;
      setState(() => _rows = [
            for (final d in ds)
              (
                id: '${d['id']}', date: '${d['delivered_on']}', by: '${d['received_by'] ?? ''}',
                items: [
                  for (final t in r[0] as List)
                    if (t['movement_id'] == d['movement_id']) (itemId: itemOfTx['${t['id']}'] ?? '', materialId: '${t['material_id']}', unitId: '${t['entered_unit_id']}', qty: n(t['entered_quantity']).toDouble()),
                ],
              ),
          ]);
    } catch (_) {
      if (mounted) setState(() => _rows = []);
    }
  }

  ({String date, Map<String, TextEditingController> qty}) _draft(({String id, String date, String by, List<({String itemId, String materialId, String unitId, double qty})> items}) r) =>
      _drafts[r.id] ??= (date: r.date, qty: {for (final i in r.items) i.itemId: TextEditingController(text: p6s(i.qty))});

  Future<void> _save(({String id, String date, String by, List<({String itemId, String materialId, String unitId, double qty})> items}) r, {bool remove = false}) async {
    setState(() { _error = ''; _busy = r.id; });
    final d = _draft(r);
    try {
      await db.rpc('change_purchase_delivery', params: {'p_delivery': r.id, 'p': {
        'delivered_on': d.date,
        'lines': [for (final i in r.items) {'item_id': i.itemId, 'quantity': remove ? 0 : ((_num(d.qty[i.itemId]!.text) ?? 0) * 1000).roundToDouble() / 1000}],
      }});
      _drafts.clear();
      await _load();
      widget.onChanged();
    } catch (e) {
      _error = dbError(e, "We couldn't change the delivery.");
    }
    if (mounted) setState(() => _busy = '');
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows == null) return const Skeleton(rows: 1, height: 24);
    final refs = widget.refs;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SectionTitle('Deliveries', trailing: widget.canEdit && rows.isNotEmpty ? TextButton(onPressed: () => setState(() => _editing = !_editing), child: Text(_editing ? 'Done changing' : 'Change')) : null),
      if (rows.isEmpty) const PlHelp('No delivery recorded yet.'),
      for (final r in rows)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _editing
              ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  DateField(label: 'Date', value: _draft(r).date, first: '${widget.purchase['purchase_date']}', last: session.today,
                      onChange: (v) => setState(() => _drafts[r.id] = (date: v, qty: _draft(r).qty))),
                  for (final i in r.items)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: TextField(controller: _draft(r).qty[i.itemId], keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(labelText: refs.items['m:${i.materialId}']?.name ?? '', suffixText: refs.unit(i.unitId))),
                    ),
                  Row(children: [
                    FilledButton(onPressed: _busy == r.id ? null : () => _save(r), child: const Text('Save')),
                    const SizedBox(width: 8),
                    TextButton(onPressed: _busy == r.id ? null : () => _save(r, remove: true), child: const Text('Remove')),
                  ]),
                ])
              : Text('${tableDate(r.date) ?? ''} · ${r.items.map((i) => '${qtyText(i.qty)} ${refs.unit(i.unitId)} ${refs.items['m:${i.materialId}']?.name ?? ''}').join(', ')}${r.by.isNotEmpty ? ' · ${r.by}' : ''}',
                  style: const TextStyle(fontSize: Fs.sm)),
        ),
      if (_error.isNotEmpty) PlHelp(_error, color: C.error),
    ]);
  }
}

// ---- Add a proof of payment to a purchase or an expense (134) --------------------------------
Future<bool> addProcurementProof(BuildContext context, {required String kind, required Object id, required Object branchId, Object? amount, Object? paidOn, required String who}) =>
    _push(context, _AddProof(kind: kind, id: id, branchId: '$branchId', amount: amount, paidOn: paidOn, who: who));

class _AddProof extends StatefulWidget {
  const _AddProof({required this.kind, required this.id, required this.branchId, this.amount, this.paidOn, required this.who});
  final String kind, branchId, who;
  final Object id;
  final Object? amount, paidOn;
  @override
  State<_AddProof> createState() => _AddProofState();
}

class _AddProofState extends State<_AddProof> {
  ProofFile? _file;
  final _sms = TextEditingController();
  late String _paidOn = '${widget.paidOn ?? session.today}';
  late final _amount = TextEditingController(text: n(widget.amount) > 0 ? '${n(widget.amount).round()}' : '');
  bool _busy = false;
  String _error = '';

  Future<void> _save() async {
    setState(() => _error = '');
    if (_file == null && _sms.text.trim().isEmpty) return setState(() => _error = 'Add the proof: a photo, a PDF or the SMS.');
    setState(() => _busy = true);
    try {
      final path = _file == null ? null : await uploadProof('payment-proofs', widget.branchId, 'procurement', _file!);
      final amount = _num(_amount.text);
      await db.rpc('add_procurement_proof', params: {'p': {
        'kind': widget.kind, 'ref_id': widget.id, 'paid_on': _paidOn, 'amount': amount, 'file_path': path,
        'file_name': _file == null ? null : proofName(kind: widget.kind == 'purchase' ? 'Paid-Supplier' : 'Paid-Expense', who: widget.who, amount: amount, date: _paidOn, ext: _file!.ext),
        'sms_text': _sms.text.trim().isEmpty ? null : _sms.text.trim(),
      }});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e, "We couldn't keep the proof."); });
    }
  }

  @override
  Widget build(BuildContext context) => FullPage(
        title: 'Proof of payment · ${widget.who}',
        footer: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Keep the proof')),
        ],
        children: [
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
          Row(children: [
            Expanded(child: DateField(label: 'Paid on', value: _paidOn, last: session.today, onChange: (v) => setState(() => _paidOn = v))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount (optional)'))),
          ]),
          const SizedBox(height: 12),
          ProofBox(file: _file, onFile: (f) => setState(() => _file = f), text: _sms, onText: () => setState(() {})),
        ],
      );
}

// ---- Delete a void purchase (technical admin, 040) --------------------------------------------
Future<bool> deletePurchase(BuildContext context, {required Json purchase, required String goods}) => _push(context, _DeletePurchase(purchase: purchase, goods: goods));

class _DeletePurchase extends StatefulWidget {
  const _DeletePurchase({required this.purchase, required this.goods});
  final Json purchase;
  final String goods;
  @override
  State<_DeletePurchase> createState() => _DeletePurchaseState();
}

class _DeletePurchaseState extends State<_DeletePurchase> {
  final _reason = TextEditingController();
  bool _undo = false, _busy = false;
  String _error = '';

  Future<void> _remove() async {
    setState(() => _error = '');
    if (_reason.text.trim().isEmpty) return setState(() => _error = 'Give a reason.');
    setState(() => _busy = true);
    try {
      await db.rpc('delete_purchase', params: {'p_id': widget.purchase['id'], 'p_reason': _reason.text.trim(), 'p_undo_receipt': _undo});
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e, "We couldn't delete this purchase. Please try again."); });
    }
  }

  @override
  Widget build(BuildContext context) => FullPage(
        title: 'Delete the purchase of ${dateText(widget.purchase['purchase_date'])}',
        footer: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Keep it')),
          OutlinedButton(style: OutlinedButton.styleFrom(foregroundColor: C.error, side: const BorderSide(color: C.error)), onPressed: _busy ? null : _remove, child: const Text('Delete purchase')),
        ],
        children: [
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
          Text('Deleting removes this purchase${widget.purchase['status'] == 'void' ? ' (void)' : ''} from the list for good — supplier, prices and payment. The audit log keeps a copy of every value.', style: const TextStyle(fontSize: Fs.sm)),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: _undo, onChanged: (v) => setState(() => _undo = v ?? false),
            title: Text('Also undo the goods received${widget.goods.isNotEmpty ? ' (${widget.goods})' : ''} — they never arrived, or the quantity was wrong', style: const TextStyle(fontSize: Fs.sm)),
          ),
          PlHelp(_undo
              ? 'The receipt is reversed, dated as the original. This is refused if the stock has since been used.'
              : 'The goods stay in stock and the receipt goes back under "Waiting for details", to be completed again with the right details.'),
          const SizedBox(height: 10),
          TextField(controller: _reason, decoration: const InputDecoration(hintText: 'Reason (required)')),
        ],
      );
}
