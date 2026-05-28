import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/card_repository.dart';
import '../db/recents_store.dart';
import 'results_screen.dart';

/// Lists cards scanned within the last 24 hours.
class RecentsScreen extends StatefulWidget {
  const RecentsScreen({super.key});

  @override
  State<RecentsScreen> createState() => _RecentsScreenState();
}

class _RecentsScreenState extends State<RecentsScreen> {
  late Future<List<RecentScan>> _future;

  @override
  void initState() {
    super.initState();
    _future = context.read<RecentsStore>().list();
  }

  void _refresh() {
    setState(() => _future = context.read<RecentsStore>().list());
  }

  Future<void> _open(RecentScan scan) async {
    final repo = context.read<CardRepository>();
    final card = await repo.cardById(scan.cardId);
    if (card == null || !mounted) return;
    final print = card.prints.firstWhere(
      (p) => p.faceId == scan.faceId,
      orElse: () => card.canonicalPrint ?? card.prints.first,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ResultsScreen(card: card, initialPrint: print),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Recently scanned'),
        actions: [
          IconButton(
            tooltip: 'Clear',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await context.read<RecentsStore>().clear();
              _refresh();
            },
          ),
        ],
      ),
      body: FutureBuilder<List<RecentScan>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final scans = snapshot.data ?? const <RecentScan>[];
          if (scans.isEmpty) {
            return const Center(child: Text('Nothing scanned in the last 24h.'));
          }
          return ListView.separated(
            itemCount: scans.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final s = scans[i];
              return ListTile(
                leading: SizedBox(
                  width: 40,
                  height: 56,
                  child: s.imageUrl == null
                      ? const Icon(Icons.style)
                      : Image.network(s.imageUrl!, fit: BoxFit.cover,
                          errorBuilder: (c, e, st) => const Icon(Icons.style)),
                ),
                title: Text(s.name),
                subtitle: Text([
                  if (s.setCode != null) s.setCode!,
                  if (s.pitch != null) 'Pitch ${s.pitch}',
                  _ago(s.scannedAt),
                ].join(' · ')),
                onTap: () => _open(s),
              );
            },
          );
        },
      ),
    );
  }

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    return '${d.inHours}h ago';
  }
}
