import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/files.dart';
import '../core/format.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';

/*
 * Payments and their proof — a port of web components/sales/PaymentProofs.jsx (PaymentProofsList,
 * ReviewModal, proofState). The branch adds proof (reminders first: late, queried, then due);
 * directors confirm what waits: ✓ Received or ✗ Query (with what's wrong), marked on the slip
 * (review_payment_proof; a shared slip is marked on every payment it covers).
 */
const proofDays = 2, confirmDays = 3;
int _daysSince(String d, String today) => DateTime.parse(today).difference(DateTime.parse(d)).inDays;

/// none | late | waiting | overdue | queried | confirmed
String proofState(Json payment, Json? proof, String today) {
  if (proof == null) return _daysSince('${payment['paid_on']}', today) > proofDays ? 'late' : 'none';
  if (proof['status'] == 'confirmed') return 'confirmed';
  if (proof['status'] == 'queried') return 'queried';
  return _daysSince('${payment['paid_on']}', today) > confirmDays ? 'overdue' : 'waiting';
}

const proofBadge = {
  'none': ('No proof yet', Tone.neutral), 'late': ('Proof late', Tone.error), 'waiting': ('Waiting for a director', Tone.warning),
  'overdue': ('Confirmation overdue', Tone.error), 'queried': ('Queried', Tone.error), 'confirmed': ('Confirmed', Tone.success),
};

/// READY_MARK (SlipMark.jsx): the tick / cross a box puts on the slip
const readyMark = {
  'green': [[[0.30, 0.52], [0.42, 0.66], [0.72, 0.30]]],
  'red': [[[0.32, 0.34], [0.68, 0.66]], [[0.68, 0.34], [0.32, 0.66]]],
};

Future<Map<String, Json>> loadProofs() async {
  final data = await db.from('sale_payment_proofs').select('*');
  return {for (final p in data) p['payment_id'] as String: p};
}

class PaymentProofsList extends StatefulWidget {
  const PaymentProofsList({super.key, this.directorView = false});
  final bool directorView;
  @override
  State<PaymentProofsList> createState() => _PaymentProofsListState();
}

