import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';
import 'products.dart' show EntityFlags, EntityHistory;

/*
 * Colours — a port of web pages/Colours.jsx (approved 2026-11-24): the organization's colour
 * palette; categories, recipes and prices reference these colours. A row a colour (order, used
 * by, status); editing opens a full-screen form.
 */
class ColoursPage extends StatefulWidget {
  const ColoursPage({super.key});
  @override
  State<ColoursPage> createState() => _ColoursPageState();
}

class _ColoursPageState extends State<ColoursPage> {
  List<Json>? _colours;
  DateTime? _savedAt;
  String _error = '';
  bool get canWrite => session.canManage('products.manage');

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _error = '');
    try {
      final (data, at) = await offline.load<List>('colours', () async =>
          await db.from('color_palette').select('id, name, display_order, is_active, categories:product_category_colors(count)').order('display_order', ascending: true).order('name', ascending: true));
      if (mounted) setState(() { _colours = [for (final x in data) Map<String, dynamic>.from(x as Map)]; _savedAt = at; });
    } catch (_) {
      if (mounted) setState(() => _error = "We couldn't load this page. Please try again.");
    }
  }

  Future<void> _edit(Json c) async {
    final next = _colours!.fold<num>(0, (m, x) => n(x['display_order']) > m ? n(x['display_order']) : m).toInt() + 1;
    final saved = await Navigator.push<bool>(context, MaterialPageRoute(fullscreenDialog: true, builder: (_) => _ColourForm(colour: c, nextOrder: next)));
    if (saved == true) _load();
  }

  static int _uses(Json c) => n(((c['categories'] as List?)?.firstOrNull as Map?)?['count']).toInt();

  @override
  Widget build(BuildContext context) {
    final t = context.tk;
    final list = _colours;
    if (_error.isNotEmpty && list == null) return ListView(padding: const EdgeInsets.all(14), children: [ErrorState(_error, onRetry: _load)]);
    if (list == null) return ListView(padding: const EdgeInsets.all(14), children: const [Skeleton(rows: 5)]);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: !canWrite
          ? null
          : FloatingActionButton(
              tooltip: 'New colour',
              backgroundColor: t.dark ? C.khaki : C.charcoal,
              foregroundColor: t.dark ? C.charcoal : Colors.white,
              onPressed: () => _edit({}),
              child: const Icon(LucideIcons.plus),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: PageList(padding: const EdgeInsets.fromLTRB(14, 0, 14, 88), children: [
          OfflineNote(_savedAt),
          if (list.isEmpty)
            const EmptyState(icon: LucideIcons.palette, title: 'No colours yet', description: 'Add the colours your products come in.')
          else
            for (final c in list)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Material(
                  color: t.surface,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: t.border)),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    onTap: canWrite ? () => _edit(c) : null,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                      child: Row(children: [
                        Container(width: 16, height: 16, decoration: BoxDecoration(color: cssColour('${c['name']}'), shape: BoxShape.circle, border: Border.all(color: t.borderStrong))),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: Fs.md)),
                            Text('Order ${c['display_order']} · used by ${_uses(c)} categor${_uses(c) == 1 ? 'y' : 'ies'}', style: TextStyle(fontSize: Fs.sm, color: t.textMuted)),
                          ]),
                        ),
                        Badge2(c['is_active'] == true ? 'active' : 'inactive', tone: c['is_active'] == true ? Tone.success : Tone.neutral),
                        if (canWrite) ...[const SizedBox(width: 8), Icon(LucideIcons.pencil, size: 16, color: t.textSecondary)],
                      ]),
                    ),
                  ),
                ),
              ),
        ]),
      ),
    );
  }
}

class _ColourForm extends StatefulWidget {
  const _ColourForm({required this.colour, required this.nextOrder});
  final Json colour;
  final int nextOrder;
  @override
  State<_ColourForm> createState() => _ColourFormState();
}

class _ColourFormState extends State<_ColourForm> {
  Json get c => widget.colour;
  bool get isNew => c['id'] == null;
  late final _name = TextEditingController(text: '${c['name'] ?? ''}');
  late final _order = TextEditingController(text: '${c['display_order'] ?? widget.nextOrder}');
  bool _busy = false;
  String _error = '';

  Future<void> _run(Future<void> Function() f) async {
    setState(() { _error = ''; _busy = true; });
    try {
      await f();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      setState(() { _busy = false; _error = dbError(e); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final inUse = _ColoursPageState._uses(c);
    final row = {'name': _name.text.trim(), 'display_order': int.tryParse(_order.text.trim()) ?? 0};
    return FullPage(
      title: isNew ? 'Add colour' : 'Edit ${c['name']}',
      footer: [
        OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy || _name.text.trim().isEmpty
              ? null
              : () => _run(() async => isNew
                  ? await db.from('color_palette').insert({...row, 'organization_id': session.organization!['id']})
                  : await db.from('color_palette').update(row).eq('id', c['id'])),
          child: const Text('Save'),
        ),
      ],
      children: [
        if (_error.isNotEmpty) Alert(_error, tone: Tone.error),
        Row(children: [
          Expanded(flex: 2, child: TextField(controller: _name, autofocus: isNew, textCapitalization: TextCapitalization.words, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Name'))),
          const SizedBox(width: 8),
          Expanded(child: TextField(controller: _order, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Display order'))),
        ]),
        if (!isNew) ...[
          const SectionTitle('Status'),
          PlHelp(c['is_active'] == true
              ? 'Deactivating hides it when choosing colours.${inUse > 0 ? ' It stays on the $inUse categor${inUse == 1 ? 'y' : 'ies'} already using it.' : ''}'
              : 'Inactive — not offered when choosing colours.'),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton(
              onPressed: _busy ? null : () => _run(() async => await db.from('color_palette').update({'is_active': c['is_active'] != true}).eq('id', c['id'])),
              child: Text(c['is_active'] == true ? 'Deactivate colour' : 'Reactivate colour'),
            ),
          ),
          EntityFlags(entityType: 'color', entityId: '${c['id']}', canResolve: true),
          EntityHistory(entityType: 'color', entityId: '${c['id']}'),
        ],
      ],
    );
  }
}
