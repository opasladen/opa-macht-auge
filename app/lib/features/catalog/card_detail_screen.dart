/// Karten-Detail mit Preisen pro Variante.
library;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/api/cards_api.dart';
import '../../data/dto/card_dto.dart';
import '../../data/local/scan_history_store.dart';

final cardDetailProvider =
    FutureProvider.family<CardDto, String>((ref, cardId) async {
  final api = ref.watch(cardsApiProvider);
  return api.getCard(cardId);
});

class CardDetailScreen extends ConsumerWidget {
  const CardDetailScreen({super.key, required this.cardId});

  final String cardId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(cardDetailProvider(cardId));
    final history = ref.watch(scanHistoryProvider);
    // In-Sammlung-Status: irgendein Verlaufseintrag fuer diese cardId
    // hat inCollection=true.
    final inCollection = history.valueOrNull
            ?.any((e) => e.cardId == cardId && e.inCollection) ??
        false;

    return Scaffold(
      appBar: AppBar(title: const Text('Karte')),
      body: detail.when(
        data: (c) => _CardDetailBody(card: c),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Fehler: $e')),
      ),
      floatingActionButton: detail.maybeWhen(
        data: (c) => FloatingActionButton.extended(
          backgroundColor: inCollection ? Colors.green.shade700 : null,
          icon: Icon(inCollection
              ? Icons.bookmark_added
              : Icons.bookmark_add_outlined),
          label: Text(inCollection
              ? 'In Sammlung'
              : 'Zur Sammlung hinzufuegen'),
          onPressed: () async {
            final added = await ref
                .read(scanHistoryProvider.notifier)
                .setInCollectionForCard(
                  cardId: c.cardId,
                  value: !inCollection,
                  cardName: c.displayName,
                  setCode: c.setCode,
                  number: c.number,
                  language: c.setLanguage,
                  rarity: c.rarity,
                  imageUrl: c.imageUrlSmall ?? c.imageUrlLarge,
                  cardmarketMetacardId: c.cardmarketMetacardId,
                  cardmarketProductId: c.cardmarketProductId,
                  cardmarketExpansionId: c.cardmarketExpansionId,
                );
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(added
                    ? 'Karte zur Sammlung hinzugefuegt.'
                    : 'Karte aus Sammlung entfernt.'),
                duration: const Duration(seconds: 2),
              ),
            );
          },
        ),
        orElse: () => null,
      ),
    );
  }
}

class _CardDetailBody extends StatelessWidget {
  const _CardDetailBody({required this.card});
  final CardDto card;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (card.imageUrlLarge != null || card.imageUrlSmall != null)
          AspectRatio(
            aspectRatio: 245 / 337,
            child: CachedNetworkImage(
              imageUrl: card.imageUrlLarge ?? card.imageUrlSmall!,
              fit: BoxFit.contain,
            ),
          ),
        const SizedBox(height: 12),
        Text(card.displayName, style: theme.textTheme.headlineSmall),
        Text(
          '${card.setName} (${card.setCode}) · #${card.number} · ${card.setLanguage.toUpperCase()}'
          '${card.rarity != null ? ' · ${card.rarity}' : ''}',
          style: theme.textTheme.bodyMedium,
        ),
        const SizedBox(height: 24),
        Text('Varianten & Preise', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        if (card.variants.isEmpty)
          const Text('Keine Variants/Preise in der DB.')
        else
          ...card.variants.map((v) => _VariantTile(variant: v)),
      ],
    );
  }
}

class _VariantTile extends StatelessWidget {
  const _VariantTile({required this.variant});
  final VariantDto variant;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('dd.MM.yyyy');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${variant.language.toUpperCase()} · ${variant.finish} · ${variant.edition}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 8),
            if (variant.prices.isEmpty)
              const Text('Keine Preise erfasst.')
            else
              ...variant.prices.map(
                (p) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '${p.source} (${p.condition}) – ${fmt.format(p.fetchedAt.toLocal())}',
                        ),
                      ),
                      Text(
                        p.priceFormatted,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
