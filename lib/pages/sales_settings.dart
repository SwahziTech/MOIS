import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;

import '../core/format.dart';
import '../core/sales.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';

/*
 * Sales settings — a port of web components/sales/SalesSettings.jsx, behind the ⚙ on Sales: the company's
 * payment terms (097) and the accounts each branch takes money into (067) — the cash box, banks, mobile money
 * lines. Managers add, rename, order and retire them; each is a column in the sales book. Online only.
 */
const _kinds = {'cash': 'Cash', 'bank': 'Bank', 'mobile_money': 'Mobile money'};

Future<void> openSalesSettings(BuildContext context) => Navigator.push(context, MaterialPageRoute(fullscreenDialog: true, builder: (ctx) => FullPage(
      title: 'Sales settings',
      footer: [OutlinedButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      children: const [_Terms(), SizedBox(height: 10), _Accounts()],
    )));

class _Terms extends StatefulWidget {
  const _Terms();
  @override
  State<_Terms> createState() => _TermsState();
}

class _TermsState extends State<_Terms> {
  int? _current;
  bool _off = false;
  final _days = TextEditingController();
  String _msg = '';
  bool get canSet => session.can('sales.discount');

  @override
  void initState() { super.initState(); _load(); _days.addListener(() => setState(() {})); }

  Future<void> _load() async {
    try {
      final d = await db.from('organizations').select('default_payment_days').eq('id', session.organization!['id']).maybeSingle();
      if (mounted) setState(() { _current = n(d?['default_payment_days']).toInt(); _days.text = '$_current'; });
    } catch (_) {
      if (mounted) setState(() => _off = true); // before 097
    }
  }

  Future<void> _save() async {
    setState(() => _msg = '');
    try {
      await db.rpc('set_default_payment_days', params: {'p_days': int.tryParse(_days.text.trim()) ?? 0});
      await _load();
      if (mounted) setState(() => _msg = 'Saved — new orders and invoices use it.');
    } catch (e) {
      if (mounted) setState(() => _msg = dbError(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_off || _current == null) return const SizedBox.shrink();
    return CardBox(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Payment terms', style: TextStyle(fontWeight: FontWeight.w700)),
        const PlHelp('Days to pay after an order or invoice (0 = at once).'),
        const SizedBox(height: 8),
        Row(children: [
          SizedBox(width: 90, child: TextField(controller: _days, enabled: canSet, keyboardType: TextInputType.number, decoration: const InputDecoration(isDense: true))),
          const SizedBox(width: 8),
          const Text('days'),
          const Spacer(),
          if (canSet) FilledButton(onPressed: _days.text.trim().isEmpty || int.tryParse(_days.text.trim()) == _current ? null : _save, child: const Text('Save')),
        ]),
        if (_msg.isNotEmpty) PlHelp(_msg),
      ]),
    );
  }
}

class _Accounts extends StatefulWidget {
  const _Accounts();
  @override
  State<_Accounts> createState() => _AccountsState();
}

class _AccountsState extends State<_Accounts> {
  late String _branch = session.branchId.isNotEmpty ? session.branchId : (session.branches.firstOrNull?.id ?? '');
  List<Json>? _rows;
  final _name = TextEditingController();
  String _kind = 'bank', _error = '';
  bool _busy = false;
  bool get canEdit => _branch.isNotEmpty && session.canAt('sales.discount', _branch, null);

  @override
  void initState() { super.initState(); _load(); _name.addListener(() => setState(() {})); }

  Future<void> _load() async {
    if (_branch.isEmpty) return;
    try {
      final d = jl(await db.from('payment_accounts').select('*').eq('branch_id', _branch).order('display_order', ascending: true).order('name', ascending: true));
      if (mounted) setState(() => _rows = d);
    } catch (_) {
      if (mounted) setState(() => _rows = []);
    }
  }

  Future<bool> _run(Future<dynamic> Function() q) async {
    setState(() { _error = ''; _busy = true; });
    var ok = true;
    try {
      await q();
    } catch (e) {
      _error = e is PostgrestException && e.code == '23505' ? 'That account is already on the list.' : dbError(e);
      ok = false;
    }
    if (mounted) setState(() => _busy = false);
    if (ok) await _load();
    return ok;
  }

  void _move(int i, int dir) {
    final list = [..._rows!];
    final j = i + dir;
    if (j < 0 || j >= list.length) return;
    final x = list[i];
    list[i] = list[j];
    list[j] = x;
    _run(() => Future.wait([for (final (k, a) in list.indexed) db.from('payment_accounts').update({'display_order': k + 1}).eq('id', a['id'])]));
  }

  Future<void> _rename(Json a) async {
    final c = TextEditingController(text: '${a['name']}');
    final v = await showDialog<String>(context: context, builder: (ctx) => AlertDialog(
          title: const Text('Rename the account'),
          content: TextField(controller: c, autofocus: true),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save'))],
        ));
    if (v != null && v.trim().isNotEmpty && v.trim() != a['name']) _run(() => db.from('payment_accounts').update({'name': v.trim()}).eq('id', a['id']));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final rows = _rows;
    return CardBox(
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Receiving accounts', style: TextStyle(fontWeight: FontWeight.w700)),
        if (session.branches.length > 1) ...[
          const SizedBox(height: 6),
          SlideRow(children: [for (final b in session.branches) Chip2(b.name, on: _branch == b.id, onTap: () { setState(() { _branch = b.id; _rows = null; }); _load(); })]),
        ],
        const PlHelp('Where customers pay. Each is a column in the sales book.'),
        const SizedBox(height: 6),
        if (rows == null)
          const Skeleton(rows: 3)
        else if (rows.isEmpty)
          const PlHelp('No accounts yet.')
        else
          for (final (i, a) in rows.indexed)
            Container(
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${a['name']}', style: TextStyle(fontWeight: FontWeight.w600, color: a['status'] != 'active' ? t.textMuted : null)),
                  PlHelp('${_kinds[a['kind']] ?? ''}${a['status'] != 'active' ? ' · retired' : ''}'),
                ])),
                if (canEdit) ...[
                  IconButton(tooltip: 'Move up', onPressed: _busy || i == 0 ? null : () => _move(i, -1), icon: const Icon(LucideIcons.arrowUp, size: 16)),
                  IconButton(tooltip: 'Move down', onPressed: _busy || i == rows.length - 1 ? null : () => _move(i, 1), icon: const Icon(LucideIcons.arrowDown, size: 16)),
                  PopupMenuButton<String>(
                    icon: const Icon(LucideIcons.ellipsisVertical, size: 18),
                    enabled: !_busy,
                    onSelected: (v) => v == 'rename' ? _rename(a) : _run(() => db.from('payment_accounts').update({'status': a['status'] == 'active' ? 'inactive' : 'active'}).eq('id', a['id'])),
                    itemBuilder: (_) => [const PopupMenuItem(value: 'rename', child: Text('Rename')), PopupMenuItem(value: 'status', child: Text(a['status'] == 'active' ? 'Retire' : 'Bring back'))],
                  ),
                ],
              ]),
            ),
        if (canEdit) ...[
          const SizedBox(height: 10),
          TextField(controller: _name, decoration: const InputDecoration(isDense: true, hintText: 'e.g. Bank — company account')),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: SlideRow(children: [for (final e in _kinds.entries) Chip2(e.value, on: _kind == e.key, onTap: () => setState(() => _kind = e.key))])),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _busy || _name.text.trim().isEmpty ? null : () async {
                if (await _run(() => db.from('payment_accounts').insert({'organization_id': session.organization!['id'], 'branch_id': _branch, 'name': _name.text.trim(), 'kind': _kind, 'display_order': (rows?.length ?? 0) + 1}))) _name.clear();
              },
              icon: const Icon(LucideIcons.plus, size: 15), label: const Text('Add account'),
            ),
          ]),
        ] else
          const PlHelp('Managers edit accounts.'),
        if (_error.isNotEmpty) PlHelp(_error, color: C.error),
      ]),
    );
  }
}
