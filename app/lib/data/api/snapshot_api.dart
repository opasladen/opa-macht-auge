// app/lib/data/api/snapshot_api.dart
/// Embedding-Snapshot-Download fuer den lokalen Index.
///
/// Holt das Binaer-Blob von ``GET /api/v1/embeddings/snapshot`` und nutzt
/// ``If-None-Match`` fuer Delta-Updates (304 spart den ~16 MB Download).
library;

import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/http_client.dart';

class SnapshotPayload {
  const SnapshotPayload({
    required this.body,
    required this.etag,
    required this.modelVersion,
    required this.count,
    required this.dim,
    required this.updatedAt,
  });

  final Uint8List body;
  final String etag;
  final String modelVersion;
  final int count;
  final int dim;
  final String updatedAt;
}

class SnapshotMeta {
  const SnapshotMeta({
    required this.etag,
    required this.modelVersion,
    required this.count,
    required this.dim,
    required this.updatedAt,
  });

  final String etag;
  final String modelVersion;
  final int count;
  final int dim;
  final String updatedAt;
}

class SnapshotApi {
  SnapshotApi(this._dio);
  final Dio _dio;

  /// Returns `null` bei HTTP 304 – der Client hat bereits den aktuellen Stand.
  Future<SnapshotPayload?> fetchSnapshot({
    required String gameSlug,
    String? ifNoneMatch,
  }) async {
    final response = await _dio.get<List<int>>(
      '/api/v1/embeddings/snapshot',
      queryParameters: {'game_slug': gameSlug},
      options: Options(
        responseType: ResponseType.bytes,
        headers: ifNoneMatch != null && ifNoneMatch.isNotEmpty
            ? {'If-None-Match': '"$ifNoneMatch"'}
            : null,
        validateStatus: (status) =>
            status != null && (status == 200 || status == 304),
        receiveTimeout: const Duration(minutes: 5),
      ),
    );
    if (response.statusCode == 304) return null;
    final headers = response.headers;
    final etag = _stripEtag(headers.value('etag'));
    return SnapshotPayload(
      body: Uint8List.fromList(response.data!),
      etag: etag,
      modelVersion: headers.value('x-model-version') ?? '',
      count: int.tryParse(headers.value('x-snapshot-count') ?? '0') ?? 0,
      dim: int.tryParse(headers.value('x-snapshot-dim') ?? '0') ?? 0,
      updatedAt: headers.value('x-snapshot-updated-at') ?? '',
    );
  }

  Future<SnapshotMeta?> fetchMeta({required String gameSlug}) async {
    final response = await _dio.get<Map<String, dynamic>>(
      '/api/v1/embeddings/snapshot/meta',
      queryParameters: {'game_slug': gameSlug},
    );
    final data = response.data;
    if (data == null || data['etag'] == null) return null;
    return SnapshotMeta(
      etag: data['etag'] as String,
      modelVersion: data['model_version'] as String? ?? '',
      count: (data['count'] as num?)?.toInt() ?? 0,
      dim: (data['dim'] as num?)?.toInt() ?? 0,
      updatedAt: data['updated_at'] as String? ?? '',
    );
  }
}

String _stripEtag(String? raw) {
  if (raw == null) return '';
  var v = raw.trim();
  if (v.startsWith('W/')) v = v.substring(2);
  if (v.startsWith('"') && v.endsWith('"') && v.length >= 2) {
    v = v.substring(1, v.length - 1);
  }
  return v;
}

final snapshotApiProvider = Provider<SnapshotApi>((ref) {
  return SnapshotApi(ref.watch(dioProvider));
});
