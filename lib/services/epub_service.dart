import 'dart:io';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:xml/xml.dart';
import 'smil_service.dart';

// ─── Manifest item ────────────────────────────────────────────────────────

class EpubManifestItem {
  final String id;
  final String href;
  final String mediaType;

  /// ID of the SMIL manifest item that provides media overlay for this item.
  final String? mediaOverlayId;

  const EpubManifestItem({
    required this.id,
    required this.href,
    required this.mediaType,
    this.mediaOverlayId,
  });

  bool get isSmil => mediaType == 'application/smil+xml';
  bool get isAudio =>
      mediaType.startsWith('audio/') || mediaType == 'application/ogg';
  bool get isContent =>
      mediaType == 'application/xhtml+xml' || mediaType == 'text/html';
}

// ─── Parsed epub ──────────────────────────────────────────────────────────

class EpubInfo {
  /// Absolute path to the directory where the epub was extracted.
  final String extractDir;

  /// Absolute path to the directory that contains the OPF file.
  /// All manifest hrefs are relative to this directory.
  final String opfDir;

  final List<EpubManifestItem> manifest;

  /// Spine item IDs in reading order.
  final List<String> spineIds;

  /// Parsed SMIL data (one entry per SMIL file, in spine order).
  final List<SmilFileInfo> smilFiles;

  /// Audio file basenames in playback order (derived from SMIL clips).
  final List<String> audioFilesInOrder;

  /// Map of audio file basename → absolute filesystem path (after extraction).
  final Map<String, String> extractedAudioPaths;

  /// CSS class name to apply for the active/highlighted element.
  /// From OPF `<meta property="media:active-class">`, or fallback.
  final String activeClass;

  const EpubInfo({
    required this.extractDir,
    required this.opfDir,
    required this.manifest,
    required this.spineIds,
    required this.smilFiles,
    required this.audioFilesInOrder,
    required this.extractedAudioPaths,
    required this.activeClass,
  });

  /// True when this epub contains SMIL media overlays for read-along.
  bool get hasMediaOverlays => smilFiles.isNotEmpty;

  /// Resolve a manifest href to an absolute filesystem path.
  String resolveHref(String href) => p.normalize(p.join(opfDir, href));

  EpubManifestItem? itemById(String id) =>
      manifest.where((m) => m.id == id).firstOrNull;

  /// Absolute path of the first spine content document.
  String? get firstContentPath {
    for (final id in spineIds) {
      final item = itemById(id);
      if (item != null && item.isContent) return resolveHref(item.href);
    }
    return null;
  }
}

// ─── EpubService ─────────────────────────────────────────────────────────

