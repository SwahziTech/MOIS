import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/nav.dart';
import '../core/ui.dart';
import 'approvals.dart';
import 'daily_report.dart';
import 'documents.dart';
import 'dashboard.dart';
import 'categories.dart';
import 'colours.dart';
import 'materials.dart';
import 'movements.dart';
import 'pricing.dart';
import 'print_lists.dart';
import 'products.dart';
import 'reports.dart';
import 'recipes.dart';
import 'stock.dart';

/*
 * Each web path's page in the app. Pages are added here as they are ported from the web,
 * one by one; a path not ported yet says so.
 */
final Map<String, Widget Function(String path)> _pages = {
  '/': (_) => const DashboardPage(),
  '/stock': (_) => const StockPage(),
  '/categories': (_) => const CategoriesPage(),
  '/colours': (_) => const ColoursPage(),
  '/recipes': (_) => const RecipesPage(),
  '/pricing': (_) => const PricingPage(),
  '/materials': (_) => const MaterialsPage(),
  '/documents': (_) => const DocumentsPage(),
  '/print-lists': (_) => const PrintListsPage(),
  '/reports': (p) { final q = Uri.parse(p).queryParameters; return ReportsPage(tab: q['tab'], from: q['from'], to: q['to']); },
  '/movements': (_) => const MovementsPage(),
  '/products': (p) => ProductsPage(edit: Uri.parse(p).queryParameters['edit']),
  '/daily-report': (_) => const DailyReportPage(),
  '/approvals': (p) => ApprovalsPage(tab: p.contains('tab=payments') ? 'payments' : 'pending'),
  '/review': (_) => const ReviewsPage(),
};

Widget pageFor(String path, NavItem? item) {
  final base = path.split('&').first;
  final f = _pages[base] ?? _pages[base.split('?').first];
  if (f != null) return f(path);
  return ListView(padding: const EdgeInsets.all(14), children: [
    EmptyState(icon: item?.icon ?? LucideIcons.hammer, title: '${item?.label ?? 'This page'} is being ported from the web', description: 'It comes in this first release.'),
  ]);
}
