import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';

/**
 * The company's details printed on documents (066): TIN, VRN, address,
 * phone, email, how to pay, the footer — org admins. The legal name and the
 * logo stay with the Technical admin (034).
 */
export default function CompanyDetailsCard() {
  const { organization, canManage } = useAuth();
  const canEdit = canManage('org.manage');
  const isTech = canManage('system.manage');
  const [f, setF] = useState(null);
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');
  const [error, setError] = useState('');

  async function load() {
    const { data } = await supabase.from('organizations').select('*').eq('id', organization.id).maybeSingle();
    if (!data || !('tin' in data)) { setF(undefined); return; }   // before 066
    setF({ legal_name: data.legal_name ?? '', tin: data.tin ?? '', vrn: data.vrn ?? '', address: data.address ?? '', phone: data.phone ?? '',
      email: data.email ?? '', bank_details: data.bank_details ?? '', document_footer: data.document_footer ?? '', logo_url: data.logo_url ?? '' });
  }
  useEffect(() => { if (organization?.id) load(); }, [organization?.id]); // eslint-disable-line react-hooks/exhaustive-deps

  // a logo is kept small: drawn at most 360 px wide, as PNG
  function pickLogo(file) {
    setError('');
    if (!file) return;
    const img = new Image();
    img.onload = () => {
      const w = Math.min(360, img.width), h = Math.round(img.height * (w / img.width));
      const c = document.createElement('canvas'); c.width = w; c.height = h;
      c.getContext('2d').drawImage(img, 0, 0, w, h);
      const url = c.toDataURL('image/png');
      if (url.length > 400000) { setError('That image is too large — use a smaller logo.'); return; }
      setF(x => ({ ...x, logo_url: url }));
    };
    img.onerror = () => setError('That file is not an image.');
    img.src = URL.createObjectURL(file);
  }

  async function save() {
    setError(''); setMsg('');
    const trim = v => (v.trim() === '' ? null : v.trim());
    const row = { tin: trim(f.tin), vrn: trim(f.vrn), address: trim(f.address), phone: trim(f.phone), email: trim(f.email),
      bank_details: trim(f.bank_details), document_footer: trim(f.document_footer),
      ...(isTech ? { legal_name: trim(f.legal_name), logo_url: f.logo_url || null } : {}) };
    setBusy(true);
    const { error: err } = await supabase.from('organizations').update(row).eq('id', organization.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setMsg('Saved — documents use these now.');
  }

  if (f === undefined || f === null) return null;
  const input = (k, label, props = {}) => (
    <label className="pe-field"><span>{label}</span><input className="form-input" disabled={!canEdit} value={f[k]} onChange={e => setF({ ...f, [k]: e.target.value })} {...props} /></label>
  );
  const area = (k, label, placeholder) => (
    <label className="pe-field"><span>{label}</span><textarea className="form-input" rows={3} disabled={!canEdit} placeholder={placeholder} value={f[k]} onChange={e => setF({ ...f, [k]: e.target.value })} /></label>
  );
  return (
    <section className="card">
      <div className="card-header"><h2 className="card-title">Company details for documents</h2></div>
      <div className="card-body modal-form" style={{ paddingTop: 6 }}>
        <p className="text-xs text-muted">Printed on quotations, invoices, receipts and delivery notes.</p>
        <div className="flex items-center gap-8">
          {f.logo_url ? <img src={f.logo_url} alt="Logo" style={{ maxHeight: 56, maxWidth: 160 }} /> : <span className="pl-help">No logo</span>}
          {isTech && <label className="btn btn-outline btn-sm">Upload logo<input type="file" accept="image/*" hidden onChange={e => pickLogo(e.target.files?.[0])} /></label>}
          {isTech && f.logo_url && <button type="button" className="btn btn-ghost btn-sm" onClick={() => setF({ ...f, logo_url: '' })}>Remove</button>}
        </div>
        <label className="pe-field"><span>Legal name{isTech ? '' : ' (Technical admin)'}</span><input className="form-input" disabled={!isTech} value={f.legal_name} onChange={e => setF({ ...f, legal_name: e.target.value })} /></label>
        <div className="form-row">{input('tin', 'TIN')}{input('vrn', 'VRN')}</div>
        {input('address', 'Address')}
        <div className="form-row">{input('phone', 'Phone', { inputMode: 'tel' })}{input('email', 'Email')}</div>
        {area('bank_details', 'How to pay (bank / mobile money)', 'e.g. CRDB Bank · STUMARCOT CO LTD · A/C 0150…\nM-Pesa Lipa Namba …')}
        {area('document_footer', 'Footer on documents', 'e.g. Goods once sold are not returnable. Prices valid 14 days.')}
        {canEdit && <div className="flex items-center gap-8">
          <button type="button" className={`btn btn-primary btn-sm${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save</button>
          {msg && <span className="text-xs text-success">{msg}</span>}
          {error && <span className="text-xs text-error">{error}</span>}
        </div>}
      </div>
    </section>
  );
}
