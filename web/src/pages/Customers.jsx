import { useEffect, useMemo, useState } from 'react';
import { Users, Plus } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney } from '../lib/format';
import { dbErrorMessage } from '../lib/masterData';
import PageShell from '../components/PageShell';
import { ListToolbar } from '../components/ListControls';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';

const LOAD_ERROR = "We couldn't load customers. Please try again.";
const r2 = n => Math.round(n * 100) / 100;

/*
 * Customers (1e, migration 064): shared by the organization's branches —
 * name, phone, TIN/VRN, and what each owes across its orders and invoices.
 * Click shows the details; double-click or Edit changes them.
 */
export default function Customers() {
  const { organization, canAnywhere, can } = useAuth();
  const { branchId } = useBranch();
  const money = v => formatMoney(v, organization?.currency_code);
  const [rows, setRows] = useState(null);
  const [balances, setBalances] = useState([]);
  const [error, setError] = useState('');
  const [search, setSearch] = useState('');
  const [editing, setEditing] = useState(null);
  const [viewing, setViewing] = useState(null);
  const canEdit = (canAnywhere ?? can)('sales.create');

  async function load() {
    setError('');
    const [c, b] = await Promise.all([
      supabase.from('customers').select('*').order('name'),
      supabase.from('sale_balances').select('*'),
    ]);
    if (c.error) { console.error(c.error); setError(LOAD_ERROR); return; }
    setRows(c.data || []);
    setBalances(b.data || []);
  }
  useEffect(() => { load(); }, []);

  const statsOf = id => {
    const mine = balances.filter(b => b.customer_id === id && b.stage !== 'cancelled');
    return { sales: mine.length, owed: r2(mine.filter(b => b.stage !== 'quotation').reduce((t, b) => t + Number(b.balance), 0)) };
  };
  const shown = useMemo(() => {
    const q = search.trim().toLowerCase();
    return (rows || []).filter(c => !q || `${c.name} ${c.phone ?? ''} ${c.tin ?? ''}`.toLowerCase().includes(q));
  }, [rows, search]);

  return (
    <PageShell title="Customers" subtitle="Sales & Costing" description="Customers shared by every branch, and what each owes."
      primaryAction={canEdit && <button type="button" className="btn btn-primary" onClick={() => setEditing({})}><Plus size={15} /> New customer</button>}>
      {error ? <div className="card"><ErrorState message={error} onRetry={load} /></div> : (
        <>
          <ListToolbar id="customers-search" search={search} onSearch={setSearch} placeholder="Search name, phone or TIN…" />
          <section className="sk">
            <div className="sk-head"><span>Customers ({shown.length})</span></div>
            {rows === null ? Array.from({ length: 4 }).map((_, i) => <div key={i} className="sk-card"><span className="skeleton" /></div>)
            : shown.length === 0 ? <div className="card"><EmptyState icon={Users} title="No customers yet" description="Add them here or while making a sale. Walk-in buyers need no record." /></div>
            : shown.map(c => {
              const st = statsOf(c.id);
              return (
                <div key={c.id} className={`sk-card lk-card${c.status !== 'active' ? ' is-inactive' : ''}`} onClick={() => setViewing(c)}
                  onDoubleClick={() => { if (canEdit) { setViewing(null); setEditing(c); } }} title="Click for details · double-click to edit">
                  <div className="sk-name">
                    <strong>{c.name}</strong>
                    <span className="pl-help">{[c.phone, c.tin && `TIN ${c.tin}`].filter(Boolean).join(' · ') || 'no phone'}</span>
                  </div>
                  <div className="sk-total">
                    <span><strong className={st.owed > 0 ? 'text-warning' : ''}>{money(st.owed)}</strong></span>
                    <span className="sk-sub">owed</span>
                  </div>
                  <div className="co-details">
                    <span>{st.sales} sale{st.sales === 1 ? '' : 's'}</span>
                    {c.status !== 'active' && <span className="pl-help">not in use</span>}
                  </div>
                </div>
              );
            })}
          </section>
        </>
      )}
      {viewing && (
        <Modal title={viewing.name} onClose={() => setViewing(null)}
          footer={<>{canEdit && <button type="button" className="btn btn-outline" onClick={() => { setEditing(viewing); setViewing(null); }}>Edit</button>}
            <button type="button" className="btn btn-primary" onClick={() => setViewing(null)}>Close</button></>}>
          <dl className="detail-list text-sm">
            <dt>Phone</dt><dd>{viewing.phone || '—'}</dd>
            <dt>Email</dt><dd>{viewing.email || '—'}</dd>
            <dt>TIN</dt><dd>{viewing.tin || '—'}</dd>
            <dt>VRN</dt><dd>{viewing.vrn || '—'}</dd>
            <dt>Address</dt><dd>{viewing.address || '—'}</dd>
            <dt>Owed</dt><dd>{money(statsOf(viewing.id).owed)} across {statsOf(viewing.id).sales} sale(s)</dd>
            {viewing.notes && <><dt>Notes</dt><dd>{viewing.notes}</dd></>}
          </dl>
        </Modal>
      )}
      {editing && <CustomerModal customer={editing.id ? editing : null} organizationId={organization?.id} branchId={branchId}
        onClose={() => setEditing(null)} onSaved={async () => { setEditing(null); await load(); }} />}
    </PageShell>
  );
}

function CustomerModal({ customer, organizationId, branchId, onClose, onSaved }) {
  const [f, setF] = useState({ name: customer?.name ?? '', phone: customer?.phone ?? '', email: customer?.email ?? '', tin: customer?.tin ?? '',
    vrn: customer?.vrn ?? '', address: customer?.address ?? '', notes: customer?.notes ?? '', status: customer?.status ?? 'active' });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const field = (k, label, extra = {}) => (
    <label className="pe-field"><span>{label}</span><input className="form-input" value={f[k]} onChange={e => setF({ ...f, [k]: e.target.value })} {...extra} /></label>
  );
  async function save() {
    setError('');
    if (!f.name.trim()) { setError('Enter the name.'); return; }
    const row = Object.fromEntries(Object.entries(f).map(([k, v]) => [k, typeof v === 'string' && k !== 'status' ? (v.trim() || null) : v]));
    setBusy(true);
    const { error: err } = customer
      ? await supabase.from('customers').update(row).eq('id', customer.id)
      : await supabase.from('customers').insert({ ...row, organization_id: organizationId, branch_id: branchId || null });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }
  return (
    <Modal title={customer ? `Edit ${customer.name}` : 'New customer'} onClose={onClose}
      footer={<>{error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save</button></>}>
      <div className="modal-form">
        {field('name', 'Name', { autoFocus: true })}
        <div className="form-row">{field('phone', 'Phone', { inputMode: 'tel' })}{field('email', 'Email')}</div>
        <div className="form-row">{field('tin', 'TIN')}{field('vrn', 'VRN')}</div>
        {field('address', 'Address')}
        {field('notes', 'Notes')}
        {customer && <label className="text-sm flex items-center gap-8"><input type="checkbox" checked={f.status === 'active'} onChange={e => setF({ ...f, status: e.target.checked ? 'active' : 'inactive' })} /> In use</label>}
      </div>
    </Modal>
  );
}
