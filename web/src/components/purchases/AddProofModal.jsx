import { useState } from 'react';
import { supabase } from '../../lib/supabase';
import { files } from '../../lib/files';
import { dbErrorMessage } from '../../lib/masterData';
import { proofName, extOf } from '../../lib/proofName';
import Modal from '../Modal';
import NumberInput from '../NumberInput';
import ProofBox from '../ProofBox';

const num = v => (String(v ?? '').trim() === '' ? null : Number(v));

/* A proof of payment added to a purchase or an expense (134, 2026-11-16, the user): photo, PDF or the SMS */
export default function AddProofModal({ x, organization, today, money, onClose, onSaved }) {
  const [file, setFile] = useState(null);
  const [sms, setSms] = useState('');
  const [paidOn, setPaidOn] = useState(x.paidOn || today);
  const [amount, setAmount] = useState(x.amount > 0 ? String(Math.round(Number(x.amount))) : '');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    setError('');
    if (!file && !sms.trim()) { setError('Add the proof: a photo, a PDF or the SMS.'); return; }
    setBusy(true);
    try {
      let path = null;
      if (file) {
        const ext = (file.name.split('.').pop() || 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '');
        path = `${organization.id}/${x.branch}/procurement/${Date.now()}.${ext}`;
        const up = await files('payment-proofs').upload(path, file, { contentType: file.type || undefined, upsert: false });
        if (up.error) throw up.error;
      }
      const { error: err } = await supabase.rpc('add_procurement_proof', { p: { kind: x.kind, ref_id: x.id, paid_on: paidOn || null, amount: num(amount),
        file_path: path, file_name: file ? proofName({ kind: x.kind === 'purchase' ? 'Paid-Supplier' : 'Paid-Expense', who: x.who, amount: num(amount), date: paidOn }, extOf(file)) : null,
        sms_text: sms.trim() || null } });
      if (err) throw err;
      onSaved();
    } catch (e) { setError(dbErrorMessage(e, "We couldn't keep the proof.")); } finally { setBusy(false); }
  }
  return (
    <Modal title={`Proof of payment · ${x.who ?? ''}`} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Keep the proof</button></>}>
      <div className="modal-form">
        <div className="form-row">
          <label className="pe-field"><span>Paid on</span><input type="date" className="form-input" max={today} value={paidOn} onChange={e => setPaidOn(e.target.value)} /></label>
          <label className="pe-field"><span>Amount (optional)</span><NumberInput className="form-input" min="0" value={amount} onChange={e => setAmount(e.target.value)} /></label>
        </div>
        <ProofBox file={file} onFile={f => setFile(f && f.size > 10 * 1024 * 1024 ? file : f)} text={sms} onText={setSms} />
      </div>
    </Modal>
  );
}