class _PaymentProofsListState extends State<PaymentProofsList> {
  List<Json>? _rows;
  Map<String, Json> _proofs = {};
  Map<String, String> _accounts = {};
  late String _show = widget.directorView ? 'waiting' : 'todo';
  DateTime? _savedAt;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final (d, at) = await offline.load<Json>('proofs', () async {
        final res = await Future.wait<dynamic>([
          db.from('sale_payments').select('id, sale_id, paid_on, amount, method, receipt_no, account_id, created_at, sale:sales!inner(id, sale_no, branch_id, stage, customer_id, walk_in_name, total, customer:customers(name))')
              .order('paid_on', ascending: false).limit(500),
          db.from('sale_payment_proofs').select('*'),
          db.from('payment_accounts').select('id, name'),
        ]);
        return {'p': res[0], 'pr': res[1], 'ac': res[2]};
      });
      if (!mounted) return;
      setState(() {
        _savedAt = at;
        _rows = [for (final x in d['p'] as List) if (x['sale']['stage'] != 'cancelled') Map<String, dynamic>.from(x)];
        _proofs = {for (final p in d['pr'] as List) p['payment_id'] as String: Map<String, dynamic>.from(p)};
        _accounts = {for (final a in d['ac'] as List) a['id'] as String: '${a['name']}'};
      });
    } catch (_) {
      if (mounted) setState(() => _rows = []);
    }
  }

  String _buyer(Json x) => '${x['sale']['customer']?['name'] ?? x['sale']['walk_in_name'] ?? 'Walk-in'}';
  String _acc(Json x) => _accounts[x['account_id']] ?? const {'cash': 'Cash', 'mobile_money': 'Mobile money', 'bank': 'Bank'}[x['method']] ?? '';

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows == null) return const Padding(padding: EdgeInsets.all(14), child: Skeleton());
    final today = session.today;
    final here = [for (final x in rows) if (session.inBranch(x['sale']['branch_id'])) {...x, 'state': proofState(x, _proofs[x['id']], today)}];
    const todo = ['late', 'queried', 'none'];
    final counts = {
      'todo': here.where((x) => todo.contains(x['state'])).length,
      'waiting': here.where((x) => x['state'] == 'waiting' || x['state'] == 'overdue').length,
      'confirmed': here.where((x) => x['state'] == 'confirmed').length,
      'all': here.length,
    };
    const order = {'late': 0, 'queried': 1, 'overdue': 2, 'none': 3, 'waiting': 4, 'confirmed': 5};
    final shown = here.where((x) => _show == 'all' || (_show == 'todo' ? todo.contains(x['state']) : _show == 'waiting' ? (x['state'] == 'waiting' || x['state'] == 'overdue') : x['state'] == 'confirmed')).toList()
      ..sort((a, b) {
        final o = _show == 'all' || _show == 'confirmed' ? 0 : order[a['state']]!.compareTo(order[b['state']]!);
        return o != 0 ? o : '${b['paid_on']}'.compareTo('${a['paid_on']}');
      });
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        OfflineNote(_savedAt),
        Stats([
          Stat('Proof to add', '${counts['todo']}', figureColor: counts['todo']! > 0 ? C.warning : null, help: '${here.where((x) => x['state'] == 'late').length} late (over $proofDays days)'),
          Stat('Waiting for a director', '${counts['waiting']}', figureColor: counts['waiting']! > 0 ? C.warning : null, help: '${here.where((x) => x['state'] == 'overdue').length} overdue (over $confirmDays days)'),
          Stat('Confirmed', '${counts['confirmed']}', help: 'of ${counts['all']} payments'),
        ]),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (k, l) in const [('todo', 'Proof to add'), ('waiting', 'Waiting'), ('confirmed', 'Confirmed'), ('all', 'All')])
            Chip2('$l (${counts[k]})', on: _show == k, onTap: () => setState(() => _show = k)),
        ]),
        const SizedBox(height: 10),
        if (shown.isEmpty)
          EmptyState(icon: LucideIcons.receipt, title: _show == 'todo' ? 'Every payment has its proof.' : _show == 'waiting' ? 'Nothing waits for a director.' : 'Nothing here.')
        else
          for (final x in shown) _row(context, x),
      ]),
    );
  }

  Widget _row(BuildContext context, Json x) {
    final t = context.tk;
    final pr = _proofs[x['id']];
    final (label, tone) = proofBadge[x['state']]!;
    final canReview = pr != null && x['state'] != 'confirmed' && session.canAt('sales.confirm_payments', x['sale']['branch_id']);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: t.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: pr == null ? null : () => _review(x, pr, canReview),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('#${x['sale']['sale_no']} · ${_buyer(x)}', style: const TextStyle(fontWeight: FontWeight.w600)),
                  PlHelp('${tableDate(x['paid_on'])} · ${_acc(x)}${x['receipt_no'] != null ? ' · receipt ${x['receipt_no']}' : ''}'),
                  const SizedBox(height: 4),
                  Badge2(label, tone: tone),
                  if (pr?['status'] == 'queried') PlHelp('${pr!['note'] ?? ''}', color: C.error),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(formatAmount(n(x['amount'])), style: const TextStyle(fontWeight: FontWeight.w700)),
                if (canReview) Padding(padding: const EdgeInsets.only(top: 6), child: FilledButton(onPressed: () => _review(x, pr, true), child: const Text('Check')))
                else if (pr != null) TextButton(onPressed: () => _review(x, pr, false), child: const Text('View')),
              ]),
            ]),
          ),
        ),
      ),
    );
  }

  Future<void> _review(Json x, Json proof, bool canReview) async {
    final done = await showModal<bool>(context, title: 'Payment proof · ${formatMoney(n(x['amount']), session.currency)}',
        body: (ctx) => ProofReview(payment: x, proof: proof, buyer: _buyer(x), account: _acc(x), canReview: canReview));
    if (done == true) _load();
  }
}

/// ReviewModal: the slip, the sale's items, and ✓ Received / ✗ Query
class ProofReview extends StatefulWidget {
  const ProofReview({super.key, required this.payment, required this.proof, required this.buyer, required this.account, required this.canReview});
  final Json payment, proof;
  final String buyer, account;
  final bool canReview;
  @override
  State<ProofReview> createState() => _ProofReviewState();
}

