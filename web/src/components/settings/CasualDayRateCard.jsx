import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { formatMoney } from '../../lib/format';
import { dbErrorMessage } from '../../lib/masterData';
import NumberInput from '../NumberInput';

/**
 * What a casual labourer is paid a day, per branch (073) — labour cost until
 * the Staff (HR) phase: the day's casual labourers (daily report) × this rate,
 * shared over the day's batches by cement bags. Days already entered keep the
 * rate they were entered with.
 */
export default function CasualDayRateCard() {
  const { organization, canAt } = useAuth();
  const [rows, setRows] = useState(null);       // null = loading; false = before 073
  const [editing, setEditing] = useState(null);
  const [value, setValue] = useState('');
  const [error, setError] = useState('');
  async function load() {
    const { data, error: err } = await supabase.from('branches').select('id, name, status, casual_day_rate').eq('status', 'active').order('name');
    setRows(err ? false : data || []);
  }
  useEffect(() => { load(); }, []);
  async function save(id) {
    setError('');
    const n = value.trim() === '' ? null : Number(value);
    if (n !== null && !(n >= 0)) { setError('Enter the day rate as a number.'); return; }
    const { error: err } = await supabase.rpc('set_branch_casual_day_rate', { p_branch: id, p_rate: n });
    if (err) { setError(dbErrorMessage(err)); return; }
    setEditing(null);
    load();
  }
  if (rows === false) return null;
  return (
    <section className="card">
      <div className="card-header"><h2 className="card-title">Casual labour</h2></div>
      <div className="card-body" style={{ paddingTop: 6 }}>
        <p className="text-xs text-muted mb-8">What a casual labourer is paid a day. The daily report asks how many worked; their wages are shared over the day's batches by cement bags, into product cost.</p>
        {rows === null ? <p className="text-sm text-muted">Loading…</p> : rows.map(b => (
          <div key={b.id} className="ps-row">
            <span>{b.name}</span>
            {editing === b.id ? (
              <span className="flex items-center gap-8">
                <NumberInput step="any" min="0" className="form-input" style={{ width: 110 }} autoFocus value={value} onChange={e => setValue(e.target.value)} />
                <button type="button" className="btn btn-primary btn-sm" onClick={() => save(b.id)}>Save</button>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => setEditing(null)}>Cancel</button>
              </span>
            ) : (
              <span className="flex items-center gap-8">
                <span className="text-sm" style={{ fontWeight: 500 }}>{b.casual_day_rate != null ? `${formatMoney(Number(b.casual_day_rate), organization?.currency_code)} a day` : 'Not set'}</span>
                {(canAt('production.create', b.id, null) || canAt('products.manage', b.id, null)) &&
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setEditing(b.id); setValue(b.casual_day_rate != null ? String(Number(b.casual_day_rate)) : ''); setError(''); }}>Change</button>}
              </span>
            )}
          </div>
        ))}
        {error && <p className="text-xs text-error">{error}</p>}
      </div>
    </section>
  );
}
