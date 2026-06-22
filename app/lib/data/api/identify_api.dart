import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/http_client.dart';
import '../dto/identify_dto.dart';

class IdentifyApi {
  IdentifyApi(this._dio);
  final Dio _dio;

  Future<IdentifyResponse> identify(IdentifyRequest request) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/identify',
      data: request.toJson(),
    );
    return IdentifyResponse.fromJson(response.data!);
  }

  Future<IdentifyResponse> identifyByCode(IdentifyByCodeRequest request) async {
    final response = await _dio.post<Map<String, dynamic>>(
      '/api/v1/identify-by-code',
      data: request.toJson(),
    );
    return IdentifyResponse.fromJson(response.data!);
  }
}

final identifyApiProvider = Provider<IdentifyApi>((ref) {
  return IdentifyApi(ref.watch(dioProvider));
});
