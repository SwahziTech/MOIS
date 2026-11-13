import { supabase } from '../../lib/supabase';

/*
 * Where the money came from (2026-11-13, migration 121): the branch's weekly operations cash, or the
 * directors / a bank. Only weekly-cash spending goes on the weekly cash sheet — cement or sand paid
 * by the directors does not. The person says which; nothing is assumed.
 *   value: true (weekly cash) | false (directors · bank) | null (not chosen yet)
 */
export function PaidFrom({ value, onChange }) {
  return (
    <div className="pe-field">
      <span>Money from</span>
      <div className="filter-chips" role="radiogroup" aria-label="Money from">
        <button type="button" role="radio" aria-checked={value === true} className={`filter-chip${value === true ? ' is-on' : ''}`} onClick={() => onChange(true)}
          title="Paid out of the cash the directors sent to the branch this week — shows on the weekly cash sheet">Weekly cash (branch)</button>
        <button type="button" role="radio" aria-checked={value === false} className={`filter-chip${value === false ? ' is-on' : ''}`} onClick={() => onChange(false)}
          title="Paid by the directors or from a bank — not on the weekly cash sheet">Directors · bank</button>
      </div>
    </div>
  );
}

/** Save the choice (121); before the migration it's simply not kept */
export async function saveWeeklyCash(kind, id, on) {
  if (!id || on == null) return;
  const { error } = await supabase.rpc('set_weekly_cash', { p_kind: kind, p_id: id, p_on: !!on });
  if (error && !/set_weekly_cash/.test(error.message || '')) console.error(error);
}
