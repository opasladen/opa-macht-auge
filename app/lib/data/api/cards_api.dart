import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/http_client.dart';
import '../dto/card_dto.dart';
import '../dto/card_summary_dto.dart';

class CardsApi {
  CardsApi(this._dio);
  final Dio _dio;

  Future<CardDto> getCard(String cardId) async {
    final response = await _dio.get<Map<String, dynamic>>('/api/v1/cards/$cardId');
    return CardDto.fromJson(response.data!);
  }

  Future<List<VariantDto>> getCardPrices(String cardId) async {
    final response = await _dio.get<List<dynamic>>('/api/v1/prices/cards/$cardId');
    return response.data!
        .map((e) => VariantDto.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Batch-Lookup fuer TopK-Hydration nach dem On-Device-Index-Match.
  /// Reihenfolge der Antwort entspricht der Reihenfolge der Eingabe-IDs.
  Future<List<CardSummaryDto>> lookup(List<String> cardIds) async {
    if (cardIds.isEmpty) return const [];
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/cards/lookup',
      data: {'card_ids': cardIds},
    );
    final cards = (response.data!['cards'] as List<dynamic>?) ?? const [];
    return cards
        .map((e) => CardSummaryDto.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Freie Karten-Suche fuer Korrektur-Flows. Backend filtert ueber
  /// Name (alle Sprachen), Set-Code und Card-Number case-insensitiv.
  Future<List<CardSummaryDto>> search(String query,
      {String? language, int limit = 20}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/v1/cards/search',
      queryParameters: {
        'q': query,
        if (language != null) 'language': language,
        'limit': limit,
      },
    );
    final cards = (response.data!['cards'] as List<dynamic>?) ?? const [];
    return cards
        .map((e) => CardSummaryDto.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

final cardsApiProvider = Provider<CardsApi>((ref) {
  return CardsApi(ref.watch(dioProvider));
});
