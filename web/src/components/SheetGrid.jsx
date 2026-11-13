import { useRef } from 'react';
import { X } from 'lucide-react';
import NumberInput from './NumberInput';

/*
 * A sheet that works like Excel (2026-11-13, the user: "very more like Excel itself"):
 *   - gridlines, column letters on top, row numbers on the left, a green frame on the cell in use;
 *   - Enter goes down, Shift+Enter up, Tab right, the arrows move between cells, Esc leaves;
 *     a cell's text is selected when you land on it, so typing replaces it;
 *   - paste rows copied from Excel (Ctrl+C there, Ctrl+V here): they fill from the cell you are in,
 *     adding rows as needed;
 *   - an empty row always waits at the bottom; the totals stay at the foot.
 *
 * columns: [{ key, label, type: 'text'|'number'|'select', options?: [{ value, label }], width?, align?,
 *             min?, editable?: boolean (default: !readOnly), ignoreLock?: boolean, show?: row => node (read-only display) }]
 * rows:    the rows (objects); onChange(rows) gets the whole new list
 * isLocked(row): a row that can't be changed (shown grey); blankRow: what a new row starts as
 * totals:  { [column key]: node } shown on the foot; totalLabel
 */
const LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const cleanNumber = v => String(v ?? '').replace(/[^\d.-]/g, '');

export default function SheetGrid({ columns, rows, onChange, readOnly = false, isLocked = () => false, lockedTitle, blankRow = {}, totals = {}, totalLabel = 'Total', label = 'Sheet' }) {
  const box = useRef(null);
  const canEdit = (col, row) => (col.editable ?? !readOnly) && (col.ignoreLock || !isLocked(row));
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
      return <div className={`xs-ro${col.align === 'right' ? ' xs-num' : ''}`}>{col.show ? col.show(row) : String(row[col.key] ?? '')}</div>;
    }
    const common = { 'data-cell': `${r}:${c}`, 'aria-label': `${col.label}, row ${r + 1}`, onKeyDown: e => onKey(e, r, c), onPaste: e => onPaste(e, r, c),
      onFocus: e => { if (e.target.select && e.target.tagName === 'INPUT') e.target.select(); } };
    if (col.type === 'number') return <NumberInput {...common} className="xs-in xs-num" step="any" min={col.min} value={row[col.key] ?? ''} onChange={e => setCell(r, col.key, e.target.value)} />;
    if (col.type === 'select') return (
      <select {...common} className="xs-in" value={row[col.key] ?? ''} onChange={e => setCell(r, col.key, e.target.value)}>
        <option value="">—</option>
        {(col.options || []).map(o => <option key={o.value} value={o.value}>{o.label}</option>)}
      </select>
    );
    return <input {...common} className="xs-in" value={row[col.key] ?? ''} onChange={e => setCell(r, col.key, e.target.value)} />;
  };

  return (
    <div className="xs-grid" ref={box} role="grid" aria-label={label}>
      <table>
        <colgroup><col style={{ width: 38 }} />{columns.map(c => <col key={c.key} style={c.width ? { width: c.width } : undefined} />)}{!readOnly && <col style={{ width: 30 }} />}</colgroup>
        <thead>
          <tr className="xs-letters"><th />{columns.map((c, i) => <th key={c.key}>{LETTERS[i]}</th>)}{!readOnly && <th />}</tr>
          <tr className="xs-labels"><th />{columns.map(c => <th key={c.key} className={c.align === 'right' ? 'xs-num' : ''}>{c.label}</th>)}{!readOnly && <th />}</tr>
        </thead>
        <tbody>
          {shown.map((row, r) => (
            <tr key={r} className={`${isLocked(row) ? 'xs-locked' : ''}${row.__blank ? ' xs-blank' : ''}`} title={isLocked(row) ? lockedTitle : undefined}>
              <td className="xs-rn">{r + 1}</td>
              {columns.map((col, c) => <td key={col.key}>{cell(row, r, col, c)}</td>)}
              {!readOnly && <td className="xs-del">{!row.__blank && !isLocked(row) && (
                <button type="button" tabIndex={-1} className="xs-del-btn" aria-label={`Remove row ${r + 1}`} title="Remove the row" onClick={() => removeRow(r)}><X size={12} /></button>)}</td>}
            </tr>
          ))}
        </tbody>
        <tfoot>
          <tr><td className="xs-rn" />{columns.map((c, i) => <td key={c.key} className={c.align === 'right' ? 'xs-num' : ''}>{i === 0 ? <strong>{totalLabel}</strong> : totals[c.key] != null ? <strong>{totals[c.key]}</strong> : null}</td>)}{!readOnly && <td />}</tr>
        </tfoot>
      </table>
    </div>
  );
}
