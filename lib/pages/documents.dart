import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/offline.dart';
import '../core/pdf_doc.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../docs/payslip_doc.dart';
import '../docs/purchase_docs.dart';
import '../docs/sale_doc.dart';

/*
 * Documents (Document Center) — a port of web pages/Documents.jsx (approved 2026-11-24): find any
 * document MOIS prints and open it again as a PDF made on the phone.
 *   Sales       — quotations, proformas (orders), invoices, payment receipts, delivery notes;
 *   Purchasing  — goods received notes, purchase orders;
 *   Payslips    — each pay sheet's payslips.
 * Newest first, at the branch in the menu; search by number, name or reference.
 */
const _show = 300;

class _Doc {
  _Doc({required this.key, required this.branchId, required this.date, required this.at, required this.kind, required this.number, this.who, this.ref, this.amount, required this.open});
  final String key, kind, number;
  final String? branchId, date, at, who, ref;
  final Object? amount;
  final Future<Uint8List> Function() open;
}

List<_Doc> _byNewest(List<_Doc> rows) => rows
  ..sort((a, b) => a.date == b.date ? '${b.at}'.compareTo('${a.at}') : ('${a.date}'.compareTo('${b.date}') < 0 ? 1 : -1));
String _buyer(Map? s) => '${s?['customer']?['name'] ?? s?['walk_in_name'] ?? 'Walk-in'}';

Future<List> _salesRaw() async {
  final r = await Future.wait<dynamic>([
    db.from('sales').select('id, sale_no, stage, branch_id, sale_date, invoiced_on, total, efd_receipt_no, walk_in_name, created_at, customer:customers(name)').neq('stage', 'cancelled'),
    db.from('sale_payments').select('id, paid_on, amount, receipt_no, created_at, sale:sales!inner(id, sale_no, branch_id, walk_in_name, customer:customers(name))').then<List>((v) => v).catchError((_) => <dynamic>[]),
    db.from('sale_deliveries').select('id, delivery_no, delivered_on, kind, created_at, sale:sales!inner(id, sale_no, branch_id, walk_in_name, site, customer:customers(name))').then<List>((v) => v).catchError((_) => <dynamic>[]),
  ]);
  return r;
}

List<_Doc> _sales(List r) {
  const doc = {'quotation': ('Quotation', 'quotation'), 'order': ('Proforma', 'proforma'), 'invoice': ('Invoice', 'invoice')};
  return _byNewest([
    for (final x in r[0] as List)
      if (doc[x['stage']] != null)
        _Doc(key: 's${x['id']}', branchId: x['branch_id'], date: '${x['stage'] == 'invoice' ? (x['invoiced_on'] ?? x['sale_date']) : x['sale_date']}', at: x['created_at'],
            kind: doc[x['stage']]!.$1, number: '#${x['sale_no']}', who: _buyer(x), ref: x['efd_receipt_no'] != null ? 'EFD ${x['efd_receipt_no']}' : '', amount: x['total'],
            open: () => saleDocPdf('${x['id']}', doc[x['stage']]!.$2)),
    for (final x in r[1] as List)
      _Doc(key: 'p${x['id']}', branchId: x['sale']['branch_id'], date: x['paid_on'], at: x['created_at'], kind: 'Receipt',
          number: '${x['receipt_no'] ?? ''}'.isNotEmpty ? '${x['receipt_no']}' : 'on #${x['sale']['sale_no']}', who: _buyer(x['sale']), ref: 'Sale #${x['sale']['sale_no']}', amount: x['amount'],
          open: () => saleDocPdf('${x['sale']['id']}', 'receipt', paymentId: '${x['id']}')),
    for (final x in r[2] as List)
      _Doc(key: 'd${x['id']}', branchId: x['sale']['branch_id'], date: x['delivered_on'], at: x['created_at'], kind: 'Delivery note',
          number: 'DN-${x['delivery_no'] ?? '—'}', who: _buyer(x['sale']), ref: ['Sale #${x['sale']['sale_no']}', if ('${x['sale']['site'] ?? ''}'.isNotEmpty) x['sale']['site']].join(' · '),
          open: () => saleDocPdf('${x['sale']['id']}', 'delivery', deliveryId: '${x['id']}')),
  ]);
}

