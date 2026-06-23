/// ONNX-Detector-Service: laedt das YOLO11n-OBB-Modell und liefert
/// orientierte Bounding-Boxes (rotated rectangles) fuer Karten.
///
/// Output-Format des Modells (Ultralytics YOLO11-OBB ONNX-Export):
///   Shape (1, 5+nc+1, N) oder (1, N, 5+nc+1).
///   Channels: cx, cy, w, h, cls_score_1..nc, angle_rad.
///   Bei nc=1: 6 Channels.
///   Koordinaten im Letterbox-Input-Raum (640x640).
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

import 'detection.dart';

const String _kModelAsset = 'assets/models/cards_detector.onnx';

class DetectorService {
  DetectorService._(this._session);

  final OrtSession _session;

  static const int inputSize = 640;
  // Conf-Threshold hoch: niedrigere Confidences korrelieren mit
  // falschen Orientierungen oder Hintergrund-Strukturen.
  static const double confThreshold = 0.50;
  static const double iouThreshold = 0.45;
  static const int maxDetections = 32;
  // Pokemon-Karte aspect (kurze/lange Seite): 245/337 = 0.727.
  // Toleranz +/- 0.13 deckt Perspektiv-Verzerrungen ab,
  // verwirft aber Spielmatten-Stuecke und Stapel-Anschnitte.
  static const double minAspectRatio = 0.55;
  static const double maxAspectRatio = 0.90;
  static const double minSideLengthPx = 60.0;
  static const String modelVersion = 'yolo11n-obb-cards-2026.06';

  /// Karten-Aspect (Pokemon): ~245:337 = 0.727. Wir croppen auf 256x352
  /// (etwas ueber Embedder-Input-Groesse, damit Embedder noch resize+crop
  /// auf 224 macht ohne Detail-Verlust).
  static const int cropWidth = 256;
  static const int cropHeight = 352;

  static Future<DetectorService> create() async {
    // ignore: avoid_print
    print('[Detector] init OrtEnv...');
    OrtEnv.instance.init();

    Uint8List modelBytes;
    try {
      final byteData = await rootBundle.load(_kModelAsset);
      modelBytes = byteData.buffer.asUint8List();
    } catch (e) {
      // ignore: avoid_print
      print('[Detector] Modell nicht gefunden ($_kModelAsset): $e');
      rethrow;
    }
    // ignore: avoid_print
    print('[Detector] model bytes: ${modelBytes.lengthInBytes}, building session...');

    final options = OrtSessionOptions()
      ..setIntraOpNumThreads(4)
      ..setInterOpNumThreads(1)
      ..setSessionGraphOptimizationLevel(GraphOptimizationLevel.ortEnableAll);
    try {
      options.appendXnnpackProvider();
      // ignore: avoid_print
      print('[Detector] XNNPACK provider attached');
    } catch (e) {
      // ignore: avoid_print
      print('[Detector] XNNPACK unavailable: $e (using CPU)');
    }

    final session = OrtSession.fromBuffer(modelBytes, options);
    // ignore: avoid_print
    print('[Detector] session ready (inputs=${session.inputNames}, outputs=${session.outputNames})');
    return DetectorService._(session);
  }

  /// Sucht orientierte Karten-Bounding-Boxes im Bild.
  /// Liefert maximal [maxDetections] Detections, sortiert nach Confidence.
  Future<List<CardDetection>> detect(img.Image image) async {
    final lb = _letterbox(image, inputSize);

    final shape = [1, 3, inputSize, inputSize];
    final tensor = OrtValueTensor.createTensorWithDataList(lb.input, shape);
    final runOptions = OrtRunOptions();
    try {
      final inputName = _session.inputNames.first;
      final outputs = await _session.runAsync(runOptions, {inputName: tensor});
      try {
        final tensorOut = outputs?.first;
        if (tensorOut == null) {
          throw StateError('ONNX-Session lieferte kein Output.');
        }
        final raw = tensorOut.value;
        final detections = _decode(
          raw,
          scale: lb.scale,
          padX: lb.padX,
          padY: lb.padY,
          origW: image.width,
          origH: image.height,
        );
        final kept = _nms(detections, iouThreshold);
        kept.sort((a, b) => b.confidence.compareTo(a.confidence));
        return kept.take(maxDetections).toList();
      } finally {
        outputs?.forEach((o) => o?.release());
      }
    } finally {
      tensor.release();
      runOptions.release();
    }
  }

