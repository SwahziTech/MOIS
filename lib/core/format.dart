/*
 * Ports of the web's lib/format.js, lib/periods.js and qtyText (lib/inventory.js) — the same
 * words and numbers as the web (LOCKED: money "Tsh 10,000", never K; dates "Fri, 30 Oct 2026",
 * "30 Oct 2026" in tables; quantities at most 3 decimals).
 */
double n(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
double? nn(Object? v) => v == null || '$v'.trim().isEmpty ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
double r2(num v) => (v * 100).round() / 100;
double q3(num v) => (v * 1000).round() / 1000;

String _group(String digits) {
  final b = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) b.write(',');
    b.write(digits[i]);
  }
  return b.toString();
}

/// Intl en-US with at most [maxDecimals] fraction digits
String _num(num v, int maxDecimals) {
  final neg = v < 0;
  final f = (v.abs() * _pow10(maxDecimals)).round() / _pow10(maxDecimals);
  final s = f.toStringAsFixed(maxDecimals);
  final parts = s.split('.');
  final dec = parts.length > 1 ? parts[1].replaceAll(RegExp(r'0+$'), '') : '';
  return '${neg && f != 0 ? '-' : ''}${_group(parts[0])}${dec.isEmpty ? '' : '.$dec'}';
}

double _pow10(int d) {
  var p = 1.0;
  for (var i = 0; i < d; i++) { p *= 10; }
  return p;
}

const _localSymbol = {'TZS': 'Tsh'};

/// formatMoney: "Tsh 10,000" (no currency set → the plain number)
String formatMoney(num? value, [String? currency]) {
  if (value == null) return '—';
  if (currency == null || currency.isEmpty) return _num(value, 2);
  final sym = _localSymbol[currency] ?? currency;
  return '${value < 0 ? '−' : ''}$sym ${_num(value.abs(), 0)}';
}

/// formatAmount: a plain amount for a table whose header carries the currency
String formatAmount(num? value) => value == null ? '—' : _num(value, 0);

/// formatMoneyShort: summary cards only — never K; M from 10 million, B from a billion
String formatMoneyShort(num? value, [String? currency]) {
  if (value == null) return '—';
  final a = value.abs();
  String s;
  if (a >= 1e9) {
    s = '${(a / 1e9).toStringAsFixed(2)}B';
  } else if (a >= 1e7) {
    s = '${(a / 1e6).toStringAsFixed(1)}M';
  } else {
    s = _num(a, 0);
  }
  s = s.replaceAllMapped(RegExp(r'\.0+([MB])$'), (m) => m[1]!);
  return '${value < 0 ? '−' : ''}${_localSymbol[currency] ?? currency ?? ''} $s'.trim();
}

/// qtyText: at most 3 decimals
String qtyText(num? v) => v == null ? '—' : _num(v, 3);

/// one decimal (wastani, yields)
String n1(num? v) => v == null ? '—' : _num(v, 1);

const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const monthLong = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const weekdayLong = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

DateTime? _parse(Object? v) {
  if (v == null || '$v'.isEmpty) return null;
  final s = '$v';
  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return DateTime.utc(int.parse(s.substring(0, 4)), int.parse(s.substring(5, 7)), int.parse(s.substring(8, 10)));
  return DateTime.tryParse(s)?.toLocal();
}

/// dateText: "Fri, 30 Oct 2026"
String? dateText(Object? v) {
  final d = _parse(v);
  if (d == null) return v == null || '$v'.isEmpty ? null : '$v';
  return '${_wd[d.weekday - 1]}, ${d.day} ${_mon[d.month - 1]} ${d.year}';
}

/// tableDate: "30 Oct 2026"
String? tableDate(Object? v) => dateText(v)?.replaceFirst(RegExp(r'^\w+,\s*'), '');

