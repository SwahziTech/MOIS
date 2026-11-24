import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'format.dart';
import 'offline.dart';
import 'session.dart';
import 'theme.dart';

/*
 * The web's shared parts (components/ListControls.jsx, PeriodBar.jsx, Modal.jsx, EmptyState,
 * ErrorState and their CSS: .page-tabs, .filter-chip, .mm-stat, .badge, .btn, .alert…),
 * redrawn for the phone with the same names, sizes and colours.
 */

// ---- text helpers (.pl-label / .pl-help) ------------------------------------------------
class PlLabel extends StatelessWidget {
  const PlLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(), style: TextStyle(fontSize: Fs.xs, color: context.tk.textMuted, letterSpacing: 0.5));
}

class PlHelp extends StatelessWidget {
  const PlHelp(this.text, {super.key, this.color, this.maxLines});
  final String text;
  final Color? color;
  final int? maxLines;
  @override
  Widget build(BuildContext context) => Text(text, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: TextStyle(fontSize: Fs.xs, color: color ?? context.tk.textMuted));
}

// ---- .page-tabs (a page's own tabs) ---------------------------------------------------
class PageTabs<T> extends StatelessWidget {
  const PageTabs({super.key, required this.tabs, required this.value, required this.onChange});
  final List<(T, String)> tabs;
  final T value;
  final ValueChanged<T> onChange;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final (k, label) in tabs)
            InkWell(
              onTap: () => onChange(k),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(border: Border(bottom: BorderSide(color: k == value ? C.khaki : Colors.transparent, width: 2))),
                child: Text(label, style: TextStyle(fontSize: Fs.sm, color: k == value ? t.textPrimary : t.textMuted, fontWeight: k == value ? FontWeight.w600 : FontWeight.w400)),
              ),
            ),
        ]),
      ),
    );
  }
}

// ---- .filter-chips / ChipRow ---------------------------------------------------------
class Chip2 extends StatelessWidget {
  const Chip2(this.label, {super.key, required this.on, required this.onTap});
  final String label;
  final bool on;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Material(
      color: on ? const Color(0x2EB7A57A) : (t.dark ? t.border : const Color(0xFFE8E5E0)),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(label, style: TextStyle(fontSize: Fs.xs, fontWeight: on ? FontWeight.w600 : FontWeight.w500, color: on ? (t.dark ? C.khakiLight : C.coffee) : t.textSecondary)),
        ),
      ),
    );
  }
}

class ChipItem {
  const ChipItem(this.id, this.label, [this.children]);
  final String id, label;
  final List<ChipItem>? children;
}

/// "All" + each item; an item with children (a category group) opens a second row
class ChipRow extends StatelessWidget {
  const ChipRow({super.key, required this.items, required this.value, required this.onChange, this.allLabel = 'All'});
  final List<ChipItem> items;
  final String value;
  final ValueChanged<String> onChange;
  final String allLabel;
  @override
  Widget build(BuildContext context) {
    final open = items.where((i) => (i.children?.isNotEmpty ?? false) && (i.id == value || i.children!.any((c) => c.id == value))).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 6, runSpacing: 6, children: [
        Chip2(allLabel, on: value.isEmpty, onTap: () => onChange('')),
        for (final i in items) Chip2(i.label, on: value == i.id || open?.id == i.id, onTap: () => onChange(value == i.id ? '' : i.id)),
      ]),
      if (open != null) ...[
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          Chip2('All ${open.label}', on: value == open.id, onTap: () => onChange(open.id)),
          for (final c in open.children!) Chip2(c.label, on: value == c.id, onTap: () => onChange(c.id)),
        ]),
      ],
    ]);
  }
}

// ---- .list-toolbar: search + Sort / Filter ---------------------------------------------
class SortSpec {
  const SortSpec({required this.value, required this.onChange, required this.options});
  final String value;
  final ValueChanged<String> onChange;
  final List<(String, String)> options;
}

class FilterSpec {
  const FilterSpec({required this.key, required this.label, required this.value, required this.onChange, required this.options});
  final String key, label, value;
  final ValueChanged<String> onChange;
  final List<(String, String)> options;
}

