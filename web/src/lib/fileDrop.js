/*
 * Drag and drop for every upload (2026-11-04, the user): a file dropped on an
 * upload's area — the card or window holding its file input — goes to that
 * input, exactly as if chosen with its button (its own onChange runs). The area
 * is outlined while a file is dragged over it. A file dropped anywhere else is
 * ignored, so the browser never opens it and leaves MOIS.
 */
const AREAS = '.ru-file-row, .ru-file, .modal, .card, .page-embedded, main';

// the upload a drop lands on: the nearest area holding an enabled file input
function inputFor(target) {
  let el = target instanceof Element ? target : target?.parentElement;
  while (el && el !== document.body) {
    if (el.matches?.(AREAS)) {
      const input = el.querySelector('input[type="file"]:not([disabled])');
      if (input) return { area: el, input };
    }
    el = el.parentElement;
  }
  return null;
}

// does the file suit the input's accept list ("image/*,application/pdf", ".csv", …)?
function accepts(input, file) {
  const list = (input.accept || '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
  if (!list.length) return true;
  const name = file.name.toLowerCase(); const type = (file.type || '').toLowerCase();
  return list.some(a => (a.startsWith('.') ? name.endsWith(a) : a.endsWith('/*') ? type.startsWith(a.slice(0, -1)) : type === a));
}

let lit = null;
const light = area => { if (lit === area) return; if (lit) lit.classList.remove('drop-over'); lit = area; if (area) area.classList.add('drop-over'); };
const hasFiles = e => [...(e.dataTransfer?.types || [])].includes('Files');

export function installFileDrop() {
  if (typeof window === 'undefined' || window.__moisFileDrop) return;
  window.__moisFileDrop = true;
  window.addEventListener('dragover', e => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    const hit = inputFor(e.target);
    e.dataTransfer.dropEffect = hit ? 'copy' : 'none';
    light(hit?.area ?? null);
  });
  window.addEventListener('dragleave', e => { if (!e.relatedTarget) light(null); });
  window.addEventListener('drop', e => {
    if (!hasFiles(e)) return;
    e.preventDefault();
    light(null);
    const hit = inputFor(e.target);
    if (!hit) return;
    const files = [...e.dataTransfer.files].filter(f => accepts(hit.input, f));
    if (!files.length) return;
    const dt = new DataTransfer();
    (hit.input.multiple ? files : files.slice(0, 1)).forEach(f => dt.items.add(f));
    hit.input.files = dt.files;
    hit.input.dispatchEvent(new Event('change', { bubbles: true }));
  });
}
