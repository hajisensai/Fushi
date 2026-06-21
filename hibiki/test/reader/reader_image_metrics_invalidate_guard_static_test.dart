import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../pages/reader_hibiki_page_source_corpus.dart';

/// TODO-627 / BUG-349 源码守卫：PC 阅读遇插画滚轮翻不了下一页的三处根因修复
/// 不得回退（headless WebView 不可用，数值正确性由纯函数影子覆盖，这里只锁 JS/Dart
/// 实现的关键结构）：
///
/// A-1 图片晚 load 后失效分页 metrics：两处 `Promise.all(imagePromises).then` 块内
///     `buildNodeOffsets()` 后必须把 `paginationMetrics` 置 null，否则下次 paginate
///     沿用图片未 load 时的低估 metrics（maxScroll 漏图片列）提前跨章。
/// A-2 `_stepWithFreshMetrics` forward 落点用 maxF（含 trueMaxAligned）容差上界，而非
///     旧的 `Math.max(metrics.maxScroll, currentScroll)`——后者低估时把落点 clamp 回
///     currentScroll，插画页滚轮卡死（既不翻页也不跨章）。
/// B   连续模式 wheel 到内容轴尽头回传 `onBoundarySwipe` 跨章（滚轮原本无此通道）。
void main() {
  late String scriptsSource;
  late String pageSource;

  setUpAll(() {
    scriptsSource = File('lib/src/reader/reader_pagination_scripts.dart')
        .readAsStringSync();
    // TODO-589 batch8: 连续模式 wheel onBoundarySwipe 在 setup 脚本里，已搬到
    // reader_hibiki/webview.part.dart，改读「主壳 + 全部 part」合并语料。
    pageSource = readReaderPageSource();
  });

  group('A-1: invalidate pagination metrics after images load', () {
    test('both Promise.all(imagePromises).then blocks null out metrics', () {
      // 两处 initialize（分页 + 连续）的图片 load 回调都必须失效 metrics。
      final RegExp block = RegExp(
        r'Promise\.all\(imagePromises\)\.then\(function\(\)\s*\{'
        r'[\s\S]*?window\.hoshiReader\.buildNodeOffsets\(\);'
        r'[\s\S]*?window\.hoshiReader\.paginationMetrics = null;',
      );
      final Iterable<Match> matches = block.allMatches(scriptsSource);
      expect(
        matches.length,
        2,
        reason: '分页与连续两处图片 load 回调都必须在 buildNodeOffsets 后失效 '
            'paginationMetrics（图片晚 load 致 metrics.maxScroll 低估的根因修复）',
      );
    });
  });

  group('A-2: _stepWithFreshMetrics forward landing uses maxF ceiling', () {
    test(
        'forward dest clamps to maxF, not max(metrics.maxScroll, currentScroll)',
        () {
      expect(
        scriptsSource.contains('var dest = Math.min(targetF, maxF);'),
        isTrue,
        reason: 'forward 落点上界必须是 maxF（含 trueMaxAligned），消除低估卡死',
      );
      expect(
        scriptsSource.contains(
            'Math.min(targetF, Math.max(metrics.maxScroll, currentScroll))'),
        isFalse,
        reason: '旧落点会在 metrics 低估时把 dest clamp 回 currentScroll，必须移除',
      );
    });

    test('maxF still derives from trueMaxAligned (live DOM scroll edge)', () {
      expect(
        scriptsSource.contains(
            'var maxF = Math.max(metrics.maxScroll, trueMaxAligned);'),
        isTrue,
        reason: 'maxF 必须取 metrics.maxScroll 与实时 DOM trueMaxAligned 的较大者',
      );
    });
  });

  group('B: continuous wheel crosses chapter at content-axis boundary', () {
    test('continuous wheel branch calls onBoundarySwipe', () {
      // 连续模式 wheel 监听器到底必须回传 onBoundarySwipe（复用边界跨章通道）。
      expect(
        pageSource.contains("callHandler('onBoundarySwipe', boundaryDir)"),
        isTrue,
        reason: '连续模式滚轮到内容轴尽头必须跨章，否则插画/章末滚轮无反应',
      );
    });

    test(
        'boundary direction uses no-movement stuck, not atStart/atEnd (TODO-656)',
        () {
      // TODO-656：跨章「到边界」判据从瞬时 atStart/atEnd 几何改为「内容真滚不动」
      // （stuck：横排相邻拍 scrollTop 无变化 / 竖排缓动 target 被 clamp 卡死）。
      expect(
        pageSource.contains('boundaryDir = (wheelDir && stuck)'),
        isTrue,
        reason: '滚轮跨章方向由 stuck（内容真滚不动）判定，只在真到底才发',
      );
      expect(
        pageSource.contains('boundaryDir = atEnd') ||
            pageSource.contains('boundaryDir = atStart'),
        isFalse,
        reason: '不得再用瞬时 atStart/atEnd 几何判边界（短章误翻/边界卡顿根因）',
      );
    });

    test('Dart shadow continuousWheelBoundaryDirection exists', () {
      expect(
        scriptsSource.contains(
          'static String? continuousWheelBoundaryDirection({',
        ),
        isTrue,
        reason: '连续 wheel 边界判定必须有纯函数影子供单测覆盖',
      );
    });
  });
}
