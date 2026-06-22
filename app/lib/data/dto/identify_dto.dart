/// DTOs fuer /api/v1/identify.
///
/// Bewusst ohne json_serializable, damit build_runner nicht zwingend
/// vor dem ersten Run laufen muss.
class IdentifyRequest {
  IdentifyRequest({
    required this.embedding,
    required this.modelVersion,
    this.topK = 5,
    this.gameSlug = 'pokemon',
    this.clientVersion,
  });

  final List<double> embedding;
  final String modelVersion;
  final int topK;
  final String gameSlug;
  final String? clientVersion;

  Map<String, dynamic> toJson() => {
        'embedding': embedding,
        'model_version': modelVersion,
        'top_k': topK,
        'game_slug': gameSlug,
        if (clientVersion != null) 'client_version': clientVersion,
      };
}

class IdentifyMatch {
  IdentifyMatch({
    required this.cardId,
    required this.similarity,
    required this.name,
    required this.setCode,
    required this.language,
    required this.number,
    this.rarity,
    this.imageUrl,
    this.cardmarketMetacardId,
    this.cardmarketProductId,
    this.cardmarketExpansionId,
  });

  final String cardId;
  final double similarity;
  final String name;
  final String setCode;
  final String language;
  final String number;
  final String? rarity;
  final String? imageUrl;
  final int? cardmarketMetacardId;
  final int? cardmarketProductId;
  final int? cardmarketExpansionId;

  factory IdentifyMatch.fromJson(Map<String, dynamic> json) => IdentifyMatch(
        cardId: json['card_id'] as String,
        similarity: (json['similarity'] as num).toDouble(),
        name: json['name'] as String,
        setCode: json['set_code'] as String,
        language: json['language'] as String,
        number: json['number'] as String,
        rarity: json['rarity'] as String?,
        imageUrl: json['image_url'] as String?,
        cardmarketMetacardId: (json['cardmarket_metacard_id'] as num?)?.toInt(),
        cardmarketProductId: (json['cardmarket_product_id'] as num?)?.toInt(),
        cardmarketExpansionId:
            (json['cardmarket_expansion_id'] as num?)?.toInt(),
      );
}

class IdentifyResponse {
  IdentifyResponse({required this.matches, required this.modelVersion});

  final List<IdentifyMatch> matches;
  final String modelVersion;

  factory IdentifyResponse.fromJson(Map<String, dynamic> json) =>
      IdentifyResponse(
        matches: (json['matches'] as List<dynamic>)
            .map((e) => IdentifyMatch.fromJson(e as Map<String, dynamic>))
            .toList(),
        modelVersion: json['model_version'] as String,
      );
}

/// Deterministischer Lookup ueber die auf der Karte aufgedruckten Felder.
class IdentifyByCodeRequest {
  IdentifyByCodeRequest({
    required this.number,
    this.language,
    this.setCode,
    this.printedTotal,
    this.gameSlug = 'pokemon',
  });

  final String number;
  final String? language;
  final String? setCode;
  final int? printedTotal;
  final String gameSlug;

  Map<String, dynamic> toJson() => {
        'number': number,
        if (language != null) 'language': language,
        if (setCode != null) 'set_code': setCode,
        if (printedTotal != null) 'printed_total': printedTotal,
        'game_slug': gameSlug,
      };
}
