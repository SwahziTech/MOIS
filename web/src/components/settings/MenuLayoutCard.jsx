import { useEffect, useState } from 'react';
import { ArrowUp, ArrowDown, Plus, X } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';
import { roleLabel } from '../../lib/manageUsers';
import { ROLE_RANK, resolveMenu } from '../../lib/menu';
import { NAV } from '../Sidebar';

/*
 * Menu layout (migration 098, 2026-10-30) — Technical admin only: the sidebar
 * for each role. Sections in order (rename, add, ungroup, fold), pages moved
 * up and down or into another section. The same page names everywhere; what
 * a person can open still follows their permissions (pages a role can't open
 * are marked). Starts from the current sidebar; Reset goes back to it.
 */
export default function MenuLayoutCard() {
  const [roles, setRoles] = useState([]);
  const [role, setRole] = useState('');
  const [saved, setSaved] = useState({});      // role → layout as saved
  const [draft, setDraft] = useState(null);    // { sections: [{ title, folded, items: [path] }] }
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState('');

  async function load() {
    const [r, l] = await Promise.all([
      supabase.from('roles').select('name, is_system_role, role_permissions(permission:permissions(code))'),
      supabase.from('menu_layouts').select('role_name, layout'),
    ]);
    if (l.error) { setSaved(false); return; }   // before 098
    const list = (r.data || []).sort((a, b) => (ROLE_RANK.indexOf(a.name) + 1 || 99) - (ROLE_RANK.indexOf(b.name) + 1 || 99));
    setRoles(list);
    setSaved(Object.fromEntries((l.data || []).map(x => [x.role_name, x.layout])));
    if (!role && list[0]) setRole(list[0].name);
  }
  useEffect(() => { load(); }, []); // eslint-disable-line react-hooks/exhaustive-deps
  // the role's layout as it stands (saved, else the current sidebar) — pages it doesn't mention filled in
  useEffect(() => {
    if (!role || saved === false) return;
    const resolved = resolveMenu(NAV, saved[role]);
    setDraft({ sections: resolved.map(s => ({ title: s.title, folded: s.folded, items: s.items.map(i => i.to) })) });
    setMsg('');
  }, [role, saved]);

  if (saved === false) return null;
  const byPath = Object.fromEntries(NAV.flatMap(s => s.items).map(i => [i.to, i]));
  const perms = new Set((roles.find(r => r.name === role)?.role_permissions || []).map(rp => rp.permission?.code));
  const canOpen = p => !byPath[p]?.perm || perms.has(byPath[p].perm) || role === 'owner';
  const set = sections => setDraft({ sections });
  const S = draft?.sections || [];
  const moveSection = (i, d) => { const s = [...S]; const j = i + d; if (j < 0 || j >= s.length) return; [s[i], s[j]] = [s[j], s[i]]; set(s); };
  const patchSection = (i, patch) => set(S.map((x, k) => (k === i ? { ...x, ...patch } : x)));
  const moveItem = (si, ii, d) => { const items = [...S[si].items]; const j = ii + d; if (j < 0 || j >= items.length) return; [items[ii], items[j]] = [items[j], items[ii]]; patchSection(si, { items }); };
  const moveTo = (si, ii, target) => {
    const p = S[si].items[ii];
    set(S.map((x, k) => (k === si ? { ...x, items: x.items.filter((_, n) => n !== ii) } : k === target ? { ...x, items: [...x.items, p] } : x)));
  };
  const removeSection = i => {   // its pages go to the section above (or below)
    const into = i > 0 ? i - 1 : 1;
    set(S.map((x, k) => (k === into ? { ...x, items: [...x.items, ...S[i].items] } : x)).filter((_, k) => k !== i));
  };
  async function save() {
    setMsg(''); setBusy(true);
    const { error } = await supabase.rpc('set_menu_layout', { p_role: role, p_layout: { sections: S.filter(s => s.items.length || s.title) } });
    setBusy(false);
    if (error) { setMsg(dbErrorMessage(error)); return; }
    window.dispatchEvent(new Event('mois:menu-changed'));
    await load(); setMsg(`Saved — everyone with the ${roleLabel(role)} role sees it now.`);
  }
  async function reset() {
    setMsg(''); setBusy(true);
    const { error } = await supabase.rpc('reset_menu_layout', { p_role: role });
    setBusy(false);
    if (error) { setMsg(dbErrorMessage(error)); return; }
    window.dispatchEvent(new Event('mois:menu-changed'));
    await load(); setMsg('Back to the standard sidebar for this role.');
  }

  return (
    <section className="card">
      <div className="card-header" style={{ gap: 8, flexWrap: 'wrap' }}>
        <h2 className="card-title">Menu layout</h2>
        <select className="form-input" style={{ maxWidth: 200, marginLeft: 'auto' }} aria-label="Role" value={role} onChange={e => setRole(e.target.value)}>
          {roles.map(r => <option key={r.name} value={r.name}>{roleLabel(r.name)}{saved[r.name] ? ' · arranged' : ''}</option>)}
        </select>
      </div>
      <div className="card-body" style={{ paddingTop: 6 }}>
        <p className="text-xs text-muted mb-8">
          The sidebar for everyone with this role: sections in order, pages in them. Same page names everywhere; a person still only sees the pages they're allowed to open
          (<span className="text-warning">marked</span> when this role can't). A section with no name shows its pages without a heading. A folded section opens with a click.
          Someone with several roles sees the layout of the highest.
        </p>
        <div className="ml-sections">
          {S.map((sec, si) => (
            <div key={si} className="ml-section">
              <div className="ml-sec-head">
                <input className="form-input" style={{ maxWidth: 220 }} placeholder="(no heading)" aria-label="Section name" value={sec.title} onChange={e => patchSection(si, { title: e.target.value })} />
                <label className="text-sm flex items-center gap-8"><input type="checkbox" checked={!!sec.folded} disabled={!sec.title} onChange={e => patchSection(si, { folded: e.target.checked })} /> folded</label>
                <span className="ml-actions">
                  <button type="button" className="btn btn-ghost btn-sm" aria-label="Section up" disabled={si === 0} onClick={() => moveSection(si, -1)}><ArrowUp size={13} /></button>
                  <button type="button" className="btn btn-ghost btn-sm" aria-label="Section down" disabled={si === S.length - 1} onClick={() => moveSection(si, 1)}><ArrowDown size={13} /></button>
                  {sec.title && <button type="button" className="btn btn-ghost btn-sm" title="Keep the pages, drop the heading" onClick={() => patchSection(si, { title: '', folded: false })}>Ungroup</button>}
                  {S.length > 1 && <button type="button" className="btn btn-ghost btn-sm" title="Remove the section — its pages move to the one above" aria-label="Remove section" onClick={() => removeSection(si)}><X size={13} /></button>}
                </span>
              </div>
              {sec.items.length === 0 && <p className="pl-help" style={{ margin: '4px 0 0 4px' }}>No pages — move some here, or remove the section.</p>}
              {sec.items.map((p, ii) => (
                <div key={p} className="ml-item">
                  <span className={canOpen(p) ? '' : 'text-warning'} title={canOpen(p) ? undefined : "This role can't open it — hidden for them"}>{byPath[p]?.label ?? p}</span>
                  <span className="ml-actions">
                    <button type="button" className="btn btn-ghost btn-sm" aria-label="Page up" disabled={ii === 0} onClick={() => moveItem(si, ii, -1)}><ArrowUp size={12} /></button>
                    <button type="button" className="btn btn-ghost btn-sm" aria-label="Page down" disabled={ii === sec.items.length - 1} onClick={() => moveItem(si, ii, 1)}><ArrowDown size={12} /></button>
                    <select className="form-input ml-move" aria-label={`Move ${byPath[p]?.label} to`} value="" onChange={e => e.target.value !== '' && moveTo(si, ii, Number(e.target.value))}>
                      <option value="">Move to…</option>
                      {S.map((t, ti) => ti !== si && <option key={ti} value={ti}>{t.title || `(no heading, ${ti + 1})`}</option>)}
                    </select>
                  </span>
                </div>
              ))}
            </div>
          ))}
        </div>
        <div className="flex items-center gap-8" style={{ marginTop: 10, flexWrap: 'wrap' }}>
          <button type="button" className="btn btn-outline btn-sm" onClick={() => set([...S, { title: 'New section', folded: false, items: [] }])}><Plus size={13} /> Section</button>
          <button type="button" className="btn btn-primary btn-sm" disabled={busy || !role} onClick={save}>Save for {roleLabel(role)}</button>
          {saved[role] && <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={reset}>Reset to standard</button>}
          {msg && <span className="pl-help">{msg}</span>}
        </div>
      </div>
    </section>
  );
}


