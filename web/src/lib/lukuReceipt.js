/*
 * Read a LUKU payment message (2026-10-28) — the SMS/receipt text sent after
 * buying a token, e.g. "Malipo yamekamilika. <ref> <ref> TOKEN <20 digits>
 * <units>KWH Cost <n> VAT 18% <n> EWURA 1% <n> REA 3% <n> Debt Collected <n>
 * TOTAL TZS <n> <date> <time>" — into the token form's fields, only to fill
 * them in: everything stays editable. Units (kWh) and the amount are what
 * matter; the token number is optional.
 */
const amount = s => (s == null ? null : Number(String(s).replace(/,/g, '')));
const pick = (text, re) => { const m = text.match(re); return m ? m[1] : null; };

export function parseLukuReceipt(raw) {
  const text = String(raw || '').replace(/\s+/g, ' ').trim();
  if (!text) return null;
  const units = amount(pick(text, /([\d,]+(?:\.\d+)?)\s*KWH/i));
  const cost = amount(pick(text, /\bCost\s*:?\s*([\d,]+(?:\.\d+)?)/i));
  const vat = amount(pick(text, /\bVAT\s*(?:\d+(?:\.\d+)?\s*%)?\s*:?\s*([\d,]+(?:\.\d+)?)/i));
  const ewura = amount(pick(text, /\bEWURA\s*(?:\d+(?:\.\d+)?\s*%)?\s*:?\s*([\d,]+(?:\.\d+)?)/i));
  const rea = amount(pick(text, /\bREA\s*(?:\d+(?:\.\d+)?\s*%)?\s*:?\s*([\d,]+(?:\.\d+)?)/i));
  const debt = amount(pick(text, /\bDebt\s*(?:Collected)?\s*:?\s*([\d,]+(?:\.\d+)?)/i));
  let total = amount(pick(text, /\bTOTAL\s*(?:TZS|TSH)?\s*:?\s*([\d,]+(?:\.\d+)?)/i));
  if (total == null && cost != null) total = Math.round((cost + (vat || 0) + (ewura || 0) + (rea || 0) + (debt || 0)) * 100) / 100;
  // the token: 20 digits after TOKEN, written in groups
  const tokenDigits = (pick(text, /\bTOKEN\s*:?\s*((?:\d[\s-]?){20})/i) || '').replace(/\D/g, '');
  const token = tokenDigits.length === 20 ? tokenDigits.replace(/(\d{4})(?=\d)/g, '$1 ') : null;
  const date = pick(text, /(\d{4}-\d{2}-\d{2})/);
  const time = pick(text, /\d{4}-\d{2}-\d{2}[ T](\d{1,2}:\d{2})/);
  // the payment references: what comes between the opening words and TOKEN
  const refPart = pick(text, /^(?:[^.]*\.)?\s*(.*?)\s*\bTOKEN\b/i);
  const ref = refPart ? refPart.split(' ').filter(w => /\d/.test(w) && w.length >= 6).join(' ') || null : null;
  if (units == null && total == null && !token) return null;
  return { units, cost, vat, ewura, rea, debt, total, token, date, time: time ? time.padStart(5, '0') : null, ref };
}