class ListToolbar extends StatelessWidget {
  const ListToolbar({super.key, required this.onSearch, this.placeholder = 'Search…', this.sort, this.filters = const [], this.trailing = const []});
  final ValueChanged<String> onSearch;
  final String placeholder;
  final SortSpec? sort;
  final List<FilterSpec> filters;
  final List<Widget> trailing;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final narrowed = filters.any((f) => f.value != f.options.first.$1);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: [
        Expanded(
          child: SizedBox(
            height: 40,
            child: TextField(
              onChanged: onSearch,
              style: const TextStyle(fontSize: Fs.sm),
              decoration: InputDecoration(
                hintText: placeholder, fillColor: t.canvas, contentPadding: EdgeInsets.zero,
                prefixIcon: Icon(LucideIcons.search, size: 15, color: t.textMuted),
              ),
            ),
          ),
        ),
        if (sort != null || filters.isNotEmpty) ...[
          const SizedBox(width: 8),
          SizedBox(
            height: 40, width: 44,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, side: BorderSide(color: narrowed ? C.khaki : t.borderStrong)),
              onPressed: () => _open(context),
              child: Badge(isLabelVisible: narrowed, smallSize: 7, backgroundColor: C.khaki, child: const Icon(LucideIcons.arrowUpDown, size: 15)),
            ),
          ),
        ],
        for (final w in trailing) ...[const SizedBox(width: 8), w],
      ]),
    );
  }

  void _open(BuildContext context) => showModalBottomSheet(
        context: context,
        builder: (ctx) => SafeArea(
          child: StatefulBuilder(builder: (ctx, set) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
            if (sort != null) ...[
              const Padding(padding: EdgeInsets.only(bottom: 6), child: PlLabel('Sort')),
              for (final (v, l) in sort!.options)
                ListTile(
                  dense: true, contentPadding: EdgeInsets.zero, title: Text(l),
                  trailing: v == sort!.value ? const Icon(LucideIcons.check, size: 16) : null,
                  onTap: () { sort!.onChange(v); Navigator.pop(ctx); },
                ),
            ],
            if (filters.isNotEmpty) ...[
              const Padding(padding: EdgeInsets.only(top: 10, bottom: 6), child: PlLabel('Show')),
              for (final f in filters)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DropdownButtonFormField<String>(
                    initialValue: f.value, isExpanded: true,
                    decoration: InputDecoration(labelText: f.label),
                    items: [for (final (v, l) in f.options) DropdownMenuItem(value: v, child: Text(l, overflow: TextOverflow.ellipsis))],
                    onChanged: (v) { f.onChange(v ?? f.options.first.$1); set(() {}); },
                  ),
                ),
            ],
          ])),
        ),
      );
}

// ---- .mm-stats (summary cards, two a row on phones) --------------------------------------
class Stats extends StatelessWidget {
  const Stats(this.cards, {super.key});
  final List<Widget> cards;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10),
        child: LayoutBuilder(builder: (context, c) {
          final w = (c.maxWidth - 8) / 2;
          return Wrap(spacing: 8, runSpacing: 8, children: [for (final x in cards) SizedBox(width: w, child: x)]);
        }),
      );
}

class Stat extends StatelessWidget {
  const Stat(this.label, this.figure, {super.key, this.help, this.figureColor, this.onTap});
  final String label, figure;
  final String? help;
  final Color? figureColor;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Material(
      color: t.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            PlLabel(label),
            const SizedBox(height: 2),
            FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(figure, maxLines: 1, style: TextStyle(fontSize: Fs.lg, fontWeight: FontWeight.w700, color: figureColor))),
            if (help != null && help!.isNotEmpty) PlHelp(help!, maxLines: 2),
          ]),
        ),
      ),
    );
  }
}

// ---- .badge ---------------------------------------------------------------------------
enum Tone { success, warning, error, neutral, info }

class Badge2 extends StatelessWidget {
  const Badge2(this.text, {super.key, this.tone = Tone.neutral});
  final String text;
  final Tone tone;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final (bg, fg) = switch (tone) {
      Tone.success => (t.bgSuccess, C.success),
      Tone.warning => (t.bgWarning, C.warning),
      Tone.error => (t.bgError, C.error),
      Tone.info => (t.bgInfo, C.info),
      Tone.neutral => (t.dark ? t.border : const Color(0xFFE8E5E0), t.textSecondary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(100)),
      child: Text(text, style: TextStyle(fontSize: Fs.xs, fontWeight: FontWeight.w500, color: fg)),
    );
  }
}