class _ProofReviewState extends State<ProofReview> {
  String? _url;
  List<Json> _siblings = [];
  Map<String, List<Json>> _lines = {};
  String? _pick; // confirm | query
  final _note = TextEditingController();
  bool _busy = false;
  String _error = '';

  Json get pay => widget.payment;
  Json get proof => widget.proof;
  bool get _isPdf => RegExp(r'\.pdf$', caseSensitive: false).hasMatch('${proof['file_path'] ?? ''}');
  bool get _isPhoto => (proof['file_path'] != null && !_isPdf) || (proof['file_path'] == null && proof['sms_text'] != null);

  @override
  void initState() {
    super.initState();
    if (proof['file_path'] != null) signedUrl('payment-proofs', proof['file_path']).then((u) { if (mounted) setState(() => _url = u); });
    _loadSiblings();
  }

  @override
  void dispose() { _note.dispose(); super.dispose(); }

  /// other payments the same slip covers (same file or SMS)
  Future<void> _loadSiblings() async {
    try {
      var q = db.from('sale_payment_proofs').select('id, payment_id, status, payment:sale_payments!inner(id, amount, paid_on, sale:sales!inner(id, sale_no, walk_in_name, customer:customers(name)))').neq('id', proof['id']);
      if (proof['file_path'] != null) {
        q = q.eq('file_path', proof['file_path']);
      } else if (proof['sms_text'] != null) {
        q = q.isFilter('file_path', null).eq('sms_text', proof['sms_text']);
      } else {
        return;
      }
      final sib = await q;
      final ids = [pay['sale']['id'], for (final x in sib) x['payment']['sale']['id']];
      final ls = await db.from('sale_lines').select('sale_id, line_no, item_name, quantity, price, total, unit:units(symbol), product:products(canonical_name)').inFilter('sale_id', ids).order('line_no');
      final m = <String, List<Json>>{};
      for (final l in ls) { m.putIfAbsent(l['sale_id'], () => []).add(l); }
      if (mounted) setState(() { _siblings = [for (final x in sib) Map<String, dynamic>.from(x)]; _lines = m; });
    } catch (_) {}
  }

