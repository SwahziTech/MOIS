/// Money and numbers as the web app writes them (LOCKED: "Tsh 10,000").
double n(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;

String commas(num v) {
  final s = v.abs().round().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return '${v < 0 ? '−' : ''}$b';
}

String moneyShort(num v) {
  final a = v.abs();
  final String t;
  if (a >= 1e9) {
    t = '${(a / 1e9).toStringAsFixed(1)}B';
  } else if (a >= 1e6) {
    t = '${(a / 1e6).toStringAsFixed(1)}M';
  } else if (a >= 1e4) {
    t = '${(a / 1e3).round()}K';
  } else {
    t = commas(a);
  }
  return '${v < 0 ? '−' : ''}Tsh ${t.replaceAll('.0', '')}';
}

String isoDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// yyyy-MM, [back] months before [month].
String monthsBack(String month, int back) {
  final d = DateTime.utc(int.parse(month.substring(0, 4)), int.parse(month.substring(5, 7)) - back);
  return isoDay(d).substring(0, 7);
}

String lastDay(String month) {
  final d = DateTime.utc(int.parse(month.substring(0, 4)), int.parse(month.substring(5, 7)) + 1, 0);
  return isoDay(d);
}

String monthShort(String month) => const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][int.parse(month.substring(5, 7)) - 1];
