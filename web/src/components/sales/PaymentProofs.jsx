import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Upload, FileImage, FileText, MessageSquare, Receipt } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { orgToday } from '../../lib/inventory';
import { formatMoney, formatAmount, dateText, tableDate } from '../../lib/format';
import Modal from '../Modal';
import ProofBox from '../ProofBox';
import { proofName, extOf } from '../../lib/proofName';
import { SlipCanvas, markedSlipBlob, READY_MARK } from './SlipMark';

/*
 * Proof of payment (105, 2026-11-03, the user): instead of the WhatsApp group,
 * each sale payment gets its proof in MOIS — a photo or PDF and/or the
 * transaction SMS — within 2 days of the payment; a director confirms it, or
 * queries it with a note, within 3 days of the payment. A sale is fully
 * approved when it is fully paid and every payment is confirmed.
 */
export const PROOF_DAYS = 2;     // to add the proof, from the payment date
export const CONFIRM_DAYS = 3;   // to confirm it, from the payment date
const daysSince = (d, today) => Math.round((new Date(`${today}T00:00:00Z`) - new Date(`${d}T00:00:00Z`)) / 864e5);

/** none | late | waiting | overdue | queried | confirmed */
export function proofState(payment, proof, today) {
  if (!proof) return daysSince(payment.paid_on, today) > PROOF_DAYS ? 'late' : 'none';
  if (proof.status === 'confirmed') return 'confirmed';
  if (proof.status === 'queried') return 'queried';
  return daysSince(payment.paid_on, today) > CONFIRM_DAYS ? 'overdue' : 'waiting';
}
export const PROOF_BADGE = {
  none: ['No proof yet', 'badge-neutral'], late: ['Proof late', 'badge-error'],
  waiting: ['Waiting for a director', 'badge-warning'], overdue: ['Confirmation overdue', 'badge-error'],
  queried: ['Queried', 'badge-error'], confirmed: ['Confirmed', 'badge-success'],
};
export const ProofBadge = ({ state }) => <span className={`badge ${PROOF_BADGE[state][1]}`}>{PROOF_BADGE[state][0]}</span>;

/** A sale's approval: 'approved' when fully paid and every payment confirmed; else what's missing */
export function saleApproval(sale, proofs, today) {
  const pays = sale.payments || [];
  const paid = pays.reduce((t, p) => t + Number(p.amount), 0);
  const states = pays.map(p => proofState(p, proofs[p.id], today));
  const toAdd = states.filter(s => s === 'none' || s === 'late' || s === 'queried').length;
  const waiting = states.filter(s => s === 'waiting' || s === 'overdue').length;
  if (pays.length && !toAdd && !waiting && paid + 0.01 >= Number(sale.total)) return { state: 'approved', label: '100% approved', badge: 'badge-success' };
  if (toAdd) return { state: 'proof', label: `${toAdd} proof${toAdd === 1 ? '' : 's'} to add`, badge: states.some(s => s === 'late' || s === 'queried') ? 'badge-error' : 'badge-warning' };
  if (waiting) return { state: 'waiting', label: 'Waiting for a director', badge: states.includes('overdue') ? 'badge-error' : 'badge-warning' };
  return { state: 'owed', label: pays.length ? 'Part paid' : 'Not paid', badge: 'badge-neutral' };
}

/** The proofs of the organization's payments, by payment id ({} before 105) */
export async function loadProofs() {
  const { data, error } = await supabase.from('sale_payment_proofs').select('*');
  return error ? {} : Object.fromEntries((data || []).map(x => [x.payment_id, x]));
}

/*
 * Proofs given while recording a sale (2026-11-08, the user): once the sale is saved, each
 * payment that came with a photo or SMS gets it posted, matched by account and amount.
 * proofs: [{ accountId, amount, file, text }]. Returns how many could not be posted.
 */
export async function postSaleProofs(saleId, proofs, { organizationId, buyer }) {
  const want = (proofs || []).filter(x => x && (x.file || x.text?.trim()));
  if (!want.length) return 0;
  const { data: s } = await supabase.from('sales').select('id, sale_no, branch_id, payments:sale_payments(id, account_id, amount, paid_on)').eq('id', saleId).single();
  if (!s) return want.length;
  const free = [...(s.payments || [])];
  let failed = 0;
  for (const x of want) {
    const i = free.findIndex(p => (p.account_id ?? '') === (x.accountId || '') && Math.abs(Number(p.amount) - Number(x.amount)) < 0.01);
    if (i < 0) { failed += 1; continue; }
    const pay = free.splice(i, 1)[0];
    try {
      let path = null;
      if (x.file) {
        const ext = (x.file.name.split('.').pop() || 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '');
        path = `${organizationId}/${s.branch_id}/${pay.id}/${Date.now()}.${ext}`;
        const up = await supabase.storage.from('payment-proofs').upload(path, x.file, { contentType: x.file.type || undefined, upsert: false });
        if (up.error) throw up.error;
      }
      const name = x.file ? proofName({ kind: `Sale-${s.sale_no}`, who: buyer || 'Walk-in', amount: pay.amount, date: pay.paid_on }, extOf(x.file)) : null;
      const { error } = await supabase.rpc('submit_payment_proof', { p: { payment_id: pay.id, file_path: path, file_name: name, sms_text: x.text?.trim() || null } });
      if (error) throw error;
    } catch (e) { console.error(e); failed += 1; }
  }
  return failed;
}

