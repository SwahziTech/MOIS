import { useLayoutEffect, useRef, useState } from 'react';

/** "1234567.5" → "1,234,567.5" for display; values themselves never carry commas */
export function groupDigits(raw) {
  const s = String(raw ?? '');
  const m = s.match(/^(-?)(\d*)(\.?\d*)$/);
  return m ? m[1] + m[2].replace(/\B(?=(\d{3})+(?!\d))/g, ',') + m[3] : s;
}

/**
 * A number box that shows thousand separators while typing (2026-10-18).
 * A drop-in for <input type="number">: onChange / onBlur get
 * { target: { value } } with the plain number text ("1234.5"), so callers
 * parse it exactly as before. step="1" allows whole numbers only; a min of
 * zero or more refuses a minus sign. Without `value` it keeps its own text.
 */
export default function NumberInput({ value, onChange, onBlur, min, step, ...rest }) {
  const ref = useRef(null);
  const caret = useRef(null);   // characters (digits, '.', '-') before the caret after an edit
  const [own, setOwn] = useState('');
  const raw = value !== undefined && value !== null ? String(value) : own;
  const whole = step === '1' || step === 1;
  const negative = min === undefined || min === null || Number(min) < 0;

  // Keep the caret after the same digits once commas are added or removed
  useLayoutEffect(() => {
    const el = ref.current;
    if (caret.current == null || !el || document.activeElement !== el) return;
    let left = caret.current, pos = 0;
    while (pos < el.value.length && left > 0) { if (/[\d.-]/.test(el.value[pos])) left--; pos++; }
    el.setSelectionRange(pos, pos);
    caret.current = null;
  });

  function change(e) {
    const el = e.target;
    let out = '', dot = false;
    [...el.value.replace(/[,\s]/g, '')].forEach((ch, i) => {
      if (/\d/.test(ch)) out += ch;
      else if (ch === '.' && !dot && !whole) { out += ch; dot = true; }
      else if (ch === '-' && i === 0 && negative) out += ch;
    });
    caret.current = el.value.slice(0, el.selectionStart ?? el.value.length).replace(/[^\d.-]/g, '').length;
    if (value === undefined || value === null) setOwn(out);
    onChange?.({ target: { value: out } });
  }

  return (
    <input ref={ref} type="text" inputMode={whole ? 'numeric' : 'decimal'} autoComplete="off" {...rest}
      value={groupDigits(raw)} onChange={change}
      onBlur={onBlur ? () => onBlur({ target: { value: raw } }) : undefined} />
  );
}
