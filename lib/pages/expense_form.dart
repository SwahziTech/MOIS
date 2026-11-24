import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/session.dart';
import '../core/ui.dart';
import 'procurement_actions.dart';

/*
 * Record or change an expense — a port of web components/purchases/ExpenseModal.jsx (041) with
 * lib/lukuReceipt.js: electricity, water, tools… The category comes from the list; what was bought is
 * typed each time. An Electricity expense at a branch with LUKU meters is recorded as the meter's token
 * (072/074): paste the LUKU message to fill the fields. A production overhead names its machine (076).
 */
const paymentMethods = ['Cash', 'Mobile money', 'Bank transfer', 'Cheque'];
double _r2(num v) => (v * 100).roundToDouble() / 100;
double? _num(String v) => v.trim().isEmpty ? null : double.tryParse(v.trim().replaceAll(',', ''));
String _money(Object? v) => formatMoney(n(v), session.currency);
List<Json> _l(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];

/// Read a LUKU payment message into the token form's fields (only to fill them; all stay editable)
Map<String, Object?>? parseLukuReceipt(String raw) {
  final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return null;
  double? amount(String? s) => s == null ? null : double.tryParse(s.replaceAll(',', ''));
  String? pick(String re) => RegExp(re, caseSensitive: false).firstMatch(text)?.group(1);
  final units = amount(pick(r'([\d,]+(?:\.\d+)?)\s*KWH'));
  final cost = amount(pick(r'\bCost\s*:?\s*([\d,]+(?:\.\d+)?)'));
  final vat = amount(pick(r'\bVAT\s*(?:\d+(?:\.\d+)?\s*%)?\s*:?\s*([\d,]+(?:\.\d+)?)'));
  final ewura = amount(pick(r'\bEWURA\s*(?:\d+(?:\.\d+)?\s*%)?\s*:?\s*([\d,]+(?:\.\d+)?)'));
  final rea = amount(pick(r'\bREA\s*(?:\d+(?:\.\d+)?\s*%)?\s*:?\s*([\d,]+(?:\.\d+)?)'));
  final debt = amount(pick(r'\bDebt\s*(?:Collected)?\s*:?\s*([\d,]+(?:\.\d+)?)'));
  var total = amount(pick(r'\bTOTAL\s*(?:TZS|TSH)?\s*:?\s*([\d,]+(?:\.\d+)?)'));
  if (total == null && cost != null) total = _r2(cost + (vat ?? 0) + (ewura ?? 0) + (rea ?? 0) + (debt ?? 0));
  final tokenDigits = (pick(r'\bTOKEN\s*:?\s*((?:\d[\s-]?){20})') ?? '').replaceAll(RegExp(r'\D'), '');
  final token = tokenDigits.length == 20 ? tokenDigits.replaceAllMapped(RegExp(r'(\d{4})(?=\d)'), (m) => '${m[1]} ') : null;
  final date = pick(r'(\d{4}-\d{2}-\d{2})');
  final time = pick(r'\d{4}-\d{2}-\d{2}[ T](\d{1,2}:\d{2})');
  final refPart = pick(r'^(?:[^.]*\.)?\s*(.*?)\s*\bTOKEN\b');
  final refWords = refPart?.split(' ').where((w) => RegExp(r'\d').hasMatch(w) && w.length >= 6).join(' ');
  if (units == null && total == null && token == null) return null;
  return {'units': units, 'cost': cost, 'vat': vat, 'ewura': ewura, 'rea': rea, 'debt': debt, 'total': total, 'token': token, 'date': date,
    'time': time?.padLeft(5, '0'), 'ref': (refWords ?? '').isEmpty ? null : refWords};
}

/// prefill: from an approved request line (080) or an order line (082)
Future<bool> openExpenseForm(BuildContext context, {Json? expense, Json? prefill, required List<Json> categories, required List<Json> suppliers}) async =>
    await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ExpenseForm(expense: expense, prefill: prefill, categories: categories, suppliers: suppliers))) == true;

