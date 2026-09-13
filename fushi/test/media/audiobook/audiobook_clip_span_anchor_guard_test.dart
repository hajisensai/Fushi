import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// TODO-1278 守卫：有声书片段导出误报「跨章或跨音频文件」。
///
/// 根因：导出侧的音频位置锚点（[_currentSentenceAudioRange] /
/// [_buildAudiobookClipPlan]）此前只读句级 span `_cachedSentenceRange`，丢掉了收藏 /
/// 制卡历史 / lookup / chrome 都在用的 `_cachedSentenceRange ?? _cachedSelectionRange`
/// 回退。句级 span 偶发缺失（拖选跨 block / ruby / 图片相邻节点未进归一化索引 → JS
/// `sentenceNormalizedOffset` 为 null）时，导出独自失去位置锚点 → 对同章 gap word 解析出
/// null 区间 → 被归成 `unsupportedRange` → 弹「跨章或跨音频文件」误导 toast。
///
/// 修复：两处锚点都改走单一真相源 `_miningSpanRange()`（内含选区级回退），与其余消费者
/// 归一。本守卫钉住这条不变量：两个导出锚点不得再裸读 `_cachedSentenceRange`，必须经
/// `_miningSpanRange()`；且 `_miningSpanRange()` 必须保留选区级回退。回退任一处即变红。
void main() {
  String libFile(String relative) =>
      File(relative).readAsStringSync().replaceAll('\r\n', '\n');

  // 从 [signature]（函数名 + 起始 '('）起，先按圆括号配平跳过参数列表，再按大括号配平
  // 截出函数体（复用 audiobook_clip_export_logging_guard_test 的成熟做法）。
  String fnBody(String src, String signature) {
    final int start = src.indexOf(signature);
    expect(start, greaterThanOrEqualTo(0), reason: '函数 $signature 必须存在（守卫锚点）。');
    int i = start + signature.length - 1; // 指向起始 '('
    expect(src[i], '(', reason: 'signature 必须以 "(" 结尾。');
    int paren = 0;
    for (; i < src.length; i++) {
      final String ch = src[i];
      if (ch == '(') paren++;
      if (ch == ')') {
        paren--;
        if (paren == 0) break;
      }
    }
    final int bodyStart = src.indexOf('{', i);
    expect(bodyStart, greaterThanOrEqualTo(0),
        reason: '函数 $signature 参数列表后必须有函数体 "{"。');
    int depth = 0;
    for (i = bodyStart; i < src.length; i++) {
      final String ch = src[i];
      if (ch == '{') depth++;
      if (ch == '}') {
        depth--;
        if (depth == 0) return src.substring(bodyStart, i + 1);
      }
    }
    fail('函数 $signature 大括号不配平，无法截出函数体。');
  }

  group('export-clip audio anchor shares the sentence?selection span fallback',
      () {
    late String audiobookPart;

    setUpAll(() {
      audiobookPart = libFile(
        'lib/src/pages/implementations/reader_fushi/audiobook.part.dart',
      );
    });

    test('_miningSpanRange is defined and keeps the selection-range fallback',
        () {
      final String body = fnBody(
          audiobookPart, '({int offset, int length})? _miningSpanRange(');
      // BUG-2333 起这里用的是**音频匹配坐标**（matchable）而不是学习单位范围：
      // 学习单位不能拿去和字幕的 normCharStart/End 比，那是这轮修的坐标混用。
      // 不变式没变（TODO-1278：句级优先、缺失时回退选区级，否则导出误报跨章），
      // 所以钉的是这个**次序**加上「用的是 matchable 那套」。
      final int sentenceIdx = body.indexOf('_cachedMatchableSentenceRange');
      final int selectionIdx = body.indexOf('_cachedMatchableSelectionRange');
      expect(sentenceIdx, greaterThanOrEqualTo(0),
          reason:
              '_miningSpanRange 必须先取句级 span _cachedMatchableSentenceRange。');
      expect(selectionIdx, greaterThan(sentenceIdx),
          reason: '_miningSpanRange 必须回退到选区级 span '
              '_cachedMatchableSelectionRange，且排在句级之后 '
              '(TODO-1278：否则句级 span 缺失时导出误报跨章)。');
      // 不得回到学习单位坐标——音频裁片段拿它去比字幕偏移就是 BUG-2333 本体。
      expect(
        RegExp(r'_cached(?!Matchable)(Sentence|Selection)Range').hasMatch(body),
        isFalse,
        reason: '音频 span 只能用 matchable 坐标，不能混用学习单位范围',
      );
    });

    test(
        '_currentSentenceAudioRange anchors via _miningSpanRange, not raw '
        '_cachedSentenceRange', () {
      final String body = fnBody(
          audiobookPart, 'AudioPlaybackRange? _currentSentenceAudioRange(');
      expect(body.contains('_miningSpanRange()'), isTrue,
          reason: '导出 / 制卡音频区间必须经 _miningSpanRange() 取锚点。');
      expect(body.contains('_cachedSentenceRange'), isFalse,
          reason: '不得再裸读 _cachedSentenceRange（会丢选区级回退，TODO-1278 回归）。');
    });

    test(
        '_buildAudiobookClipPlan anchors via _miningSpanRange, not raw '
        '_cachedSentenceRange', () {
      // BUG-1320：构造器返回类型改成记录 ({plan, range})，签名不再以 `(` 结尾；
      // 改用共享 methodBody（会跳过命名参数表）。`_buildAudiobookClipPlan({` 只匹配
      // 定义，调用点是 `_buildAudiobookClipPlan(audioFileCount:`，不会撞。
      final String body =
          methodBody(audiobookPart, '_buildAudiobookClipPlan({');
      expect(body.contains('_miningSpanRange()'), isTrue,
          reason: '动态多句计划的 span 定位必须经 _miningSpanRange() 取锚点。');
      expect(body.contains('_cachedSentenceRange'), isFalse,
          reason: '不得再裸读 _cachedSentenceRange（会丢选区级回退，TODO-1278 回归）。');
    });
  });
}
