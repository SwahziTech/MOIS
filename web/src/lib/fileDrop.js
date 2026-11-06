/*
 * Drag and drop for every upload (2026-11-04, the user): a file dropped on an
 * upload's area — the card or window holding its file input — goes to that
 * input, exactly as if chosen with its button (its own onChange runs). The area
 * is outlined while a file is dragged over it. A file dropped anywhere else is
 * ignored, so the browser never opens it and leaves MOIS.
 * 2026-11-06: pasting an image (a screenshot, Ctrl+V) does the same: it goes to
 * the upload of the open window (or of the area being typed in, or the page).
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

// the upload a paste goes to: where the cursor is, else the open window, else the page
function pasteTarget() {
  const at = document.activeElement && document.activeElement !== document.body ? inputFor(document.activeElement) : null;
  if (at) return at;
  const dialogs = [...document.querySelectorAll('[role="dialog"], .modal')];
  for (const d of dialogs.reverse()) { const hit = inputFor(d.querySelector('input[type="file"]') || d); if (hit) return hit; }
  const main = document.querySelector('main');
  return main ? inputFor(main.querySelector('input[type="file"]') || main) : null;
}

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
  window.addEventListener('paste', e => {
    const images = [...(e.clipboardData?.files || [])].filter(f => f.type.startsWith('image/'));
    if (!images.length) return;   // text pastes as usual
    const hit = pasteTarget();
    if (!hit) return;
    const files = images.filter(f => accepts(hit.input, f))
      .map(f => new File([f], `screenshot-${new Date().toISOString().slice(0, 19).replace(/[T:]/g, '-')}.${(f.type.split('/')[1] || 'png').replace('jpeg', 'jpg')}`, { type: f.type }));
    if (!files.length) return;
    e.preventDefault();
    const dt = new DataTransfer();
    (hit.input.multiple ? files : files.slice(0, 1)).forEach(f => dt.items.add(f));
    hit.input.files = dt.files;
    hit.input.dispatchEvent(new Event('change', { bubbles: true }));
  });
}
