import 'package:flutter/material.dart';

import 'update_banner.dart';

/// Start-/Home-Screen. Beim App-Start landet der Nutzer hier statt
/// direkt im Kamera-Scanner; gescannt wird erst nach explizitem
/// Tab-Wechsel ueber die NavigationBar.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const UpdateBanner(),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(
                        aspectRatio: 1,
                        child: Image.asset(
                          'assets/branding/opa_logo.png',
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Icon(
                            Icons.image_outlined,
                            size: 160,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      Text(
                        'Opa macht Auge',
                        style: theme.textTheme.headlineMedium,
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Sammelkarten-Scanner',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 32),
                      Text(
                        'Tippe unten auf "Scannen", um eine Karte zu erfassen.',
                        style: theme.textTheme.bodyMedium,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
