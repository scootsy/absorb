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
  final String smilPath; // relative path inside the epub (relative to opfDir)
  final List<SmilClip> clips;
  const SmilFileInfo({required this.smilPath, required this.clips});
}

// ─── Audio offset result ─────────────────────────────────────────────────────

class SmilAudioOffsets {
  /// Audio file basenames in playback order.
  final List<String> order;

  /// Basename → absolute start Duration (cumulative).
  final Map<String, Duration> offsets;

  /// Total duration = sum of all track durations estimated from max clipEnd.
  final Duration total;

  const SmilAudioOffsets({
    required this.order,
    required this.offsets,
    required this.total,
  });
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
  int get length => _clips.length;

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

  /// Returns the absolute begin time for the clip with [fragId],
  /// or null if not found. Used for tap-to-seek.
  Duration? beginForFrag(String fragId) {
    for (final ac in _clips) {
      if (ac.clip.fragId == fragId) return ac.absoluteBegin;
    }
    return null;
  }
}

// ─── SmilService ─────────────────────────────────────────────────────────────

class SmilService {
  // ── Public API ──────────────────────────────────────────────────────────

  /// Compute audio file order and cumulative start offsets from SMIL data.
  ///
  /// Durations are estimated as the maximum [clipEnd] seen for each audio
  /// file (Option C). This matches real durations closely for Storyteller
  /// EPUBs where the last SMIL clip ends very close to the audio file's end.
  static SmilAudioOffsets computeAudioOffsets(List<SmilFileInfo> smilFiles) {
    final order = <String>[];
    final seen = <String>{};
    final maxClipEnd = <String, Duration>{};

    for (final sf in smilFiles) {
      for (final clip in sf.clips) {
        final base = p.basename(clip.audioSrc).toLowerCase();
        if (seen.add(base)) order.add(base);
        final current = maxClipEnd[base] ?? Duration.zero;
        if (clip.clipEnd > current) maxClipEnd[base] = clip.clipEnd;
      }
    }

    final offsets = <String, Duration>{};
    var acc = Duration.zero;
    for (final base in order) {
      offsets[base] = acc;
      acc += maxClipEnd[base] ?? Duration.zero;
    }

    return SmilAudioOffsets(order: order, offsets: offsets, total: acc);
  }

  /// Build a [SmilIndex] from parsed SMIL files.
  ///
  /// Audio track durations are estimated from the SMIL data itself
  /// (max clipEnd per audio file), so no external track info is needed.
  static SmilIndex buildIndex(List<SmilFileInfo> smilFiles) {
    final ao = computeAudioOffsets(smilFiles);

    final absolute = <_AbsoluteClip>[];
    for (final sf in smilFiles) {
      for (final clip in sf.clips) {
        final base = p.basename(clip.audioSrc).toLowerCase();
        final offset = ao.offsets[base];
        if (offset == null) continue;
        absolute.add(_AbsoluteClip(
          absoluteBegin: offset + clip.clipBegin,
          absoluteEnd: offset + clip.clipEnd,
          clip: clip,
        ));
      }
    }

    absolute.sort((a, b) => a.absoluteBegin.compareTo(b.absoluteBegin));
    return SmilIndex(absolute);
  }

  /// Parse a SMIL XML document and return all [SmilClip]s.
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