class _ExpenseForm extends StatefulWidget {
  const _ExpenseForm({this.expense, this.prefill, required this.categories, required this.suppliers});
  final Json? expense, prefill;
  final List<Json> categories, suppliers;
  @override
  State<_ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends State<_ExpenseForm> {
  Json? get e => widget.expense;
  Json? get pre => widget.prefill;
  bool get isNew => e == null;
  String get today => session.today;
  bool canRecordAt(String id) => id.isNotEmpty && session.canAt('procurement.receive', id, null);
  late final myBranches = session.branches.where((b) => canRecordAt(b.id)).toList();
  late String _branch = '${e?['branch_id'] ?? (canRecordAt(session.branchId) ? session.branchId : myBranches.firstOrNull?.id ?? '')}';
  late String _date = '${e?['expense_date'] ?? today}';
  late String _category = '${e?['category_id'] ?? pre?['category_id'] ?? ''}';
  late final _what = TextEditingController(text: '${e?['description'] ?? pre?['description'] ?? ''}');
  late final _qty = TextEditingController(text: e?['quantity'] != null ? p6s(n(e!['quantity'])) : pre?['quantity'] != null ? p6s(n(pre!['quantity'])) : '');
  late final _price = TextEditingController(text: e?['unit_price'] != null ? p6s(n(e!['unit_price'])) : '');
  late final _amount = TextEditingController(text: e != null ? p6s(n(e!['amount'])) : pre?['amount'] != null ? p6s(n(pre!['amount'])) : '');
  late String _supplierId = '${e?['supplier_id'] ?? ''}';
  final _newSupplier = TextEditingController();
  late bool _vatShown = e?['vat_amount'] != null;
  late final _paid = TextEditingController(text: e != null ? p6s(n(e!['amount_paid'])) : '');
  late String _method = '${e?['payment_method'] ?? ''}';
  late String _accountId = '${e?['account_id'] ?? ''}';
  late bool? _weekly = e?['from_weekly_cash'] as bool?;
  List<Json> _accounts = [], _meters = [], _machines = [];
  late String _paidOn = '${e?['paid_on'] ?? e?['expense_date'] ?? today}';
  late bool _paidOnSet = e?['paid_on'] != null;
  late final _notes = TextEditingController(text: '${e?['notes'] ?? ''}');
  bool _voiding = false, _busy = false;
  final _voidReason = TextEditingController();
  String _error = '';
  String _meterId = '';
  String _loadedTime = TimeOfDay.now().format24();
  Json? _token;
  late String _machineId = '${e?['machine_id'] ?? ''}';
  final Map<String, TextEditingController> _receipt = {for (final k in ['vat', 'ewura', 'rea', 'debt', 'ref']) k: TextEditingController()};
  final _pasted = TextEditingController();
  double _rate = 18;

  @override
  void initState() {
    super.initState();
    _loadBranch();
    if (e?['id'] != null) {
      db.from('power_tokens').select('*').eq('expense_id', e!['id']).maybeSingle().then((d) { if (mounted) setState(() => _token = d); }).catchError((_) {});
    }
  }

  Future<void> _loadBranch() async {
    if (_branch.isEmpty) return;
    try {
      final r = await Future.wait<dynamic>([
        db.from('payment_accounts').select('id, name, kind, status').eq('branch_id', _branch).order('display_order', ascending: true),
        db.from('power_meters').select('id, name, status').eq('branch_id', _branch).eq('status', 'active').order('name', ascending: true).then<List>((v) => v).catchError((_) => <dynamic>[]),
        db.from('machines').select('id, name, status').eq('branch_id', _branch).order('name', ascending: true).then<List>((v) => v).catchError((_) => <dynamic>[]),
        db.from('branches').select('vat_rate').eq('id', _branch).maybeSingle(),
      ]);
      if (!mounted) return;
      setState(() {
        _accounts = _l(r[0]).where((a) => a['status'] == 'active' || a['id'] == _accountId).toList();
        _meters = _l(r[1]);
        if (_meters.length == 1) _meterId = '${_meters.first['id']}';
        _machines = _l(r[2]).where((m) => m['status'] == 'active' || m['id'] == e?['machine_id']).toList();
        _rate = (r[3] as Map?)?['vat_rate'] != null ? n((r[3] as Map)['vat_rate']).toDouble() : 18;
      });
    } catch (_) {}
  }

  Json? get _cat => widget.categories.where((c) => c['id'] == _category).firstOrNull;
  bool get isOverhead => _cat?['in_production_cost'] == true;
  bool get isElectricity => isNew && _meters.isNotEmpty && RegExp(r'^\s*electricity\b', caseSensitive: false).hasMatch('${_cat?['name'] ?? ''}');
  double? get computed => _num(_qty.text) != null && _num(_price.text) != null ? _r2(_num(_qty.text)! * _num(_price.text)!) : null;
  double? get total => computed ?? _num(_amount.text);
  double? get vat => _vatShown && total != null ? _r2(total! * _rate / (100 + _rate)) : null;

  void _fromMessage(String text) {
    final r = parseLukuReceipt(text);
    if (r == null) return;
    setState(() {
      if (r['units'] != null) _qty.text = p6s(r['units'] as num);
      if (r['total'] != null) { _amount.text = p6s(r['total'] as num); _price.clear(); _paid.text = p6s(r['total'] as num); }
      if (r['token'] != null) _notes.text = '${r['token']}';
      if (r['date'] != null && '${r['date']}'.compareTo(today) <= 0) { _date = '${r['date']}'; if (!_paidOnSet) _paidOn = _date; }
      if (r['time'] != null) _loadedTime = '${r['time']}';
      for (final k in ['vat', 'ewura', 'rea', 'debt']) {
        if (r[k] != null) _receipt[k]!.text = p6s(r[k] as num);
      }
      if (r['ref'] != null) _receipt['ref']!.text = '${r['ref']}';
    });
  }

  Future<void> _save() async {
    setState(() => _error = '');
    void fail(String m) => setState(() { _busy = false; _error = m; });
    if (_branch.isEmpty) return fail('Choose the branch.');
    if (_category.isEmpty) return fail('Choose the category.');
    try {
      if (isElectricity) {
        if (_meterId.isEmpty) return fail('Choose the meter the token went on.');
        if (!((_num(_qty.text) ?? 0) > 0)) return fail('Enter the units bought.');
        if (total == null || !(total! >= 0)) return fail('Enter what was paid.');
        setState(() => _busy = true);
        final tokenId = await db.rpc('record_power_token', params: {'p': {
          'meter_id': _meterId, 'units': _num(_qty.text), 'amount': total, 'loaded_at': DateTime.parse('${_date}T${_loadedTime.isEmpty ? '12:00' : _loadedTime}').toUtc().toIso8601String(),
          'token_no': _notes.text.trim().isEmpty ? null : _notes.text.trim(), 'paid_from': _method.trim().isEmpty ? 'cash' : _method.trim(),
          'vat_amount': _num(_receipt['vat']!.text), 'ewura_levy': _num(_receipt['ewura']!.text), 'rea_levy': _num(_receipt['rea']!.text), 'debt_deducted': _num(_receipt['debt']!.text),
          'receipt_ref': _receipt['ref']!.text.trim().isEmpty ? null : _receipt['ref']!.text.trim(),
        }});
        if ((pre?['order_line_id'] != null || pre?['request_line_id'] != null) && tokenId != null) {
          final tk = await db.from('power_tokens').select('expense_id').eq('id', tokenId).maybeSingle();
          if (tk?['expense_id'] != null) {
            await (pre?['order_line_id'] != null
                ? db.rpc('link_expense_to_order_line', params: {'p_expense': tk!['expense_id'], 'p_line': pre!['order_line_id']})
                : db.rpc('link_expense_to_request', params: {'p_expense': tk!['expense_id'], 'p_line': pre!['request_line_id']}));
          }
        }
        if (mounted) Navigator.pop(context, true);
        return;
      }
      final qty = _num(_qty.text), paid = _num(_paid.text);
      if (_what.text.trim().isEmpty) return fail('Say what was bought or paid for.');
      if (_qty.text.trim().isNotEmpty && !(qty != null && qty > 0)) return fail('Quantity must be above zero, or leave it blank.');
      if (total == null || !(total! >= 0)) return fail('Enter the amount, or the quantity and price.');
      if ((paid ?? 0) > total!) return fail('Paid is more than the amount.');
      if ((paid ?? 0) > 0 && _weekly == null) return fail('Say where the money came from: the weekly cash, or the directors · bank.');
      if (_supplierId == '__new' && _newSupplier.text.trim().isEmpty) return fail("Type the new supplier's name, or choose none.");
      final account = _accounts.where((a) => a['id'] == _accountId).firstOrNull;
      final p = {
        'branch_id': _branch, 'expense_date': _date, 'category_id': _category, 'description': _what.text.trim(),
        'quantity': qty, 'unit_price': qty != null ? _num(_price.text) : null, 'amount': total,
        if (_supplierId == '__new') 'new_supplier_name': _newSupplier.text.trim() else if (_supplierId.isNotEmpty) 'supplier_id': _supplierId,
        'vat_amount': vat, 'amount_paid': paid ?? 0, 'payment_method': account != null ? account['kind'] : (_method.trim().isEmpty ? null : _method.trim()),
        if (_accounts.isNotEmpty) 'account_id': (paid ?? 0) > 0 && _accountId.isNotEmpty ? _accountId : null,
        'paid_on': (paid ?? 0) > 0 ? _paidOn : null, 'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
      };
      setState(() => _busy = true);
      final res = isNew ? await db.rpc('record_expense', params: {'p': p}) : await db.rpc('update_expense', params: {'p_id': e!['id'], 'p': p});
      final id = isNew ? res : e!['id'];
      if (isNew && pre?['order_line_id'] != null && res != null) {
        await db.rpc('link_expense_to_order_line', params: {'p_expense': res, 'p_line': pre!['order_line_id']});
      } else if (isNew && pre?['request_line_id'] != null && res != null) {
        await db.rpc('link_expense_to_request', params: {'p_expense': res, 'p_line': pre!['request_line_id']});
      }
      if ((isOverhead || e?['machine_id'] != null) && (_machineId.isEmpty ? null : _machineId) != e?['machine_id']) {
        await db.rpc('set_expense_machine', params: {'p_id': id, 'p_machine': isOverhead && _machineId.isNotEmpty ? _machineId : null});
      }
      if ((paid ?? 0) > 0) await saveWeeklyCash('expense', id, _weekly);
      if (mounted) Navigator.pop(context, true);
    } catch (err) {
      fail(dbError(err, isElectricity ? "We couldn't save this token. Please try again." : "We couldn't save this expense. Please try again."));
    }
  }

  Future<void> _voidIt() async {
    setState(() => _error = '');
    if (_voidReason.text.trim().isEmpty) return setState(() => _error = 'Give a reason.');
    setState(() => _busy = true);
    try {
      if (_token != null) {
        await db.rpc('void_power_token', params: {'p_id': _token!['id'], 'p_reason': _voidReason.text.trim()});   // voids its expense too
      } else {
        await db.rpc('void_expense', params: {'p_id': e!['id'], 'p_reason': _voidReason.text.trim()});
      }
      if (mounted) Navigator.pop(context, true);
    } catch (err) {
      setState(() { _busy = false; _error = dbError(err); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cats = widget.categories.where((c) => c['status'] == 'active' || c['id'] == e?['category_id']).toList();
    final suppliers = widget.suppliers.where((s) => s['status'] == 'active' || s['id'] == e?['supplier_id']).toList();
    final paid = _num(_paid.text);
    Widget gap() => const SizedBox(height: 12);
    InputDecoration dec(String l, [String? h]) => InputDecoration(labelText: l, hintText: h);
    const numKb = TextInputType.numberWithOptions(decimal: true);
    return FullPage(
      title: isNew ? 'Record expense' : 'Expense',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _save, child: Text(isNew ? 'Record expense' : 'Save changes')),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        const PlHelp('Not stock: LUKU, water, tools…'),
        gap(),
        if (isNew && session.branchId.isEmpty) ...[
          DropdownButtonFormField<String>(
            initialValue: _branch.isEmpty ? null : _branch, decoration: dec('Branch'),
            items: [for (final b in myBranches) DropdownMenuItem(value: b.id, child: Text(b.name))],
            onChanged: (v) { setState(() => _branch = v ?? ''); _loadBranch(); },
          ),
          gap(),
        ],
        Row(children: [
          Expanded(child: DateField(label: 'Date', value: _date, last: today, onChange: (v) => setState(() { _date = v; if (!_paidOnSet) _paidOn = v; }))),
          const SizedBox(width: 8),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: _category.isEmpty ? null : _category, isExpanded: true, decoration: dec('Category'),
              items: [for (final c in cats) DropdownMenuItem(value: '${c['id']}', child: Text('${c['name']}'))],
              onChanged: (v) => setState(() => _category = v ?? ''),
            ),
          ),
        ]),
        if (isElectricity) ...[
          gap(),
          TextField(controller: _pasted, minLines: 3, maxLines: 5, onChanged: _fromMessage, decoration: dec('Paste the LUKU message (optional — fills the form)', 'Malipo yamekamilika… TOKEN … KWH Cost … VAT … TOTAL TZS …')),
          gap(),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                initialValue: _meterId.isEmpty ? null : _meterId, isExpanded: true, decoration: dec('LUKU meter'),
                items: [for (final m in _meters) DropdownMenuItem(value: '${m['id']}', child: Text('${m['name']}'))],
                onChanged: (v) => setState(() { _meterId = v ?? ''; if (_what.text.trim().isEmpty) _what.text = 'LUKU token'; }),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: InkWell(
                onTap: () async {
                  final p = _loadedTime.split(':');
                  final tm = await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.tryParse(p.first) ?? 12, minute: int.tryParse(p.length > 1 ? p[1] : '0') ?? 0));
                  if (tm != null) setState(() => _loadedTime = tm.format24());
                },
                child: InputDecorator(decoration: dec('Loaded at').copyWith(helperText: 'Before the next meter reading.'), child: Text(_loadedTime)),
              ),
            ),
          ]),
          gap(),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (k, label) in const [('vat', 'VAT'), ('ewura', 'EWURA levy'), ('rea', 'REA levy'), ('debt', 'Old debt taken off')])
              SizedBox(width: 150, child: TextField(controller: _receipt[k], keyboardType: numKb, decoration: dec(label, '—'))),
            SizedBox(width: 308, child: TextField(controller: _receipt['ref'], decoration: dec('Receipt / transaction ref.'))),
          ]),
          const PlHelp('As on the token receipt.'),
        ],
        if (_token != null) ...[gap(), Alert('LUKU token: ${p6s(n(_token!['units']))} units on its meter. To change it, void it and enter it again.', tone: Tone.info)],
        gap(),
        // typed each time: names of tools and items are not kept as a list
        TextField(controller: _what, decoration: dec('What was it?', 'e.g. LUKU token, hammer, printer paper')),
        gap(),
        Row(children: [
          Expanded(child: TextField(controller: _qty, onChanged: (_) => setState(() {}), keyboardType: numKb, decoration: dec(isElectricity ? 'Units bought' : 'Quantity (optional)', '—'))),
          const SizedBox(width: 6),
          Expanded(child: TextField(controller: _price, onChanged: (_) => setState(() {}), keyboardType: numKb, decoration: dec(isElectricity ? 'Price a unit (optional)' : 'Price each (optional)', '—'))),
        ]),
        gap(),
        computed != null
            ? InputDecorator(decoration: dec('Amount').copyWith(helperText: 'Quantity × price.'), child: Text(p6s(computed!)))
            : TextField(controller: _amount, onChanged: (_) => setState(() {}), keyboardType: numKb, decoration: dec('Amount')),
        if (isOverhead && !isElectricity) ...[
          gap(),
          DropdownButtonFormField<String>(
            initialValue: _machineId, isExpanded: true, decoration: dec('For machine / line').copyWith(helperText: 'Production cost.'),
            items: [const DropdownMenuItem(value: '', child: Text('The whole branch')), for (final m in _machines) DropdownMenuItem(value: '${m['id']}', child: Text('${m['name']}'))],
            onChanged: (v) => setState(() => _machineId = v ?? ''),
          ),
        ],
        gap(),
        DropdownButtonFormField<String>(
          initialValue: _supplierId, isExpanded: true, decoration: dec('Supplier (optional)'),
          items: [
            const DropdownMenuItem(value: '', child: Text('None')),
            for (final s in suppliers) DropdownMenuItem(value: '${s['id']}', child: Text('${s['name']}', overflow: TextOverflow.ellipsis)),
            const DropdownMenuItem(value: '__new', child: Text('New supplier…')),
          ],
          onChanged: (v) => setState(() => _supplierId = v ?? ''),
        ),
        if (_supplierId == '__new') ...[const SizedBox(height: 8), TextField(controller: _newSupplier, textCapitalization: TextCapitalization.words, decoration: dec('', "Supplier's name"))],
        if (_rate > 0 || _vatShown) ...[
          CheckboxListTile(contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, value: _vatShown, onChanged: (v) => setState(() => _vatShown = v ?? false),
              title: Text('VAT (${p6s(_rate)}%) is included in the amount')),
          if (_vatShown && total != null) PlHelp('VAT: ${_money(vat)} = ${_money(total)} × ${p6s(_rate)}/${p6s(100 + _rate)}'),
        ],
        gap(),
        TextField(controller: _paid, onChanged: (_) => setState(() {}), keyboardType: numKb, decoration: dec('Paid', '0 = not paid yet')),
        gap(),
        _accounts.isNotEmpty
            ? DropdownButtonFormField<String>(
                initialValue: _accountId, isExpanded: true, decoration: dec('Paid from'),
                items: [const DropdownMenuItem(value: '', child: Text('Choose the account…')), for (final a in _accounts) DropdownMenuItem(value: '${a['id']}', child: Text('${a['name']}'))],
                onChanged: (v) => setState(() => _accountId = v ?? ''),
              )
            : DropdownButtonFormField<String>(
                initialValue: _method, isExpanded: true, decoration: dec('How'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('Choose…')),
                  for (final m in [if (_method.isNotEmpty && !paymentMethods.contains(_method)) _method, ...paymentMethods]) DropdownMenuItem(value: m, child: Text(m)),
                ],
                onChanged: (v) => setState(() => _method = v ?? ''),
              ),
        if ((paid ?? 0) > 0) ...[
          gap(),
          DateField(label: 'Paid on', value: _paidOn, last: today, onChange: (v) => setState(() { _paidOn = v; _paidOnSet = true; })),
          gap(),
          PaidFrom(value: _weekly, onChange: (v) => setState(() => _weekly = v)),
        ],
        gap(),
        TextField(controller: _notes, decoration: dec(isElectricity ? 'Token number (optional)' : 'Notes (optional)')),
        if (!isNew) ...[
          const SectionTitle('Entered wrongly?'),
          if (_voiding) ...[
            const PlHelp('Voiding keeps it on record, marked void.'),
            const SizedBox(height: 6),
            TextField(controller: _voidReason, decoration: dec('', 'Reason')),
            Row(children: [
              OutlinedButton(onPressed: _busy ? null : _voidIt, child: const Text('Void expense')),
              TextButton(onPressed: () => setState(() => _voiding = false), child: const Text('Keep it')),
            ]),
          ] else
            Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => setState(() => _voiding = true), child: const Text('Void this expense…'))),
        ],
      ],
    );
  }
}

extension on TimeOfDay {
  String format24() => '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';
}