  /// Schneidet die Karte perspektivisch korrigiert aus dem Originalbild
  /// aus. Verwendet eine 3-Punkt-Affin-Transformation (TL, TR, BL aus OBB)
  /// mit bilinearer Interpolation.
  img.Image cropDetection(
    img.Image source,
    CardDetection det, {
    int? targetWidth,
    int? targetHeight,
  }) {
    final tw = targetWidth ?? cropWidth;
    final th = targetHeight ?? cropHeight;
    // Orientierungs-Korrektur: wenn die Detection breiter als hoch ist
    // (Karte liegt im Modell-Frame quer), Polygon zyklisch um 1
    // Position drehen damit die lange Seite immer Crop-Hoehe wird.
    // Sonst wird die Karte ins Hochformat-Crop verdreht und der
    // Embedder bekommt eine verzerrte Eingabe.
    final poly = det.width > det.height
        ? <Offset>[det.polygon[3], det.polygon[0], det.polygon[1], det.polygon[2]]
        : det.polygon;
    return _affineWarp(source, poly, tw, th);
  }

  void dispose() {
    _session.release();
  }
}

// ---------------------------------------------------------------------------
// Letterbox-Preprocess
// ---------------------------------------------------------------------------

({Float32List input, double scale, int padX, int padY}) _letterbox(
  img.Image src,
  int size,
) {
  final scaleX = size / src.width;
  final scaleY = size / src.height;
  final scale = math.min(scaleX, scaleY);
  final newW = (src.width * scale).round();
  final newH = (src.height * scale).round();
  final padX = ((size - newW) ~/ 2);
  final padY = ((size - newH) ~/ 2);

  final resized = img.copyResize(
    src,
    width: newW,
    height: newH,
    interpolation: img.Interpolation.linear,
  );

  final input = Float32List(1 * 3 * size * size);
  final planeSize = size * size;
  // YOLO-Standard Padding: gray 114/255
  const padVal = 114.0 / 255.0;
  for (var i = 0; i < planeSize; i++) {
    input[i] = padVal;
    input[planeSize + i] = padVal;
    input[2 * planeSize + i] = padVal;
  }
  for (var y = 0; y < newH; y++) {
    for (var x = 0; x < newW; x++) {
      final p = resized.getPixel(x, y);
      final dx = x + padX;
      final dy = y + padY;
      final idx = dy * size + dx;
      input[idx] = p.r / 255.0;
      input[planeSize + idx] = p.g / 255.0;
      input[2 * planeSize + idx] = p.b / 255.0;
    }
  }
  return (input: input, scale: scale, padX: padX, padY: padY);
}

// ---------------------------------------------------------------------------
// Output-Decode
// ---------------------------------------------------------------------------

