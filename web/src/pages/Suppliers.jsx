import { useEffect, useState } from 'react';
import { Truck, Plus, Search } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { formatMoney } from '../lib/format';
import { dbErrorMessage } from '../lib/masterData';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';
import { EntityFlags, EntityHistory } from '../components/master/EntityPanels';

const LOAD_ERROR = "We couldn't load suppliers. Please try again.";
const FIELDS = [
  ['contact_person', 'Contact person'], ['phone', 'Phone'], ['email', 'Email'],
  ['tax_id', 'Tax ID (TIN)'], ['address', 'Address'], ['notes', 'Notes'],
];

/*
 * Supplier master data (migration 022). What a supplier provides is never
 * fixed on a material (031): it comes from the purchases recorded with
 * them (035) — what was bought, where, when, and what is still to pay.
 */
export default function Suppliers() {
  const { organization, canManage } = useAuth();
  const { branchId, branchName, inBranch } = useBranch();
  const canWrite = canManage('materials.manage');
  const [suppliers, setSuppliers] = useState([]);
  const [purchases, setPurchases] = useState([]);   // recorded purchases (035)
  const [itemNames, setItemNames] = useState({});   // 'm:<id>' / 'p:<id>' → name
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [search,  setSearch]  = useState('');
  const [showInactive, setShowInactive] = useState(false);
  const [editing, setEditing] = useState(null);

  async function load() {
    setError('');
    const [supRes, recRes, matRes, prodRes, totRes] = await Promise.all([
      supabase.from('suppliers').select('id, name, contact_person, phone, email, address, tax_id, notes, status').order('name'),
      supabase.from('purchases')
        .select('id, supplier_id, branch_id, purchase_date, lines:purchase_lines(tx:inventory_transactions(material_id, product_id))')
        .eq('status', 'recorded'),
      supabase.from('materials').select('id, name'),
      supabase.from('products').select('id, canonical_name'),
      supabase.from('purchase_totals').select('purchase_id, balance'),
    ]);
    const err = supRes.error || recRes.error || matRes.error || prodRes.error || totRes.error;
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }
    setSuppliers(supRes.data || []);
    const balance = Object.fromEntries((totRes.data || []).map(t => [t.purchase_id, Number(t.balance)]));
    setPurchases((recRes.data || []).map(r => ({ ...r, balance: balance[r.id] ?? 0 })));
    setItemNames({
      ...Object.fromEntries((matRes.data || []).map(m => [`m:${m.id}`, m.name])),
      ...Object.fromEntries((prodRes.data || []).map(p => [`p:${p.id}`, p.canonical_name])),
    });
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  // Per supplier, from the purchases in view (the sidebar's branch, or all)
  const bought = {};
  for (const r of purchases) {
    if (!inBranch(r.branch_id)) continue;
    const b = (bought[r.supplier_id] ??= { count: 0, last: '', items: new Set(), owed: 0 });
    b.count++;
    if (r.purchase_date > b.last) b.last = r.purchase_date;
    b.owed += Math.max(r.balance, 0);
    for (const l of r.lines) b.items.add(itemNames[l.tx?.material_id ? `m:${l.tx.material_id}` : `p:${l.tx?.product_id}`] ?? '—');
  }
  const money = v => formatMoney(v, organization?.currency_code);

  const q = search.trim().toLowerCase();
  const shown = suppliers.filter(s => (showInactive || s.status === 'active')
    && (!q || s.name.toLowerCase().includes(q) || (s.contact_person || '').toLowerCase().includes(q)));

  return (
    <PageShell
      title="Suppliers"
      subtitle="Master Data"
      actions={
        <div className="flex items-center gap-8">
          <div className="search-wrapper">
            <Search size={14} className="search-icon" />
            <input id="suppliers-search" type="search" className="search-input" placeholder="Search suppliers…" value={search} onChange={e => setSearch(e.target.value)} />
          </div>
          {canWrite && (
            <button type="button" className="btn btn-primary" onClick={() => setEditing({})}><Plus size={14} /> Add supplier</button>
          )}
        </div>
      }
    >
      <label className="text-sm flex items-center gap-4 mb-16">
        <input type="checkbox" checked={showInactive} onChange={e => setShowInactive(e.target.checked)} /> Show inactive
      </label>
      <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            <table>
              <thead><tr><th>Supplier</th><th>Contact</th><th>Bought from them{branchId ? ` (${branchName})` : ''}</th><th>Purchases</th><th>Status</th>{canWrite && <th aria-label="Actions" />}</tr></thead>
              <tbody>
                {loading ? Array.from({ length: 3 }).map((_, i) => <SkeletonRow key={i} cols={6} />)
                : shown.length === 0 ? (
                  <tr><td colSpan={6}><EmptyState icon={Truck} title="No suppliers yet"
                    description="Add the people and companies you buy from — or name a new one when recording a receipt." /></td></tr>
                ) : shown.map(s => (
                  <tr key={s.id}>
                    <td style={{ fontWeight: 500 }}>{s.name}</td>
                    <td className="text-sm">{[s.contact_person, s.phone, s.email].filter(Boolean).join(' · ') || <span className="text-muted">—</span>}</td>
                    <td className="text-sm text-muted">{bought[s.id] ? [...bought[s.id].items].sort().join(', ') : '—'}</td>
                    <td className="text-sm">{bought[s.id] ? <>{bought[s.id].count} <span className="text-muted">· last {bought[s.id].last}</span>{bought[s.id].owed > 0 && <div className="text-xs">{money(Math.round(bought[s.id].owed * 100) / 100)} to pay</div>}</> : <span className="text-muted">none yet</span>}</td>
                    <td><span className={`badge ${s.status === 'active' ? 'badge-success' : 'badge-neutral'}`}>{s.status}</span></td>
                    {canWrite && <td style={{ textAlign: 'right' }}><button type="button" className="btn btn-outline btn-sm" onClick={() => setEditing(s)}>Edit</button></td>}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {editing && (
        <SupplierModal supplier={editing} organizationId={organization.id}
          onClose={() => setEditing(null)} onSaved={async () => { setEditing(null); await load(); }} />
      )}
    </PageShell>
  );
}

function SupplierModal({ supplier, organizationId, onClose, onSaved }) {
  const isNew = !supplier.id;
  const [values, setValues] = useState(Object.fromEntries([['name'], ...FIELDS].map(([k]) => [k, supplier[k] ?? ''])));
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');

  async function save(e) {
    e.preventDefault();
    setError('');
    const row = Object.fromEntries(Object.entries(values).map(([k, v]) => [k, v.trim() || null]));
    setBusy(true);
    const { error: err } = isNew
      ? await supabase.from('suppliers').insert({ ...row, organization_id: organizationId })
      : await supabase.from('suppliers').update(row).eq('id', supplier.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  async function toggle() {
    setBusy(true);
    const { error: err } = await supabase.from('suppliers').update({ status: supplier.status === 'active' ? 'inactive' : 'active' }).eq('id', supplier.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  return (
    <Modal title={isNew ? 'Add supplier' : `Edit ${supplier.name}`} onClose={onClose}
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="supplier-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !values.name.trim()}>Save</button>
      </>}>
      <form id="supplier-form" className="modal-form" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        <div className="form-group">
          <label className="form-label" htmlFor="sup-name">Name</label>
          <input id="sup-name" className="form-input" required autoFocus value={values.name} onChange={e => setValues(v => ({ ...v, name: e.target.value }))} />
        </div>
        <div className="form-row">
          {FIELDS.map(([k, label]) => (
            <div key={k} className="form-group">
              <label className="form-label" htmlFor={`sup-${k}`}>{label}</label>
              <input id={`sup-${k}`} className="form-input" type={k === 'email' ? 'email' : 'text'} value={values[k]} onChange={e => setValues(v => ({ ...v, [k]: e.target.value }))} />
            </div>
          ))}
        </div>
        {!isNew && (
          <section>
            <h3 className="modal-section-title">Status</h3>
            <p className="text-sm text-muted" style={{ marginBottom: 8 }}>
              {supplier.status === 'active' ? 'Deactivating hides it when recording receipts. History is kept.' : 'Inactive — kept for history.'}
            </p>
            <button type="button" className="btn btn-outline" disabled={busy} onClick={toggle}>
              {supplier.status === 'active' ? 'Deactivate supplier' : 'Reactivate supplier'}
            </button>
          </section>
        )}
        {!isNew && <EntityFlags entityType="supplier" entityId={supplier.id} canResolve canRaise />}
        {!isNew && <EntityHistory entityType="supplier" entityId={supplier.id} />}
      </form>
    </Modal>
  );
}