/*
 * One slip for several sales (2026-11-08, the user): cash paid at the office and banked together.
 * The file is uploaded once and every payment it covers points to it, so a slip is "shared" when
 * its file (or, for an SMS, its text) is the same. payments: [{ id, amount, paid_on, sale: { sale_no, branch_id } }]
 */
export async function postSharedSlip(payments, slip, { organizationId, who }) {
  const ps = (payments || []).filter(Boolean);
  if (!ps.length || !(slip?.file || slip?.text?.trim())) return ps.length;
  const total = ps.reduce((t, p) => t + Number(p.amount), 0);
  const nos = [...new Set(ps.map(p => p.sale.sale_no))].sort((a, b) => a - b);
  let path = null;
  try {
    if (slip.file) {
      const ext = (slip.file.name.split('.').pop() || 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '');
      path = `${organizationId}/${ps[0].sale.branch_id}/shared-${Date.now()}/${Date.now()}.${ext}`;
      const up = await supabase.storage.from('payment-proofs').upload(path, slip.file, { contentType: slip.file.type || undefined, upsert: false });
      if (up.error) throw up.error;
    }
  } catch (e) { console.error(e); return ps.length; }
  const name = slip.file ? proofName({ kind: `Sales-${nos.join('-')}`, who, amount: total, date: ps[0].paid_on }, extOf(slip.file)) : null;
  let failed = 0;
  for (const p of ps) {
    const { error } = await supabase.rpc('submit_payment_proof', { p: { payment_id: p.id, file_path: path, file_name: name, sms_text: slip.text?.trim() || null } });
    if (error) { console.error(error); failed += 1; }
  }
  return failed;
}

/* The other payments a slip also covers (same file, or same SMS when there is no file) */
export async function loadSlipSiblings(proof) {
  if (!proof?.file_path && !proof?.sms_text) return [];
  let q = supabase.from('sale_payment_proofs').select('id, payment_id, status, payment:sale_payments!inner(id, amount, paid_on, sale:sales!inner(id, sale_no, walk_in_name, customer:customers(name)))').neq('id', proof.id);
  q = proof.file_path ? q.eq('file_path', proof.file_path) : q.is('file_path', null).eq('sms_text', proof.sms_text);
  const { data } = await q;
  return data || [];
}

