import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/files.dart';
import '../core/format.dart';
import '../core/pdf_doc.dart';
import '../core/proof_box.dart';
import '../core/sales.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../docs/sale_doc.dart';
import 'procurement_actions.dart' show DateField;

/*
 * Deliveries — a port of web components/sales/DeliveriesPanel.jsx (PRD 4.14, 096): every delivery note at the
 * branch by the day the goods left, newest first. Collected — the goods have left the store (a delivery not yet
 * confirmed arrived, or a customer's own collection); Delivered — a delivery confirmed arrived, with who received
 * it, when, a note and a photo (117). Online only.
 */
class DeliveriesPanel extends StatefulWidget {
  const DeliveriesPanel({super.key, required this.canAct, this.onChanged});
  final bool canAct;
  final VoidCallback? onChanged;
  @override
  State<DeliveriesPanel> createState() => _DeliveriesPanelState();
}

class _DeliveriesPanelState extends State<DeliveriesPanel> {
  List<Json>? _rows;
  String _error = '', _filter = 'collected', _search = '';

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final d = jl(await db.from('sale_deliveries')
          .select('*, sale:sales!inner(id, sale_no, branch_id, customer_id, walk_in_name, site, customer:customers(name)), lines:sale_delivery_lines(quantity, line:sale_lines(line_no, item_name, product:products(canonical_name, unit:units(symbol)), color:color_palette(name)))')
          .order('created_at', ascending: false).limit(500));
      if (mounted) setState(() => _rows = d);
    } catch (_) {
      if (mounted) setState(() { _error = "We couldn't load deliveries."; _rows = []; });
    }
  }

  String who(Json r) => '${r['sale']['customer']?['name'] ?? r['sale']['walk_in_name'] ?? 'Walk-in'}';
  List<({String name, double qty, String unit})> items(Json r) => [
        for (final x in jl(r['lines'])..sort((a, b) => n(a['line']?['line_no']).compareTo(n(b['line']?['line_no']))))
          (
            name: x['line']?['product'] != null ? '${x['line']['product']['canonical_name']}${x['line']['color']?['name'] != null ? ' ${x['line']['color']['name']}' : ''}' : '${x['line']?['item_name'] ?? ''}',
            qty: n(x['quantity']).toDouble(),
            unit: '${x['line']?['product']?['unit']?['symbol'] ?? ''}'.toUpperCase() == 'SQM' ? 'm²' : 'pcs',
          ),
      ];
  String stateOf(Json r) => r['kind'] == 'delivery' && (r['status'] ?? 'delivered') == 'delivered' ? 'delivered' : 'collected';

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final rows = _rows;
    final today = session.today;
    final here = (rows ?? []).where((r) => session.inBranch(r['sale']['branch_id'])).toList();
    final q = _search.trim().toLowerCase();
    final shown = here.where((r) => (_filter == 'all' || stateOf(r) == _filter) &&
        (q.isEmpty || '${who(r)} ${r['sale']['site'] ?? ''} ${r['driver'] ?? ''} ${r['vehicle'] ?? ''} ${r['sale']['sale_no']} DN-${r['delivery_no']}'.toLowerCase().contains(q))).toList()
      ..sort((x, y) { final c = '${y['delivered_on'] ?? ''}'.compareTo('${x['delivered_on'] ?? ''}'); return c != 0 ? c : '${y['created_at'] ?? ''}'.compareTo('${x['created_at'] ?? ''}'); });
    final toConfirm = here.where((r) => r['status'] == 'on_the_way').length;
    final leftToday = here.where((r) => r['delivered_on'] == today).length;
    int count(String k) => here.where((r) => stateOf(r) == k).length;
    String? lastDay;

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        if (rows != null)
          Stats([
            Stat('To confirm delivered', '$toConfirm', figureColor: toConfirm > 0 ? C.warning : null, help: toConfirm > 0 ? 'collected, not yet confirmed' : 'none waiting'),
            Stat('Left the store today', '$leftToday', help: 'delivery note${leftToday == 1 ? '' : 's'}'),
            Stat('This month', '${here.where((r) => '${r['delivered_on'] ?? ''}'.startsWith(today.substring(0, 7))).length}', help: 'delivery notes'),
          ]),
        ListToolbar(placeholder: 'Search customer, site, driver, truck or DN…', onSearch: (v) => setState(() => _search = v)),
        SlideRow(children: [
          for (final (k, l) in [('collected', 'Collected (${count('collected')})'), ('delivered', 'Delivered (${count('delivered')})'), ('all', 'All')])
            Chip2(l, on: _filter == k, onTap: () => setState(() => _filter = k)),
        ]),
        const SizedBox(height: 8),
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        if (rows == null)
          const Skeleton(rows: 4)
        else if (shown.isEmpty)
          EmptyState(icon: LucideIcons.truck, title: 'Nothing here', description: _filter == 'collected' ? 'No goods collected.' : _filter == 'delivered' ? 'No deliveries confirmed.' : 'No delivery notes.')
        else
          for (final r in shown) ...[
            if (r['delivered_on'] != lastDay) ...[
              () { lastDay = r['delivered_on'] as String?; return SectionTitle('${tableDate(r['delivered_on'])} · ${shown.where((x) => x['delivered_on'] == r['delivered_on']).length} notes'); }(),
            ],
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: t.surface, borderRadius: BorderRadius.circular(10), border: Border.all(color: t.border)),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text('DN-${r['delivery_no']} · ${who(r)}', style: const TextStyle(fontWeight: FontWeight.w700))),
                  stateOf(r) == 'delivered'
                      ? const Badge2('Delivered', tone: Tone.success)
                      : Badge2('Collected', tone: r['status'] == 'on_the_way' ? Tone.warning : Tone.neutral),
                ]),
                PlHelp('sale #${r['sale']['sale_no']}${r['sale']['site'] != null && '${r['sale']['site']}'.isNotEmpty ? ' · ${r['sale']['site']}' : ''}'
                    ' · ${r['kind'] == 'collection' ? (r['vehicle'] ?? "the customer's own") : [r['driver'], r['vehicle']].where((x) => x != null && '$x'.isNotEmpty).join(' · ').ifEmpty('—')}'),
                const SizedBox(height: 4),
                for (final x in items(r))
                  Row(children: [Expanded(child: Text(x.name, style: const TextStyle(fontSize: Fs.sm))), Text('${qtyText(x.qty)} ', style: const TextStyle(fontSize: Fs.sm)), PlHelp(x.unit)]),
                if (stateOf(r) == 'delivered' && (r['pod_received_by'] ?? r['received_by']) != null)
                  PlHelp('Received by ${r['pod_received_by'] ?? r['received_by']}${r['delivered_at'] != null ? ' · ${tableDateTime(r['delivered_at'])}' : ''}${r['pod_note'] != null ? ' · ${r['pod_note']}' : ''}'),
                Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                  if (r['pod_file_path'] != null)
                    IconButton(tooltip: 'Delivery photo', icon: const Icon(LucideIcons.camera, size: 17), onPressed: () => _photo(r)),
                  IconButton(tooltip: 'Delivery note', icon: const Icon(LucideIcons.printer, size: 17),
                      onPressed: () => openDoc(context, 'Delivery note DN-${r['delivery_no']}', () => saleDocPdf('${r['sale']['id']}', 'delivery', deliveryId: '${r['id']}'))),
                  if (widget.canAct && r['status'] == 'on_the_way')
                    FilledButton(onPressed: () async { if (await confirmDelivery(context, delivery: r, who: who(r), branchId: '${r['sale']['branch_id']}')) { _load(); widget.onChanged?.call(); } }, child: const Text('Delivered…')),
                ]),
              ]),
            ),
          ],
      ]),
    );
  }

  Future<void> _photo(Json r) async {
    final url = await signedUrl('delivery-proofs', r['pod_file_path'] as String?);
    if (url == null || !mounted) return;
    await showModal<void>(context, title: 'Delivered — DN-${r['delivery_no']}', body: (_) => InteractiveViewer(child: Image.network(url, fit: BoxFit.contain)));
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// Proof of delivery: who received the goods, when, a note, a photo (096 / 117)
Future<bool> confirmDelivery(BuildContext context, {required Json delivery, required String who, required String branchId}) async =>
    await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ConfirmDelivery(delivery: delivery, who: who, branchId: branchId))) == true;