  Future<void> _act(String action) async {
    if (action == 'query' && _note.text.trim().isEmpty) { setState(() => _error = 'Say what is wrong with the proof.'); return; }
    setState(() { _busy = true; _error = ''; });
    final ids = [pay['id'], for (final s in _siblings) if (s['status'] != 'confirmed') s['payment_id']];
    try {
      for (final id in ids) {
        await db.rpc('review_payment_proof', params: {
          'p_payment': id, 'p_action': action, 'p_note': action == 'query' ? _note.text.trim() : null,
          'p_mark': _isPhoto ? {'strokes': readyMark[action == 'confirm' ? 'green' : 'red']} : null,
        });
      }
      if (mounted) { toast(context, action == 'confirm' ? 'Signed as received' : 'Query sent'); Navigator.pop(context, true); }
    } catch (e) {
      if (mounted) setState(() { _busy = false; _error = dbError(e); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final open = widget.canReview && !_busy;
    final all = [
      (no: pay['sale']['sale_no'], id: pay['sale']['id'], who: widget.buyer, amount: n(pay['amount'])),
      for (final s in _siblings) (no: s['payment']['sale']['sale_no'], id: s['payment']['sale']['id'], who: '${s['payment']['sale']['customer']?['name'] ?? s['payment']['sale']['walk_in_name'] ?? 'Walk-in'}', amount: n(s['payment']['amount'])),
    ];
    final slipTotal = all.fold<double>(0, (s, r) => s + r.amount);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PlHelp('${_siblings.isEmpty ? 'Sale #${pay['sale']['sale_no']} · ${widget.buyer} · ' : ''}paid ${dateText(pay['paid_on'])} into ${widget.account}${pay['receipt_no'] != null ? ' · #${pay['receipt_no']}' : ''}'),
      const SizedBox(height: 8),
      if (_siblings.isNotEmpty) Text('One slip for ${_siblings.length + 1} sales', style: const TextStyle(fontWeight: FontWeight.w600)),
      for (final r in all) ...[
        Padding(padding: const EdgeInsets.only(top: 6), child: Text('${r.who} · #${r.no}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.sm))),
        for (final l in _lines[r.id] ?? const <Json>[])
          Row(children: [
            Expanded(child: Text('${l['product']?['canonical_name'] ?? l['item_name']} · ${qtyText(n(l['quantity']))} ${l['unit']?['symbol'] ?? ''} × ${formatAmount(n(l['price']))}', style: const TextStyle(fontSize: Fs.sm))),
            Text(formatAmount(n(l['total']).round()), style: const TextStyle(fontSize: Fs.sm)),
          ]),
      ],
      const Divider(),
      Row(children: [const Expanded(child: Text('This slip', style: TextStyle(fontWeight: FontWeight.w700))), Text(formatMoney(slipTotal, session.currency), style: const TextStyle(fontWeight: FontWeight.w700))]),
      if (proof['status'] == 'queried') Padding(padding: const EdgeInsets.only(top: 8), child: Alert('Queried: ${proof['note'] ?? ''}', tone: Tone.error)),
      const SizedBox(height: 10),
      if (proof['file_path'] != null)
        _isPdf
            ? OutlinedButton.icon(onPressed: _url == null ? null : () => launchUrl(Uri.parse(_url!), mode: LaunchMode.externalApplication), icon: const Icon(LucideIcons.fileText, size: 16), label: const Text('Open the PDF'))
            : (_url == null ? const Skeleton(rows: 1, height: 200) : Stack(children: [
                InteractiveViewer(maxScale: 4, child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.network(_url!, fit: BoxFit.contain))),
                if (_pick != null || proof['status'] != 'waiting')
                  Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _MarkPainter((_pick ?? (proof['status'] == 'confirmed' ? 'confirm' : 'query')) == 'confirm' ? 'green' : 'red')))),
              ])),
      if (proof['sms_text'] != null)
        Container(margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: t.soft, borderRadius: BorderRadius.circular(8)),
            child: Text('${proof['sms_text']}', style: const TextStyle(fontSize: Fs.sm))),
      if (widget.canReview) ...[
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: _box('confirm', '✓ Received', C.success, open)),
          const SizedBox(width: 10),
          Expanded(child: _box('query', '✗ Query', C.error, open)),
        ]),
        if (_pick == 'query') Padding(padding: const EdgeInsets.only(top: 10), child: TextField(controller: _note, decoration: const InputDecoration(labelText: "What's wrong?", hintText: 'Amount on the slip is different'))),
        if (_error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Alert(_error, tone: Tone.error)),
        const SizedBox(height: 12),
        if (_pick == 'confirm') FilledButton(onPressed: _busy ? null : () => _act('confirm'), child: Text(_busy ? 'Saving…' : 'Sign as received')),
        if (_pick == 'query') FilledButton(style: FilledButton.styleFrom(backgroundColor: C.error), onPressed: _busy ? null : () => _act('query'), child: Text(_busy ? 'Saving…' : 'Send query')),
      ],
    ]);
  }

  Widget _box(String kind, String label, Color c, bool enabled) {
    final on = _pick == kind;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(minimumSize: const Size(0, 52), side: BorderSide(color: on ? c : context.tk.borderStrong, width: on ? 2 : 1), foregroundColor: c),
      onPressed: enabled ? () => setState(() { _pick = kind; _error = ''; }) : null,
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }
}

class _MarkPainter extends CustomPainter {
  _MarkPainter(this.color);
  final String color;
  @override
  void paint(Canvas canvas, Size s) {
    final p = Paint()
      ..color = color == 'green' ? const Color(0xFF16A34A) : const Color(0xFFDC2626)
      ..strokeWidth = (s.width * 0.014).clamp(3, 12)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    for (final stroke in readyMark[color]!) {
      final path = Path()..moveTo(stroke.first[0] * s.width, stroke.first[1] * s.height);
      for (final pt in stroke.skip(1)) { path.lineTo(pt[0] * s.width, pt[1] * s.height); }
      canvas.drawPath(path, p);
    }
  }

  @override
  bool shouldRepaint(covariant _MarkPainter old) => old.color != color;
}
