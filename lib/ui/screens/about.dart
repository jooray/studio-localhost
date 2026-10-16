import 'package:flutter/material.dart';

import '../../core/app_info.dart';

Future<void> showAboutStudio(BuildContext context) => showDialog(
      context: context,
      builder: (ctx) {
        final t = Theme.of(ctx).textTheme;
        return AlertDialog(
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Image.asset('assets/icon-macos-1024.png', width: 96, height: 96),
            const SizedBox(height: 12),
            Text(appName, style: t.titleLarge, textAlign: TextAlign.center),
            Text('Version $appVersion ($appBuild)', style: t.bodyMedium),
            const SizedBox(height: 8),
            Text('$appLicence licence · $appSourceUrl', style: t.bodySmall, textAlign: TextAlign.center),
          ]),
          actions: [
            TextButton(onPressed: () => showLicensePage(context: ctx, applicationName: appName, applicationVersion: appVersion), child: const Text('Licences')),
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
          ],
        );
      },
    );
