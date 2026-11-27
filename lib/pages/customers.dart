import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/pdf_doc.dart';
import '../core/sales.dart' show jl, paidOf;
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import '../docs/sale_doc.dart';
import '../docs/statement_doc.dart';
import '../shell.dart';
import 'procurement_actions.dart' show DateField;

/*
 * Customers — a port of web pages/Customers.jsx and components/customers/LeadsPanel.jsx (1e 064, CRM 095;
 * approved for the phone 2026-11-26). Shared by the organization's branches: name, phone, TIN/VRN; who owes what
 * and for how long (walk-in buyers by name); each customer's history and statement of account (a PDF to share).
 * Leads: prospects before they buy, who follows up and when; Make quotation turns one into a customer and opens
 * a quotation for it. Online only.
 */
class CustomersPage extends StatefulWidget {
  const CustomersPage({super.key, this.tab});
  final String? tab;
  @override
  State<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends State<CustomersPage> {
  List<Json>? _rows;
  List<Json> _sales = [];
  String _error = '', _search = '';
  late String _tab = widget.tab ?? 'customers';
  bool get canEdit => session.can('sales.create');
  String get today => session.today;
  String money(num v) => formatMoney(v, session.currency);

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final r = await Future.wait<dynamic>([db.from('customers').select('*').order('name', ascending: true), loadOwing()]);
      if (mounted) setState(() { _rows = jl(r[0]); _sales = r[1] as List<Json>; });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load customers. Please try again.");
    }
  }

  Future<void> _edit([Json? c]) async {
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _CustomerForm(customer: c)));
    if (ok == true) _load();
  }

  Future<void> _view(Json c, Buyer? st) async {
    await Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _CustomerView(
          customer: c, sales: _sales.where((s) => s['customer_id'] == c['id']).toList(), stats: st, canEdit: canEdit,
          onEdit: () async { Navigator.pop(context); await _edit(c); },
        )));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final rows = _rows;
    if (_error.isNotEmpty && rows == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    // owed across the organization's branches for a customer; the "Who owes" list follows the branch picked
    final all = rows == null ? <Buyer>[] : ageByBuyer(_sales, rows, today);
    Buyer? statsOf(Object? id) => all.where((b) => b.key == id).firstOrNull;
    final q = _search.trim().toLowerCase();
    final owing = rows == null
        ? <Buyer>[]
        : (ageByBuyer(_sales.where((s) => session.inBranch(s['branch_id'])).toList(), rows, today)
            .where((b) => b.owed > 0 && (q.isEmpty || '${b.name} ${b.phone ?? ''}'.toLowerCase().contains(q))).toList()
          ..sort((a, b) => b.owed.compareTo(a.owed)));
    final shown = (rows ?? []).where((c) => q.isEmpty || '${c['name']} ${c['phone'] ?? ''} ${c['tin'] ?? ''}'.toLowerCase().contains(q)).toList();

    final tabs = PageTabs<String>(
      tabs: [('customers', 'Customers'), ('leads', 'Leads'), ('owing', 'Statements & aging${owing.isNotEmpty ? ' (${owing.length})' : ''}')],
      value: _tab, onChange: (v) => setState(() => _tab = v),
    );
    if (_tab == 'leads') {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: tabs),
        const Expanded(child: _Leads()),
      ]);
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: canEdit && _tab == 'customers' ? FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(LucideIcons.plus), label: const Text('New customer')) : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 88), children: [
          tabs,
          ListToolbar(key: ValueKey('s$_tab'), placeholder: 'Search name, phone or TIN…', onSearch: (v) => setState(() => _search = v)),
          if (rows == null)
            const Skeleton(rows: 5)
          else if (_tab == 'customers') ...[
            Text('Customers (${shown.length})', style: const TextStyle(fontWeight: FontWeight.w700)),
            const SizedBox(height: 6),
            if (shown.isEmpty)
              const EmptyState(icon: LucideIcons.users, title: 'No customers yet', description: 'Add them here or while making a sale. Walk-in buyers need no record.')
            else
              for (final c in shown)
                () {
                  final st = statsOf(c['id']);
                  final off = c['status'] != 'active';
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: t.surface,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => _view(c, st),
                        onDoubleTap: canEdit ? () => _edit(c) : null,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${c['name']}', style: TextStyle(fontWeight: FontWeight.w700, color: off ? t.textMuted : null)),
                              PlHelp([c['phone'], if (c['tin'] != null) 'TIN ${c['tin']}'].where((x) => x != null).join(' · ').ifEmpty('no phone')),
                              PlHelp('${st?.sales ?? 0} sale${st?.sales == 1 ? '' : 's'}${st?.oldest != null ? ' · owed since ${tableDate(st!.oldest)}' : ''}${off ? ' · not in use' : ''}'),
                            ])),
                            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Text(money(st?.owed ?? 0), style: TextStyle(fontWeight: FontWeight.w700, color: (st?.owed ?? 0) > 0 ? C.warning : null)),
                              const PlHelp('owed'),
                            ]),
                          ]),
                        ),
                      ),
                    ),
                  );
                }(),
          ] else ...[
            if (owing.isEmpty)
              PlHelp(_search.isNotEmpty ? 'Nobody matches.' : 'Nobody owes anything.')
            else ...[
              for (final b in owing)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: t.surface,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: b.customer == null ? null : () => _view(b.customer!, statsOf(b.key)),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(children: [
                            Expanded(child: Text(b.name, style: const TextStyle(fontWeight: FontWeight.w700))),
                            Text(formatAmount(b.owed), style: const TextStyle(fontWeight: FontWeight.w700)),
                          ]),
                          PlHelp('${b.customer == null ? 'walk-in · ' : ''}${b.phone ?? ''}${b.oldest != null ? ' · owed since ${tableDate(b.oldest)}' : ''} · last paid ${b.lastPaid != null ? tableDate(b.lastPaid) : 'never'}'),
                          const SizedBox(height: 6),
                          Row(children: [
                            for (final (i, x) in ageBuckets.indexed)
                              Expanded(child: Column(children: [
                                Text(x.$3.replaceAll(' days', ''), style: TextStyle(fontSize: Fs.xs, color: t.textMuted)),
                                Text(b.buckets[i] != 0 ? formatAmount(b.buckets[i]) : '—', style: TextStyle(fontSize: Fs.sm, color: i >= 2 && b.buckets[i] > 0 ? C.warning : null)),
                              ])),
                          ]),
                        ]),
                      ),
                    ),
                  ),
                ),
              CardBox(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Row(children: [const Expanded(child: Text('Total', style: TextStyle(fontWeight: FontWeight.w700))), Text(money(owing.fold<double>(0, (s, b) => s + b.owed)), style: const TextStyle(fontWeight: FontWeight.w700))]),
                  for (final (i, x) in ageBuckets.indexed)
                    Row(children: [Expanded(child: PlHelp(x.$3)), Text(money(r2(owing.fold<double>(0, (s, b) => s + b.buckets[i]))), style: const TextStyle(fontSize: Fs.sm))]),
                ]),
              ),
            ],
          ],
        ]),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

