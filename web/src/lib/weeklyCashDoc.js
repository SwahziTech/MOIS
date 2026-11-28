import { saveFile, isApp } from './native';

/*
 * The weekly cash report as a document (2026-11-15, the user): one page, on the paper that fits it,
 * as PDF (what directors open, mostly on their phones) or Excel (for whoever edits it).
 *
 * doc = {
 *   company, branch, title, status,
 *   lw:  { title, rows: [{ date, description, qty, cash_in, cash_out, balance, bold }] },
 *   req: { title, showApproved, lines: [{ description, qty, amount, approved }], total, approvedTotal },
 *   account: { bank, number, holder } | null, notes, fileName
 * }
 * Libraries load only when used.
 */
export const PAPERS = { A5: [148, 210], A4: [210, 297], A3: [297, 420], Letter: [216, 279], Legal: [216, 356] };
const EXCEL_PAPER = { A5: 11, A4: 9, A3: 8, Letter: 1, Legal: 5 };

const amt = v => (v == null || v === '' || Number.isNaN(Number(v)) ? '' : Math.round(Number(v)).toLocaleString('en-US'));

/** The weekly report's paper: A3, portrait (2026-11-15, the user) */
export function pickPaper() {
  return { paper: 'A3', orientation: 'portrait' };
}

const lwHead = ['DATE', 'DESCRIPTION', 'QTY', 'CASH IN (TZS)', 'CASH OUT (TZS)', 'BALANCE (TZS)'];
const reqHead = d => ['DESCRIPTION', 'QTY', 'AMOUNT (TZS)', ...(d.req.showApproved ? ['APPROVED (TZS)'] : [])];
export const lwCells = r => [r.date ?? '', r.description ?? '', r.qty ?? '', amt(r.cash_in), amt(r.cash_out), amt(r.balance)];
export const reqCells = (d, l) => [l.description ?? '', l.qty ?? '', amt(l.amount), ...(d.req.showApproved ? [amt(l.approved ?? l.amount)] : [])];

/**
 * The columns as the user sized them on screen (2026-11-28, the user: "the preview and printing, pdf should be as
 * edited — it leaves a lot of empty space from description to amount"). Each sheet keeps the same proportions; the
 * wider sheet fills the page and the other is as much narrower as it is on screen. Unit goes with Qty on paper;
 * Category is not printed. → { lw: { table, cols }, req: { table, cols } } as fractions, or null.
 */
const shownOf = label => { try { return JSON.parse(localStorage.getItem(`xs-shown:${label}`) || 'null'); } catch { return null; } };
export function sheetWidths() {
  const lw = shownOf("Last week's spending"), rq = shownOf("This week's request");
  const lwPx = lw && ['date', 'description', 'qty', 'cash_in', 'cash_out', 'balance'].map(k => lw[k] || 0);
  const rqPx = rq && [rq.description || 0, (rq.quantity || 0) + (rq.unit || 0), rq.amount || 0];
  const ok = a => a && a.every(x => x > 0);
  const sum = a => a.reduce((t, x) => t + x, 0);
  const ref = Math.max(ok(lwPx) ? sum(lwPx) : 0, ok(rqPx) ? sum(rqPx) : 0);
  if (!ref) return null;
  const part = a => (ok(a) ? { table: sum(a) / ref, cols: a.map(x => x / sum(a)) } : null);
  return { lw: part(lwPx), req: part(rqPx) };
}
// each column at least as wide as its longest header word (+ padding) — "BALANCE (TZS)" never runs into the next
// column, even on A4 (2026-11-28, the user); the room comes from the columns that have some to spare
const widthStyles = (w, n, full, extra = {}, pdf = null, head = [], fsz = 12) => {
  const pad = fsz * 0.16;   // the cell padding (base.styles)
  if (!w || w.cols.length !== n) return { columnStyles: extra };
  const tw = full * w.table;
  let ws = w.cols.map(f => tw * f);
  if (pdf) {
    pdf.setFont('times', 'bold'); pdf.setFontSize(fsz);
    const min = head.map(h => Math.max(...String(h).split(/s+/).map(x => pdf.getTextWidth(x))) + 2 * pad + 0.5);
    const short = ws.reduce((t, x, k) => t + Math.max(0, min[k] - x), 0);
    const spare = ws.reduce((t, x, k) => t + Math.max(0, x - min[k]), 0);
    if (short > 0 && spare >= short) ws = ws.map((x, k) => (x < min[k] ? min[k] : x - (x - min[k]) * short / spare));
    pdf.setFont('times', 'normal');
  }
  const cs = {};
  ws.forEach((x, k) => { cs[k] = { ...(extra[k] || {}), cellWidth: x }; });
  return { tableWidth: tw, columnStyles: cs };
};

