import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// BUG-4824：点词查词的选区状态（选区 / 句子范围、音频坐标选区、所属章号）原先写在
/// `await _runLookupAndHighlight` 之后，而 currentSentence / 句偏移 / cue 写在之前。
///
/// - 查词在飞时这组字段是「新句子 + 新 cue + 旧选区范围」的混合态；
/// - `_runLookupAndHighlight` 没有代际守卫，连点两个词时先点那次的尾段会在后点那次
///   之后落下，留下与弹窗不符的范围（收藏 / 制卡 / 片段导出都读它）。
///
/// 修法是结构性的：整组字段只有一个**同步**写点 `_applyLookupStateFromSelectionData`
/// （拖选菜单 / 原生选区经 `_fillLookupStateFromSelectionData` 也走它），点词在 await
/// 之前调它，await 之后不再写。时序本身只有真 WebView 上才跑得出来，这里钉住让时序
/// 成立的三件事：写点同步、点词在 await 前调、await 后没有尾段。
void main() {
  final String lookup = File(
    'lib/src/pages/implementations/reader_fushi/lookup.part.dart',
  ).readAsStringSync();
  final String chrome = File(
    'lib/src/pages/implementations/reader_fushi/chrome.part.dart',
  ).readAsStringSync();

  const String applySignature =
      'void _applyLookupStateFromSelectionData(ReaderSelectionData data) {';

  /// 选区状态里由 `_applyLookupStateFromSelectionData` 负责的字段。
  const List<String> stateFields = <String>[
    '_cachedSentenceOffset',
    '_lookupCue',
    '_cachedSelectionRange',
    '_cachedSentenceRange',
    '_cachedSelectionSectionIndex',
  ];

  bool assigns(String code, String field) => RegExp(
    r'(?<![A-Za-z0-9_$])' + RegExp.escape(field) + r'\s*(\?\?)?=(?!=)',
  ).hasMatch(code);

  group('_applyLookupStateFromSelectionData：唯一写点', () {
    final String code = maskComments(methodBody(chrome, applySignature));

    test('是同步函数：没有 await，返回 void', () {
      expect(
        containsIdentifier(code, 'await'),
        isFalse,
        reason: '往写点里加 await 就把「await 之前一次写齐」的保证拆了',
      );
      expect(
        maskComments(chrome),
        isNot(contains('Future<void> $applySignature')),
      );
    });

    test('一次写齐整组选区状态', () {
      expect(code, contains('setCurrentSentence('));
      expect(
        code,
        contains('ReaderSelectionScripts.resolveCurrentSentenceText('),
      );
      expect(code, contains('_cacheMatchableSelection(data);'));
      expect(code, contains('_lookupCue = _cueForSelectionData(data);'));
      for (final String field in stateFields) {
        expect(assigns(code, field), isTrue, reason: '$field 必须在写点里赋值');
      }
      // 章号快照取自 cue 定下之后的 _lookupSectionIndex。
      expect(
        code.indexOf('_cachedSelectionSectionIndex = _lookupSectionIndex;'),
        greaterThan(code.indexOf('_lookupCue = _cueForSelectionData(data);')),
      );
    });

    test('清空上一次选区抽出的插图', () {
      // 行为变化、方向是对的：原先点词路径不碰 _cachedSelectionImages，「原生选区抽过
      // 图 → 再点词」会把旧图带进这次查词的片段导出。
      expect(code, contains('_resetSelectionImages();'));
      final String reset = maskComments(
        methodBody(chrome, 'void _resetSelectionImages() {'),
      );
      expect(
        compactCode(reset),
        contains(
          '_cachedSelectionImages=const<({intnormOffset,Uint8Listbytes})>[];',
        ),
      );
      // 同时作废在途的抽图：换令牌。
      expect(reset, contains('_selectionImagesOwner = Object();'));
    });

    test('歌词点词、关弹窗同样清图并作废在途抽图', () {
      final String handler = maskComments(
        methodBody(lookup, 'Future<void> _handleTextSelected('),
      );
      final int lyricsStart = handler.indexOf('if (_lyricsMode) {');
      expect(lyricsStart, isNonNegative);
      final int reset = handler.indexOf(
        '_resetSelectionImages();',
        lyricsStart,
      );
      expect(reset, isNonNegative, reason: '歌词分支不经正文写点，要自己清');
      expect(
        reset,
        lessThan(handler.indexOf('await ', lyricsStart)),
        reason: '在歌词分支第一个 await 之前清',
      );
      final String page = File(
        'lib/src/pages/implementations/reader_fushi_page.dart',
      ).readAsStringSync();
      expect(
        maskComments(methodBody(page, 'void clearDictionaryResult() {')),
        contains('_resetSelectionImages();'),
      );
    });
  });

  group('_fillLookupStateFromSelectionData：拖选 / 原生选区走同一个写点', () {
    final String code = maskComments(
      methodBody(chrome, 'Future<void> _fillLookupStateFromSelectionData('),
    );

    test('先同步写状态，再按需抽图', () {
      final int apply = code.indexOf(
        '_applyLookupStateFromSelectionData(data);',
      );
      expect(apply, isNonNegative);
      final int firstAwait = code.indexOf('await ');
      expect(firstAwait, greaterThan(apply));
      expect(code, contains('if (!extractNativeImages) return;'));
    });

    test('抽图结果只在选区状态仍是发起时那份才写回', () {
      // 抽图期间点了另一个词 / 关了弹窗：那边刚清掉的图不得被旧选区的结果盖回。
      final int owner = code.indexOf(
        'final Object owner = _selectionImagesOwner;',
      );
      final int extract = code.indexOf('await _extractSelectionClipImages();');
      final int guard = code.indexOf(
        'if (!identical(owner, _selectionImagesOwner)) return;',
      );
      final int write = code.indexOf('_cachedSelectionImages = images;');
      expect(owner, isNonNegative);
      expect(
        owner,
        greaterThan(code.indexOf('_applyLookupStateFromSelectionData(data);')),
      );
      expect(extract, greaterThan(owner));
      expect(guard, greaterThan(extract));
      expect(write, greaterThan(guard));
    });

    test('自己不再各写一份选区字段', () {
      for (final String field in stateFields) {
        expect(assigns(code, field), isFalse, reason: '$field 只在写点里赋值');
      }
    });
  });

  group('点词查词（_handleTextSelected 正文分支）', () {
    final String handler = maskComments(
      methodBody(lookup, 'Future<void> _handleTextSelected('),
    );
    // 歌词分支以 `return;` 收尾，正文分支是其后的全部。
    final int lyricsStart = handler.indexOf('if (_lyricsMode) {');
    final String lyricsBlock = balancedBlockFrom(handler, lyricsStart);
    final String body = handler.substring(lyricsStart + lyricsBlock.length);

    test('切得到正文分支', () {
      expect(lyricsStart, isNonNegative);
      expect(lyricsBlock.trimRight(), endsWith('}'));
      expect(body, contains('await _runLookupAndHighlight('));
    });

    test('await 查词之前经唯一写点写齐状态', () {
      final int apply = body.indexOf(
        '_applyLookupStateFromSelectionData(data);',
      );
      final int run = body.indexOf('await _runLookupAndHighlight(');
      expect(apply, isNonNegative);
      expect(run, greaterThan(apply));
      expect(
        body.substring(0, apply).contains('await '),
        isFalse,
        reason: '写点之前正文分支不得有 await',
      );
      // 顺序：写点 → 续播 cue → cue 文本覆盖 currentSentence → 查词。
      final int restart = body.indexOf(
        'if (_pausedForLookup) _lookupRestartCue = _lookupCue;',
      );
      final int sync = body.indexOf('_syncCueSentence();');
      expect(restart, greaterThan(apply));
      expect(sync, greaterThan(restart));
      expect(run, greaterThan(sync));
    });

    test('await 之后没有选区状态的尾段', () {
      final String tail = body.substring(
        body.indexOf('await _runLookupAndHighlight('),
      );
      for (final String field in <String>[
        ...stateFields,
        '_cachedMatchableSelectionRange',
        '_cachedMatchableSentenceRange',
      ]) {
        expect(
          assigns(tail, field),
          isFalse,
          reason: '$field 在 await 之后赋值 = 先点的那次能盖掉后点的那次',
        );
      }
      expect(containsIdentifierCall(tail, '_cacheMatchableSelection'), isFalse);
      expect(containsIdentifierCall(tail, 'setCurrentSentence'), isFalse);
      expect(
        tail,
        contains('_checkFavoriteStatus();'),
        reason: '收藏态查询读这些缓存，留在写入之后',
      );
    });

    test('正文分支不再各抄一份字段赋值', () {
      for (final String field in stateFields) {
        expect(assigns(body, field), isFalse, reason: '$field 只在写点里赋值');
      }
    });

    test('歌词分支不并入：仍自己写（坐标来自 cue fragment）', () {
      expect(
        containsIdentifierCall(
          lyricsBlock,
          '_applyLookupStateFromSelectionData',
        ),
        isFalse,
      );
      expect(
        lyricsBlock,
        contains('_cachedSelectionSectionIndex = frag.sectionIndex;'),
      );
      expect(lyricsBlock, contains('setCurrentSentence('));
      expect(
        lyricsBlock,
        contains('_cachedSentenceOffset = data.sentenceOffset;'),
      );
    });
  });
}
