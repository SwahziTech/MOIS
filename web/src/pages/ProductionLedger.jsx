import { useEffect, useMemo, useState } from 'react';
import { BookOpen } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { useBranch } from '../hooks/useBranch';
import { loadInventoryRefs, qtyText, orgToday, byMaterialOrder, breakdownMaterials } from '../lib/inventory';
import PageShell from '../components/PageShell';
import EmptyState from '../components/EmptyState';
import ErrorState from '../components/ErrorState';
import Modal from '../components/Modal';
import { SkeletonRow } from '../components/LoadingSpinner';
import DaySummary from '../components/production/DaySummary';
import { formatMoney } from '../lib/format';

const LOAD_ERROR = "We couldn't load the production ledger. Please try again.";
const STAGES = ['Curing', 'Ready', 'Released', 'Void'];
const STAGE_BADGE = { Curing: 'badge-accent', Ready: 'badge-warning', Released: 'badge-success', Void: 'badge-neutral' };
const round = (n, d = 2) => Math.round(n * 10 ** d) / 10 ** d;
const addDays = (iso, n) => new Date(new Date(`${iso}T00:00:00Z`).getTime() + n * 864e5).toISOString().slice(0, 10);

/** A batch's stage: Curing → Ready (curing time up) → Released; or Void */
export const stageOf = (b, today) => (b.status === 'void' ? 'Void' : b.status === 'released' ? 'Released' : b.curing_until <= today ? 'Ready' : 'Curing');

/*
 * Production ledger (2026-10-21): every confirmed production day, by
 * period and stage. A day opens as the same one-screen summary shown
 * before it was saved — batches, products (main and residuals apart),
 * materials used in the recipe's units, curing and release.
 */
