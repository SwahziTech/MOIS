import { useEffect, useMemo, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Upload, Trash2, AlertTriangle, FileImage } from 'lucide-react';
import { supabase } from '../../lib/supabase';
import { useAuth } from '../../hooks/useAuth';
import { dbErrorMessage } from '../../lib/masterData';
import { formatAmount, dateText, tableDate } from '../../lib/format';
import { loadDayFacts, readReport, bestMatch, words } from '../../lib/dailyReport';
import { useProductionLists } from '../production/BatchNotes';
import NumberInput from '../NumberInput';

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
 * Production report only for now; sales, stock count and past sales follow.
 */
export default function ReportUpload({ refs, branchId, branchName, today }) {
  const { organization, canAt } = useAuth();
  const navigate = useNavigate();
  const [lists] = useProductionLists(branchId);
  const [kind, setKind] = useState('production');
  const [date, setDate] = useState(today);
  const [file, setFile] = useState(null);
  const [preview, setPreview] = useState('');
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
  useEffect(() => () => { if (preview) URL.revokeObjectURL(preview); }, [preview]);

  function pickFile(e) {
    const f = e.target.files?.[0];
    e.target.value = '';
    if (!f) return;
    if (f.size > 10 * 1024 * 1024) { setError('That file is over 10 MB. Take the photo again at a smaller size.'); return; }
    setError('');
    setFile(f);
    setPreview(f.type.startsWith('image/') ? URL.createObjectURL(f) : '');
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
      // 1. the photo and the text, kept with the day
      let path = null;
      if (file) {
        const ext = (file.name.split('.').pop() || 'jpg').toLowerCase().replace(/[^a-z0-9]/g, '');
        path = `${organization.id}/${branchId}/${date}/${Date.now()}.${ext}`;
        const up = await supabase.storage.from('report-photos').upload(path, file, { contentType: file.type || undefined, upsert: false });
        if (up.error) throw up.error;
      }
      if (path || text.trim()) {
        const { error: err } = await supabase.rpc('record_report_upload', { p: { branch_id: branchId, report_date: date, kind, file_path: path, file_name: file?.name ?? null, report_text: text.trim() || null } });
        if (err) throw err;
      }
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
      setRead(null); setText(''); setFile(null); setPreview(''); setTried(false);
      await loadDay();
    } catch (e) {
      setError(dbErrorMessage(e, "We couldn't save the report. Please try again."));
    } finally {
      setBusy(false);
    }
  }
  async function openKept(u) {
    const { data } = await supabase.storage.from('report-photos').createSignedUrl(u.file_path, 300);
    if (data?.signedUrl) window.open(data.signedUrl, '_blank', 'noopener');
  }

  if (!canUpload) return <div className="card"><div className="card-body"><p className="text-sm">Uploading reports is for the Branch Manager and the Secretary at {branchName}.</p></div></div>;

  const nBatches = read?.batches.length ?? 0;
  const pieces = read ? read.batches.reduce((t, b) => t + (num(b.pieces) || 0) + b.leftovers.reduce((s, l) => s + (num(l.pieces) || 0), 0), 0) : 0;
  return (
    <>
      <div className="mm-stats">
        <div className="mm-stat"><span className="pl-label">Read</span><strong>{read ? `${nBatches} batch${nBatches === 1 ? '' : 'es'}` : '—'}</strong><span className="pl-help">{read ? `${formatAmount(pieces)} pcs · ${read.meters.length} meter${read.meters.length === 1 ? '' : 's'}` : 'paste the report, then Read'}</span></div>
        <div className="mm-stat"><span className="pl-label">To type</span><strong className={toType ? 'text-warning' : ''}>{read ? toType : '—'}</strong><span className="pl-help">details the report doesn't hold</span></div>
        <div className="mm-stat"><span className="pl-label">Already in MOIS</span><strong className={already ? 'text-warning' : ''}>{facts ? `${formatAmount(already)} pcs` : '…'}</strong><span className="pl-help">for {tableDate(date)}{kept.length ? ` · ${kept.length} upload${kept.length === 1 ? '' : 's'} kept` : ''}</span></div>
      </div>

      <div className="filter-chips" style={{ margin: '12px 0 8px' }}>
        {KINDS.map(([k, label]) => (
          <button key={k} type="button" className={`filter-chip${kind === k ? ' is-on' : ''}`} onClick={() => setKind(k)}
            title={k === 'production' ? undefined : 'Coming next'}>{label}{k === 'production' ? '' : ' · soon'}</button>
        ))}
      </div>

      {kind !== 'production' ? (
        <div className="card"><div className="card-body"><p className="text-sm">{KINDS.find(x => x[0] === kind)[1]} uploads come next, the same way: the photo is read, you type what's missing, then save.</p></div></div>
      ) : (
        <>
          <div className="card ru-file"><div className="card-body">
            <div className="ru-thumb">{preview ? <img src={preview} alt="The report" /> : <FileImage size={28} aria-hidden="true" />}</div>
            <div className="ru-file-info">
              <strong>{file ? file.name : 'No photo yet'}</strong>
              <span className="pl-help">{file ? 'Kept with the day when you save.' : 'A photo or PDF of the report. Reading it by AI comes later; for now paste the text below too.'}</span>
              <label className="pe-field" style={{ maxWidth: 200, marginTop: 8 }}><span>Day of the report</span>
                <input type="date" className="form-input" max={today} value={date} onChange={e => setDate(e.target.value || today)} /></label>
              {read?.readDate && read.readDate !== date && <span className="pl-help text-warning">The report says {dateText(read.readDate)}.</span>}
            </div>
            <label className="btn btn-outline btn-sm"><Upload size={14} /> {file ? 'Replace photo' : 'Choose photo or PDF'}
              <input type="file" accept="image/*,application/pdf" hidden onChange={pickFile} /></label>
          </div></div>

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
              <span className="pl-help">Batches open in Production one by one, with the materials and stock checks, before the day is saved.</span>
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
