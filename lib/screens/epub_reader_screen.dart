import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../providers/auth_provider.dart';
import '../services/audio_player_service.dart';
import '../services/epub_service.dart';
import '../services/smil_service.dart';

// ─── Entry point ─────────────────────────────────────────────────────────────

/// Push the epub reader screen onto the navigator.
/// Call this when the user taps "Read Along".
void openEpubReader(
  BuildContext context, {
  required String itemId,
  required String fileIno,
  required String bookTitle,
}) {
  Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => EpubReaderScreen(
      itemId: itemId,
      fileIno: fileIno,
      bookTitle: bookTitle,
    ),
  ));
}

// ─── Screen ───────────────────────────────────────────────────────────────────

class EpubReaderScreen extends StatefulWidget {
  final String itemId;
  final String fileIno;
  final String bookTitle;

  const EpubReaderScreen({
    super.key,
    required this.itemId,
    required this.fileIno,
    required this.bookTitle,
  });

  @override
  State<EpubReaderScreen> createState() => _EpubReaderScreenState();
}

class _EpubReaderScreenState extends State<EpubReaderScreen> {
  // ── Loading state ──────────────────────────────────────────────────────
  bool _loading = true;
  String? _error;

  // ── Epub / SMIL data ───────────────────────────────────────────────────
  EpubInfo? _epub;
  SmilIndex? _smilIndex;

  // ── WebView ────────────────────────────────────────────────────────────
  late final WebViewController _webController;
  String? _loadedContentPath; // absolute path of the HTML currently in WebView
  bool _webReady = false;     // true after onPageFinished fires

  // ── Sync state ─────────────────────────────────────────────────────────
  StreamSubscription<Duration>? _positionSub;
  SmilClip? _activeClip;