/// dateTimeText: "Fri, 30 Oct 2026, 14:53"
String? dateTimeText(Object? v) {
  final d = _parse(v);
  if (d == null) return null;
  return '${dateText(v)}, ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String? tableDateTime(Object? v) => dateTimeText(v)?.replaceFirst(RegExp(r'^\w+,\s*'), '');

/// Dates inside text written elsewhere (database messages, saved summaries)
String datesInText(String s) => s.replaceAllMapped(RegExp(r'\b\d{4}-\d{2}-\d{2}\b'), (m) => dateText(m[0]) ?? m[0]!);

String iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
DateTime _utc(String d) => DateTime.utc(int.parse(d.substring(0, 4)), int.parse(d.substring(5, 7)), int.parse(d.substring(8, 10)));
String shiftDay(String d, int days) => iso(_utc(d).add(Duration(days: days)));

/// Today in the organization's time zone (Tanzania: UTC+3; the org's zone is read at sign-in)
String orgToday([int offsetMinutes = 180]) => iso(DateTime.now().toUtc().add(Duration(minutes: offsetMinutes)));

// ---- periods (web lib/periods.js) -------------------------------------------------------
String mondayOf(String d) => shiftDay(d, -(_utc(d).weekday - 1));
String sundayOf(String d) => shiftDay(d, -(_utc(d).weekday % 7));

class PeriodOpt {
  const PeriodOpt(this.value, this.label);
  final String value, label;
}

/// This month, Last month, This week, its days back to Monday, Last week
List<PeriodOpt> weekPeriods(String today) {
  final dow = _utc(today).weekday % 7; // Sunday 0
  final nDays = dow == 0 ? 0 : dow - 1;
  return [
    const PeriodOpt('month', 'This month'),
    const PeriodOpt('lastmonth', 'Last month'),
    const PeriodOpt('week', 'This week'),
    for (var i = 0; i <= nDays; i++)
      PeriodOpt(i == 0 ? 'today' : i == 1 ? 'yesterday' : 'day:${shiftDay(today, -i)}',
          i == 0 ? 'Today' : i == 1 ? 'Yesterday' : weekdayLong[_utc(shiftDay(today, -i)).weekday - 1]),
    const PeriodOpt('lastweek', 'Last week'),
  ];
}

(String, String)? weekRange(String key, String today) {
  final sun = sundayOf(today);
  if (key == 'week') return (sun, today);
  if (key == 'today') return (today, today);
  if (key == 'yesterday') return (shiftDay(today, -1), shiftDay(today, -1));
  if (key == 'lastweek') return (shiftDay(sun, -7), shiftDay(sun, -1));
  if (key.startsWith('day:')) return (key.substring(4), key.substring(4));
  return null;
}

String? weekLabel(String key, String today) => weekPeriods(today).where((p) => p.value == key).firstOrNull?.label;

(String, String) periodRange(String key, String today) {
  final wk = weekRange(key, today);
  if (wk != null) return wk;
  if (key == 'all') return ('0000-01-01', '9999-12-31');
  if (key == 'month') return ('${today.substring(0, 7)}-01', today);
  if (key == 'quarter') {
    final m = int.parse(today.substring(5, 7));
    final q = ((m - 1) ~/ 3) * 3 + 1;
    return ('${today.substring(0, 4)}-${q.toString().padLeft(2, '0')}-01', today);
  }
  if (key == 'year') return ('${today.substring(0, 4)}-01-01', today);
  if (key == 'lastmonth') {
    final first = '${today.substring(0, 7)}-01';
    final prev = shiftDay(first, -1);
    return ('${prev.substring(0, 7)}-01', prev);
  }
  return (shiftDay(today, -(int.tryParse(key) ?? 0)), today);
}

String _monShort(String d) => _mon[int.parse(d.substring(5, 7)) - 1];
String lastOfMonth(String d) => iso(DateTime.utc(int.parse(d.substring(0, 4)), int.parse(d.substring(5, 7)) + 1, 0));

/// The dates beside a period's name: "Nov", "Nov 2 – Nov 7", "Nov 11"
String shortRange(String? from, String? to, String today) {
  if (from == null || to == null || from == '0000-01-01') return '';
  String yr(String d) => d.substring(0, 4) != today.substring(0, 4) ? ' ${d.substring(0, 4)}' : '';
  String day(String d) => '${_monShort(d)} ${int.parse(d.substring(8))}${yr(d)}';
  if (from == to) return day(from);
  var f = from;
  if (_utc(f).weekday == DateTime.sunday && shiftDay(f, 1).compareTo(to) <= 0) f = shiftDay(f, 1);
  if (f == to) return day(f);
  if (f.substring(8) == '01' && f.substring(0, 7) == to.substring(0, 7) && (to == lastOfMonth(to) || to == today)) return '${_monShort(f)}${yr(f)}';
  return '${day(f)} – ${day(to)}';
}

/// StepBar month options, newest first: 'YYYY-MM', "This month" / "October 2026"
List<({String value, String label, String note})> monthOptions(String today, [int count = 12]) {
  final out = <({String value, String label, String note})>[];
  var y = int.parse(today.substring(0, 4));
  var m = int.parse(today.substring(5, 7));
  for (var i = 0; i < count; i++) {
    final v = '$y-${m.toString().padLeft(2, '0')}';
    final name = '${monthLong[m - 1]} $y';
    out.add((value: v, label: i == 0 ? 'This month' : i == 1 ? 'Last month' : name, note: i < 2 ? monthLong[m - 1].substring(0, 3) : ''));
    m -= 1;
    if (m == 0) { m = 12; y -= 1; }
  }
  return out;
}

/// "Grace Mushi" → "GM"
String initials(String? name) {
  final parts = (name ?? '').trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  return (parts.first[0] + (parts.length > 1 ? parts.last[0] : '')).toUpperCase();
}
