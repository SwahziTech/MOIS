import { useEffect, useState } from 'react';
import { Plus } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';
import { formatAmount, tableDate } from '../../lib/format';
import NumberInput from '../NumberInput';

const SHOWN = 30;

/*
 * Overtime inside a person (migration 102, 2026-11-01): typed by hand, counted
 * on their pay sheet automatically. A rest day appears here when they are
 * ticked on attendance, at the company's rate, and its amount can be adjusted.
 * Newest first. Approved pay sheets can't change.
 */
export default function OvertimePanel({ person, today, canRecord, onChanged }) {
  const [rows, setRows] = useState(null);
  const [form, setForm] = useState(null);     // { id?, work_date, amount, note, kind }
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    const { data, error: err } = await supabase.from('staff_overtime').select('id, work_date, kind, amount, note')
      .eq('staff_id', person.id).eq('status', 'recorded').order('work_date', { ascending: false }).limit(SHOWN);
    setRows(err ? false : data || []);
  }
  useEffect(() => { load(); }, [person.id]); // eslint-disable-line react-hooks/exhaustive-deps

  async function send(p) {
    setBusy(true); setError('');
    const { error: err } = await supabase.rpc('save_overtime', { p });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    setForm(null);
    await load();
    onChanged?.();
  }
  function save(e) {
    e.preventDefault();
    send({ ...(form.id ? { id: form.id } : { staff_id: person.id }), work_date: form.work_date, amount: form.amount, note: form.note });
  }

  if (rows === false) return null;   // before 102
  const total = (rows || []).reduce((t, r) => t + Number(r.amount), 0);
  return (
    <section className="ot-panel">
      <div className="ot-head">
        <strong>Overtime</strong>
        {canRecord && !form && <button type="button" className="btn btn-outline btn-sm" onClick={() => setForm({ work_date: today, amount: '', note: '' })}><Plus size={13} /> Add</button>}
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {form && (
        <form className="form-row ot-form" onSubmit={save}>
          <label className="pe-field"><span>Date</span>
            <input type="date" className="form-input" required max={today} disabled={form.kind === 'rest_day'} value={form.work_date} onChange={e => setForm({ ...form, work_date: e.target.value })} /></label>
          <label className="pe-field"><span>Amount (TZS)</span>
            <NumberInput step="any" min="0" className="form-input" required autoFocus value={form.amount} onChange={e => setForm({ ...form, amount: e.target.value })} /></label>
          <label className="pe-field" style={{ flex: 1 }}><span>Note</span>
            <input className="form-input" placeholder="e.g. stayed 3 hours" value={form.note} onChange={e => setForm({ ...form, note: e.target.value })} /></label>
          <button type="submit" className="btn btn-primary btn-sm" disabled={busy}>Save</button>
          <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setForm(null); setError(''); }}>Cancel</button>
        </form>
      )}
      {rows === null ? <span className="skeleton" /> : rows.length === 0 ? <p className="pl-help">No overtime recorded.</p> : (
        <div className="table-container">
          <table>
            <thead><tr><th>Date</th><th>For</th><th className="num">Amount (TZS)</th>{canRecord && <th aria-label="Actions" />}</tr></thead>
            <tbody>
              {rows.map(r => (
                <tr key={r.id}>
                  <td>{tableDate(r.work_date)}</td>
                  <td>{r.kind === 'rest_day' ? 'Rest day' : 'Overtime'}{r.note ? ` · ${r.note}` : ''}</td>
                  <td className="num">{formatAmount(Number(r.amount))}</td>
                  {canRecord && (
                    <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
                      <button type="button" className="btn btn-ghost btn-sm" onClick={() => setForm({ id: r.id, kind: r.kind, work_date: r.work_date, amount: String(Number(r.amount)), note: r.note ?? '' })}>Edit</button>
                      {r.kind !== 'rest_day' && <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={() => send({ id: r.id, void: true })}>Remove</button>}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
            <tfoot><tr><td colSpan={2}><strong>Total shown</strong></td><td className="num"><strong>{formatAmount(total)}</strong></td>{canRecord && <td />}</tr></tfoot>
          </table>
        </div>
      )}
    </section>
  );
}
