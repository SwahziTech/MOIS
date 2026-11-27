/*
 * Tanzania's public holidays (2026-11-27, the user: attendance days count against workdays "excluding Sundays and
 * major holidays"). Fixed dates every year; Good Friday and Easter Monday worked out from Easter; the Islamic
 * holidays follow the moon and are announced close to the day — the dates below are the expected ones and can be
 * a day out (add the next years here when known).
 */
const FIXED = [
  ['01-01', "New Year's Day"], ['01-12', 'Zanzibar Revolution Day'], ['04-07', 'Karume Day'], ['04-26', 'Union Day'],
  ['05-01', "Workers' Day"], ['07-07', 'Saba Saba'], ['08-08', 'Nane Nane'], ['10-14', 'Nyerere Day'],
  ['12-09', 'Independence Day'], ['12-25', 'Christmas Day'], ['12-26', 'Boxing Day'],
];
const ISLAMIC = {
  2026: [['2026-03-20', 'Eid al-Fitr'], ['2026-05-27', 'Eid al-Adha'], ['2026-08-26', 'Maulid']],
  2027: [['2027-03-10', 'Eid al-Fitr'], ['2027-05-17', 'Eid al-Adha'], ['2027-08-15', 'Maulid']],
  2028: [['2028-02-27', 'Eid al-Fitr'], ['2028-05-05', 'Eid al-Adha'], ['2028-08-03', 'Maulid']],
};

/** Easter Sunday (Gregorian, anonymous algorithm) as YYYY-MM-DD */
function easter(y) {
  const a = y % 19, b = Math.floor(y / 100), c = y % 100, d = Math.floor(b / 4), e = b % 4, f = Math.floor((b + 8) / 25);
  const g = Math.floor((b - f + 1) / 3), h = (19 * a + b - d - g + 15) % 30, i = Math.floor(c / 4), k = c % 4;
  const l = (32 + 2 * e + 2 * i - h - k) % 7, m = Math.floor((a + 11 * h + 22 * l) / 451);
  const month = Math.floor((h + l - 7 * m + 114) / 31), day = ((h + l - 7 * m + 114) % 31) + 1;
  return `${y}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}
const shift = (iso, n) => { const d = new Date(`${iso}T00:00:00Z`); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); };

const cache = {};
/** date → holiday name, for a year */
export function holidaysOf(year) {
  if (cache[year]) return cache[year];
  const m = {};
  for (const [md, name] of FIXED) m[`${year}-${md}`] = name;
  const e = easter(year);
  m[shift(e, -2)] = 'Good Friday';
  m[shift(e, 1)] = 'Easter Monday';
  for (const [d, name] of ISLAMIC[year] || []) m[d] = name;
  cache[year] = m;
  return m;
}

/** the holiday on a day (YYYY-MM-DD), or null */
export const holidayOn = iso => holidaysOf(Number(iso.slice(0, 4)))[iso] ?? null;
