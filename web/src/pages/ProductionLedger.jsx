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

  const openDay = days.find(d => d.key === open);
  return (
    <PageShell title="Production ledger" subtitle="Production"
      description={branchId ? `Every production day confirmed at ${branchName}.` : 'Every production day confirmed, at every branch.'}>
      <div className="pled-toolbar">
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

      <div className="card">
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
      </div>

      {openDay && refs && (
        <Modal title={`Production — ${openDay.date}`} onClose={() => setOpen(null)} size="xl"
          footer={<button type="button" className="btn btn-outline" onClick={() => setOpen(null)}>Close</button>}>
          <DaySummary day={summaryOf(openDay)} currency={organization?.currency_code} />
        </Modal>
      )}
    </PageShell>
  );
}
