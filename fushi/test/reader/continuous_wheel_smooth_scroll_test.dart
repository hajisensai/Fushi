@Tags(<String>['chrome'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show kContinuousWheelScrollJs, readerFushiEngineSourceUncompacted;

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// 滚动（连续）模式的鼠标滚轮「无极滚动」+ 触控板按手机手势跟手。
///
/// 旧实现每格滚轮一次 `scrollBy(behavior:'auto')` 硬跳；竖排触控板横滑被
/// 「主 delta 投影」乘上 vertical-rl 的 sign=-1，内容反着手指走；横排触控板横滑
/// 被当成纵向滚动。
void main() {
  test('production smooth wheel helper eases, accumulates and keeps boundaries '
      'in real Chrome', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS execution');
      return;
    }
    final Directory temp = Directory.systemTemp.createTempSync('cwheel-');
    try {
      final File payload = File('${temp.path}/helper.json')
        ..writeAsStringSync(
          jsonEncode(<String, String>{
            'helper': kContinuousWheelScrollJs,
          }),
        );
      final ProcessResult result = await Process.run(nodeExe, <String>[
        'test/reader/continuous_wheel_smooth_scroll_harness.mjs',
        payload.path,
      ]).timeout(const Duration(seconds: 80));
      if (result.exitCode == 77) {
        markTestSkipped('Chrome unavailable: ${result.stdout}');
        return;
      }
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('PASS 10 browser cases'));
    } finally {
      temp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));

  group('wheel listener wiring', () {
    late String wheel;
    setUpAll(() {
      final String corpus = maskCommentsAndScriptLines(readReaderPageSource());
      final int start = bodyEngineWheelListenerStart(corpus);
      expect(start, isNonNegative);
      wheel = balancedBlockFrom(
        corpus,
        start,
        lexicon: SourceLexicon.js,
        what: '正文引擎 wheel 监听回调体',
      );
      expect(wheel.contains('fushiContinuousMode'), isTrue);
    });

    test('continuous engine injects the helper verbatim', () {
      expect(
        readerFushiEngineSourceUncompacted(continuousMode: true),
        contains(kContinuousWheelScrollJs),
      );
    });

    test('prepare -> try-scroll -> commit, before the boundary hand-off', () {
      int at(String needle) {
        final int i = wheel.indexOf(needle);
        expect(i, isNonNegative, reason: 'missing: $needle');
        return i;
      }

      final int prepare = at(
        "_smoothWheelPrepare(vertical, pointerKind === 'wheel')",
      );
      final int tryScroll = at('window.scrollBy(');
      final int moved = at('var moved = Math.abs(after - before) > 1');
      final int commit = at(
        'if (_smoothWheelCommit(vertical, shownPos, after)) return;',
      );
      final int boundary = at("'onBoundarySwipe'");
      expect(
        prepare < tryScroll && tryScroll < moved,
        isTrue,
        reason: '缓动终点要在试滚之前就位，连拨才会累加',
      );
      expect(
        moved < commit && commit < boundary,
        isTrue,
        reason: '缓动没走到边界前不得交给跨章',
      );
    });

    test('trackpad follows the content axis in native direction', () {
      final int gate = wheel.indexOf("if (pointerKind === 'trackpad') {");
      final int tryScroll = wheel.indexOf('window.scrollBy(');
      expect(gate, isNonNegative);
      expect(gate, lessThan(tryScroll));
      expect(
        containsCodeLine(wheel, 'if (!vertical) wheelDelta = e.deltaY;'),
        isTrue,
        reason: '横排触控板只认纵向分量（手机横划不滚）',
      );
      expect(
        containsCodeLine(
          wheel,
          'else if (Math.abs(e.deltaX) > Math.abs(e.deltaY)) wheelDelta = e.deltaX * sign;',
        ),
        isTrue,
        reason: '竖排横划乘回 sign，wheelDelta * sign 才是原生 deltaX',
      );
    });

    // BUG-2831：Mac 上一次触控板滑动跨章后，残余惯性在新章接着滚，再滑就连跳章节。
    test('trackpad swallows the fling inherited from the previous chapter', () {
      final int gate = wheel.indexOf("if (pointerKind === 'trackpad') {");
      final int swallow = wheel.indexOf(
        'if (_swallowInheritedTrackpadFling(wheelTickAt, wheelQuietMs)) {',
      );
      final int tryScroll = wheel.indexOf('window.scrollBy(');
      final int boundary = wheel.indexOf("'onBoundarySwipe'");
      expect(swallow, greaterThan(gate), reason: '只吞触控板，鼠标滚轮照常');
      expect(swallow, lessThan(tryScroll), reason: '吞掉的 tick 不得滚动');
      expect(swallow, lessThan(boundary), reason: '吞掉的 tick 不得判边界跨章');
    });
  });
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}
