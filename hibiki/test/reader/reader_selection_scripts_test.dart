import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

void main() {
  group('ReaderSelectionScripts.selectInvocation', () {
    test('generates correct JS call', () {
      expect(
        ReaderSelectionScripts.selectInvocation(100.5, 200.0, 50),
        'window.hoshiSelection.selectText(100.5, 200.0, 50)',
      );
    });

    test('handles zero coordinates', () {
      expect(
        ReaderSelectionScripts.selectInvocation(0, 0, 1),
        'window.hoshiSelection.selectText(0.0, 0.0, 1)',
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

    test('selectText delegates to selectFromPosition (shared core for the '
        'coordinate and caret paths)', () {
      expect(js, contains('return this.selectFromPosition(hit.node, hit.offset'));
    });

    test('selectFromPosition fires the onTextSelected handler (caret lookup '
        'reuses the same dictionary pipeline)', () {
      // Single onTextSelected emitter lives in selectFromPosition.
      final int emitters =
          "callHandler('onTextSelected'".allMatches(js).length;
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
