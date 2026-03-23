import 'package:xml/xml.dart';
import 'package:path/path.dart' as p;

// ─── Data types ─────────────────────────────────────────────────────────────

/// A single synchronized clip: one audio segment paired with one text fragment.
class SmilClip {
  /// Relative path to the audio file (as written in the SMIL src attribute).
  final String audioSrc;

  /// Start time within [audioSrc].
  final Duration clipBegin;

  /// End time within [audioSrc].
  final Duration clipEnd;

  /// Relative path to the content HTML file (fragment stripped).
  final String contentSrc;

  /// Element id inside [contentSrc] that should be highlighted.
  final String fragId;

  const SmilClip({
    required this.audioSrc,
    required this.clipBegin,
    required this.clipEnd,
    required this.contentSrc,
    required this.fragId,
  });
}

/// Parsed SMIL file: a path and the list of clips it contains.
class SmilFileInfo {
  final String smilPath; // relative path inside the epub
  final List<SmilClip> clips;
  const SmilFileInfo({required this.smilPath, required this.clips});
}

// ─── Absolute clip (used internally in SmilIndex) ───────────────────────────

class _AbsoluteClip {
  final Duration absoluteBegin;
  final Duration absoluteEnd;
  final SmilClip clip;
  _AbsoluteClip({
    required this.absoluteBegin,
    required this.absoluteEnd,
    required this.clip,
  });
}

// ─── SmilIndex ───────────────────────────────────────────────────────────────

/// A sorted, searchable index of all SMIL clips mapped to absolute playback
/// positions (accounting for track offsets).
class SmilIndex {
  final List<_AbsoluteClip> _clips;

  SmilIndex(this._clips);

  bool get isEmpty => _clips.isEmpty;

  /// Returns the [SmilClip] whose absolute time range contains [position],
  /// or null if no clip matches.
  SmilClip? clipAt(Duration position) {
    if (_clips.isEmpty) return null;
    int lo = 0, hi = _clips.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final c = _clips[mid];
      if (position < c.absoluteBegin) {
        hi = mid - 1;
      } else if (position >= c.absoluteEnd) {
        lo = mid + 1;
      } else {
        return c.clip;
      }
    }
    return null;
  }
}

// ─── SmilService ─────────────────────────────────────────────────────────────

class SmilService {
  // ── Public API ──────────────────────────────────────────────────────────

  /// Build a [SmilIndex] from the parsed SMIL files and the server's track info.
  ///
  /// [audioTrackBasenames] — file basenames in playback order, e.g. `['ch1.mp3', 'ch2.mp3']`
  /// [audioTrackDurations] — durations in seconds, same order as basenames
  static SmilIndex buildIndex({
    required List<SmilFileInfo> smilFiles,
    required List<String> audioTrackBasenames,
    required List<double> audioTrackDurations,
  }) {
    // Map: lowercase basename -> absolute start Duration
    final offsetMap = <String, Duration>{};
    var acc = Duration.zero;
    for (int i = 0; i < audioTrackBasenames.length; i++) {
      final name = audioTrackBasenames[i].toLowerCase();
      offsetMap[name] = acc;
      acc += Duration(milliseconds: (audioTrackDurations[i] * 1000).round());
    }

    final absolute = <_AbsoluteClip>[];
    for (final smilFile in smilFiles) {
      for (final clip in smilFile.clips) {
        final audioBase = p.basename(clip.audioSrc).toLowerCase();
        final trackOffset = offsetMap[audioBase];
        if (trackOffset == null) continue; // can't map — skip
        absolute.add(_AbsoluteClip(
          absoluteBegin: trackOffset + clip.clipBegin,
          absoluteEnd: trackOffset + clip.clipEnd,
          clip: clip,
        ));
      }
    }

    absolute.sort((a, b) => a.absoluteBegin.compareTo(b.absoluteBegin));
    return SmilIndex(absolute);
  }

  /// Parse a SMIL XML document and return all [SmilClip]s.
  ///
  /// [smilContent] — raw XML string of the SMIL file.
  static List<SmilClip> parseSmilFile(String smilContent) {
    final clips = <SmilClip>[];
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(smilContent);
    } catch (_) {
      return clips;
    }

    for (final par in doc.findAllElements('par')) {
      final textEl = par.findElements('text').firstOrNull;
      final audioEl = par.findElements('audio').firstOrNull;
      if (textEl == null || audioEl == null) continue;

      final textSrc = textEl.getAttribute('src') ?? '';
      final audioSrc = audioEl.getAttribute('src') ?? '';
      final beginStr = audioEl.getAttribute('clipBegin') ?? '0';
      final endStr = audioEl.getAttribute('clipEnd') ?? '0';

      if (textSrc.isEmpty || audioSrc.isEmpty) continue;

      final hashIdx = textSrc.indexOf('#');
      final contentSrc = hashIdx >= 0 ? textSrc.substring(0, hashIdx) : textSrc;
      final fragId = hashIdx >= 0 ? textSrc.substring(hashIdx + 1) : '';
      if (fragId.isEmpty) continue;

      clips.add(SmilClip(
        audioSrc: audioSrc,
        clipBegin: _parseTime(beginStr),
        clipEnd: _parseTime(endStr),
        contentSrc: contentSrc,
        fragId: fragId,
      ));
    }

    return clips;
  }

  // ── Internal time parsing ────────────────────────────────────────────────

  // Supports: "H:MM:SS.mmm", "MM:SS.mmm", "SS.mmm", and an optional trailing 's'
  static Duration _parseTime(String s) {
    s = s.trim();
    if (s.endsWith('s')) s = s.substring(0, s.length - 1);
    try {
      final colonParts = s.split(':');
      if (colonParts.length == 3) {
        final h = int.parse(colonParts[0]);
        final m = int.parse(colonParts[1]);
        final (sec, ms) = _splitSeconds(colonParts[2]);
        return Duration(hours: h, minutes: m, seconds: sec, milliseconds: ms);
      } else if (colonParts.length == 2) {
        final m = int.parse(colonParts[0]);
        final (sec, ms) = _splitSeconds(colonParts[1]);
        return Duration(minutes: m, seconds: sec, milliseconds: ms);
      } else {
        final (sec, ms) = _splitSeconds(s);
        return Duration(seconds: sec, milliseconds: ms);
      }
    } catch (_) {
      return Duration.zero;
    }
  }

  static (int, int) _splitSeconds(String s) {
    final dotParts = s.split('.');
    final sec = int.parse(dotParts[0]);
    if (dotParts.length < 2) return (sec, 0);
    var frac = dotParts[1];
    while (frac.length < 3) frac += '0';
    if (frac.length > 3) frac = frac.substring(0, 3);
    return (sec, int.parse(frac));
  }
}
