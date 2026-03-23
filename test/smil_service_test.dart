import 'package:flutter_test/flutter_test.dart';
import 'package:absorb/services/smil_service.dart';

void main() {
  // ─── _parseTime (via parseSmilFile round-trip) ─────────────────────────

  group('SmilService.parseSmilFile', () {
    test('parses basic par elements', () {
      const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
  <body>
    <seq>
      <par id="p1">
        <text src="chapter01.xhtml#s001"/>
        <audio src="audio/chapter01.m4a" clipBegin="0:00:00.000" clipEnd="0:00:03.200"/>
      </par>
      <par id="p2">
        <text src="chapter01.xhtml#s002"/>
        <audio src="audio/chapter01.m4a" clipBegin="0:00:03.200" clipEnd="0:00:07.500"/>
      </par>
    </seq>
  </body>
</smil>''';

      final clips = SmilService.parseSmilFile(xml);
      expect(clips.length, 2);

      expect(clips[0].fragId, 's001');
      expect(clips[0].contentSrc, 'chapter01.xhtml');
      expect(clips[0].audioSrc, 'audio/chapter01.m4a');
      expect(clips[0].clipBegin, Duration.zero);
      expect(clips[0].clipEnd, const Duration(milliseconds: 3200));

      expect(clips[1].fragId, 's002');
      expect(clips[1].clipBegin, const Duration(milliseconds: 3200));
      expect(clips[1].clipEnd, const Duration(milliseconds: 7500));
    });

    test('skips par elements missing text or audio', () {
      const xml = '''<?xml version="1.0"?>
<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
  <body>
    <par id="p1">
      <text src="ch.xhtml#s1"/>
    </par>
    <par id="p2">
      <audio src="audio/ch.m4a" clipBegin="0:00:00.000" clipEnd="0:00:02.000"/>
    </par>
    <par id="p3">
      <text src="ch.xhtml#s3"/>
      <audio src="audio/ch.m4a" clipBegin="0:00:05.000" clipEnd="0:00:08.000"/>
    </par>
  </body>
</smil>''';

      final clips = SmilService.parseSmilFile(xml);
      expect(clips.length, 1);
      expect(clips[0].fragId, 's3');
    });

    test('skips text elements with no fragment id', () {
      const xml = '''<?xml version="1.0"?>
<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
  <body>
    <par>
      <text src="chapter01.xhtml"/>
      <audio src="audio/ch.m4a" clipBegin="0:00:00.000" clipEnd="0:00:01.000"/>
    </par>
  </body>
</smil>''';

      final clips = SmilService.parseSmilFile(xml);
      expect(clips, isEmpty);
    });

    test('returns empty list for invalid XML', () {
      final clips = SmilService.parseSmilFile('not xml at all');
      expect(clips, isEmpty);
    });
  });

  // ─── Time parsing ──────────────────────────────────────────────────────

  group('SmilService time parsing (via parseSmilFile)', () {
    SmilClip _clip(String begin, String end) {
      final xml = '''<?xml version="1.0"?>
<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
  <body>
    <par>
      <text src="ch.xhtml#s1"/>
      <audio src="audio/ch.m4a" clipBegin="$begin" clipEnd="$end"/>
    </par>
  </body>
</smil>''';
      return SmilService.parseSmilFile(xml).first;
    }

    test('H:MM:SS.mmm', () {
      final c = _clip('1:23:45.678', '2:00:00.000');
      expect(c.clipBegin,
          const Duration(hours: 1, minutes: 23, seconds: 45, milliseconds: 678));
      expect(c.clipEnd, const Duration(hours: 2));
    });

    test('MM:SS.mmm', () {
      final c = _clip('23:45.678', '59:59.999');
      expect(c.clipBegin,
          const Duration(minutes: 23, seconds: 45, milliseconds: 678));
    });

    test('SS.mmm', () {
      final c = _clip('45.678', '120.000');
      expect(c.clipBegin, const Duration(seconds: 45, milliseconds: 678));
      expect(c.clipEnd, const Duration(seconds: 120));
    });

    test('trailing s suffix', () {
      final c = _clip('3.5s', '7.25s');
      expect(c.clipBegin, const Duration(seconds: 3, milliseconds: 500));
      expect(c.clipEnd, const Duration(seconds: 7, milliseconds: 250));
    });

    test('zero', () {
      final c = _clip('0', '0');
      expect(c.clipBegin, Duration.zero);
    });

    test('fractional seconds with fewer than 3 digits', () {
      // "3.5" should be 3500ms, not 5ms
      final c = _clip('3.5', '10.50');
      expect(c.clipBegin, const Duration(seconds: 3, milliseconds: 500));
      expect(c.clipEnd, const Duration(seconds: 10, milliseconds: 500));
    });
  });

  // ─── SmilIndex binary search ────────────────────────────────────────────

  group('SmilIndex.clipAt', () {
    // Build a minimal index: one audio file, three clips
    SmilIndex _buildTestIndex() {
      const xml = '''<?xml version="1.0"?>
<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
  <body>
    <par><text src="ch.xhtml#s1"/>
      <audio src="audio/ch.m4a" clipBegin="0:00:00.000" clipEnd="0:00:03.000"/>
    </par>
    <par><text src="ch.xhtml#s2"/>
      <audio src="audio/ch.m4a" clipBegin="0:00:03.000" clipEnd="0:00:07.000"/>
    </par>
    <par><text src="ch.xhtml#s3"/>
      <audio src="audio/ch.m4a" clipBegin="0:00:07.000" clipEnd="0:00:10.500"/>
    </par>
  </body>
</smil>''';
      final clips = SmilService.parseSmilFile(xml);
      final sf = SmilFileInfo(smilPath: 'chapter01.smil', clips: clips);
      return SmilService.buildIndex([sf]);
    }

    test('returns correct clip for positions within ranges', () {
      final idx = _buildTestIndex();
      expect(idx.clipAt(Duration.zero)?.fragId, 's1');
      expect(idx.clipAt(const Duration(seconds: 1))?.fragId, 's1');
      expect(idx.clipAt(const Duration(milliseconds: 2999))?.fragId, 's1');
      expect(idx.clipAt(const Duration(seconds: 3))?.fragId, 's2');
      expect(idx.clipAt(const Duration(seconds: 5))?.fragId, 's2');
      expect(idx.clipAt(const Duration(milliseconds: 6999))?.fragId, 's2');
      expect(idx.clipAt(const Duration(seconds: 7))?.fragId, 's3');
      expect(idx.clipAt(const Duration(milliseconds: 10499))?.fragId, 's3');
    });

    test('returns null past the last clip', () {
      final idx = _buildTestIndex();
      expect(idx.clipAt(const Duration(seconds: 11)), isNull);
    });

    test('returns null for empty index', () {
      final idx = SmilService.buildIndex([]);
      expect(idx.clipAt(Duration.zero), isNull);
      expect(idx.isEmpty, isTrue);
    });
  });

  // ─── SmilIndex.beginForFrag ─────────────────────────────────────────────

  group('SmilIndex.beginForFrag', () {
    SmilIndex _buildIndex() {
      const xml = '''<?xml version="1.0"?>
<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
  <body>
    <par><text src="ch.xhtml#sentence-1"/>
      <audio src="audio/ch.m4a" clipBegin="0:00:01.000" clipEnd="0:00:04.500"/>
    </par>
    <par><text src="ch.xhtml#sentence-2"/>
      <audio src="audio/ch.m4a" clipBegin="0:00:04.500" clipEnd="0:00:09.000"/>
    </par>
  </body>
</smil>''';
      final sf = SmilFileInfo(
          smilPath: 'ch.smil', clips: SmilService.parseSmilFile(xml));
      return SmilService.buildIndex([sf]);
    }

    test('returns correct begin time for known fragment', () {
      final idx = _buildIndex();
      expect(idx.beginForFrag('sentence-1'), const Duration(seconds: 1));
      expect(idx.beginForFrag('sentence-2'), const Duration(milliseconds: 4500));
    });

    test('returns null for unknown fragment', () {
      final idx = _buildIndex();
      expect(idx.beginForFrag('nonexistent'), isNull);
    });
  });

  // ─── computeAudioOffsets ───────────────────────────────────────────────

  group('SmilService.computeAudioOffsets', () {
    test('single audio file', () {
      const xml = '''<?xml version="1.0"?>
<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
  <body>
    <par><text src="ch.xhtml#s1"/>
      <audio src="audio/ch01.m4a" clipBegin="0:00:00.000" clipEnd="0:00:05.000"/>
    </par>
    <par><text src="ch.xhtml#s2"/>
      <audio src="audio/ch01.m4a" clipBegin="0:00:05.000" clipEnd="0:00:12.300"/>
    </par>
  </body>
</smil>''';
      final sf = SmilFileInfo(smilPath: 'ch01.smil', clips: SmilService.parseSmilFile(xml));
      final ao = SmilService.computeAudioOffsets([sf]);

      expect(ao.order, ['ch01.m4a']);
      expect(ao.offsets['ch01.m4a'], Duration.zero);
      expect(ao.total, const Duration(milliseconds: 12300));
    });

    test('two audio files, offsets accumulate', () {
      final sf1 = SmilFileInfo(smilPath: 'ch01.smil', clips: SmilService.parseSmilFile('''
<?xml version="1.0"?><smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body>
  <par><text src="ch01.xhtml#s1"/>
    <audio src="audio/ch01.m4a" clipBegin="0" clipEnd="10.000"/>
  </par>
</body></smil>'''));
      final sf2 = SmilFileInfo(smilPath: 'ch02.smil', clips: SmilService.parseSmilFile('''
<?xml version="1.0"?><smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body>
  <par><text src="ch02.xhtml#s1"/>
    <audio src="audio/ch02.m4a" clipBegin="0" clipEnd="15.500"/>
  </par>
</body></smil>'''));
      final ao = SmilService.computeAudioOffsets([sf1, sf2]);

      expect(ao.order, ['ch01.m4a', 'ch02.m4a']);
      expect(ao.offsets['ch01.m4a'], Duration.zero);
      expect(ao.offsets['ch02.m4a'], const Duration(seconds: 10));
      expect(ao.total,
          const Duration(seconds: 10) + const Duration(milliseconds: 15500));
    });
  });

  // ─── Multi-chapter buildIndex ──────────────────────────────────────────

  group('SmilService.buildIndex (multi-chapter)', () {
    test('clips span two audio files with correct absolute offsets', () {
      final sf1 = SmilFileInfo(smilPath: 'ch01.smil', clips: SmilService.parseSmilFile('''
<?xml version="1.0"?><smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body>
  <par><text src="ch01.xhtml#a"/>
    <audio src="audio/ch01.m4a" clipBegin="0" clipEnd="5.000"/>
  </par>
</body></smil>'''));
      final sf2 = SmilFileInfo(smilPath: 'ch02.smil', clips: SmilService.parseSmilFile('''
<?xml version="1.0"?><smil xmlns="http://www.w3.org/ns/SMIL" version="3.0"><body>
  <par><text src="ch02.xhtml#b"/>
    <audio src="audio/ch02.m4a" clipBegin="0" clipEnd="3.000"/>
  </par>
</body></smil>'''));
      final idx = SmilService.buildIndex([sf1, sf2]);

      // ch01 starts at 0, ch02 starts at 5s
      expect(idx.clipAt(Duration.zero)?.fragId, 'a');
      expect(idx.clipAt(const Duration(seconds: 4))?.fragId, 'a');
      expect(idx.clipAt(const Duration(seconds: 5))?.fragId, 'b');
      expect(idx.clipAt(const Duration(seconds: 7))?.fragId, 'b');
      expect(idx.clipAt(const Duration(seconds: 9)), isNull);
    });
  });
}
