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
  const { canManage, organization } = useAuth();
  const canEdit = canManage('materials.manage');
  const [cats, setCats] = useState(null);
  const [name, setName] = useState('');
  const [renaming, setRenaming] = useState(null);   // { id, name }
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    const { data, error: err } = await supabase.from('expense_categories').select('id, name, status, display_order').order('display_order').order('name');
    setCats(err ? [] : data || []);
  }
  useEffect(() => { load(); }, []);

  async function run(q) {
    setError('');
    setBusy(true);
    const { error: err } = await q;
    setBusy(false);
    if (err) { setError(err.code === '23505' ? 'That category already exists.' : dbErrorMessage(err)); return false; }
    load();
    return true;
  }
  async function add(e) {
    e.preventDefault();
    if (!name.trim()) return;
    const next = Math.max(0, ...cats.filter(c => c.display_order < 99).map(c => c.display_order)) + 1;   // "Other" (99) stays last
    if (await run(supabase.from('expense_categories').insert({ organization_id: organization.id, name: name.trim(), display_order: next }))) setName('');
  }

  if (!cats?.length) return null;
  return (
    <section className="card">
      <div className="card-header"><h2 className="card-title">Expense categories</h2></div>
      <div className="card-body" style={{ paddingTop: 6 }}>
        <p className="text-xs text-muted mb-8">An expense is filed under one of these. What was bought (a hammer, a LUKU token…) is typed on each expense, not kept here.</p>
        {cats.map(c => (
          <div key={c.id} className="flex items-center gap-8" style={{ padding: '6px 0', borderBottom: '1px solid var(--border)', flexWrap: 'wrap' }}>
            {renaming?.id === c.id ? (
              <>
                <input className="form-input" style={{ maxWidth: 220 }} aria-label="Category name" value={renaming.name} onChange={e => setRenaming({ ...renaming, name: e.target.value })} />
                <button type="button" className="btn btn-primary btn-sm" disabled={busy || !renaming.name.trim()}
                  onClick={async () => { if (await run(supabase.from('expense_categories').update({ name: renaming.name.trim() }).eq('id', c.id))) setRenaming(null); }}>Save</button>
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
                      onClick={() => run(supabase.from('expense_categories').update({ status: c.status === 'active' ? 'inactive' : 'active' }).eq('id', c.id))}>
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
            <input className="form-input" placeholder="New category, e.g. Fuel" aria-label="New expense category" value={name} onChange={e => setName(e.target.value)} />
            <button type="submit" className="btn btn-outline btn-sm" disabled={busy || !name.trim()}>Add</button>
          </form>
        )}
        {error && <p className="text-xs text-error mt-8">{error}</p>}
      </div>
    </section>
  );
}
