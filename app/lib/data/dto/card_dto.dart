/// DTOs fuer /api/v1/cards und /api/v1/prices.
library;

import 'package:intl/intl.dart';

class PriceDto {
  PriceDto({
    required this.source,
    required this.condition,
    required this.priceEur,
    this.trend7dEur,
    required this.fetchedAt,
  });

  final String source;
  final String condition;
  final double priceEur;
  final double? trend7dEur;
  final DateTime fetchedAt;

  factory PriceDto.fromJson(Map<String, dynamic> json) => PriceDto(
        source: json['source'] as String,
        condition: json['condition'] as String,
        priceEur: _toDouble(json['price_eur']),
        trend7dEur:
            json['trend_7d_eur'] == null ? null : _toDouble(json['trend_7d_eur']),
        fetchedAt: DateTime.parse(json['fetched_at'] as String),
      );

  String get priceFormatted =>
      NumberFormat.currency(locale: 'de_DE', symbol: '€').format(priceEur);
}

class VariantDto {
  VariantDto({
    required this.variantId,
    required this.language,
    required this.edition,
    required this.finish,
    required this.prices,
  });

  final String variantId;
  final String language;
  final String edition;
  final String finish;
  final List<PriceDto> prices;

  factory VariantDto.fromJson(Map<String, dynamic> json) => VariantDto(
        variantId: json['variant_id'] as String,
        language: json['language'] as String,
        edition: json['edition'] as String,
        finish: json['finish'] as String,
        prices: (json['prices'] as List<dynamic>? ?? [])
            .map((e) => PriceDto.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}

class CardDto {
  CardDto({
    required this.cardId,
    required this.setCode,
    required this.setName,
    required this.setLanguage,
    required this.number,
    required this.nameLocalized,
    this.rarity,
    this.cardType,
    this.imageUrlSmall,
    this.imageUrlLarge,
    required this.variants,
    this.cardmarketMetacardId,
    this.cardmarketProductId,
    this.cardmarketExpansionId,
  });

  final String cardId;
  final String setCode;
  final String setName;
  final String setLanguage;
  final String number;
  final Map<String, String> nameLocalized;
  final String? rarity;
  final String? cardType;
  final String? imageUrlSmall;
  final String? imageUrlLarge;
  final List<VariantDto> variants;
  final int? cardmarketMetacardId;
  final int? cardmarketProductId;
  final int? cardmarketExpansionId;

  String get displayName =>
      nameLocalized[setLanguage] ??
      nameLocalized['de'] ??
      nameLocalized['en'] ??
      nameLocalized.values.first;

  factory CardDto.fromJson(Map<String, dynamic> json) => CardDto(
        cardId: json['card_id'] as String,
        setCode: json['set_code'] as String,
        setName: json['set_name'] as String,
        setLanguage: json['set_language'] as String,
        number: json['number'] as String,
        nameLocalized: (json['name_localized'] as Map<String, dynamic>? ?? {})
            .map((k, v) => MapEntry(k, v as String)),
        rarity: json['rarity'] as String?,
        cardType: json['card_type'] as String?,
        imageUrlSmall: json['image_url_small'] as String?,
        imageUrlLarge: json['image_url_large'] as String?,
        variants: (json['variants'] as List<dynamic>? ?? [])
            .map((e) => VariantDto.fromJson(e as Map<String, dynamic>))
            .toList(),
        cardmarketMetacardId: (json['cardmarket_metacard_id'] as num?)?.toInt(),
        cardmarketProductId: (json['cardmarket_product_id'] as num?)?.toInt(),
        cardmarketExpansionId:
            (json['cardmarket_expansion_id'] as num?)?.toInt(),
      );
}

double _toDouble(dynamic v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.parse(v);
  throw ArgumentError('cannot convert $v to double');
}