// ---- .alert ---------------------------------------------------------------------------
class Alert extends StatelessWidget {
  const Alert(this.text, {super.key, this.tone = Tone.info, this.action});
  final String text;
  final Tone tone;
  final Widget? action;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final (bg, fg) = switch (tone) {
      Tone.error => (t.bgError, C.error),
      Tone.warning => (t.bgWarning, C.warning),
      Tone.success => (t.bgSuccess, C.success),
      _ => (t.bgInfo, C.info),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Row(children: [
        Expanded(child: Text(text, style: TextStyle(fontSize: Fs.sm, color: fg))),
        ?action,
      ]),
    );
  }
}

// ---- states ---------------------------------------------------------------------------
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.description});
  final IconData icon;
  final String title;
  final String? description;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: Column(children: [
        Container(
          width: 48, height: 48,
          decoration: BoxDecoration(color: t.canvas, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, size: 22, color: t.textMuted),
        ),
        const SizedBox(height: 12),
        Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.base)),
        if (description != null) ...[const SizedBox(height: 6), Text(description!, textAlign: TextAlign.center, style: TextStyle(fontSize: Fs.sm, color: t.textMuted))],
      ]),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState(this.message, {super.key, this.onRetry});
  final String message;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Icon(LucideIcons.triangleAlert, size: 28, color: C.error),
          const SizedBox(height: 10),
          Text(message, textAlign: TextAlign.center),
          if (onRetry != null) ...[const SizedBox(height: 12), OutlinedButton(onPressed: onRetry, child: const Text('Try again'))],
        ]),
      );
}

/// Grey bars while loading (.skeleton)
class Skeleton extends StatelessWidget {
  const Skeleton({super.key, this.rows = 5, this.height = 56});
  final int rows;
  final double height;
  @override
  Widget build(BuildContext context) => Column(children: [
        for (var i = 0; i < rows; i++)
          Container(height: height, margin: const EdgeInsets.only(bottom: 8), decoration: BoxDecoration(color: context.tk.soft, borderRadius: BorderRadius.circular(10))),
      ]);
}

/// "Offline — as of …" over a page showing its saved copy
class OfflineNote extends StatelessWidget {
  const OfflineNote(this.savedAt, {super.key});
  final DateTime? savedAt;
  @override
  Widget build(BuildContext context) => savedAt == null
      ? const SizedBox.shrink()
      : Alert('Offline — showing what was loaded ${tableDateTime(savedAt!.toIso8601String())}.', tone: Tone.warning);
}

// ---- .card with a header -----------------------------------------------------------------
class CardBox extends StatelessWidget {
  const CardBox({super.key, this.title, this.trailing, required this.child, this.padding = const EdgeInsets.all(14)});
  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(color: t.surface, border: Border.all(color: t.border), borderRadius: BorderRadius.circular(10)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (title != null)
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: t.border))),
            child: Row(children: [
              Expanded(child: Text(title!, style: const TextStyle(fontSize: Fs.md, fontWeight: FontWeight.w600))),
              ?trailing,
            ]),
          ),
        Padding(padding: padding, child: child),
      ]),
    );
  }
}

// ---- PeriodBar / StepBar (LOCKED period design) -----------------------------------------
class PeriodBar extends StatelessWidget {
  const PeriodBar({super.key, required this.value, required this.onChange, this.extra = const [], this.range, this.note});
  final String value;
  final ValueChanged<String> onChange;
  final List<(String, String)> extra;
  final (String, String)? range;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final today = session.today;
    final dow = DateTime.parse(today).weekday - 1; // days since Monday
    final steps = [for (var i = 0; i <= dow; i++) i == 0 ? 'today' : i == 1 ? 'yesterday' : 'day:${shiftDay(today, -i)}', 'lastweek', 'lastmonth'];
    const lastOf = {'week': 'lastweek', 'month': 'lastmonth'};
    final at = steps.indexOf(value);
    final earlier = at >= 0 ? (at + 1 < steps.length ? steps[at + 1] : null) : lastOf[value];
    final later = at >= 0 ? (at == 0 ? null : steps[at - 1]) : (lastOf.entries.where((e) => e.value == value).firstOrNull?.key ?? (value == 'week' || value == 'month' ? 'today' : null));
    final label = weekLabel(value, today) ?? extra.where((x) => x.$1 == value).firstOrNull?.$2 ?? '';
    final (from, to) = range ?? periodRange(value, today);
    final shown = note ?? shortRange(from, to, today);
    final usual = weekPeriods(today);
    return _Bar(
      onEarlier: earlier == null ? null : () => onChange(earlier),
      onLater: later == null ? null : () => onChange(later),
      label: label,
      note: shown,
      showNow: value != 'month',
      onNow: () => onChange('month'),
      options: [...usual.map((p) => (p.value, p.label)), ...extra],
      value: value,
      onPick: onChange,
    );
  }
}

