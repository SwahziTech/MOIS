import { useEffect, useState } from 'react';
import { ArrowUp, ArrowDown } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';
import { roleLabel } from '../../lib/manageUsers';
import { ROLE_RANK } from '../../lib/menu';
import { DASHBOARD_TABS, defaultTabsFor } from '../../lib/dashboardTabs';

/*
 * Dashboard layout (116, 2026-11-10, the user) — Technical admin only: each role's dashboard
 * tabs, ticked and put in order. Each tab opens the real page; Overview carries all the
 * summaries. What a person can open on a tab still follows their permissions. Starts from
 * the role's built-in set; Reset goes back to it.
 */
export default function DashboardLayoutCard() {
  const [roles, setRoles] = useState([]);
  const [role, setRole] = useState('');
  const [saved, setSaved] = useState({});   // role → tabs as saved
  const [draft, setDraft] = useState([]);   // [{ key, on }] in order
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');

  async function load() {
    const [r, l] = await Promise.all([
      supabase.from('roles').select('name'),
      supabase.from('dashboard_layouts').select('role_name, tabs'),
    ]);
    if (l.error) { setSaved(false); return; }   // before 116
    const list = (r.data || []).map(x => x.name).sort((a, b) => (ROLE_RANK.indexOf(a) + 1 || 99) - (ROLE_RANK.indexOf(b) + 1 || 99));
    setRoles(list);
    setSaved(Object.fromEntries((l.data || []).map(x => [x.role_name, x.tabs])));
    if (!role && list[0]) setRole(list[0]);
  }
  useEffect(() => { load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => {
    if (!role || saved === false) return;
    const on = saved[role] ?? defaultTabsFor(role);
    setDraft([...on.map(k => ({ key: k, on: true })), ...DASHBOARD_TABS.filter(t => !on.includes(t.key)).map(t => ({ key: t.key, on: false }))]);
    setMsg('');
  }, [role, saved]);

  if (saved === false) return null;
  const move = (i, d) => setDraft(ds => { const n = [...ds]; [n[i], n[i + d]] = [n[i + d], n[i]]; return n; });
  async function save() {
    const tabs = draft.filter(x => x.on).map(x => x.key);
    if (!tabs.length) { setMsg('Keep at least one tab.'); return; }
    setBusy(true); setMsg('');
    const { error } = await supabase.rpc('set_dashboard_layout', { p_role: role, p_tabs: tabs });
    setBusy(false);
    if (error) { setMsg(dbErrorMessage(error)); return; }
    setMsg('Saved — it shows the next time they open the dashboard.');
    load();
  }
  async function reset() {
    setBusy(true); setMsg('');
    const { error } = await supabase.rpc('reset_dashboard_layout', { p_role: role });
    setBusy(false);
    if (error) { setMsg(dbErrorMessage(error)); return; }
    setMsg('Back to the built-in tabs.');
    load();
  }
  return (
    <div className="card">
      <div className="card-header"><h2 className="card-title">Dashboard layout</h2></div>
      <div className="card-body">
        <p className="pl-help" style={{ marginTop: 0 }}>Each role's dashboard tabs, in order. A tab opens the real page; Overview carries all the summaries.</p>
        <div className="flex items-center gap-8" style={{ marginBottom: 10, flexWrap: 'wrap' }}>
          <select className="form-input" style={{ maxWidth: 220 }} aria-label="Role" value={role} onChange={e => setRole(e.target.value)}>
            {roles.map(r => <option key={r} value={r}>{roleLabel(r)}</option>)}
          </select>
          <span className="pl-help">{saved[role] ? 'Arranged' : 'Built-in tabs'}</span>
        </div>
        <ul className="dl-list">
          {draft.map((x, i) => {
            const t = DASHBOARD_TABS.find(y => y.key === x.key);
            return (
              <li key={x.key} className={x.on ? '' : 'is-off'}>
                <label><input type="checkbox" checked={x.on} onChange={e => setDraft(ds => ds.map((y, j) => (j === i ? { ...y, on: e.target.checked } : y)))} /> <strong>{t?.label ?? x.key}</strong>
                  {t?.note && <span className="pl-help"> · {t.note}</span>}</label>
                <span>
                  <button type="button" className="icon-btn" aria-label="Up" disabled={i === 0} onClick={() => move(i, -1)}><ArrowUp size={14} /></button>
                  <button type="button" className="icon-btn" aria-label="Down" disabled={i === draft.length - 1} onClick={() => move(i, 1)}><ArrowDown size={14} /></button>
                </span>
              </li>
            );
          })}
        </ul>
        <div className="flex items-center gap-8" style={{ marginTop: 10 }}>
          {msg && <span className="pl-help">{msg}</span>}
          <button type="button" className="btn btn-ghost btn-sm" style={{ marginLeft: 'auto' }} disabled={busy || !saved[role]} onClick={reset}>Reset</button>
          <button type="button" className={`btn btn-primary btn-sm${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>Save</button>
        </div>
      </div>
    </div>
  );
}
