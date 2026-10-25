import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import NumberInput from '../NumberInput';

/**
 * Each branch's VAT rate (041), kept by its branch manager (products.manage
 * at the branch; org admins for every branch). 0 = not VAT-registered: no
 * VAT on that branch's purchases and expenses.
 */
export function BranchVatCard() {
  const { canAt } = useAuth();
  const [rows, setRows] = useState(null);       // null = loading; [] after a failed load (041 not live)
  const [editing, setEditing] = useState(null); // branch id
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    const { data, error: err } = await supabase.from('branches').select('id, name, status, vat_rate').order('name');
    setRows(err ? [] : (data || []).filter(b => b.status !== 'inactive'));
  }
  useEffect(() => { load(); }, []);

  async function save(id) {
    setError('');
    const n = Number(value);
    if (String(value).trim() === '' || !(n >= 0 && n < 100)) { setError('Enter a rate from 0 to below 100 (0 = not VAT-registered).'); return; }
    setBusy(true);
    const { error: err } = await supabase.rpc('set_branch_vat_rate', { p_branch_id: id, p_rate: n });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setEditing(null);
    load();
  }

  if (!rows?.length) return null;
  return (
    <section className="card">
      <div className="card-header"><h2 className="card-title">VAT per branch</h2></div>
      <div className="card-body" style={{ paddingTop: 6 }}>
        <p className="text-xs text-muted mb-8">Used on the branch's purchases and expenses: ticked, VAT = amount × rate/(100 + rate). Set by the branch manager; 0 = not VAT-registered.</p>
        {rows.map(b => (
          <div key={b.id} className="flex items-center gap-8" style={{ padding: '8px 0', borderBottom: '1px solid var(--border)', flexWrap: 'wrap' }}>
            <span className="text-sm" style={{ width: 140, color: 'var(--text-muted)' }}>{b.name}</span>
            {editing === b.id ? (
              <>
                <NumberInput step="any" min="0" className="form-input" style={{ width: 90 }} aria-label={`${b.name} VAT rate`} value={value} onChange={e => setValue(e.target.value)} /> %
                <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={() => save(b.id)}>Save</button>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setEditing(null); setError(''); }}>Cancel</button>
              </>
            ) : (
              <>
                <span className="text-sm" style={{ fontWeight: 500 }}>{Number(b.vat_rate) > 0 ? `${Number(b.vat_rate)}%` : 'Not VAT-registered'}</span>
                {canAt('products.manage', b.id, null) && (
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setEditing(b.id); setValue(String(b.vat_rate)); setError(''); }}>Change</button>
                )}
              </>
            )}
          </div>
        ))}
        {error && <p className="text-xs text-error mt-8">{error}</p>}
      </div>
    </section>
  );
}

/**
 * Expense categories (041): the list an expense is filed under. What was
 * bought is typed on each expense and never added here. Org admins keep it.
 */
export function ExpenseCategoriesCard() {
  return <NamedListCard table="expense_categories" perm="materials.manage" title="Expense categories" placeholder="New category, e.g. Fuel"
    help="An expense is filed under one of these. What was bought (a hammer, a LUKU token…) is typed on each expense, not kept here." />;
}

/** Reject reasons (042): picked at a batch's quality release; org admins keep the list */
export function RejectReasonsCard() {
  return <NamedListCard table="reject_reasons" perm="products.manage" title="Reject reasons" placeholder="New reason"
    help="Picked for the rejected pieces at a batch's quality release after curing." />;
}

/** A short list an organization keeps (name, order, in use) */
function NamedListCard({ table, perm, title, help, placeholder }) {
  const { canManage, organization } = useAuth();
  const canEdit = canManage(perm);
  const [cats, setCats] = useState(null);
  const [name, setName] = useState('');
  const [renaming, setRenaming] = useState(null);   // { id, name }
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    const { data, error: err } = await supabase.from(table).select('id, name, status, display_order').order('display_order').order('name');
    setCats(err ? [] : data || []);
  }
  useEffect(() => { load(); }, []);

  async function run(q) {
    setError('');
    setBusy(true);
    const { error: err } = await q;
    setBusy(false);
    if (err) { setError(err.code === '23505' ? 'That name is already on the list.' : dbErrorMessage(err)); return false; }
    load();
    return true;
  }
  async function add(e) {
    e.preventDefault();
    if (!name.trim()) return;
    const next = Math.max(0, ...cats.filter(c => c.display_order < 99).map(c => c.display_order)) + 1;   // "Other" (99) stays last
    if (await run(supabase.from(table).insert({ organization_id: organization.id, name: name.trim(), display_order: next }))) setName('');
  }

  if (!cats?.length) return null;
  return (
    <section className="card">
      <div className="card-header"><h2 className="card-title">{title}</h2></div>
      <div className="card-body" style={{ paddingTop: 6 }}>
        <p className="text-xs text-muted mb-8">{help}</p>
        {cats.map(c => (
          <div key={c.id} className="flex items-center gap-8" style={{ padding: '6px 0', borderBottom: '1px solid var(--border)', flexWrap: 'wrap' }}>
            {renaming?.id === c.id ? (
              <>
                <input className="form-input" style={{ maxWidth: 220 }} aria-label="Name" value={renaming.name} onChange={e => setRenaming({ ...renaming, name: e.target.value })} />
                <button type="button" className="btn btn-primary btn-sm" disabled={busy || !renaming.name.trim()}
                  onClick={async () => { if (await run(supabase.from(table).update({ name: renaming.name.trim() }).eq('id', c.id))) setRenaming(null); }}>Save</button>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => setRenaming(null)}>Cancel</button>
              </>
            ) : (
              <>
                <span className={`text-sm${c.status === 'inactive' ? ' text-muted' : ''}`} style={{ flex: 1, fontWeight: 500 }}>
                  {c.name}{c.status === 'inactive' && <span className="text-xs"> · not in use</span>}
                </span>
                {canEdit && (
                  <>
                    <button type="button" className="btn btn-ghost btn-sm" onClick={() => setRenaming({ id: c.id, name: c.name })}>Rename</button>
                    <button type="button" className="btn btn-ghost btn-sm" disabled={busy}
                      onClick={() => run(supabase.from(table).update({ status: c.status === 'active' ? 'inactive' : 'active' }).eq('id', c.id))}>
                      {c.status === 'active' ? 'Stop using' : 'Use again'}
                    </button>
                  </>
                )}
              </>
            )}
          </div>
        ))}
        {canEdit && (
          <form className="flex gap-8 mt-8" onSubmit={add}>
            <input className="form-input" placeholder={placeholder} aria-label={`Add to ${title}`} value={name} onChange={e => setName(e.target.value)} />
            <button type="submit" className="btn btn-outline btn-sm" disabled={busy || !name.trim()}>Add</button>
          </form>
        )}
        {error && <p className="text-xs text-error mt-8">{error}</p>}
      </div>
    </section>
  );
}

