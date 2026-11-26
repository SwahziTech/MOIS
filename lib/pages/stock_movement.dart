import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/inventory.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';

/*
 * Record one stock movement — a port of web components/inventory/MovementModal.jsx (with
 * lib/doubleEntry.js). Everything is validated again and posted atomically by
 * post_inventory_movement() (022); this form offers only what the person may do and shows the
 * effect before posting. Corrections and backdated entries by non-admins go to Approvals (033).
 * A likely double entry is asked about before anything is posted (it never blocks).
 */
class _Line {
  _Line(this.kind);
  String kind; // material | product
  String key = '', colorId = '', quantity = '', unitId = '', unitCost = '', direction = 'remove';
}

String _kindForStore(Store? w) => w?.type == 'finished_goods' ? 'product' : 'material';

class MovementPage extends StatefulWidget {
  const MovementPage({super.key, required this.type, required this.refs, required this.balances, this.defaultWarehouseId, this.defaultItemKey, this.kind, this.prefill});
  final String type;
  final Refs refs;
  final Map<String, double> balances;
  final String? defaultWarehouseId, defaultItemKey, kind;
  /// a sheet filled elsewhere (Daily report › Upload a report › Stock count): its date, lines { key, colorId, unitId, quantity } and a note
  final ({String date, List<Map<String, String>> lines, String note})? prefill;
  @override
  State<MovementPage> createState() => _MovementPageState();
}

class _MovementPageState extends State<MovementPage> {
  late final MoveType def = movementTypes[widget.type]!;
  Refs get refs => widget.refs;
  String get type => widget.type;
  String get today => session.today;

  late final String? itemKind = widget.kind ??
      ((widget.defaultItemKey ?? '').startsWith('m:') ? 'material' : (widget.defaultItemKey ?? '').startsWith('p:') ? 'product' : null);
  bool _storeFits(Store w) => itemKind == 'material' ? (w.type == 'raw_materials' || w.type == 'general')
      : itemKind == 'product' ? (w.type == 'finished_goods' || w.type == 'rejects') : true;
  late final List<Store> allowed = refs.warehouses.where((w) => w.status == 'active' && w.row['branch']?['status'] != 'inactive' &&
      session.inBranch(w.branchId) && session.canAt(def.perm, w.branchId, w.id) && _storeFits(w)).toList();

  late String warehouseId = allowed.any((w) => w.id == widget.defaultWarehouseId) ? widget.defaultWarehouseId! : (allowed.firstOrNull?.id ?? '');
  String toWarehouseId = '';
  ({String? id, String? newName, bool pending})? supplier;
  late String date = widget.prefill?.date ?? today;
  Map<String, double>? asOf;
  final reference = TextEditingController(), reason = TextEditingController(), notes = TextEditingController();
  late List<_Line> lines = widget.prefill == null
      ? [_firstLine()]
      : [
          for (final l in widget.prefill!.lines)
            _Line(refs.items[l['key']]?.kind ?? 'material')
              ..key = l['key'] ?? ''
              ..colorId = l['colorId'] ?? ''
              ..unitId = l['unitId'] ?? ''
              ..quantity = l['quantity'] ?? '',
        ];

  @override
  void initState() {
    super.initState();
    if (date.compareTo(today) < 0) _loadAsOf();
  }
  bool busy = false, submitted = false;
  String error = '';
  List<({int idx, List<Json> existing})>? repeats;
  List<_Line>? repeatFilled;
  final Map<int, String> choices = {};

  _Line _firstLine() {
    final k = widget.defaultItemKey;
    final it = k == null ? null : refs.items[k];
    if (it != null) {
      return _Line(it.kind)
        ..key = k!
        ..unitId = it.mainUnitId ?? it.stockUnitId ?? '';
    }
    return _Line(_kindForStore(refs.store(warehouseId)));
  }

  Store? get wh => refs.store(warehouseId);
  bool get canBackdate => wh != null && session.canAt('inventory.adjust', wh!.branchId, wh!.id);
  bool get needsApproval => !session.canManage('inventory.adjust') &&
      (isCorrective(type, date, today) || (type == 'count' && wh != null && !session.canAt('inventory.adjust', wh!.branchId, wh!.id)));

  @override
  void dispose() { reference.dispose(); reason.dispose(); notes.dispose(); super.dispose(); }

  String _skey(String itemKey, String colorId) => '$itemKey${colorId.isNotEmpty ? '|c:$colorId' : ''}';
  double _balanceOf(_Line l) => (asOf ?? widget.balances)['$warehouseId|${_skey(l.key, l.colorId)}'] ?? 0;

