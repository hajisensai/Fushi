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
      // 钉不变式而不是写法：起点字段统一走唯一写入口 [_setOpenResumePoint]
      // （某条分支只写 progress 不决定 charOffset，会让上一条分支残留的锚把视口
      // 拽回旧位置），所以这里要的是「映射出来的 studyOffset 被交给起点的
      // charOffset」，而不是某一行手写赋值长什么样。
      expect(
        audio,
        matches(RegExp(r'charOffset:\s*studyOffset')),
        reason: '音频 cue 派生的起点必须带上映射后的学习单位字符锚',
      );
      // 反过来也钉住：不得绕开写入口裸写起点字段（绕开就会留下别的分支的残留锚）。
      expect(
        RegExp(r'^\s*_initialCharOffset\s*=', multiLine: true)
            .allMatches(audio)
            .length,
        0,
        reason:
            'audiobook.part 不得绕开 _setOpenResumePoint 直接写 _initialCharOffset',
      );
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
