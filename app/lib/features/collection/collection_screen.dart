import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/local/scan_history_entry.dart';
import '../../data/local/scan_history_store.dart';

/// Meine Sammlung = alle Verlaufs-Eintraege mit `inCollection == true`.
/// Dedupliziert pro cardId (mehrere Scans derselben Karte zaehlen als ein
/// Sammlungs-Stueck). Grid-Ansicht mit Karten-Cover.
class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(scanHistoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Meine Sammlung'),
        actions: [
          IconButton(
            tooltip: 'Sammlung als CSV exportieren',
            icon: const Icon(Icons.ios_share),
            onPressed: () => _exportCsv(context, ref),
          ),
        ],
      ),
      body: history.when(
        data: (entries) {
          final unique = _uniqueCollection(entries);
          if (unique.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.collections_bookmark_outlined,
                        size: 48, color: Colors.grey.shade500),
                    const SizedBox(height: 16),
                    Text('Noch keine Karten in deiner Sammlung',
                        style: Theme.of(context).textTheme.titleMedium,
                        textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    const Text(
                      'Markiere im Verlauf eine Karte mit dem Stern, um '
                      'sie hier abzulegen.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 245 / 380, // Karte + Label
            ),
            itemCount: unique.length,
            itemBuilder: (context, i) {
              final e = unique[i];
              return _CollectionCard(entry: e);
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, st) => Center(child: Text('Fehler: $err')),
      ),
    );
  }

  /// Pro cardId nur den juengsten Eintrag behalten.
  List<ScanHistoryEntry> _uniqueCollection(List<ScanHistoryEntry> all) {
    final seen = <String>{};
    final out = <ScanHistoryEntry>[];
    for (final e in all) {
      if (!e.inCollection) continue;
      if (seen.add(e.cardId)) out.add(e);
    }
    return out;
  }

  Future<void> _exportCsv(BuildContext context, WidgetRef ref) async {
    final all = ref.read(scanHistoryProvider).valueOrNull ?? const [];
    final unique = _uniqueCollection(all);
    if (unique.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sammlung ist leer.')),
      );
      return;
    }
    final csv = exportEntriesToCsv(unique);
    final file = await writeCsvToTemp(csv, filenamePrefix: 'sammlung');
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv', name: file.uri.pathSegments.last)],
      subject: 'Opa macht Auge - Sammlung',
    );
  }
}

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({required this.entry});

  final ScanHistoryEntry entry;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push('/card/${entry.cardId}'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: entry.imageUrl == null
                  ? const ColoredBox(color: Colors.black12)
                  : CachedNetworkImage(
                      imageUrl: entry.imageUrl!,
                      fit: BoxFit.cover,
                      placeholder: (_, __) =>
                          const ColoredBox(color: Colors.black12),
                      errorWidget: (_, __, ___) =>
                          const Icon(Icons.broken_image_outlined),
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            entry.cardName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          Text(
            '${entry.setCode.toUpperCase()} #${entry.number}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Colors.grey.shade600,
                ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
