import { useEffect, useState } from 'react';
import { supabase } from '../../lib/supabase';
import { useBranch } from '../../hooks/useBranch';
import { dbErrorMessage } from '../../lib/masterData';
import { formatMoney } from '../../lib/format';
import { orgToday } from '../../lib/inventory';
import Modal from '../Modal';
import NumberInput from '../NumberInput';

const num = v => (String(v ?? '').trim() === '' ? null : Number(v));
const round2 = n => Math.round(n * 100) / 100;
export const PAYMENT_METHODS = ['Cash', 'Mobile money', 'Bank transfer', 'Cheque'];   // as on purchases

/**
 * Record or change an expense (041): electricity, water, tools, equipment…
 * The category comes from the list; what was bought is typed each time —
 * on purpose never offered back as a list to pick from.
 */
export default function ExpenseModal({ expense, branchId, categories, suppliers, vatRateOf, organization, canRecordAt, onClose, onSaved }) {
  const { branches } = useBranch();
  const today = orgToday(organization?.timezone);
  const money = v => formatMoney(v, organization?.currency_code);
  const isNew = !expense;
  const myBranches = branches.filter(b => b.status !== 'inactive' && canRecordAt(b.id));

  const [branch,   setBranch]   = useState(expense?.branch_id ?? (canRecordAt(branchId) ? branchId : myBranches[0]?.id ?? ''));
  const [date,     setDate]     = useState(expense?.expense_date ?? today);
  const [category, setCategory] = useState(expense?.category_id ?? '');
  const [what,     setWhat]     = useState(expense?.description ?? '');
  const [qty,      setQty]      = useState(expense?.quantity != null ? String(expense.quantity) : '');
  const [price,    setPrice]    = useState(expense?.unit_price != null ? String(expense.unit_price) : '');
  const [amount,   setAmount]   = useState(expense ? String(expense.amount) : '');
  const [supplierId, setSupplierId] = useState(expense?.supplier_id ?? '');
  const [newSupplier, setNewSupplier] = useState('');
  const [vatShown, setVatShown] = useState(expense?.vat_amount != null);
  const [paid,     setPaid]     = useState(expense ? String(expense.amount_paid) : '');
  const [method,   setMethod]   = useState(expense?.payment_method ?? '');
  const [paidOn,   setPaidOn]   = useState(expense?.paid_on ?? expense?.expense_date ?? today);
  const [paidOnSet, setPaidOnSet] = useState(!!expense?.paid_on);
  const [notes,    setNotes]    = useState(expense?.notes ?? '');
  const [voiding,  setVoiding]  = useState(false);
  const [voidReason, setVoidReason] = useState('');
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  // LUKU (072): an Electricity expense names its meter and units; it is recorded as the meter's token
  const [meters, setMeters] = useState([]);
  const [meterId, setMeterId] = useState('');
  const [loadedTime, setLoadedTime] = useState(() => new Date().toTimeString().slice(0, 5));
  const [token, setToken] = useState(null);     // the token this expense came from
  useEffect(() => {
    if (!branch) return;
    supabase.from('power_meters').select('id, name, status').eq('branch_id', branch).eq('status', 'active').order('name')
      .then(({ data, error: err }) => { if (!err) { setMeters(data || []); if ((data || []).length === 1) setMeterId(data[0].id); } });
  }, [branch]);
  useEffect(() => {
    if (!expense?.id) return;
    supabase.from('power_tokens').select('*').eq('expense_id', expense.id).maybeSingle().then(({ data }) => setToken(data || null));
  }, [expense?.id]);

  // The payment date follows the expense date until the user sets it
  useEffect(() => { if (!paidOnSet) setPaidOn(date); }, [date, paidOnSet]);

  const rate = vatRateOf(branch);
  const computed = num(qty) != null && num(price) != null ? round2(num(qty) * num(price)) : null;
  const total = computed ?? num(amount);
  const vat = vatShown && total != null ? round2(total * rate / (100 + rate)) : null;
  const activeCats = categories.filter(c => c.status === 'active' || c.id === expense?.category_id);
  const isElectricity = isNew && meters.length > 0 && /^\s*electricity\s*$/i.test(categories.find(c => c.id === category)?.name ?? '');
  const activeSuppliers = suppliers.filter(s => s.status === 'active' || s.id === expense?.supplier_id);

  async function save(e) {
    e.preventDefault();
    setError('');
    if (!branch) { setError('Choose the branch.'); return; }
    if (!category) { setError('Choose the category.'); return; }
    if (isElectricity) {
      if (!meterId) { setError('Choose the meter the token went on.'); return; }
      if (!(num(qty) > 0)) { setError('Enter the units bought.'); return; }
      if (total == null || !(total >= 0)) { setError('Enter what was paid.'); return; }
      setBusy(true);
      const { error: err } = await supabase.rpc('record_power_token', { p: {
        meter_id: meterId, units: num(qty), amount: total, loaded_at: new Date(`${date}T${loadedTime || '12:00'}`).toISOString(),
        token_no: notes.trim() || null, paid_from: method.trim() || 'cash' } });
      setBusy(false);
      if (err) { setError(dbErrorMessage(err, "We couldn't save this token. Please try again.")); return; }
      onSaved();
      return;
    }
    if (!what.trim()) { setError('Say what was bought or paid for.'); return; }
    if (num(qty) != null && !(num(qty) > 0)) { setError('Quantity must be above zero, or leave it blank.'); return; }
    if (total == null || !(total >= 0)) { setError('Enter the amount, or the quantity and price.'); return; }
    if ((num(paid) ?? 0) > total) { setError('Paid is more than the amount.'); return; }
    if (supplierId === '__new' && !newSupplier.trim()) { setError("Type the new supplier's name, or choose none."); return; }
    const p = {
      branch_id: branch, expense_date: date, category_id: category, description: what.trim(),
      quantity: num(qty), unit_price: num(qty) != null ? num(price) : null, amount: total,
      ...(supplierId === '__new' ? { new_supplier_name: newSupplier.trim() } : supplierId ? { supplier_id: supplierId } : {}),
      vat_amount: vat, amount_paid: num(paid) ?? 0, payment_method: method.trim() || null,
      paid_on: num(paid) > 0 ? paidOn || null : null, notes: notes.trim() || null,
    };
    setBusy(true);
    const { error: err } = isNew
      ? await supabase.rpc('record_expense', { p })
      : await supabase.rpc('update_expense', { p_id: expense.id, p });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't save this expense. Please try again.")); return; }
    onSaved();
  }

  async function voidIt() {
    setError('');
    if (!voidReason.trim()) { setError('Give a reason.'); return; }
    setBusy(true);
    const { error: err } = token
      ? await supabase.rpc('void_power_token', { p_id: token.id, p_reason: voidReason.trim() })   // voids its expense too
      : await supabase.rpc('void_expense', { p_id: expense.id, p_reason: voidReason.trim() });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err)); return; }
    onSaved();
  }

  return (
    <Modal title={isNew ? 'Record expense' : 'Expense'} onClose={onClose} size="lg"
      footer={<>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="submit" form="expense-form" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy}>
          {isNew ? 'Record expense' : 'Save changes'}
        </button>
      </>}>
      <form id="expense-form" className="modal-form" onSubmit={save}>
        <p className="text-sm text-muted">Spending that is not stock — electricity (LUKU), water, office tools, equipment… It does not change stock or material costs.</p>
        <div className="form-row">
          {isNew && !branchId && (
            <div className="form-group">
              <label className="form-label" htmlFor="ex-branch">Branch</label>
              <select id="ex-branch" className="form-input" value={branch} onChange={e => setBranch(e.target.value)}>
                {myBranches.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
              </select>
            </div>
          )}
          <div className="form-group">
            <label className="form-label" htmlFor="ex-date">Date</label>
            <input id="ex-date" type="date" className="form-input" max={today} value={date} onChange={e => setDate(e.target.value)} />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="ex-cat">Category</label>
            <select id="ex-cat" className="form-input" value={category} onChange={e => setCategory(e.target.value)}>
              <option value="" disabled>Choose…</option>
              {activeCats.map(c => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </div>
        </div>
        {isElectricity && (
          <div className="form-row">
            <div className="form-group">
              <label className="form-label" htmlFor="ex-meter">LUKU meter</label>
              <select id="ex-meter" className="form-input" value={meterId} onChange={e => { setMeterId(e.target.value); if (!what.trim()) setWhat('LUKU token'); }}>
                <option value="" disabled>Choose…</option>{meters.map(m => <option key={m.id} value={m.id}>{m.name}</option>)}
              </select>
            </div>
            <div className="form-group">
              <label className="form-label" htmlFor="ex-time">Loaded at</label>
              <input id="ex-time" type="time" className="form-input" value={loadedTime} onChange={e => setLoadedTime(e.target.value)} />
              <span className="form-hint">Before the next meter reading.</span>
            </div>
          </div>
        )}
        {token && <div className="alert alert-info">LUKU token: {Number(token.units)} units on its meter. To change it, void it and enter it again.</div>}
        <div className="form-group">
          <label className="form-label" htmlFor="ex-what">What was it?</label>
          {/* typed each time: names of tools and items are not kept as a list */}
          <input id="ex-what" className="form-input" autoComplete="off" placeholder="e.g. LUKU token, hammer, printer paper"
            value={what} onChange={e => setWhat(e.target.value)} />
        </div>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="ex-qty">{isElectricity ? 'Units bought' : 'Quantity (optional)'}</label>
            <NumberInput id="ex-qty" step="any" min="0" className="form-input" placeholder="—" value={qty} onChange={e => setQty(e.target.value)} />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="ex-price">{isElectricity ? 'Price a unit (optional)' : 'Price each (optional)'}</label>
            <NumberInput id="ex-price" step="any" min="0" className="form-input" placeholder="—" value={price} onChange={e => setPrice(e.target.value)} />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="ex-amount">Amount</label>
            <NumberInput id="ex-amount" step="any" min="0" className="form-input" disabled={computed != null}
              value={computed != null ? String(computed) : amount} onChange={e => setAmount(e.target.value)} />
            {computed != null && <span className="form-hint">Quantity × price.</span>}
          </div>
        </div>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="ex-sup">Supplier (optional)</label>
            <select id="ex-sup" className="form-input" value={supplierId} onChange={e => setSupplierId(e.target.value)}>
              <option value="">None</option>
              {activeSuppliers.map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
              <option value="__new">New supplier…</option>
            </select>
            {supplierId === '__new' && (
              <input className="form-input mt-4" aria-label="New supplier name" placeholder="Supplier's name" value={newSupplier} onChange={e => setNewSupplier(e.target.value)} />
            )}
          </div>
          <div className="form-group">
            {(rate > 0 || vatShown) && (
              <>
                <label className="text-sm flex items-center gap-8">
                  <input type="checkbox" checked={vatShown} onChange={e => setVatShown(e.target.checked)} /> VAT ({rate}%) is included in the amount
                </label>
                {vatShown && total != null && <span className="form-hint">VAT: {money(vat)} = {money(total)} × {rate}/{100 + rate}</span>}
              </>
            )}
          </div>
        </div>
        <div className="form-row">
          <div className="form-group">
            <label className="form-label" htmlFor="ex-paid">Paid</label>
            <NumberInput id="ex-paid" step="any" min="0" className="form-input" placeholder="0 = not paid yet" value={paid} onChange={e => setPaid(e.target.value)} />
          </div>
          <div className="form-group">
            <label className="form-label" htmlFor="ex-method">How</label>
            <input id="ex-method" className="form-input" list="ex-methods" placeholder="e.g. Cash" value={method} onChange={e => setMethod(e.target.value)} />
            <datalist id="ex-methods">{PAYMENT_METHODS.map(m => <option key={m} value={m} />)}</datalist>
          </div>
          {num(paid) > 0 && (
            <div className="form-group">
              <label className="form-label" htmlFor="ex-paidon">Paid on</label>
              <input id="ex-paidon" type="date" className="form-input" max={today} value={paidOn}
                onChange={e => { setPaidOn(e.target.value); setPaidOnSet(true); }} />
            </div>
          )}
        </div>
        <div className="form-group">
          <label className="form-label" htmlFor="ex-notes">{isElectricity ? 'Token number (optional)' : 'Notes (optional)'}</label>
          <input id="ex-notes" className="form-input" value={notes} onChange={e => setNotes(e.target.value)} />
        </div>

        {!isNew && (
          <section>
            <h3 className="modal-section-title">Entered wrongly?</h3>
            {voiding ? (
              <div className="confirm-box">
                <p className="text-sm">Voiding keeps it on record, marked void.</p>
                <input className="form-input" placeholder="Reason" aria-label="Reason for voiding" value={voidReason} onChange={e => setVoidReason(e.target.value)} />
                <div className="flex gap-8">
                  <button type="button" className="btn btn-outline btn-sm" disabled={busy} onClick={voidIt}>Void expense</button>
                  <button type="button" className="btn btn-ghost btn-sm" onClick={() => setVoiding(false)}>Keep it</button>
                </div>
              </div>
            ) : (
              <button type="button" className="btn btn-ghost btn-sm" onClick={() => setVoiding(true)}>Void this expense…</button>
            )}
          </section>
        )}
      </form>
    </Modal>
  );
}