// ---- a customer: details, statement, history ----
class _CustomerView extends StatefulWidget {
  const _CustomerView({required this.customer, required this.sales, required this.stats, required this.canEdit, required this.onEdit});
  final Json customer;
  final List<Json> sales;
  final Buyer? stats;
  final bool canEdit;
  final VoidCallback onEdit;
  @override
  State<_CustomerView> createState() => _CustomerViewState();
}

class _CustomerViewState extends State<_CustomerView> {
  final _rp = RangePeriod('customer-statement');

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final c = widget.customer;
    final st = statementLines(widget.sales, null, session.today);
    final history = [...widget.sales]..sort((a, b) => owedSince(b).compareTo(owedSince(a)));
    String money(num v) => formatMoney(v, session.currency);
    Widget dl(String k, String v, {Color? color}) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 90, child: PlHelp(k)),
            Expanded(child: Text(v, style: TextStyle(fontSize: Fs.sm, color: color))),
          ]),
        );
    final owed = widget.stats?.owed ?? 0;
    return FullPage(
      title: '${c['name']}',
      footer: [
        if (widget.canEdit) OutlinedButton(onPressed: widget.onEdit, child: const Text('Edit')),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
      ],
      children: [
        dl('Phone', '${c['phone'] ?? '—'}'),
        dl('Email', '${c['email'] ?? '—'}'),
        dl('TIN / VRN', [c['tin'], c['vrn']].where((x) => x != null).join(' / ').ifEmpty('—')),
        dl('Address', '${c['address'] ?? '—'}'),
        dl('Owed', '${money(owed)}${widget.stats?.oldest != null ? ' — since ${tableDate(widget.stats!.oldest)}' : ''} · bought ${money(st.charged)}, paid ${money(st.paid)} in all', color: owed > 0 ? C.warning : null),
        if (c['notes'] != null) dl('Notes', '${c['notes']}'),
        SectionTitle('Statement of account', trailing: OutlinedButton.icon(
          onPressed: () => openDoc(context, 'Statement ${c['name']} ${_rp.from}–${_rp.to}', () => statementPdf('${c['id']}', from: _rp.key == 'all' ? null : _rp.from, to: _rp.to)),
          icon: const Icon(LucideIcons.fileText, size: 15), label: const Text('Statement'),
        )),
        _rp.bar(context, () => setState(() {})),
        const SectionTitle('History'),
        if (history.isEmpty)
          const PlHelp('No orders or invoices yet.')
        else
          for (final s in history)
            () {
              final paid = paidOf(s), bal = r2(n(s['total']) - paid);
              final pays = jl(s['payments'])..sort((a, b) => '${a['paid_on']}'.compareTo('${b['paid_on']}'));
              return InkWell(
                onTap: () => openDoc(context, '${s['stage'] == 'invoice' ? 'Invoice' : 'Proforma'} #${s['sale_no']}', () => saleDocPdf('${s['id']}', s['stage'] == 'invoice' ? 'invoice' : 'proforma')),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(child: Text('${tableDate(owedSince(s))} · ${s['stage'] == 'invoice' ? 'Invoice' : 'Order'} #${s['sale_no']}', style: const TextStyle(fontWeight: FontWeight.w600))),
                      Text(formatAmount(n(s['total'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ]),
                    Row(children: [
                      Expanded(child: PlHelp(pays.map((p) => '${tableDate(p['paid_on'])}: ${formatAmount(n(p['amount']))}').join(' · ').ifEmpty('no payment'))),
                      Text(bal > 0.004 ? 'owes ${formatAmount(bal)}' : 'paid', style: TextStyle(fontSize: Fs.sm, color: bal > 0.004 ? C.warning : t.textMuted, fontWeight: FontWeight.w600)),
                    ]),
                  ]),
                ),
              );
            }(),
      ],
    );
  }
}

