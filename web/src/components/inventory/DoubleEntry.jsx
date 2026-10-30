import { useEffect, useState } from 'react';
import { AlertTriangle } from 'lucide-react';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { dbErrorMessage } from '../../lib/masterData';
import { warehouseLabel, qtyText, itemKey } from '../../lib/inventory';
import { findOpeningDuplicates, planOpeningFix, runSteps, closeDoubleEntry } from '../../lib/doubleEntry';
import Modal from '../Modal';
import NumberInput from '../NumberInput';
import { dateText } from '../../lib/format';

// The store an item usually belongs in: products in a finished-goods store, materials elsewhere
export const fitsStore = (item, w) => !!item && !!w && (item.kind === 'product') === (w.type === 'finished_goods');

/**
 * Stock page: items whose opening balance was entered more than once at a
 * branch, with a button to sort each one out.
 */
export function DoubleEntryAlert({ refs, reloadKey, onFixed }) {
  const { canAt } = useAuth();
  const { inBranch } = useBranch();
  const [dups, setDups] = useState([]);
  const [fixing, setFixing] = useState(null);

  useEffect(() => {
    let live = true;
    findOpeningDuplicates().then(d => { if (live) setDups(d); }).catch(err => console.error(err));
    return () => { live = false; };
  }, [reloadKey]);

  const whById = Object.fromEntries(refs.warehouses.map(w => [w.id, w]));
  const shown = dups.filter(d => inBranch(d.branchId) && refs.items[itemKey(d.entries[0])]);
  if (!shown.length) return null;

  return (<>
    <div className="alert alert-warning mb-16" role="alert">
      <div className="flex items-center gap-8"><AlertTriangle size={15} /><strong>Possible double entry</strong></div>
      <ul className="double-entry-list">
        {shown.map(d => {
          const item = refs.items[itemKey(d.entries[0])];
          const colour = refs.colorById[d.entries[0].color_id]?.name;
          const sym = refs.unitById[item.stockUnitId]?.symbol ?? '';
          const canFix = canAt('inventory.adjust', d.branchId, null);
          return (
            <li key={d.key}>
              <span>
                <strong>{item.name}{colour ? ` (${colour})` : ''}</strong> has {d.entries.length} opening balances:{' '}
                {d.entries.map(e => `${qtyText(e.quantity)} ${sym} in ${whById[e.warehouse_id]?.name ?? 'a store'}`).join(' and ')}.
              </span>
              {canFix
                ? <button type="button" className="btn btn-outline btn-sm" onClick={() => setFixing(d)}>Sort it out…</button>
                : <span className="text-xs">Ask the branch manager to sort it out.</span>}
            </li>
          );
        })}
      </ul>
    </div>
      {fixing && (
        <FixOpeningModal dup={fixing} refs={refs} whById={whById}
          onClose={() => setFixing(null)} onFixed={() => { setFixing(null); onFixed(); }} />
      )}
  </>);
}

