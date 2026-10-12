import { useEffect, useState } from 'react';
import { Truck, Plus, Search } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
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
 * Supplier master data (migration 022). Which materials a supplier provides
 * comes from the materials' branch sources; purchase history and balances
 * arrive with procurement (1c).
 */
export default function Suppliers() {
  const { organization, canManage } = useAuth();
  const canWrite = canManage('materials.manage');
  const [suppliers, setSuppliers] = useState([]);
  const [supplies,  setSupplies]  = useState({});   // supplier id → ['Cement (Dodoma)', ...]
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [search,  setSearch]  = useState('');
  const [showInactive, setShowInactive] = useState(false);
  const [editing, setEditing] = useState(null);

  async function load() {
    setError('');
    const [supRes, srcRes] = await Promise.all([
      supabase.from('suppliers').select('id, name, contact_person, phone, email, address, tax_id, notes, status').order('name'),
      supabase.from('material_branch_sources').select('supplier_id, status, material:materials(name), branch:branches(name)').not('supplier_id', 'is', null),
    ]);
    if (supRes.error || srcRes.error) { console.error(supRes.error || srcRes.error); setError(LOAD_ERROR); setLoading(false); return; }
    const map = {};
    for (const s of srcRes.data || []) if (s.status === 'active') (map[s.supplier_id] ??= []).push(`${s.material?.name} (${s.branch?.name})`);
    setSuppliers(supRes.data || []);
    setSupplies(map);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

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
              <thead><tr><th>Supplier</th><th>Contact</th><th>Supplies</th><th>Status</th>{canWrite && <th aria-label="Actions" />}</tr></thead>
              <tbody>
                {loading ? Array.from({ length: 3 }).map((_, i) => <SkeletonRow key={i} cols={5} />)
                : shown.length === 0 ? (
                  <tr><td colSpan={5}><EmptyState icon={Truck} title="No suppliers yet"
                    description="Add the people and companies you buy materials from, then link them to materials' sources." /></td></tr>
                ) : shown.map(s => (
                  <tr key={s.id}>
                    <td style={{ fontWeight: 500 }}>{s.name}</td>
                    <td className="text-sm">{[s.contact_person, s.phone, s.email].filter(Boolean).join(' · ') || <span className="text-muted">—</span>}</td>
                    <td className="text-sm text-muted">{supplies[s.id]?.join(', ') || '—'}</td>
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