class StepBar extends StatelessWidget {
  const StepBar({super.key, required this.options, required this.value, required this.onChange, this.nowLabel = 'This month'});
  final List<({String value, String label, String note})> options;
  final String value;
  final ValueChanged<String> onChange;
  final String nowLabel;
  @override
  Widget build(BuildContext context) {
    final at = options.indexWhere((o) => o.value == value);
    final cur = at >= 0 ? options[at] : null;
    return _Bar(
      onEarlier: at < 0 || at >= options.length - 1 ? null : () => onChange(options[at + 1].value),
      onLater: at <= 0 ? null : () => onChange(options[at - 1].value),
      label: cur?.label ?? '—',
      note: cur?.note ?? '',
      showNow: at > 0,
      nowLabel: nowLabel,
      onNow: () => onChange(options.first.value),
      options: [for (final o in options) (o.value, o.note.isEmpty ? o.label : '${o.label} · ${o.note}')],
      value: value,
      onPick: onChange,
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.onEarlier, required this.onLater, required this.label, required this.note, required this.showNow, required this.onNow,
      required this.options, required this.value, required this.onPick, this.nowLabel = 'This month'});
  final VoidCallback? onEarlier, onLater;
  final String label, note, nowLabel, value;
  final bool showNow;
  final VoidCallback onNow;
  final List<(String, String)> options;
  final ValueChanged<String> onPick;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    Widget step(IconData i, VoidCallback? f) => SizedBox(
          width: 36, height: 36,
          child: OutlinedButton(
            style: OutlinedButton.styleFrom(padding: EdgeInsets.zero, side: BorderSide(color: t.border), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            onPressed: f, child: Icon(i, size: 18),
          ),
        );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        step(LucideIcons.chevronLeft, onEarlier),
        const SizedBox(width: 6),
        step(LucideIcons.chevronRight, onLater),
        const SizedBox(width: 8),
        Expanded(
          child: Text.rich(TextSpan(children: [
            TextSpan(text: label, style: TextStyle(fontWeight: FontWeight.w700, color: t.textPrimary)),
            if (note.isNotEmpty) TextSpan(text: ' · $note'),
          ]), style: TextStyle(fontSize: Fs.sm, color: t.textMuted), maxLines: 2),
        ),
        if (showNow) TextButton(onPressed: onNow, child: Text(nowLabel)),
        PopupMenuButton<String>(
          tooltip: 'Period',
          initialValue: value,
          onSelected: onPick,
          itemBuilder: (_) => [for (final (v, l) in options) PopupMenuItem(value: v, child: Text(l))],
          child: Container(
            height: 36, padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(border: Border.all(color: t.borderStrong), borderRadius: BorderRadius.circular(6)),
            child: const Icon(LucideIcons.chevronDown, size: 16),
          ),
        ),
      ]),
    );
  }
}

// ---- Modal (web components/Modal.jsx): title, × top right (LOCKED close-x), body, footer ----
Future<T?> showModal<T>(BuildContext context, {required String title, required Widget Function(BuildContext) body, Widget Function(BuildContext)? footer}) =>
    showModalBottomSheet<T>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.92),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              padding: const EdgeInsets.fromLTRB(18, 14, 6, 10),
              decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ctx.tk.border))),
              child: Row(children: [
                Expanded(child: Text(title, style: const TextStyle(fontSize: Fs.md, fontWeight: FontWeight.w600))),
                IconButton(
                  tooltip: 'Close', onPressed: () => Navigator.pop(ctx),
                  style: IconButton.styleFrom(foregroundColor: ctx.tk.textMuted),
                  icon: const Icon(LucideIcons.x, size: 20),
                ),
              ]),
            ),
            Flexible(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(18, 14, 18, 18), child: body(ctx))),
            if (footer != null)
              Container(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: ctx.tk.border))),
                child: footer(ctx),
              ),
          ]),
        ),
      ),
    );

