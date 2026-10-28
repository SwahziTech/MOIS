/*
 * The weekly cash sheet in Excel (2026-10-28): read the branch's own sheet —
 * its "needs this week" table (DESCRIPTION · QTY · AMOUNT, down to TOTAL) and
 * the week it is for — and write the same layout back out: last week's
 * summary (cash in, cash out, running balance), this week's needs, and the
 * receiving account. ExcelJS is loaded only when used.
 */
const loadExcel = async () => (await import('exceljs')).default;

const text = v => {
  if (v == null) return '';
  if (typeof v === 'object') return v.richText ? v.richText.map(t => t.text).join('') : v.result != null ? String(v.result) : v.text ?? '';
  return String(v);
};
const numberOf = v => {
  if (typeof v === 'number') return v;
  if (v && typeof v === 'object' && typeof v.result === 'number') return v.result;
  const n = Number(text(v).replace(/[^0-9.-]/g, ''));
  return Number.isFinite(n) && text(v).match(/\d/) ? n : null;
};
// "KG 2", "PCS 15", "12", "SQM 176" → { quantity, unit }
export function splitQty(v) {
  if (typeof v === 'number') return { quantity: v, unit: '' };
  const t = text(v).trim();
  if (!t) return { quantity: null, unit: '' };
  const n = t.match(/-?\d+(\.\d+)?/);
  return { quantity: n ? Number(n[0]) : null, unit: t.replace(/-?\d+(\.\d+)?/, '').replace(/\s+/g, ' ').trim().toUpperCase() };
}
const MONTHS = { JAN: 0, FEB: 1, MAR: 2, APR: 3, MAY: 4, JUN: 5, JUL: 6, AUG: 7, SEP: 8, OCT: 9, NOV: 10, DEC: 11 };
// "MAHITAJI YA WIKI HII (17 OCTOBER 2026)" → '2026-10-17'
function dateIn(s) {
  const m = s.match(/(\d{1,2})\s*[ /.-]?\s*([A-Za-z]{3,})\s*[ ,/.-]?\s*(\d{4})/) || null;
  if (m && MONTHS[m[2].slice(0, 3).toUpperCase()] != null) return new Date(Date.UTC(Number(m[3]), MONTHS[m[2].slice(0, 3).toUpperCase()], Number(m[1]))).toISOString().slice(0, 10);
  const d = s.match(/(\d{1,2})[/.-](\d{1,2})[/.-](\d{2,4})/);
  if (d) { const y = Number(d[3]) < 100 ? 2000 + Number(d[3]) : Number(d[3]); return new Date(Date.UTC(y, Number(d[2]) - 1, Number(d[1]))).toISOString().slice(0, 10); }
  return null;
}

/** Read the "needs this week" table from a workbook file → { weekEnding, lines: [{ description, quantity, unit, amount }], total } */
export async function readWeeklySheet(file) {
  const ExcelJS = await loadExcel();
  const wb = new ExcelJS.Workbook();
  await wb.xlsx.load(await file.arrayBuffer());
  for (const ws of wb.worksheets) {
    const rows = [];
    ws.eachRow({ includeEmpty: false }, (row, i) => rows.push({ i, cells: row.values.slice(1).map(text), raw: row.values.slice(1) }));
    // the header of the needs table: DESCRIPTION and AMOUNT, without CASH IN/OUT (that is last week's summary)
    const hi = rows.findIndex(r => r.cells.some(c => /^\s*description\s*$/i.test(c)) && r.cells.some(c => /^\s*amount\s*$/i.test(c)) && !r.cells.some(c => /cash\s*(in|out)/i.test(c)));
    if (hi < 0) continue;
    const head = rows[hi].cells;
    const col = re => head.findIndex(c => re.test(c));
    const cD = col(/^\s*description\s*$/i), cQ = col(/^\s*qty|quantity\s*$/i), cA = col(/^\s*amount\s*$/i);
    // the week: a date written in a row just above the table
    let weekEnding = null;
    for (let k = hi - 1; k >= Math.max(0, hi - 3) && !weekEnding; k--) weekEnding = dateIn(rows[k].cells.join(' '));
    const lines = [];
    let total = null;
    for (let k = hi + 1; k < rows.length; k++) {
      const desc = (rows[k].cells[cD] ?? '').trim();
      if (!desc) continue;
      if (/^total/i.test(desc)) { total = numberOf(rows[k].raw[cA]); break; }
      const amount = numberOf(rows[k].raw[cA]);
      if (amount == null) continue;
      lines.push({ description: desc, ...(cQ >= 0 ? splitQty(rows[k].raw[cQ]) : { quantity: null, unit: '' }), amount });
    }
    if (lines.length) return { weekEnding, lines, total };
  }
  throw new Error('No table with DESCRIPTION, QTY and AMOUNT was found in this file.');
}

/** Write the sheet: last week's summary, this week's needs, the receiving account → downloads the file */
export async function writeWeeklySheet({ fileName, summaryTitle, summary, needsTitle, needs, account }) {
  const ExcelJS = await loadExcel();
  const wb = new ExcelJS.Workbook();
  const ws = wb.addWorksheet('Weekly cash');
  ws.columns = [{ width: 13 }, { width: 34 }, { width: 12 }, { width: 15 }, { width: 15 }, { width: 15 }];
  const thin = { style: 'thin' };
  const box = cell => { cell.border = { top: thin, left: thin, bottom: thin, right: thin }; };
  const money = '#,##0';
  let r = 1;
  const title = (t, span) => { ws.mergeCells(r, 1, r, span); const c = ws.getCell(r, 1); c.value = t; c.font = { bold: true }; c.alignment = { horizontal: 'center' }; r += 1; };
  const row = (vals, opts = {}) => {
    vals.forEach((v, k) => { const c = ws.getCell(r, k + 1); c.value = v; box(c); if (typeof v === 'number') c.numFmt = money; if (opts.bold) c.font = { bold: true }; if (k === 1) c.alignment = { horizontal: 'center' }; });
    r += 1;
  };
  if (summary) {
    title(summaryTitle, 6);
    row(['DATE', 'DESCRIPTION', 'QTY', 'CASH IN', 'CASH OUT', 'BALANCE'], { bold: true });
    row([summary.date, 'BALANCE', '', summary.opening, '', '']);
    row(['', 'CASH SENT', '', summary.sent, '', '']);
    row(['', 'TOTAL CASH', '', summary.opening + summary.sent, '', ''], { bold: true });
    for (const s of summary.lines) row([s.date, s.description, s.qty ?? '', '', s.amount, s.balance]);
    row(['', 'TOTAL CASH', '', '', summary.spent, ''], { bold: true });
    row(['', 'BALANCE', '', summary.closing, '', ''], { bold: true });
    r += 1;
  }
  title(needsTitle, 4);
  row(['', 'DESCRIPTION', 'QTY', 'AMOUNT'], { bold: true });
  for (const n of needs) row(['', n.description, n.qty ?? '', n.amount]);
  row(['', 'TOTAL', '', needs.reduce((t, n) => t + Number(n.amount || 0), 0)], { bold: true });
  if (account) { r += 1; row(['', account.bank ?? '', account.number ?? '', '']); row(['', 'JINA', account.holder ?? '', '']); }
  const buf = await wb.xlsx.writeBuffer();
  const url = URL.createObjectURL(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }));
  const a = document.createElement('a'); a.href = url; a.download = fileName; document.body.appendChild(a); a.click(); a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 2000);
}
