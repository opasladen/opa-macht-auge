// app/lib/data/dto/card_summary_dto.dart
/// Kompakte Karten-Metadaten fuer TopK-Hydration nach lokalem Index-Match.
/// Entspricht dem ``CardSummary``-Schema im Backend (``cards.py``).
library;

class CardSummaryDto {
  const CardSummaryDto({
    required this.cardId,
    required this.name,
    required this.setCode,
    required this.setLanguage,
    required this.number,
    this.rarity,
    this.imageUrlSmall,
    this.cardmarketMetacardId,
    this.cardmarketProductId,
    this.cardmarketExpansionId,
  });

  final String cardId;
  final String name;
  final String setCode;
  final String setLanguage;
  final String number;
  final String? rarity;
  final String? imageUrlSmall;
  final int? cardmarketMetacardId;
  final int? cardmarketProductId;
  final int? cardmarketExpansionId;

  factory CardSummaryDto.fromJson(Map<String, dynamic> json) => CardSummaryDto(
        cardId: json['card_id'] as String,
        name: json['name'] as String? ?? '',
        setCode: json['set_code'] as String? ?? '',
        setLanguage: json['set_language'] as String? ?? '',
        number: json['number'] as String? ?? '',
        rarity: json['rarity'] as String?,
        imageUrlSmall: json['image_url_small'] as String?,
        cardmarketMetacardId: (json['cardmarket_metacard_id'] as num?)?.toInt(),
        cardmarketProductId: (json['cardmarket_product_id'] as num?)?.toInt(),
        cardmarketExpansionId:
            (json['cardmarket_expansion_id'] as num?)?.toInt(),
      );
}
