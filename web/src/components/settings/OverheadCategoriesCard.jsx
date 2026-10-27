import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';

/**
 * Which expense categories are production costs (076): their expenses stay in
 * Purchases › Expenses, and Costing shares them into the month's batches (by
 * machine when an expense names one). Electricity is costed from the meter
 * readings and wages come with HR, so neither is counted twice.
 */
export default function OverheadCategoriesCard({ onChanged }) {
  const { canManage } = useAuth();
  const [cats, setCats] = useState(null);       // null = loading; false = before 076
  const [error, setError] = useState('');
  const canEdit = canManage('materials.manage');
  async function load() {
    const { data, error: err } = await supabase.from('expense_categories').select('*').order('display_order').order('name');
    setCats(err || !(data || []).every(c => 'in_production_cost' in c) ? false : (data || []).filter(c => c.status === 'active'));
  }
  useEffect(() => { load(); }, []);
  async function toggle(c) {
    setError('');
    const { error: err } = await supabase.from('expense_categories').update({ in_production_cost: !c.in_production_cost }).eq('id', c.id);
    if (err) { setError(dbErrorMessage(err)); return; }
    await load(); onChanged?.();
  }
  if (cats === false) return null;
  return (
    <section className="card">
      <div className="card-header"><h2 className="card-title">Production costs</h2></div>
      <div className="card-body" style={{ paddingTop: 6 }}>
        <p className="text-xs text-muted mb-8">Tick the expense categories that are production costs (diesel, repairs, molds…). Their expenses stay here; Costing shares them over the month's batches by cement bags — over a machine's batches when the expense names one. Electricity (meter readings) and wages (HR) are never counted twice.</p>
        {cats === null ? <p className="text-sm text-muted">Loading…</p> : cats.map(c => {
          const fixed = /^\s*(electricity|wages)\b/i.test(c.name);
          return (
            <label key={c.id} className="ps-row text-sm" style={{ cursor: canEdit && !fixed ? 'pointer' : 'default' }}>
              <span>{c.name}{fixed && <span className="pl-help"> · {/^\s*electricity/i.test(c.name) ? 'costed from the meters' : 'labour, with HR'}</span>}</span>
              <input type="checkbox" checked={!fixed && c.in_production_cost} disabled={!canEdit || fixed} onChange={() => toggle(c)} />
            </label>
          );
        })}
        {error && <p className="text-xs text-error">{error}</p>}
      </div>
    </section>
  );
}
