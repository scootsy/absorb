import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

class SmilClip {
  final String fragId;
  final String contentSrc;
  final String audioSrc;
  final Duration clipBegin;
  final Duration clipEnd;

  const SmilClip({
    required this.fragId,
    required this.contentSrc,
    required this.audioSrc,
    required this.clipBegin,
    required this.clipEnd,
  });
}

class SmilFileInfo {
  final String smilPath;
  final List<SmilClip> clips;

  const SmilFileInfo({
    required this.smilPath,
    required this.clips,
  });
}

class AudioOffsets {
  final List<String> order;
  final Map<String, Duration> offsets;
  final Duration total;

  const AudioOffsets({
    required this.order,
    required this.offsets,
    required this.total,
  });
}

class SmilIndex {
  final List<SmilClip> _clips;

  const SmilIndex(this._clips);

  bool get isEmpty => _clips.isEmpty;

  SmilClip? clipAt(Duration position) {
    var low = 0;
    var high = _clips.length - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final clip = _clips[mid];
      if (position < clip.clipBegin) {
        high = mid - 1;
      } else if (position >= clip.clipEnd) {
        low = mid + 1;
      } else {
        return clip;
      }
    }
    return null;
  }

  Duration? beginForFrag(String fragId) {
    for (final clip in _clips) {
      if (clip.fragId == fragId) return clip.clipBegin;
    }
    return null;
  }
}

class SmilService {
  static List<SmilClip> parseSmilFile(String xml) {
    try {
      final doc = XmlDocument.parse(xml);
      final clips = <SmilClip>[];

      for (final par in doc.findAllElements('par')) {
        final textElements = par.findElements('text');
        final audioElements = par.findElements('audio');
        if (textElements.isEmpty || audioElements.isEmpty) continue;

        final text = textElements.first;
        final audio = audioElements.first;

        final textSrc = text.getAttribute('src');
        final audioSrc = audio.getAttribute('src');
        final beginRaw = audio.getAttribute('clipBegin');
        final endRaw = audio.getAttribute('clipEnd');
        if (textSrc == null ||
            audioSrc == null ||
            beginRaw == null ||
            endRaw == null) {
          continue;
        }

        final hashIdx = textSrc.indexOf('#');
        if (hashIdx <= 0 || hashIdx == textSrc.length - 1) continue;
        final contentSrc = textSrc.substring(0, hashIdx);
        final fragId = textSrc.substring(hashIdx + 1);

        clips.add(SmilClip(
          fragId: fragId,
          contentSrc: contentSrc,
          audioSrc: audioSrc,
          clipBegin: _parseTime(beginRaw),
          clipEnd: _parseTime(endRaw),
        ));
      }

      return clips;
    } catch (_) {
      return const [];
    }
  }

  static SmilIndex buildIndex(List<SmilFileInfo> smilFiles) {
    final merged = <SmilClip>[];
    var runningOffset = Duration.zero;

    for (final file in smilFiles) {
      Duration fileEnd = Duration.zero;
      for (final clip in file.clips) {
        if (clip.clipEnd > fileEnd) fileEnd = clip.clipEnd;
        merged.add(SmilClip(
          fragId: clip.fragId,
          contentSrc: clip.contentSrc,
          audioSrc: clip.audioSrc,
          clipBegin: runningOffset + clip.clipBegin,
          clipEnd: runningOffset + clip.clipEnd,
        ));
      }
      runningOffset += fileEnd;
    }

    return SmilIndex(merged);
  }

  static AudioOffsets computeAudioOffsets(List<SmilFileInfo> smilFiles) {
    final order = <String>[];
    final offsets = <String, Duration>{};
    var chapterOffset = Duration.zero;

    for (final file in smilFiles) {
      Duration fileEnd = Duration.zero;
      for (final clip in file.clips) {
        if (clip.clipEnd > fileEnd) fileEnd = clip.clipEnd;
        final audioKey = p.basename(clip.audioSrc);
        offsets.putIfAbsent(audioKey, () {
          order.add(audioKey);
          return chapterOffset;
        });
      }
      chapterOffset += fileEnd;
    }

    return AudioOffsets(order: order, offsets: offsets, total: chapterOffset);
  }

  static Duration _parseTime(String raw) {
    var value = raw.trim();
    if (value == '0') return Duration.zero;
    if (value.endsWith('s')) value = value.substring(0, value.length - 1);

    final parts = value.split(':');
    if (parts.length == 3) {
      final secAndMs = _splitSecondFraction(parts[2]);
      return Duration(
        hours: int.parse(parts[0]),
        minutes: int.parse(parts[1]),
        seconds: secAndMs.$1,
        milliseconds: secAndMs.$2,
      );
    }
    if (parts.length == 2) {
      final secAndMs = _splitSecondFraction(parts[1]);
      return Duration(
        minutes: int.parse(parts[0]),
        seconds: secAndMs.$1,
        milliseconds: secAndMs.$2,
      );
    }

    final secAndMs = _splitSecondFraction(parts[0]);
    return Duration(seconds: secAndMs.$1, milliseconds: secAndMs.$2);
  }

  static (int, int) _splitSecondFraction(String value) {
    final seg = value.split('.');
    final seconds = int.parse(seg[0]);
    if (seg.length == 1) return (seconds, 0);

    final frac = seg[1];
    final ms = int.parse(frac.padRight(3, '0').substring(0, 3));
    return (seconds, ms);
  }
}
