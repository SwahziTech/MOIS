/*
 * Suggestions under the box (2026-11-11, the user): the browser's own suggestion list (an input
 * with list="…" and a <datalist>) can open far from the field. Every such field in MOIS gets this
 * drop-down instead, attached right under the box: the matching suggestions as you type, ↑ ↓ and
 * Enter to pick, Esc to close. The page's own code is unchanged — it still reads the box's value.
 */
const setNative = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
let box = null, input = null, items = [], at = -1;

function ensureBox() {
  if (box) return box;
  box = document.createElement('div');
  box.className = 'sg-pop';
  box.setAttribute('role', 'listbox');
  box.addEventListener('mousedown', e => {
    const li = e.target.closest('[data-i]');
    e.preventDefault();
    if (li) pick(Number(li.dataset.i));
  });
  document.body.appendChild(box);
  return box;
}
const optionsOf = el => {
  const id = el.dataset.sgList; const dl = id && document.getElementById(id);
  return dl ? [...dl.querySelectorAll('option')].map(o => ({ value: o.value, note: (o.textContent || '').trim() !== o.value ? (o.textContent || '').trim() : '' })).filter(o => o.value) : [];
};
function place() {
  if (!box || !input) return;
  const r = input.getBoundingClientRect();
  box.style.left = `${r.left}px`; box.style.top = `${r.bottom + 4}px`; box.style.width = `${r.width}px`;
}
function hide() { if (box) box.style.display = 'none'; items = []; at = -1; }
function render() {
  if (!input) return;
  const q = input.value.trim().toLowerCase();
  items = optionsOf(input).filter(o => !q || o.value.toLowerCase().includes(q) || o.note.toLowerCase().includes(q))
    .filter(o => o.value.toLowerCase() !== q).slice(0, 8);
  if (!items.length) { hide(); return; }
  ensureBox();
  at = Math.min(at, items.length - 1);
  box.innerHTML = '';
  items.forEach((o, i) => {
    const li = document.createElement('div');
    li.className = `sg-item${i === at ? ' is-on' : ''}`; li.dataset.i = i; li.setAttribute('role', 'option');
    const v = document.createElement('span'); v.textContent = o.value; li.appendChild(v);
    if (o.note) { const n = document.createElement('span'); n.className = 'sg-note'; n.textContent = o.note; li.appendChild(n); }
    box.appendChild(li);
  });
  box.style.display = 'block';
  place();
}
function pick(i) {
  const o = items[i]; if (!o || !input) return;
  setNative.call(input, o.value);
  input.dispatchEvent(new Event('input', { bubbles: true }));
  hide();
}

export function installSuggest() {
  // take over the field's suggestions the moment it is used: the native list is turned off
  document.addEventListener('focusin', e => {
    const el = e.target;
    if (!(el instanceof HTMLInputElement)) return;
    if (el.getAttribute('list')) { el.dataset.sgList = el.getAttribute('list'); el.removeAttribute('list'); el.setAttribute('autocomplete', 'off'); }
    if (!el.dataset.sgList) return;
    input = el; at = -1; render();
  });
  document.addEventListener('input', e => { if (e.target === input) { at = -1; render(); } });
  document.addEventListener('focusout', e => { if (e.target === input) setTimeout(() => { if (document.activeElement !== input) { hide(); input = null; } }, 120); });
  document.addEventListener('keydown', e => {
    if (e.target !== input || !items.length || !box || box.style.display === 'none') return;
    if (e.key === 'ArrowDown') { e.preventDefault(); at = (at + 1) % items.length; render(); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); at = (at - 1 + items.length) % items.length; render(); }
    else if (e.key === 'Enter' && at >= 0) { e.preventDefault(); pick(at); }
    else if (e.key === 'Escape') { e.preventDefault(); hide(); }
  }, true);
  window.addEventListener('scroll', place, true);
  window.addEventListener('resize', place);
}