// ---- new / edit customer ----
class _CustomerForm extends StatefulWidget {
  const _CustomerForm({this.customer});
  final Json? customer;
  @override
  State<_CustomerForm> createState() => _CustomerFormState();
}

class _CustomerFormState extends State<_CustomerForm> {
  Json? get c => widget.customer;
  late final Map<String, TextEditingController> _f = {
    for (final k in ['name', 'phone', 'email', 'tin', 'vrn', 'address', 'notes', 'payment_days']) k: TextEditingController(text: c?[k] == null ? '' : '${c![k]}'),
  };
  late bool _active = (c?['status'] ?? 'active') == 'active';
  int? _usual; // 097: null while loading or before it
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    db.from('organizations').select('default_payment_days').eq('id', session.organization!['id']).maybeSingle()
        .then((d) { if (mounted) setState(() => _usual = n(d?['default_payment_days']).toInt()); }).catchError((_) {});
  }

  Future<void> _save() async {
    setState(() => _error = '');
    if (_f['name']!.text.trim().isEmpty) { setState(() => _error = 'Enter the name.'); return; }
    final row = <String, dynamic>{for (final e in _f.entries) e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim(), 'status': _active ? 'active' : 'inactive'};
    if (_usual == null) {
      row.remove('payment_days');
    } else if (row['payment_days'] != null) {
      final d = int.tryParse('${row['payment_days']}');
      if (d == null || d < 0 || d > 365) { setState(() => _error = 'Payment days: 0 to 365, or empty for the usual.'); return; }
      row['payment_days'] = d;
    }
    setState(() => _busy = true);
    try {
      if (c != null) {
        await db.from('customers').update(row).eq('id', c!['id']);
      } else {
        await db.from('customers').insert({...row, 'organization_id': session.organization!['id'], 'branch_id': session.branchId.isEmpty ? null : session.branchId});
      }
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  Widget field(String k, String label, {TextInputType? type}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(controller: _f[k], keyboardType: type, autofocus: k == 'name' && c == null, decoration: InputDecoration(labelText: label, hintText: k == 'payment_days' ? 'usual' : null)),
      );

  @override
  Widget build(BuildContext context) => FullPage(
        title: c != null ? 'Edit ${c!['name']}' : 'New customer',
        footer: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
        ],
        children: [
          field('name', 'Name'),
          Row(children: [Expanded(child: field('phone', 'Phone', type: TextInputType.phone)), const SizedBox(width: 8), Expanded(child: field('email', 'Email', type: TextInputType.emailAddress))]),
          Row(children: [Expanded(child: field('tin', 'TIN')), const SizedBox(width: 8), Expanded(child: field('vrn', 'VRN'))]),
          if (_usual != null) field('payment_days', 'Payment days (usual $_usual)', type: TextInputType.number),
          field('address', 'Address'),
          field('notes', 'Notes'),
          if (c != null) CheckboxListTile(value: _active, onChanged: (v) => setState(() => _active = v ?? true), contentPadding: EdgeInsets.zero, controlAffinity: ListTileControlAffinity.leading, title: const Text('In use')),
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        ],
      );
}