List<CardDetection> _decode(
  Object? raw, {
  required double scale,
  required int padX,
  required int padY,
  required int origW,
  required int origH,
}) {
  if (raw is! List) {
    throw StateError('Unerwarteter Detector-Output: ${raw.runtimeType}');
  }
  final batch = raw.first;
  if (batch is! List) {
    throw StateError('Unerwarteter Detector-Output (batch): ${batch.runtimeType}');
  }

  final firstDim = batch.length;
  final secondInner = batch.first;
  if (secondInner is! List) {
    throw StateError('Unerwarteter Detector-Output (inner): ${secondInner.runtimeType}');
  }
  final secondDim = secondInner.length;

  // (1, channels, anchors) wenn firstDim < secondDim, sonst transposed.
  final isChannelFirst = firstDim < secondDim;
  final numChannels = isChannelFirst ? firstDim : secondDim;
  final numAnchors = isChannelFirst ? secondDim : firstDim;

  if (numChannels < 6) {
    throw StateError(
      'Detector-Output hat ${numChannels} channels, erwartet >=6 (cx,cy,w,h,conf,angle)',
    );
  }

  // Schnelle Accessoren: convertiert nested Lists in flache typed-Arrays.
  final flat = Float32List(numChannels * numAnchors);
  if (isChannelFirst) {
    for (var c = 0; c < numChannels; c++) {
      final row = batch[c] as List;
      for (var a = 0; a < numAnchors; a++) {
        flat[c * numAnchors + a] = (row[a] as num).toDouble();
      }
    }
  } else {
    for (var a = 0; a < numAnchors; a++) {
      final row = batch[a] as List;
      for (var c = 0; c < numChannels; c++) {
        flat[c * numAnchors + a] = (row[c] as num).toDouble();
      }
    }
  }

  final detections = <CardDetection>[];
  for (var a = 0; a < numAnchors; a++) {
    final conf = flat[4 * numAnchors + a]; // class_0 score
    if (conf < DetectorService.confThreshold) continue;

    final cx = flat[0 * numAnchors + a];
    final cy = flat[1 * numAnchors + a];
    final w = flat[2 * numAnchors + a];
    final h = flat[3 * numAnchors + a];
    // angle = letzter Channel (5 bei nc=1, ggf. 4+nc bei mehr Klassen).
    final angle = flat[(numChannels - 1) * numAnchors + a];

    final cosA = math.cos(angle);
    final sinA = math.sin(angle);
    final halfW = w / 2.0;
    final halfH = h / 2.0;
    // TL, TR, BR, BL relativ zum Center, vor Rotation
    final relCorners = [
      [-halfW, -halfH],
      [halfW, -halfH],
      [halfW, halfH],
      [-halfW, halfH],
    ];
    final corners = <Offset>[];
    for (final rc in relCorners) {
      final rx = cosA * rc[0] - sinA * rc[1] + cx;
      final ry = sinA * rc[0] + cosA * rc[1] + cy;
      // Reverse Letterbox: (input_coord - pad) / scale
      final ox = ((rx - padX) / scale).clamp(0.0, (origW - 1).toDouble());
      final oy = ((ry - padY) / scale).clamp(0.0, (origH - 1).toDouble());
      corners.add(Offset(ox, oy));
    }

    final originalCx = (cx - padX) / scale;
    final originalCy = (cy - padY) / scale;

    final origW2 = w / scale;
    final origH2 = h / scale;
    // Validation: Min-Groesse + plausibler Pokemon-Karten-Aspect.
    // Schliesst Hintergrund-Detections, Karten-Stuecke und
    // Multi-Karten-Cluster aus.
    final shortSide = math.min(origW2, origH2);
    final longSide = math.max(origW2, origH2);
    if (shortSide < DetectorService.minSideLengthPx) continue;
    final aspect = shortSide / longSide;
    if (aspect < DetectorService.minAspectRatio ||
        aspect > DetectorService.maxAspectRatio) {
      continue;
    }

    detections.add(CardDetection(
      polygon: corners,
      confidence: conf,
      angleRad: angle,
      center: Offset(originalCx, originalCy),
      width: origW2,
      height: origH2,
    ));
  }
  return detections;
}

// ---------------------------------------------------------------------------
// NMS (Axis-Aligned IoU – Approximation, ausreichend fuer Karten-Layouts)
// ---------------------------------------------------------------------------

List<CardDetection> _nms(List<CardDetection> dets, double iouThreshold) {
  if (dets.isEmpty) return const [];
  dets.sort((a, b) => b.confidence.compareTo(a.confidence));
  final kept = <CardDetection>[];
  for (final d in dets) {
    var suppress = false;
    for (final k in kept) {
      if (_aabbIou(d, k) > iouThreshold) {
        suppress = true;
        break;
      }
    }
    if (!suppress) kept.add(d);
  }
  return kept;
}