function FixOpeningModal({ dup, refs, whById, onClose, onFixed }) {
  const { canManage, organization } = useAuth();
  const { entries, branchId } = dup;
  const item = refs.items[itemKey(entries[0])];
  const colorId = entries[0].color_id;
  const sym = refs.unitById[item.stockUnitId]?.symbol ?? '';
  const total = entries.reduce((s, e) => s + Number(e.quantity), 0);
  const stores = refs.warehouses.filter(w => w.branch_id === branchId && w.status === 'active');
  // "Add them up" goes to a store that suits the item, preferring one that already has an entry
  const sumStore = entries.find(e => fitsStore(item, whById[e.warehouse_id]))?.warehouse_id
    ?? stores.find(w => fitsStore(item, w))?.id ?? entries[0].warehouse_id;
  const [choice, setChoice] = useState('');
  const [customQty, setCustomQty] = useState('');
  const [customWh, setCustomWh] = useState(sumStore);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [sent, setSent] = useState(null);
  const viaApproval = !canManage('inventory.adjust');
  const store = id => whById[id]?.name ?? 'a store';

  const target = choice.startsWith('keep:') ? (e => ({ qty: Number(e.quantity), warehouseId: e.warehouse_id }))(entries.find(e => e.id === choice.slice(5)))
    : choice === 'sum' ? { qty: total, warehouseId: sumStore }
    : choice === 'custom' ? { qty: Number(customQty), warehouseId: customWh }
    : null;
  const reason = target ? `${item.name}'s opening balance was entered ${entries.length === 2 ? 'twice' : `${entries.length} times`} — kept ${qtyText(target.qty)} ${sym} in ${store(target.warehouseId)}` : '';
  const steps = target && Number.isFinite(target.qty) && target.qty >= 0
    ? planOpeningFix({ entries, item, colorId, target: { ...target, unitSymbol: sym }, whById, reason }) : [];

  async function apply() {
    setError('');
    if (!choice) { setError('Choose what is right.'); return; }
    if (choice === 'custom' && (customQty === '' || !(Number(customQty) >= 0))) { setError('Enter the correct quantity (zero or more).'); return; }
    setBusy(true);
    try {
      if (choice === 'both') {
        const { error: err } = await closeDoubleEntry({ organizationId: organization.id, entries, status: 'dismissed',
          reason: `${item.name}: ${entries.length} opening balances at one branch`, note: 'Both are right: separate stock in each store' });
        if (err) throw err;
        onFixed();
        return;
      }
      const res = await runSteps(steps, viaApproval);
      // Looked at: don't raise it again (an adjusted-away entry still exists in the ledger)
      await closeDoubleEntry({ organizationId: organization.id, entries, status: 'resolved',
        reason: `${item.name}: ${entries.length} opening balances at one branch`, note: reason });
      if (res.sent) setSent(res.sent); else onFixed();
    } catch (err) {
      setError(dbErrorMessage(err, "We couldn't make this correction. Please try again."));
    }
    setBusy(false);
  }

  if (sent) {
    return (
      <Modal title="Sent for approval" onClose={onFixed}
        footer={<button type="button" className="btn btn-primary" onClick={onFixed}>Done</button>}>
        <p className="text-sm">{sent === 1 ? 'The correction was' : `${sent} corrections were`} sent for an admin's approval. Stock changes once approved — follow it under <strong>Approvals</strong>.</p>
      </Modal>
    );
  }

  // A plain function, not a component: the quantity box inside must keep focus while typing
  const option = (value, children) => (
    <label key={value} className={`double-entry-option${choice === value ? ' is-on' : ''}`}>
      <input type="radio" name="dup-choice" value={value} checked={choice === value} onChange={() => setChoice(value)} />
      <span>{children}</span>
    </label>
  );

  return (
    <Modal title={`${item.name} — opening balance entered twice`} onClose={onClose}
      footer={<>
        <button type="button" className="btn btn-outline" onClick={onClose}>Cancel</button>
        <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy || !choice} onClick={apply}>
          {choice === 'both' ? 'Keep both' : viaApproval ? 'Submit for approval' : 'Correct it'}
        </button>
      </>}>
      <div className="modal-form">
        {error && <div className="alert alert-error" role="alert">{error}</div>}
        <ul className="text-sm double-entry-entries">
          {entries.map(e => (
            <li key={e.id}>
              <strong>{qtyText(e.quantity)} {sym}</strong> in {warehouseLabel(whById[e.warehouse_id])}, dated {dateText(e.transaction_date)}
              <span className="text-muted"> · entered {dateText(e.created_at)}</span>
              {!fitsStore(item, whById[e.warehouse_id]) && <span className="text-warning"> · {item.kind === 'material' ? 'a material in a finished-goods store' : 'a product outside the finished-goods store'}</span>}
            </li>
          ))}
        </ul>
        <div className="double-entry-options">
          <span className="form-label">What is right?</span>
          {entries.map(e => option(`keep:${e.id}`,
            <>Keep <strong>{qtyText(e.quantity)} {sym} in {store(e.warehouse_id)}</strong> — the other was entered by mistake</>))}
          {option('sum', <>Add them up: <strong>{qtyText(total)} {sym} in {store(sumStore)}</strong></>)}
          {option('custom', <>
            Another figure:
            <span className="double-entry-custom" onClick={() => setChoice('custom')}>
              <NumberInput step="any" min="0" className="form-input" aria-label="Correct quantity" placeholder="Qty" value={customQty} onChange={e => setCustomQty(e.target.value)} />
              <span>{sym} in</span>
              <select className="form-input" aria-label="Store" value={customWh} onChange={e => setCustomWh(e.target.value)}>
                {stores.map(w => <option key={w.id} value={w.id}>{w.name}</option>)}
              </select>
            </span>
          </>)}
          {option('both', 'Both are right — this is separate stock in each store')}
        </div>
        {steps.length > 0 && (
          <div className="confirm-box text-sm">
            <span className="form-label">{viaApproval ? 'Will be sent for approval' : 'Will be posted'}</span>
            <ul className="double-entry-entries">{steps.map((s, i) => <li key={i}>{s.summary}</li>)}</ul>
            <span className="text-xs text-muted">Nothing is deleted: the history keeps both entries and these corrections.</span>
          </div>
        )}
        {target && steps.length === 0 && choice !== 'both' && <p className="text-xs text-muted">Nothing to post.</p>}
      </div>
    </Modal>
  );
}
