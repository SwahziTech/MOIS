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
      columnStyles: { 0: { cellWidth: 'wrap' }, 3: { halign: 'right' }, 4: { halign: 'right' }, 5: { halign: 'right' } },
    });
    y = pdf.lastAutoTable.finalY + 4;
    const n = reqHead(doc).length;
    autoTable(pdf, { ...base, startY: y,
      head: [titleRow(doc.req.title, n), reqHead(doc)],
      body: doc.req.lines.map(l => reqCells(doc, l)),
      foot: [['TOTAL', '', `Tsh ${amt(doc.req.total)}`, ...(doc.req.showApproved ? [`Tsh ${amt(doc.req.approvedTotal)}`] : [])]],
      footStyles: { fillColor: [235, 235, 235], textColor: 20, fontStyle: 'bold', halign: 'right' },
      columnStyles: { 2: { halign: 'right' }, 3: { halign: 'right' } },
    });
    y = pdf.lastAutoTable.finalY + 3;
    if (doc.account) {
      autoTable(pdf, { ...base, startY: y, head: [['BANK', 'ACCOUNT NUMBER', 'ACCOUNT NAME']], body: [[doc.account.bank || '', doc.account.number || '', doc.account.holder || '']] });
      y = pdf.lastAutoTable.finalY + 3;
    }
    if (doc.notes) { pdf.setFont('times', 'normal'); pdf.setFontSize(fs); pdf.text(`Notes: ${doc.notes}`, m, y + fs * 0.35, { maxWidth: W - 2 * m }); }
    if (pdf.getNumberOfPages() === 1) break;
  }
  return pdf;
}

export async function downloadPdf(doc, setup) { (await buildPdf(doc, setup)).save(`${doc.fileName}.pdf`); }
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
      vals.forEach((v, k) => { const c = ws.getCell(r, start + k); c.value = v; c.border = { top: thin, left: thin, bottom: thin, right: thin }; if (typeof v === 'number') c.numFmt = '#,##0'; c.font = { ...TNR, bold: !!bold };
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
  r += 1;
  const head = reqHead(doc);
  table(doc.req.title, head, [
    ...doc.req.lines.map(l => ({ cells: [l.description ?? '', l.qty ?? '', n(l.amount), ...(doc.req.showApproved ? [n(l.approved ?? l.amount)] : [])] })),
    { bold: true, cells: ['TOTAL', '', n(doc.req.total), ...(doc.req.showApproved ? [n(doc.req.approvedTotal)] : [])] },
  ], head.length, 2);
  r += 1;
  if (doc.account) table('PAY TO', ['BANK', 'ACCOUNT NUMBER', 'ACCOUNT NAME'], [{ cells: [doc.account.bank || '', doc.account.number || '', doc.account.holder || ''] }], 3, 2);
  if (doc.notes) { r += 1; const c = ws.getCell(r, 2); c.value = `Notes: ${doc.notes}`; c.font = TNR; }
  const buf = await wb.xlsx.writeBuffer();
  const url = URL.createObjectURL(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
  const a = document.createElement('a'); a.href = url; a.download = `${doc.fileName}.xlsx`; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}