class EpubService {
  /// Download (if not cached) and parse an epub file.
  ///
  /// Uses [getApplicationSupportDirectory] so the cache survives across
  /// app launches and is not purged by the OS (unlike temp).
  ///
  /// Returns null on any failure.
  static Future<EpubInfo?> loadEpub({
    required String itemId,
    required String fileIno,
    required String baseUrl,
    required Map<String, String> headers,
  }) async {
    try {
      final supportDir = await getApplicationSupportDirectory();
      final safeId = itemId.replaceAll(RegExp(r'[^\w]'), '_');
      // Include fileIno in cache paths so a replaced server file invalidates cache.
      final safeIno = fileIno.replaceAll(RegExp(r'[^\w]'), '_');
      final epubFile = File(p.join(supportDir.path, '${safeId}_$safeIno.epub'));
      final extractDir = Directory(p.join(supportDir.path, '${safeId}_${safeIno}_epub'));
      final tmpExtractDir = Directory(p.join(supportDir.path, '${safeId}_${safeIno}_epub_tmp'));

      // ── Download ────────────────────────────────────────────────────────
      if (!epubFile.existsSync()) {
        final cleanBase =
            baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
        final url = '$cleanBase/api/items/$itemId/file/$fileIno';

        final request = http.Request('GET', Uri.parse(url));
        request.followRedirects = false;
        headers.forEach((k, v) => request.headers[k] = v);
        final client = http.Client();
        try {
          var response = await client.send(request);
          var redirects = 0;
          while ([301, 302, 303, 307, 308].contains(response.statusCode) &&
              redirects < 5) {
            final location = response.headers['location'];
            if (location == null) break;
            final redirectUri = Uri.parse(url).resolve(location);
            final rReq = http.Request('GET', redirectUri);
            headers.forEach((k, v) => rReq.headers[k] = v);
            rReq.followRedirects = false;
            response = await client.send(rReq);
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
          await response.stream.pipe(sink);
          await sink.close();
        } finally {
          client.close();
        }
      }

      // ── Extract ─────────────────────────────────────────────────────────
      if (!extractDir.existsSync()) {
        // Clean up any leftover temp dir from a previous failed extraction.
        if (tmpExtractDir.existsSync()) tmpExtractDir.deleteSync(recursive: true);
        tmpExtractDir.createSync(recursive: true);
        try {
          // Run CPU-heavy ZIP decode + file I/O on a background isolate.
          await compute(_extractZipInIsolate, [epubFile.path, tmpExtractDir.path]);
          // Atomic rename: only visible as complete or not-started.
          await tmpExtractDir.rename(extractDir.path);
        } catch (e) {
          if (tmpExtractDir.existsSync()) tmpExtractDir.deleteSync(recursive: true);
          rethrow;
        }
      }

      // ── Parse container.xml ─────────────────────────────────────────────
      final containerFile =
          File(p.join(extractDir.path, 'META-INF', 'container.xml'));
      if (!containerFile.existsSync()) {
        debugPrint('[EpubService] No META-INF/container.xml');
        return null;
      }

      final containerDoc = XmlDocument.parse(containerFile.readAsStringSync());
      final rootfileEl = containerDoc.findAllElements('rootfile').firstOrNull;
      if (rootfileEl == null) {
        debugPrint('[EpubService] No rootfile element');
        return null;
      }

      final opfRelPath = rootfileEl.getAttribute('full-path') ?? '';
      if (opfRelPath.isEmpty) return null;

      // ── Parse OPF ────────────────────────────────────────────────────────
      final opfAbsPath = p.join(extractDir.path, opfRelPath);
      final opfFile = File(opfAbsPath);
      if (!opfFile.existsSync()) {
        debugPrint('[EpubService] OPF not found at $opfAbsPath');
        return null;
      }

      final opfDoc = XmlDocument.parse(opfFile.readAsStringSync());
      final opfDir = p.dirname(opfAbsPath);

      // ── OPF metadata: active-class ────────────────────────────────────
      String activeClass = '-epub-media-overlay-active';
      for (final meta in opfDoc.findAllElements('meta')) {
        final prop = meta.getAttribute('property') ?? '';
        if (prop == 'media:active-class') {
          final val = meta.innerText.trim();
          if (val.isNotEmpty) {
            // Strip a leading '.' if the author included the selector dot
            activeClass = val.startsWith('.') ? val.substring(1) : val;
          }
          break;
        }
      }

      // ── Build manifest ────────────────────────────────────────────────
      final manifest = <EpubManifestItem>[];
      for (final item in opfDoc.findAllElements('item')) {
        manifest.add(EpubManifestItem(
          id: item.getAttribute('id') ?? '',
          href: item.getAttribute('href') ?? '',
          mediaType: item.getAttribute('media-type') ?? '',
          mediaOverlayId: item.getAttribute('media-overlay'),
        ));
      }

      // Build map of audio basenames → extracted abs paths (from manifest).
      // Keys are lowercased to match SmilService's lowercase basename convention.
      final extractedAudioPaths = <String, String>{};
      for (final item in manifest) {
        if (!item.isAudio) continue;
        final absPath = p.normalize(p.join(opfDir, item.href));
        if (File(absPath).existsSync()) {
          extractedAudioPaths[p.basename(absPath).toLowerCase()] = absPath;
        }
      }

      // ── Build spine ───────────────────────────────────────────────────
      final spineIds = <String>[];
      for (final itemref in opfDoc.findAllElements('itemref')) {
        final idref = itemref.getAttribute('idref');
        if (idref != null && idref.isNotEmpty) spineIds.add(idref);
      }

      // ── Parse SMIL files (in spine overlay order) ─────────────────────
      final smilFiles = <SmilFileInfo>[];
      final audioFilesInOrder = <String>[];
      final processedSmilIds = <String>{};

      for (final spineId in spineIds) {
        final spineItem = manifest.where((m) => m.id == spineId).firstOrNull;
        if (spineItem == null) continue;

        final overlayId = spineItem.mediaOverlayId;
        if (overlayId == null || processedSmilIds.contains(overlayId)) continue;
        processedSmilIds.add(overlayId);

        final smilItem = manifest.where((m) => m.id == overlayId).firstOrNull;
        if (smilItem == null) continue;

        final smilAbsPath = p.normalize(p.join(opfDir, smilItem.href));
        final smilFile = File(smilAbsPath);
        if (!smilFile.existsSync()) continue;

        final clips = SmilService.parseSmilFile(smilFile.readAsStringSync());
        smilFiles.add(SmilFileInfo(smilPath: smilItem.href, clips: clips));

        for (final clip in clips) {
          final base = p.basename(clip.audioSrc);
          if (!audioFilesInOrder.contains(base)) audioFilesInOrder.add(base);
        }
      }

      debugPrint('[EpubService] Loaded: ${smilFiles.length} SMIL files, '
          '${audioFilesInOrder.length} audio files, '
          'activeClass="$activeClass", '
          'hasMediaOverlays=${smilFiles.isNotEmpty}');

      return EpubInfo(
        extractDir: extractDir.path,
        opfDir: opfDir,
        manifest: manifest,
        spineIds: spineIds,
        smilFiles: smilFiles,
        audioFilesInOrder: audioFilesInOrder,
        extractedAudioPaths: extractedAudioPaths,
        activeClass: activeClass,
      );
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

// ─── Isolate helper ───────────────────────────────────────────────────────────

/// Top-level function so [compute] can spawn it in a background isolate.
/// args[0] = source epub file path, args[1] = destination extract directory path.
Future<void> _extractZipInIsolate(List<String> args) async {
  final epubPath = args[0];
  final extractPath = args[1];
  final bytes = await File(epubPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  for (final file in archive) {
    if (!file.isFile) continue;
    final outPath = p.join(extractPath, file.name);
    final outFile = File(outPath);
    outFile.parent.createSync(recursive: true);
    outFile.writeAsBytesSync(file.content as List<int>);
  }
}
