// app/lib/features/scan/scan_controller.dart
/// Live-Scan-Pipeline mit On-Device-Embedder + Local-Index.
///
/// Pipeline pro Frame:
///   1. Bild von Datei laden, auf zentralen Karten-ROI croppen.
///   2. Sharpness-Gate (Laplace-Varianz) – verwirft offensichtlich verwackelte
///      Frames bevor der teure ONNX-Run startet.
///   3. DINOv2-INT8-Embedding berechnen (~80–150 ms auf Mobile-CPU).
///   4. Top-K Cosine-Match gegen [LocalIndex] (~10–30 ms fuer 40k Karten).
///   5. Stabilitaets-Tracker: liefert nur dann ein UI-Ergebnis wenn die
///      gleiche Top-1-Karte ueber mehrere Frames mit ausreichender
///      Similarity gewinnt. Verhindert flackernde False-Positives.
///   6. Erst bei stabilem Treffer wird das Backend einmalig fuer die
///      Metadaten (``/api/v1/cards/lookup``) angefragt.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image/image.dart' as img;

import '../../core/sound_service.dart';
import '../../data/api/cards_api.dart';
import '../../data/dto/card_summary_dto.dart';
import '../../data/dto/identify_dto.dart';
import '../../data/local/scan_history_entry.dart';
import '../../data/local/scan_history_store.dart';
import '../../detector/detector_service.dart';
import '../../embedder/camera_image_converter.dart';
import '../../embedder/embedder_service.dart';
import '../../embedder/local_index.dart';

/// Schwellwerte fuer die Live-Erkennung.
class ScanThresholds {
  const ScanThresholds({
    this.minSimilarity = 0.55,
    this.confirmSimilarity = 0.72,
    this.stableFrames = 2,
    this.sharpnessMin = 60.0,
  });

  /// Unter dieser Cosine-Similarity wird der Top-1 verworfen (kein Match).
  final double minSimilarity;

  /// Ab dieser Similarity wird ein Match als "confirmed" markiert und der
  /// Live-Loop kann pausiert werden.
  final double confirmSimilarity;

  /// Wie viele Frames in Folge die gleiche Top-1-cardId liefern muessen
  /// bevor der Tracker einen stabilen Match meldet.
  final int stableFrames;

  /// Mindest-Laplace-Varianz im ROI – Frames darunter sind zu verschwommen.
  final double sharpnessMin;
}

class ScanResult {
  const ScanResult({
    required this.matches,
    required this.stable,
    required this.confirmed,
    required this.topSimilarity,
    required this.sharpness,
  });

  /// Hydratisierte Top-K-Treffer mit Backend-Metadaten.
  final List<IdentifyMatch> matches;

  /// True wenn die gleiche cardId mehrfach in Folge gewonnen hat.
  final bool stable;

  /// True wenn der Top-1-Match zusaetzlich die ``confirmSimilarity`` erreicht.
  /// Auf ``confirmed`` reagiert die UI mit Auto-Show.
  final bool confirmed;

  /// Cosine-Similarity des Top-1 (zur Anzeige als Konfidenz-Balken).
  final double topSimilarity;

  /// Berechnete Schaerfe des verarbeiteten ROIs (Debug/Telemetry).
  final double sharpness;

  bool get hasMatches => matches.isNotEmpty;
}

class _StabilityTracker {
  _StabilityTracker(this.requiredFrames);

  final int requiredFrames;
  String? _lastCardId;
  int _streak = 0;

  /// Returns true wenn `cardId` zum requiredFrames-ten Mal in Folge gewinnt.
  bool observe(String? cardId) {
    if (cardId == null) {
      _lastCardId = null;
      _streak = 0;
      return false;
    }
    if (_lastCardId == cardId) {
      _streak++;
    } else {
      _lastCardId = cardId;
      _streak = 1;
    }
    return _streak >= requiredFrames;
  }

  void reset() {
    _lastCardId = null;
    _streak = 0;
  }
}

class ScanController extends StateNotifier<AsyncValue<ScanResult?>> {
  ScanController(this._ref, {ScanThresholds? thresholds})
      : _thresholds = thresholds ?? const ScanThresholds(),
        _tracker = _StabilityTracker(
          (thresholds ?? const ScanThresholds()).stableFrames,
        ),
        super(const AsyncValue.data(null));

  final Ref _ref;
  final ScanThresholds _thresholds;
  final _StabilityTracker _tracker;