/** Build the PDF on one page: the type gets smaller until it all fits */
export async function buildPdf(doc, { paper = 'A4', orientation = 'portrait' } = {}) {
  const { jsPDF } = await import('jspdf');
  const autoTable = (await import('jspdf-autotable')).default;
  const [pw, ph] = PAPERS[paper] ?? PAPERS.A4;
  let pdf;
  // printed documents: Times New Roman, 12 pt; smaller only if it would not fit one page
  for (let fs = 12; fs >= 4; fs -= 0.5) {
    pdf = new jsPDF({ unit: 'mm', format: [pw, ph], orientation });
    const W = pdf.internal.pageSize.getWidth();
    const m = 10;
    let y = m + 2;
    pdf.setFont('times', 'bold'); pdf.setFontSize(fs + 4);
    if (doc.company) { pdf.text(doc.company, W / 2, y, { align: 'center' }); y += (fs + 4) * 0.45; }
    pdf.setFont('times', 'normal'); pdf.setFontSize(fs);
    if (doc.branch) { pdf.text(doc.branch, W / 2, y, { align: 'center' }); y += fs * 0.5; }
    pdf.setFont('times', 'bold'); pdf.setFontSize(fs + 2);
    pdf.text(doc.title, W / 2, y + 1, { align: 'center' });
    if (doc.status) { pdf.setFont('times', 'normal'); pdf.setFontSize(fs - 1); pdf.text(doc.status, W - m, y + 1, { align: 'right' }); }
    y += fs * 0.7;
    const base = {
      theme: 'grid', margin: { left: m, right: m }, tableLineWidth: 0.6, tableLineColor: 0,
      styles: { font: 'times', fontSize: fs, cellPadding: fs * 0.16, lineColor: 120, lineWidth: 0.1, textColor: 20, overflow: 'linebreak' },
      headStyles: { fillColor: [235, 235, 235], textColor: 20, fontStyle: 'bold', lineColor: 120, lineWidth: 0.1 },
    };
    const titleRow = (t, n) => [{ content: t, colSpan: n, styles: { halign: 'center', fontStyle: 'bold', fontSize: fs + 1, fillColor: [255, 255, 255] } }];
    autoTable(pdf, { ...base, startY: y,
      head: [titleRow(doc.lw.title, 6), lwHead],
      body: doc.lw.rows.map(r => lwCells(r).map(c => ({ content: c, styles: r.bold ? { fontStyle: 'bold' } : {} }))),
      ...(doc.widths?.lw ? widthStyles(doc.widths.lw, 6, W - 2 * m, { 3: { halign: 'center' }, 4: { halign: 'center' }, 5: { halign: 'center' } }, pdf, lwHead, fs)
        : { columnStyles: { 0: { cellWidth: 'wrap' }, 3: { halign: 'center' }, 4: { halign: 'center' }, 5: { halign: 'center' } } }),
    });
    y = pdf.lastAutoTable.finalY + 12;   // a clear gap between the two sheets (2026-11-15, the user)
    const n = reqHead(doc).length;
    autoTable(pdf, { ...base, startY: y,
      head: [titleRow(doc.req.title, n), reqHead(doc)],
      body: doc.req.lines.map(l => reqCells(doc, l)),
      foot: [['TOTAL', '', `Tsh ${amt(doc.req.total)}`, ...(doc.req.showApproved ? [`Tsh ${amt(doc.req.approvedTotal)}`] : [])]],
      footStyles: { fillColor: [235, 235, 235], textColor: 20, fontStyle: 'bold', halign: 'center' },
      ...widthStyles(doc.widths?.req, n, W - 2 * m, { 2: { halign: 'center' }, 3: { halign: 'center' } }, pdf, reqHead(doc), fs),
    });
    y = pdf.lastAutoTable.finalY + 3;
    if (doc.account) {
      autoTable(pdf, { ...base, startY: y, head: [['BANK', 'ACCOUNT NUMBER', 'ACCOUNT NAME']], body: [[doc.account.bank || '', doc.account.number || '', doc.account.holder || '']],
        ...(doc.widths?.req ? { tableWidth: (W - 2 * m) * doc.widths.req.table } : {}) });   // as wide as the request above it
      y = pdf.lastAutoTable.finalY + 3;
    }
    if (doc.notes) { pdf.setFont('times', 'normal'); pdf.setFontSize(fs); pdf.text(`Notes: ${doc.notes}`, m, y + fs * 0.35, { maxWidth: W - 2 * m }); }
    if (pdf.getNumberOfPages() === 1) break;
  }
  return pdf;
}

