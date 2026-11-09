import { useEffect, useState } from 'react';
import { Plus, Pencil, Trash2, Check, X } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';
import { formatAmount, tableDate } from '../../lib/format';
import NumberInput from '../NumberInput';

const SHOWN = 30;

/*
 * Overtime inside a person (102; redesigned 2026-11-09, the user — 114): one table, edited in place.
 * Each line: date, what for, amount, and whether it was paid directly. Edit changes the date,
 * amount and note on the row itself; Mark paid takes it off the pay sheet (paid in cash);
 * Delete removes it (a rest day's line too). Newest first. Approved pay sheets can't change.
 */
export default function OvertimePanel({ person, today, canRecord, onChanged }) {
  const [rows, setRows] = useState(null);
  const [editing, setEditing] = useState(null);   // { id? (none = new), kind, work_date, amount, note }
  const [deleting, setDeleting] = useState(null); // a row id waiting for Yes
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    let r = await supabase.from('staff_overtime').select('id, work_date, kind, amount, note, paid_on')
      .eq('staff_id', person.id).eq('status', 'recorded').order('work_date', { ascending: false }).limit(SHOWN);
    if (r.error) r = await supabase.from('staff_overtime').select('id, work_date, kind, amount, note')   // before 114
      .eq('staff_id', person.id).eq('status', 'recorded').order('work_date', { ascending: false }).limit(SHOWN);
    setRows(r.error ? false : r.data || []);
  }
  useEffect(() => { load(); }, [person.id]); // eslint-disable-line react-hooks/exhaustive-deps

  async function send(p) {
    setBusy(true); setError('');
    const { error: err } = await supabase.rpc('save_overtime', { p });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return false; }
    setEditing(null); setDeleting(null);
    await load();
    onChanged?.();
    return true;
  }
  function saveRow(e) {
    e?.preventDefault();
    if (!editing.work_date) { setError('Choose the day.'); return; }
    if (editing.amount === '' || Number(editing.amount) < 0) { setError('Enter the amount.'); return; }
    send({ ...(editing.id ? { id: editing.id } : { staff_id: person.id }), work_date: editing.work_date, amount: editing.amount, note: editing.note });
  }

  if (rows === false) return null;   // before 102
  const total = (rows || []).reduce((t, r) => t + Number(r.amount), 0);
  const unpaid = (rows || []).filter(r => !r.paid_on).reduce((t, r) => t + Number(r.amount), 0);
  const editRow = key => (
    <tr key={key} className="ot-edit">
      <td><input type="date" className="form-input" aria-label="Date" max={today} value={editing?.work_date ?? ''} onChange={e => setEditing({ ...editing, work_date: e.target.value })} /></td>
      <td><input className="form-input" aria-label="Note" placeholder="e.g. stayed 3 hours" value={editing?.note ?? ''} onChange={e => setEditing({ ...editing, note: e.target.value })}
        onKeyDown={e => { if (e.key === 'Enter') saveRow(e); }} /></td>
      <td className="num"><NumberInput step="any" min="0" className="form-input" aria-label="Amount" autoFocus value={editing?.amount ?? ''} onChange={e => setEditing({ ...editing, amount: e.target.value })}
        onKeyDown={e => { if (e.key === 'Enter') saveRow(e); }} /></td>
      <td />
      <td className="ot-actions">
        <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={saveRow}><Check size={13} /> Save</button>
        <button type="button" className="btn btn-ghost btn-sm" onClick={() => { setEditing(null); setError(''); }}>Cancel</button>
      </td>
    </tr>
  );
  return (
    <section className="ot-panel">
      <div className="ot-head">
        <strong>Overtime</strong>
        {rows?.length > 0 && <span className="pl-help">{formatAmount(unpaid)} to pay on the pay sheet</span>}
        {canRecord && !editing && <button type="button" className="btn btn-outline btn-sm" style={{ marginLeft: 'auto' }} onClick={() => setEditing({ work_date: today, amount: '', note: '' })}><Plus size={13} /> Add</button>}
      </div>
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {rows === null ? <span className="skeleton" /> : rows.length === 0 && !editing ? <p className="pl-help">No overtime recorded.</p> : (
        <div className="table-container">
          <table className="ot-table">
            <thead><tr><th>Date</th><th>For</th><th className="num">Amount (TZS)</th><th>Paid</th>{canRecord && <th aria-label="Actions" />}</tr></thead>
            <tbody>
              {editing && !editing.id && editRow('new')}
              {rows.map(r => (editing?.id === r.id ? editRow(r.id) : (
                <tr key={r.id} className={r.paid_on ? 'ot-paid' : ''}>
                  <td>{tableDate(r.work_date)}</td>
                  <td>{r.kind === 'rest_day' ? 'Rest day' : 'Overtime'}{r.note ? <span className="pl-help"> · {r.note}</span> : ''}</td>
                  <td className="num">{formatAmount(Number(r.amount))}</td>
                  <td>{r.paid_on ? <span className="badge badge-success">Paid {tableDate(r.paid_on)}</span> : <span className="pl-help">On pay sheet</span>}</td>
                  {canRecord && (
                    <td className="ot-actions">
                      {deleting === r.id ? <>
                        <span className="pl-help">Delete?</span>
                        <button type="button" className="btn btn-danger btn-sm" disabled={busy} onClick={() => send({ id: r.id, void: true })}>Yes</button>
                        <button type="button" className="btn btn-ghost btn-sm" onClick={() => setDeleting(null)}>No</button>
                      </> : <>
                        {'paid_on' in r && (r.paid_on
                          ? <button type="button" className="btn btn-ghost btn-sm" disabled={busy} title="Put it back on the pay sheet" onClick={() => send({ id: r.id, paid: false })}><X size={13} /> Not paid</button>
                          : <button type="button" className="btn btn-outline btn-sm" disabled={busy} title="Paid directly — it comes off the pay sheet" onClick={() => send({ id: r.id, paid: true })}><Check size={13} /> Mark paid</button>)}
                        <button type="button" className="icon-btn" aria-label="Edit" title="Edit the date, amount or note" disabled={!!editing} onClick={() => { setError(''); setEditing({ id: r.id, kind: r.kind, work_date: r.work_date, amount: String(Number(r.amount)), note: r.note ?? '' }); }}><Pencil size={14} /></button>
                        <button type="button" className="icon-btn" aria-label="Delete" title="Delete" onClick={() => setDeleting(r.id)}><Trash2 size={14} /></button>
                      </>}
                    </td>
                  )}
                </tr>
              )))}
            </tbody>
            <tfoot><tr><td colSpan={2}><strong>Total shown</strong></td><td className="num"><strong>{formatAmount(total)}</strong></td><td colSpan={canRecord ? 2 : 1} /></tr></tfoot>
          </table>
        </div>
      )}
    </section>
  );
}