/** Days a batch cures before its quality release (042) — one period for the organization */
export function CuringDays({ canEdit }) {
  const { organization } = useAuth();
  const [days, setDays] = useState(null);
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => {
    if (!organization?.id) return;
    supabase.from('organizations').select('curing_days').eq('id', organization.id).maybeSingle()
      .then(({ data, error: err }) => { if (!err && data) setDays(data.curing_days); });
  }, [organization?.id]);
  async function save() {
    setError('');
    const n = Number(value);
    if (!Number.isInteger(n) || n < 0 || n > 365) { setError('Enter whole days, 0 to 365.'); return; }
    setBusy(true);
    const { error: err } = await supabase.from('organizations').update({ curing_days: n }).eq('id', organization.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setDays(n);
    setEditing(false);
  }
  if (days == null) return null;
  if (!editing) {
    return (
      <span className="flex items-center gap-8">
        {days} days
        {canEdit && <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setValue(String(days)); setEditing(true); }}>Change</button>}
      </span>
    );
  }
  return (
    <span className="flex flex-col gap-4">
      <span className="flex items-center gap-8">
        <NumberInput step="1" min="0" className="form-input" style={{ width: 90 }} aria-label="Curing days" value={value} onChange={e => setValue(e.target.value)} /> days
        <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={save}>Save</button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(false)}>Cancel</button>
      </span>
      <span className="text-xs text-muted" style={{ fontWeight: 400 }}>How long a batch cures before its quality release. Applies to every product.</span>
      {error && <span className="text-xs text-error">{error}</span>}
    </span>
  );
}

/** Fewest days a batch cures before its quality release (054); from then it can be released without a reason */
export function MinCuringDays({ canEdit }) {
  const { organization } = useAuth();
  const [days, setDays] = useState(undefined);   // undefined = loading; null = no minimum
  const [editing, setEditing] = useState(false);
  const [value, setValue] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  useEffect(() => {
    if (!organization?.id) return;
    supabase.from('organizations').select('*').eq('id', organization.id).maybeSingle()
      .then(({ data }) => setDays(data && 'min_curing_days' in data ? data.min_curing_days : undefined));
  }, [organization?.id]);
  async function save() {
    setError('');
    const n = String(value).trim() === '' ? null : Number(value);
    if (n !== null && (!Number.isInteger(n) || n < 0 || n > 365)) { setError('Enter whole days, 0 to 365, or leave blank for no minimum.'); return; }
    setBusy(true);
    const { error: err } = await supabase.from('organizations').update({ min_curing_days: n }).eq('id', organization.id);
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setDays(n);
    setEditing(false);
  }
  if (days === undefined) return null;
  if (!editing) {
    return (
      <span className="flex items-center gap-8">
        {days == null ? 'No minimum' : `${days} days`}
        {canEdit && <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setValue(days == null ? '' : String(days)); setEditing(true); }}>Change</button>}
      </span>
    );
  }
  return (
    <span className="flex flex-col gap-4">
      <span className="flex items-center gap-8">
        <NumberInput step="1" min="0" className="form-input" style={{ width: 90 }} aria-label="Minimum curing days" placeholder="None" value={value} onChange={e => setValue(e.target.value)} /> days
        <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={save}>Save</button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(false)}>Cancel</button>
      </span>
      <span className="text-xs text-muted" style={{ fontWeight: 400 }}>Release is refused before this; from it on, no reason is needed.</span>
      {error && <span className="text-xs text-error">{error}</span>}
    </span>
  );
}
