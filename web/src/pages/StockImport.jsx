import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { Upload, AlertTriangle, CheckCircle2 } from 'lucide-react';
import { supabase } from '../lib/supabase';
import { useAuth } from '../hooks/useAuth';
import { dbErrorMessage } from '../lib/masterData';
import { warehouseLabel, qtyText, orgToday } from '../lib/inventory';
import { parseStockSheet, matchSheet, lineProblems, normalize } from '../lib/stockImport';
import PageShell from '../components/PageShell';
import ErrorState from '../components/ErrorState';

const LOAD_ERROR = "We couldn't load the catalogue. Please try again.";

/*
 * Import a stock sheet as opening balances (build-plan 1b). Nothing is
 * written until "Post": the sheet is parsed and matched in the browser, the
 * admin resolves every line, previews the batch, and it posts through
 * post_inventory_batch() — every movement via post_inventory_movement(),
 * all or nothing. Resolved names are remembered (import_aliases).
 */
export default function StockImport() {
  const { organization, canAt, canManage } = useAuth();
  const navigate = useNavigate();
  const today = orgToday(organization?.timezone);
  const [catalog, setCatalog] = useState(null);
  const [warehouses, setWarehouses] = useState([]);
  const [loadError, setLoadError] = useState('');

  const [fileName, setFileName] = useState('');
  const [parsed,   setParsed]   = useState(null);
  const [matched,  setMatched]  = useState(null);
  const [warehouseId, setWarehouseId] = useState('');
  const [date,     setDate]     = useState(today);
  const [tableChoice, setTableChoice] = useState({});   // table index → { categoryId, unitId }
  const [choices,  setChoices]  = useState({});         // line id → { productId, colorId, unitId, qty, date, skip, converted }
  const [step,     setStep]     = useState('upload');   // upload | resolve | preview | done
  const [busy,  setBusy]  = useState(false);
  const [error, setError] = useState('');
  const [result, setResult] = useState(null);

  async function loadCatalog() {
    setLoadError('');
    const [cats, pcc, prods, colors, units, aliases, wh] = await Promise.all([
      supabase.from('product_categories').select('id, name, status, sort_order, default_unit_id').order('sort_order'),
      supabase.from('product_category_colors').select('category_id, color_id, display_order'),
      supabase.from('products').select('id, canonical_name, category_id, unit_id, pcs_per_sqm, status').order('canonical_name'),
      supabase.from('color_palette').select('id, name, display_order, is_active').order('display_order'),
      supabase.from('units').select('id, symbol, name, status'),
      supabase.from('import_aliases').select('alias_type, scope, alias_normalized, product_id, color_id, category_id'),
      supabase.from('warehouses').select('id, name, status, branch_id, branch:branches(id, name, status)').order('name'),
    ]);
    const err = [cats, pcc, prods, colors, units, aliases, wh].find(r => r.error)?.error;
    if (err) { console.error(err); setLoadError(LOAD_ERROR); return null; }
    const c = {
      categories: cats.data.map(x => ({ id: x.id, name: x.name, status: x.status, defaultUnitId: x.default_unit_id,
        colorIds: pcc.data.filter(p => p.category_id === x.id).sort((a, b) => a.display_order - b.display_order).map(p => p.color_id) })),
      products: prods.data.map(p => ({ id: p.id, name: p.canonical_name, categoryId: p.category_id, unitId: p.unit_id, pcsPerSqm: p.pcs_per_sqm, status: p.status })),
      colors: colors.data.map(x => ({ id: x.id, name: x.name, isActive: x.is_active })),
      units: units.data.map(u => ({ id: u.id, symbol: u.symbol, name: u.name })),
      aliases: aliases.data,
    };
    setCatalog(c);
    setWarehouses(wh.data.filter(w => w.status === 'active' && canAt('inventory.adjust', w.branch_id, w.id)));
    return c;
  }

  useEffect(() => { loadCatalog(); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const prodById = useMemo(() => Object.fromEntries((catalog?.products || []).map(p => [p.id, p])), [catalog]);
  const catById  = useMemo(() => Object.fromEntries((catalog?.categories || []).map(c => [c.id, c])), [catalog]);
  const colById  = useMemo(() => Object.fromEntries((catalog?.colors || []).map(c => [c.id, c])), [catalog]);
  const unitById = useMemo(() => Object.fromEntries((catalog?.units || []).map(u => [u.id, u])), [catalog]);

  function analyse(text, cat = catalog) {
    const p = parseStockSheet(text);
    const m = matchSheet(p, cat);
    setParsed(p);
    setMatched(m);
    setTableChoice(Object.fromEntries(m.tables.map(t => [t.index, {
      categoryId: t.cat.id ?? '',
      unitId: cat.units.find(u => normalize(u.symbol) === normalize(t.defaultUnit) || normalize(u.name) === normalize(t.defaultUnit))?.id ?? '',
    }])));
    setChoices(Object.fromEntries(m.lines.map(l => [l.id, {
      productId: l.product.id ?? '', colorId: l.colour?.id ?? '', unitId: l.unitId ?? '', qty: l.qty, date: '', skip: false,
    }])));
    setStep('resolve');
  }

  function onFile(e) {
    const f = e.target.files?.[0];
    if (!f) return;
    setFileName(f.name);
    const r = new FileReader();
    r.onload = () => analyse(String(r.result));
    r.readAsText(f);
  }

  // A category chosen for a table re-runs that table's matching against it;
  // products already chosen stay chosen
  function chooseTableCategory(t, categoryId) {
    const next = { ...tableChoice, [t.index]: { ...tableChoice[t.index], categoryId } };
    setTableChoice(next);
    if (!t.category || !categoryId) return;
    const extra = Object.entries(next)
      .map(([i, v]) => ({ t: matched.tables[i], v }))
      .filter(({ t: tt, v }) => tt.category && v.categoryId && v.categoryId !== tt.cat.id)
      .map(({ t: tt, v }) => ({ alias_type: 'category', scope: '', alias_normalized: normalize(tt.category), category_id: v.categoryId }));
    const m = matchSheet(parsed, { ...catalog, aliases: [...catalog.aliases, ...extra] });
    setMatched({ tables: matched.tables, lines: m.lines });   // keep each table's original match labels
    setChoices(cs => Object.fromEntries(m.lines.map(l => [l.id, cs[l.id]?.productId ? cs[l.id] : { ...cs[l.id], productId: l.product.id ?? '' }])));
  }

  const setChoice = (id, patch) => setChoices(cs => ({ ...cs, [id]: { ...cs[id], ...patch } }));

  // A table's own unit stands in for lines whose heading had none
  const effective = l => {
    const c = choices[l.id] || {};
    return { ...c, unitId: c.unitId || (!l.unitExplicit ? tableChoice[l.table]?.unitId : '') || '' };
  };
  const problemsOf = l => (catalog ? lineProblems({ ...l, unitId: effective(l).unitId }, effective(l), catalog) : []);

  const lines = matched?.lines || [];
  const ready = lines.filter(l => !choices[l.id]?.skip && problemsOf(l).length === 0);
  const open  = lines.filter(l => !choices[l.id]?.skip && problemsOf(l).length > 0);
  const skipped = lines.filter(l => choices[l.id]?.skip);

  // Same product + colour twice on one date can't be one opening balance
  const dupes = useMemo(() => {
    const seen = {}, out = new Set();
    for (const l of ready) {
      const c = effective(l);
      const k = `${c.date || date}|${c.productId}|${c.colorId}`;
      if (seen[k]) { out.add(l.id); out.add(seen[k]); } else seen[k] = l.id;
    }
    return out;
  }, [ready, choices, date]); // eslint-disable-line react-hooks/exhaustive-deps

  async function createColour(l) {
    const prod = prodById[choices[l.id].productId];
    const cat = prod && catById[prod.categoryId];
    if (!cat) return;
    setError('');
    const name = l.colourText.charAt(0).toUpperCase() + l.colourText.slice(1).toLowerCase();
    setBusy(true);
    let colour = catalog.colors.find(c => normalize(c.name) === normalize(name));
    if (!colour) {
      const { data, error: err } = await supabase.from('color_palette')
        .insert({ organization_id: organization.id, name, display_order: catalog.colors.length + 1 }).select('id').single();
      if (err) { setBusy(false); setError(dbErrorMessage(err)); return; }
      colour = { id: data.id };
    }
    const { error: err2 } = await supabase.from('product_category_colors')
      .insert({ organization_id: organization.id, category_id: cat.id, color_id: colour.id, display_order: cat.colorIds.length + 1 });
    setBusy(false);
    if (err2 && err2.code !== '23505') { setError(dbErrorMessage(err2)); return; }
    const c = await loadCatalog();
    if (c) setChoices(cs => Object.fromEntries(Object.entries(cs).map(([id, ch]) => {
      const line = lines.find(x => x.id === id);
      return [id, line?.colourText && normalize(line.colourText) === normalize(name) && !ch.colorId ? { ...ch, colorId: colour.id } : ch];
    })));
  }

  async function post() {
    setError('');
    if (!warehouseId) { setError('Choose the store.'); return; }
    const byDate = {};
    for (const l of ready) {
      const c = effective(l);
      (byDate[c.date || date] ??= []).push({ product_id: c.productId, ...(c.colorId ? { color_id: c.colorId } : {}), quantity: Number(c.qty), unit_id: c.unitId });
    }
    const conversions = ready.filter(l => choices[l.id].converted).map(l => `${l.typeText}${l.colourText ? ' ' + l.colourText : ''}: ${l.qty}${l.unitText} → ${choices[l.id].qty}`);
    const movements = Object.entries(byDate).sort().map(([d, ls]) => ({
      type: 'opening_balance', warehouse_id: warehouseId, movement_date: d, reference: fileName || null,
      notes: conversions.length ? `Converted from pieces: ${conversions.join('; ')}` : null, lines: ls,
    }));

    // Teach the names the admin resolved by hand
    const aliases = [];
    const seen = new Set();
    for (const l of ready) {
      const t = matched.tables[l.table];
      const c = effective(l);
      if (l.product.status !== 'exact' || l.product.id !== c.productId) {
        const k = `p|${t.category}|${normalize(l.typeText)}`;
        if (!seen.has(k)) { seen.add(k); aliases.push({ alias_type: 'product', scope: t.category, alias_text: l.typeText, product_id: c.productId }); }
      }
      if (l.colourText && c.colorId && (l.colour?.status !== 'exact' || l.colour.id !== c.colorId)) {
        const k = `c|${normalize(l.colourText)}`;
        if (!seen.has(k)) { seen.add(k); aliases.push({ alias_type: 'color', scope: '', alias_text: l.colourText, color_id: c.colorId }); }
      }
    }
    for (const t of matched.tables) {
      const chosen = tableChoice[t.index]?.categoryId;
      if (t.category && chosen && t.cat.id !== chosen) aliases.push({ alias_type: 'category', scope: '', alias_text: t.category, category_id: chosen });
    }

    setBusy(true);
    const { data, error: err } = await supabase.rpc('post_inventory_batch', { p: { movements, aliases } });
    setBusy(false);
    if (err) { setError(dbErrorMessage(err, "We couldn't post the import. Nothing was recorded.")); return; }
    setResult({ movements: data.length, lines: ready.length, aliases: aliases.length });
    setStep('done');
  }

  if (loadError) return <PageShell title="Import stock sheet" subtitle="Inventory"><div className="card"><ErrorState message={loadError} onRetry={loadCatalog} /></div></PageShell>;

  const canCreate = canManage('products.manage');
  const productOptions = l => {
    const t = matched.tables[l.table];
    const catId = tableChoice[l.table]?.categoryId || t.cat.id;
    const sug = l.product.suggestions.map(s => s.id);
    const inCat = catalog.products.filter(p => p.status === 'active' && p.categoryId === catId && !sug.includes(p.id));
    const rest = catalog.products.filter(p => p.status === 'active' && p.categoryId !== catId && !sug.includes(p.id));
    return { sug: l.product.suggestions, inCat, rest };
  };

  return (
    <PageShell title="Import stock sheet" subtitle="Inventory">
      {step === 'done' ? (
        <div className="card"><div className="card-body flex flex-col gap-12">
          <p className="flex items-center gap-8"><CheckCircle2 size={18} className="text-success" /> Posted {result.lines} opening-balance lines in {result.movements} movement{result.movements === 1 ? '' : 's'}.</p>
          {result.aliases > 0 && <p className="text-sm text-muted">{result.aliases} name match{result.aliases === 1 ? '' : 'es'} remembered for the next sheet.</p>}
          <div className="flex gap-8">
            <button type="button" className="btn btn-primary" onClick={() => navigate('/movements')}>See movements</button>
            <button type="button" className="btn btn-outline" onClick={() => navigate('/stock')}>See stock</button>
          </div>
        </div></div>
      ) : (
        <div className="flex flex-col gap-16">
          <div className="card"><div className="card-body flex flex-col gap-12">
            <p className="text-sm text-muted">
              One file, one table per category: a heading like <code>== FLOOR TILES (unit: SQM) ==</code>, then <code>Type</code> and either one column per
              colour or a single <code>Qty</code>. A bare number is in the table's unit; <code>4pcs</code> overrides it for that cell. Nothing is recorded until you post.
            </p>
            <div className="form-row">
              <div className="form-group">
                <label className="form-label" htmlFor="imp-wh">Store</label>
                <select id="imp-wh" className="form-input" value={warehouseId} onChange={e => setWarehouseId(e.target.value)}>
                  <option value="">Choose…</option>
                  {warehouses.map(w => <option key={w.id} value={w.id}>{warehouseLabel(w)}</option>)}
                </select>
                {!warehouses.length && catalog && <span className="form-hint">You need stock-adjustment permission at a store to import opening balances.</span>}
              </div>
              <div className="form-group">
                <label className="form-label" htmlFor="imp-date">Stock as of</label>
                <input id="imp-date" type="date" className="form-input" max={today} value={date} onChange={e => setDate(e.target.value)} />
                <span className="form-hint">Applies to every line unless you change a line's own date below.</span>
              </div>
            </div>
            <label className="btn btn-outline" style={{ alignSelf: 'flex-start' }}>
              <Upload size={14} /> {fileName ? `Replace ${fileName}` : 'Choose file (.csv)'}
              <input type="file" accept=".csv,.txt,text/csv,text/plain" hidden onChange={onFile} disabled={!catalog} />
            </label>
          </div></div>

          {matched && (
            <>
              {parsed.issues.length > 0 && (
                <div className="alert alert-error" role="alert">
                  {parsed.issues.map((i, n) => <div key={n}>Line {i.lineNo}: {i.message}</div>)}
                </div>
              )}

              <div className="flex gap-8 text-sm" style={{ flexWrap: 'wrap' }}>
                <span className="badge badge-success">{ready.length} ready</span>
                <span className={`badge ${open.length ? 'badge-warning' : 'badge-neutral'}`}>{open.length} need a decision</span>
                <span className="badge badge-neutral">{skipped.length} skipped</span>
                {dupes.size > 0 && <span className="badge badge-warning">{dupes.size} duplicated</span>}
              </div>

              {matched.tables.map(t => {
                const tl = lines.filter(l => l.table === t.index);
                const tc = tableChoice[t.index] || {};
                return (
                  <div key={t.index} className="card">
                    <div className="card-header" style={{ flexWrap: 'wrap', gap: 8 }}>
                      <h2 className="card-title">{t.category || <span className="text-error">Table with no category name (line {t.firstLine})</span>}</h2>
                      <div className="flex items-center gap-8" style={{ flexWrap: 'wrap' }}>
                        <select className="form-input" style={{ width: 'auto' }} aria-label="Category" value={tc.categoryId}
                          onChange={e => chooseTableCategory(t, e.target.value)}>
                          <option value="">{t.cat.status === 'none' ? 'Category: no match — choose' : 'Category…'}</option>
                          {catalog.categories.filter(c => c.status === 'active').map(c => (
                            <option key={c.id} value={c.id}>{c.name}{t.cat.suggestions.some(s => s.id === c.id) ? ' (suggested)' : ''}</option>
                          ))}
                        </select>
                        <select className="form-input" style={{ width: 'auto' }} aria-label="Table unit" value={tc.unitId}
                          onChange={e => setTableChoice(x => ({ ...x, [t.index]: { ...tc, unitId: e.target.value } }))}>
                          <option value="">{t.defaultUnit ? `Unit "${t.defaultUnit}" not found` : 'Unit: none stated — choose'}</option>
                          {catalog.units.map(u => <option key={u.id} value={u.id}>{u.symbol}</option>)}
                        </select>
                      </div>
                    </div>
                    <div className="table-container">
                      <table>
                        <thead><tr><th>On the sheet</th><th>Product</th><th>Colour</th><th style={{ textAlign: 'right' }}>Quantity</th><th>Date</th><th>Status</th></tr></thead>
                        <tbody>
                          {tl.map(l => {
                            const c = choices[l.id] || {};
                            const e = effective(l);
                            const prod = prodById[c.productId];
                            const pcat = prod && catById[prod.categoryId];
                            const problems = c.skip ? [] : problemsOf(l);
                            const opts = productOptions(l);
                            const unitMismatch = prod && e.unitId && e.unitId !== prod.unitId;
                            const canConvert = unitMismatch && prod.pcsPerSqm && normalize(unitById[e.unitId]?.symbol) === 'pcs';
                            return (
                              <tr key={l.id} className={c.skip ? 'row-muted' : ''}>
                                <td className="text-sm">
                                  <div style={{ fontWeight: 500 }}>{l.typeText}</div>
                                  <div className="text-xs text-muted">{l.colourText ? `${l.colourText} · ` : ''}{l.raw}{!l.unitExplicit && l.unitText ? ` ${l.unitText}` : ''} · line {l.lineNo}</div>
                                </td>
                                <td>
                                  <select className="form-input" aria-label="Product" value={c.productId} disabled={c.skip}
                                    onChange={ev => setChoice(l.id, { productId: ev.target.value, colorId: l.colour?.id ?? '' })}>
                                    <option value="">{l.product.status === 'none' ? 'No match — choose…' : 'Choose…'}</option>
                                    {opts.sug.length > 0 && <optgroup label="Suggested">
                                      {opts.sug.map(s => <option key={s.id} value={s.id}>{prodById[s.id]?.name}{s.otherCategory ? ` — ${catById[prodById[s.id]?.categoryId]?.name}` : ''}{s.strong ? ' ✓' : ''}</option>)}
                                    </optgroup>}
                                    <optgroup label="This category">{opts.inCat.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}</optgroup>
                                    <optgroup label="Other categories">{opts.rest.map(p => <option key={p.id} value={p.id}>{p.name} — {catById[p.categoryId]?.name}</option>)}</optgroup>
                                  </select>
                                  {l.product.status === 'exact' && c.productId === l.product.id && <div className="text-xs text-muted">{l.product.via}</div>}
                                </td>
                                <td>
                                  {pcat?.colorIds.length ? (
                                    <>
                                      <select className="form-input" aria-label="Colour" value={c.colorId} disabled={c.skip} onChange={ev => setChoice(l.id, { colorId: ev.target.value })}>
                                        <option value="">{l.colourText ? `"${l.colourText}" — choose…` : 'Choose…'}</option>
                                        {pcat.colorIds.map(id => <option key={id} value={id}>{colById[id]?.name}</option>)}
                                      </select>
                                      {l.colourText && !c.colorId && canCreate && !catalog.colors.some(x => normalize(x.name) === normalize(l.colourText) && pcat.colorIds.includes(x.id)) && (
                                        <button type="button" className="btn btn-ghost btn-sm" disabled={busy} onClick={() => createColour(l)}>
                                          Add {l.colourText.toLowerCase()} to {pcat.name}
                                        </button>
                                      )}
                                    </>
                                  ) : <span className="text-muted">—</span>}
                                </td>
                                <td style={{ textAlign: 'right' }}>
                                  {qtyText(c.qty)} {unitById[e.unitId]?.symbol ?? l.unitText ?? ''}
                                  {canConvert && !c.skip && (
                                    <div>
                                      <button type="button" className="btn btn-ghost btn-sm"
                                        onClick={() => setChoice(l.id, { qty: Math.round((l.qty / prod.pcsPerSqm) * 10000) / 10000, unitId: prod.unitId, converted: true })}>
                                        Convert at {prod.pcsPerSqm} pcs/m² → {qtyText(Math.round((l.qty / prod.pcsPerSqm) * 10000) / 10000)} {unitById[prod.unitId]?.symbol}
                                      </button>
                                    </div>
                                  )}
                                  {c.converted && <div className="text-xs text-muted">from {l.qty}{l.unitText}</div>}
                                </td>
                                <td>
                                  <input type="date" className="form-input" style={{ width: 150 }} max={today} aria-label="Line date"
                                    value={c.date || date} disabled={c.skip} onChange={ev => setChoice(l.id, { date: ev.target.value === date ? '' : ev.target.value })} />
                                </td>
                                <td className="text-xs">
                                  {c.skip ? <span className="text-muted">skipped</span>
                                    : problems.length ? <span className="text-error flex items-center gap-4"><AlertTriangle size={12} /> {problems.join('; ')}</span>
                                    : dupes.has(l.id) ? <span className="text-error">same product and colour twice</span>
                                    : <span className="text-success">ready</span>}
                                  <label className="flex items-center gap-4 mt-8">
                                    <input type="checkbox" checked={!!c.skip} onChange={ev => setChoice(l.id, { skip: ev.target.checked })} /> skip
                                  </label>
                                </td>
                              </tr>
                            );
                          })}
                        </tbody>
                      </table>
                    </div>
                  </div>
                );
              })}

              {step === 'preview' ? (
                <div className="card">
                  <div className="card-header"><h2 className="card-title">Preview — {ready.length} lines</h2></div>
                  <div className="table-container">
                    <table>
                      <thead><tr><th>Product</th><th>Colour</th><th>Date</th><th style={{ textAlign: 'right' }}>Quantity</th><th style={{ textAlign: 'right' }}>Running total</th></tr></thead>
                      <tbody>
                        {(() => {
                          const run = {};
                          return [...ready].sort((a, b) => (prodById[effective(a).productId]?.name || '').localeCompare(prodById[effective(b).productId]?.name || ''))
                            .map(l => {
                              const e = effective(l);
                              const u = unitById[e.unitId]?.symbol;
                              run[u] = (run[u] || 0) + Number(e.qty);
                              return (
                                <tr key={l.id}>
                                  <td>{prodById[e.productId]?.name}</td>
                                  <td className="text-muted">{colById[e.colorId]?.name ?? '—'}</td>
                                  <td className="text-muted">{e.date || date}</td>
                                  <td style={{ textAlign: 'right' }}>{qtyText(e.qty)} {u}</td>
                                  <td style={{ textAlign: 'right' }} className="text-muted">{qtyText(run[u])} {u}</td>
                                </tr>
                              );
                            });
                        })()}
                      </tbody>
                    </table>
                  </div>
                  <div className="card-body flex flex-col gap-8">
                    {error && <div className="alert alert-error" role="alert">{error}</div>}
                    <p className="text-sm text-muted">
                      Posts {ready.length} opening balances at {warehouseLabel(warehouses.find(w => w.id === warehouseId))}
                      {skipped.length ? `; ${skipped.length} skipped lines are not recorded` : ''}. All or nothing — and an item that already has stock here is refused.
                    </p>
                    <div className="flex gap-8">
                      <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={post}>Post {ready.length} opening balances</button>
                      <button type="button" className="btn btn-ghost" onClick={() => setStep('resolve')}>Back</button>
                    </div>
                  </div>
                </div>
              ) : (
                <div className="flex flex-col gap-8">
                  {error && <div className="alert alert-error" role="alert">{error}</div>}
                  <button type="button" className="btn btn-primary" style={{ alignSelf: 'flex-start' }}
                    disabled={!ready.length || open.length > 0 || dupes.size > 0 || !warehouseId}
                    onClick={() => setStep('preview')}>
                    {open.length ? `Resolve or skip ${open.length} line${open.length === 1 ? '' : 's'} first` : !warehouseId ? 'Choose the store first' : `Preview ${ready.length} lines`}
                  </button>
                  <p className="text-xs text-muted">Need a product that doesn't exist yet? Add it under <Link to="/products">Products</Link>, then choose the file again.</p>
                </div>
              )}
            </>
          )}
        </div>
      )}
    </PageShell>
  );
}
