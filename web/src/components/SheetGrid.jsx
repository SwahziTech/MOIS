import { useRef, useState } from 'react';
import { X } from 'lucide-react';
import NumberInput from './NumberInput';

/*
 * A sheet that works like Excel (2026-11-13, the user: "very more like Excel itself"):
 *   - gridlines, column letters on top, row numbers on the left, a green frame on the cell in use;
 *   - Enter goes down, Shift+Enter up, Tab right, the arrows move between cells, Esc leaves;
 *     a cell's text is selected when you land on it, so typing replaces it;
 *   - paste rows copied from Excel (Ctrl+C there, Ctrl+V here): they fill from the cell you are in,
 *     adding rows as needed;
 *   - an empty row always waits at the bottom; the totals stay at the foot;
 *   - hold a row's number and drag the row up or down to move it (2026-11-21).
 *
 * columns: [{ key, label, type: 'text'|'number'|'select', options?: [{ value, label }], width?, align?,
 *             min?, editable?: boolean (default: !readOnly), ignoreLock?: boolean, show?: row => node (read-only display) }]
 * rows:    the rows (objects); onChange(rows) gets the whole new list
 * isLocked(row): a row that can't be changed (shown grey); blankRow: what a new row starts as
 * totals:  { [column key]: node } shown on the foot; totalLabel
 * title:   a heading across the top of the sheet (centred); className: e.g. xs-bold for a bold outer frame
 * canEditCell(col, row) / canRemoveRow(row): per-cell locks (formula cells); rowClass(row): extra row class
 * footRows: fixed rows under the blank row (formula totals), shown read-only
 * column.wrap: the read-only text wraps onto more lines instead of being cut
 *
 * resizable / freeze: the weekly cash framework's extras (2026-11-15, the user: locked to weekly cash;
 *   other sheets get their own framework later) — off unless asked for.
 *
 * Sizes, as in Excel (resizable; 2026-11-15, the user): drag a column letter's right edge to widen or narrow it,
 * double-click that edge to fit the words; drag a row number's bottom edge for a taller row,
 * double-click it to go back. Double-click the top-left corner to reset every size. Column widths
 * are kept on this device for this sheet; row heights last while the page is open.
 */
const LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
// column.align: 'right' (numbers) or 'center' (the weekly cash amounts, 2026-11-15)
const alignCls = col => (col.align === 'right' ? ' xs-num' : col.align === 'center' ? ' xs-center' : '');
const cleanNumber = v => String(v ?? '').replace(/[^\d.-]/g, '');

