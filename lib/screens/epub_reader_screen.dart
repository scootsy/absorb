import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flureadium/flureadium.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../services/audio_player_service.dart';
import '../services/epub_service.dart';
import '../services/scoped_prefs.dart';

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

  // ── Flureadium ─────────────────────────────────────────────────────────
  final _flureadium = Flureadium();
  Publication? _publication;
  Locator? _initialLocator;
  bool _hasMediaOverlays = false;

  // ── Main player ────────────────────────────────────────────────────────
  AudioPlayerService? _mainPlayer;
  bool _mainPlayerWasPlaying = false;

  // ── Playback UI state ──────────────────────────────────────────────────
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _totalDuration = Duration.zero;
  double _speed = 1.0;

  // ── Seek-drag state ────────────────────────────────────────────────────
  bool _seeking = false;
  double _seekDragMs = 0;

  // ── Subscriptions ──────────────────────────────────────────────────────
  StreamSubscription<ReadiumTimebasedState>? _playerStateSub;
  StreamSubscription<Locator>? _locatorSub;

  // ── Section tracking ───────────────────────────────────────────────────
  String _sectionLabel = '';

  // ─── Init ─────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadEpub());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _savePosition();
    _playerStateSub?.cancel();
    _locatorSub?.cancel();
    _flureadium.closePublication();
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

    // Download the epub file (or use cached copy).
    String? epubPath;
    try {
      epubPath = await EpubService.downloadEpub(
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

    if (epubPath == null) {
      _setError(
          'Could not load the eBook.\n\n'
          'Make sure the book has an EPUB file and is accessible on your Audiobookshelf server.');
      return;
    }

    // Set auth headers for any network requests Readium might make.
    await _flureadium.setCustomHeaders(api.mediaHeaders);

    // Open the publication with Readium.
    setState(() => _loadStatus = 'Opening…');
    Publication publication;
    try {
      publication = await _flureadium.openPublication('file://$epubPath');
    } catch (e) {
      _setError('Failed to open eBook:\n$e');
      return;
    }

    if (!mounted) return;

    final hasMediaOverlays = publication.containsMediaOverlays();

    // Restore saved position.
    Locator? initialLocator;
    final savedLocatorJson = await ScopedPrefs.getString('epub_locator_${widget.itemId}');
    if (savedLocatorJson != null) {
      try {
        initialLocator = Locator.fromJson(json.decode(savedLocatorJson) as Map<String, dynamic>);
      } catch (_) {}
    }

    // Restore saved speed.
    final savedSpeed = await ScopedPrefs.getDouble('epub_speed_${widget.itemId}');
    if (savedSpeed != null) _speed = savedSpeed;

    // Apply theme preferences.
    _applyThemePreferences();

    // Listen for position changes.
    _locatorSub = _flureadium.onTextLocatorChanged.listen((locator) {
      _updateSectionLabel(locator, publication);
      _lastLocator = locator;
    });

    // Set up audio if this epub has media overlays.
    if (hasMediaOverlays) {
      await _flureadium.audioEnable(
        prefs: AudioPreferences(speed: _speed),
        fromLocator: initialLocator,
      );

      _playerStateSub = _flureadium.onTimebasedPlayerStateChanged.listen((state) {
        if (!mounted) return;
        setState(() {
          _isPlaying = state.state == TimebasedState.playing;
          if (state.currentOffset != null) _position = state.currentOffset!;
          if (state.currentDuration != null) _totalDuration = state.currentDuration!;
        });
      });
    }

    setState(() {
      _publication = publication;
      _initialLocator = initialLocator;
      _hasMediaOverlays = hasMediaOverlays;
      _loading = false;
    });
  }

  void _setError(String msg) {
    if (mounted) setState(() { _error = msg; _loading = false; });
  }

  // ─── Theme ────────────────────────────────────────────────────────────

  void _applyThemePreferences() {
    final cs = Theme.of(context).colorScheme;
    _flureadium.setEPUBPreferences(EPUBPreferences(
      fontSize: 18,
      fontFamily: '',
      fontWeight: 0.4,
      verticalScroll: false,
      backgroundColor: cs.surface,
      textColor: cs.onSurface,
    ));
  }

  // ─── Section label ────────────────────────────────────────────────────

  Locator? _lastLocator;

  void _updateSectionLabel(Locator locator, Publication publication) {
    final title = locator.title;
    if (title != null && title.isNotEmpty && mounted) {
      setState(() => _sectionLabel = title);
    }
  }

  // ─── Position persistence ─────────────────────────────────────────────

  void _savePosition() {
    final locator = _lastLocator;
    if (locator != null) {
      ScopedPrefs.setString(
          'epub_locator_${widget.itemId}', json.encode(locator.toJson()));
    }
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
    final hasAudio = _hasMediaOverlays && _publication != null;

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
            if (_sectionLabel.isNotEmpty)
              Text(_sectionLabel,
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
            onPressed: () => _flureadium.skipToPrevious(),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right_rounded),
            tooltip: 'Next section',
            onPressed: () => _flureadium.skipToNext(),
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
    return ReadiumReaderWidget(
      publication: _publication!,
      initialLocator: _initialLocator,
      onLocatorChanged: (locator) {
        _lastLocator = locator;
        _updateSectionLabel(locator, _publication!);
      },
    );
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
                    final offset = Duration(milliseconds: v.round()) - _position;
                    _flureadium.audioSeekBy(offset);
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
                _flureadium.audioSeekBy(const Duration(seconds: -15));
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
                    _flureadium.pause();
                  } else {
                    _flureadium.resume();
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
                _flureadium.audioSeekBy(const Duration(seconds: 30));
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
        await _flureadium.audioSetPreferences(AudioPreferences(speed: v));
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
