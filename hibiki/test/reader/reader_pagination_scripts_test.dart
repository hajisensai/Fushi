// 覆盖边界（勿误读）：本文件只验 reader 侧 JS 载荷的**语义**——生成函数返回的那个字符串
// 里有什么、行为契约对不对。它证明不了这个载荷真的被拼进最终注入 WebView 的 setup 脚本。
// 「装配完整性」（每个子载荷都被拼进去、压缩后还在）由
// test/reader/reader_script_compactor_test.dart 的「setup 装配完整性」一组集中守——
// 那里删掉模板中的 $caretJs / $selectionJs / $longPressDragJs 会立刻转红，本文件不会。
// 改这里前先分清你要锁的是语义还是注入，别在本文件里重造装配断言。
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';

void main() {
  group('ReaderPaginationScripts.didScroll', () {
    test('returns true for "scrolled"', () {
      expect(ReaderPaginationScripts.didScroll('scrolled'), isTrue);
    });

    test('returns false for other strings', () {
      expect(ReaderPaginationScripts.didScroll('nope'), isFalse);
    });

    test('returns false for null', () {
      expect(ReaderPaginationScripts.didScroll(null), isFalse);
    });

    test('returns false for empty string', () {
      expect(ReaderPaginationScripts.didScroll(''), isFalse);
    });
  });

  group('ReaderPaginationScripts.doubleResult', () {
    test('parses double from double value', () {
      expect(ReaderPaginationScripts.doubleResult(0.75), 0.75);
    });

    test('parses double from int value', () {
      expect(ReaderPaginationScripts.doubleResult(42), 42.0);
    });

    test('parses double from string value', () {
      expect(ReaderPaginationScripts.doubleResult('0.5'), 0.5);
    });

    test('returns null for null input', () {
      expect(ReaderPaginationScripts.doubleResult(null), isNull);
    });

    test('returns null for non-numeric string', () {
      expect(ReaderPaginationScripts.doubleResult('abc'), isNull);
    });

    test('returns null for empty string', () {
      expect(ReaderPaginationScripts.doubleResult(''), isNull);
    });
  });

  group('ReaderPaginationScripts invocations', () {
    test('paginateInvocation forward', () {
      expect(
        ReaderPaginationScripts.paginateInvocation(
            ReaderNavigationDirection.forward),
        "window.fushiReader && window.fushiReader.paginate('forward')",
      );
    });

    test('paginateInvocation backward', () {
      expect(
        ReaderPaginationScripts.paginateInvocation(
            ReaderNavigationDirection.backward),
        "window.fushiReader && window.fushiReader.paginate('backward')",
      );
    });

    test('progressInvocation', () {
      expect(
        ReaderPaginationScripts.progressInvocation(),
        'window.fushiReader && window.fushiReader.calculateProgress()',
      );
    });

    test('stableProgressInvocation returns null during reanchor', () {
      expect(
        ReaderPaginationScripts.stableProgressInvocation(),
        'window.fushiReader && !window.fushiReader._reanchorPending '
        '&& window.hoshiProgressDetails ? window.hoshiProgressDetails() : null',
      );
    });

    test('updatePageSizeInvocation', () {
      expect(
        ReaderPaginationScripts.updatePageSizeInvocation(360.0, 640.0),
        'window.fushiReader && window.fushiReader.updatePageSize(360.0, 640.0)',
      );
    });

    test('clearSasayakiCueInvocation', () {
      expect(
        ReaderPaginationScripts.clearSasayakiCueInvocation(),
        'window.fushiReader.clearSasayakiCue()',
      );
    });

    test('scrollToSearchMatchInvocation escapes query', () {
      final String result =
          ReaderPaginationScripts.scrollToSearchMatchInvocation('猫', 100);
      expect(result, contains('scrollToSearchMatch'));
      expect(result, contains('100'));
    });

    test('clearSearchHighlightInvocation', () {
      expect(
        ReaderPaginationScripts.clearSearchHighlightInvocation(),
        'window.fushiReader.clearSearchHighlight()',
      );
    });
  });

  group('ReaderPaginationScripts.navigationDirectionForKey', () {
    test('maps desktop forward keys', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowDown,
      ]) {
        expect(
          ReaderPaginationScripts.navigationDirectionForKey(key),
          ReaderNavigationDirection.forward,
        );
      }
    });

    test('maps desktop backward keys', () {
      for (final LogicalKeyboardKey key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowUp,
      ]) {
        expect(
          ReaderPaginationScripts.navigationDirectionForKey(key),
          ReaderNavigationDirection.backward,
        );
      }
    });

    test('ignores non-navigation keys', () {
      expect(
        ReaderPaginationScripts.navigationDirectionForKey(
          LogicalKeyboardKey.keyA,
        ),
        isNull,
      );
    });
  });

  group('ReaderPaginationScripts.shellScript contract', () {
    test('paginated mode contains fushiReader object', () {
      final String script = ReaderPaginationScripts.paginatedShellSource();
      expect(script, contains('<script>'));
      expect(script, contains('</script>'));
      expect(script, contains('window.fushiReader'));
    });

    test('continuous mode contains fushiReader object', () {
      final String script = ReaderPaginationScripts.continuousShellSource();
      expect(script, contains('window.fushiReader'));
    });

    test('paginated mode defines paginate method', () {
      final String script = ReaderPaginationScripts.paginatedShellSource();
      expect(script, contains('paginate'));
      expect(script, contains('calculateProgress'));
    });

    // BUG-1140 第二阶段①：恢复锚与 cue 不再插进源码，改由运行时读 config。
    // 判据（fragment > charOffset > progress 的优先级）必须原样保留。
    test('initial progress / char offset / fragment are read from config', () {
      final String script = ReaderPaginationScripts.paginatedShellSource();
      expect(script,
          contains('window.fushiReader.restoreProgress(C.initialProgress)'));
      expect(
          script,
          contains(
              'window.fushiReader.restoreToCharOffset(C.initialCharOffset)'));
      expect(script,
          contains('window.fushiReader.jumpToFragment(C.initialFragment)'));
      final int fragIdx = script.indexOf('C.initialFragment !== null');
      final int charIdx = script.indexOf('C.initialCharOffset >= 0');
      expect(fragIdx, isNonNegative);
      expect(charIdx, isNonNegative);
      expect(fragIdx < charIdx, isTrue, reason: 'fragment 跳转优先级必须高于精确字符锚');
    });

    test('sasayaki cues are read from config when present', () {
      final String script = ReaderPaginationScripts.paginatedShellSource();
      expect(script,
          contains('window.fushiReader.applySasayakiCues(C.sasayakiCues)'));
      expect(script, contains('C.sasayakiCues !== null'));
    });

    test('defines onRestoreComplete callback', () {
      final String script = ReaderPaginationScripts.paginatedShellSource();
      expect(script, contains('onRestoreComplete'));
    });

    test('defines updatePageSize method', () {
      final String script = ReaderPaginationScripts.paginatedShellSource();
      expect(script, contains('updatePageSize'));
    });

    test('defines initialize function', () {
      final String script = ReaderPaginationScripts.paginatedShellSource();
      expect(script, contains('initialize'));
      expect(script, contains('addEventListener'));
    });
  });

  group('ReaderPaginationScripts continuous vertical position contract', () {
    final String continuous = ReaderPaginationScripts.continuousShellSource();

    test('continuous paginate actually scrolls before reporting scrolled', () {
      final String body = _between(
        continuous,
        'paginate: function(direction) {',
        '  getFirstVisibleCharOffset: function() {',
      );

      expect(body, contains('window.scrollBy({left: step'));
      expect(body, contains('return moved ? "scrolled" : "limit";'));
    });

    test('continuous vertical visible-char sampling uses viewport width', () {
      final String body = _between(
        continuous,
        'getFirstVisibleCharOffset: function() {',
        '  // BUG-162:',
      );

      expect(body, contains('window.innerWidth - pr - 2'));
      expect(body, isNot(contains('document.body.clientWidth - pr - 2')));
    });

    test('continuous vertical char restore uses viewport right edge', () {
      // BUG-461: 连续 scrollToCharOffset 增加可选 endCharOffset（句尾区间对齐）后签名变为
      // (charOffset, endCharOffset)；TODO-1229 又加第三参 hintScroll（<=0 章首区保位）。
      // 竖排分支仍按视口右沿锚句首（与横排句尾对齐、章首区保位均正交）。
      final String body = _between(
        continuous,
        'scrollToCharOffset: function(charOffset, endCharOffset, hintScroll) {',
        '  // BUG-162:',
      );

      expect(body, contains('window.innerWidth - pr'));
      expect(body, isNot(contains('document.body.clientWidth - pr')));
    });
  });

  // HBK-AUDIT-053: the shellScript group above only greps generated JS for
  // substrings. These tests instead exercise real Dart behaviour — the
  // string-literal escaping used when injecting user/data values into JS
  // invocations — so a regression that breaks the generated JS (or opens an
  // injection hole) actually fails here, not just at flutter-drive time.
  group('ReaderPaginationScripts invocation escaping', () {
    test('scrollToSearchMatchInvocation escapes a double quote', () {
      final String result =
          ReaderPaginationScripts.scrollToSearchMatchInvocation('a"b', 7);
      // The query must be emitted as a single, properly escaped JS string
      // literal so the raw quote cannot terminate the argument early.
      expect(result, 'window.fushiReader.scrollToSearchMatch("a\\"b", 7)');
      expect(result, isNot(contains('"a"b"')));
    });

    test('scrollToSearchMatchInvocation escapes backslash and newline', () {
      final String result =
          ReaderPaginationScripts.scrollToSearchMatchInvocation(
        'a\\b\nc',
        0,
      );
      // jsonEncode escapes backslash -> \\ and newline -> \n; the produced
      // literal must contain no raw newline that would break the one-line eval.
      expect(result, contains(r'\\'));
      expect(result, contains(r'\n'));
      expect(result, isNot(contains('\n')));
    });

    test('scrollToSearchMatchInvocation preserves CJK query verbatim', () {
      final String result =
          ReaderPaginationScripts.scrollToSearchMatchInvocation('猫', 100);
      expect(result, 'window.fushiReader.scrollToSearchMatch("猫", 100)');
    });

    test('highlightSasayakiCueInvocation escapes cue id and embeds bool', () {
      final String result =
          ReaderPaginationScripts.highlightSasayakiCueInvocation(
        'cue"1',
        reveal: true,
      );
      expect(
        result,
        'window.fushiReader.highlightSasayakiCue("cue\\"1", true)',
      );
    });
  });

  // HBK-AUDIT-053: intResult is the JS-channel parser used for restore
  // offsets (getFirstVisibleCharOffset) — cover the conversion the same way
  // doubleResult is covered, so a broken parse cannot reopen the book at the
  // wrong character offset silently.
  group('ReaderPaginationScripts.intResult', () {
    test('parses int from int value', () {
      expect(ReaderPaginationScripts.intResult(42), 42);
    });

    test('truncates double value to int', () {
      expect(ReaderPaginationScripts.intResult(42.9), 42);
    });

    test('parses int from quoted string value', () {
      expect(ReaderPaginationScripts.intResult('"123"'), 123);
    });

    test('returns null for null and non-numeric input', () {
      expect(ReaderPaginationScripts.intResult(null), isNull);
      expect(ReaderPaginationScripts.intResult('abc'), isNull);
    });
  });

  // BUG-023 / TODO-736：调整字体大小（行间/余白同源）走 _applyStylesLive 的两阶段
  // 编排（beginStyleReanchor/commitStyleReanchor，见 reanchor_charoffset_guard_test 守
  // char-precise + settle-aware）。本 group 只留与样式重锚无关的分页 metrics 预热守卫
  // （warmPaginationMetrics）；旧单函数 reanchorAfterStyleChange 已作死代码删除。
  group('ReaderPaginationScripts pagination metrics warm (BUG-023)', () {
    final String paginated = ReaderPaginationScripts.paginatedShellSource();
    final String continuous = ReaderPaginationScripts.continuousShellSource();

    test('paginated restore completion warms pagination metrics during idle',
        () {
      expect(paginated, contains('warmPaginationMetrics: function()'),
          reason:
              'Hoshi Android 在 restore 完成后 idle 预热分页 metrics，避免下次翻页才同步扫 DOM');
      expect(paginated,
          contains("typeof this.warmPaginationMetrics === 'function'"));
      expect(paginated, contains('this.warmPaginationMetrics();'));
      expect(paginated,
          contains('window.requestIdleCallback(run, { timeout: 1000 });'));
      expect(paginated, contains('setTimeout(run, 200);'));
      expect(paginated, contains('this.buildPaginationMetrics();'));
      expect(continuous,
          contains("typeof this.warmPaginationMetrics === 'function'"),
          reason:
              'notifyRestoreComplete 是 shared JS，连续模式必须安全跳过 paginated-only warm');
    });

    test(
        'continuous calculateProgress is char-precise (countCharsBeforeViewport, '
        'not whole-node in/out) — TODO-736 A-1', () {
      final int idx = continuous.indexOf('calculateProgress: function() {');
      expect(idx, greaterThanOrEqualTo(0));
      final int end = continuous.indexOf('\n  },', idx);
      final String body =
          continuous.substring(idx, end < 0 ? continuous.length : end);
      expect(body, contains('countCharsBeforeViewport'),
          reason: '连续进度分子必须用 countCharsBeforeViewport 字符级累加（TODO-736 A-1），'
              '替代整节点 in/out 的段落级粗粒度（长节点滚动期进度跳变/不动）');
      // 旧实现整节点判定的标志（selectNodeContents 整节点矩形 + 整 nodeLen 累加）应消失。
      expect(body, isNot(contains('exploredChars += nodeLen')),
          reason: '不得再整节点累加 nodeLen（旧粗粒度路径，TODO-736 A-1）');
    });

    test(
        'continuous getFirstVisibleCharOffset falls back to '
        'firstVisibleCharOffsetByScan instead of returning -1 (TODO-736 A-2)',
        () {
      // 取连续 shell 的 getFirstVisibleCharOffset 方法体（到下一个 scrollToCharOffset 之前）。
      final int idx =
          continuous.lastIndexOf('getFirstVisibleCharOffset: function() {');
      expect(idx, greaterThanOrEqualTo(0));
      final int end = continuous.indexOf('scrollToCharOffset: function', idx);
      final String body =
          continuous.substring(idx, end < 0 ? continuous.length : end);
      expect(body, contains('firstVisibleCharOffsetByScan()'),
          reason: 'caret 失败（竖排/ruby/图片页）必须走全文扫描兜底，不退 -1 丢精确锚（TODO-736 A-2）');
      // _sharedJs 必须定义该兜底。
      expect(continuous, contains('firstVisibleCharOffsetByScan: function'),
          reason:
              'firstVisibleCharOffsetByScan 必须在 _sharedJs 定义（TODO-736 A-2）');
      expect(continuous, contains('countCharsBeforeViewport: function'),
          reason: 'countCharsBeforeViewport 必须在 _sharedJs 定义（TODO-736 A-1）');
      expect(continuous, contains('isTextOffsetBeforeViewport: function'),
          reason: 'isTextOffsetBeforeViewport 必须在 _sharedJs 定义（TODO-736 A-1）');
    });
  });
}

String _between(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
