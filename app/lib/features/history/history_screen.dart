import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/api/cards_api.dart';
import '../../data/dto/card_summary_dto.dart';
import '../../data/local/scan_history_entry.dart';
import '../../data/local/scan_history_store.dart';

/// Zeigt den kompletten Scan-Verlauf chronologisch (neueste zuerst).
/// Jeder Eintrag laesst sich:
///   - antippen → Detailseite der Karte
///   - per Stern in die Sammlung uebernehmen
///   - per Swipe loeschen
/// AppBar bietet CSV-Export (Share-Sheet) und "Alles loeschen".
class HistoryScreen extends ConsumerWidget {
  const HistoryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(scanHistoryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Verlauf'),
        actions: [
          IconButton(
            tooltip: 'Als CSV exportieren',
            icon: const Icon(Icons.ios_share),
            onPressed: () => _exportCsv(context, ref),
          ),
          IconButton(
            tooltip: 'Verlauf loeschen',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: () => _confirmClear(context, ref),
          ),
        ],
      ),
      body: history.when(
        data: (entries) {
          if (entries.isEmpty) {
            return const _EmptyState(
              icon: Icons.history,
              title: 'Noch keine Scans',
              message:
                  'Wenn du eine Karte erfolgreich erkennst, landet sie '
                  'automatisch hier.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: entries.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final e = entries[i];
              return _HistoryTile(entry: e);
            },
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, st) => Center(child: Text('Fehler: $err')),
      ),
    );
  }

  Future<void> _exportCsv(BuildContext context, WidgetRef ref) async {
    final entries = ref.read(scanHistoryProvider).valueOrNull ?? const [];
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Kein Verlauf zum Exportieren.')),
      );
      return;
    }
    final csv = exportEntriesToCsv(entries);
    final file = await writeCsvToTemp(csv, filenamePrefix: 'verlauf');
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/csv', name: file.uri.pathSegments.last)],
      subject: 'Opa macht Auge - Verlauf',
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Verlauf loeschen?'),
        content: const Text(
          'Alle Scan-Eintraege werden entfernt. Karten in deiner Sammlung '
          'verschwinden ebenfalls. Diese Aktion ist nicht umkehrbar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Abbrechen'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Loeschen'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(scanHistoryProvider.notifier).clearAll();
    }
  }
}

class _HistoryTile extends ConsumerWidget {
  const _HistoryTile({required this.entry});