/* The proof/slip for several payments: the same box, posted when added */
function SlipWindow({ amount, money, note, onClose, onDone }) {
  const [file, setFile] = useState(null);
  const [text, setText] = useState('');
  const [error, setError] = useState('');
  return (
    <Modal title={`Proof of payment · ${money(amount)}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className="btn btn-primary" onClick={() => { if (!file && !text.trim()) { setError('Add the photo or paste the SMS.'); return; } onDone({ file, text }); }}>Post proof</button></>}>
      <div className="modal-form">
        <p className="pl-help">{note}</p>
        <ProofBox file={file} onFile={f => { if (f && f.size > 10 * 1024 * 1024) { setError('That file is over 10 MB. Take the photo again at a smaller size.'); return; } setError(''); setFile(f); }} text={text} onText={setText} />
      </div>
    </Modal>
  );
}

/* Add (or replace) the proof of one payment: a photo/PDF, the SMS text, or both — one step */
export function ProofModal({ payment, sale, proof, buyer, money, onClose, onSaved }) {
  // the file is named after its transaction (2026-11-06)
  const nameOf = ext => proofName({ kind: `Sale-${sale.sale_no}`, who: buyer ?? sale.customer?.name ?? sale.walk_in_name ?? 'Walk-in', amount: payment.amount, date: payment.paid_on }, ext);
  const { organization } = useAuth();
  const [file, setFile] = useState(null);
  const [preview, setPreview] = useState('');
  const [text, setText] = useState(proof?.sms_text ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview); }, [preview]);
  function pick(e) {
    const f = e.target.files?.[0]; e.target.value = '';
    if (!f) { setFile(null); return; }   // removed in the proof box
    if (f.size > 10 * 1024 * 1024) { setError('That file is over 10 MB. Take the photo again at a smaller size.'); return; }
    setError(''); setFile(f); setPreview(f.type.startsWith('image/') ? URL.createObjectURL(f) : '');
  }
  async function save() {
    setError('');
    if (!file && !text.trim() && !proof?.file_path) { setError('Add the photo or paste the SMS.'); return; }
    setBusy(true);
    try {
      let path = null;
      if (file) {
        const ext = (file.name.split('.').pop() || 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '');
        path = `${organization.id}/${sale.branch_id}/${payment.id}/${Date.now()}.${ext}`;
        const up = await supabase.storage.from('payment-proofs').upload(path, file, { contentType: file.type || undefined, upsert: false });
        if (up.error) throw up.error;
      }
      const { error: err } = await supabase.rpc('submit_payment_proof', { p: { payment_id: payment.id, file_path: path, file_name: file ? nameOf(extOf(file)) : null, sms_text: text.trim() || null } });
      if (err) throw err;
      // a copy kept on this device (2026-11-04, the user): the slip, else the SMS as text
      try {
        const blob = file ?? (text.trim() ? new Blob([text.trim()], { type: 'text/plain' }) : null);
        if (blob) {
          const a = document.createElement('a');
          a.href = URL.createObjectURL(blob);
          a.download = nameOf(file ? extOf(file) : 'txt');
          document.body.appendChild(a); a.click(); a.remove();
          setTimeout(() => URL.revokeObjectURL(a.href), 4000);
        }
      } catch { /* the proof is posted; the copy is a convenience */ }
      onSaved();
    } catch (e) {
      setError(dbErrorMessage(e, "We couldn't send the proof. Please try again."));
    } finally { setBusy(false); }
  }
  return (
    <Modal title={`Proof of payment · ${money(Number(payment.amount))}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Post proof</button></>}>
      <div className="modal-form">
        <p className="pl-help">Sale #{sale.sale_no} · paid {dateText(payment.paid_on)}{payment.receipt_no ? ` · #${payment.receipt_no}` : ''}</p>
        {proof?.status === 'queried' && <div className="alert alert-error" role="note">A director asked: {proof.note}</div>}
        <ProofBox file={file} onFile={f => pick({ target: { files: f ? [f] : [], value: '' } })} text={text} onText={setText} keptName={proof?.file_name} />
      </div>
    </Modal>
  );
}

/* The proof of a payment, seen by everyone responsible (2026-11-04); a director also confirms it or queries it */
/*
 * The director's mark (2026-11-06, the user): two boxes beside the slip — green ✓
 * received, red ✗ query, stamped with the director's initials and the time.
 * On a photo slip (109) the boxes pick the pen and the director draws the tick
 * or cross on the slip itself, as on WhatsApp before; a PDF or SMS is marked
 * with a tap on the box.
 */
const initialsOf = p => (p ? ([p.first_name, p.last_name].filter(Boolean).map(w => w[0]).join('') || (p.email || '?')[0]).toUpperCase() : '');
const stampTime = t => new Date(t).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
function MarkBox({ kind, stamp, disabled, picked, draw, onTap }) {
  const ok = kind === 'confirm';
  return (
    <div className="pp-mark-wrap">
      <button type="button" className={`pp-mark pp-mark-${ok ? 'ok' : 'no'}${stamp || picked ? ' is-on' : ''}`} disabled={disabled} aria-pressed={draw ? !!picked : undefined}
        title={draw ? (ok ? 'Then draw a tick on the slip' : 'Then draw a cross on the slip') : ok ? 'Tap to confirm the money was received' : 'Tap to query this slip'} onClick={onTap}>
        {!stamp && picked && <span className="pp-mark-sign">{ok ? '✓' : '✗'}</span>}
        {stamp && <><span className="pp-mark-sign">{ok ? '✓' : '✗'}</span><span className="pp-mark-who">{stamp.who}</span><span className="pp-mark-at">{stamp.at}</span></>}
      </button>
      <span className="pl-help">{ok ? 'Received' : 'Query'}</span>
    </div>
  );
}