  Future<void> _loadAsOf() async {
    if (date.compareTo(today) >= 0) { setState(() => asOf = null); return; }
    try {
      final data = await db.rpc('stock_balances_as_of', params: {'p_date': date});
      final m = <String, double>{};
      for (final b in data as List) {
        final key = b['material_id'] != null ? 'm:${b['material_id']}' : 'p:${b['product_id']}';
        m['${b['warehouse_id']}|$key${b['color_id'] != null ? '|c:${b['color_id']}' : ''}'] = n(b['quantity']);
      }
      if (mounted) setState(() => asOf = m);
    } catch (_) {}
  }

  double? _stockQty(_Line l) {
    final item = refs.items[l.key];
    final f = item?.units.where((u) => u.id == l.unitId).firstOrNull?.factor;
    final q = double.tryParse(l.quantity.trim());
    return item != null && f != null && q != null ? q * f : null;
  }

  List<List<int>> get _twice {
    final g = <String, List<int>>{};
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].key.isNotEmpty) g.putIfAbsent('${lines[i].key}|${lines[i].colorId}', () => []).add(i);
    }
    return g.values.where((x) => x.length > 1).toList();
  }

  void _mergeLines(List<int> group) {
    final ls = [for (final i in group) lines[i]];
    final item = refs.items[ls.first.key]!;
    final sameUnit = ls.every((l) => l.unitId == ls.first.unitId);
    double signed(_Line l) => (type == 'adjustment' && l.direction == 'remove' ? -1 : 1) * (sameUnit ? (double.tryParse(l.quantity) ?? 0) : (_stockQty(l) ?? 0));
    final sum = ls.fold<double>(0, (s, l) => s + signed(l));
    final merged = _Line(ls.first.kind)
      ..key = ls.first.key
      ..colorId = ls.first.colorId
      ..quantity = qtyText(sum.abs()).replaceAll(',', '')
      ..unitId = sameUnit ? ls.first.unitId : (item.stockUnitId ?? '')
      ..direction = type == 'adjustment' ? (sum < 0 ? 'remove' : 'add') : ls.first.direction
      ..unitCost = ls.where((l) => l.unitCost.isNotEmpty).firstOrNull?.unitCost ?? '';
    setState(() {
      final keep = [for (var i = 0; i < lines.length; i++) if (!group.skip(1).contains(i)) i == group.first ? merged : lines[i]];
      lines = keep;
    });
  }

  Future<void> _post() async {
    setState(() => error = '');
    final filled = lines.where((l) => l.key.isNotEmpty).toList();
    String? err;
    if (filled.isEmpty) err = 'Add at least one item.';
    if (err == null && _twice.isNotEmpty) err = 'An item is entered twice — merge the lines, or remove one.';
    final noColour = filled.where((l) => (refs.items[l.key]?.colorIds.isNotEmpty ?? false) && l.colorId.isEmpty).firstOrNull;
    if (err == null && noColour != null) err = '${refs.items[noColour.key]!.name}: choose the colour.';
    if (err == null) {
      for (final l in filled) {
        final q = double.tryParse(l.quantity.trim());
        if (q == null || (type == 'count' ? q < 0 : q <= 0)) {
          err = '${refs.items[l.key]!.name}: enter a ${type == 'count' ? 'quantity of zero or more' : 'quantity above zero'}.';
          break;
        }
      }
    }
    if (err == null && type == 'transfer' && toWarehouseId.isEmpty) err = 'Choose where the stock goes.';
    if (err == null && type == 'adjustment' && reason.text.trim().isEmpty) err = 'Give a reason for the adjustment.';
    if (err == null && (supplier?.pending ?? false)) err = 'Choose one of the suggested suppliers, or confirm the new one.';
    if (err != null) { setState(() => error = err!); return; }
    setState(() => busy = true);
    List<({int idx, List<Json> existing})> found = [];
    try { found = await _findRepeats(filled); } catch (_) {}
    setState(() => busy = false);
    if (found.isNotEmpty) { setState(() { repeats = found; repeatFilled = filled; choices.clear(); }); return; }
    await _send(filled, []);
  }

  /// lib/doubleEntry.js findRepeats
  Future<List<({int idx, List<Json> existing})>> _findRepeats(List<_Line> filled) async {
    if (type == 'count' || filled.isEmpty || wh == null) return [];
    final txType = type == 'transfer' ? 'transfer_out' : type;
    final mats = {for (final l in filled) if (l.kind == 'material') refs.items[l.key]!.id}.toList();
    final prods = {for (final l in filled) if (l.kind == 'product') refs.items[l.key]!.id}.toList();
    final or = [if (mats.isNotEmpty) 'material_id.in.(${mats.join(',')})', if (prods.isNotEmpty) 'product_id.in.(${prods.join(',')})'].join(',');
    var q = db.from('inventory_transactions').select('id, movement_id, warehouse_id, branch_id, material_id, product_id, color_id, quantity, stock_unit_id, transaction_type, transaction_date, created_at')
        .eq('branch_id', wh!.branchId).eq('transaction_type', txType).or(or);
    if (type != 'opening_balance') q = q.eq('warehouse_id', wh!.id).eq('transaction_date', date);
    final res = await Future.wait<dynamic>([q, db.from('inventory_movements').select('reverses_movement_id').not('reverses_movement_id', 'is', null)]);
    final reversed = {for (final r in res[1] as List) r['reverses_movement_id']};
    final existing = [for (final l in res[0] as List) if (l['transaction_type'] != 'reversal' && !reversed.contains(l['movement_id'])) Map<String, dynamic>.from(l)];
    final out = <({int idx, List<Json> existing})>[];
    for (var i = 0; i < filled.length; i++) {
      final l = filled[i];
      final item = refs.items[l.key]!;
      final signed = (type == 'adjustment' && l.direction == 'remove' ? -1 : type == 'issue' || type == 'transfer' ? -1 : 1) * (_stockQty(l) ?? 0);
      final ex = existing.where((e) => (item.isProduct ? e['product_id'] : e['material_id']) == item.id && (e['color_id'] ?? '') == l.colorId &&
          (type == 'opening_balance' || (n(e['quantity']) - signed).abs() < 1e-9)).toList()
        ..sort((a, b) => '${a['created_at']}'.compareTo('${b['created_at']}'));
      if (ex.isNotEmpty) out.add((idx: i, existing: ex));
    }
    return out;
  }

  Json _payload(List<_Line> filled) => {
        'type': type, 'warehouse_id': warehouseId, 'movement_date': date,
        'reference': reference.text.trim().isEmpty ? null : reference.text.trim(),
        'reason': reason.text.trim().isEmpty ? null : reason.text.trim(),
        'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
        if (type == 'transfer') 'to_warehouse_id': toWarehouseId,
        if (type == 'receipt' && supplier?.id != null) 'supplier_id': supplier!.id,
        if (type == 'receipt' && supplier?.newName != null) 'new_supplier_name': supplier!.newName,
        'lines': [
          for (final l in filled)
            {
              (refs.items[l.key]!.isProduct ? 'product_id' : 'material_id'): refs.items[l.key]!.id,
              if (l.colorId.isNotEmpty) 'color_id': l.colorId,
              'quantity': type == 'adjustment' && l.direction == 'remove' ? -double.parse(l.quantity) : double.parse(l.quantity),
              'unit_id': l.unitId,
              if (type == 'opening_balance' && l.unitCost.isNotEmpty) 'unit_cost': double.tryParse(l.unitCost),
            },
        ],
      };

  Future<void> _send(List<_Line> filled, List<Json> steps) async {
    setState(() { busy = true; error = ''; });
    var sentAny = false;
    try {
      if (filled.isNotEmpty && needsApproval) {
        final what = filled.map((l) {
          final it = refs.items[l.key]!;
          final sq = _stockQty(l);
          return '${type == 'adjustment' ? (l.direction == 'remove' ? 'remove ' : 'add ') : ''}${qtyText(sq ?? double.tryParse(l.quantity))} ${refs.unit(it.stockUnitId)} ${it.name}${l.colorId.isNotEmpty ? ' (${refs.colour(l.colorId)})' : ''}';
        }).join(', ');
        final summary = '${def.noun} at ${warehouseLabel(wh)}${date.compareTo(today) < 0 ? ', dated ${dateText(date)}' : ''}: $what${reason.text.trim().isNotEmpty ? ' — ${reason.text.trim()}' : ''}';
        await db.rpc('request_change', params: {'p_kind': 'stock_movement', 'p_branch_id': null, 'p_payload': _payload(filled), 'p_summary': summary});
        sentAny = true;
      } else if (filled.isNotEmpty) {
        await db.rpc('post_inventory_movement', params: {'p': _payload(filled)});
      }
      final viaApproval = !session.canManage('inventory.adjust');
      for (final s in steps) {
        if (viaApproval) {
          await db.rpc('request_change', params: s['kind'] == 'reverse'
              ? {'p_kind': 'stock_reversal', 'p_branch_id': null, 'p_payload': {'movement_id': s['movementId'], 'reason': s['reason']}, 'p_summary': s['summary']}
              : {'p_kind': 'stock_movement', 'p_branch_id': null, 'p_payload': s['payload'], 'p_summary': s['summary']});
          sentAny = true;
        } else if (s['kind'] == 'reverse') {
          await db.rpc('reverse_inventory_movement', params: {'p_movement_id': s['movementId'], 'p_reason': s['reason']});
        } else {
          await db.rpc('post_inventory_movement', params: {'p': s['payload']});
        }
      }
    } catch (e) {
      setState(() { busy = false; error = dbError(e, "We couldn't record this movement. Please try again."); });
      return;
    }
    if (!mounted) return;
    setState(() => busy = false);
    if (sentAny) {
      setState(() => submitted = true);
    } else {
      toast(context, '${def.noun} posted');
      Navigator.pop(context, true);
    }
  }

  /// After choosing what to do about each possible double entry (planOpeningFix for 'correct')
  Future<void> _continueWithChoices() async {
    final found = repeats!, filled = repeatFilled!;
    if (found.any((f) => choices[f.idx] == null)) { setState(() => error = 'Choose what to do for each item.'); return; }
    final leaveOut = <int>{};
    final steps = <Json>[];
    for (final f in found) {
      final c = choices[f.idx];
      final l = filled[f.idx];
      final item = refs.items[l.key]!;
      final sym = refs.unit(item.stockUnitId);
      final qty = _stockQty(l) ?? 0;
      final first = f.existing.first;
      Json line(double q) => {(item.isProduct ? 'product_id' : 'material_id'): item.id, if (l.colorId.isNotEmpty) 'color_id': l.colorId, 'quantity': q, 'unit_id': item.stockUnitId};
      if (c == 'skip' || c == 'keep_existing') leaveOut.add(f.idx);
      if (c == 'correct') {
        leaveOut.add(f.idx);
        final why = 'Opening balance entered again (${qtyText(qty)} $sym) — corrected to that figure';
        final counts = <String, int>{};
        final ids = {for (final e in f.existing) e['movement_id']}.toList();
        final cnt = await db.from('inventory_transactions').select('movement_id').inFilter('movement_id', ids);
        for (final r in cnt) { counts[r['movement_id']] = (counts[r['movement_id']] ?? 0) + 1; }
        final kept = f.existing.where((e) => e['warehouse_id'] == first['warehouse_id']).firstOrNull;
        for (final e in f.existing) {
          if (identical(e, kept)) continue;
          if ((counts[e['movement_id']] ?? 1) == 1) {
            steps.add({'kind': 'reverse', 'movementId': e['movement_id'], 'reason': why,
                'summary': 'Reverse the opening balance of ${dateText(e['transaction_date'])} at ${warehouseLabel(refs.store(e['warehouse_id']))} (${qtyText(n(e['quantity']))} $sym ${item.name}) — $why'});
          } else {
            steps.add({'kind': 'movement', 'payload': {'type': 'adjustment', 'warehouse_id': e['warehouse_id'], 'movement_date': e['transaction_date'], 'reason': why, 'lines': [line(-n(e['quantity']))]},
                'summary': 'Adjustment at ${warehouseLabel(refs.store(e['warehouse_id']))}, dated ${dateText(e['transaction_date'])}: remove ${qtyText(n(e['quantity']))} $sym ${item.name} — $why'});
          }
        }
        if (kept != null) {
          final diff = qty - n(kept['quantity']);
          if (diff.abs() > 1e-9) {
            steps.add({'kind': 'movement', 'payload': {'type': 'adjustment', 'warehouse_id': kept['warehouse_id'], 'movement_date': kept['transaction_date'], 'reason': why, 'lines': [line(diff)]},
                'summary': 'Adjustment at ${warehouseLabel(refs.store(kept['warehouse_id']))}, dated ${dateText(kept['transaction_date'])}: ${diff > 0 ? 'add' : 'remove'} ${qtyText(diff.abs())} $sym ${item.name} — $why'});
          }
        }
      }
      if (c == 'merge') {
        leaveOut.add(f.idx);
        final why = 'Opening balance entered again — ${qtyText(qty)} $sym merged into the existing entry';
        steps.add({'kind': 'movement', 'payload': {'type': 'adjustment', 'warehouse_id': first['warehouse_id'], 'movement_date': first['transaction_date'], 'reason': why, 'lines': [line(qty)]},
            'summary': 'Adjustment at ${warehouseLabel(refs.store(first['warehouse_id']))}, dated ${dateText(first['transaction_date'])}: add ${qtyText(qty)} $sym ${item.name} — $why'});
      }
    }
    await _send([for (var i = 0; i < filled.length; i++) if (!leaveOut.contains(i)) filled[i]], steps);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    if (submitted) {
      return Scaffold(
        appBar: AppBar(title: Text(def.noun)),
        body: const Padding(padding: EdgeInsets.all(18), child: Text('Sent for approval — see Approvals.')),
        bottomNavigationBar: SafeArea(child: Padding(padding: const EdgeInsets.all(14), child: FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Done')))),
      );
    }
    return Scaffold(
      appBar: AppBar(title: Text(repeats != null ? 'Possible double entry' : def.noun)),
      body: repeats != null ? _repeatChoices(context) : _form(context, t),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 10),
          child: Row(children: [
            Expanded(child: OutlinedButton(onPressed: () => repeats != null ? setState(() { repeats = null; error = ''; }) : Navigator.pop(context), child: Text(repeats != null ? 'Back' : 'Cancel'))),
            const SizedBox(width: 10),
            Expanded(
              flex: 2,
              child: FilledButton(
                onPressed: busy || allowed.isEmpty || (repeats != null && repeats!.any((f) => choices[f.idx] == null)) ? null : (repeats != null ? _continueWithChoices : _post),
                child: Text(busy ? 'Saving…' : repeats != null ? 'Continue' : needsApproval ? 'Submit for approval' : 'Post ${def.noun.toLowerCase()}'),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _form(BuildContext context, Tokens t) {
    final itemList = refs.items.values.where((i) => i.status == 'active').toList();
    final whBranch = wh?.branchId;
    bool inThisStore(String key) => widget.balances.entries.any((e) => e.value != 0 && (e.key == '$warehouseId|$key' || e.key.startsWith('$warehouseId|$key|')));
    final materials = itemList.where((i) => !i.isProduct && (i.branchId == null || i.branchId == whBranch)).toList()..sort(byMaterialOrder);
    final cats = CategoryTools(refs.categoryRows);
    final products = itemList.where((i) => i.isProduct && ((refs.carriedByBranch[whBranch]?.contains(i.id) ?? false) || inThisStore(i.key))).toList()..sort(productOrder(cats));
    final dateHint = canBackdate ? (date.compareTo(today) < 0 ? 'Earlier date: stock is checked as of then and at every later date.' : 'Today, or an earlier date if this happened before.') : 'Today only — earlier dates need stock-adjustment permission.';
    Widget dateField() => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          InkWell(
            onTap: !canBackdate ? null : () async {
              final d = await showDatePicker(context: context, initialDate: DateTime.parse(date), firstDate: DateTime(2024), lastDate: DateTime.parse(today));
              if (d != null) { setState(() => date = iso(d)); _loadAsOf(); }
            },
            child: InputDecorator(decoration: InputDecoration(labelText: 'Date', enabled: canBackdate), child: Text(tableDate(date)!)),
          ),
          Padding(padding: const EdgeInsets.only(top: 4), child: PlHelp(dateHint)),
        ]);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), children: [
      if (widget.prefill != null) Alert(widget.prefill!.note, tone: Tone.info),
      Text("${def.help} Posted movements can't be edited — a mistake is undone with a reversal.", style: TextStyle(fontSize: Fs.sm, color: t.textMuted)),
      const SizedBox(height: 10),
      if (error.isNotEmpty) Alert(error, tone: Tone.error),
      if (needsApproval && allowed.isNotEmpty)
        Alert("${date.compareTo(today) < 0 ? 'Backdated entries' : type == 'count' ? 'Count differences' : 'Corrections'} need an admin's approval: this is sent to the Approvals queue and changes stock once approved."),
      if (allowed.isEmpty) const Text("You don't have permission for this at any store.")
      else ...[
        DropdownButtonFormField<String>(
          initialValue: warehouseId, isExpanded: true,
          decoration: InputDecoration(labelText: type == 'transfer' ? 'From' : 'Store'),
          items: [for (final w in allowed) DropdownMenuItem(value: w.id, child: Text(warehouseLabel(w), overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() {
            warehouseId = v ?? warehouseId;
            for (final l in lines) { if (l.key.isEmpty) l.kind = _kindForStore(wh); }
            if (!canBackdate) date = today;
          }),
        ),
        const SizedBox(height: 12),
        if (type == 'transfer') ...[
          DropdownButtonFormField<String>(
            initialValue: toWarehouseId.isEmpty ? null : toWarehouseId, isExpanded: true,
            decoration: const InputDecoration(labelText: 'To'), hint: const Text('Choose…'),
            items: [for (final w in refs.warehouses.where((w) => w.status == 'active' && w.id != warehouseId && _storeFits(w))) DropdownMenuItem(value: w.id, child: Text(warehouseLabel(w), overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => toWarehouseId = v ?? ''),
          ),
          const SizedBox(height: 12),
        ],
        dateField(),
        const SizedBox(height: 12),
        if (type == 'receipt')
          _SupplierField(suppliers: refs.suppliers, value: supplier, onChange: (v) => setState(() => supplier = v))
        else if (type != 'transfer')
          TextField(controller: reason, decoration: InputDecoration(labelText: 'Reason${type == 'adjustment' ? '' : ' (optional)'}',
              hintText: type == 'adjustment' ? 'e.g. damaged in storage' : type == 'issue' ? 'e.g. production' : null)),
        const SizedBox(height: 12),
        TextField(controller: reference, decoration: const InputDecoration(labelText: 'Reference (optional)', hintText: 'e.g. delivery note no.')),
        const SizedBox(height: 16),
        const Text('Items', style: TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.md)),
        const SizedBox(height: 8),
        for (final g in _twice)
          Alert('${refs.items[lines[g.first].key]!.name}${lines[g.first].colorId.isNotEmpty ? ' (${refs.colour(lines[g.first].colorId)})' : ''} is entered ${g.length == 2 ? 'twice' : '${g.length} times'}.',
              tone: Tone.warning, action: TextButton(onPressed: () => _mergeLines(g), child: const Text('Merge'))),
        for (var i = 0; i < lines.length; i++) _lineEditor(context, i, materials, products),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(onPressed: () => setState(() => lines.add(_Line(lines.lastOrNull?.kind ?? _kindForStore(wh)))), icon: const Icon(LucideIcons.plus, size: 13), label: const Text('Add item')),
        ),
        if (type == 'opening_balance') const PlHelp('Cost is optional, per unit as entered (e.g. per bag).'),
        if (type == 'receipt') const PlHelp('Cost and payment go on the purchase (Purchases).'),
        const SizedBox(height: 12),
        TextField(controller: notes, decoration: const InputDecoration(labelText: 'Notes (optional)')),
      ],
    ]);
  }

  Widget _lineEditor(BuildContext context, int i, List<Item> materials, List<Item> products) {
    final t = context.tk;
    final l = lines[i];
    final item = refs.items[l.key];
    final needsColour = item?.colorIds.isNotEmpty ?? false;
    final bal = l.key.isNotEmpty && (!needsColour || l.colorId.isNotEmpty) ? _balanceOf(l) : null;
    final sq = _stockQty(l);
    final sym = refs.unit(item?.stockUnitId);
    final when = date.compareTo(today) < 0 ? ' on ${dateText(date)}' : '';
    var preview = '';
    if (item != null && bal != null) {
      if (type == 'count') {
        preview = sq != null ? 'records$when ${qtyText(bal)} $sym → difference ${sq - bal >= 0 ? '+' : ''}${qtyText(sq - bal)}' : 'records ${qtyText(bal)} $sym';
      } else if (type == 'issue' || type == 'transfer' || (type == 'adjustment' && l.direction == 'remove')) {
        preview = '${qtyText(bal)} $sym in stock$when${sq != null && sq > bal ? ' — not enough' : ''}';
      } else {
        preview = '${qtyText(bal)} $sym in stock$when${sq != null && l.unitId != item.stockUnitId ? ' · adds ${qtyText(sq)} $sym' : ''}';
      }
    }
    final list = l.kind == 'product' ? products : materials;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(border: Border.all(color: t.border), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(
            width: 120,
            child: DropdownButtonFormField<String>(
              initialValue: l.kind, decoration: const InputDecoration(labelText: 'Type'),
              items: const [DropdownMenuItem(value: 'material', child: Text('Material')), DropdownMenuItem(value: 'product', child: Text('Product'))],
              onChanged: (v) => setState(() { if (v != l.kind) { l.kind = v!; l.key = ''; l.unitId = ''; l.colorId = ''; } }),
            ),
          ),
          const Spacer(),
          IconButton(tooltip: 'Remove line', icon: const Icon(LucideIcons.trash2, size: 16),
              onPressed: () => setState(() { if (lines.length > 1) { lines.removeAt(i); } else { lines = [_Line(l.kind)]; } })),
        ]),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          initialValue: l.key.isEmpty ? null : l.key, isExpanded: true,
          decoration: InputDecoration(labelText: l.kind == 'product' ? 'Product' : 'Material'),
          items: [
            for (final it in list)
              DropdownMenuItem(value: it.key, enabled: it.isProduct || it.stockUnitId != null,
                  child: Text(it.isProduct ? '${it.name} · ${it.category ?? ''}' : '${it.name}${it.stockUnitId == null ? ' (set stock unit first)' : ''}', overflow: TextOverflow.ellipsis)),
          ],
          onChanged: (v) => setState(() { l.key = v ?? ''; l.unitId = refs.items[l.key]?.mainUnitId ?? refs.items[l.key]?.stockUnitId ?? ''; l.colorId = ''; }),
        ),
        if (needsColour) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: l.colorId.isEmpty ? null : l.colorId, decoration: const InputDecoration(labelText: 'Colour'), hint: const Text('Colour…'),
            items: [for (final c in item!.colorIds) DropdownMenuItem(value: c, child: Text('${refs.colour(c)}${refs.colorById[c]?['is_active'] == false ? ' (discontinued)' : ''}'))],
            onChanged: (v) => setState(() => l.colorId = v ?? ''),
          ),
        ],
        const SizedBox(height: 8),
        Row(children: [
          if (type == 'adjustment') ...[
            SizedBox(
              width: 110,
              child: DropdownButtonFormField<String>(
                initialValue: l.direction, decoration: const InputDecoration(labelText: 'Direction'),
                items: const [DropdownMenuItem(value: 'remove', child: Text('Remove')), DropdownMenuItem(value: 'add', child: Text('Add'))],
                onChanged: (v) => setState(() => l.direction = v ?? 'remove'),
              ),
            ),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: TextFormField(
              initialValue: l.quantity, keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: type == 'count' ? 'Found' : 'Qty'),
              onChanged: (v) => setState(() => l.quantity = v),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 100,
            child: DropdownButtonFormField<String>(
              initialValue: l.unitId.isEmpty ? null : l.unitId, decoration: const InputDecoration(labelText: 'Unit'),
              items: [for (final u in item?.units ?? <UnitF>[]) DropdownMenuItem(value: u.id, child: Text(refs.unit(u.id)))],
              onChanged: item == null ? null : (v) => setState(() => l.unitId = v ?? ''),
            ),
          ),
        ]),
        if (type == 'opening_balance') ...[
          const SizedBox(height: 8),
          TextFormField(initialValue: l.unitCost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Cost / unit'), onChanged: (v) => l.unitCost = v),
        ],
        if (preview.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(preview, style: TextStyle(fontSize: Fs.xs, color: preview.contains('not enough') ? C.error : t.textMuted))),
        if (item != null && wh != null && (type == 'opening_balance' || type == 'receipt') && !_fitsStore(item, wh!))
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(item.isProduct ? '${item.name} is a product — ${wh!.name} is not the finished-goods store.' : '${item.name} is a material — ${wh!.name} is a finished-goods store.',
              style: const TextStyle(fontSize: Fs.xs, color: C.warning))),
      ]),
    );
  }

  /// web DoubleEntry.jsx fitsStore: materials outside finished goods, products in it
  bool _fitsStore(Item item, Store w) => item.isProduct ? w.type == 'finished_goods' : w.type != 'finished_goods';

  Widget _repeatChoices(BuildContext context) {
    final found = repeats!, filled = repeatFilled!;
    String store(Object? id) => refs.store('$id')?.name ?? 'a store';
    return ListView(padding: const EdgeInsets.fromLTRB(16, 14, 16, 24), children: [
      Alert('${found.length == 1 ? 'This entry may repeat one already recorded.' : '${found.length} items may repeat entries already recorded.'} Choose what is right before anything is posted.', tone: Tone.warning),
      if (error.isNotEmpty) Alert(error, tone: Tone.error),
      for (final f in found)
        Builder(builder: (context) {
          final l = filled[f.idx];
          final item = refs.items[l.key]!;
          final sym = refs.unit(item.stockUnitId);
          final qty = _stockQty(l) ?? 0;
          final first = f.existing.first;
          final opts = type == 'opening_balance'
              ? [
                  ('keep_existing', 'Keep what is already recorded — leave ${item.name} out of this entry'),
                  ('merge', 'Merge: add ${qtyText(qty)} $sym to the ${store(first['warehouse_id'])} entry (total ${qtyText(n(first['quantity']) + qty)} $sym)'),
                  ('correct', 'Correct it: the opening stock is ${qtyText(qty)} $sym, in ${store(first['warehouse_id'])}${f.existing.length > 1 ? ' (the other entries are undone)' : ''}'),
                  if (!f.existing.any((e) => e['warehouse_id'] == wh!.id)) ('post', 'Both are right — ${qtyText(qty)} $sym is separate stock in ${wh!.name}'),
                ]
              : [('skip', "It's the same one — leave ${item.name} out"), ('post', "It's a different ${def.noun.toLowerCase()} — post it too")];
          return CardBox(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text('${item.name}${l.colorId.isNotEmpty ? ' (${refs.colour(l.colorId)})' : ''}${type == 'opening_balance' ? ' already has ${f.existing.length == 1 ? 'an opening balance' : '${f.existing.length} opening balances'} at ${wh?.branchName ?? 'this branch'}:' : ' — the same ${def.noun.toLowerCase()} is already recorded:'}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              for (final e in f.existing)
                Text('• ${qtyText(n(e['quantity']).abs())} $sym in ${store(e['warehouse_id'])}, dated ${dateText(e['transaction_date'])} · entered ${dateText(e['created_at'])}', style: const TextStyle(fontSize: Fs.sm)),
              const SizedBox(height: 4),
              Text('This entry: ${qtyText(qty)} $sym in ${wh?.name ?? ''}', style: const TextStyle(fontSize: Fs.sm)),
              const SizedBox(height: 6),
              RadioGroup<String>(
                groupValue: choices[f.idx],
                onChanged: (v) => setState(() => choices[f.idx] = v!),
                child: Column(children: [for (final (v, label) in opts) RadioListTile<String>(value: v, dense: true, contentPadding: EdgeInsets.zero, title: Text(label, style: const TextStyle(fontSize: Fs.sm)))]),
              ),
            ]),
          );
        }),
      const PlHelp('Nothing is deleted.'),
    ]);
  }
}

