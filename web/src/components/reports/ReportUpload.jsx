import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Upload, Trash2, AlertTriangle, FileImage } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { files } from '../../lib/files';
import { shrinkImage } from '../../lib/shrinkImage';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { formatAmount, dateText, tableDate } from '../../lib/format';
import { loadDayFacts, readReport, bestMatch, words } from '../../lib/dailyReport';
import { useProductionLists } from '../production/BatchNotes';
import NumberInput from '../NumberInput';
import SalesUpload from './SalesUpload';

const num = v => (String(v ?? '').trim() === '' ? null : Number(String(v).replace(/,/g, '')));
const KINDS = [['production', 'Production report'], ['sales', 'Sales sheet'], ['stock', 'Stock count'], ['past_sales', 'Past sales']];

/*
 * Upload a report (2026-11-03, the user): a report can come in typed, or as an
 * uploaded photo or PDF that MOIS reads. The photo is kept with the branch and
 * day (103). For now the report's text is pasted (WhatsApp); reading the photo
 * by AI comes later and fills the same rows.
 * Each row read is matched to MOIS; what the report doesn't hold (team,
 * machine, a colour, a missing number) is typed here and shows red until it
 * is. Saving keeps the photo and text, records the meter readings, and hands
 * the batches to Production, where each goes through the usual form — recipe,
 * stock and yield checks — before the day is saved.
 * Sales sheet and past sales (2026-11-03): a typing grid beside the pages,
 * handed to Sales › Record sale one sale at a time (components/reports/SalesUpload).
 * Stock count follows.
 */
