/*
 * A proof's file name, from its transaction (2026-11-06, the user): easy to find
 * and recognise wherever it is saved —
 *   Sale-12_Mbaga_235000_2026-11-02.jpg
 *   Paid-Supplier_maneno_13530000_2026-10-30.pdf
 * The pasted SMS, when saved as a file, takes the same name with .txt.
 */
const clean = s => String(s ?? '').normalize('NFKD').replace(/[^\w.-]+/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '').slice(0, 40);

export function extOf(file) {
  const fromName = (file?.name?.split('.').pop() || '').toLowerCase();
  if (/^[a-z0-9]{2,5}$/.test(fromName) && fromName !== (file?.name || '').toLowerCase()) return fromName;
  return ((file?.type || '').split('/')[1] || 'jpg').replace('jpeg', 'jpg');
}

/** parts: { kind: 'Sale-12' | 'Paid-Supplier' …, who, amount, date } */
export function proofName({ kind, who, amount, date }, ext = 'jpg') {
  return [clean(kind), clean(who), amount != null ? String(Math.round(Number(amount))) : null, clean(date)]
    .filter(Boolean).join('_') + `.${ext}`;
}