// ======================= Leads (CRM, 095) =======================
const leadStage = {'new': 'New', 'contacted': 'Contacted', 'quoted': 'Quoted', 'won': 'Won', 'lost': 'Lost'};
const _stageTone = {'new': Tone.info, 'contacted': Tone.neutral, 'quoted': Tone.warning, 'won': Tone.success, 'lost': Tone.error};
const _source = {'walk_in': 'Walk-in', 'phone': 'Phone call', 'whatsapp': 'WhatsApp', 'referral': 'Referral', 'site_visit': 'Site visit', 'social': 'Social media', 'other': 'Other'};
const _kind = {'call': 'Call', 'visit': 'Visit', 'whatsapp': 'WhatsApp', 'meeting': 'Meeting', 'other': 'Other'};
String _fullName(Json? p) => [p?['first_name'], p?['last_name']].where((x) => x != null && '$x'.isNotEmpty).join(' ').ifEmpty('Someone');

class _Leads extends StatefulWidget {
  const _Leads();
  @override
  State<_Leads> createState() => _LeadsState();
}

class _LeadsState extends State<_Leads> {
  List<Json>? _leads;
  List<Json> _people = [];
  Map<String, Json> _sales = {};
  String _error = '', _stage = 'open', _search = '';
  String get branchId => session.branchId;
  String get today => session.today;
  bool get canEdit => branchId.isNotEmpty && session.canAt('sales.create', branchId, null);

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final r = await Future.wait<dynamic>([
        db.from('leads').select('*').order('created_at', ascending: false),
        db.from('profiles').select('id, first_name, last_name, status'),
      ]);
      final leads = jl(r[0]);
      final ids = [for (final l in leads) if (l['sale_id'] != null) l['sale_id']];
      final sales = ids.isEmpty ? <Json>[] : jl(await db.from('sales').select('id, sale_no, stage, total').inFilter('id', ids));
      if (mounted) setState(() { _leads = leads; _people = jl(r[1]); _sales = {for (final s in sales) '${s['id']}': s}; });
    } catch (_) {
      if (mounted) setState(() { _error = "We couldn't load leads."; _leads = []; });
    }
  }

  /// a lead whose quotation became an order or invoice is won
  String stageOf(Json l) => l['stage'] != 'lost' && ['order', 'invoice'].contains(_sales['${l['sale_id']}']?['stage']) ? 'won' : '${l['stage']}';

  Future<void> _edit([Json? l]) async {
    final ok = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _LeadForm(lead: l, branchId: '${l?['branch_id'] ?? branchId}', people: _people)));
    if (ok == true) _load();
  }

  Future<void> _view(Json l) async {
    final a = await Navigator.push<String>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _LeadView(lead: l, stage: stageOf(l), sale: _sales['${l['sale_id']}'], people: _people, canEdit: canEdit, onChanged: _load)));
    if (!mounted) return;
    if (a == 'edit') _edit(l);
    if (a == 'quote') {
      try {
        final cid = await db.rpc('lead_to_customer', params: {'p_lead': l['id']});
        if (mounted) Shell.of(context).go('/sales?tab=list&quote_for=$cid&lead=${l['id']}');
      } catch (e) {
        setState(() => _error = dbError(e));
      }
    }
    if (a == 'sales' && mounted) Shell.of(context).go('/sales?tab=list');
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final leads = _leads;
    final here = (leads ?? []).where((l) => session.inBranch(l['branch_id'])).toList();
    final open = here.where((l) => !['won', 'lost'].contains(stageOf(l))).toList();
    final due = open.where((l) => l['next_follow_up'] != null && '${l['next_follow_up']}'.compareTo(today) <= 0).toList();
    final month = today.substring(0, 7);
    final wonMonth = here.where((l) => stageOf(l) == 'won' && '${l['updated_at'] ?? ''}'.startsWith(month)).length;
    final q = _search.trim().toLowerCase();
    final shown = here.where((l) {
      final st = stageOf(l);
      if (_stage == 'open' && ['won', 'lost'].contains(st)) return false;
      if (_stage == 'due' && !(l['next_follow_up'] != null && '${l['next_follow_up']}'.compareTo(today) <= 0 && !['won', 'lost'].contains(st))) return false;
      if (!['open', 'due', 'all'].contains(_stage) && st != _stage) return false;
      return q.isEmpty || '${l['name']} ${l['contact_person'] ?? ''} ${l['phone'] ?? ''} ${l['site'] ?? ''} ${l['interest'] ?? ''}'.toLowerCase().contains(q);
    }).toList();
    Json? personOf(Object? id) => _people.where((p) => p['id'] == id).firstOrNull;

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: canEdit ? FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(LucideIcons.plus), label: const Text('New lead')) : null,
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 88), children: [
          if (leads != null)
            Stats([
              Stat('Open leads', '${open.length}', help: 'worth about ${formatMoneyShort(open.fold<double>(0, (t, l) => t + n(l['estimated_value'])), session.currency)}'),
              Stat('Follow-ups due', '${due.length}', figureColor: due.isNotEmpty ? C.warning : null, help: due.isNotEmpty ? '${due.where((l) => '${l['next_follow_up']}'.compareTo(today) < 0).length} late' : 'none today'),
              Stat('Won this month', '$wonMonth', help: '${here.where((l) => stageOf(l) == 'lost').length} lost in all'),
            ]),
          ListToolbar(placeholder: 'Search name, contact, site or what they want…', onSearch: (v) => setState(() => _search = v)),
          SlideRow(children: [
            for (final (k, l) in [('open', 'Open'), ('due', 'Due (${due.length})'), ('new', 'New'), ('contacted', 'Contacted'), ('quoted', 'Quoted'), ('won', 'Won'), ('lost', 'Lost'), ('all', 'All')])
              Chip2(l, on: _stage == k, onTap: () => setState(() => _stage = k)),
          ]),
          const SizedBox(height: 8),
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
          if (leads == null)
            const Skeleton(rows: 3)
          else if (shown.isEmpty)
            const EmptyState(icon: LucideIcons.target, title: 'No leads here', description: 'Add contractors, sites and enquiries before they buy — with who follows up and when.')
          else
            for (final l in shown)
              () {
                final st = stageOf(l);
                final closed = ['won', 'lost'].contains(st);
                final nf = l['next_follow_up'] as String?;
                final late = nf != null && nf.compareTo(today) < 0 && !closed;
                final isDue = nf != null && nf.compareTo(today) <= 0 && !closed;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Material(
                    color: t.surface,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () => _view(l),
                      onDoubleTap: canEdit ? () => _edit(l) : null,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('${l['name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                              PlHelp([l['contact_person'], l['site']].where((x) => x != null && '$x'.isNotEmpty).join(' · ').ifEmpty(_source[l['source']] ?? '')),
                            ])),
                            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                              Text(l['estimated_value'] != null ? formatAmount(n(l['estimated_value'])) : '—', style: const TextStyle(fontWeight: FontWeight.w700)),
                              PlHelp('${l['interest'] ?? 'interest not noted'}'),
                            ]),
                          ]),
                          const SizedBox(height: 4),
                          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                            Badge2(leadStage[st] ?? st, tone: _stageTone[st] ?? Tone.neutral),
                            if (l['sale_id'] != null && _sales['${l['sale_id']}'] != null) PlHelp('#${_sales['${l['sale_id']}']!['sale_no']}'),
                            PlHelp(closed ? (st == 'lost' ? '${l['lost_reason'] ?? ''}' : '') : nf != null ? 'Follow up ${nf == today ? 'today' : dateText(nf)}${late ? ' (late)' : ''}' : 'no follow-up planned',
                                color: late ? C.error : isDue ? C.warning : null),
                            PlHelp(l['assigned_to'] != null ? _fullName(personOf(l['assigned_to'])) : 'not assigned'),
                          ]),
                        ]),
                      ),
                    ),
                  ),
                );
              }(),
        ]),
      ),
    );
  }
}

