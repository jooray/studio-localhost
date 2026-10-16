import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/settings.dart';
import '../core/update_check.dart';
import '../core/version.dart';
import 'widgets.dart';

Future<void> showAboutYue(BuildContext context) {
  return showDialog(
    context: context,
    builder: (ctx) {
      final t = Theme.of(ctx).textTheme;
      return Dialog(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Image.asset('assets/icon-macos-1024.png', width: 128, height: 128),
              const SizedBox(height: 12),
              Text(appName, style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w600)),
              Text('Version $appVersion (build $appBuild)', style: t.bodyMedium),
              const SizedBox(height: 16),
              Text(
                'Local music generation with YuE2-3B: style and lyrics in, 48 kHz stereo songs out, '
                'on your own machine. Engines: mlx-Yue (MLX, Apple Silicon) and yue2.cpp (ggml: Metal, CUDA, Vulkan, CPU).',
                textAlign: TextAlign.center,
                style: t.bodyMedium,
              ),
              const SizedBox(height: 12),
              Text(
                'Model: YuE2 by M-A-P, weights CC BY-NC 4.0 (non-commercial).\n'
                'mlx-Yue by vanch007 (Apache-2.0) · yue2.cpp by ServeurpersoCom (MIT).\n'
                'Sibling app: YuE2 Pocket (Android).',
                textAlign: TextAlign.center,
                style: t.bodySmall,
              ),
              const SizedBox(height: 18),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Builder(builder: (bctx) {
                  final s = bctx.read<Settings>();
                  return OutlinedButton(
                    onPressed: s.updateUrl.isEmpty
                        ? null
                        : () async {
                            try {
                              final u = await checkForUpdate(s.updateUrl);
                              if (bctx.mounted) showSnack(bctx, u.newer ? 'Version ${u.latest} is available' : 'You have the latest version');
                            } catch (e) {
                              if (bctx.mounted) showSnack(bctx, 'Update check failed: $e', error: true);
                            }
                          },
                    child: Text(s.updateUrl.isEmpty ? 'Update check: no URL set' : 'Check for updates'),
                  );
                }),
                const SizedBox(width: 12),
                FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
              ]),
            ]),
          ),
        ),
      );
    },
  );
}
