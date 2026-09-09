import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_audio_position.dart';

void main() {
  test('Latin and astral CJK audio coordinates convert to study range', () {
    final ReaderAudioPositionIndex index =
        ReaderAudioPositionIndex.fromChapterHtml(
          '<body>ABC 123𠮷<ruby>猫<rt>ねこ</rt></ruby>だ。</body>',
        );
    expect(index.studyRangeForFragment(matchableStart: 8, matchableEnd: 10), (
      offset: 3,
      length: 2,
    ));
  });

  test('node boundaries preserve reader word accounting', () {
    final ReaderAudioPositionIndex index =
        ReaderAudioPositionIndex.fromChapterHtml(
          '<body><span>ab</span><em>cd</em><p>猫</p></body>',
        );
    expect(index.studyRangeForFragment(matchableStart: 4, matchableEnd: 5), (
      offset: 2,
      length: 1,
    ));
  });

  test('word prefixes do not count unfinished study units', () {
    final ReaderAudioPositionIndex index =
        ReaderAudioPositionIndex.fromChapterHtml('<body>ABC 猫</body>');
    expect(index.studyRangeForFragment(matchableStart: 1, matchableEnd: 2), (
      offset: 0,
      length: 0,
    ));
    expect(index.studyRangeForFragment(matchableStart: 1, matchableEnd: 3), (
      offset: 0,
      length: 1,
    ));
  });

  test(
    'nonmatchable study units and transparent apostrophes are accounted for',
    () {
      final ReaderAudioPositionIndex index =
          ReaderAudioPositionIndex.fromChapterHtml(
            '<body>don\'t café русский 𠮷猫</body>',
          );
      expect(index.studyRangeForFragment(matchableStart: 9, matchableEnd: 10), (
        offset: 4,
        length: 1,
      ));
      expect(index.studyRangeForFragment(matchableStart: 4, matchableEnd: 7), (
        offset: 1,
        length: 0,
      ));
    },
  );

  test('matched EPUB fragment does not require verbatim subtitle equality', () {
    // A fuzzy SRT match can pair "猫なんだ" with the EPUB fragment "猫だ".
    // Its persisted position is authoritative; no text-search replacement is used.
    final ReaderAudioPositionIndex index =
        ReaderAudioPositionIndex.fromChapterHtml('<body>ABC猫だ犬猫だ</body>');
    expect(index.studyRangeForFragment(matchableStart: 6, matchableEnd: 8), (
      offset: 4,
      length: 2,
    ));
  });

  test('invalid ranges and split surrogate boundaries are rejected', () {
    final ReaderAudioPositionIndex index =
        ReaderAudioPositionIndex.fromChapterHtml('<body>ABC𠮷猫</body>');
    for (final (int start, int end) in <(int, int)>[
      (-1, 0),
      (6, 7),
      (4, 5),
      (3, 4),
      (3, 3),
    ]) {
      expect(
        index.studyRangeForFragment(matchableStart: start, matchableEnd: end),
        isNull,
      );
    }
    expect(index.studyRangeForFragment(matchableStart: 3, matchableEnd: 5), (
      offset: 1,
      length: 1,
    ));
  });

  test(
    'restore, cross chapter, lyrics persistence and favorites convert positions',
    () {
      const String base = 'lib/src/pages/implementations/reader_fushi/';
      final String audio = File(
        '${base}audiobook.part.dart',
      ).readAsStringSync();
      final String navigation = File(
        '${base}navigation.part.dart',
      ).readAsStringSync();
      final String lookup = File('${base}lookup.part.dart').readAsStringSync();
      expect(audio, contains('_initialCharOffset = studyOffset'));
      expect(
        audio,
        contains('_navigateToChapter(newSection, charOffset: studyOffset)'),
      );
      expect(navigation, contains('_lastProgressCharOffset = studyOffset'));
      expect(
        navigation,
        isNot(contains('frag.normCharStart / _chapterCharCounts')),
      );
      expect(audio, isNot(contains('normCharStart: frag.normCharStart')));
      expect(lookup, contains('_cachedSentenceRange = studyRange'));
      expect(lookup, contains('_studyRangeForAudioFragment(frag)'));
    },
  );
}