  // ─── Init ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initWebView();
    _loadEpub();
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    super.dispose();
  }

  // ─── WebView setup ────────────────────────────────────────────────────

  void _initWebView() {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _webReady = true;
          _injectHighlightSupport();
          // Re-apply current highlight if we already know the active clip
          if (_activeClip != null) {
            _applyHighlight(_activeClip!.fragId);
          }
        },
        onWebResourceError: (err) {
          debugPrint('[EpubReader] WebView error: ${err.description}');
        },
      ));

    // Allow local file access on Android
    if (Platform.isAndroid) {
      _webController.setBackgroundColor(Colors.transparent);
    }
  }

  // ─── Epub loading ─────────────────────────────────────────────────────

  Future<void> _loadEpub() async {
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) {
      _setError('Not connected to a server.');
      return;
    }

    final epub = await EpubService.loadEpub(
      itemId: widget.itemId,
      fileIno: widget.fileIno,
      baseUrl: api.baseUrl,
      headers: api.mediaHeaders,
    );

    if (!mounted) return;

    if (epub == null) {
      _setError(
          'Could not load the epub file.\nMake sure the book has an epub on your Audiobookshelf server.');
      return;
    }

    // Build SMIL index using the audio player's track info
    final player = context.read<AudioPlayerService>();
    SmilIndex? smilIndex;

    if (epub.smilFiles.isNotEmpty) {
      final tracks = player.audioTracks;
      final basenames = <String>[];
      final durations = <double>[];
      for (final t in tracks) {
        final track = t as Map<String, dynamic>;
        // contentUrl is something like "/api/items/{id}/file/{ino}"
        final contentUrl = track['contentUrl'] as String? ?? '';
        basenames.add(p.basename(contentUrl));
        durations.add((track['duration'] as num?)?.toDouble() ?? 0.0);
      }
      smilIndex = SmilService.buildIndex(
        smilFiles: epub.smilFiles,
        audioTrackBasenames: basenames,
        audioTrackDurations: durations,
      );
      debugPrint('[EpubReader] SMIL index built. '
          '${epub.smilFiles.fold(0, (n, f) => n + f.clips.length)} clips');
    } else {
      debugPrint('[EpubReader] No SMIL media overlays found in this epub.');
    }

    setState(() {
      _epub = epub;
      _smilIndex = smilIndex;
      _loading = false;
    });

    // Load first page
    _navigateToPath(epub.firstContentPath);

    // Start SMIL sync if we have an index
    if (smilIndex != null && !smilIndex.isEmpty) {
      _startSync(player);
    }
  }

  void _setError(String msg) {
    if (mounted) setState(() { _error = msg; _loading = false; });
  }

  // ─── Navigation ───────────────────────────────────────────────────────

  void _navigateToPath(String? absPath) {
    if (absPath == null) return;
    final f = File(absPath);
    if (!f.existsSync()) {
      debugPrint('[EpubReader] Content file not found: $absPath');
      return;
    }
    _webReady = false;
    _loadedContentPath = absPath;
    _webController.loadFile(absPath);
  }

  // ─── SMIL sync ────────────────────────────────────────────────────────

  void _startSync(AudioPlayerService player) {
    _positionSub?.cancel();
    _positionSub = player.absolutePositionStream.listen(_onPosition);
  }

  void _onPosition(Duration position) {
    final clip = _smilIndex?.clipAt(position);
    if (clip == null || clip.fragId == _activeClip?.fragId) return;
    _activeClip = clip;

    // If the new clip is in a different content file, navigate first
    final epub = _epub!;
    final smilDir = _smilDirForClip(clip);
    final targetPath =
        p.normalize(p.join(epub.opfDir, smilDir, clip.contentSrc));
    if (targetPath != _loadedContentPath) {
      _navigateToPath(targetPath);
      // Highlight will be applied in onPageFinished
    } else if (_webReady) {
      _applyHighlight(clip.fragId);
    }
  }

  /// Returns the SMIL file directory (relative to opfDir) for a given clip.
  String _smilDirForClip(SmilClip clip) {
    for (final sf in _epub!.smilFiles) {
      if (sf.clips.any((c) => c.fragId == clip.fragId)) {
        return p.dirname(sf.smilPath);
      }
    }
    return '';
  }

  // ─── WebView JS ───────────────────────────────────────────────────────

  void _injectHighlightSupport() {
    _webController.runJavaScript(r'''
(function() {
  if (window.__smilReady) return;
  window.__smilReady = true;

  var style = document.createElement('style');
  style.textContent = `
    .smil-active {
      background-color: rgba(255, 214, 0, 0.45);
      border-radius: 3px;
      transition: background-color 0.15s ease;
    }
  `;
  document.head.appendChild(style);

  window.smilHighlight = function(id) {
    var prev = document.querySelector('.smil-active');
    if (prev) prev.classList.remove('smil-active');
    var el = document.getElementById(id);
    if (el) {
      el.classList.add('smil-active');
      el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
  };
})();
''');
  }

  void _applyHighlight(String fragId) {
    _webController.runJavaScript("smilHighlight('${_escapeJs(fragId)}');");
  }

  String _escapeJs(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  // ─── Spine navigation UI ──────────────────────────────────────────────

  List<String> get _contentPaths {
    final epub = _epub;
    if (epub == null) return [];
    return epub.spineIds
        .map((id) => epub.itemById(id))
        .whereType<EpubManifestItem>()
        .where((item) => item.isContent)
        .map((item) => epub.resolveHref(item.href))
        .toList();
  }

  void _goToPrevPage() {
    final paths = _contentPaths;
    final idx = paths.indexOf(_loadedContentPath ?? '');
    if (idx > 0) _navigateToPath(paths[idx - 1]);
  }

  void _goToNextPage() {
    final paths = _contentPaths;
    final idx = paths.indexOf(_loadedContentPath ?? '');
    if (idx >= 0 && idx < paths.length - 1) _navigateToPath(paths[idx + 1]);
  }

  bool get _hasPrev {
    final paths = _contentPaths;
    final idx = paths.indexOf(_loadedContentPath ?? '');
    return idx > 0;
  }

  bool get _hasNext {
    final paths = _contentPaths;
    final idx = paths.indexOf(_loadedContentPath ?? '');
    return idx >= 0 && idx < paths.length - 1;
  }

  // ─── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Text(
          widget.bookTitle,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        elevation: 0,
        actions: [
          if (_smilIndex != null && !_smilIndex!.isEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.sync_rounded, size: 14, color: Colors.amber.shade700),
                  const SizedBox(width: 4),
                  Text('Read Along',
                      style: TextStyle(fontSize: 12, color: Colors.amber.shade700)),
                ],
              ),
            ),
        ],
      ),
      body: _buildBody(cs),
      bottomNavigationBar: _loading || _error != null ? null : _buildNavBar(cs),
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Loading epub…', style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.menu_book_rounded, size: 48, color: cs.onSurfaceVariant),
              const SizedBox(height: 16),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }

    return WebViewWidget(controller: _webController);
  }

  Widget _buildNavBar(ColorScheme cs) {
    return SafeArea(
      child: Container(
        height: 56,
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            IconButton(
              icon: const Icon(Icons.chevron_left_rounded),
              onPressed: _hasPrev ? _goToPrevPage : null,
              color: cs.onSurface,
              disabledColor: cs.onSurface.withValues(alpha: 0.25),
            ),
            // Current page indicator
            if (_epub != null) Builder(builder: (_) {
              final paths = _contentPaths;
              final idx = paths.indexOf(_loadedContentPath ?? '');
              final total = paths.length;
              return Text(
                idx >= 0 ? 'Section ${idx + 1} of $total' : '',
                style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
              );
            }),
            IconButton(
              icon: const Icon(Icons.chevron_right_rounded),
              onPressed: _hasNext ? _goToNextPage : null,
              color: cs.onSurface,
              disabledColor: cs.onSurface.withValues(alpha: 0.25),
            ),
          ],
        ),
      ),
    );
  }
}