export function ReviewModal({ payment, sale, proof, buyer, account, money, canReview = true, onClose, onSaved }) {
  const { profile } = useAuth();
  const [stamp, setStamp] = useState(null);   // { kind, who, at }
  const [pen, setPen] = useState(null);       // green | red: drawing on the photo slip
  const [strokes, setStrokes] = useState(proof?.mark?.strokes ?? []);
  const [ready, setReady] = useState(false);   // the box's ready mark is on the slip; drawing replaces it
  useEffect(() => {
    if (!proof?.reviewed_by || proof.status === 'waiting') return;
    supabase.from('profiles').select('id, first_name, last_name, email').eq('id', proof.reviewed_by).maybeSingle()
      .then(({ data }) => setStamp({ kind: proof.status === 'confirmed' ? 'confirm' : 'query', who: initialsOf(data), at: proof.reviewed_at ? stampTime(proof.reviewed_at) : '' }));
  }, [proof?.id, proof?.status]); // eslint-disable-line react-hooks/exhaustive-deps
  const [url, setUrl] = useState('');
  const [siblings, setSiblings] = useState([]);   // other sales the same slip covers
  const [sharedLines, setSharedLines] = useState({});   // sale id → its items, for a shared slip
  useEffect(() => {
    if (!siblings.length) return;
    const ids = [sale.id, ...siblings.map(x => x.payment.sale.id)].filter(Boolean);
    supabase.from('sale_lines').select('sale_id, line_no, item_name, quantity, product:products(canonical_name)').in('sale_id', ids).order('line_no')
      .then(({ data }) => { const m = {}; for (const l of data || []) (m[l.sale_id] ||= []).push(l); setSharedLines(m); });
  }, [siblings]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { loadSlipSiblings(proof).then(setSiblings); }, [proof?.id]); // eslint-disable-line react-hooks/exhaustive-deps
  const [saveUrl, setSaveUrl] = useState('');   // the same file, as a download (kept on the device)
  const [note, setNote] = useState('');
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => {
    if (!proof?.file_path) return;
    supabase.storage.from('payment-proofs').createSignedUrl(proof.file_path, 600).then(({ data }) => setUrl(data?.signedUrl ?? ''));
    const name = proof.file_name || proofName({ kind: `Sale-${sale.sale_no}`, who: buyer, amount: payment.amount, date: payment.paid_on }, 'jpg');
    supabase.storage.from('payment-proofs').createSignedUrl(proof.file_path, 600, { download: name }).then(({ data }) => setSaveUrl(data?.signedUrl ?? ''));
  }, [proof?.file_path]);
  const isPdf = /\.pdf$/i.test(proof?.file_path ?? '');
  const isPhoto = !!proof?.file_path && !isPdf;
  async function act(action) {
    setError('');
    if (isPhoto && !strokes.length) { setError('Draw your mark on the slip first.'); return; }
    if (action === 'query' && !note.trim()) { setError('Say what is wrong with the proof.'); return; }
    setBusy(true);
    // a shared slip: the mark goes on every payment it covers
    const ids = [payment.id, ...siblings.filter(x => x.status !== 'confirmed').map(x => x.payment_id)];
    let err = null;
    for (const id of ids) {
      const r = await supabase.rpc('review_payment_proof', { p_payment: id, p_action: action, p_note: action === 'query' ? note.trim() : null,
        p_mark: isPhoto ? { strokes } : null });
      if (r.error) { err = r.error; break; }
    }
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    // the stamp shows a moment before the window closes
    setStamp({ kind: action, who: initialsOf(profile), at: stampTime(Date.now()) });
    setPen(null);
    setTimeout(onSaved, 1500);
  }
  const open = canReview && !stamp && !busy;
  const markColor = pen || proof?.mark?.color || (stamp?.kind === 'query' ? 'red' : 'green');
  // keep the marked slip: the photo with the tick and stamp drawn in
  async function saveMarked(e) {
    if (!isPhoto || !strokes.length || !stamp || !url) return;
    e.preventDefault();
    try {
      const blob = await markedSlipBlob(url, { color: markColor, strokes }, `${stamp.who} · ${stamp.at}`);
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = (proof.file_name || 'slip.jpg').replace(/\.[^.]+$/, '') + '_marked.png';
      a.click();
      setTimeout(() => URL.revokeObjectURL(a.href), 5000);
    } catch { window.location.href = saveUrl; }
  }
  const pick = kind => {
    setError('');
    if (!isPhoto) { if (kind === 'confirm') act('confirm'); else setAsking(true); return; }
    const c = kind === 'confirm' ? 'green' : 'red';
    // the box decides: ticking it puts its mark on the slip, over anything drawn (2026-11-06, the user).
    // MOIS never reads the drawn shape — the decision is always the box ticked.
    setStrokes(READY_MARK[c]); setReady(true);
    setPen(c);
    setAsking(kind === 'query');
  };
  return (
    <Modal title={`Payment proof · ${money(siblings.length ? siblings.reduce((t, x) => t + Number(x.payment.amount), Number(payment.amount)) : Number(payment.amount))}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        {saveUrl && <a href={saveUrl} className="btn btn-ghost" download onClick={saveMarked}>Save to device</a>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button>
        {pen && !stamp && strokes.length > 0 && <button type="button" className="btn btn-ghost" onClick={() => { setStrokes([]); setReady(false); }}>Clear</button>}
        {pen === 'green' && !stamp && <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !strokes.length} onClick={() => act('confirm')}>Sign as received</button>}
        {asking && !stamp && <button type="button" className={`btn btn-danger${busy ? ' btn-loading' : ''}`} disabled={busy || (isPhoto && !strokes.length)} onClick={() => act('query')}>Send query</button>}</>}>
      <div className="modal-form">
        <p className="pl-help">{siblings.length ? '' : `Sale #${sale.sale_no} · ${buyer} · `}paid {dateText(payment.paid_on)} into {account}{payment.receipt_no ? ` · #${payment.receipt_no}` : ''}</p>
        {siblings.length > 0 && (
          <div className="pp-shared" role="note">
            <strong>One slip for {siblings.length + 1} sales</strong>
            <table className="pp-shared-table">
              <thead><tr><th>Name</th><th>Items</th><th className="num">Qty</th><th className="num">Amount (TZS)</th></tr></thead>
              <tbody>
                {[{ key: 'me', no: sale.sale_no, id: sale.id, who: buyer, amount: Number(payment.amount), done: false },
                  ...siblings.map(x => ({ key: x.id, no: x.payment.sale.sale_no, id: x.payment.sale.id, who: x.payment.sale.customer?.name ?? x.payment.sale.walk_in_name ?? 'Walk-in', amount: Number(x.payment.amount), done: x.status === 'confirmed' }))]
                  .sort((p, q) => p.no - q.no).map(r => {
                    const ls = sharedLines[r.id] || [];
                    return (
                      <tr key={r.key}>
                        <td><strong>{r.who}</strong><div className="pl-help">#{r.no}{r.done ? ' · confirmed' : ''}</div></td>
                        <td>{ls.length ? ls.map(l => <div key={l.line_no}>{l.product?.canonical_name ?? l.item_name}</div>) : '…'}</td>
                        <td className="num">{ls.map(l => <div key={l.line_no}>{l.product ? Number(l.quantity).toLocaleString('en-US') : '—'}</div>)}</td>
                        <td className="num">{formatAmount(r.amount)}</td>
                      </tr>
                    );
                  })}
              </tbody>
              <tfoot><tr><td colSpan={3}><strong>Total</strong></td><td className="num"><strong>{money(siblings.reduce((t, x) => t + Number(x.payment.amount), Number(payment.amount)))}</strong></td></tr></tfoot>
            </table>
            <span className="pl-help">Your mark applies to all of them.</span>
          </div>
        )}
        {proof?.status === 'queried' && <div className="alert alert-error" role="note">Queried: {proof.note}</div>}
        <div className="pp-review">
          <div className="pp-review-slip">
            {proof?.file_path && (isPdf ? <a href={url} target="_blank" rel="noopener noreferrer" className="btn btn-outline btn-sm">Open the PDF</a>
              : url ? <SlipCanvas url={url} strokes={strokes} color={markColor} pen={open && isPhoto ? pen || 'ink' : null} onStrokes={v => { setStrokes(v); setReady(false); }} replaceOnDraw={ready} stamp={strokes.length ? stamp : null} /> : <span className="skeleton" />)}
            {open && isPhoto && <span className="pl-help">{!pen ? (strokes.length ? 'Now tick ✓ Received or ✗ Query: the box decides.' : 'Tick ✓ or ✗ in a box. You may also sign on the slip with your finger.') : ready ? 'Or draw over it with your finger to sign in your own hand.' : 'Clear to start again.'}</span>}
            {proof?.sms_text && <pre className="pp-sms">{proof.sms_text}</pre>}
          </div>
          {(canReview || stamp) && (
            <div className="pp-marks">
              <MarkBox kind="confirm" stamp={stamp?.kind === 'confirm' ? stamp : null} disabled={!open} draw={isPhoto} picked={pen === 'green'} onTap={() => pick('confirm')} />
              <MarkBox kind="query" stamp={stamp?.kind === 'query' ? stamp : null} disabled={!open} draw={isPhoto} picked={pen === 'red'} onTap={() => pick('query')} />
            </div>
          )}
        </div>
        {asking && <label className="pe-field"><span>What's wrong?</span>
          <input className="form-input" autoFocus value={note} onChange={e => setNote(e.target.value)} placeholder="Amount on the slip is different" /></label>}
      </div>
    </Modal>
  );
}

