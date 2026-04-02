import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flureadium/flureadium.dart';
import 'package:provider/provider.dart' hide Locator;
import '../providers/auth_provider.dart';
import '../services/audio_player_service.dart';
import '../services/epub_service.dart';
import '../services/scoped_prefs.dart';

// ─── Reader theme constants ────────────────────────────────────────────────────

const _lightBg = Color(0xFFFFFFFF);
const _lightFg = Color(0xFF1A1A1A);
const _darkBg  = Color(0xFF1C1C1E);
const _darkFg  = Color(0xFFE5E5EA);
const _sepiaBg = Color(0xFFF5E6C8);
const _sepiaFg = Color(0xFF3B2E1E);

// ─── Font options ─────────────────────────────────────────────────────────────

const _fontFamilies = ['Georgia', 'Arial', 'Courier New'];
const _fontFamilyLabels = ['Serif', 'Sans', 'Mono'];

// ─── Prefs keys ───────────────────────────────────────────────────────────────

const _kFontSize   = 'epub_fontSize';
const _kFontFamily = 'epub_fontFamily';
const _kTheme      = 'epub_theme';

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
  StreamSubscription<ReadiumReaderStatus>? _readerStatusSub;

  // ── Section and progress tracking ─────────────────────────────────────
  String _sectionLabel = '';
  double _readingProgress = 0.0;
  Locator? _lastLocator;

  // ── Reader preferences (persisted globally, not per-book) ─────────────
  double _fontSize = 20;
  String _fontFamily = 'Georgia';
  String _readerTheme = 'system'; // 'system' | 'light' | 'dark' | 'sepia'

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
    _readerStatusSub?.cancel();
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

    final hasMediaOverlays = publication.containsMediaOverlays;

    // Restore saved position.
    Locator? initialLocator;
    final savedLocatorJson =
        await ScopedPrefs.getString('epub_locator_${widget.itemId}');
    if (savedLocatorJson != null) {
      try {
        initialLocator = Locator.fromJson(
            json.decode(savedLocatorJson) as Map<String, dynamic>);
      } catch (_) {}
    }

    // Restore saved speed (per-book).
    final savedSpeed =
        await ScopedPrefs.getDouble('epub_speed_${widget.itemId}');
    if (savedSpeed != null) _speed = savedSpeed;

    // Restore global reader preferences.
    final savedFontSize = await ScopedPrefs.getDouble(_kFontSize);
    if (savedFontSize != null) _fontSize = savedFontSize;
    final savedFontFamily = await ScopedPrefs.getString(_kFontFamily);
    if (savedFontFamily != null) _fontFamily = savedFontFamily;
    final savedTheme = await ScopedPrefs.getString(_kTheme);
    if (savedTheme != null) _readerTheme = savedTheme;

    // Subscribe to reader status. Preferences are applied once the native
    // Readium view is ready — applying them before that point is a no-op.
    _readerStatusSub =
        _flureadium.onReaderStatusChanged.listen((status) {
      if (status == ReadiumReaderStatus.ready && mounted) {
        _applyPreferences();
      }
    });

    // Listen for position / progress changes.
    _locatorSub = _flureadium.onTextLocatorChanged.listen((locator) {
      _lastLocator = locator;
      _updateSectionLabel(locator, publication);
      final prog = locator.locations?.totalProgression;
      if (prog != null && mounted) {
        setState(() => _readingProgress = prog);
      }
    });

    // Set up audio if this epub has media overlays.
    if (hasMediaOverlays) {
      await _flureadium.audioEnable(
        prefs: AudioPreferences(speed: _speed),
        fromLocator: initialLocator,
      );

      _playerStateSub =
          _flureadium.onTimebasedPlayerStateChanged.listen((state) {
        if (!mounted) return;
        setState(() {
          _isPlaying = state.state == TimebasedState.playing;
          if (state.currentOffset != null) _position = state.currentOffset!;
          if (state.currentDuration != null)
            _totalDuration = state.currentDuration!;
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

  // ─── Preferences ──────────────────────────────────────────────────────

  /// Applies current reader preferences to the Readium native view.
  /// Must only be called after ReadiumReaderStatus.ready fires.
  void _applyPreferences() {
    if (!mounted) return;
    final cs = Theme.of(context).colorScheme;
    final Color bg;
    final Color fg;
    switch (_readerTheme) {
      case 'light':
        bg = _lightBg;
        fg = _lightFg;
      case 'dark':
        bg = _darkBg;
        fg = _darkFg;
      case 'sepia':
        bg = _sepiaBg;
        fg = _sepiaFg;
      default: // 'system'
        bg = cs.surface;
        fg = cs.onSurface;
    }
    _flureadium.setEPUBPreferences(EPUBPreferences(
      fontSize: _fontSize.round(),
      fontFamily: _fontFamily,
      fontWeight: 0.4,
      verticalScroll: false,
      pageMargins: 0.06,
      backgroundColor: bg,
      textColor: fg,
    ));
  }

  // ─── Section label ────────────────────────────────────────────────────

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
    // Global reader prefs are saved immediately when changed.
  }

  // ─── TOC sheet ───────────────────────────────────────────────────────

  void _showTocSheet() {
    final toc = _publication?.tableOfContents ?? [];
    if (toc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No table of contents available')));
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) {
        final cs = Theme.of(sheetCtx).colorScheme;
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          maxChildSize: 0.92,
          expand: false,
          builder: (_, scrollCtrl) => Column(
            children: [
              const SizedBox(height: 12),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              Text('Contents',
                  style: Theme.of(sheetCtx).textTheme.titleMedium),
              const SizedBox(height: 8),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  controller: scrollCtrl,
                  itemCount: toc.length,
                  itemBuilder: (_, i) {
                    final link = toc[i];
                    final title = link.title?.isNotEmpty == true
                        ? link.title!
                        : link.href;
                    return ListTile(
                      title: Text(title),
                      onTap: () {
                        Navigator.pop(sheetCtx);
                        _flureadium.goByLink(link, _publication!);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // ─── Settings sheet ───────────────────────────────────────────────────

  void _showSettingsSheet() {
    showModalBottomSheet<void>(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (sheetCtx) {
        return StatefulBuilder(builder: (sheetCtx, setSheetState) {
          final cs = Theme.of(sheetCtx).colorScheme;

          void applyAndSave() {
            _applyPreferences();
            setSheetState(() {});
          }

          return SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── Handle ──────────────────────────────────────────
                  Center(
                    child: Container(
                      width: 36,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: cs.onSurfaceVariant.withValues(alpha: 0.4),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),

                  // ── Font size ────────────────────────────────────────
                  Row(children: [
                    Text('Text size',
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 13)),
                    const Spacer(),
                    _IconStepButton(
                      icon: Icons.remove_rounded,
                      enabled: _fontSize > 14,
                      onPressed: () {
                        setState(() => _fontSize =
                            (_fontSize - 2).clamp(14, 28));
                        ScopedPrefs.setDouble(_kFontSize, _fontSize);
                        applyAndSave();
                      },
                    ),
                    SizedBox(
                      width: 40,
                      child: Text(
                        '${_fontSize.round()}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                    ),
                    _IconStepButton(
                      icon: Icons.add_rounded,
                      enabled: _fontSize < 28,
                      onPressed: () {
                        setState(() => _fontSize =
                            (_fontSize + 2).clamp(14, 28));
                        ScopedPrefs.setDouble(_kFontSize, _fontSize);
                        applyAndSave();
                      },
                    ),
                  ]),

                  const SizedBox(height: 16),

                  // ── Font family ──────────────────────────────────────
                  Text('Font',
                      style:
                          TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                  const SizedBox(height: 8),
                  Row(
                    children: List.generate(_fontFamilies.length, (i) {
                      final selected = _fontFamily == _fontFamilies[i];
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                              right: i < _fontFamilies.length - 1 ? 8 : 0),
                          child: FilledButton.tonal(
                            onPressed: () {
                              setState(() => _fontFamily = _fontFamilies[i]);
                              ScopedPrefs.setString(
                                  _kFontFamily, _fontFamily);
                              applyAndSave();
                            },
                            style: selected
                                ? FilledButton.styleFrom(
                                    backgroundColor: cs.primary,
                                    foregroundColor: cs.onPrimary,
                                  )
                                : null,
                            child: Text(_fontFamilyLabels[i]),
                          ),
                        ),
                      );
                    }),
                  ),

                  const SizedBox(height: 16),

                  // ── Theme ────────────────────────────────────────────
                  Text('Theme',
                      style:
                          TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _buildThemeOption(
                          sheetCtx, setSheetState, applyAndSave,
                          key: 'system',
                          icon: Icons.brightness_auto_rounded,
                          label: 'Auto'),
                      const SizedBox(width: 8),
                      _buildThemeOption(
                          sheetCtx, setSheetState, applyAndSave,
                          key: 'light',
                          icon: Icons.light_mode_rounded,
                          label: 'Light'),
                      const SizedBox(width: 8),
                      _buildThemeOption(
                          sheetCtx, setSheetState, applyAndSave,
                          key: 'dark',
                          icon: Icons.dark_mode_rounded,
                          label: 'Dark'),
                      const SizedBox(width: 8),
                      _buildThemeOption(
                          sheetCtx, setSheetState, applyAndSave,
                          key: 'sepia',
                          icon: Icons.wb_sunny_outlined,
                          label: 'Sepia'),
                    ],
                  ),
                ],
              ),
            ),
          );
        });
      },
    );
  }

  Widget _buildThemeOption(
    BuildContext sheetCtx,
    StateSetter setSheetState,
    VoidCallback applyAndSave, {
    required String key,
    required IconData icon,
    required String label,
  }) {
    final selected = _readerTheme == key;
    final cs = Theme.of(sheetCtx).colorScheme;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _readerTheme = key);
          ScopedPrefs.setString(_kTheme, _readerTheme);
          applyAndSave();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected
                ? cs.primary.withValues(alpha: 0.15)
                : cs.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(10),
            border: selected
                ? Border.all(color: cs.primary, width: 1.5)
                : null,
          ),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon,
                size: 20,
                color: selected ? cs.primary : cs.onSurfaceVariant),
            const SizedBox(height: 4),
            Text(label,
                style: TextStyle(
                  fontSize: 11,
                  color: selected ? cs.primary : cs.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                )),
          ]),
        ),
      ),
    );
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
    final hasPub = _publication != null;

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
          if (hasPub)
            IconButton(
              icon: const Icon(Icons.toc_rounded),
              tooltip: 'Table of contents',
              onPressed: _showTocSheet,
            ),
          if (hasPub)
            IconButton(
              icon: const Icon(Icons.text_fields_rounded),
              tooltip: 'Reading settings',
              onPressed: _showSettingsSheet,
            ),
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
    return Column(
      children: [
        LinearProgressIndicator(
          value: _readingProgress,
          minHeight: 2,
          backgroundColor: Colors.transparent,
          valueColor: AlwaysStoppedAnimation<Color>(
              cs.primary.withValues(alpha: 0.5)),
        ),
        Expanded(
          child: ReadiumReaderWidget(
            publication: _publication!,
            initialLocator: _initialLocator,
            onLocatorChanged: (locator) {
              _lastLocator = locator;
              _updateSectionLabel(locator, _publication!);
            },
          ),
        ),
      ],
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
                child: Text('$v×',
                    style: TextStyle(
                        fontWeight: _speed == v ? FontWeight.bold : FontWeight.normal,
                        color: _speed == v ? cs.primary : null)),
              ))
          .toList(),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Text(
          '$_speed×',
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

// ─── Helper widget ────────────────────────────────────────────────────────────

class _IconStepButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  const _IconStepButton({
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon),
      iconSize: 22,
      onPressed: enabled ? onPressed : null,
      color: Theme.of(context).colorScheme.onSurface,
    );
  }
}