export default function ReportUpload({ refs, branchId, branchName, today }) {
  const { organization, canAt } = useAuth();
  const navigate = useNavigate();
  const [lists] = useProductionLists(branchId);
  const [kind, setKind] = useState('production');
  const [date, setDate] = useState(today);
  const [salesStats, setSalesStats] = useState(null);   // the sales grid's summary, shown in the summary cards
  const [files, setFiles] = useState([]);       // [{ file, preview }] — the pages, kept with the day
  const [text, setText] = useState('');
  const [read, setRead] = useState(null);       // { batches, meters, cementStore } once read
  const [facts, setFacts] = useState(null);     // what MOIS holds for the day
  const [meters, setMeters] = useState([]);
  const [kept, setKept] = useState([]);         // uploads already kept for this day
  const [tried, setTried] = useState(false);    // Save pressed: show what is missing
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const canUpload = canAt('production.create', branchId, null);

  const carried = useMemo(() => Object.values(refs.items)
    .filter(i => i.kind === 'product' && i.status === 'active' && refs.carriedByBranch?.[branchId]?.has(i.id))
    .sort((a, b) => a.name.localeCompare(b.name)), [refs, branchId]);
  const teams = (lists?.teams || []).filter(t => t.status === 'active');
  const people = (lists?.people || []).filter(p => p.status === 'active' && p.in_production_cost !== false);
  const membersOf = teamId => (teams.find(t => t.id === teamId)?.members || [])
    .filter(m => m.status === 'active' && m.staff_id && people.some(p => p.id === m.staff_id)).map(m => m.staff_id);
  const machinesFor = productId => {
    const all = (lists?.machines || []).filter(m => m.status === 'active');
    const linked = all.filter(m => lists.links.some(l => l.machine_id === m.id && l.product_id === productId));
    return linked.length ? linked : all;
  };

  useEffect(() => {
    supabase.from('power_meters').select('id, name, status').eq('branch_id', branchId).order('name')
      .then(({ data }) => setMeters((data || []).filter(m => m.status === 'active')));
  }, [branchId]);
  async function loadDay() {
    setFacts(null);
    loadDayFacts({ branchId, date, today, refs }).then(setFacts).catch(() => setFacts(null));
    const { data, error: err } = await supabase.from('report_uploads').select('id, kind, file_path, file_name, report_text, created_at')
      .eq('branch_id', branchId).eq('report_date', date).order('created_at', { ascending: false });
    setKept(err ? [] : data || []);
  }
  useEffect(() => { loadDay(); }, [branchId, date]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => () => files.forEach(x => x.preview && URL.revokeObjectURL(x.preview)), [files]);

  function pickFiles(e) {
    const picked = [...(e.target.files || [])];
    e.target.value = '';
    if (!picked.length) return;
    if (picked.some(f => f.size > 10 * 1024 * 1024)) { setError('A file is over 10 MB. Take the photo again at a smaller size.'); return; }
    setError('');
    setFiles(fs => [...fs, ...picked.map(f => ({ file: f, preview: f.type.startsWith('image/') ? URL.createObjectURL(f) : '' }))]);
  }
  // the pages and the text, kept with the branch and day (103)
  async function keep(reportKind, reportText) {
    const at = Date.now();
    const rows = [];
    for (const [i, { file: raw }] of files.entries()) {
      const file = await shrinkImage(raw, { max: 2400 });   // smaller before upload (2026-11-11); sheets keep more detail
      const ext = (file.name.split('.').pop() || 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '');
      const path = `${organization.id}/${branchId}/${date}/${at}-${i + 1}.${ext}`;
      const up = await files('report-photos').upload(path, file, { contentType: file.type || undefined, upsert: false });
      if (up.error) throw up.error;
      rows.push({ file_path: path, file_name: file.name });
    }
    if (!rows.length && reportText) rows.push({});
    for (const [i, r] of rows.entries()) {
      const { error: err } = await supabase.rpc('record_report_upload', { p: { branch_id: branchId, report_date: date, kind: reportKind, ...r, report_text: i === 0 ? reportText || null : null } });
      if (err) throw err;
    }
  }

  // a written colour in the product's line ("TOFALI 5 RED") → that colour, if the product comes in it
  const colourIn = (name, product) => {
    const w = words(name);
    return (product?.colorIds || []).find(id => w.includes(String(refs.colorById[id]?.name || '').toLowerCase())) ?? '';
  };
  function readIt() {
    setTried(false); setError('');
    const r = readReport(text);
    if (!r.products.length && !r.meters.length && r.cementStore == null) {
      setRead(null);
      setError("MOIS couldn't find production, cement or meters in that text. Check it follows the daily report format.");
      return;
    }
    if (r.date && r.date <= today) setDate(r.date);
    const left = [...carried];
    const batches = r.products.map((p, i) => {
      const m = bestMatch(p.name, left);
      return {
        key: `b${i}`, readName: p.name, productId: m?.id ?? '', colorId: m ? colourIn(p.name, m) : '',
        pieces: p.pieces ?? '', bags: p.cement ?? '', people: p.people, teamId: '', machineId: '',
        leftovers: p.leftovers.map((l, j) => ({ key: `l${j}`, readName: l.name, productId: bestMatch(l.name, carried)?.id ?? '', pieces: l.pieces ?? '' })),
      };
    });
    const usedM = new Set();
    const ms = r.meters.map((x, i) => {
      const m = bestMatch(x.name, meters.filter(y => !usedM.has(y)));
      if (m) usedM.add(m);
      return { key: `m${i}`, readName: x.name, meterId: m?.id ?? '', morning: x.morning ?? '', evening: x.evening ?? '' };
    });
    setRead({ batches, meters: ms, cementStore: r.cementStore, readDate: r.date });
  }
  const setBatch = (key, patch) => setRead(x => ({ ...x, batches: x.batches.map(b => (b.key === key ? { ...b, ...patch } : b)) }));
  const setLeftover = (bk, lk, patch) => setRead(x => ({ ...x, batches: x.batches.map(b => (b.key !== bk ? b
    : { ...b, leftovers: b.leftovers.map(l => (l.key === lk ? { ...l, ...patch } : l)) })) }));
  const setMeter = (key, patch) => setRead(x => ({ ...x, meters: x.meters.map(m => (m.key === key ? { ...m, ...patch } : m)) }));

  // what still has to be typed, per field
  const productOf = id => refs.items[`p:${id}`];
  const whole = v => num(v) != null && Number.isInteger(num(v)) && num(v) >= 0;
  const missingOf = b => ({
    product: !b.productId,
    colour: !!b.productId && (productOf(b.productId)?.colorIds?.length ?? 0) > 0 && !b.colorId,
    pieces: !(whole(b.pieces) && num(b.pieces) > 0),
    bags: !(num(b.bags) > 0),
    team: !b.teamId,
    machine: !b.machineId,
    leftovers: b.leftovers.some(l => !l.productId || !whole(l.pieces)),
  });
  // a meter's readings already in MOIS for the day aren't sent again
  const had = (meterId, slot) => {
    const name = meters.find(m => m.id === meterId)?.name;
    const f = facts?.meters.find(m => m.name === name);
    return f ? f[slot] : null;
  };
  const meterMissing = m => !m.meterId && (num(m.morning) != null || num(m.evening) != null);
  const toType = read ? read.batches.reduce((t, b) => t + Object.values(missingOf(b)).filter(Boolean).length, 0) + read.meters.filter(meterMissing).length : 0;
  const bad = on => (tried && on ? ' error' : '');
  const already = facts?.products.reduce((t, p) => t + p.pieces, 0) ?? 0;

  async function save() {
    setTried(true); setError('');
    if (toType) { setError(`Fill the ${toType} red box${toType === 1 ? '' : 'es'} first.`); return; }
    setBusy(true);
    try {
      // 1. the photos and the text, kept with the day
      await keep('production', text.trim());
      // 2. meter readings not yet in MOIS
      const readings = read.meters.filter(m => m.meterId).flatMap(m => ['morning', 'evening']
        .filter(s => num(m[s]) != null && had(m.meterId, s) == null).map(s => ({ meter_id: m.meterId, slot: s, reading: num(m[s]) })));
      if (readings.length) {
        const { error: err } = await supabase.rpc('record_power_readings', { p: { read_on: date, readings } });
        if (err) throw err;
      }
      // 3. the batches go to Production, one at a time through the usual form
      if (read.batches.length) {
        const forms = read.batches.map(b => {
          const main = productOf(b.productId);
          return {
            productId: b.productId, colorId: b.colorId, bags: String(num(b.bags)), pieces: String(num(b.pieces)),
            leftovers: b.leftovers.map(l => ({ productId: l.productId, pieces: String(num(l.pieces)) })),
            allowOther: b.leftovers.some(l => productOf(l.productId)?.categoryId !== main?.categoryId),
            teamId: b.teamId, workerIds: membersOf(b.teamId), machineId: b.machineId,
          };
        });
        try { sessionStorage.setItem(`mois.upload.queue.${organization.id}.${branchId}`, JSON.stringify({ date, forms })); } catch { /* ignore */ }
        navigate('/production?tab=log');
        return;
      }
      setRead(null); setText(''); setFiles([]); setTried(false);
      await loadDay();
    } catch (e) {
      setError(dbErrorMessage(e, "We couldn't save the report. Please try again."));
    } finally {
      setBusy(false);
    }
  }
  async function openKept(u) {
    const { data } = await files('report-photos').createSignedUrl(u.file_path, 300);
    if (data?.signedUrl) window.open(data.signedUrl, '_blank', 'noopener');
  }

  if (!canUpload) return <div className="card"><div className="card-body"><p className="text-sm">Uploading reports is for the Branch Manager and the Secretary at {branchName}.</p></div></div>;

  const nBatches = read?.batches.length ?? 0;
  const pieces = read ? read.batches.reduce((t, b) => t + (num(b.pieces) || 0) + b.leftovers.reduce((s, l) => s + (num(l.pieces) || 0), 0), 0) : 0;
  return (
    <>
      {kind === 'production' && <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Read</span><strong>{read ? `${nBatches} batch${nBatches === 1 ? '' : 'es'}` : '—'}</strong><span className="pl-help">{read ? `${formatAmount(pieces)} pcs · ${read.meters.length} meter${read.meters.length === 1 ? '' : 's'}` : 'paste the report, then Read'}</span></div>
        <div className="mm-stat"><span className="pl-label">To type</span><strong className={toType ? 'text-warning' : ''}>{read ? toType : '—'}</strong><span className="pl-help">details the report doesn't hold</span></div>
        <div className="mm-stat"><span className="pl-label">Already in MOIS</span><strong className={already ? 'text-warning' : ''}>{facts ? `${formatAmount(already)} pcs` : '…'}</strong><span className="pl-help">for {tableDate(date)}{kept.length ? ` · ${kept.length} upload${kept.length === 1 ? '' : 's'} kept` : ''}</span></div>
      </div>}
      {kind !== 'production' && kind !== 'stock' && <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Sales</span><strong>{salesStats?.sales ?? 0}</strong><span className="pl-help">{salesStats ? `${salesStats.rows} row${salesStats.rows === 1 ? '' : 's'}${salesStats.span ? ` · ${salesStats.span}` : ''}` : 'type the rows below'}</span></div>
        <div className="mm-stat"><span className="pl-label">Value</span><strong>Tsh {formatAmount(salesStats?.value ?? 0)}</strong><span className="pl-help">paid Tsh {formatAmount(salesStats?.paid ?? 0)}</span></div>
        <div className="mm-stat"><span className="pl-label">To type</span><strong className={salesStats?.toType ? 'text-warning' : ''}>{salesStats?.toType ?? 0}</strong><span className="pl-help">red boxes</span></div>
      </div>}

      <div className="filter-chips" style={{ margin: '12px 0 8px' }}>
        {KINDS.map(([k, label]) => (
          <button key={k} type="button" className={`filter-chip${kind === k ? ' is-on' : ''}`} onClick={() => setKind(k)}
            title={k === 'stock' ? 'Coming next' : undefined}>{label}{k === 'stock' ? ' · soon' : ''}</button>
        ))}
      </div>

      <div className="card ru-file"><div className="card-body">
        <div className="ru-thumbs">
          {files.length ? files.map((x, i) => (
            <div key={i} className="ru-thumb" title={x.file.name}>{x.preview ? <img src={x.preview} alt={`Page ${i + 1}`} /> : <FileImage size={24} aria-hidden="true" />}
              <button type="button" className="ru-thumb-x" aria-label={`Remove page ${i + 1}`} onClick={() => setFiles(fs => fs.filter((_, j) => j !== i))}>×</button></div>
          )) : <div className="ru-thumb"><FileImage size={28} aria-hidden="true" /></div>}
        </div>
        <div className="ru-file-info">
          <strong>{files.length ? `${files.length} page${files.length === 1 ? '' : 's'}` : 'No photo yet'}</strong>
          <span className="pl-help">{files.length ? 'Kept with the day when you save.' : kind === 'production' ? 'Photo or PDF of the report; paste its text below.' : 'Photos of the sales book; type the rows below.'}</span>
          <label className="pe-field" style={{ maxWidth: 200, marginTop: 8 }}><span>{kind === 'past_sales' ? 'Day the pages were uploaded' : 'Day of the report'}</span>
            <input type="date" className="form-input" max={today} value={date} onChange={e => setDate(e.target.value || today)} /></label>
          {kind === 'production' && read?.readDate && read.readDate !== date && <span className="pl-help text-warning">The report says {dateText(read.readDate)}.</span>}
        </div>
        <label className="btn btn-outline btn-sm"><Upload size={14} /> {files.length ? 'Add page' : 'Choose photo or PDF'}
          <input type="file" accept="image/*,application/pdf" multiple hidden onChange={pickFiles} /></label>
      </div></div>

      {kind === 'stock' ? (
        <div className="card"><div className="card-body"><p className="text-sm">Coming next.</p></div></div>
      ) : kind !== 'production' ? (
        <SalesUpload key={kind} refs={refs} branchId={branchId} today={today} day={date} past={kind === 'past_sales'} keep={keep} onStats={setSalesStats} />
      ) : (
        <>

          <div className="card"><div className="card-body">
            <label className="pe-field"><span>The report's text (as sent on WhatsApp)</span>
              <textarea className="form-input dr-paste ru-paste" rows={8} placeholder={'RIPOTI YA … TAREHE …\nUZALISHAJI WA …\nPcs … Cem …\n…'} value={text} onChange={e => setText(e.target.value)} /></label>
            <div className="flex items-center gap-8" style={{ marginTop: 8 }}>
              <button type="button" className="btn btn-outline btn-sm" onClick={readIt} disabled={!text.trim()}>{read ? 'Read again' : 'Read the report'}</button>
              {read && <span className="pl-help">Reading again replaces what you typed below.</span>}
            </div>
          </div></div>

          {read && (
            <div className="card"><div className="card-body">
              {already > 0 && <div className="alert alert-warning" role="note"><AlertTriangle size={14} /> MOIS already has {formatAmount(already)} pieces for {dateText(date)}. Check these aren't the same batches.</div>}
              <h3 className="ru-h">Production</h3>
              {read.batches.length === 0 ? <p className="pl-help">No production in the report.</p> : (
                <div className="table-container"><table className="ru-table">
                  <thead><tr><th>Product (read → MOIS)</th><th>Colour</th><th className="num">Pieces</th><th className="num">Cement (bags)</th><th>Team</th><th>Machine</th><th /></tr></thead>
                  <tbody>
                    {read.batches.map(b => {
                      const miss = missingOf(b);
                      const main = productOf(b.productId);
                      return [
                        <tr key={b.key}>
                          <td><span className="pl-help">"{b.readName}" →</span>
                            <select className={`form-input${bad(miss.product)}`} aria-label="Product" value={b.productId} onChange={e => setBatch(b.key, { productId: e.target.value, colorId: '', machineId: '' })}>
                              <option value="">Choose…</option>
                              {carried.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
                            </select></td>
                          <td>{main?.colorIds?.length ? (
                            <select className={`form-input${bad(miss.colour)}`} aria-label="Colour" value={b.colorId} onChange={e => setBatch(b.key, { colorId: e.target.value })}>
                              <option value="">Choose…</option>
                              {main.colorIds.map(id => <option key={id} value={id}>{refs.colorById[id]?.name}</option>)}
                            </select>) : <span className="pl-help">—</span>}</td>
                          <td><NumberInput className={`form-input num${bad(miss.pieces)}`} step="1" min="0" aria-label="Pieces" value={b.pieces} onChange={e => setBatch(b.key, { pieces: e.target.value })} /></td>
                          <td><NumberInput className={`form-input num${bad(miss.bags)}`} min="0" aria-label="Cement bags" value={b.bags} onChange={e => setBatch(b.key, { bags: e.target.value })} /></td>
                          <td><select className={`form-input${bad(miss.team)}`} aria-label="Team" value={b.teamId} onChange={e => setBatch(b.key, { teamId: e.target.value })}>
                              <option value="">Choose…</option>
                              {teams.map(t => <option key={t.id} value={t.id}>{t.name} ({membersOf(t.id).length})</option>)}
                            </select>{b.people != null && <span className="pl-help">read: watu {b.people}</span>}</td>
                          <td><select className={`form-input${bad(miss.machine)}`} aria-label="Machine" value={b.machineId} onChange={e => setBatch(b.key, { machineId: e.target.value })}>
                              <option value="">Choose…</option>
                              {machinesFor(b.productId).map(m => <option key={m.id} value={m.id}>{m.name}</option>)}
                            </select></td>
                          <td><button type="button" className="icon-btn" aria-label="Remove batch" title="Not this batch" onClick={() => setRead(x => ({ ...x, batches: x.batches.filter(y => y.key !== b.key) }))}><Trash2 size={14} /></button></td>
                        </tr>,
                        ...b.leftovers.map(l => (
                          <tr key={`${b.key}${l.key}`} className="ru-leftover">
                            <td><span className="pl-help">↳ mabaki "{l.readName}" →</span>
                              <select className={`form-input${bad(!l.productId)}`} aria-label="Leftover product" value={l.productId} onChange={e => setLeftover(b.key, l.key, { productId: e.target.value })}>
                                <option value="">Choose…</option>
                                {carried.filter(p => p.id !== b.productId).map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
                              </select></td>
                            <td><span className="pl-help">same as main</span></td>
                            <td><NumberInput className={`form-input num${bad(!whole(l.pieces))}`} step="1" min="0" aria-label="Leftover pieces" value={l.pieces} onChange={e => setLeftover(b.key, l.key, { pieces: e.target.value })} /></td>
                            <td colSpan={3}><span className="pl-help">leftover · same batch, no cement of its own</span></td>
                            <td><button type="button" className="icon-btn" aria-label="Remove leftover" onClick={() => setBatch(b.key, { leftovers: b.leftovers.filter(y => y.key !== l.key) })}><Trash2 size={14} /></button></td>
                          </tr>
                        )),
                      ];
                    })}
                  </tbody>
                </table></div>
              )}

              <h3 className="ru-h">Cement and electricity</h3>
              <div className="table-container"><table className="ru-table">
                <thead><tr><th>What</th><th className="num">Morning</th><th className="num">Evening</th><th>MOIS</th><th /></tr></thead>
                <tbody>
                  <tr>
                    <td>Cement in store (bags)</td>
                    <td className="num" colSpan={2}>{read.cementStore != null ? formatAmount(read.cementStore) : <span className="pl-help">not in the report</span>}</td>
                    <td className="pl-help">{facts?.cementStore != null ? `${formatAmount(facts.cementStore)}${read.cementStore != null && Math.abs(read.cementStore - facts.cementStore) >= 0.5 ? ` · differs by ${formatAmount(Math.abs(read.cementStore - facts.cementStore))}` : ''}` : '—'}</td>
                    <td />
                  </tr>
                  {read.meters.map(m => (
                    <tr key={m.key}>
                      <td><span className="pl-help">"{m.readName}" →</span>
                        <select className={`form-input${bad(meterMissing(m))}`} aria-label="Meter" value={m.meterId} onChange={e => setMeter(m.key, { meterId: e.target.value })}>
                          <option value="">Choose…</option>
                          {meters.map(x => <option key={x.id} value={x.id}>{x.name}</option>)}
                        </select></td>
                      {['morning', 'evening'].map(s => (
                        <td key={s}>{had(m.meterId, s) != null
                          ? <span className="pl-help" title="Already recorded; not sent again">{formatAmount(had(m.meterId, s))} in MOIS</span>
                          : <NumberInput className="form-input num" min="0" aria-label={s} value={m[s]} onChange={e => setMeter(m.key, { [s]: e.target.value })} />}</td>
                      ))}
                      <td className="pl-help">{num(m.morning) != null && num(m.evening) != null ? `${formatAmount(num(m.morning) - num(m.evening))} units used` : ''}</td>
                      <td><button type="button" className="icon-btn" aria-label="Remove meter" onClick={() => setRead(x => ({ ...x, meters: x.meters.filter(y => y.key !== m.key) }))}><Trash2 size={14} /></button></td>
                    </tr>
                  ))}
                </tbody>
              </table></div>
            </div></div>
          )}

          {error && <div className="alert alert-error" role="alert">{error}</div>}
          {read && (
            <div className="ru-actions">
              <span className="pl-help">Opens in Production, one batch at a time.</span>
              <button type="button" className="btn btn-outline" onClick={() => { setRead(null); setTried(false); setError(''); }}>Cancel</button>
              <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={save}>
                {nBatches ? `Save and open ${nBatches} batch${nBatches === 1 ? '' : 'es'} in Production` : 'Save readings'}</button>
            </div>
          )}

          {kept.length > 0 && (
            <div className="card" style={{ marginTop: 12 }}><div className="card-body">
              <h3 className="ru-h">Kept for {dateText(date)}</h3>
              <ul className="ru-kept">
                {kept.map(u => (
                  <li key={u.id}>{u.file_path ? <button type="button" className="link-btn" onClick={() => openKept(u)}>{u.file_name || 'Photo'}</button> : <span>Text only</span>}
                    <span className="pl-help"> · {KINDS.find(x => x[0] === u.kind)?.[1]} · {new Date(u.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</span></li>
                ))}
              </ul>
            </div></div>
          )}
        </>
      )}
    </>
  );
}