/*
 * Payments and their proof, one list for both sides: the branch adds proof (reminders first: late,
 * queried, then due); directors confirm what waits. Used on Sales › Slips and Approvals › Payments.
 * On "Proof to add", one proof/slip can cover several payments: Add proof/slip, tick them, add it once (2026-11-08).
 */
export function PaymentProofsList({ branchId, inBranch, directorView = false }) {
  const { organization, canAt } = useAuth();
  const today = orgToday(organization?.timezone);
  const money = v => formatMoney(v, organization?.currency_code);
  const [rows, setRows] = useState(null);
  const [proofs, setProofs] = useState({});
  const [accounts, setAccounts] = useState({});
  const [show, setShow] = useState(directorView ? 'waiting' : 'todo');   // todo | waiting | confirmed | all
  const [adding, setAdding] = useState(null);
  const [reviewing, setReviewing] = useState(null);
  const [choosing, setChoosing] = useState(false);
  const [sel, setSel] = useState(() => new Set());
  const [slipOpen, setSlipOpen] = useState(false);
  const [posting, setPosting] = useState(false);
  async function load() {
    const [p, pr, ac] = await Promise.all([
      supabase.from('sale_payments').select('id, sale_id, paid_on, amount, method, receipt_no, account_id, created_at, sale:sales!inner(id, sale_no, branch_id, stage, customer_id, walk_in_name, total, customer:customers(name))')
        .order('paid_on', { ascending: false }).limit(500),
      loadProofs(),
      supabase.from('payment_accounts').select('id, name'),
    ]);
    setRows((p.data || []).filter(x => x.sale.stage !== 'cancelled'));
    setProofs(pr);
    setAccounts(Object.fromEntries((ac.data || []).map(a => [a.id, a.name])));
  }
  useEffect(() => { load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  const here = useMemo(() => (rows || []).filter(x => inBranch(x.sale.branch_id)).map(x => ({ ...x, state: proofState(x, proofs[x.id], today) })), [rows, proofs, branchId, today]); // eslint-disable-line react-hooks/exhaustive-deps
  const TODO = ['late', 'queried', 'none'];
  const counts = { todo: here.filter(x => TODO.includes(x.state)).length, waiting: here.filter(x => x.state === 'waiting' || x.state === 'overdue').length, confirmed: here.filter(x => x.state === 'confirmed').length, all: here.length };
  const order = { late: 0, queried: 1, overdue: 2, none: 3, waiting: 4, confirmed: 5 };
  const shown = here.filter(x => show === 'all' || (show === 'todo' ? TODO.includes(x.state) : show === 'waiting' ? x.state === 'waiting' || x.state === 'overdue' : x.state === 'confirmed'))
    .sort((a, b) => (show === 'all' || show === 'confirmed' ? 0 : order[a.state] - order[b.state]) || b.paid_on.localeCompare(a.paid_on));
  const buyer = x => x.sale.customer?.name ?? x.sale.walk_in_name ?? 'Walk-in';
  const accName = x => accounts[x.account_id] ?? ({ cash: 'Cash', mobile_money: 'Mobile money', bank: 'Bank' }[x.method]);
  const canAddAny = show === 'todo' && shown.some(x => canAt('sales.create', x.sale.branch_id, null));
  const selRows = here.filter(x => sel.has(x.id));
  const selTotal = selRows.reduce((t, x) => t + Number(x.amount), 0);
  async function postOne(slip) {
    setSlipOpen(false); setPosting(true);
    const names = [...new Set(selRows.map(buyer))];
    const failed = await postSharedSlip(selRows.map(x => ({ id: x.id, amount: x.amount, paid_on: x.paid_on, sale: { sale_no: x.sale.sale_no, branch_id: x.sale.branch_id } })), slip,
      { organizationId: organization.id, who: names.length > 2 ? `${names[0]}-and-${names.length - 1}-more` : names.join('-') });
    setPosting(false); setSel(new Set()); setChoosing(false);
    if (failed) window.alert(`${failed} of the payments could not take the slip. Try again.`);
    await load();
  }
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Proof to add</span><strong className={counts.todo ? 'text-warning' : ''}>{counts.todo}</strong><span className="pl-help">{here.filter(x => x.state === 'late').length} late (over {PROOF_DAYS} days)</span></div>
        <div className="mm-stat"><span className="pl-label">Waiting for a director</span><strong className={counts.waiting ? 'text-warning' : ''}>{counts.waiting}</strong><span className="pl-help">{here.filter(x => x.state === 'overdue').length} overdue (over {CONFIRM_DAYS} days)</span></div>
        <div className="mm-stat"><span className="pl-label">Confirmed</span><strong>{counts.confirmed}</strong><span className="pl-help">of {counts.all} payments</span></div>
      </div>
      <div className="filter-chips" style={{ margin: '8px 0' }}>
        {[['todo', 'Proof to add'], ['waiting', 'Waiting'], ['confirmed', 'Confirmed'], ['all', 'All']].map(([k, l]) => (
          <button key={k} type="button" className={`filter-chip${show === k ? ' is-on' : ''}`} onClick={() => { setShow(k); setChoosing(false); setSel(new Set()); }}>{l} ({counts[k]})</button>))}
        {canAddAny && !choosing && <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} onClick={() => { setSel(new Set()); setChoosing(true); }}><Receipt size={13} /> Add proof/slip for several</button>}
      </div>
      {choosing && (
        <div className="sl-sel-bar">
          <span>{sel.size ? <><strong>{sel.size}</strong> ticked · {money(selTotal)}</> : 'Tick the payments this proof/slip is for.'}</span>
          <button type="button" className={`btn btn-primary btn-sm${posting ? ' btn-loading' : ''}`} disabled={!sel.size || posting} onClick={() => setSlipOpen(true)}>Add the proof/slip</button>
          <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setSel(new Set()); setChoosing(false); }}>Cancel</button>
        </div>
      )}
      {slipOpen && <SlipWindow amount={selTotal} money={money} note={`One slip for ${selRows.map(x => `#${x.sale.sale_no} ${buyer(x)}`).join(', ')}.`} onClose={() => setSlipOpen(false)} onDone={postOne} />}
      <div className="card"><div className="table-container">
        <table>
          <thead><tr>{choosing && <th aria-label="Tick" style={{ width: 32 }} />}<th>Date</th><th>Sale</th><th>Account</th><th className="num">Amount (TZS)</th><th>Proof</th><th aria-label="Actions" /></tr></thead>
          <tbody>
            {rows === null ? <tr><td colSpan={choosing ? 7 : 6}><span className="skeleton" /></td></tr>
            : shown.length === 0 ? <tr><td colSpan={choosing ? 7 : 6} className="text-muted">{show === 'todo' ? 'Every payment has its proof.' : show === 'waiting' ? 'Nothing waits for a director.' : 'Nothing here.'}</td></tr>
            : shown.map(x => {
              const pr = proofs[x.id];
              const canAdd = x.state !== 'confirmed' && canAt('sales.create', x.sale.branch_id, null);
              const canReview = !!pr && x.state !== 'confirmed' && canAt('sales.confirm_payments', x.sale.branch_id, null);
              return (
                <tr key={x.id}>
                  {choosing && <td>{canAdd && <input type="checkbox" aria-label={`Tick sale ${x.sale.sale_no}`} checked={sel.has(x.id)}
                    onChange={e => setSel(sl => { const n = new Set(sl); if (e.target.checked) n.add(x.id); else n.delete(x.id); return n; })} />}</td>}
                  <td>{tableDate(x.paid_on)}</td>
                  <td><Link to={`/sales?tab=book&sale=${x.sale.id}`}>#{x.sale.sale_no}</Link> · {buyer(x)}{x.receipt_no ? <div className="pl-help">receipt {x.receipt_no}</div> : null}</td>
                  <td>{accName(x)}</td>
                  <td className="num">{Number(x.amount).toLocaleString('en-US')}</td>
                  <td><ProofBadge state={x.state} />{pr?.status === 'queried' && <div className="pl-help text-error">{pr.note}</div>}
                    {pr && <div className="pl-help">{[pr.file_path && 'photo', pr.sms_text && 'SMS'].filter(Boolean).join(' + ')}</div>}</td>
                  <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                    {canReview ? <button type="button" className="btn btn-primary btn-sm" onClick={() => setReviewing(x)}>Check</button>
                      : pr && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setReviewing(x)}>View</button>}
                    {canAdd && <button type="button" className="btn btn-outline btn-sm" onClick={() => setAdding(x)}><Receipt size={13} /> {pr ? 'Replace proof' : 'Add proof'}</button>}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div></div>
      {adding && <ProofModal payment={adding} sale={adding.sale} proof={proofs[adding.id]} buyer={buyer(adding)} money={money} onClose={() => setAdding(null)} onSaved={async () => { setAdding(null); await load(); }} />}
      {reviewing && <ReviewModal payment={reviewing} sale={reviewing.sale} proof={proofs[reviewing.id]} buyer={buyer(reviewing)} account={accName(reviewing)} money={money}
        canReview={proofs[reviewing.id]?.status !== 'confirmed' && canAt('sales.confirm_payments', reviewing.sale.branch_id, null)}
        onClose={() => setReviewing(null)} onSaved={async () => { setReviewing(null); await load(); }} />}
    </>
  );
}

/* The reminder on the dashboard for those who add proof: payments without it (late ones first) */
export function ProofReminder({ branchId, inBranch }) {
  const { organization, canAt } = useAuth();
  const today = orgToday(organization?.timezone);
  const [n, setN] = useState(null);
  const can = !!branchId && canAt('sales.create', branchId, null) && !canAt('sales.confirm_payments', branchId, null);
  useEffect(() => {
    if (!can) return;
    Promise.all([
      supabase.from('sale_payments').select('id, paid_on, sale:sales!inner(branch_id, stage)').order('paid_on', { ascending: false }).limit(500),
      loadProofs(),
    ]).then(([p, pr]) => {
      const mine = (p.data || []).filter(x => x.sale.stage !== 'cancelled' && inBranch(x.sale.branch_id)).map(x => proofState(x, pr[x.id], today));
      setN({ todo: mine.filter(s => s === 'none' || s === 'late' || s === 'queried').length, late: mine.filter(s => s === 'late' || s === 'queried').length });
    });
  }, [branchId, can]); // eslint-disable-line react-hooks/exhaustive-deps
  if (!can || !n || !n.todo) return null;
  return (
    <div className={`alert ${n.late ? 'alert-error' : 'alert-warning'} pp-reminder`} role="note">
      <Receipt size={16} aria-hidden="true" />
      <span><strong>{n.todo} payment{n.todo === 1 ? '' : 's'} need proof</strong>{n.late ? ` · ${n.late} late` : ''}</span>
      <Link to="/sales?tab=receipts" className="btn btn-outline btn-sm">Add proof</Link>
    </div>
  );
}

/*
 * The slips waiting for a director, each on its own line in the Director view's
 * "Needs you now" (2026-11-06, the user): thumbnail, sale, buyer, amount, date —
 * Check opens the slip to confirm or query it there.
 */
function SlipThumb({ proof }) {
  const [url, setUrl] = useState('');
  const isPdf = /\.pdf$/i.test(proof.file_path ?? '');
  useEffect(() => {
    if (!proof.file_path || isPdf) return;
    supabase.storage.from('payment-proofs').createSignedUrl(proof.file_path, 600).then(({ data }) => setUrl(data?.signedUrl ?? ''));
  }, [proof.file_path]); // eslint-disable-line react-hooks/exhaustive-deps
  return (
    <span className="ru-thumb" aria-hidden="true">
      {url ? <img src={url} alt="" /> : isPdf ? <><FileText size={18} /><span className="ru-thumb-tag">PDF</span></> : proof.file_path ? <FileImage size={18} /> : <MessageSquare size={18} />}
    </span>
  );
}

export function WaitingSlips({ inBranch, onChanged }) {
  const { organization, canAt } = useAuth();
  const today = orgToday(organization?.timezone);
  const money = v => formatMoney(v, organization?.currency_code);
  const [rows, setRows] = useState(null);
  const [accounts, setAccounts] = useState({});
  const [reviewing, setReviewing] = useState(null);
  async function load() {
    const [pr, ac] = await Promise.all([
      supabase.from('sale_payment_proofs').select('*, payment:sale_payments!inner(id, paid_on, amount, method, receipt_no, account_id, sale:sales!inner(id, sale_no, branch_id, walk_in_name, customer:customers(name)))').eq('status', 'waiting'),
      supabase.from('payment_accounts').select('id, name'),
    ]);
    // a shared slip shows once, for all the sales it covers
    const groups = {};
    for (const x of (pr.data || []).filter(y => inBranch(y.branch_id))) {
      const k = x.file_path || `sms:${x.sms_text}`;
      (groups[k] ||= []).push(x);
    }
    setRows(Object.values(groups).map(g => ({ ...g[0], group: g })).sort((a, b) => b.payment.paid_on.localeCompare(a.payment.paid_on)));
    setAccounts(Object.fromEntries((ac.data || []).map(a => [a.id, a.name])));
  }
  useEffect(() => { load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  if (!rows?.length) return null;
  const buyer = x => x.payment.sale.customer?.name ?? x.payment.sale.walk_in_name ?? 'Walk-in';
  const accName = x => accounts[x.payment.account_id] ?? ({ cash: 'Cash', mobile_money: 'Mobile money', bank: 'Bank' }[x.payment.method]);
  return (
    <div className="dd-slips">
      {rows.map(x => {
        const late = proofState(x.payment, x, today) === 'overdue';
        return (
          <button key={x.id} type="button" className="dd-slip" onClick={() => setReviewing(x)}>
            <SlipThumb proof={x} />
            {x.group.length > 1
              ? <span className="dd-slip-text"><strong>Sales {x.group.map(g => `#${g.payment.sale.sale_no}`).join(', ')} · one slip</strong>
                <span className="pl-help">{money(x.group.reduce((t, g) => t + Number(g.payment.amount), 0))} · {x.group.map(buyer).join(', ')} · {dateText(x.payment.paid_on)}{late ? <span className="text-warning"> · overdue</span> : null}</span></span>
              : <span className="dd-slip-text"><strong>Sale #{x.payment.sale.sale_no} · {buyer(x)}</strong>
                <span className="pl-help">{money(Number(x.payment.amount))} · {dateText(x.payment.paid_on)}{late ? <span className="text-warning"> · overdue</span> : null}</span></span>}
            <span className="btn btn-primary btn-sm">Check</span>
          </button>
        );
      })}
      {reviewing && <ReviewModal payment={reviewing.payment} sale={reviewing.payment.sale} proof={reviewing} buyer={buyer(reviewing)} account={accName(reviewing)} money={money}
        canReview={canAt('sales.confirm_payments', reviewing.branch_id, null)}
        onClose={() => setReviewing(null)} onSaved={async () => { setReviewing(null); await load(); onChanged?.(); }} />}
    </div>
  );
}
