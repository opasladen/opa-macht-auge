// app/lib/embedder/local_index.dart
/// On-Device-Index ueber alle Karten-Embeddings.
///
/// Laedt einen kompakten Binaer-Snapshot vom Backend (siehe
/// ``backend/app/api/v1/snapshots.py``), speichert ihn lokal und liefert
/// schnelle Cosine-TopK-Suche ohne Netzwerk-Roundtrip pro Frame.
///
/// Format-Garantien:
///   * Embeddings sind L2-normalisiert auf der Index-Seite.
///   * Speicherung INT8 mit per-Vektor-Skala. Dekodiert ergibt sich der
///     Original-Vektor ueber ``v[i,j] = q[i,j] * scales[i]``.
///   * Cosine-Similarity = Dot-Product (beide Seiten L2-normalisiert), die
///     Query-Norm wird zusaetzlich angewendet damit auch nicht ganz exakte
///     ONNX-Outputs robust bleiben.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/api/snapshot_api.dart';

const String _kSnapshotFile = 'embedding_snapshot.bin';
const String _kEtagFile = 'embedding_snapshot.etag';

// Binaer-Format Konstanten (muessen exakt zu backend/app/api/v1/snapshots.py
// passen).
const List<int> _kMagic = [0x4F, 0x4D, 0x41, 0x45]; // "OMAE"
const int _kVersion = 1;
const int _kFlagInt8 = 0x01;
const int _kHeaderBytes = 4 + 4 * 4 + 32 + 32; // 84
const int _kModelVerField = 32;
const int _kGameSlugField = 32;

/// Ein Treffer aus dem lokalen TopK-Lookup.
class LocalIndexMatch {
  const LocalIndexMatch({required this.cardId, required this.similarity});

  /// UUID-String wie vom Backend geliefert (lowercase 8-4-4-4-12).
  final String cardId;

  /// Cosine-Similarity in [-1, 1]; 1.0 = identisch zum Index-Vektor.
  final double similarity;

  @override
  String toString() =>
      'LocalIndexMatch($cardId, ${similarity.toStringAsFixed(4)})';
}

/// Im-Speicher-Repraesentation des Snapshot-Blobs.
///
/// Hält keine Kopie der UUIDs als Strings, sondern berechnet sie lazy aus dem
/// rohen 16-Byte-Slice. Das spart bei 40k Karten ~3 MB String-Heap.
class LocalIndex {
  LocalIndex._({
    required this.modelVersion,
    required this.gameSlug,
    required this.count,
    required this.dim,
    required this.etag,
    required Uint8List rawIds,
    required Float32List scales,
    required Int8List vectors,
  })  : _rawIds = rawIds,
        _scales = scales,
        _vectors = vectors;

  final String modelVersion;
  final String gameSlug;
  final int count;
  final int dim;
  final String etag;

  final Uint8List _rawIds; // length = count * 16
  final Float32List _scales; // length = count
  final Int8List _vectors; // length = count * dim