Future<List> _purchasingRaw() async {
  final r = await Future.wait<dynamic>([
    db.from('purchases').select('id, movement_id, branch_id, supplier_id, purchase_date, invoice_reference, created_at, status').neq('status', 'void').not('movement_id', 'is', null),
    db.from('receipts_awaiting_purchase').select('movement_id, branch_id, supplier_id, movement_date, reference, created_at').then<List>((v) => v).catchError((_) => <dynamic>[]),
    db.from('purchase_orders').select('id, po_no, branch_id, supplier_id, order_date, status, created_at').then<List>((v) => v).catchError((_) => <dynamic>[]),
    db.from('suppliers').select('id, name'),
    db.from('purchase_totals').select('purchase_id, total').then<List>((v) => v).catchError((_) => <dynamic>[]),
  ]);
  return r;
}

List<_Doc> _purchasing(List r) {
  String name(Object? id) => '${(r[3] as List).where((x) => x['id'] == id).firstOrNull?['name'] ?? ''}';
  final totalOf = {for (final t in r[4] as List) '${t['purchase_id']}': t['total']};
  String grn(Object id) => 'GRN-${'$id'.substring(0, 8).toUpperCase()}';
  return _byNewest([
    for (final x in r[0] as List)
      _Doc(key: 'g${x['movement_id']}', branchId: x['branch_id'], date: x['purchase_date'], at: x['created_at'], kind: 'Goods received', number: grn(x['movement_id']),
          who: name(x['supplier_id']), ref: x['invoice_reference'] != null ? 'Invoice ${x['invoice_reference']}' : '', amount: totalOf['${x['id']}'], open: () => grnPdf('${x['movement_id']}')),
    for (final x in r[1] as List)
      _Doc(key: 'g${x['movement_id']}', branchId: x['branch_id'], date: x['movement_date'], at: x['created_at'], kind: 'Goods received', number: grn(x['movement_id']),
          who: name(x['supplier_id']), ref: x['reference'] != null ? '${x['reference']} · details to follow' : 'details to follow', open: () => grnPdf('${x['movement_id']}')),
    for (final x in r[2] as List)
      _Doc(key: 'o${x['id']}', branchId: x['branch_id'], date: x['order_date'], at: x['created_at'], kind: 'Purchase order', number: 'PO #${x['po_no']}',
          who: name(x['supplier_id']), ref: '${x['status'] ?? ''}', open: () => poPdf('${x['id']}')),
  ]);
}

Future<List> _payslipsRaw() async => [await db.from('pay_sheets').select('id, branch_id, cycle, period_start, period_end, status, total, paid_on, created_at').neq('status', 'void')];

List<_Doc> _payslips(List r) => _byNewest([
      for (final x in r[0] as List)
        _Doc(key: '${x['id']}', branchId: x['branch_id'], date: x['period_end'], at: x['created_at'], kind: 'Payslips',
            number: '${dateText(x['period_start'])} – ${dateText(x['period_end'])}', who: '${x['cycle'] ?? ''} pay sheet'.trim(),
            ref: x['status'] == 'paid' ? 'paid ${dateText(x['paid_on']) ?? ''}'.trim() : '${x['status']}', amount: x['total'], open: () => payslipsPdf('${x['id']}')),
    ]);

class DocumentsPage extends StatefulWidget {
  const DocumentsPage({super.key});
  @override
  State<DocumentsPage> createState() => _DocumentsPageState();
}

