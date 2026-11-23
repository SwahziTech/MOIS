import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/format.dart';
import '../core/offline.dart';
import '../core/session.dart';
import '../core/theme.dart';
import '../core/ui.dart';

/*
 * Waiting to send (offline): what was recorded on this phone without a connection, oldest
 * first. Waiting ones go by themselves when online; one the server refused shows its reason —
 * try again (after fixing what it says on the web or here) or remove it.
 */
class OutboxPage extends StatefulWidget {
  const OutboxPage({super.key});
  @override
  State<OutboxPage> createState() => _OutboxPageState();
}

class _OutboxPageState extends State<OutboxPage> {
  List<Json>? _jobs;

  @override
  void initState() {
    super.initState();
    offline.addListener(_load);
    _load();
  }

  @override
  void dispose() { offline.removeListener(_load); super.dispose(); }

  Future<void> _load() async {
    final j = await offline.jobs();
    if (mounted) setState(() => _jobs = j);
  }

  @override
  Widget build(BuildContext context) {
    final jobs = _jobs;
    return RefreshIndicator(
      onRefresh: () async { await offline.sync(); await _load(); },
      child: ListView(padding: const EdgeInsets.fromLTRB(14, 0, 14, 24), children: [
        Stats([
          Stat('Waiting', '${offline.waiting}', help: offline.online ? 'sending…' : 'sent when online'),
          Stat('Not sent', '${offline.failed}', figureColor: offline.failed > 0 ? C.error : null, help: 'refused by the server'),
        ]),
        if (jobs == null) const Skeleton(rows: 3)
        else if (jobs.isEmpty) const EmptyState(icon: LucideIcons.cloudCheck, title: 'Nothing waiting', description: 'Everything recorded on this phone has been sent.')
        else
          for (final j in jobs)
            CardBox(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text('${j['label']}', style: const TextStyle(fontWeight: FontWeight.w600))),
                  Badge2(j['status'] == 'failed' ? 'Not sent' : 'Waiting', tone: j['status'] == 'failed' ? Tone.error : Tone.warning),
                ]),
                PlHelp('${session.branchNameOf(j['branch_id'])} · recorded ${tableDateTime(j['created_at'])}'),
                if (j['error'] != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('${j['error']}', style: const TextStyle(color: C.error, fontSize: Fs.sm))),
                if (j['status'] == 'failed')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(children: [
                      OutlinedButton(onPressed: () => offline.retry(j['id']), child: const Text('Try again')),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () async {
                          final ok = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
                            title: const Text('Remove it?'),
                            content: const Text('It was not saved in MOIS. Removing it here means it is not sent.'),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
                              FilledButton(style: FilledButton.styleFrom(backgroundColor: C.error), onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                            ],
                          ));
                          if (ok == true) offline.remove(j['id']);
                        },
                        child: const Text('Remove', style: TextStyle(color: C.error)),
                      ),
                    ]),
                  ),
              ]),
            ),
      ]),
    );
  }
}
