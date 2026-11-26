import '../pages/payment_proofs.dart' show proofState;
import 'files.dart';
import 'format.dart';
import 'inventory.dart';
import 'proof_box.dart';
import 'session.dart';
import 'ui.dart' show Tone;

/*
 * Sales helpers shared by the Sales pages — ports of the web's pages/Sales.jsx helpers,
 * components/sales/PaymentProofs.jsx (saleApproval, postSaleProofs, postSharedSlip) and
 * components/sales/SaleProduction.jsx (loadSaleProduction, belongsTo, productionSummary).
 */
const saleStages = {'note': 'Note', 'quotation': 'Quotation', 'order': 'Order', 'invoice': 'Invoice', 'cancelled': 'Cancelled'};
const saleStageTone = {'note': Tone.neutral, 'quotation': Tone.neutral, 'order': Tone.info, 'invoice': Tone.success, 'cancelled': Tone.neutral};
/// Sales › Invoices tabs (141): the order pipeline — a cancelled sale stays under the stage it left
const salePipe = [('note', 'Notes'), ('quotation', 'Quotations'), ('order', 'Orders'), ('invoice', 'Invoices')];
const payMethods = {'cash': 'Cash', 'mobile_money': 'Mobile money', 'bank': 'Bank'};
const saleWaiting = [('stock', 'Stock'), ('cash', 'Cash'), ('transport', 'Transport'), ('customer', 'Customer')];
/// the advance before production — a warning only (2026-11-22)
const saleAdvance = 0.4;

List<Json> jl(Object? v) => [for (final x in (v as List? ?? [])) Map<String, dynamic>.from(x as Map)];
double? numOf(String? v) => (v ?? '').trim().isEmpty ? null : double.tryParse(v!.trim().replaceAll(',', ''));

double paidOf(Json s) => jl(s['payments']).fold(0.0, (t, p) => t + n(p['amount']));

/// delivered so far of one sale line (065)
double doneOf(Json s, Object? lineId) =>
    jl(s['deliveries']).fold(0.0, (t, d) => t + jl(d['lines']).where((y) => y['sale_line_id'] == lineId).fold<double>(0, (u, y) => u + n(y['quantity'])));

/// m² or pcs, as the product is counted (LOCKED unit follows product)
String perOf(Refs refs, Object? productId, {String piece = 'pcs'}) => refs.unit(refs.items['p:$productId']?.stockUnitId).toUpperCase() == 'SQM' ? 'm²' : piece;

String lineName(Refs refs, Json l) =>
    l['product_id'] != null ? '${refs.items['p:${l['product_id']}']?.name ?? ''}${l['color_id'] != null ? ' ${refs.colour('${l['color_id']}')}' : ''}' : '${l['item_name'] ?? ''}';

/// has a line's goods left? not | part | collected | done (other items are handed over with the sale)
String goodsStateOf(Json s, Json l) {
  if (l['product_id'] == null) return 'done';
  final d = doneOf(s, l['id']);
  if (d <= 1e-9) return 'not';
  if (d + 1e-9 < n(l['quantity'])) return 'part';
  final ds = jl(s['deliveries']).where((dv) => jl(dv['lines']).any((y) => y['sale_line_id'] == l['id'])).toList();
  final byCustomer = ds.every((dv) => dv['kind'] == 'collection');
  return ds.any((dv) => dv['status'] == 'on_the_way') || byCustomer ? 'collected' : 'done';
}

/// a sale's approval: approved when fully paid and every payment confirmed; else what's missing
({String state, String label, Tone tone}) saleApproval(Json sale, Map<String, Json> proofs, String today) {
  final pays = jl(sale['payments']);
  final paid = pays.fold<double>(0, (t, p) => t + n(p['amount']));
  final states = [for (final p in pays) proofState(p, proofs['${p['id']}'], today)];
  final toAdd = states.where((s) => s == 'none' || s == 'late' || s == 'queried').length;
  final waiting = states.where((s) => s == 'waiting' || s == 'overdue').length;
  if (pays.isNotEmpty && toAdd == 0 && waiting == 0 && paid + 0.01 >= n(sale['total'])) return (state: 'approved', label: '100% approved', tone: Tone.success);
  if (toAdd > 0) return (state: 'proof', label: toAdd == 1 ? 'No proof' : '$toAdd without proof', tone: states.any((s) => s == 'late' || s == 'queried') ? Tone.error : Tone.warning);
  if (waiting > 0) return (state: 'waiting', label: 'Waiting for a director', tone: states.contains('overdue') ? Tone.error : Tone.warning);
  return (state: 'owed', label: pays.isNotEmpty ? 'Part paid' : 'Not paid', tone: Tone.neutral);
}