class _DocumentsPageState extends State<DocumentsPage> {
  late final List<(String, String)> tabs = [
    if (session.can('sales.view')) ('sales', 'Sales'),
    if (session.can('procurement.view')) ('purchasing', 'Purchasing'),
    if (session.can('staff.view')) ('payslips', 'Payslips'),
  ];
  late String _tab = tabs.firstOrNull?.$1 ?? 'sales';
  List<_Doc>? _rows;
  DateTime? _savedAt;
  String _error = '', _search = '', _kind = '';

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    final tab = _tab;
    setState(() { _rows = null; _error = ''; _kind = ''; });
    try {
      final (raw, at) = await offline.load<List>('documents:$tab', () => switch (tab) { 'purchasing' => _purchasingRaw(), 'payslips' => _payslipsRaw(), _ => _salesRaw() });
      final rows = switch (tab) { 'purchasing' => _purchasing(raw), 'payslips' => _payslips(raw), _ => _sales(raw) };
      if (mounted && tab == _tab) setState(() { _rows = rows; _savedAt = at; });
    } catch (_) {
      if (mounted) setState(() { _error = "We couldn't load the documents."; _rows = []; });
    }
  }

  void _open(_Doc r) => openDoc(context, '${r.kind} ${r.number}', r.open);

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    if (tabs.isEmpty) {
      return ListView(padding: const EdgeInsets.all(14), children: const [EmptyState(icon: LucideIcons.fileText, title: 'No documents for you', description: "Your role doesn't open sales, purchasing or payroll.")]);
    }
    final here = (_rows ?? []).where((r) => session.inBranch(r.branchId)).toList();
    final kinds = {for (final r in here) r.kind}.toList();
    final q = _search.trim().toLowerCase();
    final shown = here.where((r) => (_kind.isEmpty || r.kind == _kind) && (q.isEmpty || '${r.number} ${r.who ?? ''} ${r.ref ?? ''}'.toLowerCase().contains(q))).toList();
    final whoWord = _tab == 'payslips' ? 'Pay sheet' : _tab == 'purchasing' ? 'Supplier' : 'Customer';
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        OfflineNote(_savedAt),
        if (tabs.length > 1) PageTabs<String>(tabs: tabs, value: _tab, onChange: (v) { setState(() { _tab = v; _search = ''; }); _load(); }),
        Stats([
          Stat('Documents', _rows == null ? '—' : '${here.length}', help: session.branchId.isNotEmpty ? (session.branchName ?? '') : 'all branches'),
          Stat('Newest', dateText(here.firstOrNull?.date) ?? '—', help: here.isNotEmpty ? '${here.first.kind} ${here.first.number}' : ''),
          Stat('Kinds', '${kinds.length}', help: kinds.join(', ')),
        ]),
        ListToolbar(key: ValueKey(_tab), placeholder: 'Search number, name or reference…', onSearch: (v) => setState(() => _search = v)),
        if (kinds.length > 1) ...[
          ChipRow(items: [for (final k in kinds) ChipItem(k, k)], value: _kind, onChange: (v) => setState(() => _kind = v)),
          const SizedBox(height: 10),
        ],
        if (_error.isNotEmpty)
          ErrorState(_error, onRetry: _load)
        else if (_rows == null)
          const Skeleton(rows: 6)
        else if (shown.isEmpty)
          PlHelp(_search.isNotEmpty || _kind.isNotEmpty ? 'Nothing matches.' : 'No documents yet.')
        else ...[
          for (final r in shown.take(_show))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: t.surface,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => _open(r),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
                    child: Row(children: [
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${tableDate(r.date) ?? '—'} · ${r.kind}', style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                          Text('${r.number}${(r.who ?? '').isNotEmpty ? ' · ${r.who}' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
                          if ((r.ref ?? '').isNotEmpty) PlHelp(r.ref!),
                        ]),
                      ),
                      if (r.amount != null) Text(formatMoney(n(r.amount).roundToDouble(), session.currency), style: const TextStyle(fontWeight: FontWeight.w700)),
                      IconButton(tooltip: 'Print', onPressed: () => _open(r), icon: Icon(LucideIcons.printer, size: 17, color: t.textSecondary)),
                    ]),
                  ),
                ),
              ),
            ),
          if (shown.length > _show) PlHelp('Showing the newest $_show of ${shown.length} — search to find older ones.'),
          PlHelp('$whoWord shown on each document · tap to open, print or share.'),
        ],
      ]),
    );
  }
}
