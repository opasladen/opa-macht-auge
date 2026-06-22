import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Build-time GitHub Token. Wird in CI via `--dart-define=GITHUB_RELEASE_TOKEN=...`
/// gesetzt. Bei lokalen Debug-Builds ist es leer; der Updater faellt dann still aus.
const String _kGithubToken = String.fromEnvironment('GITHUB_RELEASE_TOKEN');

/// Repo, der nach Releases gefragt wird.
const String _kRepoOwner = 'opasladen';
const String _kRepoName = 'opa-macht-auge';

/// Status des Update-Checks.
sealed class UpdateStatus {
  const UpdateStatus();
}

class UpdateStatusUnknown extends UpdateStatus {
  const UpdateStatusUnknown();
}

class UpdateStatusUpToDate extends UpdateStatus {
  const UpdateStatusUpToDate(this.currentVersion);
  final String currentVersion;
}

class UpdateStatusAvailable extends UpdateStatus {
  const UpdateStatusAvailable({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    required this.assetUrl,
    required this.assetName,
    required this.assetSize,
  });

  final String currentVersion;
  final String latestVersion;
  final String releaseNotes;
  final String assetUrl;
  final String assetName;
  final int assetSize;
}

class UpdateStatusError extends UpdateStatus {
  const UpdateStatusError(this.message);
  final String message;
}

/// Aktueller Download-Fortschritt 0.0..1.0; null = idle / nicht gestartet.
class UpdateDownloadState {
  const UpdateDownloadState({this.progress, this.error});
  final double? progress;
  final String? error;

  bool get isDownloading => progress != null && progress! < 1.0;
}

/// Service der GitHub-Releases pollt und APKs herunterlaedt.
class AppUpdater {
  AppUpdater({Dio? dio, Logger? logger})
      : _dio = dio ?? Dio(),
        _log = logger ?? Logger();

  final Dio _dio;
  final Logger _log;

  static const String _apiBase = 'https://api.github.com';

  bool get isEnabled => _kGithubToken.isNotEmpty;

  Map<String, String> get _authHeaders => {
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        if (_kGithubToken.isNotEmpty) 'Authorization': 'Bearer $_kGithubToken',
      };

  /// Pollt `/releases/latest` und vergleicht Versionen.
  Future<UpdateStatus> check() async {
    // ignore: avoid_print
    print('[AppUpdater] check() start, tokenLen=${_kGithubToken.length}');
    if (!isEnabled) {
      // ignore: avoid_print
      print('[AppUpdater] DISABLED: kein GITHUB_RELEASE_TOKEN im Build.');
      return const UpdateStatusError('Kein Update-Token im Build');
    }
    try {
      final info = await PackageInfo.fromPlatform();
      final currentVersion = info.version;
      final url = '$_apiBase/repos/$_kRepoOwner/$_kRepoName/releases/latest';
      // ignore: avoid_print
      print('[AppUpdater] GET $url current=$currentVersion');
      final resp = await _dio.get<Map<String, dynamic>>(
        url,
        options: Options(
          headers: _authHeaders,
          responseType: ResponseType.json,
          validateStatus: (s) => s != null && s < 500,
        ),
      );
      // ignore: avoid_print
      print('[AppUpdater] HTTP ${resp.statusCode}');
      if (resp.statusCode == 401 || resp.statusCode == 403) {
        return UpdateStatusError(
          'Token abgelehnt (HTTP ${resp.statusCode})',
        );
      }
      if (resp.statusCode == 404) {
        return UpdateStatusError(
          'Kein Release gefunden (HTTP 404, Token-Scope?)',
        );
      }
      if (resp.statusCode != 200 || resp.data == null) {
        return UpdateStatusError(
          'GitHub-Release-Lookup fehlgeschlagen (HTTP ${resp.statusCode}).',
        );
      }
      final data = resp.data!;
      final tag = (data['tag_name'] as String?) ?? '';
      final latestVersion = tag.startsWith('v') ? tag.substring(1) : tag;
      // ignore: avoid_print
      print('[AppUpdater] latest=$latestVersion current=$currentVersion');
      final body = (data['body'] as String?) ?? '';
      final assets = (data['assets'] as List<dynamic>? ?? []);
      // Bevorzugt: arm64-v8a-APK (moderne Geraete), Fallback erste APK.
      Map<String, dynamic>? asset;
      for (final a in assets) {
        final m = a as Map<String, dynamic>;
        final name = m['name'] as String? ?? '';
        if (name.endsWith('.apk') && name.contains('arm64-v8a')) {
          asset = m;
          break;
        }
      }
      asset ??= assets
          .cast<Map<String, dynamic>>()
          .firstWhere(
            (m) => (m['name'] as String? ?? '').endsWith('.apk'),
            orElse: () => <String, dynamic>{},
          );
      if (asset.isEmpty) {
        return UpdateStatusUpToDate(currentVersion);
      }
      if (!_isNewer(currentVersion, latestVersion)) {
        return UpdateStatusUpToDate(currentVersion);
      }
      return UpdateStatusAvailable(
        currentVersion: currentVersion,
        latestVersion: latestVersion,
        releaseNotes: body,
        assetUrl: asset['url'] as String, // API-URL (mit Auth)
        assetName: asset['name'] as String,
        assetSize: (asset['size'] as num).toInt(),
      );
    } on DioException catch (e) {
      // ignore: avoid_print
      print('[AppUpdater] DioException: ${e.message}');
      _log.e('AppUpdater check failed: ${e.message}');
      return UpdateStatusError(e.message ?? 'Netzwerkfehler');
    } catch (e, st) {
      // ignore: avoid_print
      print('[AppUpdater] Exception: $e');
      _log.e('AppUpdater check failed', error: e, stackTrace: st);
      return UpdateStatusError(e.toString());
    }
  }