/// a proof given while recording a sale: posted once the sale is saved, matched by account and amount
class PayProof {
  PayProof({this.accountId = '', this.amount = 0, this.file, this.text = ''});
  String accountId;
  double amount;
  ProofFile? file;
  String text;
  bool get has => file != null || text.trim().isNotEmpty;
}

Future<int> postSaleProofs(String saleId, List<PayProof> proofs, {required String buyer}) async {
  final want = proofs.where((x) => x.has).toList();
  if (want.isEmpty) return 0;
  final s = await db.from('sales').select('id, sale_no, branch_id, payments:sale_payments(id, account_id, amount, paid_on)').eq('id', saleId).maybeSingle();
  if (s == null) return want.length;
  final free = jl(s['payments']);
  var failed = 0;
  for (final x in want) {
    final i = free.indexWhere((p) => '${p['account_id'] ?? ''}' == x.accountId && (n(p['amount']) - x.amount).abs() < 0.01);
    if (i < 0) { failed++; continue; }
    final pay = free.removeAt(i);
    try {
      String? path, name;
      if (x.file != null) {
        path = await uploadProof('payment-proofs', '${s['branch_id']}', '${pay['id']}', x.file!);
        name = proofName(kind: 'Sale-${s['sale_no']}', who: buyer, amount: n(pay['amount']), date: pay['paid_on'], ext: x.file!.ext);
      }
      await db.rpc('submit_payment_proof', params: {'p': {'payment_id': pay['id'], 'file_path': path, 'file_name': name, 'sms_text': x.text.trim().isEmpty ? null : x.text.trim()}});
    } catch (_) {
      failed++;
    }
  }
  return failed;
}

/// one slip for several payments: uploaded once, every payment it covers points to it
Future<int> postSharedSlip(List<Json> payments, PayProof slip, {required String who}) async {
  if (payments.isEmpty || !slip.has) return payments.length;
  final total = payments.fold<double>(0, (t, p) => t + n(p['amount']));
  final nos = {for (final p in payments) n(p['sale']['sale_no']).toInt()}.toList()..sort();
  String? path, name;
  try {
    if (slip.file != null) {
      final f = slip.file!;
      path = '${session.organization!['id']}/${payments.first['sale']['branch_id']}/shared-${DateTime.now().millisecondsSinceEpoch}/${DateTime.now().millisecondsSinceEpoch}.${f.ext}';
      await uploadFile('payment-proofs', path, f.bytes, f.mime);
      name = proofName(kind: 'Sales-${nos.join('-')}', who: who, amount: total, date: payments.first['paid_on'], ext: f.ext);
    }
  } catch (_) {
    return payments.length;
  }
  var failed = 0;
  for (final p in payments) {
    try {
      await db.rpc('submit_payment_proof', params: {'p': {'payment_id': p['id'], 'file_path': path, 'file_name': name, 'sms_text': slip.text.trim().isEmpty ? null : slip.text.trim()}});
    } catch (_) {
      failed++;
    }
  }
  return failed;
}

// ---- customer orders (141): the production made for a sale ----
typedef ProdRow = ({Json order, Json line, Json? progress});

Future<Map<String, List<ProdRow>>> loadSaleProduction(List<String> saleIds) async {
  if (saleIds.isEmpty) return {};
  try {
    final orders = jl(await db.from('production_orders').select('id, order_no, status, due_date, sale_id, lines:production_order_lines(id, sale_line_id, product_id, color_id, pieces)').inFilter('sale_id', saleIds));
    if (orders.isEmpty) return {};
    final lineIds = [for (final o in orders) for (final l in jl(o['lines'])) l['id']];
    final prog = lineIds.isEmpty ? <Json>[] : jl(await db.from('production_order_line_progress').select('*').inFilter('line_id', lineIds));
    final byLine = {for (final p in prog) '${p['line_id']}': p};
    final out = <String, List<ProdRow>>{};
    for (final o in orders) {
      for (final l in jl(o['lines'])) {
        (out['${o['sale_id']}'] ??= []).add((order: o, line: l, progress: byLine['${l['id']}']));
      }
    }
    return out;
  } catch (_) {
    return {};
  }
}

/// a production line belongs to a sale line: by its link, or — after the sale was edited — by product and colour
bool belongsTo(ProdRow r, Json l, Json sale) =>
    r.line['sale_line_id'] == l['id'] ||
    (!jl(sale['lines']).any((y) => y['id'] == r.line['sale_line_id']) && r.line['product_id'] == l['product_id'] && r.line['color_id'] == l['color_id']);

({double planned, double cast, double ready})? productionSummary(List<ProdRow>? rows) {
  if (rows == null || rows.isEmpty) return null;
  return (
    planned: rows.fold(0.0, (t, r) => t + n(r.line['pieces'])),
    cast: rows.fold(0.0, (t, r) => t + n(r.progress?['cast_pieces'])),
    ready: rows.fold(0.0, (t, r) => t + n(r.progress?['passed'])),
  );
}