class _ConfirmDelivery extends StatefulWidget {
  const _ConfirmDelivery({required this.delivery, required this.who, required this.branchId});
  final Json delivery;
  final String who, branchId;
  @override
  State<_ConfirmDelivery> createState() => _ConfirmDeliveryState();
}

class _ConfirmDeliveryState extends State<_ConfirmDelivery> {
  late final _by = TextEditingController(text: '${widget.delivery['received_by'] ?? ''}');
  final _note = TextEditingController();
  late String _day = session.today;
  TimeOfDay _time = TimeOfDay.now();
  ProofFile? _photo;
  bool _busy = false;
  String _error = '';

  @override
  void initState() { super.initState(); _by.addListener(() => setState(() {})); }

  Future<void> _save() async {
    setState(() { _error = ''; _busy = true; });
    try {
      final d = widget.delivery;
      var pod = <String, dynamic>{};
      if (_photo != null) {
        final path = await uploadProof('delivery-proofs', widget.branchId, '${d['id']}', _photo!);
        pod = {'pod_file_path': path, 'pod_file_name': 'DN-${d['delivery_no']}_${widget.who.replaceAll(RegExp(r'[^\w-]+'), '-')}.${_photo!.ext}'};
      }
      final at = DateTime.parse(_day).add(Duration(hours: _time.hour, minutes: _time.minute));
      await db.rpc('confirm_delivery', params: {'p_delivery': d['id'], 'p': {'received_by': _by.text, 'delivered_at': at.toUtc().toIso8601String(), 'note': _note.text, ...pod}});
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => FullPage(
        title: 'Delivered — DN-${widget.delivery['delivery_no']}',
        footer: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy || _by.text.trim().isEmpty ? null : _save, child: Text(_busy ? 'Saving…' : 'Confirm delivered')),
        ],
        children: [
          PlHelp('For ${widget.who}${widget.delivery['driver'] != null ? ' · driver ${widget.delivery['driver']}' : ''}'),
          const SizedBox(height: 10),
          TextField(controller: _by, autofocus: true, decoration: const InputDecoration(labelText: 'Received by (at the site)')),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: DateField(label: 'When', value: _day, last: session.today, onChange: (v) => setState(() => _day = v))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton(
              onPressed: () async { final t = await showTimePicker(context: context, initialTime: _time); if (t != null) setState(() => _time = t); },
              child: Text(_time.format(context)),
            )),
          ]),
          const SizedBox(height: 10),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'Note (optional)', hintText: 'e.g. 3 pieces broken, left at the gate')),
          const SizedBox(height: 10),
          const PlHelp('Photo (optional) — the signed delivery note, or the goods at the site'),
          const SizedBox(height: 6),
          ProofBox(file: _photo, onFile: (f) => setState(() => _photo = f), text: TextEditingController(), onText: () {}, placeholder: 'Add the photo with +'),
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        ],
      );
}
