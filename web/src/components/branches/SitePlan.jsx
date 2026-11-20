import { useEffect, useMemo, useRef, useState } from 'react';
import { Plus, Trash2, RotateCw, Route, Save, X } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { dbErrorMessage } from '../../lib/masterData';

/*
 * A branch's site plan (137, 2026-11-20, the user): its areas drawn on a
 * 680 × 500 plan, road at the top, with the lanes between them. Each tenant
 * draws its own; only the Technical admin edits (system.manage). A stock area
 * may be part of a store, and each product can have its home area there.
 */
const W = 680, H = 500;
export const AREA_KINDS = {
  making:   { label: 'Making',          color: '#7F77DD' },
  curing:   { label: 'Curing',          color: 'var(--color-warning)' },
  ready:    { label: 'Ready stock',     color: 'var(--color-success)' },
  material: { label: 'Material area',   color: 'var(--text-secondary)', open: true },
  building: { label: 'Building',        color: 'var(--color-mid-grey)' },
  gate:     { label: 'Gate',            color: 'var(--color-mid-grey)' },
  other:    { label: 'Other',           color: 'var(--color-mid-grey)' },
};
const LANES = { road: { label: 'Road', width: 6, dash: '14 8' }, main: { label: 'Main route', width: 2, dash: '6 5' }, lane: { label: 'Lane', width: 1.2, dash: '3 4' } };
const STOCK_KINDS = ['ready', 'curing', 'material'];
// a zone is a name and a text colour (2026-11-20, the user: the box keeps its kind's colour, the words show the zone)
export const ZONE_COLORS = { teal: '#1D9E75', blue: '#378ADD', coral: '#D85A30', purple: '#7F77DD', amber: '#BA7517', pink: '#D4537E', green: '#639922', gray: '#888780' };
let tmp = 0;
const keyOf = a => a.id ?? a.tmp;
const r1 = v => Math.round(v);

