import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_updater.dart';

/// Banner oben auf dem HomeScreen, falls eine neuere App-Version verfuegbar ist.
/// Stillbleibend wenn kein Token, kein Update oder Check fehlgeschlagen.
class UpdateBanner extends ConsumerStatefulWidget {
  const UpdateBanner({super.key});

  @override
  ConsumerState<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends ConsumerState<UpdateBanner> {
  UpdateDownloadState? _download;
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final asyncStatus = ref.watch(updateCheckProvider);

    return asyncStatus.when(
      loading: () => _DiagnosticBanner(
        color: theme.colorScheme.surfaceContainerHighest,
        textColor: theme.colorScheme.onSurface,
        text: 'Update-Check laeuft...',
        onDismiss: () => setState(() => _dismissed = true),
      ),
      error: (err, __) => _DiagnosticBanner(
        color: theme.colorScheme.errorContainer,
        textColor: theme.colorScheme.onErrorContainer,
        text: 'Update-Check fehlgeschlagen: $err',
        onDismiss: () => setState(() => _dismissed = true),
      ),
      data: (status) {
        if (status is UpdateStatusError) {
          return _DiagnosticBanner(
            color: theme.colorScheme.errorContainer,
            textColor: theme.colorScheme.onErrorContainer,
            text: 'Updater: ${status.message}',
            onDismiss: () => setState(() => _dismissed = true),
          );
        }
        if (status is UpdateStatusUpToDate) {
          return _DiagnosticBanner(
            color: theme.colorScheme.surfaceContainerHighest,
            textColor: theme.colorScheme.onSurface,
            text: 'App aktuell (v${status.currentVersion})',
            onDismiss: () => setState(() => _dismissed = true),
          );
        }
        if (status is! UpdateStatusAvailable) return const SizedBox.shrink();
        final dl = _download;
        return Container(
          width: double.infinity,
          color: theme.colorScheme.primaryContainer,
          padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.system_update,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Update verfuegbar: v${status.latestVersion}',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: theme.colorScheme.onPrimaryContainer,
                    onPressed: () => setState(() => _dismissed = true),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Installiert: v${status.currentVersion}  -  Download: ${(status.assetSize / (1024 * 1024)).toStringAsFixed(1)} MB',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              if (dl != null && dl.isDownloading) ...[
                const SizedBox(height: 8),
                LinearProgressIndicator(value: dl.progress),
                const SizedBox(height: 4),
                Text(
                  'Lade Update herunter... ${((dl.progress ?? 0) * 100).toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
              ],
              if (dl?.error != null) ...[
                const SizedBox(height: 8),
                Text(
                  'Fehler: ${dl!.error}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (status.releaseNotes.isNotEmpty)
                    TextButton(
                      onPressed: () => _showReleaseNotes(context, status),
                      child: const Text('Details'),
                    ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.download),
                    label: Text(dl?.isDownloading ?? false
                        ? 'Laedt...'
                        : 'Installieren'),
                    onPressed: (dl?.isDownloading ?? false)
                        ? null
                        : () => _startDownload(status),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _startDownload(UpdateStatusAvailable status) async {
    final updater = ref.read(appUpdaterProvider);
    setState(() => _download = const UpdateDownloadState(progress: 0));
    await for (final state in updater.downloadAndInstall(status)) {
      if (!mounted) return;
      setState(() => _download = state);
    }
  }

  void _showReleaseNotes(BuildContext context, UpdateStatusAvailable status) {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Release v${status.latestVersion}'),
        content: SingleChildScrollView(
          child: Text(status.releaseNotes),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Schliessen'),
          ),
        ],
      ),
    );
  }
}

class _DiagnosticBanner extends StatelessWidget {
  const _DiagnosticBanner({
    required this.color,
    required this.textColor,
    required this.text,
    required this.onDismiss,
  });

  final Color color;
  final Color textColor;
  final String text;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: textColor, size: 18),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: textColor, fontSize: 13),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: textColor,
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
