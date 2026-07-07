import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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
        'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
      );
    });

    test('_miningSpanRange is defined and keeps the selection-range fallback',
        () {
      final String body = fnBody(
          audiobookPart, '({int offset, int length})? _miningSpanRange(');
      expect(body.contains('_cachedSentenceRange'), isTrue,
          reason: '_miningSpanRange 必须先取句级 span _cachedSentenceRange。');
      expect(body.contains('_cachedSelectionRange'), isTrue,
          reason: '_miningSpanRange 必须回退到选区级 span _cachedSelectionRange '
              '(TODO-1278：否则句级 span 缺失时导出误报跨章)。');
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
      final String body = fnBody(
          audiobookPart, '_AudiobookClipDynamicPlan? _buildAudiobookClipPlan(');
      expect(body.contains('_miningSpanRange()'), isTrue,
          reason: '动态多句计划的 span 定位必须经 _miningSpanRange() 取锚点。');
      expect(body.contains('_cachedSentenceRange'), isFalse,
          reason: '不得再裸读 _cachedSentenceRange（会丢选区级回退，TODO-1278 回归）。');
    });
  });
}
