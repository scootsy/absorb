import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// ─── EpubService ─────────────────────────────────────────────────────────

class EpubService {
  /// Download an EPUB file (if not cached) and return its local path.
  ///
  /// Uses [getApplicationSupportDirectory] so the cache survives across
  /// app launches and is not purged by the OS (unlike temp).
  ///
  /// [onStatus] is called with a human-readable status string so the UI
  /// can show progress.
  ///
  /// Returns null on any failure.
  static Future<String?> downloadEpub({
    required String itemId,
    required String fileIno,
    required String baseUrl,
    required Map<String, String> headers,
    void Function(String status)? onStatus,
  }) async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      final safeId = itemId.replaceAll(RegExp(r'[^\w]'), '_');
      final safeIno = fileIno.replaceAll(RegExp(r'[^\w]'), '_');
      final epubFile = File(p.join(supportDir.path, '${safeId}_$safeIno.epub'));

      if (!epubFile.existsSync()) {
        onStatus?.call('Downloading eBook…');
        final cleanBase =
            baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
        final url = '$cleanBase/api/items/$itemId/file/$fileIno';

        final request = http.Request('GET', Uri.parse(url));
        request.followRedirects = false;
        headers.forEach((k, v) => request.headers[k] = v);
        final client = http.Client();
        try {
          var response = await client.send(request)
              .timeout(const Duration(seconds: 30));
          var redirects = 0;
          while ([301, 302, 303, 307, 308].contains(response.statusCode) &&
              redirects < 5) {
            final location = response.headers['location'];
            if (location == null) break;
            final redirectUri = Uri.parse(url).resolve(location);
            final rReq = http.Request('GET', redirectUri);
            headers.forEach((k, v) => rReq.headers[k] = v);
            rReq.followRedirects = false;
            response = await client.send(rReq)
                .timeout(const Duration(seconds: 30));
            redirects++;
          }
          if (response.statusCode != 200) {
            debugPrint('[EpubService] Download failed: ${response.statusCode}');
            return null;
          }
          final ct = response.headers['content-type'] ?? '';
          if (ct.contains('text/html')) {
            debugPrint('[EpubService] Server returned HTML — auth issue?');
            return null;
          }
          final sink = epubFile.openWrite();
          await response.stream.pipe(sink)
              .timeout(const Duration(minutes: 5));
          await sink.close();
        } finally {
          client.close();
        }
      } else {
        onStatus?.call('Loading cached eBook…');
      }

      return epubFile.path;
    } catch (e, st) {
      debugPrint('[EpubService] Error: $e\n$st');
      return null;
    }
  }

  /// Delete all cached epub files and extracted directories for [itemId],
  /// covering both the old (no-ino) and new (ino-keyed) naming formats.
  static Future<void> clearCache(String itemId) async {
    final supportDir = await getApplicationSupportDirectory();
    final safeId = itemId.replaceAll(RegExp(r'[^\w]'), '_');
    await for (final entity in Directory(supportDir.path).list()) {
      final name = p.basename(entity.path);
      // Old format: ${safeId}.epub  or  ${safeId}_epub
      // New format: ${safeId}_${safeIno}.epub  or  ${safeId}_${safeIno}_epub[_tmp]
      final isMatch = name == '$safeId.epub' ||
          name == '${safeId}_epub' ||
          (name.startsWith('${safeId}_') &&
              (name.endsWith('.epub') ||
                  name.endsWith('_epub') ||
                  name.endsWith('_epub_tmp')));
      if (isMatch) {
        try {
          await entity.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}
