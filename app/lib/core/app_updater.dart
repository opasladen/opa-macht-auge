import 'dart:convert';
import 'dart:io';

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
  AppUpdater({Logger? logger}) : _log = logger ?? Logger();

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
    // Workaround: dart:io HttpClient hat auf manchen Android-Geraeten DNS-
    // Probleme beim ersten Call. Vorab explizit aufloesen + bis zu 3x retry.
    String? resolvedIp;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final addrs = await InternetAddress.lookup(
          'api.github.com',
          type: InternetAddressType.IPv4,
        ).timeout(const Duration(seconds: 5));
        if (addrs.isNotEmpty) {
          resolvedIp = addrs.first.address;
          // ignore: avoid_print
          print('[AppUpdater] DNS attempt $attempt -> $resolvedIp');
          break;
        }
      } catch (e) {
        // ignore: avoid_print
        print('[AppUpdater] DNS attempt $attempt failed: $e');
        if (attempt < 3) {
          await Future<void>.delayed(Duration(seconds: attempt));
        }
      }
    }
    if (resolvedIp == null) {
      return const UpdateStatusError('DNS api.github.com fehlgeschlagen (3x)');
    }
    try {
      final info = await PackageInfo.fromPlatform();
      final currentVersion = info.version;
      final url = '$_apiBase/repos/$_kRepoOwner/$_kRepoName/releases/latest';
      // ignore: avoid_print
      print('[AppUpdater] GET $url current=$currentVersion');
      // dart:io HttpClient direkt nutzen (umgeht dio-internen DNS-Cache,
      // der auf manchen Geraeten "Failed host lookup" wirft obwohl
      // InternetAddress.lookup eben noch geklappt hat).
      final pinnedIp = resolvedIp;
      // ignore: avoid_print
      print('[AppUpdater] SecureSocket.connect $pinnedIp:443 sni=api.github.com');
      late final int statusCode;
      late String responseBody;
      SecureSocket? sock;
      try {
        final tcpSocket = await Socket.connect(
          pinnedIp,
          443,
          timeout: const Duration(seconds: 15),
        );
        // ignore: avoid_print
        print('[AppUpdater] TCP connected, upgrading TLS sni=api.github.com');
        sock = await SecureSocket.secure(
          tcpSocket,
          host: 'api.github.com',
          supportedProtocols: const ['http/1.1'],
        );
        // ignore: avoid_print
        print('[AppUpdater] SSL connected, peerCert subject=${sock.peerCertificate?.subject}');
        // Manuell HTTP/1.1 sprechen
        final path = '/repos/$_kRepoOwner/$_kRepoName/releases/latest';
        final reqLines = <String>[
          'GET $path HTTP/1.1',
          'Host: api.github.com',
          'Accept: application/vnd.github+json',
          'X-GitHub-Api-Version: 2022-11-28',
          'Authorization: Bearer $_kGithubToken',
          'User-Agent: opa-macht-auge/$_kRepoName',
          'Connection: close',
          '',
          '',
        ];
        sock.add(utf8.encode(reqLines.join('\r\n')));
        await sock.flush();
        // ignore: avoid_print
        print('[AppUpdater] request sent');
        final bytes = await sock
            .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk))
            .timeout(const Duration(seconds: 20));
        final raw = utf8.decode(bytes, allowMalformed: true);
        final headerEnd = raw.indexOf('\r\n\r\n');
        if (headerEnd < 0) {
          throw const FormatException('Keine HTTP-Header gefunden');
        }
        final headerBlock = raw.substring(0, headerEnd);
        responseBody = raw.substring(headerEnd + 4);
        final firstLine = headerBlock.split('\r\n').first;
        // "HTTP/1.1 200 OK"
        final parts = firstLine.split(' ');
        statusCode = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
        // ignore: avoid_print
        print('[AppUpdater] resp status=$statusCode bodyLen=${responseBody.length}');
        // Falls chunked transfer-encoding: vereinfacht dechunken (best-effort)
        if (headerBlock.toLowerCase().contains('transfer-encoding: chunked')) {
          responseBody = _dechunk(responseBody);
        }
      } finally {
        await sock?.close();
      }
      // ignore: avoid_print
      print('[AppUpdater] HTTP $statusCode');
      if (statusCode == 401 || statusCode == 403) {
        return UpdateStatusError(
          'Token abgelehnt (HTTP $statusCode)',
        );
      }
      if (statusCode == 404) {
        return UpdateStatusError(
          'Kein Release gefunden (HTTP 404, Token-Scope?)',
        );
      }
      if (statusCode != 200 || responseBody.isEmpty) {
        return UpdateStatusError(
          'GitHub-Release-Lookup fehlgeschlagen (HTTP $statusCode).',
        );
      }
      final data = jsonDecode(responseBody) as Map<String, dynamic>;
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
      yield const UpdateDownloadState(progress: 0);
      // Manuelle TLS+HTTP-Implementation (siehe check() Doku), folgt
      // 3xx-Redirects (GitHub redirected zu objects.githubusercontent.com).
      final progressStream = _downloadStreamed(
        Uri.parse(update.assetUrl),
        {
          ..._authHeaders,
          // Asset-Download per API: Accept octet-stream loest 302 -> S3 aus.
          'Accept': 'application/octet-stream',
        },
        outFile,
      );
      await for (final p in progressStream) {
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
      // ignore: avoid_print
      print('[AppUpdater] download failed: $e');
      yield UpdateDownloadState(error: e.toString());
    }
  }

  /// Manueller HTTPS-Download mit Redirect-Support und Progress-Events.
  /// Emittiert Werte 0.0..1.0. Wirft bei Fehler.
  Stream<double> _downloadStreamed(
    Uri uri,
    Map<String, String> headers,
    File outFile, {
    int redirectsLeft = 5,
  }) async* {
    // ignore: avoid_print
    print('[AppUpdater] download GET ${uri.host}${uri.path}');
    final addrs = await InternetAddress.lookup(
      uri.host,
      type: InternetAddressType.IPv4,
    ).timeout(const Duration(seconds: 10));
    if (addrs.isEmpty) {
      throw SocketException('DNS ${uri.host} ohne Antwort');
    }
    final ip = addrs.first.address;
    final port = uri.port == 0 ? 443 : uri.port;
    final tcp = await Socket.connect(
      ip,
      port,
      timeout: const Duration(seconds: 15),
    );
    final tls = await SecureSocket.secure(
      tcp,
      host: uri.host,
      supportedProtocols: const ['http/1.1'],
    );
    final reqBuf = StringBuffer()
      ..write('GET ${uri.path}${uri.hasQuery ? "?${uri.query}" : ""} HTTP/1.1\r\n')
      ..write('Host: ${uri.host}\r\n')
      ..write('Connection: close\r\n')
      ..write('User-Agent: opa-macht-auge\r\n');
    for (final h in headers.entries) {
      reqBuf.write('${h.key}: ${h.value}\r\n');
    }
    reqBuf.write('\r\n');
    tls.add(utf8.encode(reqBuf.toString()));
    await tls.flush();
    // Single-subscription stream → ein einziger Consumer mit Phase-Machine.
    // Phase 1 (header): bytes akkumulieren bis \r\n\r\n.
    // Phase 2 (body): an outFile streamen, Progress emitten.
    final headerBytes = <int>[];
    var headerEnd = -1;
    IOSink? sink;
    var received = 0;
    int contentLength = -1;
    int statusCode = 0;
    String? locationHeader;
    var redirected = false;
    try {
      await for (final chunk in tls) {
        if (headerEnd < 0) {
          headerBytes.addAll(chunk);
          for (var i = 3; i < headerBytes.length; i++) {
            if (headerBytes[i - 3] == 13 &&
                headerBytes[i - 2] == 10 &&
                headerBytes[i - 1] == 13 &&
                headerBytes[i] == 10) {
              headerEnd = i + 1;
              break;
            }
          }
          if (headerEnd < 0) continue;
          // Parsen
          final headerOnly = headerBytes.sublist(0, headerEnd - 4);
          final bodyStart = headerBytes.sublist(headerEnd);
          final headerText =
              utf8.decode(headerOnly, allowMalformed: true);
          final lines = headerText.split('\r\n');
          final firstLine = lines.first;
          final parts = firstLine.split(' ');
          statusCode =
              parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
          for (final line in lines.skip(1)) {
            final colon = line.indexOf(':');
            if (colon < 0) continue;
            final key = line.substring(0, colon).trim().toLowerCase();
            final val = line.substring(colon + 1).trim();
            if (key == 'location') locationHeader = val;
            if (key == 'content-length') {
              contentLength = int.tryParse(val) ?? -1;
            }
          }
          // ignore: avoid_print
          print('[AppUpdater] download status=$statusCode len=$contentLength');
          if (statusCode >= 300 && statusCode < 400 && locationHeader != null) {
            redirected = true;
            break; // closes stream below; recurse outside
          }
          if (statusCode != 200) {
            throw HttpException(
              'Download fehlgeschlagen: HTTP $statusCode',
              uri: uri,
            );
          }
          // Body-Phase initialisieren
          sink = outFile.openWrite();
          if (bodyStart.isNotEmpty) {
            sink.add(bodyStart);
            received += bodyStart.length;
            if (contentLength > 0) {
              yield (received / contentLength).clamp(0.0, 1.0);
            }
          }
        } else {
          // Body-Phase
          sink!.add(chunk);
          received += chunk.length;
          if (contentLength > 0) {
            yield (received / contentLength).clamp(0.0, 1.0);
          }
        }
      }
    } finally {
      if (sink != null) {
        await sink.flush();
        await sink.close();
      }
      try {
        await tls.close();
      } catch (_) {}
    }
    if (redirected) {
      if (redirectsLeft <= 0) {
        throw const SocketException('Zu viele Redirects');
      }
      final nextUri = Uri.parse(locationHeader!);
      // Bei Cross-Origin-Redirect (z.B. zu objects.githubusercontent.com)
      // Auth-Header weg, denn S3-URL hat signed Token im Query.
      final nextHeaders = nextUri.host == uri.host
          ? headers
          : <String, String>{'Accept': '*/*'};
      yield* _downloadStreamed(
        nextUri,
        nextHeaders,
        outFile,
        redirectsLeft: redirectsLeft - 1,
      );
      return;
    }
    if (headerEnd < 0) {
      throw const SocketException('Antwort vor Headern abgebrochen');
    }
    yield 1.0;
  }

  /// Best-effort dechunking fuer Transfer-Encoding: chunked
  static String _dechunk(String body) {
    final sb = StringBuffer();
    var i = 0;
    while (i < body.length) {
      final lineEnd = body.indexOf('\r\n', i);
      if (lineEnd < 0) break;
      final sizeHex = body.substring(i, lineEnd).split(';').first.trim();
      final size = int.tryParse(sizeHex, radix: 16);
      if (size == null || size == 0) break;
      final chunkStart = lineEnd + 2;
      if (chunkStart + size > body.length) break;
      sb.write(body.substring(chunkStart, chunkStart + size));
      i = chunkStart + size + 2;
    }
    return sb.toString();
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

final appUpdaterProvider = Provider<AppUpdater>((ref) => AppUpdater());

/// One-shot Future: checkt beim App-Start einmal.
final updateCheckProvider = FutureProvider<UpdateStatus>((ref) {
  return ref.read(appUpdaterProvider).check();
});

extension<T> on List<T> {
  T? elementAtOrNull(int index) => index >= 0 && index < length ? this[index] : null;
}
