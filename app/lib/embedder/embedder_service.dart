/// ONNX-Embedder-Service: laedt DINOv2-small einmalig, embeddet Bilder.
///
/// Modell-Output ist bereits L2-normalisiert (siehe DinoV2Embedder-Wrapper
/// in `ml/ml/embedder/export_onnx.py`).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

import 'preprocess.dart';

const String _kModelAsset = 'assets/models/dinov2_small.onnx';
const String _kPreprocessAsset = 'assets/models/dinov2_small.preprocess.json';

class EmbedderService {
  EmbedderService._(this._session, this._config);

  final OrtSession _session;
  final PreprocessConfig _config;
  static const String modelVersion = 'dinov2-s-2026.06-onnx';
  static const int embeddingDim = 384;

  static Future<EmbedderService> create() async {
    // ignore: avoid_print
    print('[Embedder] init OrtEnv...');
    OrtEnv.instance.init();
    // ignore: avoid_print
    print('[Embedder] loading model asset...');
    final modelBytes = await rootBundle.load(_kModelAsset);
    // ignore: avoid_print
    print('[Embedder] model bytes: ${modelBytes.lengthInBytes}, building session...');
    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(4)
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    // XNNPACK gibt auf ARM-CPUs (Pixel 8 Pro: Cortex-X3/A715) typischerweise
    // 1.5-3x Speedup fuer reine Conv/Transformer-Inferenz. Wenn der EP aus
    // irgendeinem Grund den Subgraph nicht annehmen kann, faellt ORT
    // automatisch auf den CPU-Provider zurueck.
    try {
      options.appendXnnpackProvider();
      // ignore: avoid_print
      print('[Embedder] XNNPACK provider attached');
    } catch (e) {
      // ignore: avoid_print
      print('[Embedder] XNNPACK provider unavailable: $e (using CPU)');
    }
    final session = OrtSession.fromBuffer(
      modelBytes.buffer.asUint8List(),
      options,
    );
    // ignore: avoid_print
    print('[Embedder] session ready, loading preprocess config...');
    final jsonStr = await rootBundle.loadString(_kPreprocessAsset);
    final cfg = PreprocessConfig.fromJson(
      jsonDecode(jsonStr) as Map<String, dynamic>,
    );
    // ignore: avoid_print
    print('[Embedder] ready (cropW=${cfg.cropWidth}, cropH=${cfg.cropHeight}).');
    return EmbedderService._(session, cfg);
  }

  /// Embeddet einen einzelnen [img.Image] und liefert einen 384-D-Vector.
  Future<Float32List> embed(img.Image image) async {
    final input = preprocessImage(image, _config);
    return embedTensor(input);
  }

  /// Embeddet einen bereits preprocessed-Tensor (Float32List NCHW [1,3,H,W]).
  /// Spart den `image`-Package-Roundtrip wenn der Caller bereits die
  /// Pixel-Daten aus einem Kamera-Stream konvertiert hat.
  Future<Float32List> embedTensor(Float32List input) async {
    final shape = [1, 3, _config.cropHeight, _config.cropWidth];
    final tensor = OrtValueTensor.createTensorWithDataList(input, shape);
    final runOptions = OrtRunOptions();
    try {
      final outputs = await _session.runAsync(runOptions, {'pixel_values': tensor});
      try {
        final tensorOut = outputs?.first;
        if (tensorOut == null) {
          throw StateError('ONNX-Session lieferte kein Output.');
        }
        final value = tensorOut.value;
        return _flattenBatch1(value);
      } finally {
        outputs?.forEach((o) => o?.release());
      }
    } finally {
      tensor.release();
      runOptions.release();
    }
  }

  /// Liefert die aktive Preprocess-Config (z.B. fuer den Kamera-Stream-
  /// Konverter).
  PreprocessConfig get config => _config;

  void dispose() {
    _session.release();
  }
}

/// Akzeptiert sowohl `List<List<double>>` (Batch=1) als auch `List<double>`.
Float32List _flattenBatch1(Object? value) {
  if (value is List<List<double>>) {
    return Float32List.fromList(value.first);
  }
  if (value is List<List<dynamic>>) {
    return Float32List.fromList(
      value.first.cast<num>().map((e) => e.toDouble()).toList(),
    );
  }
  if (value is List<double>) {
    return Float32List.fromList(value);
  }
  if (value is List<dynamic>) {
    return Float32List.fromList(value.cast<num>().map((e) => e.toDouble()).toList());
  }
  throw StateError('Unerwarteter ONNX-Output-Typ: ${value.runtimeType}');
}

final embedderServiceProvider = FutureProvider<EmbedderService>((ref) async {
  final service = await EmbedderService.create();
  ref.onDispose(service.dispose);
  return service;
});
