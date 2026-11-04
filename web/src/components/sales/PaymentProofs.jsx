import { useEffect, useMemo, useState } from 'react';
import { Link } from 'react-router-dom';
import { Upload, FileImage, Receipt } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { orgToday } from '../../lib/inventory';
import { formatMoney, dateText, tableDate } from '../../lib/format';
import Modal from '../Modal';
import ProofPreview from '../ProofPreview';

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

/* Add (or replace) the proof of one payment: a photo/PDF, the SMS text, or both — one step */
export function ProofModal({ payment, sale, proof, money, onClose, onSaved }) {
  const { organization } = useAuth();
  const [file, setFile] = useState(null);
  const [preview, setPreview] = useState('');
  const [text, setText] = useState(proof?.sms_text ?? '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview); }, [preview]);
  function pick(e) {
    const f = e.target.files?.[0]; e.target.value = '';
    if (!f) return;
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
      const { error: err } = await supabase.rpc('submit_payment_proof', { p: { payment_id: payment.id, file_path: path, file_name: file?.name ?? null, sms_text: text.trim() || null } });
      if (err) throw err;
      // a copy kept on this device (2026-11-04, the user): the slip, else the SMS as text
      try {
        const base = `sale-${sale.sale_no}-${payment.paid_on}`;
        const blob = file ?? (text.trim() ? new Blob([text.trim()], { type: 'text/plain' }) : null);
        if (blob) {
          const a = document.createElement('a');
          a.href = URL.createObjectURL(blob);
          a.download = file ? `${base}-${file.name.replace(/[^\w.-]+/g, '_')}` : `${base}-sms.txt`;
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
        <ProofPreview file={file}>
          <div className="pl-help" style={{ flex: 1 }}>{file ? file.name : proof?.file_name ? `Kept: ${proof.file_name}` : 'Bank slip or receipt (photo or PDF)'}</div>
          <label className="btn btn-outline btn-sm"><Upload size={14} /> {file || proof?.file_path ? 'Replace photo' : 'Choose photo or PDF'}
            <input type="file" accept="image/*,application/pdf" hidden onChange={pick} /></label>
        </ProofPreview>
        <label className="pe-field"><span>Or paste the SMS (muamala)</span>
          <textarea className="form-input" rows={4} value={text} onChange={e => setText(e.target.value)} /></label>
      </div>
    </Modal>
  );
}

/* The proof of a payment, seen by everyone responsible (2026-11-04); a director also confirms it or queries it */
export function ReviewModal({ payment, sale, proof, buyer, account, money, canReview = true, onClose, onSaved }) {
  const [url, setUrl] = useState('');
  const [saveUrl, setSaveUrl] = useState('');   // the same file, as a download (kept on the device)
  const [note, setNote] = useState('');
  const [asking, setAsking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => {
    if (!proof?.file_path) return;
    supabase.storage.from('payment-proofs').createSignedUrl(proof.file_path, 600).then(({ data }) => setUrl(data?.signedUrl ?? ''));
    const name = `sale-${sale.sale_no}-${payment.paid_on}-${(proof.file_name || 'proof').replace(/[^\w.-]+/g, '_')}`;
    supabase.storage.from('payment-proofs').createSignedUrl(proof.file_path, 600, { download: name }).then(({ data }) => setSaveUrl(data?.signedUrl ?? ''));
  }, [proof?.file_path]);
  async function act(action) {
    setError('');
    if (action === 'query' && !note.trim()) { setError('Say what is wrong with the proof.'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('review_payment_proof', { p_payment: payment.id, p_action: action, p_note: action === 'query' ? note.trim() : null });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  const isPdf = /\.pdf$/i.test(proof?.file_path ?? '');
  return (
    <Modal title={`Payment proof · ${money(Number(payment.amount))}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        {saveUrl && <a href={saveUrl} className="btn btn-ghost" download>Save to device</a>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Close</button>
        {canReview && (asking ? <button type="button" className={`btn btn-danger${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={() => act('query')}>Send query</button>
          : <button type="button" className="btn btn-outline" onClick={() => setAsking(true)}>Query</button>)}
        {canReview && <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={() => act('confirm')}>Confirm received</button>}</>}>
      <div className="modal-form">
        <p className="pl-help">Sale #{sale.sale_no} · {buyer} · paid {dateText(payment.paid_on)} into {account}{payment.receipt_no ? ` · #${payment.receipt_no}` : ''}</p>
        {proof?.status === 'confirmed' && <p className="text-sm"><span className="badge badge-success">Confirmed</span>{proof.reviewed_at ? ` ${dateText(proof.reviewed_at)}` : ''}</p>}
        {proof?.status === 'queried' && <div className="alert alert-error" role="note">Queried: {proof.note}</div>}
        {proof?.file_path && (isPdf ? <a href={url} target="_blank" rel="noopener noreferrer" className="btn btn-outline btn-sm">Open the PDF</a>
          : url ? <a href={url} target="_blank" rel="noopener noreferrer"><img src={url} alt="Proof of payment" className="pp-photo" /></a> : <span className="skeleton" />)}
        {proof?.sms_text && <pre className="pp-sms">{proof.sms_text}</pre>}
        {asking && <label className="pe-field"><span>What's wrong?</span>
          <input className="form-input" autoFocus value={note} onChange={e => setNote(e.target.value)} placeholder="Amount on the slip is different" /></label>}
      </div>
    </Modal>
  );
}

/*
 * Payments and their proof, one list for both sides: the branch adds proof (reminders first: late,
 * queried, then due); directors confirm what waits. Used on Sales › Receipts and Approvals › Payments.
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
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Proof to add</span><strong className={counts.todo ? 'text-warning' : ''}>{counts.todo}</strong><span className="pl-help">{here.filter(x => x.state === 'late').length} late (over {PROOF_DAYS} days)</span></div>
        <div className="mm-stat"><span className="pl-label">Waiting for a director</span><strong className={counts.waiting ? 'text-warning' : ''}>{counts.waiting}</strong><span className="pl-help">{here.filter(x => x.state === 'overdue').length} overdue (over {CONFIRM_DAYS} days)</span></div>
        <div className="mm-stat"><span className="pl-label">Confirmed</span><strong>{counts.confirmed}</strong><span className="pl-help">of {counts.all} payments</span></div>
      </div>
      <div className="filter-chips" style={{ margin: '8px 0' }}>
        {[['todo', 'Proof to add'], ['waiting', 'Waiting'], ['confirmed', 'Confirmed'], ['all', 'All']].map(([k, l]) => (
          <button key={k} type="button" className={`filter-chip${show === k ? ' is-on' : ''}`} onClick={() => setShow(k)}>{l} ({counts[k]})</button>))}
      </div>
      <div className="card"><div className="table-container">
        <table>
          <thead><tr><th>Date</th><th>Sale</th><th>Account</th><th className="num">Amount (TZS)</th><th>Proof</th><th aria-label="Actions" /></tr></thead>
          <tbody>
            {rows === null ? <tr><td colSpan={6}><span className="skeleton" /></td></tr>
            : shown.length === 0 ? <tr><td colSpan={6} className="text-muted">{show === 'todo' ? 'Every payment has its proof.' : show === 'waiting' ? 'Nothing waits for a director.' : 'Nothing here.'}</td></tr>
            : shown.map(x => {
              const pr = proofs[x.id];
              const canAdd = x.state !== 'confirmed' && canAt('sales.create', x.sale.branch_id, null);
              const canReview = !!pr && x.state !== 'confirmed' && canAt('sales.confirm_payments', x.sale.branch_id, null);
              return (
                <tr key={x.id}>
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
      {adding && <ProofModal payment={adding} sale={adding.sale} proof={proofs[adding.id]} money={money} onClose={() => setAdding(null)} onSaved={async () => { setAdding(null); await load(); }} />}
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