// ---- supplier for a receipt (MovementModal SupplierField + lib/inventory matchSuppliers) ----
String _normalize(String s) => s.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), '');
String _core(String s) => _normalize(s.toLowerCase().replaceAll('&', ' and ').replaceAll(RegExp(r'[.,]'), ' ')
    .replaceAll(RegExp(r'\b(ltd|limited|co|company|plc|inc|corp|enterprises?|group|the|and)\b'), ' '));

double _similarity(String a, String b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final prev = List<int>.generate(b.length + 1, (j) => j);
  for (var i = 1; i <= a.length; i++) {
    var diag = prev[0];
    prev[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final tmp = prev[j];
      prev[j] = [prev[j] + 1, prev[j - 1] + 1, diag + (a[i - 1] == b[j - 1] ? 0 : 1)].reduce((x, y) => x < y ? x : y);
      diag = tmp;
    }
  }
  return 1 - prev[b.length] / (a.length > b.length ? a.length : b.length);
}

({Json? exact, List<Json> similar}) matchSuppliers(String typed, List<Json> suppliers) {
  final nm = _normalize(typed);
  if (nm.isEmpty) return (exact: null, similar: []);
  final exact = suppliers.where((s) => _normalize('${s['name']}') == nm).firstOrNull;
  final c = _core(typed);
  final scored = [
    for (final s in suppliers.where((s) => s != exact))
      (s: s, score: [_similarity(c, _core('${s['name']}')), c.length >= 3 && _core('${s['name']}').length >= 3 && (_core('${s['name']}').contains(c) || c.contains(_core('${s['name']}'))) ? 0.85 : 0.0].reduce((x, y) => x > y ? x : y)),
  ].where((x) => x.score >= 0.75).toList()
    ..sort((a, b) => b.score.compareTo(a.score));
  return (exact: exact, similar: [for (final x in scored.take(4)) x.s]);
}

