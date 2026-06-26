import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

void main() {
  group('ReaderSelectionScripts.selectInvocation', () {
    test('generates correct JS call (tap path defaults fromHover:false)', () {
      expect(
        ReaderSelectionScripts.selectInvocation(100.5, 200.0, 50),
        'window.hoshiSelection.selectText(100.5, 200.0, 50, false)',
      );
    });

    test('handles zero coordinates', () {
      expect(
        ReaderSelectionScripts.selectInvocation(0, 0, 1),
        'window.hoshiSelection.selectText(0.0, 0.0, 1, false)',
      );
    });

    // TODO-851：悬停查词路径传 fromHover:true，JS 端空白命中不再 fire onTapEmpty。
    test('hover path passes fromHover:true', () {
      expect(
        ReaderSelectionScripts.selectInvocation(10, 20, 400, fromHover: true),
        'window.hoshiSelection.selectText(10.0, 20.0, 400, true)',
      );
    });
  });

  group('ReaderSelectionScripts.highlightInvocation', () {
    test('generates correct JS call', () {
      expect(
        ReaderSelectionScripts.highlightInvocation(5),
        'JSON.stringify(window.hoshiSelection.highlightSelection(5))',
      );
    });

    test('handles zero count', () {
      expect(
        ReaderSelectionScripts.highlightInvocation(0),
        'JSON.stringify(window.hoshiSelection.highlightSelection(0))',
      );
    });
  });

  group('ReaderSelectionScripts.highlightRectFromResult', () {
    test('parses JSON string and applies reader top offset', () {
      final rect = ReaderSelectionScripts.highlightRectFromResult(
        '{"x":10,"y":20,"width":30,"height":40}',
        topOffset: 5,
      );

      expect(rect?.left, 10);
      expect(rect?.top, 25);
      expect(rect?.width, 30);
      expect(rect?.height, 40);
    });

    test('parses map result from platform bridge', () {
      final rect = ReaderSelectionScripts.highlightRectFromResult(
        <String, Object?>{
          'x': 1,
          'y': 2.5,
          'width': 3,
          'height': 4.5,
        },
      );

      expect(rect?.left, 1);
      expect(rect?.top, 2.5);
      expect(rect?.width, 3);
      expect(rect?.height, 4.5);
    });

    test('ignores empty and invalid highlight bounds', () {
      expect(ReaderSelectionScripts.highlightRectFromResult(null), isNull);
      expect(ReaderSelectionScripts.highlightRectFromResult('null'), isNull);
      expect(ReaderSelectionScripts.highlightRectFromResult(''), isNull);
      expect(
          ReaderSelectionScripts.highlightRectFromResult('  null  '), isNull);
      expect(
        ReaderSelectionScripts.highlightRectFromResult(
          '{"x":10,"y":20,"width":0,"height":40}',
        ),
        isNull,
      );
      expect(
        ReaderSelectionScripts.highlightRectFromResult('not-json'),
        isNull,
      );
    });
  });

  group('ReaderSelectionScripts.clearInvocation', () {
    test('generates correct JS call', () {
      expect(
        ReaderSelectionScripts.clearInvocation(),
        'window.hoshiSelection.clearSelection()',
      );
    });
  });

  group('ReaderSelectionScripts.didSelectNothing', () {
    test('null returns true', () {
      expect(ReaderSelectionScripts.didSelectNothing(null), isTrue);
    });

    test('empty string returns true', () {
      expect(ReaderSelectionScripts.didSelectNothing(''), isTrue);
    });

    test('"null" string returns true', () {
      expect(ReaderSelectionScripts.didSelectNothing('null'), isTrue);
    });

    test('whitespace-only returns true', () {
      expect(ReaderSelectionScripts.didSelectNothing('   '), isTrue);
    });

    test('quoted null returns true', () {
      expect(ReaderSelectionScripts.didSelectNothing('"null"'), isTrue);
    });

    test('valid text returns false', () {
      expect(ReaderSelectionScripts.didSelectNothing('猫'), isFalse);
    });

    test('quoted text returns false', () {
      expect(ReaderSelectionScripts.didSelectNothing('"食べる"'), isFalse);
    });

    test('JSON object returns false', () {
      expect(
        ReaderSelectionScripts.didSelectNothing('{"text":"hello"}'),
        isFalse,
      );
    });
  });

  group('ReaderSelectionScripts.script', () {
    test('wraps source in script tag', () {
      final String result = ReaderSelectionScripts.script();
      expect(result, startsWith('<script>'));
      expect(result, endsWith('</script>'));
    });

    test('contains hoshiSelection object', () {
      expect(
        ReaderSelectionScripts.source(),
        contains('window.hoshiSelection'),
      );
    });
  });

  group('ReaderSelectionScripts.source contract', () {
    late String js;

    setUp(() {
      js = ReaderSelectionScripts.source();
    });

    test('defines CJK ideograph ranges', () {
      expect(js, contains('CJK_UNIFIED_IDEOGRAPHS_RANGE'));
      expect(js, contains('CJK_IDEOGRAPH_RANGES'));
    });

    test('defines Japanese character ranges', () {
      expect(js, contains('JAPANESE_RANGES'));
      expect(js, contains('0x3040')); // hiragana start
      expect(js, contains('0x30a0')); // katakana start
    });

    test('defines all selection methods', () {
      expect(js, contains('selectText:'));
      expect(js, contains('selectFromPosition:'));
      expect(js, contains('clearSelection:'));
      expect(js, contains('highlightSelection:'));
      expect(js, contains('getCharacterAtPoint:'));
      expect(js, contains('getSentenceContext:'));
      expect(js, contains('getNormalizedOffset:'));
    });

    test(
        'selectText delegates to selectFromPosition (shared core for the '
        'coordinate and caret paths)', () {
      expect(
          js, contains('return this.selectFromPosition(hit.node, hit.offset'));
    });

    test(
        'selectFromPosition fires the onTextSelected handler (caret lookup '
        'reuses the same dictionary pipeline)', () {
      // Single onTextSelected emitter lives in selectFromPosition.
      final int emitters = "callHandler('onTextSelected'".allMatches(js).length;
      expect(emitters, 1);
    });

    test('defines sentence delimiters', () {
      expect(js, contains('sentenceDelimiters'));
      expect(js, contains('scanDelimiters'));
    });

    test('calls Flutter InAppWebView handler for text selection', () {
      expect(js, contains("callHandler('onTextSelected'"));
    });

    test('calls Flutter InAppWebView handler for empty tap', () {
      expect(js, contains("callHandler('onTapEmpty'"));
    });

    // TODO-851：selectText 签名带第 4 参 fromHover。
    test('selectText accepts fromHover discriminator parameter', () {
      expect(js, contains('selectText: function(x, y, maxLength, fromHover)'));
    });

    // TODO-851 核心守卫：空白命中（getCharacterAtPoint 返 null）时唯一的
    // onTapEmpty 调用必须被 `if (!fromHover)` 包住——悬停查词命中空白只清选区，
    // 不能 fire onTapEmpty（否则反复 toggle 操作栏导致闪烁）；真点击仍 fire。
    test('onTapEmpty only fires on the non-hover (tap) path', () {
      // 全脚本仅一处 onTapEmpty 调用（selectText 空白分支）。
      final int emitters = "callHandler('onTapEmpty'".allMatches(js).length;
      expect(emitters, 1);
      // 该调用紧跟在 `if (!fromHover) {` 守卫之后。
      final RegExp guard = RegExp(
        r'if\s*\(\s*!fromHover\s*\)\s*\{\s*'
        r"window\.flutter_inappwebview\.callHandler\('onTapEmpty'\);",
      );
      expect(
        guard.hasMatch(js),
        isTrue,
        reason: 'onTapEmpty must be gated behind `if (!fromHover)`',
      );
    });

    test('includes CSS Highlights API support detection', () {
      expect(js, contains('__hoshiCssHighlightsSupported'));
      expect(js, contains('CSS.highlights'));
    });

    test('highlightSelection returns bounds for popup positioning', () {
      expect(js, contains('return null;'));
      expect(js, contains('bounds.left'));
      expect(js, contains('width: bounds.right - bounds.left'));
      expect(js, contains('height: bounds.bottom - bounds.top'));
    });

    test('defines bracket pairs for sentence extraction', () {
      expect(js, contains("'「':'」'"));
      expect(js, contains("'『': '』'"));
    });
  });
}
