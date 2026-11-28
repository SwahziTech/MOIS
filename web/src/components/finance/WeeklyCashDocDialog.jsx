import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { Download, Printer, ChevronDown } from 'lucide-react';
import Modal from '../Modal';
import { PAPERS, pickPaper, lwCells, reqCells, downloadPdf, printPdf, downloadExcel, downloadCsv } from '../../lib/weeklyCashDoc';

/*
 * Page setup + preview for the weekly cash report (2026-11-15, the user), like Excel's print window:
 * paper (A3 by default, one page), portrait/landscape; Save as PDF, Excel or CSV; or print.
 * mode 'review': shown before Submit / Post — the page as the directors will see it; Edit goes back.
 */
export default function WeeklyCashDocDialog({ doc, mode = 'export', defaultFormat = 'pdf', confirmLabel, busy = false, note = null, onConfirm, onClose }) {
  const [setup, setSetup] = useState(() => pickPaper(doc));
  const [menu, setMenu] = useState(false);   // "Save as" choices (2026-11-15, the user)
  const [working, setWorking] = useState(false);
  const [error, setError] = useState('');
  const run = async fn => { setError(''); setWorking(true); try { await fn(); } catch (e) { console.error(e); setError('That could not be made. Please try again.'); } setWorking(false); };
  const FORMATS = { pdf: ['PDF (.pdf)', () => downloadPdf(doc, setup)], excel: ['Excel (.xlsx)', () => downloadExcel(doc, setup)], csv: ['CSV (.csv)', () => downloadCsv(doc)] };
  // the usual one first: PDF for readers, Excel for whoever edits
  const order = [defaultFormat, ...Object.keys(FORMATS).filter(k => k !== defaultFormat)];
  const saveAs = k => { setMenu(false); run(FORMATS[k][1]); };
  const chip = (on, label, click) => <button type="button" className={`filter-chip${on ? ' is-on' : ''}`} onClick={click}>{label}</button>;

  return (
    <Modal title={mode === 'review' ? 'Check before sending' : 'Export'} onClose={onClose} size="xl"
      footer={<>
        <div className="wc-foot-left">
          <div className="wc-saveas">
            <button type="button" className="btn btn-ghost" disabled={working} aria-haspopup="menu" aria-expanded={menu} onClick={() => setMenu(m => !m)}><Download size={14} /> Save as <ChevronDown size={14} /></button>
            {menu && (
              <div className="wc-saveas-menu" role="menu">
                {order.map(k => <button key={k} type="button" role="menuitem" onClick={() => saveAs(k)}>{FORMATS[k][0]}</button>)}
              </div>
            )}
          </div>
          <button type="button" className="btn btn-ghost" disabled={working} onClick={() => run(() => printPdf(doc, setup))} title="Print"><Printer size={14} /> Print</button>
        </div>
        {error && <span className="modal-footer-error" role="alert">{error}</span>}
        {mode === 'review' ? <>
          <button type="button" className="btn btn-outline" onClick={onClose}>Edit</button>
          <button type="button" className={`btn btn-primary${busy ? ' btn-loading' : ''}`} disabled={busy} onClick={onConfirm}>{confirmLabel}</button>
        </> : <button type="button" className="btn btn-outline" onClick={onClose}>Close</button>}
      </>}>
      {note && <p className="wc-doc-note">{note}</p>}
      <div className="wc-doc-layout">
        <div className="wc-doc-setup">
          <label className="pe-field"><span>Paper</span>
            <select className="form-input" value={setup.paper} onChange={e => setSetup(s => ({ ...s, paper: e.target.value }))}>
              {Object.keys(PAPERS).map(p => <option key={p} value={p}>{p}{p === pickPaper(doc).paper ? ' (default)' : ''}</option>)}
            </select>
          </label>
          <div className="pe-field"><span>Orientation</span><div className="filter-chips">{chip(setup.orientation === 'portrait', 'Portrait', () => setSetup(s => ({ ...s, orientation: 'portrait' })))}{chip(setup.orientation === 'landscape', 'Landscape', () => setSetup(s => ({ ...s, orientation: 'landscape' })))}</div></div>
          <p className="pl-help" title="Everything is fitted on one page; on a smaller paper the writing gets smaller.">One page.</p>
        </div>
        <PagePreview doc={doc} setup={setup} />
      </div>
    </Modal>
  );
}