double _aabbIou(CardDetection a, CardDetection b) {
  final ab = a.aabb;
  final bb = b.aabb;
  final ix = math.max(0.0, math.min(ab.right, bb.right) - math.max(ab.left, bb.left));
  final iy = math.max(0.0, math.min(ab.bottom, bb.bottom) - math.max(ab.top, bb.top));
  final inter = ix * iy;
  final areaA = (ab.right - ab.left) * (ab.bottom - ab.top);
  final areaB = (bb.right - bb.left) * (bb.bottom - bb.top);
  final union = areaA + areaB - inter;
  return union > 0 ? inter / union : 0.0;
}

// ---------------------------------------------------------------------------
// Affine Warp (3-Punkt) mit bilinearer Interpolation
// ---------------------------------------------------------------------------

img.Image _affineWarp(
  img.Image src,
  List<Offset> polygon,
  int targetW,
  int targetH,
) {
  // Mapping dest(u,v) -> src(x,y):
  //   src = A * [u, v]^T + t
  // mit
  //   t = TL
  //   A col 0 = (TR - TL) / targetW
  //   A col 1 = (BL - TL) / targetH
  final tl = polygon[0];
  final tr = polygon[1];
  final bl = polygon[3];
  final aXX = (tr.dx - tl.dx) / targetW;
  final aYX = (tr.dy - tl.dy) / targetW;
  final aXY = (bl.dx - tl.dx) / targetH;
  final aYY = (bl.dy - tl.dy) / targetH;
  final tX = tl.dx;
  final tY = tl.dy;

  // Eigener Uint8List-Buffer + Image.fromBytes: in image 4.9.1 liefert
  // der Image(numChannels:3)-Konstruktor in Kombination mit setPixelRgb
  // unter bestimmten Bedingungen eine unmodifiable Pixel-Iterator-View
  // ("Cannot modify an unmodifiable list"). Mit einem selbst allozierten
  // Buffer ist der Schreibpfad garantiert mutierbar.
  final buf = Uint8List(targetW * targetH * 3);
  final srcW = src.width;
  final srcH = src.height;

  for (var v = 0; v < targetH; v++) {
    for (var u = 0; u < targetW; u++) {
      final sx = aXX * u + aXY * v + tX;
      final sy = aYX * u + aYY * v + tY;

      final x0 = sx.floor();
      final y0 = sy.floor();
      final x1 = x0 + 1;
      final y1 = y0 + 1;
      final outIdx = (v * targetW + u) * 3;

      if (x0 < 0 || y0 < 0 || x1 >= srcW || y1 >= srcH) {
        // schwarz (Buffer ist bereits 0-initialisiert)
        continue;
      }

      final fx = sx - x0;
      final fy = sy - y0;
      final w00 = (1 - fx) * (1 - fy);
      final w10 = fx * (1 - fy);
      final w01 = (1 - fx) * fy;
      final w11 = fx * fy;

      final p00 = src.getPixel(x0, y0);
      final p10 = src.getPixel(x1, y0);
      final p01 = src.getPixel(x0, y1);
      final p11 = src.getPixel(x1, y1);

      final r = (p00.r * w00 + p10.r * w10 + p01.r * w01 + p11.r * w11).round();
      final g = (p00.g * w00 + p10.g * w10 + p01.g * w01 + p11.g * w11).round();
      final b = (p00.b * w00 + p10.b * w10 + p01.b * w01 + p11.b * w11).round();

      buf[outIdx] = r < 0 ? 0 : (r > 255 ? 255 : r);
      buf[outIdx + 1] = g < 0 ? 0 : (g > 255 ? 255 : g);
      buf[outIdx + 2] = b < 0 ? 0 : (b > 255 ? 255 : b);
    }
  }
  return img.Image.fromBytes(
    width: targetW,
    height: targetH,
    bytes: buf.buffer,
    numChannels: 3,
    format: img.Format.uint8,
    order: img.ChannelOrder.rgb,
  );
}

// ---------------------------------------------------------------------------
// Riverpod-Provider
// ---------------------------------------------------------------------------

final detectorServiceProvider = FutureProvider<DetectorService>((ref) async {
  final service = await DetectorService.create();
  ref.onDispose(service.dispose);
  return service;
});