  /// Laedt die APK herunter und oeffnet den Package-Installer.
  Stream<UpdateDownloadState> downloadAndInstall(
      UpdateStatusAvailable update) async* {
    try {
      final dir = await getApplicationCacheDirectory();
      final outDir = Directory(p.join(dir.path, 'updates'));
      if (!await outDir.exists()) {
        await outDir.create(recursive: true);
      }
      final outFile = File(p.join(outDir.path, update.assetName));
      if (await outFile.exists()) {
        await outFile.delete();
      }
      _log.i('AppUpdater: download ${update.assetUrl} -> ${outFile.path}');
      final controller = _ProgressBus();
      final downloadFuture = _dio.download(
        update.assetUrl,
        outFile.path,
        options: Options(
          headers: {
            ..._authHeaders,
            // Asset-Download per API: Accept octet-stream loest 302 -> S3 aus
            // und der dio folgt redirects automatisch.
            'Accept': 'application/octet-stream',
          },
          followRedirects: true,
          responseType: ResponseType.bytes,
        ),
        onReceiveProgress: (count, total) {
          if (total > 0) {
            controller.emit(count / total);
          }
        },
      );
      yield const UpdateDownloadState(progress: 0);
      await for (final p in controller.stream(downloadFuture)) {
        yield UpdateDownloadState(progress: p);
      }
      yield const UpdateDownloadState(progress: 1.0);
      _log.i('AppUpdater: open ${outFile.path}');
      final result = await OpenFilex.open(outFile.path);
      if (result.type != ResultType.done) {
        yield UpdateDownloadState(
          progress: 1.0,
          error: 'Konnte Installer nicht oeffnen: ${result.message}',
        );
      }
    } catch (e, st) {
      _log.e('AppUpdater downloadAndInstall failed', error: e, stackTrace: st);
      yield UpdateDownloadState(error: e.toString());
    }
  }

  /// Semver-Vergleich (Major.Minor.Patch), Nicht-Numerisches faellt auf 0 zurueck.
  static bool _isNewer(String current, String latest) {
    final c = _parseSemver(current);
    final l = _parseSemver(latest);
    for (var i = 0; i < 3; i++) {
      if (l[i] > c[i]) return true;
      if (l[i] < c[i]) return false;
    }
    return false;
  }

  static List<int> _parseSemver(String s) {
    final parts = s.split('+').first.split('.');
    return [
      int.tryParse(parts.elementAtOrNull(0) ?? '0') ?? 0,
      int.tryParse(parts.elementAtOrNull(1) ?? '0') ?? 0,
      int.tryParse(parts.elementAtOrNull(2) ?? '0') ?? 0,
    ];
  }
}

class _ProgressBus {
  double _last = 0;
  bool _done = false;

  void emit(double p) {
    if (p > _last) _last = p;
  }

  Stream<double> stream(Future<dynamic> until) async* {
    while (!_done) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      yield _last;
      if (_last >= 1.0) break;
    }
    await until;
    _done = true;
  }
}

final appUpdaterProvider = Provider<AppUpdater>((ref) => AppUpdater());

/// One-shot Future: checkt beim App-Start einmal.
final updateCheckProvider = FutureProvider<UpdateStatus>((ref) {
  return ref.read(appUpdaterProvider).check();
});

extension<T> on List<T> {
  T? elementAtOrNull(int index) => index >= 0 && index < length ? this[index] : null;
}
