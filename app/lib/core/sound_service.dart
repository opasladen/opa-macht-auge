// app/lib/core/sound_service.dart
/// Spielt kurze Effekt-Sounds aus dem Asset-Bundle.
///
/// Wird via Riverpod-Provider als Singleton bereitgestellt, damit der
/// `AudioPlayer` nur einmal angelegt wird und keine Latenz beim ersten
/// Scan-Hit entsteht.
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class SoundService {
  SoundService() : _player = AudioPlayer() {
    _player.setReleaseMode(ReleaseMode.stop);
    // Player-Modus = LowLatency damit fixe kurze SFX nicht buffern.
    // ignore: discarded_futures
    _player.setPlayerMode(PlayerMode.lowLatency).then((_) {
      // ignore: avoid_print
      print('[SoundService] PlayerMode.lowLatency aktiv');
    }).catchError((Object e) {
      // ignore: avoid_print
      print('[SoundService] setPlayerMode failed: $e');
    });
    // KEIN setSource hier - das hat auf einigen Geraeten in v0.1.9 den
    // Player in einen halboffenen Zustand gebracht, sodass play() spaeter
    // still scheiterte. Wir laden die Quelle nun nur per play() bei
    // Bedarf - audioplayers cached den Asset intern.
  }

  final AudioPlayer _player;

  /// Spielt den Success-Sound. Wird beim ersten Confirmed-Hit pro Karte
  /// aufgerufen. Fehler werden geloggt aber nicht eskaliert - ein
  /// fehlender Audio-Output darf die Scan-Pipeline nicht blockieren.
  Future<void> playSuccess() async {
    try {
      await _player.stop();
      await _player.setVolume(1.0);
      await _player.play(AssetSource('sounds/scan_success.mp3'));
      // ignore: avoid_print
      print('[SoundService] play() OK');
    } catch (e, st) {
      // ignore: avoid_print
      print('[SoundService] play() FAILED: $e\n$st');
    }
  }

  Future<void> dispose() async {
    await _player.dispose();
  }
}

final soundServiceProvider = Provider<SoundService>((ref) {
  final svc = SoundService();
  ref.onDispose(svc.dispose);
  return svc;
});
