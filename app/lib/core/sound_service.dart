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
    _player.setPlayerMode(PlayerMode.lowLatency);
    // Quelle vorab laden, damit der erste Scan keine Decode-Latenz hat.
    // ignore: discarded_futures
    _player.setSource(AssetSource('sounds/scan_success.mp3')).catchError((_) {});
  }

  final AudioPlayer _player;

  /// Spielt den Success-Sound. Wird beim ersten Confirmed-Hit pro Karte
  /// aufgerufen. Fehler werden bewusst geschluckt – ein fehlender
  /// Audio-Output darf die Scan-Pipeline nicht blockieren.
  Future<void> playSuccess() async {
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/scan_success.mp3'));
    } catch (_) {
      // best effort
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
