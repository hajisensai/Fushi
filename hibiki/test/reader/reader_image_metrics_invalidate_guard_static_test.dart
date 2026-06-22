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
/// B   连续模式 wheel 到内容轴尽头回传 `onBoundarySwipe` 跨章（滚轮原本无此通道）。
///
/// TODO-729：A-2（`_stepWithFreshMetrics` 的 maxF 落点）已随单一量纲收敛删除——双量纲
///     下 maxScroll 被低估才需该补救，根因消除后 paginate 直接 return "limit"。A-1
///     图片晚 load 失效 metrics 的缓存仍保留（与量纲无关，是几何缓存失效）。
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

  group('A-2: _stepWithFreshMetrics removed (TODO-729 single量纲)', () {
    test('源文件已无 _stepWithFreshMetrics（双量纲补救删除）', () {
      expect(
        scriptsSource.contains('_stepWithFreshMetrics'),
        isFalse,
        reason: 'TODO-729：单一量纲后 settle 复核落点函数已删，不得复活',
      );
    });
  });

  group('B: continuous wheel crosses chapter at content-axis boundary', () {
    test('continuous wheel branch calls onBoundarySwipe', () {
      // 连续模式 wheel 监听器到底必须回传 onBoundarySwipe（复用边界跨章通道）。
      expect(
        pageSource.contains("callHandler('onBoundarySwipe', wheelDir)"),
        isTrue,
        reason: '连续模式滚轮到内容轴尽头必须跨章，否则插画/章末滚轮无反应',
      );
    });

    test('boundary uses real try-scroll (scrollBy + measured moved) (TODO-656)',
        () {
      // TODO-656：跨章「到边界」判据改为「真试滚」——真的 scrollBy 一步、读实际位移 moved；
      // 滚动了不跨章，真滚不动才跨章。权威、同步，不靠 scrollWidth/相邻拍推算。
      expect(pageSource.contains('window.scrollBy({left: 0, top: wheelDelta'),
          isTrue,
          reason: '横排滚轮真试滚：window.scrollBy 纵向后读实际位移');
      expect(pageSource.contains('window.scrollBy({left: wheelDelta * sign'),
          isTrue,
          reason: '竖排滚轮真试滚：deltaY 投影到横向 window.scrollBy 后读实际位移');
      expect(pageSource.contains('var moved = Math.abs(after - before) > 1'),
          isTrue,
          reason: '靠实际位移 moved 判到没到边界');
      expect(pageSource.contains('boundaryDir = (wheelDir && stuck)'), isFalse,
          reason: '不得再用 stuck 推算判边界（横排误翻 / 竖排滚不动根因）');
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
