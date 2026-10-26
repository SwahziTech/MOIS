import { useEffect, useState } from 'react';
import { Plus } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { useBranch } from '../../hooks/useBranch';
import { dbErrorMessage } from '../../lib/masterData';
import Modal from '../Modal';

const KINDS = { cash: 'Cash', bank: 'Bank', mobile_money: 'Mobile money' };

/**
 * Sales settings (behind the ⚙ on the Sales page): the accounts each branch
 * takes money into (067) — the cash box, bank accounts, mobile money lines,
 * including ones held by staff. Managers add, rename, order and retire them;
 * each becomes a column in the sales book.
 */
export default function SalesSettings({ onClose }) {
  const { organization, canAt } = useAuth();
  const { branchId, branches } = useBranch();
  const [branch, setBranch] = useState(branchId || branches[0]?.id || '');
  const [rows, setRows] = useState(null);
  const [name, setName] = useState('');
  const [kind, setKind] = useState('bank');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const canEdit = branch && canAt('sales.discount', branch, null);

  async function load() {
    const { data, error: err } = await supabase.from('payment_accounts').select('*').eq('branch_id', branch).order('display_order').order('name');
    setRows(err ? [] : data || []);
  }
  useEffect(() => { if (branch) load(); }, [branch]); // eslint-disable-line react-hooks/exhaustive-deps

  async function run(q) {
    setError(''); setBusy(true);
    const { error: err } = await q;
    setBusy(false);
    if (err) { setError(err.code === '23505' ? 'That account is already on the list.' : dbErrorMessage(err)); return false; }
    await load();
    return true;
  }
  const move = (a, dir) => {
    const list = [...rows]; const i = list.indexOf(a); const j = i + dir;
    if (j < 0 || j >= list.length) return;
    [list[i], list[j]] = [list[j], list[i]];
    run(Promise.all(list.map((x, k) => supabase.from('payment_accounts').update({ display_order: k + 1 }).eq('id', x.id))).then(rs => rs.find(x => x.error) ?? { error: null }));
  };

  return (
    <Modal title="Sales settings" onClose={onClose} size="lg" footer={<button type="button" className="btn btn-outline" onClick={onClose}>Close</button>}>
      <section className="card">
        <div className="card-header" style={{ gap: 8 }}>
          <h2 className="card-title">Receiving accounts</h2>
          {branches.length > 1 && (
            <select className="form-input" style={{ maxWidth: 170, marginLeft: 'auto' }} aria-label="Branch" value={branch} onChange={e => setBranch(e.target.value)}>
              {branches.map(b => <option key={b.id} value={b.id}>{b.name}</option>)}
            </select>
          )}
        </div>
        <div className="card-body" style={{ paddingTop: 6 }}>
          <p className="text-xs text-muted mb-8">Where customers' money goes — each payment names one, and each is a column in the sales book. Retired accounts stay on past payments.</p>
          {rows === null ? <p className="pl-help">Loading…</p> : rows.length === 0 ? <p className="pl-help">No accounts yet.</p> : rows.map((a, i) => (
            <div key={a.id} className="ptc-head" style={{ padding: '6px 0', borderBottom: '1px solid var(--border)' }}>
              <strong className={a.status !== 'active' ? 'text-muted' : ''}>{a.name}</strong>
              <span className="pl-help">{KINDS[a.kind]}{a.status !== 'active' ? ' · retired' : ''}</span>
              {canEdit && <span className="ptc-actions">
                <button type="button" className="btn btn-ghost btn-sm" disabled={busy || i === 0} onClick={() => move(a, -1)} aria-label="Move up">↑</button>
                <button type="button" className="btn btn-ghost btn-sm" disabled={busy || i === rows.length - 1} onClick={() => move(a, 1)} aria-label="Move down">↓</button>
                <button type="button" className="btn btn-ghost btn-sm" disabled={busy}
                  onClick={() => { const n = window.prompt('Rename the account', a.name); if (n && n.trim() && n.trim() !== a.name) run(supabase.from('payment_accounts').update({ name: n.trim() }).eq('id', a.id)); }}>Rename</button>
                <button type="button" className="btn btn-ghost btn-sm" disabled={busy}
                  onClick={() => run(supabase.from('payment_accounts').update({ status: a.status === 'active' ? 'inactive' : 'active' }).eq('id', a.id))}>{a.status === 'active' ? 'Retire' : 'Bring back'}</button>
              </span>}
            </div>
          ))}
          {canEdit && (
            <div className="flex items-center gap-8 mt-8" style={{ flexWrap: 'wrap' }}>
              <input className="form-input" style={{ maxWidth: 240 }} placeholder="e.g. Bank — company account" value={name} onChange={e => setName(e.target.value)} />
              <select className="form-input" style={{ width: 'auto' }} value={kind} onChange={e => setKind(e.target.value)}>
                {Object.entries(KINDS).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select>
              <button type="button" className="btn btn-outline btn-sm" disabled={busy || !name.trim()}
                onClick={async () => { if (await run(supabase.from('payment_accounts').insert({ organization_id: organization.id, branch_id: branch, name: name.trim(), kind, display_order: (rows?.length ?? 0) + 1 }))) setName(''); }}>
                <Plus size={13} /> Add account</button>
            </div>
          )}
          {!canEdit && <p className="pl-help">A manager adds and changes accounts.</p>}
          {error && <p className="text-xs text-error">{error}</p>}
        </div>
      </section>
    </Modal>
  );
}