export default function ProductionLedger() {
  const { organization } = useAuth();
  const { branchId, branchName, inBranch, branches } = useBranch();
  const today = orgToday(organization?.timezone);
  const [refs, setRefs] = useState(null);
  const [batches, setBatches] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [period, setPeriod] = useState('30');     // days back: 7 | 30 | 90 | all | custom
  const [from, setFrom] = useState(addDays(today, -30));
  const [to, setTo] = useState(today);
  const [stage, setStage] = useState('');
  const [sortBy, setSortBy] = useState('newest');
  const [open, setOpen] = useState(null);         // a day key
  const [pcsPerSqm, setPcsPerSqm] = useState({});
  const [track, setTrack] = useState(null);       // teams and machines (056); null before it
  const [view, setView] = useState('days');       // days | tracking
  const [groupBy, setGroupBy] = useState('team');  // team | machine | product

  async function load() {
    setError('');
    const byBranch = q => (branchId ? q.eq('branch_id', branchId) : q);
    try {
      const [r, b, ps] = await Promise.all([
        loadInventoryRefs(),
        byBranch(supabase.from('production_batches').select('*, materials:production_batch_materials(*), outputs:production_batch_outputs(*), rejects:production_batch_rejects(*)'))
          .order('batch_date', { ascending: false }).order('created_at').limit(2000),
        supabase.from('product_specs').select('product_id, pcs_per_sqm'),
      ]);
      setPcsPerSqm(Object.fromEntries((ps.data || []).map(x => [x.product_id, Number(x.pcs_per_sqm)])));
      // production tracking (056) — the ledger still works without it
      const [t, m] = await Promise.all([
        supabase.from('production_teams').select('id, name, members:production_team_members(id, name)'),
        supabase.from('machines').select('id, name'),
      ]);
      setTrack(t.error || m.error ? null : { teams: t.data || [], machines: m.data || [] });
      if (b.error) throw b.error;
      setRefs(r);
      setBatches(b.data || []);
    } catch (e) {
      console.error(e);
      setError(LOAD_ERROR);
    }
    setLoading(false);
  }
  useEffect(() => { setLoading(true); load(); }, [branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  const branchNameOf = id => branches.find(x => x.id === id)?.name ?? '';
  const productName = (o) => `${refs?.items[`p:${o.product_id}`]?.name ?? '—'}${o.color_id ? ` ${refs?.colorById[o.color_id]?.name ?? ''}` : ''}`;
  // m² for products counted in m² (pieces ÷ pieces per m²)
  const sqmOf = (productId, pcs) => (refs?.unitById[refs?.items[`p:${productId}`]?.stockUnitId]?.symbol?.toUpperCase() === 'SQM' && pcsPerSqm[productId] > 0 ? pcs / pcsPerSqm[productId] : null);

  // One row per branch + day
  const days = useMemo(() => {
    const lo = period === 'all' ? '0000' : period === 'custom' ? from : addDays(today, -Number(period));
    const hi = period === 'custom' ? to : '9999';
    const g = {};
    for (const b of batches.filter(x => inBranch(x.branch_id) && x.batch_date >= lo && x.batch_date <= hi)) {
      const k = `${b.branch_id}|${b.batch_date}`;
      (g[k] ||= { key: k, date: b.batch_date, branchId: b.branch_id, batches: [] }).batches.push(b);
    }
    let list = Object.values(g).map(d => ({ ...d, stages: d.batches.reduce((m, b) => { const s = stageOf(b, today); m[s] = (m[s] || 0) + 1; return m; }, {}) }));
    if (stage) list = list.filter(d => d.stages[stage]);
    return list.sort((a, b) => (sortBy === 'oldest' ? a.date.localeCompare(b.date) : b.date.localeCompare(a.date)) || branchNameOf(a.branchId).localeCompare(branchNameOf(b.branchId)));
  }, [batches, period, from, to, stage, sortBy, today, branchId]); // eslint-disable-line react-hooks/exhaustive-deps

  // A day's products: main and residual products each on their own line, summed per product
  const productsOf = d => {
    const p = {};
    for (const b of d.batches.filter(x => x.status !== 'void')) for (const o of b.outputs || []) {
      const k = `${o.product_id}|${o.color_id ?? ''}`;
      p[k] ??= { name: productName(o), productId: o.product_id, pieces: 0 };
      p[k].pieces += o.pieces_cast;
    }
    return Object.values(p);
  };

  function summaryOf(d) {
    const mats = {};
    for (const b of d.batches.filter(x => x.status !== 'void')) for (const m of b.materials || []) {
      const k = `${m.material_id}|${m.unit_id}`;
      mats[k] ??= { item: refs.items[`m:${m.material_id}`] ?? { name: '—' }, used: 0, unit: refs.unitById[m.unit_id]?.symbol ?? '' };
      mats[k].used += Number(m.quantity);
    }
    const curing = d.batches.filter(b => b.status === 'curing').map(b => b.curing_until).sort();
    return {
      date: d.date, branchName: branchNameOf(d.branchId), curingUntil: curing.at(-1) ?? null,
      batches: d.batches.map((b, i) => ({
        n: i + 1, bags: Number(b.cement_bags), stage: stageOf(b, today),
        cost: b.material_cost, costComplete: b.material_cost_complete,   // 055: costed as the materials left the store
        team: teamOf(b), machine: track?.machines.find(m => m.id === b.machine_id)?.name ?? null,
        qc: b.status === 'released' ? { tags: b.qc_tags || [], note: b.release_note } : null,
        factor: b.theoretical_bags != null ? b.theoretical_bags / b.cement_bags : null,
        outOfBand: b.theoretical_bags != null && (b.cement_bags < b.bags_min - 1e-9 || (b.bags_max != null && b.cement_bags > b.bags_max + 1e-9)),
        outputs: [...(b.outputs || [])].sort((x, y) => y.is_primary - x.is_primary).map(o => ({ name: productName(o), pieces: o.pieces_cast, residual: !o.is_primary, passed: o.pieces_passed, perBag: o.yield_per_bag,
          perPiece: o.cost_per_piece, perSqm: o.cost_per_sqm })),
        materials: breakdownMaterials(b.materials, refs),
      })),
      products: productsOf(d).map(p => ({ ...p, sqm: sqmOf(p.productId, p.pieces) })),
      materials: Object.values(mats).sort((a, b) => byMaterialOrder(a.item, b.item)).map(m => ({ name: m.item.name, used: m.used, unit: m.unit })),
    };
  }

  // the team, and who worked when it differed: "Juma team (2 of 3: Juma, Neema)"
  function teamOf(b) {
    const t = track?.teams.find(x => x.id === b.team_id);
    if (!t) return null;
    if (!b.worker_ids) return t.name;
    const people = track.teams.flatMap(x => x.members);
    return `${t.name} (${b.worker_ids.map(id => people.find(p => p.id === id)?.name ?? '?').join(', ')})`;
  }

  // Tracking: the period's batches by team, machine or product
  const tracking = useMemo(() => {
    if (!track || !refs) return [];
    const live = days.flatMap(d => d.batches).filter(b => b.status !== 'void');
    const rows = {};
    const row = (k, name) => (rows[k] ||= { key: k, name, batches: 0, bags: 0, pieces: 0, implied: 0, implying: 0, released: 0, rejected: 0, cost: 0, costPcs: 0 });
    for (const b of live) {
      const keys = groupBy === 'team' ? [[b.team_id ?? '-', track.teams.find(t => t.id === b.team_id)?.name ?? 'No team (before 25 Oct)']]
        : groupBy === 'machine' ? [[b.machine_id ?? '-', track.machines.find(m => m.id === b.machine_id)?.name ?? 'No machine (before 25 Oct)']]
        : [[b.product_id, refs.items[`p:${b.product_id}`]?.name ?? '—']];
      for (const [k, name] of keys) {
        const r = row(k, name);
        r.batches += 1; r.bags += Number(b.cement_bags);
        const pcs = (b.outputs || []).reduce((s, o) => s + o.pieces_cast, 0);
        r.pieces += pcs;
        if (b.theoretical_bags != null) { r.implied += Number(b.theoretical_bags); r.implying += Number(b.cement_bags); }
        if (b.status === 'released') { r.released += pcs; r.rejected += (b.rejects || []).reduce((s, x) => s + x.pieces, 0); }
        if (b.material_cost != null) { r.cost += Number(b.material_cost); r.costPcs += pcs; }
      }
    }
    return Object.values(rows).sort((a, b) => b.pieces - a.pieces);
  }, [track, refs, days, groupBy]);
  const money = v => formatMoney(v, organization?.currency_code);
  const pct = v => (v == null || !isFinite(v) ? '—' : `${Math.round(v * 1000) / 10}%`);

  const openDay = days.find(d => d.key === open);
  return (
    <PageShell title="Production ledger" subtitle="Production"
      description={branchId ? `Every production day confirmed at ${branchName}.` : 'Every production day confirmed, at every branch.'}>
      <div className="pled-toolbar">
        <div className="filter-chips">
          <button type="button" className={`filter-chip${view === 'days' ? ' is-on' : ''}`} onClick={() => setView('days')}>Days</button>
          <button type="button" className={`filter-chip${view === 'tracking' ? ' is-on' : ''}`} disabled={!track} title={track ? '' : 'Production tracking is not set up yet'} onClick={() => setView('tracking')}>Tracking</button>
        </div>
        <select className="form-input" aria-label="Period" value={period} onChange={e => setPeriod(e.target.value)}>
          <option value="7">Last 7 days</option>
          <option value="30">Last 30 days</option>
          <option value="90">Last 90 days</option>
          <option value="all">All time</option>
          <option value="custom">Dates…</option>
        </select>
        {period === 'custom' && (
          <>
            <input type="date" className="form-input" aria-label="From" max={to} value={from} onChange={e => setFrom(e.target.value)} />
            <input type="date" className="form-input" aria-label="To" min={from} max={today} value={to} onChange={e => setTo(e.target.value)} />
          </>
        )}
        <div className="filter-chips">
          <button type="button" className={`filter-chip${!stage ? ' is-on' : ''}`} onClick={() => setStage('')}>All stages</button>
          {STAGES.map(s => <button type="button" key={s} className={`filter-chip${stage === s ? ' is-on' : ''}`} onClick={() => setStage(stage === s ? '' : s)}>{s}</button>)}
        </div>
        <select className="form-input" aria-label="Sort" value={sortBy} onChange={e => setSortBy(e.target.value)} style={{ marginLeft: 'auto' }}>
          <option value="newest">Newest first</option>
          <option value="oldest">Oldest first</option>
        </select>
      </div>

      {view === 'tracking' && track && (
        <div className="card">
          <div className="pled-track-head">
            <span className="pl-help">Batches in the period above (void left out). Yield = cement the pieces imply ÷ cement used; rejects = of pieces released.</span>
            <div className="filter-chips">
              {[['team', 'Team'], ['machine', 'Machine'], ['product', 'Product']].map(([k, l]) => (
                <button type="button" key={k} className={`filter-chip${groupBy === k ? ' is-on' : ''}`} onClick={() => setGroupBy(k)}>{l}</button>
              ))}
            </div>
          </div>
          <div className="table-container">
            {(
              <table>
                <thead><tr><th>{{ team: 'Team', machine: 'Machine', product: 'Product' }[groupBy]}</th><th style={{ textAlign: 'right' }}>Batches</th><th style={{ textAlign: 'right' }}>Bags</th>
                  <th style={{ textAlign: 'right' }}>Pieces</th><th style={{ textAlign: 'right' }}>Yield</th><th style={{ textAlign: 'right' }}>Rejects</th>
                  <th style={{ textAlign: 'right' }}>Material / pc</th></tr></thead>
                <tbody>{tracking.length === 0 ? <tr><td colSpan={7} className="text-muted">No batches in this period.</td></tr> : tracking.map(r => (
                  <tr key={r.key}>
                    <td style={{ fontWeight: 500 }} className={r.key === '-' ? 'text-muted' : ''}>{r.name}</td>
                    <td style={{ textAlign: 'right' }}>{r.batches}</td>
                    <td style={{ textAlign: 'right' }}>{qtyText(round(r.bags))}</td>
                    <td style={{ textAlign: 'right' }}>{qtyText(r.pieces)}</td>
                    <td style={{ textAlign: 'right' }}>{r.implying > 0 ? pct(r.implied / r.implying) : '—'}</td>
                    <td style={{ textAlign: 'right' }}>{r.released > 0 ? pct(r.rejected / r.released) : '—'}</td>
                    <td style={{ textAlign: 'right' }}>{r.costPcs > 0 ? money(r.cost / r.costPcs) : '—'}</td>
                  </tr>
                ))}</tbody>
              </table>
            )}
          </div>
        </div>
      )}

      {view === 'days' && <div className="card">
        {error ? <ErrorState message={error} onRetry={load} /> : (
          <div className="table-container">
            <table>
              <thead><tr>
                <th>Date</th>{!branchId && <th>Branch</th>}<th>Products</th><th style={{ textAlign: 'right' }}>Batches</th>
                <th style={{ textAlign: 'right' }}>Bags</th><th>Stage</th>
              </tr></thead>
              <tbody>
                {loading ? <SkeletonRow cols={branchId ? 5 : 6} /> : days.length === 0 ? (
                  <tr><td colSpan={branchId ? 5 : 6}><EmptyState icon={BookOpen} title="No production in this period" description="Confirmed production days appear here." /></td></tr>
                ) : days.map(d => (
                  <tr key={d.key} className="clickable-row" onClick={() => setOpen(d.key)} tabIndex={0} onKeyDown={e => { if (e.key === 'Enter') setOpen(d.key); }}>
                    <td style={{ fontWeight: 600 }}>{d.date}</td>
                    {!branchId && <td className="text-muted">{branchNameOf(d.branchId)}</td>}
                    <td>{productsOf(d).map(p => <div key={p.name} className="text-sm">{p.name} <strong>{qtyText(p.pieces)}</strong> pcs</div>)}</td>
                    <td style={{ textAlign: 'right' }}>{d.batches.length}</td>
                    <td style={{ textAlign: 'right' }}>{qtyText(round(d.batches.filter(b => b.status !== 'void').reduce((s, b) => s + Number(b.cement_bags), 0)))}</td>
                    <td>{STAGES.filter(s => d.stages[s]).map(s => <span key={s} className={`badge ${STAGE_BADGE[s]}`} style={{ marginRight: 4 }}>{s} {d.stages[s]}</span>)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>}

      {openDay && refs && (
        <Modal title={`Production — ${openDay.date}`} onClose={() => setOpen(null)} size="xl"
          footer={<button type="button" className="btn btn-outline" onClick={() => setOpen(null)}>Close</button>}>
          <DaySummary day={summaryOf(openDay)} currency={organization?.currency_code} />
        </Modal>
      )}
    </PageShell>
  );
}