/** CSV: the two sheets and the account, one after another (opens in any spreadsheet) */
export function downloadCsv(doc) {
  const q = v => { const t = String(v ?? ''); return /[",\n]/.test(t) ? `"${t.replace(/"/g, '""')}"` : t; };
  const plain = v => (v == null || v === '' ? '' : Number(v));
  const out = [[doc.company], [doc.branch], [doc.title], [], [doc.lw.title], lwHead,
    ...doc.lw.rows.map(x => [x.date ?? '', x.description ?? '', x.qty ?? '', plain(x.cash_in), plain(x.cash_out), plain(x.balance)]), [], [], [doc.req.title], reqHead(doc),
    ...doc.req.lines.map(l => [l.description ?? '', l.qty ?? '', plain(l.amount), ...(doc.req.showApproved ? [plain(l.approved ?? l.amount)] : [])]),
    ['TOTAL', '', plain(doc.req.total), ...(doc.req.showApproved ? [plain(doc.req.approvedTotal)] : [])], [],
    ['BANK', 'ACCOUNT NUMBER', 'ACCOUNT NAME'], [doc.account?.bank ?? '', doc.account?.number ?? '', doc.account?.holder ?? ''], ...(doc.notes ? [[], [`Notes: ${doc.notes}`]] : [])];
  const url = URL.createObjectURL(new Blob(['﻿' + out.map(r => r.map(q).join(',')).join('\r\n')], { type: 'text/csv;charset=utf-8' }));
  if (isApp()) { URL.revokeObjectURL(url); return saveFile(new Blob(['﻿' + out.map(r => r.map(q).join(',')).join('\r\n')], { type: 'text/csv;charset=utf-8' }), `${doc.fileName}.csv`); }
  const a = document.createElement('a'); a.href = url; a.download = `${doc.fileName}.csv`; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}

export async function downloadPdf(doc, setup) { (await buildPdf(doc, setup)).save(`${doc.fileName}.pdf`); }

/** On a phone: the PDF goes straight to the phone's "Open with / Share" list (a PDF reader, WhatsApp,
 *  Drive…) — opened, not downloaded again (2026-11-16, the user). Elsewhere, or where the phone can't
 *  share files: an ordinary download. → 'shared' | 'cancelled' | 'downloaded' */
export const isPhone = () => typeof navigator !== 'undefined' && /Android|iPhone|iPad|Mobile/i.test(navigator.userAgent);
export async function openPdf(doc, setup) {
  const pdf = await buildPdf(doc, setup);
  const name = `${doc.fileName}.pdf`;
  if (isApp()) return saveFile(pdf.output('blob'), name, doc.title);   // the phone app: its share sheet
  if (isPhone() && typeof File !== 'undefined' && navigator.canShare) {
    const file = new File([pdf.output('blob')], name, { type: 'application/pdf' });
    if (navigator.canShare({ files: [file] })) {
      try { await navigator.share({ files: [file], title: doc.title }); return 'shared'; }
      catch (e) { if (e?.name === 'AbortError') return 'cancelled'; }   // closed the list: nothing to do
    }
  }
  pdf.save(name);
  return 'downloaded';
}
/**
 * Phones (2026-11-21, the user: the PDF button did nothing on a director's phone): a phone only shares or
 * opens a file straight after a tap, so the viewer builds the file when it opens and hands it over at once.
 */
export async function pdfFile(doc, setup) {
  const pdf = await buildPdf(doc, setup);
  return new File([pdf.output('blob')], `${doc.fileName}.pdf`, { type: 'application/pdf' });
}
/** Share a ready file (phone list of apps), else open it in the browser's PDF viewer — call straight from the tap */
export function shareOrOpenPdf(file) {
  if (isApp()) return saveFile(file, file.name).catch(() => 'cancelled');
  if (isPhone() && navigator.canShare?.({ files: [file] })) {
    return navigator.share({ files: [file], title: file.name }).then(() => 'shared').catch(e => {
      if (e?.name === 'AbortError') return 'cancelled';
      openFile(file); return 'opened';
    });
  }
  openFile(file);
  return Promise.resolve('opened');
}
function openFile(file) {
  const url = URL.createObjectURL(file);
  const a = document.createElement('a');
  a.href = url; a.target = '_blank'; a.rel = 'noopener'; a.download = file.name;
  document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}
export async function printPdf(doc, setup) {
  const pdf = await buildPdf(doc, setup);
  pdf.autoPrint();
  window.open(pdf.output('bloburl'), '_blank');
}

/** Excel, in the sheet's layout, set to print on one page of the chosen paper */
export async function downloadExcel(doc, { paper = 'A4', orientation = 'portrait' } = {}) {
  const ExcelJS = (await import('exceljs')).default;
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Weekly cash', { pageSetup: { paperSize: EXCEL_PAPER[paper] ?? 9, orientation, fitToPage: true, fitToWidth: 1, fitToHeight: 1,
    margins: { left: 0.4, right: 0.4, top: 0.5, bottom: 0.5, header: 0.2, footer: 0.2 } } });
  ws.columns = [{ width: 13 }, { width: 34 }, { width: 12 }, { width: 15 }, { width: 15 }, { width: 15 }];
  const thin = { style: 'thin' }, thick = { style: 'medium' };
  let r = 1;
  const TNR = { name: 'Times New Roman', size: 12 };
  const merged = (t, span, font = { bold: true }) => { font = { ...TNR, ...font }; ws.mergeCells(r, 1, r, span); const c = ws.getCell(r, 1); c.value = t; c.font = font; c.alignment = { horizontal: 'center' }; r += 1; };
  // a table with a bold outer frame
  const table = (title, head, rows, span, start = 1) => {
    const top = r;
    ws.mergeCells(r, start, r, start + span - 1); const tc = ws.getCell(r, start); tc.value = title; tc.font = { ...TNR, bold: true }; tc.alignment = { horizontal: 'center' }; r += 1;
    const put = (vals, bold, fill) => {
      vals.forEach((v, k) => { const c = ws.getCell(r, start + k); c.value = v; c.border = { top: thin, left: thin, bottom: thin, right: thin }; if (typeof v === 'number') { c.numFmt = '#,##0'; c.alignment = { horizontal: 'center' }; } c.font = { ...TNR, bold: !!bold };
        if (fill) c.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFEBEBEB' } }; });
      r += 1;
    };
    put(head, true, true);
    for (const x of rows) put(x.cells, x.bold);
    for (let rr = top; rr < r; rr++) for (let k = 0; k < span; k++) {
      const c = ws.getCell(rr, start + k);
      c.border = { top: rr === top ? thick : thin, bottom: rr === r - 1 ? thick : thin, left: k === 0 ? thick : thin, right: k === span - 1 ? thick : thin };
    }
  };
  const n = v => (v == null || v === '' ? '' : Number(v));
  if (doc.company) merged(doc.company, 6);
  if (doc.branch) merged(doc.branch, 6, {});
  merged(doc.title, 6);
  r += 1;
  table(doc.lw.title, lwHead, doc.lw.rows.map(x => ({ bold: x.bold, cells: [x.date ?? '', x.description ?? '', x.qty ?? '', n(x.cash_in), n(x.cash_out), n(x.balance)] })), 6);
  r += 2;
  const head = reqHead(doc);
  table(doc.req.title, head, [
    ...doc.req.lines.map(l => ({ cells: [l.description ?? '', l.qty ?? '', n(l.amount), ...(doc.req.showApproved ? [n(l.approved ?? l.amount)] : [])] })),
    { bold: true, cells: ['TOTAL', '', n(doc.req.total), ...(doc.req.showApproved ? [n(doc.req.approvedTotal)] : [])] },
  ], head.length, 2);
  r += 1;
  if (doc.account) table('PAY TO', ['BANK', 'ACCOUNT NUMBER', 'ACCOUNT NAME'], [{ cells: [doc.account.bank || '', doc.account.number || '', doc.account.holder || ''] }], 3, 2);
  if (doc.notes) { r += 1; const c = ws.getCell(r, 2); c.value = `Notes: ${doc.notes}`; c.font = TNR; }
  const buf = await wb.xlsx.writeBuffer();
  await saveFile(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), `${doc.fileName}.xlsx`);   // the share sheet in the phone app (lib/native)
}