  final ScanHistoryEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fmt = DateFormat('dd.MM.yyyy HH:mm');
    return Dismissible(
      key: ValueKey(entry.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red.shade700,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) {
        ref.read(scanHistoryProvider.notifier).remove(entry.id);
      },
      child: ListTile(
        leading: SizedBox(
          width: 44,
          height: 60,
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
        title: Text(
          entry.cardName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '${entry.setCode.toUpperCase()} #${entry.number} '
          '· ${entry.language.toUpperCase()} '
          '· ${(entry.similarity * 100).toStringAsFixed(0)}% '
          '· ${fmt.format(entry.scannedAt)}',
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: entry.inCollection
                  ? 'Aus Sammlung entfernen'
                  : 'In Sammlung uebernehmen',
              icon: Icon(
                entry.inCollection ? Icons.star : Icons.star_border,
                color: entry.inCollection ? Colors.amber : null,
              ),
              onPressed: () {
                ref.read(scanHistoryProvider.notifier).toggleCollection(entry.id);
              },
            ),
            PopupMenuButton<String>(
              tooltip: 'Aktionen',
              icon: const Icon(Icons.more_vert),
              onSelected: (v) {
                if (v == 'correct') {
                  _openCorrectionSheet(context, ref, entry);
                } else if (v == 'delete') {
                  ref.read(scanHistoryProvider.notifier).remove(entry.id);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem<String>(
                  value: 'correct',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.edit_outlined),
                    title: Text('Korrigieren'),
                  ),
                ),
                PopupMenuItem<String>(
                  value: 'delete',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.delete_outline),
                    title: Text('Loeschen'),
                  ),
                ),
              ],
            ),
          ],
        ),
        onTap: () => context.push('/card/${entry.cardId}'),
      ),
    );
  }

  Future<void> _openCorrectionSheet(
    BuildContext context,
    WidgetRef ref,
    ScanHistoryEntry entry,
  ) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CorrectionSheet(entry: entry),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey.shade500),
            const SizedBox(height: 16),
            Text(title,
                style: Theme.of(context).textTheme.titleMedium,
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(message,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Korrigiert eine falsch erkannte Karte. Tippeingabe -> Backend-Suche
/// (debounced 300 ms) -> Liste von Treffern. Tap ersetzt cardId + Meta
/// des Verlaufseintrags atomar; scannedAt/inCollection bleiben erhalten.
class _CorrectionSheet extends ConsumerStatefulWidget {
  const _CorrectionSheet({required this.entry});

  final ScanHistoryEntry entry;

  @override
  ConsumerState<_CorrectionSheet> createState() => _CorrectionSheetState();
}

class _CorrectionSheetState extends ConsumerState<_CorrectionSheet> {
  final _controller = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  String? _error;
  List<CardSummaryDto> _results = const [];

  @override
  void initState() {
    super.initState();
    // Vorbelegung mit aktuellem Karten-Namen, damit der User direkt
    // sehen kann was gerade falsch im Verlauf steht.
    _controller.text = widget.entry.cardName.trim();
    _runSearch(_controller.text);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      _runSearch(value);
    });
  }

  Future<void> _runSearch(String value) async {
    final q = value.trim();
    if (q.length < 2) {
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(cardsApiProvider);
      final hits = await api.search(q, limit: 30);
      if (!mounted) return;
      setState(() {
        _results = hits;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Fehler: $e';
        _loading = false;
      });
    }
  }

  Future<void> _pick(CardSummaryDto summary) async {
    await ref.read(scanHistoryProvider.notifier).replaceCard(
          entryId: widget.entry.id,
          cardId: summary.cardId,
          cardName: summary.name,
          setCode: summary.setCode,
          number: summary.number,
          language: summary.setLanguage,
          rarity: summary.rarity,
          imageUrl: summary.imageUrlSmall,
          cardmarketMetacardId: summary.cardmarketMetacardId,
          cardmarketProductId: summary.cardmarketProductId,
          cardmarketExpansionId: summary.cardmarketExpansionId,
        );
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Verlauf korrigiert: ${summary.name}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      builder: (_, scrollCtrl) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Karte korrigieren',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(
                'Aktuell: ${widget.entry.cardName} '
                '(${widget.entry.setCode.toUpperCase()} #${widget.entry.number})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                autofocus: true,
                onChanged: _onChanged,
                onSubmitted: _runSearch,
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search),
                  hintText: 'Name, Set-Code oder Number...',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _buildBody(scrollCtrl),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody(ScrollController scrollCtrl) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(child: Text(_error!));
    }
    if (_results.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'Tippe mindestens 2 Zeichen ein um Karten zu suchen.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    return ListView.separated(
      controller: scrollCtrl,
      itemCount: _results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final s = _results[i];
        return ListTile(
          leading: SizedBox(
            width: 44,
            height: 60,
            child: s.imageUrlSmall == null
                ? const ColoredBox(color: Colors.black12)
                : CachedNetworkImage(
                    imageUrl: s.imageUrlSmall!,
                    fit: BoxFit.cover,
                    placeholder: (_, __) =>
                        const ColoredBox(color: Colors.black12),
                    errorWidget: (_, __, ___) =>
                        const Icon(Icons.broken_image_outlined),
                  ),
          ),
          title: Text(s.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${s.setCode.toUpperCase()} #${s.number} '
            '· ${s.setLanguage.toUpperCase()}'
            '${s.rarity != null ? ' · ${s.rarity}' : ''}',
          ),
          onTap: () => _pick(s),
        );
      },
    );
  }
}
