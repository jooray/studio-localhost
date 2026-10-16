import 'dart:convert';
import 'dart:io';

import 'app_info.dart';

class UpdateInfo {
  UpdateInfo(this.latest, this.newer, {this.url, this.notes});
  final String latest;
  final bool newer;
  final String? url;
  final String? notes;
}

/// Fetch a version from [url]: either plain text ("0.4.0") or JSON
/// ({"version": "0.4.0", "url": "...", "notes": "..."}). Off unless a URL is configured.
Future<UpdateInfo> checkForUpdate(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set(HttpHeaders.userAgentHeader, 'LocalhostRecordingStudio/$appVersion');
    final res = await req.close().timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final body = (await res.transform(utf8.decoder).join()).trim();
    String version = body;
    String? link, notes;
    if (body.startsWith('{')) {
      final m = jsonDecode(body) as Map<String, dynamic>;
      version = (m['version'] ?? m['latest'] ?? '').toString();
      link = m['url']?.toString();
      notes = m['notes']?.toString();
    }
    version = version.split('\n').first.trim();
    if (!RegExp(r'^[vV]?\d+(\.\d+)*').hasMatch(version)) {
      throw FormatException('No version string at $url');
    }
    return UpdateInfo(version, compareVersions(version, appVersion) > 0, url: link, notes: notes);
  } finally {
    client.close(force: true);
  }
}
