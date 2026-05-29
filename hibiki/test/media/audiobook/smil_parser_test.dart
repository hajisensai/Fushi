import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  group('SmilParser.parseString', () {
    test('parses basic SMIL with audio clips', () {
      const smil = '''<?xml version="1.0" encoding="UTF-8"?>
<smil xmlns="http://www.w3.org/ns/SMIL" version="3.0">
  <body>
    <seq>
      <par>
        <text src="chapter.xhtml#p1"/>
        <audio src="audio.mp3" clipBegin="0" clipEnd="2.5"/>
      </par>
      <par>
        <text src="chapter.xhtml#p2"/>
        <audio src="audio.mp3" clipBegin="2.5" clipEnd="5.0"/>
      </par>
    </seq>
  </body>
</smil>''';

      final cues = SmilParser.parseString(
        content: smil,
        bookUid: 'book/1',
        chapterHref: 'OEBPS/chapter.xhtml',
      );

      expect(cues, hasLength(2));
      expect(cues[0].textFragmentId, '#p1');
      expect(cues[0].startMs, 0);
      expect(cues[0].endMs, 2500);
      expect(cues[0].sentenceIndex, 0);
      expect(cues[0].bookUid, 'book/1');
      expect(cues[0].chapterHref, 'OEBPS/chapter.xhtml');
      expect(cues[1].textFragmentId, '#p2');
      expect(cues[1].startMs, 2500);
      expect(cues[1].endMs, 5000);
      expect(cues[1].sentenceIndex, 1);
    });

    test('handles hh:mm:ss.sss time format', () {
      const smil = '''<smil xmlns="http://www.w3.org/ns/SMIL">
  <body>
    <par>
      <text src="ch.xhtml#s1"/>
      <audio src="a.mp3" clipBegin="0:01:30.500" clipEnd="0:02:00.000"/>
    </par>
  </body>
</smil>''';

      final cues = SmilParser.parseString(
        content: smil,
        bookUid: 'b',
        chapterHref: 'ch.xhtml',
      );

      expect(cues, hasLength(1));
      expect(cues[0].startMs, 90500);
      expect(cues[0].endMs, 120000);
    });

    test('uses audioFileMap for multi-file index', () {
      const smil = '''<smil xmlns="http://www.w3.org/ns/SMIL">
  <body>
    <par>
      <text src="ch.xhtml#s1"/>
      <audio src="track02.mp3" clipBegin="0" clipEnd="1.0"/>
    </par>
  </body>
</smil>''';

      final cues = SmilParser.parseString(
        content: smil,
        bookUid: 'b',
        chapterHref: 'ch.xhtml',
        audioFileMap: {'track01.mp3': 0, 'track02.mp3': 1},
      );

      expect(cues.single.audioFileIndex, 1);
    });

    test('defaults audioFileIndex to 0 without audioFileMap', () {
      const smil = '''<smil xmlns="http://www.w3.org/ns/SMIL">
  <body>
    <par>
      <text src="ch.xhtml#s1"/>
      <audio src="any.mp3" clipBegin="0" clipEnd="1"/>
    </par>
  </body>
</smil>''';

      final cues = SmilParser.parseString(
        content: smil,
        bookUid: 'b',
        chapterHref: 'ch.xhtml',
      );

      expect(cues.single.audioFileIndex, 0);
    });

    test('skips par elements missing text or audio', () {
      const smil = '''<smil xmlns="http://www.w3.org/ns/SMIL">
  <body>
    <par>
      <text src="ch.xhtml#s1"/>
    </par>
    <par>
      <audio src="a.mp3" clipBegin="0" clipEnd="1"/>
    </par>
    <par>
      <text src="ch.xhtml#s2"/>
      <audio src="a.mp3" clipBegin="1" clipEnd="2"/>
    </par>
  </body>
</smil>''';

      final cues = SmilParser.parseString(
        content: smil,
        bookUid: 'b',
        chapterHref: 'ch.xhtml',
      );

      expect(cues, hasLength(1));
      expect(cues[0].textFragmentId, '#s2');
    });

    test('returns empty for SMIL with no par elements', () {
      const smil = '''<smil xmlns="http://www.w3.org/ns/SMIL">
  <body><seq></seq></body>
</smil>''';

      final cues = SmilParser.parseString(
        content: smil,
        bookUid: 'b',
        chapterHref: 'ch.xhtml',
      );

      expect(cues, isEmpty);
    });

    test('text without fragment uses full src as fragmentId', () {
      const smil = '''<smil xmlns="http://www.w3.org/ns/SMIL">
  <body>
    <par>
      <text src="ch.xhtml"/>
      <audio src="a.mp3" clipBegin="0" clipEnd="1"/>
    </par>
  </body>
</smil>''';

      final cues = SmilParser.parseString(
        content: smil,
        bookUid: 'b',
        chapterHref: 'ch.xhtml',
      );

      expect(cues.single.textFragmentId, 'ch.xhtml');
    });

    test('handles mm:ss.sss time format', () {
      const smil = '''<smil xmlns="http://www.w3.org/ns/SMIL">
  <body>
    <par>
      <text src="ch.xhtml#p1"/>
      <audio src="a.mp3" clipBegin="01:30.500" clipEnd="02:00.000"/>
    </par>
  </body>
</smil>''';

      final cues = SmilParser.parseString(
        content: smil,
        bookUid: 'b',
        chapterHref: 'ch.xhtml',
      );
      expect(cues, hasLength(1));
      expect(cues[0].startMs, 90500);
      expect(cues[0].endMs, 120000);
    });

    test('handles bare seconds time format', () {
      const smil = '''<smil xmlns="http://www.w3.org/ns/SMIL">
  <body>
    <par>
      <text src="ch.xhtml#p1"/>
      <audio src="a.mp3" clipBegin="5.5" clipEnd="10.0"/>
    </par>
  </body>
</smil>''';

      final cues = SmilParser.parseString(
        content: smil,
        bookUid: 'b',
        chapterHref: 'ch.xhtml',
      );
      expect(cues, hasLength(1));
      expect(cues[0].startMs, 5500);
      expect(cues[0].endMs, 10000);
    });

    test('handles unit-suffixed clock values s/ms/min (HBK-AUDIT-024)', () {
      const smil = '''<smil xmlns="http://www.w3.org/ns/SMIL">
  <body>
    <par>
      <text src="ch.xhtml#p1"/>
      <audio src="a.mp3" clipBegin="4.5s" clipEnd="4230ms"/>
    </par>
    <par>
      <text src="ch.xhtml#p2"/>
      <audio src="a.mp3" clipBegin="0.1min" clipEnd="7s"/>
    </par>
  </body>
</smil>''';

      final cues = SmilParser.parseString(
        content: smil,
        bookUid: 'b',
        chapterHref: 'ch.xhtml',
      );
      // Previously these unit-tagged values returned null and the cues were
      // dropped; now they parse.
      expect(cues, hasLength(2));
      expect(cues[0].startMs, 4500); // 4.5s
      expect(cues[0].endMs, 4230); // 4230ms
      expect(cues[1].startMs, 6000); // 0.1min
      expect(cues[1].endMs, 7000); // 7s
    });

    test('empty body returns empty list', () {
      const smil = '''<smil xmlns="http://www.w3.org/ns/SMIL">
  <body/>
</smil>''';

      final cues = SmilParser.parseString(
        content: smil,
        bookUid: 'b',
        chapterHref: 'ch.xhtml',
      );
      expect(cues, isEmpty);
    });
  });
}