  /// Liefert die TopK-Treffer absteigend nach Similarity sortiert.
  ///
  /// [query] muss die Modell-Dimension haben und sollte L2-normalisiert sein
  /// (der DINOv2-ONNX-Wrapper macht das bereits, siehe ``export_onnx.py``).
  /// Eine zusaetzliche Normalisierung im Client haerten wir trotzdem ab.
  List<LocalIndexMatch> topK(Float32List query, int k) {
    if (query.length != dim) {
      throw ArgumentError('query.length=${query.length} != dim=$dim');
    }
    if (count == 0) return const [];

    // Query-Norm zusaetzlich anwenden, falls der Embedder leicht abweicht.
    var qNorm = 0.0;
    for (var j = 0; j < dim; j++) {
      qNorm += query[j] * query[j];
    }
    qNorm = math.sqrt(qNorm);
    final qScale = qNorm > 1e-8 ? 1.0 / qNorm : 1.0;

    final sims = Float32List(count);
    final vectors = _vectors;
    final scales = _scales;
    final d = dim;
    final n = count;

    // Skalarer Brute-Force-Loop. Bei 40k * 384 = 15.4M MACs liegt das auf
    // einem 2024er Mobile-CPU bei ~30 ms; das ist deutlich schneller als
    // jeder Netzwerk-Roundtrip.
    for (var i = 0; i < n; i++) {
      final base = i * d;
      var dot = 0.0;
      for (var j = 0; j < d; j++) {
        dot += query[j] * vectors[base + j];
      }
      sims[i] = (dot * scales[i] * qScale).toDouble();
    }

    // Partial-Top-K via Insertion-Sort in einem fixen Buffer. O(N*K), bei
    // K<=10 schneller als ein voller sort() und ohne Heap-Allokation.
    final take = k < n ? k : n;
    final topIdx = List<int>.filled(take, -1);
    final topSim = Float32List(take);
    for (var i = 0; i < take; i++) {
      topSim[i] = double.negativeInfinity;
    }
    var minIdx = 0;
    var minVal = double.negativeInfinity;
    var filled = 0;
    for (var i = 0; i < n; i++) {
      final s = sims[i];
      if (filled < take) {
        topIdx[filled] = i;
        topSim[filled] = s;
        filled++;
        if (filled == take) {
          minVal = topSim[0];
          minIdx = 0;
          for (var t = 1; t < take; t++) {
            if (topSim[t] < minVal) {
              minVal = topSim[t];
              minIdx = t;
            }
          }
        }
        continue;
      }
      if (s > minVal) {
        topIdx[minIdx] = i;
        topSim[minIdx] = s;
        // recompute min
        minVal = topSim[0];
        minIdx = 0;
        for (var t = 1; t < take; t++) {
          if (topSim[t] < minVal) {
            minVal = topSim[t];
            minIdx = t;
          }
        }
      }
    }

    // Result-Liste descending sortieren.
    final pairs = List<MapEntry<int, double>>.generate(
      filled,
      (t) => MapEntry(topIdx[t], topSim[t]),
    );
    pairs.sort((a, b) => b.value.compareTo(a.value));
    return [
      for (final pair in pairs)
        LocalIndexMatch(cardId: _uuidAt(pair.key), similarity: pair.value),
    ];
  }

  String _uuidAt(int i) {
    final off = i * 16;
    final buf = StringBuffer();
    for (var b = 0; b < 16; b++) {
      buf.write(_rawIds[off + b].toRadixString(16).padLeft(2, '0'));
      if (b == 3 || b == 5 || b == 7 || b == 9) buf.write('-');
    }
    return buf.toString();
  }
}

class LocalIndexException implements Exception {
  LocalIndexException(this.message);
  final String message;
  @override
  String toString() => 'LocalIndexException: $message';
}

/// Persistenz + Lifecycle fuer den Local-Index.
class LocalIndexService {
  LocalIndexService(this._ref);

  final Ref _ref;
  LocalIndex? _cached;
  Future<LocalIndex>? _inflight;

  /// Idempotent: gibt den gecachten Index zurueck oder laedt ihn beim ersten
  /// Aufruf. Mit ``force: true`` wird die lokale Datei ignoriert.
  Future<LocalIndex> load({
    String gameSlug = 'pokemon',
    bool force = false,
  }) {
    if (_cached != null && _cached!.gameSlug == gameSlug && !force) {
      return Future.value(_cached!);
    }
    final inflight = _inflight;
    if (inflight != null && !force) return inflight;

    final future = _loadImpl(gameSlug: gameSlug, force: force).whenComplete(() {
      _inflight = null;
    });
    _inflight = future;
    return future;
  }

  Future<LocalIndex> _loadImpl({
    required String gameSlug,
    required bool force,
  }) async {
    final dir = await getApplicationSupportDirectory();
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File(p.join(dir.path, _kSnapshotFile));
    final etagFile = File(p.join(dir.path, _kEtagFile));

    String? localEtag;
    if (!force && await file.exists() && await etagFile.exists()) {
      localEtag = (await etagFile.readAsString()).trim();
    }

    final api = _ref.read(snapshotApiProvider);
    SnapshotPayload? payload;
    try {
      // ignore: avoid_print
      print('[LocalIndex] fetching snapshot game=$gameSlug etag=$localEtag');
      payload = await api.fetchSnapshot(
        gameSlug: gameSlug,
        ifNoneMatch: localEtag,
      );
      // ignore: avoid_print
      print(
        '[LocalIndex] snapshot fetched: ${payload == null ? "304 not-modified" : "${payload.body.length} bytes count=${payload.count} dim=${payload.dim}"}',
      );
    } catch (e, st) {
      // ignore: avoid_print
      print('[LocalIndex] fetch failed: $e');
      if (e is DioException) {
        // ignore: avoid_print
        print(
          '[LocalIndex] DioException type=${e.type} message="${e.message}" error=${e.error} (${e.error?.runtimeType}) response=${e.response?.statusCode}',
        );
      }
      // ignore: avoid_print
      print('[LocalIndex] stacktrace: $st');
      // Offline / Backend down: nutze lokale Datei wenn vorhanden.
      if (await file.exists() && localEtag != null) {
        // ignore: avoid_print
        print('[LocalIndex] backend offline, using cached snapshot ($e)');
        final bytes = await file.readAsBytes();
        final index = _decodeSnapshot(bytes, localEtag);
        _cached = index;
        return index;
      }
      rethrow;
    }

    if (payload == null) {
      // 304: lokal ist aktuell.
      if (!await file.exists() || localEtag == null) {
        throw LocalIndexException(
          'Backend lieferte 304 obwohl kein lokaler Snapshot vorhanden ist.',
        );
      }
      final bytes = await file.readAsBytes();
      final index = _decodeSnapshot(bytes, localEtag);
      _cached = index;
      return index;
    }

    // Atomar schreiben (tmp -> rename), damit ein Abbruch nicht zu einer
    // halben Datei fuehrt.
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(payload.body, flush: true);
    if (await file.exists()) await file.delete();
    await tmp.rename(file.path);
    await etagFile.writeAsString(payload.etag);

    final index = _decodeSnapshot(payload.body, payload.etag);
    _cached = index;
    return index;
  }