class _SupplierField extends StatefulWidget {
  const _SupplierField({required this.suppliers, required this.value, required this.onChange});
  final List<Json> suppliers;
  final ({String? id, String? newName, bool pending})? value;
  final ValueChanged<({String? id, String? newName, bool pending})?> onChange;
  @override
  State<_SupplierField> createState() => _SupplierFieldState();
}

class _SupplierFieldState extends State<_SupplierField> {
  final _text = TextEditingController();
  List<Json> get active => widget.suppliers.where((s) => s['status'] == 'active').toList();

  void _type(String t) {
    setState(() {});
    final m = matchSuppliers(t, active);
    if (t.trim().isEmpty) {
      widget.onChange(null);
    } else if (m.exact != null) {
      widget.onChange((id: m.exact!['id'] as String, newName: null, pending: false));
    } else {
      widget.onChange((id: null, newName: t.trim(), pending: m.similar.isNotEmpty));
    }
  }

  @override
  void dispose() { _text.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final chosen = widget.value?.id != null ? widget.suppliers.where((s) => s['id'] == widget.value!.id).firstOrNull : null;
    if (chosen != null) {
      return Row(children: [
        const Text('Supplier  ', style: TextStyle(fontSize: Fs.sm)),
        Badge2('${chosen['name']}', tone: Tone.info),
        TextButton(onPressed: () { _text.clear(); widget.onChange(null); setState(() {}); }, child: const Text('Change')),
      ]);
    }
    final m = matchSuppliers(_text.text, active);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Autocomplete<String>(
        optionsBuilder: (v) => v.text.trim().isEmpty ? const [] : active.map((s) => '${s['name']}').where((n) => n.toLowerCase().contains(v.text.toLowerCase())).take(8),
        onSelected: (v) { _text.text = v; _type(v); },
        fieldViewBuilder: (ctx, c, focus, submit) => TextField(
          controller: c, focusNode: focus,
          decoration: const InputDecoration(labelText: 'Supplier (optional)', hintText: 'Type to find or add'),
          onChanged: (v) { _text.text = v; _type(v); },
        ),
      ),
      if (_text.text.trim().isNotEmpty && m.exact == null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: m.similar.isNotEmpty
              ? Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
                  const PlHelp('Did you mean '),
                  for (final s in m.similar) TextButton(onPressed: () { _text.text = '${s['name']}'; widget.onChange((id: s['id'] as String, newName: null, pending: false)); setState(() {}); }, child: Text('${s['name']}')),
                  if (widget.value?.pending ?? false)
                    OutlinedButton(onPressed: () => widget.onChange((id: null, newName: _text.text.trim(), pending: false)), child: Text('No — add “${_text.text.trim()}” as new'))
                  else
                    PlHelp(' · “${_text.text.trim()}” will be added as a new supplier'),
                ])
              : const PlHelp('New supplier — added when this receipt is posted.'),
        ),
    ]);
  }
}