class _LeadForm extends StatefulWidget {
  const _LeadForm({this.lead, required this.branchId, required this.people});
  final Json? lead;
  final String branchId;
  final List<Json> people;
  @override
  State<_LeadForm> createState() => _LeadFormState();
}

class _LeadFormState extends State<_LeadForm> {
  Json? get l => widget.lead;
  late final Map<String, TextEditingController> _f = {
    for (final k in ['name', 'contact_person', 'phone', 'email', 'site', 'interest', 'estimated_value', 'notes'])
      k: TextEditingController(text: l?[k] == null ? '' : (k == 'estimated_value' ? qtyText(n(l![k])).replaceAll(',', '') : '${l![k]}')),
  };
  late String _sourceV = '${l?['source'] ?? ''}', _assigned = '${l?['assigned_to'] ?? session.userId ?? ''}', _next = '${l?['next_follow_up'] ?? session.today}';
  bool _busy = false;
  String _error = '';

  Future<void> _save() async {
    setState(() => _error = '');
    if (_f['name']!.text.trim().isEmpty) { setState(() => _error = 'Enter who the lead is.'); return; }
    if (widget.branchId.isEmpty) { setState(() => _error = 'Choose a branch first.'); return; }
    String? v(String k) => _f[k]!.text.trim().isEmpty ? null : _f[k]!.text.trim();
    final row = {
      'name': v('name'), 'contact_person': v('contact_person'), 'phone': v('phone'), 'email': v('email'), 'site': v('site'), 'source': _sourceV.isEmpty ? null : _sourceV,
      'interest': v('interest'), 'estimated_value': numOrNullText(_f['estimated_value']!.text), 'assigned_to': _assigned.isEmpty ? null : _assigned,
      'next_follow_up': _next.isEmpty ? null : _next, 'notes': v('notes'),
    };
    setState(() => _busy = true);
    try {
      if (l != null) {
        await db.from('leads').update(row).eq('id', l!['id']);
      } else {
        await db.from('leads').insert({...row, 'organization_id': session.organization!['id'], 'branch_id': widget.branchId, 'created_by': session.userId});
      }
      if (mounted) Navigator.pop(context, true);
      return;
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  double? numOrNullText(String s) => s.trim().isEmpty ? null : double.tryParse(s.trim().replaceAll(',', ''));
  Widget field(String k, String label, {TextInputType? type, String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: TextField(controller: _f[k], keyboardType: type, autofocus: k == 'name' && l == null, decoration: InputDecoration(labelText: label, hintText: hint)),
      );

  @override
  Widget build(BuildContext context) => FullPage(
        title: l != null ? 'Edit ${l!['name']}' : 'New lead',
        footer: [
          OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _save, child: Text(_busy ? 'Saving…' : 'Save')),
        ],
        children: [
          field('name', 'Who (person or company)'),
          field('contact_person', 'Contact person'),
          Row(children: [Expanded(child: field('phone', 'Phone', type: TextInputType.phone)), const SizedBox(width: 8), Expanded(child: field('email', 'Email', type: TextInputType.emailAddress))]),
          field('site', 'Site', hint: 'where the work is'),
          DropdownButtonFormField<String>(
            initialValue: _sourceV, isExpanded: true, decoration: const InputDecoration(labelText: 'Came from'),
            items: [const DropdownMenuItem(value: '', child: Text('—')), for (final e in _source.entries) DropdownMenuItem(value: e.key, child: Text(e.value))],
            onChanged: (v) => setState(() => _sourceV = v ?? ''),
          ),
          const SizedBox(height: 10),
          field('interest', 'Wants', hint: 'e.g. 500 m² red paving, 2,000 Tofali 5"'),
          field('estimated_value', 'About (TZS)', type: const TextInputType.numberWithOptions(decimal: true)),
          DropdownButtonFormField<String>(
            initialValue: widget.people.any((p) => p['id'] == _assigned) ? _assigned : '', isExpanded: true, decoration: const InputDecoration(labelText: 'Who follows up'),
            items: [const DropdownMenuItem(value: '', child: Text('Not assigned')),
              for (final p in widget.people.where((p) => p['status'] != 'inactive' || p['id'] == _assigned))
                DropdownMenuItem(value: '${p['id']}', child: Text('${_fullName(p)}${p['id'] == session.userId ? ' (me)' : ''}'))],
            onChanged: (v) => setState(() => _assigned = v ?? ''),
          ),
          const SizedBox(height: 10),
          DateField(label: 'Next follow-up', value: _next, onChange: (v) => setState(() => _next = v)),
          const SizedBox(height: 10),
          field('notes', 'Notes'),
          if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        ],
      );
}

class _LeadView extends StatefulWidget {
  const _LeadView({required this.lead, required this.stage, this.sale, required this.people, required this.canEdit, required this.onChanged});
  final Json lead;
  final String stage;
  final Json? sale;
  final List<Json> people;
  final bool canEdit;
  final Future<void> Function() onChanged;
  @override
  State<_LeadView> createState() => _LeadViewState();
}

class _LeadViewState extends State<_LeadView> {
  Json get lead => widget.lead;
  late String _stage = widget.stage;
  List<Json>? _history;
  String _fuKind = 'call';
  late String _doneOn = session.today;
  String _nextFu = '';
  final _note = TextEditingController(), _lost = TextEditingController();
  bool _losing = false, _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _note.addListener(() => setState(() {}));
    _lost.addListener(() => setState(() {}));
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    try {
      final d = jl(await db.from('lead_follow_ups').select('*').eq('lead_id', lead['id']).order('done_on', ascending: false).order('created_at', ascending: false));
      if (mounted) setState(() => _history = d);
    } catch (_) {
      if (mounted) setState(() => _history = []);
    }
  }

  String nameOf(Object? id) => _fullName(widget.people.where((p) => p['id'] == id).firstOrNull);

  Future<void> _run(Future<dynamic> Function() q, [VoidCallback? after]) async {
    setState(() { _error = ''; _busy = true; });
    try {
      await q();
      await _loadHistory();
      await widget.onChanged();
      after?.call();
    } catch (e) {
      _error = dbError(e);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final closed = ['won', 'lost'].contains(_stage);
    Widget dl(String k, String v) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [SizedBox(width: 90, child: PlHelp(k)), Expanded(child: Text(v, style: const TextStyle(fontSize: Fs.sm)))]),
        );
    return FullPage(
      title: '${lead['name']}',
      footer: [
        if (widget.canEdit && !closed && !_losing) TextButton(onPressed: () => setState(() => _losing = true), child: const Text('Mark lost…')),
        if (widget.canEdit && _stage == 'lost')
          TextButton(onPressed: _busy ? null : () => _run(() => db.from('leads').update({'stage': 'contacted', 'lost_reason': null}).eq('id', lead['id']), () => setState(() => _stage = 'contacted')), child: const Text('Reopen')),
        if (widget.canEdit) OutlinedButton(onPressed: () => Navigator.pop(context, 'edit'), child: const Text('Edit')),
        if (widget.sale != null)
          OutlinedButton(onPressed: () => Navigator.pop(context, 'sales'), child: Text('Quotation ${widget.sale!['sale_no']} ›'))
        else if (widget.canEdit && !closed)
          FilledButton(onPressed: () => Navigator.pop(context, 'quote'), child: const Text('Make quotation')),
      ],
      children: [
        dl('Stage', '${leadStage[_stage] ?? _stage}${_stage == 'lost' && lead['lost_reason'] != null ? ' — ${lead['lost_reason']}' : ''}'),
        dl('Contact', [lead['contact_person'], lead['phone'], lead['email']].where((x) => x != null && '$x'.isNotEmpty).join(' · ').ifEmpty('—')),
        dl('Site', '${lead['site'] ?? '—'}'),
        dl('Wants', '${lead['interest'] ?? '—'}${lead['estimated_value'] != null ? ' · about ${formatMoneyShort(n(lead['estimated_value']), session.currency)}' : ''}'),
        dl('Came from', _source[lead['source']] ?? '—'),
        dl('Follows up', '${lead['assigned_to'] != null ? nameOf(lead['assigned_to']) : 'Not assigned'}${lead['next_follow_up'] != null && !closed ? ' — next ${dateText(lead['next_follow_up'])}' : ''}'),
        if (lead['notes'] != null) dl('Notes', '${lead['notes']}'),
        if (_losing) ...[
          const SizedBox(height: 8),
          TextField(controller: _lost, autofocus: true, decoration: const InputDecoration(labelText: 'Why was it lost?', hintText: 'e.g. bought elsewhere, price, project stopped')),
          Row(children: [
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: C.error),
              onPressed: _busy || _lost.text.trim().isEmpty ? null : () => _run(() => db.from('leads').update({'stage': 'lost', 'lost_reason': _lost.text.trim()}).eq('id', lead['id']), () => setState(() { _losing = false; _stage = 'lost'; })),
              child: const Text('Mark lost'),
            ),
            TextButton(onPressed: () => setState(() => _losing = false), child: const Text('Cancel')),
          ]),
        ],
        if (widget.canEdit && !closed) ...[
          const SectionTitle('Record a follow-up'),
          SlideRow(children: [for (final e in _kind.entries) Chip2(e.value, on: _fuKind == e.key, onTap: () => setState(() => _fuKind = e.key))]),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: DateField(label: 'On', value: _doneOn, last: session.today, onChange: (v) => setState(() => _doneOn = v))),
            const SizedBox(width: 8),
            Expanded(child: DateField(label: 'Next follow-up', value: _nextFu, first: session.today, onChange: (v) => setState(() => _nextFu = v))),
          ]),
          const SizedBox(height: 8),
          TextField(controller: _note, decoration: const InputDecoration(labelText: 'What was said')),
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: FilledButton(
            onPressed: _busy || _note.text.trim().isEmpty ? null : () => _run(
                () => db.from('lead_follow_ups').insert({'organization_id': lead['organization_id'], 'lead_id': lead['id'], 'done_on': _doneOn, 'kind': _fuKind, 'note': _note.text.trim(), 'next_follow_up': _nextFu.isEmpty ? null : _nextFu, 'done_by': session.userId}),
                () => setState(() { _fuKind = 'call'; _note.clear(); _doneOn = session.today; _nextFu = ''; })),
            child: const Text('Save follow-up'),
          )),
        ],
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        const SectionTitle('Follow-ups'),
        if (_history == null)
          const Skeleton(rows: 2)
        else if (_history!.isEmpty)
          const PlHelp('No follow-ups yet.')
        else
          for (final h in _history!)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text('${tableDate(h['done_on'])} · ${_kind[h['kind']] ?? ''} · ${nameOf(h['done_by'])}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.sm)),
                Text('${h['note'] ?? ''}', style: const TextStyle(fontSize: Fs.sm)),
                if (h['next_follow_up'] != null) PlHelp('next ${tableDate(h['next_follow_up'])}'),
              ]),
            ),
      ],
    );
  }
}
