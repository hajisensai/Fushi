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
        "window.hoshiReader && window.hoshiReader.paginate('forward')",
      );
    });

    test('paginateInvocation backward', () {
      expect(
        ReaderPaginationScripts.paginateInvocation(
            ReaderNavigationDirection.backward),
        "window.hoshiReader && window.hoshiReader.paginate('backward')",
      );
    });

    test('progressInvocation', () {
      expect(
        ReaderPaginationScripts.progressInvocation(),
        'window.hoshiReader && window.hoshiReader.calculateProgress()',
      );
    });

    test('stableProgressInvocation returns null during reanchor', () {
      expect(
        ReaderPaginationScripts.stableProgressInvocation(),
        'window.hoshiReader && !window.hoshiReader._reanchorPending '
        '&& window.hoshiProgressDetails ? window.hoshiProgressDetails() : null',
      );
    });

    test('updatePageSizeInvocation', () {
      expect(
        ReaderPaginationScripts.updatePageSizeInvocation(360.0, 640.0),
        'window.hoshiReader && window.hoshiReader.updatePageSize(360.0, 640.0)',
      );
    });

    test('clearSasayakiCueInvocation', () {
      expect(
        ReaderPaginationScripts.clearSasayakiCueInvocation(),
        'window.hoshiReader.clearSasayakiCue()',
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
        'window.hoshiReader.clearSearchHighlight()',
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
    test('paginated mode contains hoshiReader object', () {
      final String script = ReaderPaginationScripts.shellScript(
        initialProgress: 0.0,
        continuousMode: false,
      );
      expect(script, contains('<script>'));
      expect(script, contains('</script>'));
      expect(script, contains('window.hoshiReader'));
    });

    test('continuous mode contains hoshiReader object', () {
      final String script = ReaderPaginationScripts.shellScript(
        initialProgress: 0.5,
        continuousMode: true,
      );
      expect(script, contains('window.hoshiReader'));
    });

    test('paginated mode defines paginate method', () {
      final String script = ReaderPaginationScripts.shellScript(
        initialProgress: 0.0,
        continuousMode: false,
      );
      expect(script, contains('paginate'));
      expect(script, contains('calculateProgress'));
    });

    test('initial progress is injected', () {
      final String script = ReaderPaginationScripts.shellScript(
        initialProgress: 0.75,
        continuousMode: false,
      );
      expect(script, contains('0.75'));
    });

    test('sasayaki cues JSON is injected when provided', () {
      final String script = ReaderPaginationScripts.shellScript(
        initialProgress: 0.0,
        continuousMode: false,
        sasayakiCuesJson: '[{"id":"cue1","start":0,"end":10}]',
      );
      expect(script, contains('cue1'));
    });

    test('defines onRestoreComplete callback', () {
      final String script = ReaderPaginationScripts.shellScript(
        initialProgress: 0.0,
        continuousMode: false,
      );
      expect(script, contains('onRestoreComplete'));
    });

    test('defines updatePageSize method', () {
      final String script = ReaderPaginationScripts.shellScript(
        initialProgress: 0.0,
        continuousMode: false,
      );
      expect(script, contains('updatePageSize'));
    });

    test('defines initialize function', () {
      final String script = ReaderPaginationScripts.shellScript(
        initialProgress: 0.0,
        continuousMode: false,
      );
      expect(script, contains('initialize'));
      expect(script, contains('addEventListener'));
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
      expect(result, 'window.hoshiReader.scrollToSearchMatch("a\\"b", 7)');
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
      expect(result, 'window.hoshiReader.scrollToSearchMatch("猫", 100)');
    });

    test('highlightSasayakiCueInvocation escapes cue id and embeds bool', () {
      final String result =
          ReaderPaginationScripts.highlightSasayakiCueInvocation(
        'cue"1',
        reveal: true,
      );
      expect(
        result,
        'window.hoshiReader.highlightSasayakiCue("cue\\"1", true)',
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

  // BUG-023: 调整字体大小（行间/余白同源）走 _applyStylesLive 的 CSS-only live
  // 注入，会让 body 重新分页排版，但旧路径既不重建 paginationMetrics、也不把视口
  // 重新对齐到分页边界 —— 既有的 updatePageSize / setChromeInsets 都有「捕捉进度
  // → 重排 → 重锚」机制，唯独外部 CSS 变更没有，于是页面停在错位的滚动量、最上
  // 一行被裁。修复加 reanchorAfterStyleChange，两模式各镜像自身 updatePageSize 的
  // 重锚序列。这些断言先红（方法不存在），实现后绿。
  group('ReaderPaginationScripts.reanchorAfterStyleChange (BUG-023)', () {
    final String paginated = ReaderPaginationScripts.shellScript(
      initialProgress: 0.3,
    );
    final String continuous = ReaderPaginationScripts.shellScript(
      continuousMode: true,
      initialProgress: 0.3,
    );

    test('paginated shell defines reanchorAfterStyleChange', () {
      expect(paginated, contains('reanchorAfterStyleChange'));
    });

    test('continuous shell defines reanchorAfterStyleChange', () {
      expect(continuous, contains('reanchorAfterStyleChange'));
    });

    test(
        'paginated re-anchor captures precise char offset, invalidates '
        'metrics, serialises via _reanchorPending and re-snaps via '
        'scrollToCharOffset (BUG-109)', () {
      final int idx = paginated.indexOf('reanchorAfterStyleChange =');
      expect(idx, greaterThanOrEqualTo(0));
      // 取方法体（到下一处 window.hoshiReader. 赋值之前，足够覆盖本方法）。
      final int next = paginated.indexOf('window.hoshiReader.', idx + 1);
      final String body =
          paginated.substring(idx, next < 0 ? paginated.length : next);
      // BUG-109：分页重锚改用精确字符偏移（对齐 setChromeInsets），不再用粗粒度
      // 进度分数 —— 后者重排后 alignToPage 取整会落到相邻页，切主题/字体「翻页」。
      expect(body, contains('getFirstVisibleCharOffset()'),
          reason: '必须在重排前用 getFirstVisibleCharOffset 精确捕捉首个可见字符（BUG-109）');
      expect(body, contains('this.paginationMetrics = null'),
          reason: '字体变更后分页 metrics 失效，不置空会用旧 progressStops 算错页');
      expect(body, contains('_reanchorPending'),
          reason: '必须复用既有 in-flight 串行标志，避免与 chrome-inset/页尺寸重锚打架');
      expect(body, contains('scrollToCharOffset('),
          reason: 'rAF 内必须用 scrollToCharOffset 落到该字符真实所在页（BUG-109），'
              '勿退回 scrollToProgressPaged 的进度分数对齐');
    });

    test('continuous re-anchor captures progress and re-scrolls', () {
      final int idx = continuous.indexOf('reanchorAfterStyleChange =');
      expect(idx, greaterThanOrEqualTo(0));
      final int next = continuous.indexOf('window.hoshiReader.', idx + 1);
      final String body =
          continuous.substring(idx, next < 0 ? continuous.length : next);
      expect(body, contains('calculateProgress()'));
      expect(body, contains('_reanchorPending'));
      expect(body, contains('scrollToProgressContinuous'),
          reason: '连续模式重排后必须按进度重新滚动到同一位置');
    });
  });
}