export default function SitePlan({ branch, stores, organizationId, canEdit }) {
  const svgRef = useRef(null);
  const [areas, setAreas] = useState(null);
  const [lanes, setLanes] = useState([]);
  const [homes, setHomes] = useState({});        // product id → area key
  const [zones, setZones] = useState([]);        // [{ id | tmp, name, color }]
  const [machines, setMachines] = useState([]);  // [{ id, name, zone }] — zone: a zone key; its products are kept there
  const [links, setLinks] = useState([]);        // machine_products of the branch's machines
  const [stock, setStock] = useState({});        // `${store}|${product}` → quantity on hand (all colours)
  const [unitOf, setUnitOf] = useState({});      // product id → its stock unit symbol
  const [products, setProducts] = useState([]);  // the branch's products [{ id, name }]
  const [sel, setSel] = useState(null);          // { type: 'area' | 'lane', key }
  const [drag, setDrag] = useState(null);
  const [drawing, setDrawing] = useState(null);  // { kind, points } while a lane is drawn
  const [newKind, setNewKind] = useState('ready');
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function load() {
    setError(''); setSel(null); setDrawing(null); setDirty(false);
    const [a, l, h, bp, z, m, mp] = await Promise.all([
      supabase.from('site_areas').select('*').eq('branch_id', branch.id).eq('status', 'active'),
      supabase.from('site_lanes').select('*').eq('branch_id', branch.id),
      supabase.from('product_home_areas').select('product_id, area_id').eq('branch_id', branch.id),
      supabase.from('branch_products').select('product_id, product:products(canonical_name)').eq('branch_id', branch.id).eq('status', 'active'),
      supabase.from('site_zones').select('*').eq('branch_id', branch.id).order('name'),
      supabase.from('machines').select('*').eq('branch_id', branch.id).eq('status', 'active').order('name'),
      supabase.from('machine_products').select('machine_id, product_id'),
    ]);
    // what is on hand in the branch's stores, to show on the plan (2026-11-20, the user)
    const ids = stores.map(w => w.id);
    const [sb, un] = await Promise.all([
      ids.length ? supabase.from('stock_balances').select('warehouse_id, product_id, quantity, stock_unit_id').in('warehouse_id', ids).not('product_id', 'is', null) : Promise.resolve({ data: [] }),
      supabase.from('units').select('id, symbol'),
    ]);
    const sym = Object.fromEntries((un.data || []).map(u => [u.id, u.symbol]));
    const st = {}, uo = {};
    for (const r of sb.data || []) { const k = `${r.warehouse_id}|${r.product_id}`; st[k] = (st[k] || 0) + Number(r.quantity); uo[r.product_id] = sym[r.stock_unit_id] ?? ''; }
    setStock(st); setUnitOf(uo);
    if (a.error) { setAreas([]); setError(['42P01', 'PGRST205'].includes(a.error.code) ? 'Site plans need migration 137 on the database.' : dbErrorMessage(a.error)); return; }
    setAreas((a.data || []).map(x => ({ ...x, x: +x.x, y: +x.y, w: +x.w, h: +x.h })));
    setLanes((l.data || []).map(x => ({ ...x, key: x.id })));
    setHomes(Object.fromEntries((h.data || []).map(x => [x.product_id, x.area_id])));
    setProducts((bp.data || []).map(x => ({ id: x.product_id, name: x.product?.canonical_name ?? '—' })).sort((p, q) => p.name.localeCompare(q.name)));
    setZones(z.data || []);
    setMachines((m.data || []).map(x => ({ id: x.id, name: x.name, zone: x.zone_id ?? '', was: x.zone_id ?? null })));
    setLinks(mp.data || []);
  }
  useEffect(() => { load(); }, [branch.id]); // eslint-disable-line react-hooks/exhaustive-deps

  const pt = e => { const s = svgRef.current; const p = s.createSVGPoint(); p.x = e.clientX; p.y = e.clientY; return p.matrixTransform(s.getScreenCTM().inverse()); };
  const change = fn => { setDirty(true); fn(); };
  const selArea = sel?.type === 'area' ? areas?.find(a => keyOf(a) === sel.key) : null;
  const setArea = patch => change(() => setAreas(as => as.map(a => (keyOf(a) === sel.key ? { ...a, ...patch } : a))));
  // drawn back to front: big areas first, so what sits inside them stays on top
  const ordered = useMemo(() => [...(areas || [])].sort((a, b) => b.w * b.h - a.w * a.h), [areas]);
  const homeCount = k => Object.values(homes).filter(v => v === k).length;
  const zoneColor = k => ZONE_COLORS[zones.find(z => keyOf(z) === k)?.color] ?? null;
  // where each product is kept: its home area's zone, else the zone of a machine it is made on (as product_zone() in 137)
  const zoneOfProduct = pid => {
    const home = homes[pid] && areas?.find(a => keyOf(a) === homes[pid]);
    if (home?.zone_id) return home.zone_id;
    return machines.find(m => m.zone && links.some(l => l.machine_id === m.id && l.product_id === pid))?.zone ?? null;
  };
  // the quantity of a product in an area's store, and what an area holds
  const qtyText = (v, pid) => `${(Math.round(v * 100) / 100).toLocaleString('en-US')} ${(unitOf[pid] || '').toUpperCase() === 'SQM' ? 'm²' : 'pcs'}`;
  const storeOfZone = zk => areas?.find(a => a.zone_id === zk && a.warehouse_id && a.kind === 'ready')?.warehouse_id ?? null;
  const contents = a => {
    if (!a.warehouse_id || !['ready', 'curing'].includes(a.kind)) return [];
    const list = a.kind === 'curing'
      ? products.filter(p => Math.abs(stock[`${a.warehouse_id}|${p.id}`] || 0) > 1e-9)   // curing: whatever is curing there now
      : products.filter(p => homes[p.id] === keyOf(a));
    return list.map(p => ({ ...p, qty: stock[`${a.warehouse_id}|${p.id}`] || 0 }));
  };
  const setZone = (k, patch) => change(() => setZones(zs => zs.map(z => (keyOf(z) === k ? { ...z, ...patch } : z))));

  function down(e, a) {
    if (!canEdit || drawing) return;
    e.stopPropagation();
    setSel({ type: 'area', key: keyOf(a) });
    const p = pt(e);
    setDrag({ mode: 'move', key: keyOf(a), dx: p.x - a.x, dy: p.y - a.y });
    svgRef.current.setPointerCapture(e.pointerId);
  }
  function move(e) {
    if (!drag) return;
    const p = pt(e);
    change(() => setAreas(as => as.map(a => {
      if (keyOf(a) !== drag.key) return a;
      return drag.mode === 'move'
        ? { ...a, x: r1(Math.max(0, Math.min(W - a.w, p.x - drag.dx))), y: r1(Math.max(0, Math.min(H - a.h, p.y - drag.dy))) }
        : { ...a, w: r1(Math.max(16, Math.min(W - a.x, drag.w + p.x - drag.ox))), h: r1(Math.max(14, Math.min(H - a.y, drag.h + p.y - drag.oy))) };
    })));
  }
  function backgroundDown(e) {
    if (drawing) { const p = pt(e); setDrawing(d => ({ ...d, points: [...d.points, [r1(p.x), r1(p.y)]] })); return; }
    setSel(null);
  }
  function finishLane() {
    if (drawing?.points.length >= 2) change(() => setLanes(ls => [...ls, { key: `t${++tmp}`, kind: drawing.kind, points: drawing.points }]));
    setDrawing(null);
  }
  function addArea() {
    const a = { tmp: `t${++tmp}`, name: AREA_KINDS[newKind].label, kind: newKind, warehouse_id: null, x: 300, y: 230, w: 90, h: 44 };
    change(() => setAreas(as => [...as, a]));
    setSel({ type: 'area', key: a.tmp });
  }
  function removeSel() {
    if (sel?.type === 'area') {
      change(() => { setAreas(as => as.filter(a => keyOf(a) !== sel.key)); setHomes(h => Object.fromEntries(Object.entries(h).filter(([, v]) => v !== sel.key))); });
    } else if (sel?.type === 'lane') change(() => setLanes(ls => ls.filter(l => l.key !== sel.key)));
    setSel(null);
  }

  async function save() {
    setError(''); setBusy(true);
    try {
      if (areas.some(a => !String(a.name || '').trim())) throw new Error('Every area needs a name.');
      if (zones.some(z => !String(z.name || '').trim())) throw new Error('Every zone needs a name.');
      // zones first, so areas and machines can point at them
      const zoneId = {};
      const { data: zBefore } = await supabase.from('site_zones').select('id').eq('branch_id', branch.id);
      const zKeep = new Set(zones.filter(z => z.id).map(z => z.id));
      const zGone = (zBefore || []).map(x => x.id).filter(id => !zKeep.has(id));
      if (zGone.length) { const r = await supabase.from('site_zones').delete().in('id', zGone); if (r.error) throw r.error; }
      for (const z of zones) {
        const row = { name: z.name.trim(), color: z.color };
        if (z.id) { const r = await supabase.from('site_zones').update(row).eq('id', z.id); if (r.error) throw r.error; zoneId[z.id] = z.id; }
        else { const r = await supabase.from('site_zones').insert({ ...row, organization_id: organizationId, branch_id: branch.id }).select('id').single(); if (r.error) throw r.error; zoneId[z.tmp] = r.data.id; }
      }
      const { data: before } = await supabase.from('site_areas').select('id').eq('branch_id', branch.id);
      const keep = new Set(areas.filter(a => a.id).map(a => a.id));
      const gone = (before || []).map(x => x.id).filter(id => !keep.has(id));
      if (gone.length) { const r = await supabase.from('site_areas').delete().in('id', gone); if (r.error) throw r.error; }
      const idOf = {};
      for (const a of areas) {
        const row = { name: a.name.trim(), kind: a.kind, warehouse_id: STOCK_KINDS.includes(a.kind) ? a.warehouse_id || null : null, zone_id: a.zone_id ? zoneId[a.zone_id] ?? null : null, x: a.x, y: a.y, w: a.w, h: a.h, parent_id: null };
        if (a.id) { const r = await supabase.from('site_areas').update(row).eq('id', a.id); if (r.error) throw r.error; idOf[a.id] = a.id; }
        else {
          const r = await supabase.from('site_areas').insert({ ...row, organization_id: organizationId, branch_id: branch.id }).select('id').single();
          if (r.error) throw r.error; idOf[a.tmp] = r.data.id;
        }
      }
      // what an area is drawn inside: the smallest area around it (a machine in its building)
      for (const a of areas) {
        const box = areas.filter(b => b !== a && b.w * b.h > a.w * a.h && b.x <= a.x && b.y <= a.y && b.x + b.w >= a.x + a.w && b.y + b.h >= a.y + a.h)
          .sort((p, q) => p.w * p.h - q.w * q.h)[0];
        if (box) { const r = await supabase.from('site_areas').update({ parent_id: idOf[keyOf(box)] }).eq('id', idOf[keyOf(a)]); if (r.error) throw r.error; }
      }
      for (const m of machines) {
        const z = m.zone ? zoneId[m.zone] ?? null : null;
        if (z === m.was) continue;   // only the machines whose zone changed
        const r = await supabase.from('machines').update({ zone_id: z }).eq('id', m.id); if (r.error) throw r.error;
      }
      let r = await supabase.from('site_lanes').delete().eq('branch_id', branch.id); if (r.error) throw r.error;
      if (lanes.length) { r = await supabase.from('site_lanes').insert(lanes.map(l => ({ organization_id: organizationId, branch_id: branch.id, kind: l.kind, points: l.points }))); if (r.error) throw r.error; }
      r = await supabase.from('product_home_areas').delete().eq('branch_id', branch.id); if (r.error) throw r.error;
      const hs = Object.entries(homes).filter(([, k]) => idOf[k]).map(([pid, k]) => ({ organization_id: organizationId, branch_id: branch.id, product_id: pid, area_id: idOf[k] }));
      if (hs.length) { r = await supabase.from('product_home_areas').insert(hs); if (r.error) throw r.error; }
      await load();
    } catch (e) {
      setError(e.message && !e.code ? e.message : dbErrorMessage(e, "We couldn't save the plan. Please try again."));
    } finally { setBusy(false); }
  }

  if (areas === null) return <p className="text-sm text-muted">Loading the plan…</p>;
  const storeName = id => stores.find(w => w.id === id)?.name;
  const productsHere = k => products.filter(p => homes[p.id] === k);

  return (
    <div className="sp">
      {error && <div className="alert alert-error" role="alert">{error}</div>}
      {!areas.length && !canEdit && <p className="text-sm text-muted">No site plan drawn for {branch.name} yet.</p>}
      {(areas.length > 0 || canEdit) && (
        <svg ref={svgRef} className={`sp-svg${drawing ? ' is-drawing' : ''}`} viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`Site plan of ${branch.name}`}
          onPointerMove={move} onPointerUp={() => setDrag(null)} onPointerDown={backgroundDown}>
          <rect x="0" y="0" width={W} height={H} className="sp-ground" />
          {lanes.map(l => (
            <polyline key={l.key} points={l.points.map(p => p.join(',')).join(' ')} fill="none" className={`sp-lane${sel?.key === l.key ? ' is-sel' : ''}`}
              strokeWidth={LANES[l.kind].width} strokeDasharray={LANES[l.kind].dash}
              onPointerDown={e => { if (!canEdit || drawing) return; e.stopPropagation(); setSel({ type: 'lane', key: l.key }); }} />
          ))}
          {ordered.map(a => {
            const k = AREA_KINDS[a.kind];
            const on = sel?.key === keyOf(a);
            // a thin, tall area (a wall strip, a gate) writes its name sideways; a tight one writes it smaller
            const upright = a.h > a.w * 2 && a.w < 40;
            const small = upright || a.w < 70 || a.h < 30 || a.name.length * 7 > a.w - 6;
            const cx = a.x + a.w / 2, cy = a.y + a.h / 2;
            const held = contents(a).filter(p => p.qty > 1e-9);
            const showHeld = held.length > 0 && !upright && a.h >= 34 && a.w >= 50;
            return (
              <g key={keyOf(a)} className={`sp-area${canEdit ? ' can-edit' : ''}`} onPointerDown={e => { if (drawing) return; e.stopPropagation(); if (canEdit) down(e, a); else setSel({ type: 'area', key: keyOf(a) }); }}>
                <title>{`${a.name} · ${k.label}${a.warehouse_id ? ` · ${storeName(a.warehouse_id) ?? ''}` : ''}${held.length ? `\n${held.map(p => `${p.name}: ${qtyText(p.qty, p.id)}`).join('\n')}` : ''}`}</title>
                <rect x={a.x} y={a.y} width={a.w} height={a.h} rx="4"
                  style={{ fill: k.open ? 'transparent' : `color-mix(in srgb, ${k.color} 22%, var(--bg-surface))`, stroke: k.color }}
                  strokeWidth={on ? 2.5 : 1} strokeDasharray={k.open ? '5 3' : undefined} />
                {showHeld && <text x={cx} y={cy + 12} textAnchor="middle" dominantBaseline="central" className="sp-held">{held.length} product{held.length === 1 ? '' : 's'} on hand</text>}
                <text x={cx} y={showHeld ? cy - 6 : cy} textAnchor="middle" dominantBaseline="central" className={`sp-label${small ? ' is-small' : ''}`} transform={upright ? `rotate(-90 ${cx} ${cy})` : undefined}
                  style={zoneColor(a.zone_id) ? { fill: zoneColor(a.zone_id) } : undefined}>{a.name}</text>
              </g>
            );
          })}
          {drawing && drawing.points.length > 0 && <polyline points={drawing.points.map(p => p.join(',')).join(' ')} fill="none" className="sp-lane is-sel" strokeWidth="2" strokeDasharray="4 3" />}
          {canEdit && selArea && <rect className="sp-handle" x={selArea.x + selArea.w - 6} y={selArea.y + selArea.h - 6} width="12" height="12" rx="2"
            onPointerDown={e => { e.stopPropagation(); const p = pt(e); setDrag({ mode: 'size', key: sel.key, ox: p.x, oy: p.y, w: selArea.w, h: selArea.h }); svgRef.current.setPointerCapture(e.pointerId); }} />}
        </svg>
      )}

      <div className="sp-legend">
        {Object.entries(AREA_KINDS).filter(([k]) => k !== 'other').map(([k, v]) => <span key={k}><i style={{ background: v.open ? 'transparent' : `color-mix(in srgb, ${v.color} 30%, transparent)`, borderColor: v.color, borderStyle: v.open ? 'dashed' : 'solid' }} />{v.label}</span>)}
      </div>

      {selArea && (
        <div className="sp-panel">
          {canEdit ? (
            <div className="sp-row">
              <label className="pe-field"><span>Name</span><input className="form-input" value={selArea.name} onChange={e => setArea({ name: e.target.value })} /></label>
              <label className="pe-field"><span>Kind</span><select className="form-input" value={selArea.kind} onChange={e => setArea({ kind: e.target.value })}>
                {Object.entries(AREA_KINDS).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}</select></label>
              <label className="pe-field"><span>Zone</span><select className="form-input" value={selArea.zone_id ?? ''} onChange={e => setArea({ zone_id: e.target.value || null })}>
                <option value="">None</option>{zones.map(z => <option key={keyOf(z)} value={keyOf(z)}>{z.name}</option>)}</select></label>
              {STOCK_KINDS.includes(selArea.kind) && <label className="pe-field"><span>Part of store</span><select className="form-input" value={selArea.warehouse_id ?? ''} onChange={e => setArea({ warehouse_id: e.target.value || null })}>
                <option value="">None</option>{stores.map(w => <option key={w.id} value={w.id}>{w.name}</option>)}</select></label>}
              <button type="button" className="btn btn-ghost btn-sm" onClick={() => setArea({ w: selArea.h, h: selArea.w, x: Math.min(selArea.x, W - selArea.h), y: Math.min(selArea.y, H - selArea.w) })}><RotateCw size={14} /> Turn</button>
              <button type="button" className="btn btn-ghost btn-sm text-error" onClick={removeSel}><Trash2 size={14} /> Remove</button>
            </div>
          ) : <p className="text-sm"><strong>{selArea.name}</strong> · {AREA_KINDS[selArea.kind].label}{selArea.warehouse_id ? ` · ${storeName(selArea.warehouse_id) ?? ''}` : ''}</p>}
          {selArea.kind === 'curing' && (
            <div className="sp-homes">
              <span className="pl-label">Curing here now</span>
              {contents(selArea).length ? contents(selArea).map(p => <span key={p.id} className="ptc-chip">{p.name} · <strong>{qtyText(p.qty, p.id)}</strong></span>) : <span className="pl-help">nothing</span>}
            </div>
          )}
          {selArea.kind === 'ready' && (
            <div className="sp-homes">
              <span className="pl-label">Products kept here</span>
              {productsHere(sel.key).map(p => <span key={p.id} className="ptc-chip">{p.name}{selArea.warehouse_id ? <> · <strong>{qtyText(stock[`${selArea.warehouse_id}|${p.id}`] || 0, p.id)}</strong></> : null}
                {canEdit && <button type="button" aria-label={`${p.name} not kept here`} onClick={() => change(() => setHomes(h => { const n = { ...h }; delete n[p.id]; return n; }))}><X size={11} /></button>}</span>)}
              {!productsHere(sel.key).length && <span className="pl-help">none yet</span>}
              {canEdit && <select className="form-input ptc-sel" value="" aria-label="Add a product kept here" onChange={e => e.target.value && change(() => setHomes(h => ({ ...h, [e.target.value]: sel.key })))}>
                <option value="">+ Product…</option>
                {products.filter(p => homes[p.id] !== sel.key).map(p => <option key={p.id} value={p.id}>{p.name}{homes[p.id] ? ' (moves here)' : ''}</option>)}</select>}
            </div>
          )}
        </div>
      )}
      {sel?.type === 'lane' && canEdit && (
        <div className="sp-panel sp-row">
          <span className="text-sm">{LANES[lanes.find(l => l.key === sel.key)?.kind]?.label}</span>
          <button type="button" className="btn btn-ghost btn-sm text-error" onClick={removeSel}><Trash2 size={14} /> Remove</button>
        </div>
      )}

      {/* zones: a name and a text colour; a machine's products are kept in its zone */}
      {(zones.length > 0 || canEdit) && (
        <div className="sp-panel">
          <span className="pl-label">Zones</span>
          {zones.map(z => {
            const here = products.filter(p => zoneOfProduct(p.id) === keyOf(z));
            return (
              <div key={keyOf(z)} className="sp-zone">
                {canEdit ? <>
                  <input className="form-input sp-zone-name" aria-label="Zone name" value={z.name} style={{ color: ZONE_COLORS[z.color] }} onChange={e => setZone(keyOf(z), { name: e.target.value })} />
                  <select className="form-input sp-zone-color" aria-label="Zone colour" value={z.color} onChange={e => setZone(keyOf(z), { color: e.target.value })}>
                    {Object.keys(ZONE_COLORS).map(c => <option key={c} value={c}>{c}</option>)}</select>
                  <button type="button" className="icon-btn" aria-label={`Remove zone ${z.name}`} onClick={() => change(() => { setZones(zs => zs.filter(x => keyOf(x) !== keyOf(z))); setAreas(as => as.map(a => (a.zone_id === keyOf(z) ? { ...a, zone_id: null } : a))); setMachines(ms => ms.map(m => (m.zone === keyOf(z) ? { ...m, zone: '' } : m))); })}><Trash2 size={14} /></button>
                </> : <strong style={{ color: ZONE_COLORS[z.color] }}>{z.name}</strong>}
                {/* the products kept in this zone, opened like a drop-down (2026-11-20, the user) */}
                <details className="sp-zone-list">
                  <summary>{here.length} product{here.length === 1 ? '' : 's'} kept here</summary>
                  {here.length ? <ul>{here.map(p => {
                    const area = homes[p.id] ? areas.find(a => keyOf(a) === homes[p.id]) : null;
                    const wh = area?.warehouse_id ?? storeOfZone(keyOf(z));
                    return <li key={p.id}>{p.name}{wh ? <strong> · {qtyText(stock[`${wh}|${p.id}`] || 0, p.id)}</strong> : null}
                      {canEdit ? <select className="form-input sp-place" aria-label={`Where ${p.name} is kept`} value={area ? keyOf(area) : ''}
                        onChange={e => change(() => setHomes(h => { const n = { ...h }; if (e.target.value) n[p.id] = e.target.value; else delete n[p.id]; return n; }))}>
                        <option value="">No place yet</option>
                        {areas.filter(a => a.zone_id === keyOf(z) && a.kind === 'ready').map(a => <option key={keyOf(a)} value={keyOf(a)}>{a.name}</option>)}</select>
                        : <span className="pl-help"> · {area ? area.name : 'no place on the plan yet'}</span>}</li>;
                  })}</ul>
                    : <span className="pl-help">None yet — set a machine's zone below, or add products to an area of this zone.</span>}
                </details>
              </div>
            );
          })}
          {canEdit && <button type="button" className="btn btn-ghost btn-sm" style={{ alignSelf: 'flex-start' }} onClick={() => change(() => setZones(zs => [...zs, { tmp: `t${++tmp}`, name: `Zone ${zs.length + 1}`, color: Object.keys(ZONE_COLORS)[zs.length % 8] }]))}><Plus size={14} /> Zone</button>}
          {machines.length > 0 && zones.length > 0 && (
            <div className="sp-machines">
              <span className="pl-label">Products of each machine are kept in</span>
              {machines.map(m => (
                <label key={m.id} className="sp-machine"><span>{m.name}</span>
                  {canEdit ? <select className="form-input" value={m.zone} onChange={e => change(() => setMachines(ms => ms.map(x => (x.id === m.id ? { ...x, zone: e.target.value } : x))))}>
                    <option value="">—</option>{zones.map(z => <option key={keyOf(z)} value={keyOf(z)}>{z.name}</option>)}</select>
                    : <strong style={{ color: zoneColor(m.zone) ?? undefined }}>{zones.find(z => keyOf(z) === m.zone)?.name ?? '—'}</strong>}
                </label>
              ))}
              <span className="pl-help">A product kept elsewhere: select that area on the plan and add it under Products kept here.</span>
            </div>
          )}
        </div>
      )}

      {canEdit && (
        <div className="sp-row sp-tools">
          <select className="form-input" style={{ width: 'auto' }} aria-label="Kind of new area" value={newKind} onChange={e => setNewKind(e.target.value)}>
            {Object.entries(AREA_KINDS).map(([k, v]) => <option key={k} value={k}>{v.label}</option>)}</select>
          <button type="button" className="btn btn-outline btn-sm" onClick={addArea}><Plus size={14} /> Add area</button>
          {drawing ? <>
            <span className="pl-help">Click points on the plan, then</span>
            <button type="button" className="btn btn-primary btn-sm" onClick={finishLane}>Finish {LANES[drawing.kind].label.toLowerCase()}</button>
            <button type="button" className="btn btn-ghost btn-sm" onClick={() => setDrawing(null)}>Cancel</button>
          </> : Object.entries(LANES).map(([k, v]) => (
            <button key={k} type="button" className="btn btn-ghost btn-sm" onClick={() => { setSel(null); setDrawing({ kind: k, points: [] }); }}><Route size={14} /> {v.label}</button>
          ))}
          <span style={{ marginLeft: 'auto' }} />
          {dirty && <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={load}>Undo changes</button>}
          <button type="button" className={`btn btn-primary btn-sm${busy ? ' btn-loading' : ''}`} disabled={busy || !dirty} onClick={save}><Save size={14} /> Save plan</button>
        </div>
      )}
    </div>
  );
}
