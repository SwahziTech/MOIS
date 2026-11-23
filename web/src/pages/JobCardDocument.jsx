import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { useParams } from 'react-router-dom';
import { Printer } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { dateText, tableDate } from '../lib/format';
import { loadInventoryRefs, byMaterialOrder } from '../lib/inventory';
import { printPage } from '../lib/native';

const qty = v => new Intl.NumberFormat('en-US', { maximumFractionDigits: 3 }).format(v);
const amt = v => new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(v);

/*
 * Production job card (2026-11-20, the user: "the uploaded format" — the old
 * system's card), A4, in a tab of its own: /print/job-card/:branchId/:date
 * One branch's production on one day: the company's details, the card's
 * details, then three boxes — production costs (consumables, 138), the
 * materials used (each batch's, quantity × cost a unit = total, oldest stock
 * first, VAT included) and the products made (pieces × cost a piece).
 */
export default function JobCardDocument() {
  const { batchId } = useParams();
  const { session, loading: authLoading } = useAuth();
  const [d, setD] = useState(null);
  const [error, setError] = useState('');
  // one A4 page always (2026-11-20, the user): a busy day's card shrinks to fit
  const ref = useRef(null);
  const [zoom, setZoom] = useState(1);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    el.style.zoom = 1;
    const mm = el.getBoundingClientRect().width / 210;
    const used = [...el.children].reduce((h, c) => Math.max(h, c.getBoundingClientRect().bottom), 0) - el.getBoundingClientRect().top + 16 * mm;
    const z = Math.min(1, (297 * mm) / used);
    el.style.zoom = '';
    setZoom(z < 0.999 ? Math.floor(z * 100) / 100 : 1);
  }, [d]);

  useEffect(() => {
    if (!session) return;
    (async () => {
      const [b, refs] = await Promise.all([
        supabase.from('production_batches').select('*, materials:production_batch_materials(*), outputs:production_batch_outputs(*)').eq('id', batchId).maybeSingle(),
        loadInventoryRefs(),
      ]);
      if (b.error || !b.data) { setError("We couldn't find this batch."); return; }
      const x = b.data;
      // its place in the day (batch 2 of 4) and who made it — the team's name and how many, no names
      const [day, br, org, team, mach] = await Promise.all([
        supabase.from('production_batches').select('id').eq('branch_id', x.branch_id).eq('batch_date', x.batch_date).order('created_at'),
        supabase.from('branches').select('name').eq('id', x.branch_id).maybeSingle(),
        supabase.from('organizations').select('*').eq('id', x.organization_id).maybeSingle(),
        x.team_id ? supabase.from('production_teams').select('name').eq('id', x.team_id).maybeSingle() : Promise.resolve({ data: null }),
        x.machine_id ? supabase.from('machines').select('name').eq('id', x.machine_id).maybeSingle() : Promise.resolve({ data: null }),
      ]);
      const ids = (day.data || []).map(r => r.id);
      setD({ batches: [x], n: ids.indexOf(x.id) + 1, of: ids.length, branch: br.data?.name, org: org.data, refs,
        team: team.data?.name ?? null, people: (x.worker_ids || []).length || null, machine: mach.data?.name ?? null });
    })();
  }, [batchId, session]);

  if (authLoading) return null;
  if (!session) return <div className="doc-msg">Sign in to MOIS to see this document.</div>;
  if (error) return <div className="doc-msg">{error}</div>;
  if (!d) return <div className="doc-msg">Loading…</div>;
  const { org, refs, batches } = d;
  const name = id => refs.items[`m:${id}`]?.name ?? '—';
  const sym = id => refs.unitById[id]?.symbol ?? '';
  const prod = o => `${refs.items[`p:${o.product_id}`]?.name ?? '—'}${o.color_id ? ` ${refs.colorById[o.color_id]?.name ?? ''}` : ''}`;

  // materials batch by batch, in material order; consumables (138) go in the costs box
  const matRows = batches.flatMap((b, i) => [...(b.materials || [])]
    .filter(m => m.source !== 'consumable' && Number(m.quantity) > 0)
    .sort((x, y) => byMaterialOrder(refs.items[`m:${x.material_id}`] ?? {}, refs.items[`m:${y.material_id}`] ?? {}))
    .map(m => ({ batch: i + 1, ...m })));
  const costRows = batches.flatMap((b, i) => (b.materials || []).filter(m => m.source === 'consumable' && Number(m.quantity) > 0).map(m => ({ batch: i + 1, ...m })));
  const prodRows = batches.flatMap(b => [...(b.outputs || [])].sort((x, y) => y.is_primary - x.is_primary)
    .map(o => ({ name: prod(o), pcs: Number(o.pieces_cast), each: o.cost_per_piece != null ? Number(o.cost_per_piece) : null })));
  const sum = (rows, f) => rows.reduce((t, r) => t + (f(r) ?? 0), 0);
  const matTotal = sum(matRows, m => (m.cost != null ? Number(m.cost) : 0));
  const costTotal = sum(costRows, m => (m.cost != null ? Number(m.cost) : 0));
  const prodTotal = sum(prodRows, p => (p.each != null ? p.each * p.pcs : 0));
  const released = batches.filter(b => b.released_on).map(b => b.released_on).sort();
  const allReleased = released.length === batches.length;
  const each = m => (m.cost != null && Number(m.quantity) > 0 ? Number(m.cost) / Number(m.quantity) : null);
  const several = false;   // one batch a card (2026-11-20, the user)
  const b0 = batches[0];
  const date = b0.batch_date;

  const matTable = (rows, total) => (
    <table className="doc-table jc-table">
      <thead><tr><th>Item</th><th>Unit</th><th className="num">Qty</th><th className="num">Unit cost</th><th className="num">Total</th></tr></thead>
      <tbody>
        {rows.map((m, i) => (
          <tr key={m.id} className={several && i > 0 && rows[i - 1].batch !== m.batch ? 'jc-break' : ''}>
            <td>{name(m.material_id)}{several && (i === 0 || rows[i - 1].batch !== m.batch) && <span className="jc-batch"> · batch {m.batch}</span>}</td>
            <td>{sym(m.unit_id)}</td>
            <td className="num">{qty(Number(m.quantity))}</td>
            <td className="num">{each(m) != null ? amt(each(m)) : '—'}</td>
            <td className="num">{m.cost != null ? amt(Number(m.cost)) : '—'}</td>
          </tr>
        ))}
      </tbody>
      {rows.length > 0 && <tfoot><tr><td colSpan={4} /><td className="num"><strong>{amt(total)}</strong></td></tr></tfoot>}
    </table>
  );

  return (
    <div className="doc-page">
      <div className="doc-bar">
        <button type="button" className="btn btn-primary" onClick={() => printPage()}><Printer size={15} /> Print / Save as PDF</button>
        <span className="pl-help">Choose “Save as PDF” as the printer to keep a copy.</span>
      </div>
      <article className="doc jc" ref={ref} style={zoom < 1 ? { zoom } : undefined}>
        <header className="jc-head">
          <div className="jc-co">
            <strong className="doc-co-name">{org?.legal_name || org?.name}</strong>
            {org?.address && <div>{org.address}</div>}
            {org?.phone && <div>{org.phone}</div>}
            {org?.email && <div>Email: {org.email}</div>}
            <div className="jc-title">Production job card</div>
          </div>
          {org?.logo_url && <img src={org.logo_url} alt="" className="doc-logo" />}
        </header>

        <section className="jc-details">
          <div>
            <div><span className="doc-label">Job card</span>PJC-{date.replaceAll('-', '')}-{d.n}</div>
            <div><span className="doc-label">Description</span>Production · {d.branch} · batch {d.n} of {d.of}</div>
            <div><span className="doc-label">Batch</span>{qty(Number(b0.cement_bags))} bags of cement{b0.status === 'void' ? ' · VOID' : ''}</div>
            <div><span className="doc-label">Made by</span>{[d.team, d.people != null && `${d.people} ${d.people === 1 ? 'person' : 'people'}`, d.machine].filter(Boolean).join(' · ') || '—'}</div>
            <div><span className="doc-label">Currency</span>{org?.currency_code || 'TZS'}</div>
          </div>
          <div>
            <div><span className="doc-label">Started</span>{tableDate(date)}</div>
            <div><span className="doc-label">Completed</span>{allReleased ? tableDate(released.at(-1)) : 'curing'}</div>
            <div><span className="doc-label">Date printed</span>{dateText(new Date().toISOString().slice(0, 10))}</div>
          </div>
        </section>

        <section className="jc-boxes">
          <div className="jc-box">
            <h2>Production costs</h2>
            {costRows.length ? matTable(costRows, costTotal) : <p className="jc-empty">Consumables, electricity and labour come in through Costing.</p>}
          </div>
          <div className="jc-box">
            <h2>Production materials</h2>
            {matTable(matRows, matTotal)}
          </div>
          <div className="jc-box">
            <h2>Production products</h2>
            <table className="doc-table jc-table">
              <thead><tr><th>Product</th><th className="num">Qty</th><th className="num">Unit cost</th><th className="num">Total</th></tr></thead>
              <tbody>
                {prodRows.map((p, i) => (
                  <tr key={i}><td>{p.name}</td><td className="num">{qty(p.pcs)}</td><td className="num">{p.each != null ? amt(p.each) : '—'}</td><td className="num">{p.each != null ? amt(p.each * p.pcs) : '—'}</td></tr>
                ))}
              </tbody>
              <tfoot><tr><td colSpan={3} /><td className="num"><strong>{amt(prodTotal)}</strong></td></tr></tfoot>
            </table>
          </div>
        </section>

        <footer className="doc-sign">
          <div>Recorded by</div><div>Checked by</div><div>Approved by</div>
        </footer>
      </article>
    </div>
  );
}