void toast(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), backgroundColor: error ? C.error : null));
}

/// The result of a write, said plainly: sent now, or waiting on the phone
void sentOrQueued(BuildContext context, String how, String what) =>
    toast(context, how == 'queued' ? '$what — saved on this phone, sent when online' : what);

/// The status line under the top bar: offline, waiting to send, failed
class SyncStrip extends StatelessWidget {
  const SyncStrip({super.key, required this.onOpen});
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: offline,
        builder: (context, _) {
          if (offline.online && offline.waiting == 0 && offline.failed == 0) return const SizedBox.shrink();
          final parts = [
            if (!offline.online) 'Offline',
            if (offline.waiting > 0) '${offline.waiting} waiting to send',
            if (offline.failed > 0) '${offline.failed} not sent — open to fix',
          ];
          final bad = offline.failed > 0;
          return Material(
            color: bad ? context.tk.bgError : context.tk.bgWarning,
            child: InkWell(
              onTap: onOpen,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                child: Row(children: [
                  Icon(offline.online ? LucideIcons.cloudUpload : LucideIcons.cloudOff, size: 15, color: bad ? C.error : C.warning),
                  const SizedBox(width: 8),
                  Expanded(child: Text(parts.join(' · '), style: TextStyle(fontSize: Fs.sm, color: bad ? C.error : C.warning))),
                ]),
              ),
            ),
          );
        },
      );
}

// ---- a full-screen window (web Modal size lg / forms): title, × top right, body, footer ----
class FullPage extends StatelessWidget {
  const FullPage({super.key, required this.title, required this.children, this.footer});
  final String title;
  final List<Widget> children;
  final List<Widget>? footer;
  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    return Scaffold(
      backgroundColor: t.canvas,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: Fs.md, fontWeight: FontWeight.w600)),
        actions: [
          IconButton(tooltip: 'Close', onPressed: () => Navigator.pop(context), icon: const Icon(LucideIcons.x, size: 20)),
        ],
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: children),
      bottomNavigationBar: footer == null || footer!.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                decoration: BoxDecoration(color: t.surface, border: Border(top: BorderSide(color: t.border))),
                child: Wrap(alignment: WrapAlignment.end, spacing: 8, runSpacing: 8, children: footer!),
              ),
            ),
    );
  }
}

/// A section heading inside a window (.modal-section-title)
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});
  final String text;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 6),
        child: Row(children: [
          Expanded(child: Text(text, style: TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w600, color: context.tk.textSecondary))),
          ?trailing,
        ]),
      );
}

/// The colour a palette name stands for (the web paints it with the name as a CSS colour)
Color cssColour(String name) {
  const named = {
    'red': Color(0xFFFF0000), 'blue': Color(0xFF0000FF), 'green': Color(0xFF008000), 'yellow': Color(0xFFFFFF00),
    'black': Color(0xFF000000), 'white': Color(0xFFFFFFFF), 'grey': Color(0xFF808080), 'gray': Color(0xFF808080),
    'brown': Color(0xFFA52A2A), 'orange': Color(0xFFFFA500), 'maroon': Color(0xFF800000), 'pink': Color(0xFFFFC0CB),
    'purple': Color(0xFF800080), 'cream': Color(0xFFFFFDD0), 'beige': Color(0xFFF5F5DC), 'tan': Color(0xFFD2B48C),
    'charcoal': Color(0xFF36454F), 'terracotta': Color(0xFFE2725B), 'gold': Color(0xFFFFD700), 'silver': Color(0xFFC0C0C0),
    'navy': Color(0xFF000080), 'olive': Color(0xFF808000), 'teal': Color(0xFF008080), 'khaki': Color(0xFFF0E68C),
  };
  return named[name.trim().toLowerCase()] ?? const Color(0x00000000);
}

/// A colour dot with its first letter (.pc-dot)
class ColourDot extends StatelessWidget {
  const ColourDot(this.name, {super.key});
  final String name;
  @override
  Widget build(BuildContext context) => Tooltip(
        message: name,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: cssColour(name), shape: BoxShape.circle, border: Border.all(color: context.tk.borderStrong))),
          const SizedBox(width: 2),
          Text(name.isEmpty ? '' : name[0], style: TextStyle(fontSize: Fs.xs, color: context.tk.textMuted)),
        ]),
      );
}
