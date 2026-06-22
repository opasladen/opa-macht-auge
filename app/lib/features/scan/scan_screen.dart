import 'dart:async';

import 'package:camera/camera.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/dto/identify_dto.dart';
import '../../embedder/embedder_service.dart';
import '../../embedder/local_index.dart';
import 'scan_controller.dart';

/// Kamera-Discovery wird einmalig beim App-Start gecached.
final _camerasProvider = FutureProvider<List<CameraDescription>>((ref) async {
  // ignore: avoid_print
  print('[Scan] availableCameras() starting');
  try {
    final cams = await availableCameras();
    // ignore: avoid_print
    print('[Scan] availableCameras() returned ${cams.length} cameras');
    return cams;
  } catch (e, st) {
    // ignore: avoid_print
    print('[Scan] availableCameras() error: $e\n$st');
    rethrow;
  }
});

/// Mindest-Abstand zwischen zwei Stream-Frames die wir tatsaechlich
/// verarbeiten. Pixel liefert ~30 fps; bei 100 ms throttlen wir auf 10 fps
/// was die CPU nicht ueberlastet aber trotzdem sub-sekunden-Erkennung
/// ermoeglicht. Der zusaetzliche _busy-Guard verhindert Pile-Up wenn ein
/// einzelner Embed-Run laenger als das Intervall braucht.
const Duration _minFrameInterval = Duration(milliseconds: 100);

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  CameraController? _controller;
  CameraDescription? _activeCamera;
  bool _streaming = false;
  bool _busy = false;
  bool _paused = false;
  DateTime _lastFrameAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void dispose() {
    _stopStream();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _ensureController(List<CameraDescription> cameras) async {
    if (_controller != null) return;
    // ignore: avoid_print
    print('[Scan] _ensureController called cams=${cameras.length}');
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    // ignore: avoid_print
    print('[Scan] selected camera name=${back.name} lens=${back.lensDirection} sensorOrientation=${back.sensorOrientation}');
    final ctrl = CameraController(
      back,
      // medium = 720p reicht fuer DINOv2 (Ziel ist 224x224 nach Center-Crop)
      // und haelt den YUV-Stream-Konverter im Sub-30-ms-Bereich.
      ResolutionPreset.medium,
      enableAudio: false,
      // YUV420 ist auf Android nativ vom Sensor und erspart uns die JPEG-
      // Encode/Decode-Runde. Auf iOS ist das BGRA, dort muessten wir
      // spaeter eine zweite Konvertierungs-Variante hinzufuegen.
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    try {
      await ctrl.initialize();
      // ignore: avoid_print
      print('[Scan] controller initialized: ${ctrl.value.previewSize}');
    } catch (e, st) {
      // ignore: avoid_print
      print('[Scan] controller.initialize() failed: $e\n$st');
      rethrow;
    }
    if (!mounted) return;
    setState(() {
      _controller = ctrl;
      _activeCamera = back;
    });
    await _startStream();
  }

  Future<void> _startStream() async {
    final ctrl = _controller;
    if (ctrl == null || _streaming) return;
    _streaming = true;
    try {
      await ctrl.startImageStream(_onFrame);
      // ignore: avoid_print
      print(
        '[Scan] image stream started, sensorOrientation='
        '${_activeCamera?.sensorOrientation}',
      );
    } catch (e, st) {
      _streaming = false;
      // ignore: avoid_print
      print('[Scan] startImageStream failed: $e\n$st');
      rethrow;
    }
  }

  Future<void> _stopStream() async {
    final ctrl = _controller;
    if (ctrl == null || !_streaming) return;
    _streaming = false;
    try {
      await ctrl.stopImageStream();
    } catch (_) {
      // Best-effort beim Dispose; Plugin wirft gelegentlich wenn Stream
      // schon abgeraeumt ist.
    }
  }

  void _onFrame(CameraImage frame) {
    if (!mounted || _paused || _busy) return;
    final now = DateTime.now();
    if (now.difference(_lastFrameAt) < _minFrameInterval) return;
    _lastFrameAt = now;

    final embedder = ref.read(embedderServiceProvider);
    final index = ref.read(localIndexProvider);
    if (embedder is! AsyncData || index is! AsyncData) {
      // ignore: avoid_print
      print(
        '[Scan] frame skipped (embedder=${embedder.runtimeType} index=${index.runtimeType})',
      );
      return;
    }

    _processFrame(frame);
  }

  Future<void> _processFrame(CameraImage frame) async {
    if (_busy) return;
    _busy = true;
    final sensorOrientation = _activeCamera?.sensorOrientation ?? 90;
    final startMs = DateTime.now().millisecondsSinceEpoch;
    try {
      await ref.read(scanControllerProvider.notifier).identifyFromCameraImage(
            frame,
            sensorOrientation: sensorOrientation,
          );
      if (!mounted) return;
      final elapsedMs = DateTime.now().millisecondsSinceEpoch - startMs;
      // ignore: avoid_print
      print('[Scan] frame processed in ${elapsedMs} ms');
    } catch (e, st) {
      // ignore: avoid_print
      print('[Scan] frame error: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  void _togglePause() {
    setState(() => _paused = !_paused);
  }

  @override
  Widget build(BuildContext context) {
    final cameras = ref.watch(_camerasProvider);
    final embedder = ref.watch(embedderServiceProvider);
    final indexAsync = ref.watch(localIndexProvider);
    final scanState = ref.watch(scanControllerProvider);

    final ready = embedder is AsyncData && indexAsync is AsyncData;

    return Scaffold(
      appBar: AppBar(title: const Text('Karte scannen')),
      body: cameras.when(
        data: (list) {
          if (list.isEmpty) {
            return const _Centered('Keine Kamera gefunden.');
          }
          // Lazy-init Controller via Future.microtask in build
          // (kein setState in build).
          if (_controller == null) {
            Future.microtask(() => _ensureController(list));
          }
          final ctrl = _controller;
          if (ctrl == null || !ctrl.value.isInitialized) {
            return const _Centered('Kamera wird initialisiert...');
          }
          return Stack(
            children: [
              Positioned.fill(child: CameraPreview(ctrl)),
              const _CardFrameOverlay(),
              Positioned(
                left: 12,
                right: 12,
                bottom: 24,
                child: _LiveMatchPanel(
                  embedder: embedder,
                  index: indexAsync,
                  paused: _paused,
                  busy: _busy,
                  scanState: scanState,
                ),
              ),
            ],
          );
        },
        loading: () => const _Centered('Kameras werden gesucht...'),
        error: (e, _) => _Centered('Kamera-Fehler: $e'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: !ready ? null : _togglePause,
        icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
        label: Text(_paused ? 'Fortsetzen' : 'Pause'),
      ),
    );
  }
}

class _CardFrameOverlay extends StatelessWidget {
  const _CardFrameOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Center(
        child: AspectRatio(
          aspectRatio: 245 / 337,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 32),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white70, width: 2),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
      ),
    );
  }
}

class _LiveMatchPanel extends StatelessWidget {
  const _LiveMatchPanel({
    required this.embedder,
    required this.index,
    required this.paused,
    required this.busy,
    required this.scanState,
  });

  final AsyncValue<EmbedderService> embedder;
  final AsyncValue<LocalIndex> index;
  final bool paused;
  final bool busy;
  final AsyncValue<ScanResult?> scanState;

  @override
  Widget build(BuildContext context) {
    // Setup-/Fehler-States blockieren das Live-Match-Panel komplett.
    if (embedder.hasError) {
      return _StatusText('Modell-Fehler: ${embedder.error}');
    }
    if (index.hasError) {
      return _StatusText('Index-Fehler: ${index.error}');
    }
    if (embedder is! AsyncData) {
      return const _StatusText('Modell wird geladen...');
    }
    if (index is! AsyncData) {
      return const _StatusText('Karten-Index wird geladen...');
    }
    if (paused) {
      return const _StatusText('Pausiert. Tippe auf Fortsetzen.');
    }
    if (scanState.hasError) {
      return _StatusText('Fehler: ${scanState.error}');
    }

    final result = scanState.valueOrNull;
    if (result == null || result.matches.isEmpty) {
      // Wir haben (noch) keinen sinnvollen Match -> kurzer Hinweis-Bar.
      if (result != null && result.sharpness > 0 && result.sharpness < 80) {
        return const _StatusText('Bild verschwommen - Kamera ruhig halten.');
      }
      if (result != null && result.topSimilarity > 0) {
        final pct = (result.topSimilarity * 100).toStringAsFixed(0);
        return _StatusText('Suche... beste Naeherung $pct %');
      }
      return const _StatusText(
        'Karte ins Raster halten - wird automatisch erkannt.',
      );
    }

    return _MatchCard(
      match: result.matches.first,
      confirmed: result.confirmed,
      busy: busy,
    );
  }
}

/// Vollwertige Karten-Anzeige direkt im Live-Stream: Cover-Thumb,
/// Name, Set/Number/Sprache, Confidence-Bar, Tap -> Detailseite.
/// Bei `confirmed` zusaetzlich gruener Akzent + Badge, damit der
/// Nutzer sofort sieht dass die Karte in den Verlauf uebernommen wurde.
class _MatchCard extends StatelessWidget {
  const _MatchCard({
    required this.match,
    required this.confirmed,
    required this.busy,
  });

  final IdentifyMatch match;
  final bool confirmed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final pct = (match.similarity * 100).toStringAsFixed(0);
    final accent = confirmed ? Colors.greenAccent.shade400 : Colors.white70;
    return Material(
      color: Colors.black.withValues(alpha: 0.72),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => context.push('/card/${match.cardId}'),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent, width: confirmed ? 2 : 1),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 56,
                  height: 78,
                  child: match.imageUrl == null
                      ? const ColoredBox(color: Colors.white12)
                      : CachedNetworkImage(
                          imageUrl: match.imageUrl!,
                          fit: BoxFit.cover,
                          placeholder: (_, __) =>
                              const ColoredBox(color: Colors.white12),
                          errorWidget: (_, __, ___) =>
                              const Icon(Icons.broken_image_outlined,
                                  color: Colors.white54),
                        ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            match.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (confirmed) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.check_circle,
                              color: accent, size: 18),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${match.setCode.toUpperCase()} #${match.number} '
                      '\u00B7 ${match.language.toUpperCase()}'
                      '${match.rarity != null ? '  \u00B7 ${match.rarity}' : ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.78),
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: LinearProgressIndicator(
                              value: match.similarity.clamp(0.0, 1.0),
                              minHeight: 5,
                              backgroundColor: Colors.white24,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(accent),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 36,
                          child: Text(
                            '$pct%',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (confirmed)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'In Verlauf gespeichert  \u00B7  Tippen fuer Details',
                          style: TextStyle(
                            color: accent,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      )
                    else if (busy)
                      const Padding(
                        padding: EdgeInsets.only(top: 4),
                        child: Text(
                          'Karte ruhig halten...',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Text(
          text,
          style: const TextStyle(color: Colors.white),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(text)));
}
