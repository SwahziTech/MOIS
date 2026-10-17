import { useEffect, useState } from 'react';
import { Palette, Plus } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { dbErrorMessage } from '../lib/masterData';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';
import { EntityFlags, EntityHistory } from '../components/master/EntityPanels';

const LOAD_ERROR = "We couldn't load this page. Please try again.";

/**
 * The organization's colour palette (color_palette). Open-ended per tenant:
 * categories, recipes and prices reference these colours by id.
 */
export default function Colours() {
  const { organization, canManage } = useAuth();
  const canWrite = canManage('products.manage');
  const [colours, setColours] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error,   setError]   = useState('');
  const [editing, setEditing] = useState(null);   // colour row, or {} for new

  async function load() {
    setError('');
    const { data, error: err } = await supabase
      .from('color_palette')
      .select('id, name, display_order, is_active, categories:product_category_colors(count)')
      .order('display_order').order('name');
    if (err) { console.error(err); setError(LOAD_ERROR); setLoading(false); return; }
    setColours(data || []);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  return (
    <PageShell
      title="Colours"
      subtitle="Master Data"
      description="The colours your products come in; each category chooses its own."
      primaryAction={canWrite && (
        <button type="button" className="btn btn-primary" onClick={() => setEditing({})}>
          <Plus size={14} /> New Colour
        </button>
      )}
    >
      <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            <table>
              <thead>
                <tr><th>Colour</th><th>Order</th><th>Used by</th><th>Status</th>{canWrite && <th aria-label="Actions" />}</tr>
              </thead>
              <tbody>
                {loading ? Array.from({ length: 4 }).map((_, i) => <SkeletonRow key={i} cols={canWrite ? 5 : 4} />)
                : colours.length === 0 ? (
                  <tr><td colSpan={canWrite ? 5 : 4}>
                    <EmptyState icon={Palette} title="No colours yet" description="Add the colours your products come in." />
                  </td></tr>
                ) : colours.map(c => (
                  <tr key={c.id}>
                    <td style={{ fontWeight: 500 }}>{c.name}</td>
                    <td className="text-muted">{c.display_order}</td>
                    <td className="text-muted">{c.categories?.[0]?.count ?? 0} categor{(c.categories?.[0]?.count ?? 0) === 1 ? 'y' : 'ies'}</td>
                    <td><span className={`badge ${c.is_active ? 'badge-success' : 'badge-neutral'}`}>{c.is_active ? 'active' : 'inactive'}</span></td>
                    {canWrite && (
                      <td style={{ textAlign: 'right' }}>
                        <button type="button" className="btn btn-outline btn-sm" onClick={() => setEditing(c)}>Edit</button>
                      </td>
                    )}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {editing && (
        <ColourModal
          colour={editing}
          organizationId={organization.id}
          nextOrder={Math.max(0, ...colours.map(c => c.display_order)) + 1}
          onClose={() => setEditing(null)}
          onSaved={async () => { setEditing(null); await load(); }}
        />
      )}
    </PageShell>
  );
}

function ColourModal({ colour, organizationId, nextOrder, onClose, onSaved }) {
  const isNew = !colour.id;
  const [name,  setName]  = useState(colour.name ?? '');
  const [order, setOrder] = useState(colour.display_order ?? nextOrder);
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const inUse = colour.categories?.[0]?.count ?? 0;

  async function save(e) {
    e.preventDefault();
    setError('');
    setBusy(true);
    const row = { name: name.trim(), display_order: Number(order) || 0 };
    const { error: err } = isNew
      ? await supabase.from('color_palette').insert({ ...row, organization_id: organizationId })
      : await supabase.from('color_palette').update(row).eq('id', colour.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  async function toggleActive() {
    setError('');
    setBusy(true);
    const { error: err } = await supabase.from('color_palette').update({ is_active: !colour.is_active }).eq('id', colour.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  return (
    <Modal title={isNew ? 'Add colour' : `Edit ${colour.name}`} onClose={onClose}
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="colour-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !name.trim()}>Save</button>
      </>}>
      <form id="colour-form" className="modal-form" onSubmit={save}>
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="colour-name">Name</label>
            <input id="colour-name" className="form-input" required autoFocus value={name} onChange={e => setName(e.target.value)} />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="colour-order">Display order</label>
            <input id="colour-order" type="number" className="form-input" value={order} onChange={e => setOrder(e.target.value)} />
          </div>
        </div>
        {!isNew && (
          <section>
            <h3 className="modal-section-title">Status</h3>
            <p className="text-sm text-muted" style={{ marginBottom: 8 }}>
              {colour.is_active
                ? `Deactivating hides it when choosing colours. ${inUse ? `It stays on the ${inUse} categor${inUse === 1 ? 'y' : 'ies'} already using it.` : ''}`
                : 'Inactive — not offered when choosing colours.'}
            </p>
            <button type="button" className="btn btn-outline" disabled={busy} onClick={toggleActive}>
              {colour.is_active ? 'Deactivate colour' : 'Reactivate colour'}
            </button>
          </section>
        )}
        {!isNew && <EntityFlags entityType="color" entityId={colour.id} canResolve />}
        {!isNew && <EntityHistory entityType="color" entityId={colour.id} />}
      </form>
    </Modal>
  );
}