  /// Loescht alle lokalen Snapshot-Dateien (z.B. wenn das Modell-Versions-
  /// Format nicht mehr kompatibel ist).
  Future<void> clear() async {
    _cached = null;
    final dir = await getApplicationSupportDirectory();
    for (final name in const [_kSnapshotFile, _kEtagFile]) {
      final f = File(p.join(dir.path, name));
      if (await f.exists()) await f.delete();
    }
  }
}

LocalIndex _decodeSnapshot(Uint8List bytes, String etag) {
  if (bytes.length < _kHeaderBytes) {
    throw LocalIndexException('snapshot too small: ${bytes.length} bytes');
  }
  for (var i = 0; i < 4; i++) {
    if (bytes[i] != _kMagic[i]) {
      throw LocalIndexException(
        'snapshot magic mismatch (got ${bytes.sublist(0, 4)})',
      );
    }
  }
  final view = ByteData.sublistView(bytes);
  final version = view.getUint32(4, Endian.little);
  if (version != _kVersion) {
    throw LocalIndexException('snapshot version $version not supported');
  }
  final count = view.getUint32(8, Endian.little);
  final dim = view.getUint32(12, Endian.little);
  final flags = view.getUint32(16, Endian.little);
  if ((flags & _kFlagInt8) == 0) {
    throw LocalIndexException(
      'snapshot has unsupported flags=$flags (need INT8)',
    );
  }
  final modelVersion =
      _readPaddedAscii(bytes, 20, _kModelVerField);
  final gameSlug =
      _readPaddedAscii(bytes, 20 + _kModelVerField, _kGameSlugField);

  final idsOffset = _kHeaderBytes;
  final idsEnd = idsOffset + count * 16;
  final scalesEnd = idsEnd + count * 4;
  final vectorsEnd = scalesEnd + count * dim;
  if (bytes.length != vectorsEnd) {
    throw LocalIndexException(
      'snapshot size mismatch: expected $vectorsEnd, got ${bytes.length}',
    );
  }

  final rawIds = Uint8List.sublistView(bytes, idsOffset, idsEnd);
  final scales = Float32List.view(
    bytes.buffer,
    bytes.offsetInBytes + idsEnd,
    count,
  );
  final vectors = Int8List.view(
    bytes.buffer,
    bytes.offsetInBytes + scalesEnd,
    count * dim,
  );

  return LocalIndex._(
    modelVersion: modelVersion,
    gameSlug: gameSlug,
    count: count,
    dim: dim,
    etag: etag,
    rawIds: rawIds,
    scales: scales,
    vectors: vectors,
  );
}

String _readPaddedAscii(Uint8List bytes, int offset, int length) {
  var end = offset;
  final limit = offset + length;
  while (end < limit && bytes[end] != 0) {
    end++;
  }
  return String.fromCharCodes(bytes.sublist(offset, end));
}

final localIndexServiceProvider = Provider<LocalIndexService>((ref) {
  return LocalIndexService(ref);
});

/// FutureProvider, der den Index beim ersten Watch laedt.
final localIndexProvider = FutureProvider<LocalIndex>((ref) async {
  return ref.read(localIndexServiceProvider).load();
});
