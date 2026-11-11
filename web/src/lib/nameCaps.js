/*
 * Names start with capitals, everywhere (2026-11-11, the user): while a name is typed, the first
 * letter of each word becomes upper case — "juma hassan" → "Juma Hassan". Only the first letter is
 * touched, so "CRDB" or "McDonald" stay as typed.
 *
 * A field counts as a name when its label, placeholder or aria-label says name, or it asks for a
 * person, customer, supplier, buyer, team, branch, product, material, category, meter or machine —
 * never an email, username, password, number or note.
 */
const NAME_HINT = /\b(name|names|jina|customer|buyer|supplier|person|staff|employee|casual|team|branch|product|material|category|colou?r|meter|machine|item|site)\b/i;
const NOT_NAME = /\b(e-?mail|user ?name|login|password|phone|number|no\.|tin|vrn|nssf|reference|receipt|note|notes|description|reason|search|amount|price|qty|quantity|code|sms|address|query)\b/i;

const hintOf = el => {
  const label = el.closest('label');
  const labelText = label ? (label.querySelector('span')?.textContent || label.textContent || '') : '';
  return [el.getAttribute('aria-label'), el.getAttribute('placeholder'), labelText, el.name, el.dataset.field].filter(Boolean).join(' ');
};

export const capitalizeWords = v => String(v).replace(/(^|[\s\-/(])(\p{Ll})/gu, (_, sep, ch) => sep + ch.toUpperCase());

const isNameField = el => {
  if (!(el instanceof HTMLInputElement) || (el.type && el.type !== 'text' && el.type !== 'search')) return false;
  if (el.type === 'search' || el.dataset.noCaps !== undefined) return false;
  if (el.inputMode === 'numeric' || el.inputMode === 'decimal' || el.inputMode === 'tel' || el.inputMode === 'email') return false;
  if (el.dataset.caps !== undefined) return true;   // a field can ask for it
  const h = hintOf(el);
  return NAME_HINT.test(h) && !NOT_NAME.test(h);
};

const setNative = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;

export function installNameCaps() {
  // capture phase on the document runs before React reads the value, so the form state gets the capitalised name
  document.addEventListener('input', e => {
    const el = e.target;
    if (!isNameField(el) || e.isComposing) return;
    const v = el.value;
    const nv = capitalizeWords(v);
    if (nv === v) return;
    const a = el.selectionStart, b = el.selectionEnd;
    setNative.call(el, nv);
    try { el.setSelectionRange(a, b); } catch { /* some inputs don't keep a selection */ }
  }, true);
}
