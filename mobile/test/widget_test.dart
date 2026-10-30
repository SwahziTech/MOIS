import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mois_mobile/board_data.dart';
import 'package:mois_mobile/board_screen.dart';
import 'package:mois_mobile/format.dart';

void main() {
  test('money is written the MOIS way', () {
    expect(commas(1234567), '1,234,567');
    expect(moneyShort(48200000), 'Tsh 48.2M');
    expect(moneyShort(46154), 'Tsh 46K');
    expect(moneyShort(4615), 'Tsh 4,615');
    expect(monthsBack('2026-01', 1), '2025-12');
    expect(lastDay('2026-02'), '2026-02-28');
  });

  for (final width in [320.0, 375.0, 430.0]) {
    testWidgets('the dashboard fits a ${width.round()} px phone', (tester) async {
      tester.view.physicalSize = Size(width, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: BoardScreen(board: demoBoard(), onRefresh: () async {}, place: 'All branches', today: '2026-10-30'))));
      expect(tester.takeException(), isNull);
      expect(find.text('Needs you now'), findsOneWidget);
      expect(find.text('Tsh 48.2M'), findsOneWidget);
      expect(find.text('Top overdue customers', skipOffstage: false), findsOneWidget);
    });
  }
}
