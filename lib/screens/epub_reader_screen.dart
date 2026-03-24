import 'dart:async';
import 'dart:io';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../providers/auth_provider.dart';
import '../services/audio_player_service.dart';
import '../services/epub_service.dart';
import '../services/scoped_prefs.dart';
import '../services/smil_service.dart';

// ─── Entry point ─────────────────────────────────────────────────────────────

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

class _EpubReaderScreenState extends State<EpubReaderScreen>
    with WidgetsBindingObserver {
  // ── Loading ────────────────────────────────────────────────────────────
  bool _loading = true;
  String? _error;
  String _loadStatus = 'Loading…';

  // ── Epub / SMIL ────────────────────────────────────────────────────────
  EpubInfo? _epub;
  SmilIndex? _smilIndex;
  SmilAudioOffsets? _audioOffsets;
  // fragId → smilDir: precomputed to avoid O(n·m) scan on every position tick.
  Map<String, String> _fragSmilDir = {};
  // Cached spine content paths (set once when epub loads).
  List<String>? _cachedContentPaths;

  // ── WebView ────────────────────────────────────────────────────────────
  late final WebViewController _webController;
  String? _loadedContentPath;
  bool _webReady = false;

  // ── SMIL sync ──────────────────────────────────────────────────────────
  SmilClip? _activeClip;

  // ── Main player ────────────────────────────────────────────────────────
  AudioPlayerService? _mainPlayer;
  bool _mainPlayerWasPlaying = false;

  // ── EPUB audio player ──────────────────────────────────────────────────
  AudioPlayer? _epubPlayer;
  int _currentAudioIdx = 0;
  Duration _currentAudioOffset = Duration.zero;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<int?>? _indexSub;
  StreamSubscription<PlayerState>? _stateSub;

  // ── Playback UI state ──────────────────────────────────────────────────
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _totalDuration = Duration.zero;
  double _speed = 1.0;

  // ── Seek-drag state ────────────────────────────────────────────────────
  bool _seeking = false;
  double _seekDragMs = 0;

  // ── Theme cache ────────────────────────────────────────────────────────
  ColorScheme? _cs;

  // ─── Init ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initWebView();
    // Defer epub loading so the build context is available
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadEpub());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final newCs = Theme.of(context).colorScheme;
    if (_cs != newCs) {
      _cs = newCs;
      // Re-inject CSS if the page is already loaded (e.g., theme changed)
      if (_webReady) _injectPageSetup();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _savePosition();
    _positionSub?.cancel();
    _indexSub?.cancel();
    _stateSub?.cancel();
    _epubPlayer?.dispose();
    // Resume the main audiobook player if it was playing when we opened.
    if (_mainPlayerWasPlaying) _mainPlayer?.play();
    _mainPlayer = null;
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      _savePosition();
    }
  }

  // ─── WebView setup ────────────────────────────────────────────────────

  void _initWebView() {
    _webController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'SmilTap',
        onMessageReceived: (msg) => _onTapFrag(msg.message),
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) {
          _webReady = true;
          _injectPageSetup();
          if (_activeClip != null) _applyHighlight(_activeClip!.fragId);
        },
        onWebResourceError: (err) {
          debugPrint('[EpubReader] WebView error: ${err.description}');
          if (err.isForMainFrame == true) {
            _setError('Failed to display eBook content.\n${err.description}');
          }
        },
      ));
  }

  // ─── Epub loading ─────────────────────────────────────────────────────

  Future<void> _loadEpub() async {
    final auth = context.read<AuthProvider>();
    final api = auth.apiService;
    if (api == null) {
      _setError('Not connected to a server.');
      return;
    }

    // Pause the main audiobook player if it's running; resume it on dispose.
    _mainPlayer = AudioPlayerService();
    _mainPlayerWasPlaying = _mainPlayer!.isPlaying;
    if (_mainPlayerWasPlaying) _mainPlayer!.pause();

    EpubInfo? epub;
    try {
      epub = await EpubService.loadEpub(
        itemId: widget.itemId,
        fileIno: widget.fileIno,
        baseUrl: api.baseUrl,
        headers: api.mediaHeaders,
        onStatus: (status) {
          if (mounted) setState(() => _loadStatus = status);
        },
      );
    } on TimeoutException {
      _setError('Download timed out.\nCheck your connection and try again.');
      return;
    } catch (e) {
      _setError('Failed to load eBook:\n$e');
      return;
    }

    if (!mounted) return;

    if (epub == null) {
      _setError(
          'Could not load the eBook.\n\n'
          'Make sure the book has an EPUB file and is accessible on your Audiobookshelf server.');
      return;
    }
    final epubData = epub;

    SmilIndex? smilIndex;
    SmilAudioOffsets? audioOffsets;
    final fragSmilDir = <String, String>{};

    if (epubData.hasMediaOverlays) {
      audioOffsets = SmilService.computeAudioOffsets(epubData.smilFiles);
      smilIndex = SmilService.buildIndex(epubData.smilFiles);
      debugPrint('[EpubReader] SMIL index: ${smilIndex.length} clips, '
          'total ${audioOffsets.total.inSeconds}s');
      // Pre-build fragId → smilDir map to avoid O(n·m) scan on every tick.
      for (final sf in epubData.smilFiles) {
        final dir = p.dirname(sf.smilPath);
        for (final clip in sf.clips) {
          fragSmilDir[clip.fragId] = dir;
        }
      }
    } else {
      debugPrint('[EpubReader] No media overlays — read-only mode.');
    }

    // Pre-compute content paths list once.
    final contentPaths = epubData.spineIds
        .map((id) => epubData.itemById(id))
        .whereType<EpubManifestItem>()
        .where((item) => item.isContent)
        .map((item) => epubData.resolveHref(item.href))
        .toList();

    setState(() {
      _epub = epubData;
      _smilIndex = smilIndex;
      _audioOffsets = audioOffsets;
      _fragSmilDir = fragSmilDir;
      _cachedContentPaths = contentPaths;
      if (audioOffsets != null) _totalDuration = audioOffsets.total;
      _loading = false;
    });

    // Load first content page
    _navigateToPath(epubData.firstContentPath);

    // Start EPUB audio player if we have overlays
    if (epubData.hasMediaOverlays) await _startEpubPlayer(epubData, audioOffsets!);
  }

  void _setError(String msg) {
    if (mounted) setState(() { _error = msg; _loading = false; });
  }

  // ─── EPUB audio player ────────────────────────────────────────────────

  Future<void> _startEpubPlayer(
      EpubInfo epub, SmilAudioOffsets ao) async {
    // Configure audio session for music/spoken word playback
    try {
      final session = await AudioSession.instance;
      await session.configure(const AudioSessionConfiguration.music());
    } catch (e) {
      debugPrint('[EpubReader] Audio session config error: $e');
    }

    // Build audio sources in playback order
    final sources = <AudioSource>[];
    for (final base in ao.order) {
      final absPath = epub.extractedAudioPaths[base];
      if (absPath == null || !File(absPath).existsSync()) {
        debugPrint('[EpubReader] Audio file missing: $base');
        continue;
      }
      sources.add(AudioSource.file(absPath));
    }

    if (sources.isEmpty) {
      debugPrint('[EpubReader] No playable audio files found in epub.');
      return;
    }

    final player = AudioPlayer();
    _epubPlayer = player;

    // Build track offset map (basename → cumulative start Duration)
    final offsetByIndex = ao.order
        .map((base) => ao.offsets[base] ?? Duration.zero)
        .toList();

    // Track absolute position
    _indexSub = player.currentIndexStream.listen((idx) {
      if (idx == null) return;
      _currentAudioIdx = idx;
      _currentAudioOffset = offsetByIndex[idx];
    });

    _positionSub = player.positionStream.listen((pos) {
      final absolute = _currentAudioOffset + pos;
      if (!_seeking) {
        if (mounted) setState(() => _position = absolute);
      }
      _onPosition(absolute);
    });

    _stateSub = player.playerStateStream.listen((state) {
      if (mounted) setState(() => _isPlaying = state.playing);
    });

    try {
      await player.setAudioSource(
        ConcatenatingAudioSource(children: sources),
        initialIndex: 0,
        initialPosition: Duration.zero,
        preload: false,
      );

      // Restore saved speed
      final savedSpeed = await ScopedPrefs.getDouble('epub_speed_${widget.itemId}');
      if (savedSpeed != null) {
        _speed = savedSpeed;
        await player.setSpeed(_speed);
      }

      // Restore saved position
      final savedMs = await ScopedPrefs.getInt('epub_pos_${widget.itemId}');
      if (savedMs != null && savedMs > 0) {
        _seekToAbsolute(Duration(milliseconds: savedMs), player: player);
      }
    } catch (e) {
      debugPrint('[EpubReader] Player setup error: $e');
    }
  }

  void _seekToAbsolute(Duration absolute, {AudioPlayer? player}) {
    final p0 = player ?? _epubPlayer;
    final ao = _audioOffsets;
    if (p0 == null || ao == null) return;
    for (int i = ao.order.length - 1; i >= 0; i--) {
      final offset = ao.offsets[ao.order[i]]!;
      if (absolute >= offset) {
        p0.seek(absolute - offset, index: i);
        return;
      }
    }
    p0.seek(Duration.zero, index: 0);
  }

  // ─── SMIL sync ────────────────────────────────────────────────────────

  void _onPosition(Duration absolute) {
    final clip = _smilIndex?.clipAt(absolute);
    if (clip == null || clip.fragId == _activeClip?.fragId) return;
    _activeClip = clip;

    final epub = _epub!;
    final smilDir = _fragSmilDir[clip.fragId] ?? '';
    final targetPath = p.normalize(p.join(epub.opfDir, smilDir, clip.contentSrc));
    if (targetPath != _loadedContentPath) {
      _navigateToPath(targetPath);
      // Highlight applied in onPageFinished
    } else if (_webReady) {
      _applyHighlight(clip.fragId);
    }
  }

  // ─── Tap-to-seek ──────────────────────────────────────────────────────

  void _onTapFrag(String fragId) {
    final beginTime = _smilIndex?.beginForFrag(fragId);
    if (beginTime == null) return;
    _seekToAbsolute(beginTime);
    if (!_isPlaying) _epubPlayer?.play();
  }

  // ─── WebView navigation ───────────────────────────────────────────────

  void _navigateToPath(String? absPath) {
    if (absPath == null) {
      _setError('This eBook has no readable content.');
      return;
    }
    if (!File(absPath).existsSync()) {
      debugPrint('[EpubReader] Content file not found: $absPath');
      _setError('eBook content file not found.\nTry closing and re-opening the reader.');
      return;
    }
    _webReady = false;
    _loadedContentPath = absPath;
    _webController.loadFile(absPath);
  }

  // ─── WebView JS injection ─────────────────────────────────────────────

  void _injectPageSetup() {
    final cs = _cs ?? Theme.of(context).colorScheme;
    final surface = _hexColor(cs.surface);
    final onSurface = _hexColor(cs.onSurface);
    final primary = _hexColor(cs.primary);
    final highlight = _hexColor(cs.primaryContainer);
    // Sanitize to safe CSS identifier characters before injecting into JS.
    final rawClass = _epub?.activeClass ?? '-epub-media-overlay-active';
    final sanitized = rawClass.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final activeClass = sanitized.isNotEmpty ? sanitized : 'epub-overlay-active';

    _webController.runJavaScript('''
(function() {
  // ─── Theme CSS ──────────────────────────────────────────────────────
  var styleId = '__smil_style';
  var existing = document.getElementById(styleId);
  if (existing) existing.remove();
  var style = document.createElement('style');
  style.id = styleId;
  style.textContent = `
    html { color-scheme: light !important; }
    body {
      background-color: ${surface} !important;
      color: ${onSurface} !important;
      font-size: 18px;
      line-height: 1.7;
      padding: 16px 20px 32px;
      max-width: 720px;
      margin: 0 auto;
      -webkit-text-size-adjust: none;
    }
    a { color: ${primary}; }
    img, svg { max-width: 100%; height: auto; }
    .${activeClass} {
      background-color: ${highlight} !important;
      border-radius: 3px;
      transition: background-color 0.15s ease;
      outline: none;
    }
  `;
  document.head.appendChild(style);

  // ─── Highlight function ─────────────────────────────────────────────
  window.smilHighlight = function(id) {
    var prev = document.querySelector('.$activeClass');
    if (prev) prev.classList.remove('$activeClass');
    var el = document.getElementById(id);
    if (el) {
      el.classList.add('$activeClass');
      el.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
  };

  // ─── Tap-to-seek ────────────────────────────────────────────────────
  document.addEventListener('click', function(e) {
    var el = e.target;
    // Walk up to find the nearest element with an id
    for (var i = 0; i < 6 && el; i++) {
      if (el.id) { window.SmilTap.postMessage(el.id); return; }
      el = el.parentElement;
    }
  }, true);
})();
''');
  }

  void _applyHighlight(String fragId) {
    _webController.runJavaScript(
        "if(window.smilHighlight)smilHighlight('${_escapeJs(fragId)}');");
  }

  String _escapeJs(String s) => s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\u2028', r'\u2028')
      .replaceAll('\u2029', r'\u2029');

  String _hexColor(Color c) {
    final r = (c.r * 255).round().toRadixString(16).padLeft(2, '0');
    final g = (c.g * 255).round().toRadixString(16).padLeft(2, '0');
    final b = (c.b * 255).round().toRadixString(16).padLeft(2, '0');
    return '#$r$g$b';
  }

  // ─── Spine navigation ─────────────────────────────────────────────────

  List<String> get _contentPaths => _cachedContentPaths ?? [];

  void _goToPrev() {
    final paths = _contentPaths;
    final idx = paths.indexOf(_loadedContentPath ?? '');
    if (idx > 0) _navigateToPath(paths[idx - 1]);
  }

  void _goToNext() {
    final paths = _contentPaths;
    final idx = paths.indexOf(_loadedContentPath ?? '');
    if (idx >= 0 && idx < paths.length - 1) _navigateToPath(paths[idx + 1]);
  }

  // ─── Position persistence ─────────────────────────────────────────────

  void _savePosition() {
    ScopedPrefs.setInt('epub_pos_${widget.itemId}', _position.inMilliseconds);
    ScopedPrefs.setDouble('epub_speed_${widget.itemId}', _speed);
  }

  // ─── Formatting ───────────────────────────────────────────────────────

  String _fmt(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}:'
          '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:'
          '${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
    }
    return '${d.inMinutes.remainder(60).toString().padLeft(2, '0')}:'
        '${d.inSeconds.remainder(60).toString().padLeft(2, '0')}';
  }

  // ─── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasAudio = _epub?.hasMediaOverlays == true && _epubPlayer != null;

    // Derive section label for app bar
    String sectionLabel = '';
    if (_epub != null && _loadedContentPath != null) {
      final paths = _contentPaths;
      final idx = paths.indexOf(_loadedContentPath!);
      if (idx >= 0) sectionLabel = 'Section ${idx + 1} of ${paths.length}';
    }

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.bookTitle,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
            if (sectionLabel.isNotEmpty)
              Text(sectionLabel,
                  style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant)),
          ],
        ),
        backgroundColor: cs.surface,
        foregroundColor: cs.onSurface,
        elevation: 0,
        actions: [
          if (hasAudio) _buildSpeedButton(cs),
          IconButton(
            icon: const Icon(Icons.chevron_left_rounded),
            tooltip: 'Previous section',
            onPressed: () {
              final paths = _contentPaths;
              final idx = paths.indexOf(_loadedContentPath ?? '');
              if (idx > 0) _goToPrev();
            },
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: 'Next section',
            onPressed: () {
              final paths = _contentPaths;
              final idx = paths.indexOf(_loadedContentPath ?? '');
              if (idx >= 0 && idx < paths.length - 1) _goToNext();
            },
          ),
        ],
      ),
      body: _buildBody(cs),
      bottomNavigationBar: hasAudio ? _buildPlayerBar(cs) : null,
    );
  }

  Widget _buildBody(ColorScheme cs) {
    if (_loading) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(_loadStatus, style: TextStyle(color: cs.onSurfaceVariant)),
        ]),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.menu_book_rounded, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(_error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: cs.onSurfaceVariant)),
          ]),
        ),
      );
    }
    return WebViewWidget(controller: _webController);
  }

  // ─── Player bar ───────────────────────────────────────────────────────

  Widget _buildPlayerBar(ColorScheme cs) {
    final total = _totalDuration.inMilliseconds.toDouble();
    final current = _seeking
        ? _seekDragMs
        : _position.inMilliseconds
            .toDouble()
            .clamp(0.0, total > 0 ? total : 1.0)
            .toDouble();

    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(top: BorderSide(color: cs.outlineVariant, width: 0.5)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // ── Seek row ──────────────────────────────────────────────────
          Row(children: [
            SizedBox(
              width: 44,
              child: Text(
                _fmt(_seeking
                    ? Duration(milliseconds: _seekDragMs.round())
                    : _position),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 3,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                  activeTrackColor: cs.primary,
                  inactiveTrackColor: cs.onSurface.withValues(alpha: 0.15),
                  thumbColor: cs.primary,
                  overlayColor: cs.primary.withValues(alpha: 0.12),
                ),
                child: Slider(
                  value: current,
                  min: 0.0,
                  max: total > 0 ? total : 1.0,
                  onChangeStart: (v) => setState(() {
                    _seeking = true;
                    _seekDragMs = v;
                  }),
                  onChanged: (v) => setState(() => _seekDragMs = v),
                  onChangeEnd: (v) {
                    setState(() { _seeking = false; });
                    _seekToAbsolute(Duration(milliseconds: v.round()));
                  },
                ),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                _fmt(_totalDuration),
                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
            ),
          ]),

          // ── Controls row ──────────────────────────────────────────────
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            // Skip back 15s
            IconButton(
              icon: const Icon(Icons.replay_rounded),
              iconSize: 28,
              color: cs.onSurface,
              tooltip: 'Skip back 15s',
              onPressed: () {
                final newPos = _position - const Duration(seconds: 15);
                _seekToAbsolute(newPos < Duration.zero ? Duration.zero : newPos);
              },
            ),

            // Play / Pause
            Container(
              width: 52, height: 52,
              decoration: BoxDecoration(
                color: cs.primary,
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: Icon(_isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
                iconSize: 28,
                color: cs.onPrimary,
                onPressed: () {
                  if (_isPlaying) {
                    _epubPlayer?.pause();
                  } else {
                    _epubPlayer?.play();
                  }
                },
              ),
            ),

            // Skip forward 30s
            IconButton(
              icon: const Icon(Icons.forward_30_rounded),
              iconSize: 28,
              color: cs.onSurface,
              tooltip: 'Skip forward 30s',
              onPressed: () {
                final newPos = _position + const Duration(seconds: 30);
                final max = _totalDuration;
                _seekToAbsolute(newPos > max ? max : newPos);
              },
            ),
          ]),
        ]),
      ),
    );
  }

  Widget _buildSpeedButton(ColorScheme cs) {
    return PopupMenuButton<double>(
      initialValue: _speed,
      tooltip: 'Playback speed',
      onSelected: (v) async {
        setState(() => _speed = v);
        await _epubPlayer?.setSpeed(v);
        ScopedPrefs.setDouble('epub_speed_${widget.itemId}', v);
      },
      itemBuilder: (_) => [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]
          .map((v) => PopupMenuItem<double>(
                value: v,
                child: Text('${v}×',
                    style: TextStyle(
                        fontWeight: _speed == v ? FontWeight.bold : FontWeight.normal,
                        color: _speed == v ? cs.primary : null)),
              ))
          .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          '${_speed}×',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: cs.onSurface,
          ),
        ),
      ),
    );
  }
}
