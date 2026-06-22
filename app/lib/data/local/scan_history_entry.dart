/// Ein Eintrag im Scan-Verlauf: was wurde wann erkannt und ist die Karte
/// bereits Teil der persoenlichen Sammlung.
///
/// Die [id] ist ein lokaler Identifier (Millisekunden seit Epoch + cardId)
/// damit der gleiche cardId mehrfach gescannt werden kann ohne dass die
/// Liste in den Konflikt geraet.
class ScanHistoryEntry {
  ScanHistoryEntry({
    required this.id,
    required this.cardId,
    required this.cardName,
    required this.setCode,
    this.setName,
    required this.number,
    required this.language,
    this.rarity,
    this.imageUrl,
    required this.scannedAt,
    required this.similarity,
    this.inCollection = false,
    this.cardmarketMetacardId,
    this.cardmarketProductId,
    this.cardmarketExpansionId,
  });

  final String id;
  final String cardId;
  final String cardName;
  final String setCode;
  final String? setName;
  final String number;
  final String language;
  final String? rarity;
  final String? imageUrl;
  final DateTime scannedAt;
  final double similarity;
  final bool inCollection;
  final int? cardmarketMetacardId;
  final int? cardmarketProductId;
  final int? cardmarketExpansionId;

  ScanHistoryEntry copyWith({
    bool? inCollection,
  }) {
    return ScanHistoryEntry(
      id: id,
      cardId: cardId,
      cardName: cardName,
      setCode: setCode,
      setName: setName,
      number: number,
      language: language,
      rarity: rarity,
      imageUrl: imageUrl,
      scannedAt: scannedAt,
      similarity: similarity,
      inCollection: inCollection ?? this.inCollection,
      cardmarketMetacardId: cardmarketMetacardId,
      cardmarketProductId: cardmarketProductId,
      cardmarketExpansionId: cardmarketExpansionId,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'cardId': cardId,
        'cardName': cardName,
        'setCode': setCode,
        'setName': setName,
        'number': number,
        'language': language,
        'rarity': rarity,
        'imageUrl': imageUrl,
        'scannedAt': scannedAt.toUtc().toIso8601String(),
        'similarity': similarity,
        'inCollection': inCollection,
        'cardmarketMetacardId': cardmarketMetacardId,
        'cardmarketProductId': cardmarketProductId,
        'cardmarketExpansionId': cardmarketExpansionId,
      };

  factory ScanHistoryEntry.fromJson(Map<String, dynamic> json) {
    return ScanHistoryEntry(
      id: json['id'] as String,
      cardId: json['cardId'] as String,
      cardName: json['cardName'] as String,
      setCode: json['setCode'] as String,
      setName: json['setName'] as String?,
      number: json['number'] as String,
      language: json['language'] as String,
      rarity: json['rarity'] as String?,
      imageUrl: json['imageUrl'] as String?,
      scannedAt: DateTime.parse(json['scannedAt'] as String).toLocal(),
      similarity: (json['similarity'] as num).toDouble(),
      inCollection: (json['inCollection'] as bool?) ?? false,
      cardmarketMetacardId:
          (json['cardmarketMetacardId'] as num?)?.toInt(),
      cardmarketProductId: (json['cardmarketProductId'] as num?)?.toInt(),
      cardmarketExpansionId:
          (json['cardmarketExpansionId'] as num?)?.toInt(),
    );
  }
}