  /// Letzte cardId fuer die wir bereits ein Confirm-Feedback (Sound +
  /// Haptik) ausgeloest haben. Verhindert dass jeder weitere stable Frame
  /// derselben Karte erneut piept. Wird in `reset()` und beim Reject
  /// geloescht, sodass die exakt gleiche Karte nach einer Lueck-Phase
  /// erneut beepen darf (= naechster Scan-Versuch).
  String? _lastFeedbackCardId;

  /// Laedt eine Datei, dekodiert sie und ruft [identifyFromImage] auf.
  Future<void> identifyFromFile(File file) async {
    final bytes = await file.readAsBytes();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      state = AsyncValue.error(
        StateError('Bild konnte nicht dekodiert werden: ${file.path}'),
        StackTrace.current,
      );
      return;
    }
    await identifyFromImage(decoded);
  }

  /// Verarbeitet ein bereits dekodiertes Bild (z.B. aus dem Kamera-Stream).
  Future<void> identifyFromImage(img.Image image) async {
    state = const AsyncValue.loading();
    try {
      final roi = await _detectAndCrop(image);
      final sharpness = _laplaceVariance(roi);
      if (sharpness < _thresholds.sharpnessMin) {
        _tracker.reset();
        state = AsyncValue.data(
          ScanResult(
            matches: const [],
            stable: false,
            confirmed: false,
            topSimilarity: 0,
            sharpness: sharpness,
          ),
        );
        return;
      }

      final embedder = await _ref.read(embedderServiceProvider.future);
      final index = await _ref.read(localIndexProvider.future);
      final embedding = await embedder.embed(roi);

      await _processEmbedding(embedding, index, sharpness);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Versucht zuerst den YOLO11-OBB-Detector. Findet er mindestens eine
  /// Karte, wird das Top-1-Polygon perspektivisch entzerrt ausgeschnitten.
  /// Schlaegt der Detector fehl (kein Match, Modell fehlt, ORT-Fehler),
  /// fallback auf den fixen Cutout-ROI.
  Future<img.Image> _detectAndCrop(img.Image image) async {
    try {
      final detector = await _ref.read(detectorServiceProvider.future);
      final detections = await detector.detect(image);
      if (detections.isNotEmpty) {
        final top = detections.first;
        // ignore: avoid_print
        print(
          '[Scan] Detector: ${detections.length} Karte(n), '
          'top conf=${top.confidence.toStringAsFixed(3)} '
          'angle=${(top.angleRad * 180 / 3.14159).toStringAsFixed(1)}°',
        );
        return detector.cropDetection(image, top);
      }
      // ignore: avoid_print
      print('[Scan] Detector: keine Karte gefunden, fallback fixer ROI');
    } catch (e) {
      // ignore: avoid_print
      print('[Scan] Detector-Fehler, fallback fixer ROI: $e');
    }
    return _cropToCardRoi(image);
  }

  /// Schneller Pfad fuer Live-Streams: nimmt einen YUV-Kamera-Frame, macht
  /// Crop+Resize+Normalize+CHW in einem Pass und ruft den Embedder mit dem
  /// fertigen Tensor auf. Spart JPEG-Encode/Decode (~300-500 ms auf Mobile).
  Future<void> identifyFromCameraImage(
    CameraImage image, {
    int sensorOrientation = 90,
  }) async {
    state = const AsyncValue.loading();
    try {
      final embedder = await _ref.read(embedderServiceProvider.future);
      final index = await _ref.read(localIndexProvider.future);
      final t0 = DateTime.now().microsecondsSinceEpoch;
      final prepared = preprocessCameraImage(
        image,
        embedder.config,
        sensorOrientation: sensorOrientation,
      );
      final t1 = DateTime.now().microsecondsSinceEpoch;
      if (prepared.sharpness < _thresholds.sharpnessMin) {
        _tracker.reset();
        // ignore: avoid_print
        print(
          '[Scan] reject sharpness=${prepared.sharpness.toStringAsFixed(0)} '
          '< min=${_thresholds.sharpnessMin} (prep=${((t1 - t0) / 1000).toStringAsFixed(0)}ms)',
        );
        state = AsyncValue.data(
          ScanResult(
            matches: const [],
            stable: false,
            confirmed: false,
            topSimilarity: 0,
            sharpness: prepared.sharpness,
          ),
        );
        return;
      }
      final embedding = await embedder.embedTensor(prepared.tensor);
      final t2 = DateTime.now().microsecondsSinceEpoch;
      await _processEmbedding(embedding, index, prepared.sharpness,
          prepMs: (t1 - t0) / 1000, embedMs: (t2 - t1) / 1000);
    } catch (e, st) {
      // ignore: avoid_print
      print('[Scan] identifyFromCameraImage error: $e');
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> _processEmbedding(
    Float32List embedding,
    LocalIndex index,
    double sharpness, {
    double prepMs = 0,
    double embedMs = 0,
  }) async {
    final t0 = DateTime.now().microsecondsSinceEpoch;
    final hits = index.topK(embedding, 5);
    final topKMs = (DateTime.now().microsecondsSinceEpoch - t0) / 1000;
    if (hits.isEmpty || hits.first.similarity < _thresholds.minSimilarity) {
      _tracker.reset();
      _lastFeedbackCardId = null;
      // ignore: avoid_print
      print(
        '[Scan] reject sim=${hits.isEmpty ? 0 : hits.first.similarity.toStringAsFixed(3)} '
        '< min=${_thresholds.minSimilarity} sharp=${sharpness.toStringAsFixed(0)} '
        '(prep=${prepMs.toStringAsFixed(0)}ms embed=${embedMs.toStringAsFixed(0)}ms topK=${topKMs.toStringAsFixed(0)}ms)',
      );
      state = AsyncValue.data(
        ScanResult(
          matches: const [],
          stable: false,
          confirmed: false,
          topSimilarity: hits.isEmpty ? 0 : hits.first.similarity,
          sharpness: sharpness,
        ),
      );
      return;
    }

    final top = hits.first;

    // Lock-Modus: wenn wir gerade eine confirmed-Karte zeigen und der
    // Embedder weiterhin dieselbe Karte als Top-1 sieht, dann nichts tun.
    // Spart pro Frame: tracker-update, _hydrate(Backend-Call), setState,
    // UI-Rebuild. UI bleibt ruhig, Akku/CPU werden geschont.
    if (_lastFeedbackCardId != null && top.cardId == _lastFeedbackCardId) {
      // ignore: avoid_print
      print(
        '[Scan] locked top=${top.cardId} sim=${top.similarity.toStringAsFixed(3)} - skip',
      );
      return;
    }

    // Eine ANDERE Karte ist ploetzlich Top-1: alten Lock loesen und den
    // Stability-Tracker explizit zuruecksetzen, damit die neue Karte
    // ehrlich ueber `stableFrames` belegt werden muss.
    if (_lastFeedbackCardId != null) {
      _lastFeedbackCardId = null;
      _tracker.reset();
    }

    final isStable = _tracker.observe(top.cardId);
    final isConfirmed =
        isStable && top.similarity >= _thresholds.confirmSimilarity;

    // Backend-Hydration nur wenn wir wirklich etwas zeigen. Bei jedem
    // Frame ein Lookup-Call waere unnoetig Traffic und Server-Load.
    final matches = isStable ? await _hydrate(hits) : const <IdentifyMatch>[];

    // ignore: avoid_print
    print(
      '[Scan] top=${top.cardId} sim=${top.similarity.toStringAsFixed(3)} '
      'sharp=${sharpness.toStringAsFixed(0)} stable=$isStable '
      'confirmed=$isConfirmed '
      '(prep=${prepMs.toStringAsFixed(0)}ms embed=${embedMs.toStringAsFixed(0)}ms topK=${topKMs.toStringAsFixed(0)}ms)',
    );

    // Confirmed-Match → automatisch in den Verlauf packen. Der Notifier
    // de-dupliziert intern gegen den letzten Eintrag, damit derselbe
    // Scan-Stream nicht 20x dieselbe Karte schreibt. Fire-and-forget,
    // damit der Frame-Loop nicht auf den File-Write wartet.
    if (isConfirmed && matches.isNotEmpty) {
      final m = matches.first;
      // Akustisches + taktiles Feedback genau einmal pro neuer Karte.
      // Erst nach reset (= Karte rausgenommen) darf dieselbe cardId
      // erneut piepen.
      if (m.cardId != _lastFeedbackCardId) {
        _lastFeedbackCardId = m.cardId;
        // Eigener Asset-Sound (assets/sounds/scan_success.mp3) ueber
        // SoundService. AudioPlayer ist als Singleton vorgeladen, daher
        // keine Decode-Latenz beim ersten Hit. Haptic bleibt parallel
        // fuer taktiles Feedback.
        // ignore: discarded_futures
        _ref.read(soundServiceProvider).playSuccess();
        HapticFeedback.mediumImpact();
      }
      final entry = ScanHistoryEntry(
        id: '${DateTime.now().millisecondsSinceEpoch}-${m.cardId}',
        cardId: m.cardId,
        cardName: m.name,
        setCode: m.setCode,
        number: m.number,
        language: m.language,
        rarity: m.rarity,
        imageUrl: m.imageUrl,
        scannedAt: DateTime.now(),
        similarity: m.similarity,
        cardmarketMetacardId: m.cardmarketMetacardId,
        cardmarketProductId: m.cardmarketProductId,
        cardmarketExpansionId: m.cardmarketExpansionId,
      );
      // ignore: discarded_futures
      _ref.read(scanHistoryProvider.notifier).addEntry(entry);
    }

    state = AsyncValue.data(
      ScanResult(
        matches: matches,
        stable: isStable,
        confirmed: isConfirmed,
        topSimilarity: top.similarity,
        sharpness: sharpness,
      ),
    );
  }

  Future<List<IdentifyMatch>> _hydrate(List<LocalIndexMatch> hits) async {
    final ids = [for (final h in hits) h.cardId];
    final api = _ref.read(cardsApiProvider);
    final summaries = await api.lookup(ids);
    final byId = {for (final s in summaries) s.cardId: s};
    final result = <IdentifyMatch>[];
    for (final hit in hits) {
      final s = byId[hit.cardId];
      if (s == null) continue; // Karte wurde im Backend geloescht
      result.add(_toMatch(hit, s));
    }
    return result;
  }

  void reset() {
    _tracker.reset();
    _lastFeedbackCardId = null;
    state = const AsyncValue.data(null);
  }
}

IdentifyMatch _toMatch(LocalIndexMatch hit, CardSummaryDto summary) =>
    IdentifyMatch(
      cardId: hit.cardId,
      similarity: hit.similarity,
      name: summary.name,
      setCode: summary.setCode,
      language: summary.setLanguage,
      number: summary.number,
      rarity: summary.rarity,
      imageUrl: summary.imageUrlSmall,
      cardmarketMetacardId: summary.cardmarketMetacardId,
      cardmarketProductId: summary.cardmarketProductId,
      cardmarketExpansionId: summary.cardmarketExpansionId,
    );

/// Schneidet das Kamerabild auf den zentralen Karten-ROI (Aspect 245:337)
/// zurecht – sonst dominiert der Hintergrund das DINOv2-Embedding und
/// die Match-Treffer werden zufaellig.
img.Image _cropToCardRoi(img.Image image) {
  const cardAspect = 245.0 / 337.0;
  final w = image.width;
  final h = image.height;
  final shortAxis = w < h ? w : h;
  final roiH = (shortAxis * 0.95).round();
  var roiW = (roiH * cardAspect).round();
  if (roiW > w) {
    roiW = w;
  }
  final left = ((w - roiW) / 2).round().clamp(0, w - roiW);
  final top = ((h - roiH) / 2).round().clamp(0, h - roiH);
  return img.copyCrop(
    image,
    x: left,
    y: top,
    width: roiW,
    height: roiH,
  );
}

/// Schaetzt die Schaerfe eines Bildes ueber die Varianz des Laplace-Filters.
/// Niedrige Werte (< ~80) bedeuten verwackelte oder unscharfe Frames.
///
/// Wir samplen auf 128x128 herunter um den Loop schnell zu halten und
/// verwenden einen 4-Nachbarn-Laplace-Kernel.
double _laplaceVariance(img.Image source) {
  final small = img.copyResize(
    source,
    width: 128,
    height: 128,
    interpolation: img.Interpolation.linear,
  );
  final w = small.width;
  final h = small.height;
  final gray = Uint8List(w * h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final p = small.getPixel(x, y);
      // ITU-R BT.601 Luma
      final lum =
          (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
      gray[y * w + x] = lum;
    }
  }

  var sum = 0.0;
  var sumSq = 0.0;
  var count = 0;
  for (var y = 1; y < h - 1; y++) {
    for (var x = 1; x < w - 1; x++) {
      final c = gray[y * w + x];
      final l = gray[y * w + (x - 1)];
      final r = gray[y * w + (x + 1)];
      final t = gray[(y - 1) * w + x];
      final b = gray[(y + 1) * w + x];
      final lap = (l + r + t + b - 4 * c).toDouble();
      sum += lap;
      sumSq += lap * lap;
      count++;
    }
  }
  if (count == 0) return 0;
  final mean = sum / count;
  return (sumSq / count) - mean * mean;
}

final scanThresholdsProvider = Provider<ScanThresholds>(
  (ref) => const ScanThresholds(),
);

final scanControllerProvider =
    StateNotifierProvider<ScanController, AsyncValue<ScanResult?>>(
  (ref) => ScanController(ref, thresholds: ref.read(scanThresholdsProvider)),
);