export default function SheetGrid({ columns, rows, onChange, readOnly = false, isLocked = () => false, lockedTitle, blankRow = {}, totals = null, totalLabel = 'Total', label = 'Sheet', title = null, className = '', canEditCell = null, canRemoveRow = null, rowClass = null, footRows = [], resizable = false, freeze = false }) {
  const box = useRef(null);
  const sizeKey = `xs-size:${label}`;
  const [colW, setColW] = useState(() => { if (!resizable) return {}; try { return JSON.parse(localStorage.getItem(sizeKey) || '{}') || {}; } catch { return {}; } });
  const [rowH, setRowH] = useState({});
  const keepCols = w => { try { localStorage.setItem(sizeKey, JSON.stringify(w)); } catch { /* sizes are a convenience */ } };
  const widthOf = c => colW[c.key] ?? c.width;
  // drag an edge: the column's width or the row's height follows the pointer
  function drag(e, start, apply, done) {
    e.preventDefault(); e.stopPropagation();
    const el = e.currentTarget; try { el.setPointerCapture?.(e.pointerId); } catch { /* not every pointer can be captured */ }
    const x0 = e.clientX, y0 = e.clientY;
    let last = null;
    const move = ev => { last = apply(start, ev.clientX - x0, ev.clientY - y0); };
    const up = () => { el.removeEventListener('pointermove', move); el.removeEventListener('pointerup', up); el.removeEventListener('pointercancel', up); done?.(last); };
    el.addEventListener('pointermove', move); el.addEventListener('pointerup', up); el.addEventListener('pointercancel', up);
  }
  const startCol = (e, c) => {
    const start = e.currentTarget.parentElement.getBoundingClientRect().width;
    drag(e, start, (w0, dx) => { const w = Math.max(40, Math.round(w0 + dx)); let next; setColW(p => (next = { ...p, [c.key]: w })); return next; }, next => next && keepCols(next));
  };
  const startRow = (e, key) => {
    const start = e.currentTarget.closest('tr').getBoundingClientRect().height;
    drag(e, start, (h0, dx, dy) => { setRowH(p => ({ ...p, [key]: Math.max(24, Math.round(h0 + dy)) })); return null; });
  };
  // double-click a column edge: as wide as its longest words
  function fitCol(c) {
    const cells = [...(box.current?.querySelectorAll(`[data-col="${c.key}"]`) || [])];
    const ctx = document.createElement('canvas').getContext('2d');
    let w = 40;
    for (const td of cells) {
      const el = td.querySelector('input, select, .xs-ro') || td;
      ctx.font = getComputedStyle(el).font;
      const t = el.tagName === 'INPUT' ? el.value : el.tagName === 'SELECT' ? el.options[el.selectedIndex]?.text ?? '' : el.innerText;
      for (const line of String(t).split('\n')) w = Math.max(w, ctx.measureText(line).width);
    }
    const next = { ...colW, [c.key]: Math.ceil(w + 28) };
    setColW(next); keepCols(next);
  }
  const resetSizes = () => { setColW({}); setRowH({}); keepCols({}); };
  const allSized = columns.every(c => widthOf(c));
  const tableWidth = allSized ? 38 + columns.reduce((t, c) => t + widthOf(c), 0) + (readOnly ? 0 : 30) : undefined;
  const canEdit = (col, row) => (col.editable ?? !readOnly) && (col.ignoreLock || !isLocked(row)) && (!canEditCell || canEditCell(col, row));
  const editableCols = columns.map((c, i) => ({ c, i })).filter(x => x.c.editable ?? !readOnly);
  // an empty row always waits at the bottom while the sheet can be typed in
  const shown = readOnly ? rows : [...rows, { ...blankRow, __blank: true }];

  const setCell = (r, key, value) => {
    const next = rows.map(x => ({ ...x }));
    if (r >= rows.length) next.push({ ...blankRow, [key]: value });
    else next[r][key] = value;
    onChange(next);
  };
  const removeRow = r => onChange(rows.filter((_, j) => j !== r));
  // hold a row's number and drag the whole row up or down (2026-11-21, the user); a locked row and the empty row stay put
  const [rowDrag, setRowDrag] = useState(null);   // { from, over }
  const canDragRow = r => !readOnly && r < rows.length && !isLocked(rows[r]);
  function startRowDrag(e, r) {
    if (!canDragRow(r) || e.button !== 0) return;
    e.preventDefault();
    const el = e.currentTarget; try { el.setPointerCapture?.(e.pointerId); } catch { /* not every pointer can be captured */ }
    let over = r;
    setRowDrag({ from: r, over: r });
    const at = ev => {
      const tr = document.elementFromPoint(ev.clientX, ev.clientY)?.closest('tr[data-r]');
      if (!tr || !box.current?.contains(tr)) return;
      over = Math.min(Math.max(Number(tr.dataset.r), 0), rows.length - 1);
      setRowDrag({ from: r, over });
    };
    const up = () => {
      window.removeEventListener('pointermove', at); window.removeEventListener('pointerup', up); window.removeEventListener('pointercancel', up);
      setRowDrag(null);
      if (over === r) return;
      const next = [...rows];
      const [moved] = next.splice(r, 1);
      next.splice(over, 0, moved);
      onChange(next);
    };
    // followed on the whole page, so a quick drag past the row numbers still lands
    window.addEventListener('pointermove', at); window.addEventListener('pointerup', up); window.addEventListener('pointercancel', up);
  }

  function focusCell(r, c) {
    const el = box.current?.querySelector(`[data-cell="${r}:${c}"]`);
    if (!el) return false;
    el.focus();
    if (el.select && el.tagName === 'INPUT') setTimeout(() => el.select(), 0);
    return true;
  }
  function move(r, c, dr, dc) {
    if (dr) { for (let rr = r + dr; rr >= 0 && rr < shown.length; rr += dr) if (focusCell(rr, c)) return; return; }
    const order = editableCols.map(x => x.i);
    let k = order.indexOf(c) + dc;
    while (k >= 0 && k < order.length) { if (focusCell(r, order[k])) return; k += dc; }
  }
  function onKey(e, r, c) {
    const el = e.target;
    const isSelect = el.tagName === 'SELECT';
    if (e.key === 'Enter') { e.preventDefault(); move(r, c, e.shiftKey ? -1 : 1, 0); }
    else if (e.key === 'Escape') { el.blur(); }
    else if (!isSelect && e.key === 'ArrowDown') { e.preventDefault(); move(r, c, 1, 0); }
    else if (!isSelect && e.key === 'ArrowUp') { e.preventDefault(); move(r, c, -1, 0); }
    else if (e.key === 'ArrowLeft' && (isSelect || (el.selectionStart === 0 && el.selectionEnd === 0))) { e.preventDefault(); move(r, c, 0, -1); }
    else if (e.key === 'ArrowRight' && (isSelect || (el.selectionStart === el.value.length && el.selectionEnd === el.value.length))) { e.preventDefault(); move(r, c, 0, 1); }
  }
  // rows copied from Excel: tabs between cells, new lines between rows
  function onPaste(e, r, c) {
    const text = e.clipboardData?.getData('text/plain') ?? '';
    if (!/[\t\n]/.test(text.replace(/\r?\n$/, ''))) return;   // one value: an ordinary paste
    e.preventDefault();
    const grid = text.replace(/\r/g, '').replace(/\n$/, '').split('\n').map(l => l.split('\t'));
    const order = editableCols.map(x => x.i).filter(i => i >= c);
    const next = rows.map(x => ({ ...x }));
    let target = r;
    for (const cells of grid) {
      while (target < next.length && isLocked(next[target])) target += 1;   // a locked row is skipped
      if (target >= next.length) next.push({ ...blankRow });
      cells.forEach((v, k) => {
        const col = columns[order[k]];
        if (!col) return;
        const val = v.trim();
        if (canEditCell && !canEditCell(col, next[target])) return;   // a formula cell stays as it is
        next[target][col.key] = col.type === 'number' ? cleanNumber(val)
          : col.type === 'select' ? (col.options || []).find(o => o.label.toLowerCase() === val.toLowerCase() || o.value === val)?.value ?? ''
          : val;
      });
      target += 1;
    }
    onChange(next);
  }

  const cell = (row, r, col, c) => {
    if (!canEdit(col, row)) {
      return <div className={`xs-ro${alignCls(col)}${col.wrap ? ' xs-wrap' : ''}`}>{col.show ? col.show(row) : String(row[col.key] ?? '')}</div>;
    }
    const common = { 'data-cell': `${r}:${c}`, 'aria-label': `${col.label}, row ${r + 1}`, onKeyDown: e => onKey(e, r, c), onPaste: e => onPaste(e, r, c),
      onFocus: e => { if (e.target.select && e.target.tagName === 'INPUT') e.target.select(); } };
    if (col.type === 'number') return <NumberInput {...common} className={`xs-in${col.align === 'center' ? ' xs-center' : ' xs-num'}`} step="any" min={col.min} value={row[col.key] ?? ''} onChange={e => setCell(r, col.key, e.target.value)} />;
    if (col.type === 'select') return (
      <select {...common} className="xs-in" value={row[col.key] ?? ''} onChange={e => setCell(r, col.key, e.target.value)}>
        <option value="">—</option>
        {(col.options || []).map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
    );
    return <input {...common} className="xs-in" value={row[col.key] ?? ''} onChange={e => setCell(r, col.key, e.target.value)} />;
  };

  return (
    <div className={`xs-grid${freeze ? ' xs-freeze' : ''}${className ? ` ${className}` : ''}`} ref={box} role="grid" aria-label={label}>
      <table style={tableWidth ? { width: tableWidth, minWidth: tableWidth } : undefined}>
        <colgroup><col style={{ width: 38 }} />{columns.map(c => <col key={c.key} style={widthOf(c) ? { width: widthOf(c) } : undefined} />)}{!readOnly && <col style={{ width: 30 }} />}</colgroup>
        <thead>
          {title && <tr className="xs-title"><th colSpan={columns.length + (readOnly ? 1 : 2)}>{title}</th></tr>}
          <tr className="xs-letters"><th className={resizable ? 'xs-corner' : undefined} title={resizable ? 'Double-click to reset the column widths and row heights' : undefined} onDoubleClick={resizable ? resetSizes : undefined} />{columns.map((c, i) => (
            <th key={c.key}>{LETTERS[i]}{resizable && <span className="xs-col-rs" role="separator" aria-orientation="vertical" aria-label={`Resize column ${LETTERS[i]}`}
              title="Drag to resize · double-click to fit" onPointerDown={e => startCol(e, c)} onDoubleClick={() => fitCol(c)} />}</th>))}{!readOnly && <th />}</tr>
          <tr className="xs-labels"><th />{columns.map(c => <th key={c.key} className={alignCls(c).trim()}>{c.label}</th>)}{!readOnly && <th />}</tr>
        </thead>
        <tbody>
          {shown.map((row, r) => (
            <tr key={r} data-r={r} style={rowH[r] ? { height: rowH[r] } : undefined} className={`${isLocked(row) ? 'xs-locked' : ''}${row.__blank ? ' xs-blank' : ''}${rowClass ? ` ${rowClass(row) || ''}` : ''}${rowDrag?.from === r ? ' xs-dragging' : ''}${rowDrag && rowDrag.over === r && rowDrag.from !== r ? (rowDrag.over < rowDrag.from ? ' xs-drop-above' : ' xs-drop-below') : ''}`} title={isLocked(row) ? lockedTitle : undefined}>
              <td className={`xs-rn${canDragRow(r) ? ' xs-rn-drag' : ''}`} title={canDragRow(r) ? 'Hold and drag to move the row' : undefined} onPointerDown={e => startRowDrag(e, r)}>{r + 1}{resizable && <span className="xs-row-rs" role="separator" aria-label={`Resize row ${r + 1}`} title="Drag to resize · double-click to reset"
                onPointerDown={e => startRow(e, r)} onDoubleClick={() => setRowH(p => { const n = { ...p }; delete n[r]; return n; })} />}</td>
              {columns.map((col, c) => <td key={col.key} data-col={col.key}>{cell(row, r, col, c)}</td>)}
              {!readOnly && <td className="xs-del">{!row.__blank && !isLocked(row) && (!canRemoveRow || canRemoveRow(row)) && (
                <button type="button" tabIndex={-1} className="xs-del-btn" aria-label={`Remove row ${r + 1}`} title="Remove the row" onClick={() => removeRow(r)}><X size={12} /></button>)}</td>}
            </tr>
          ))}
        </tbody>
        {footRows.length > 0 && <tbody className="xs-foot">
          {footRows.map((row, k) => (
            <tr key={`f${k}`} style={rowH[`f${k}`] ? { height: rowH[`f${k}`] } : undefined} className={rowClass ? rowClass(row) || '' : ''}>
              <td className="xs-rn">{shown.length + k + 1}{resizable && <span className="xs-row-rs" role="separator" aria-label="Resize row" title="Drag to resize · double-click to reset"
                onPointerDown={e => startRow(e, `f${k}`)} onDoubleClick={() => setRowH(p => { const n = { ...p }; delete n[`f${k}`]; return n; })} />}</td>
              {columns.map(col => <td key={col.key} data-col={col.key}><div className={`xs-ro${alignCls(col)}`}>{col.show ? col.show(row) : String(row[col.key] ?? '')}</div></td>)}
              {!readOnly && <td />}
            </tr>
          ))}
        </tbody>}
        {totals && Object.keys(totals).length > 0 && <tfoot>
          <tr><td className="xs-rn" />{columns.map((c, i) => <td key={c.key} className={alignCls(c).trim()}>{i === 0 ? <strong>{totalLabel}</strong> : totals[c.key] != null ? <strong>{totals[c.key]}</strong> : null}</td>)}{!readOnly && <td />}</tr>
        </tfoot>}
      </table>
    </div>
  );
}
