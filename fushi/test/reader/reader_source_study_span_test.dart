import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi/src/reader/reader_source_locator.dart';

import '../helpers/source_guard.dart' as guard;

/// BUG-5049：小说卡片「来源」回看时高亮整体往后偏（制卡词「真っ当な」，高亮落在
/// 「理由」」上）。根因：制卡写 [CardSourceLink] 时 charOffset/charLength 取的是
/// `_miningSpanRange()` 的**音频匹配坐标**（`sentenceMatchableOffset`，白名单 UTF-16
/// 码元数），而回看把它当 `Bookmark.charAnchor`，按**学习单位坐标**
/// （`getNormalizedOffset`）滚动并标落点句，两把尺子不同，高亮就错位。
void main() {
  group('readerSourceStudySpan', () {
    test('prefers the sentence span (review marks the whole sentence)', () {
      expect(
        readerSourceStudySpan(
          sentence: (offset: 40, length: 6),
          selection: (offset: 40, length: 4, text: '真っ当な'),
        ),
        (offset: 40, length: 6),
      );
    });

    test('falls back to the selection span, then null', () {
      expect(
        readerSourceStudySpan(
          sentence: null,
          selection: (offset: 40, length: 4, text: '真っ当な'),
        ),
        (offset: 40, length: 4),
      );
      expect(readerSourceStudySpan(sentence: null, selection: null), isNull);
    });

    test('a payload whose matchable coords differ keeps the study coords', () {
      // 句子前有拉丁词与全角数字时，音频匹配坐标逐字母 / 逐码元计，学习单位按词计，
      // 两者必然不同——来源链接必须取 normalized（学习单位）这一组。
      final ReaderSelectionData data =
          ReaderSelectionData.fromJson(<String, dynamic>{
            'text': '真っ当な',
            'sentence': '「真っ当な理由」',
            'normalizedOffset': 40,
            'normalizedLength': 4,
            'sentenceNormalizedOffset': 40,
            'sentenceNormalizedLength': 6,
            'matchableOffset': 44,
            'matchableLength': 4,
            'sentenceMatchableOffset': 44,
            'sentenceMatchableLength': 6,
          });
      final ({int offset, int length})? span = readerSourceStudySpan(
        sentence: (
          offset: data.sentenceNormalizedOffset!,
          length: data.sentenceNormalizedLength!,
        ),
        selection: (
          offset: data.normalizedOffset!,
          length: data.normalizedLength!,
          text: data.text,
        ),
      );
      expect(span, (offset: 40, length: 6));
      expect(span!.offset, isNot(data.sentenceMatchableOffset));
    });
  });

  group('reader mining writes source coords in study units', () {
    final String mining = File(
      'lib/src/pages/implementations/reader_fushi/mining.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    String body(String name) {
      final String? b = guard.topLevelFunctionBody(mining, name);
      expect(b, isNotNull, reason: 'missing production method $name');
      return guard.compactCode(b!);
    }

    test('_miningStudySpan reads the study-unit caches only', () {
      final String b = body('_miningStudySpan');
      expect(b, contains('readerSourceStudySpan('));
      expect(b, contains('sentence:_cachedSentenceRange'));
      expect(b, contains('selection:_cachedSelectionRange'));
      expect(b, isNot(contains('Matchable')));
    });

    test('CardSourceLink offset comes from _miningStudySpan, not audio '
        'matchable coords', () {
      final String b = body('_prepareMiningContext');
      expect(b, contains('sourceRange=_miningStudySpan();'));
      expect(b, contains('sourceOffset=sourceRange?.offset??'));
      expect(b, contains('charOffset:sourceOffset,'));
      expect(b, contains('charLength:sourceRange?.length,'));
      expect(
        b,
        isNot(contains('sourceRange=_miningSpanRange()')),
        reason: '_miningSpanRange 是音频匹配坐标，不能当回看锚点',
      );
    });

    test('mined-sentence history and char position share the same span', () {
      expect(
        body('_recordMinedSentence'),
        contains('sentenceRange=_miningStudySpan();'),
      );
      expect(
        body('_miningCharPosition'),
        contains('sentenceRange=_miningStudySpan();'),
      );
    });
  });
}