// the page, drawn at its real size and shrunk to fit one sheet of the chosen paper
// fitWidth: the full-screen view — the page fills the screen's width and scrolls down (2026-11-16)
// a table at the widths the user gave the sheet on screen (sheetWidths)
// auto layout: the widths are a guide, a column never gets narrower than its longest word (2026-11-28, the user)
const sized = w => (w ? { width: `${w.table * 100}%` } : undefined);
const cols = (w, n) => (w && w.cols.length === n ? <colgroup>{w.cols.map((f, k) => <col key={k} style={{ width: `${f * 100}%` }} />)}</colgroup> : null);
export function PagePreview({ doc, setup, fitWidth = false }) {
  const [pw0, ph0] = PAPERS[setup.paper];
  const [pw, ph] = setup.orientation === 'landscape' ? [ph0, pw0] : [pw0, ph0];
  const box = useRef(null), page = useRef(null);
  const [scale, setScale] = useState(1);
  const [boxW, setBoxW] = useState(420);
  const [pageH, setPageH] = useState(0);
  const natW = (pw - 20) * 3.78;   // printable width in px (10 mm margins)
  // measured again whenever the space changes (a phone turned, a window resized)
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!box.current || typeof ResizeObserver === 'undefined') return undefined;
    const ro = new ResizeObserver(() => setTick(t => t + 1));
    ro.observe(box.current);
    return () => ro.disconnect();
  }, []);
  useLayoutEffect(() => {
    const w = box.current?.clientWidth || 420;
    setBoxW(w);
    const h = page.current?.scrollHeight || 1;
    const usableH = (w * ph / pw) - (w * 20 / pw);
    const sc = fitWidth ? (w - w * 20 / pw) / natW : Math.min(1, (w - w * 20 / pw) / natW, usableH / h);
    setScale(sc);
    setPageH(h * sc);
  }, [doc, setup, natW, pw, ph, tick, fitWidth]);
  const pad = boxW * 10 / pw;
  return (
    <div className="wc-doc-paper-wrap" ref={box}>
      <div className={`wc-doc-paper${fitWidth ? ' is-reading' : ''}`} style={fitWidth ? undefined : { aspectRatio: `${pw} / ${ph}`, padding: pad }}>
        <div ref={page} className="wc-doc-page" style={fitWidth ? undefined : { width: natW, transform: `scale(${scale})` }}>
          {doc.company && <div className="wc-doc-company">{doc.company}</div>}
          {doc.branch && <div className="wc-doc-branch">{doc.branch}</div>}
          <div className="wc-doc-title"><strong>{doc.title}</strong>{doc.status && <span>{doc.status}</span>}</div>
          <table className="wc-doc-table" style={sized(doc.widths?.lw)}>
            {cols(doc.widths?.lw, 6)}
            <thead><tr><th colSpan={6} className="wc-doc-cap">{doc.lw.title}</th></tr>
              <tr><th>DATE</th><th>DESCRIPTION</th><th>QTY</th><th className="n">CASH IN (TZS)</th><th className="n">CASH OUT (TZS)</th><th className="n">BALANCE (TZS)</th></tr></thead>
            <tbody>{doc.lw.rows.map((r, i) => <tr key={i} className={r.bold ? 'b' : ''}>{lwCells(r).map((c, k) => <td key={k} className={k > 2 ? 'n' : ''}>{c}</td>)}</tr>)}</tbody>
          </table>
          <table className="wc-doc-table" style={sized(doc.req.showApproved ? null : doc.widths?.req)}>
            {cols(doc.req.showApproved ? null : doc.widths?.req, 3)}
            <thead><tr><th colSpan={doc.req.showApproved ? 4 : 3} className="wc-doc-cap">{doc.req.title}</th></tr>
              <tr><th>DESCRIPTION</th><th>QTY</th><th className="n">AMOUNT (TZS)</th>{doc.req.showApproved && <th className="n">APPROVED (TZS)</th>}</tr></thead>
            <tbody>{doc.req.lines.map((l, i) => <tr key={i}>{reqCells(doc, l).map((c, k) => <td key={k} className={k > 1 ? 'n' : ''}>{c}</td>)}</tr>)}</tbody>
            <tfoot><tr className="b"><td>TOTAL</td><td /><td className="n">Tsh {Math.round(doc.req.total).toLocaleString('en-US')}</td>{doc.req.showApproved && <td className="n">Tsh {Math.round(doc.req.approvedTotal).toLocaleString('en-US')}</td>}</tr></tfoot>
          </table>
          {doc.account && <table className="wc-doc-table" style={doc.widths?.req ? { width: `${doc.widths.req.table * 100}%` } : undefined}><thead><tr><th>BANK</th><th>ACCOUNT NUMBER</th><th>ACCOUNT NAME</th></tr></thead>
            <tbody><tr><td>{doc.account.bank}</td><td>{doc.account.number}</td><td>{doc.account.holder}</td></tr></tbody></table>}
          {doc.notes && <p className="wc-doc-notes">Notes: {doc.notes}</p>}
        </div>
      </div>
    </div>
  );
}
