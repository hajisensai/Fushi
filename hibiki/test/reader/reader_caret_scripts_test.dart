import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';

void main() {
  group('ReaderCaretScripts invocations', () {
    test('enter / exit / lookup / refresh', () {
      expect(ReaderCaretScripts.enterInvocation(),
          'JSON.stringify(window.hoshiCaret.enter())');
      expect(ReaderCaretScripts.exitInvocation(), 'window.hoshiCaret.exit()');
      expect(
          ReaderCaretScripts.lookupInvocation(), 'window.hoshiCaret.lookup()');
      expect(ReaderCaretScripts.activateInvocation(),
          'window.hoshiCaret.activate()');
      expect(ReaderCaretScripts.refreshInvocation(),
          'JSON.stringify(window.hoshiCaret.refresh())');
    });

    test('move passes the direction token through', () {
      expect(ReaderCaretScripts.moveInvocation('left'),
          "JSON.stringify(window.hoshiCaret.move('left'))");
      expect(ReaderCaretScripts.moveInvocation('forward'),
          "JSON.stringify(window.hoshiCaret.move('forward'))");
    });

    test('reanchor passes the edge token through', () {
      expect(ReaderCaretScripts.reanchorInvocation('forward'),
          "JSON.stringify(window.hoshiCaret.reanchor('forward'))");
      expect(ReaderCaretScripts.reanchorInvocation('backward'),
          "JSON.stringify(window.hoshiCaret.reanchor('backward'))");
    });

    test('init embeds colour + insets, scopeSelector defaults to null', () {
      expect(
        ReaderCaretScripts.initInvocation(
            color: '#ff8a00', insetTop: 24.0, insetBottom: 48.0),
        "window.hoshiCaret.init({color:'#ff8a00',insetTop:24.0,"
        'insetBottom:48.0,scopeSelector:null})',
      );
    });

    test('init embeds a scopeSelector when given (popup definition body)', () {
      expect(
        ReaderCaretScripts.initInvocation(
          color: '#ff8a00',
          insetTop: 0,
          insetBottom: 0,
          scopeSelector: '.glossary-content',
        ),
        "window.hoshiCaret.init({color:'#ff8a00',insetTop:0.0,"
        "insetBottom:0.0,scopeSelector:'.glossary-content'})",
      );
    });
  });

  group('ReaderCaretScripts.moveStatus', () {
    test('reads status field', () {
      expect(ReaderCaretScripts.moveStatus('{"status":"moved"}'), 'moved');
      expect(ReaderCaretScripts.moveStatus('{"status":"pageForward"}'),
          'pageForward');
      expect(ReaderCaretScripts.moveStatus('{"status":"pageBackward"}'),
          'pageBackward');
      expect(ReaderCaretScripts.moveStatus('{"status":"blocked"}'), 'blocked');
    });

    test('maps enter/reanchor {ok:..} to moved/blocked', () {
      expect(ReaderCaretScripts.moveStatus('{"ok":true,"rect":{}}'), 'moved');
      expect(ReaderCaretScripts.moveStatus('{"ok":false}'), 'blocked');
    });

    test('defaults to blocked on null / junk / empty', () {
      expect(ReaderCaretScripts.moveStatus(null), 'blocked');
      expect(ReaderCaretScripts.moveStatus('null'), 'blocked');
      expect(ReaderCaretScripts.moveStatus(''), 'blocked');
      expect(ReaderCaretScripts.moveStatus('not-json'), 'blocked');
    });

    test('accepts a map payload from the platform bridge', () {
      expect(
        ReaderCaretScripts.moveStatus(<String, Object?>{'status': 'moved'}),
        'moved',
      );
    });
  });

  group('ReaderCaretScripts.rectOf', () {
    test('parses a caret rect', () {
      final rect = ReaderCaretScripts.rectOf(
          '{"status":"moved","rect":{"x":10,"y":20,"width":8,"height":16}}');
      expect(rect?.left, 10);
      expect(rect?.top, 20);
      expect(rect?.width, 8);
      expect(rect?.height, 16);
    });

    test('null when missing or degenerate', () {
      expect(ReaderCaretScripts.rectOf('{"status":"blocked"}'), isNull);
      expect(
        ReaderCaretScripts.rectOf(
            '{"rect":{"x":0,"y":0,"width":0,"height":10}}'),
        isNull,
      );
      expect(ReaderCaretScripts.rectOf(null), isNull);
    });
  });

  group('ReaderCaretScripts.source contract', () {
    late String js;
    setUp(() => js = ReaderCaretScripts.source());

    test('defines the caret object and public API', () {
      expect(js, contains('window.hoshiCaret'));
      expect(js, contains('enter:'));
      expect(js, contains('exit:'));
      expect(js, contains('move:'));
      expect(js, contains('reanchor:'));
      expect(js, contains('lookup:'));
      expect(js, contains('activate:'));
      expect(js, contains('refresh:'));
      expect(js, contains('init:'));
      expect(js, contains('isActive:'));
    });

    test('activate is a context click: link/control click else lookup', () {
      // A hyperlink is followed, any clickable ancestor is clicked, and plain
      // text falls back to the lookup pipeline.
      expect(js, contains("closest('a[href]')"));
      expect(js, contains('link.click()'));
      expect(js, contains("closest('[data-hoshi-clk]')"));
      expect(js, contains('control.click()'));
    });

    test('popup clickable detection is unified (control/onclick/pointer)', () {
      // _markClickables tags every clickable element with data-hoshi-clk so
      // _isStop (text rejection) and _interactiveEls (element stops) agree on
      // what is a control — covering pointer-cursor collapsibles with no role.
      expect(js, contains('_markClickables:'));
      expect(js, contains('data-hoshi-clk'));
      expect(js, contains("cursor === 'pointer'"));
    });

    test('popup caret skips passive term/POS tags (.glossary-tag, e.g. name)',
        () {
      expect(js, contains("closest('.glossary-tag')"));
    });

    test('resolves writing-mode and paged vs continuous from live state', () {
      expect(js, contains('_vertical:'));
      expect(js, contains('isVertical'));
      expect(js, contains("'paginationMetrics' in window.hoshiReader"));
    });

    test('maps physical directions to logical ones for vertical-rl', () {
      expect(js, contains('_logicalDir:'));
      // vertical-rl: down advances reading order, left is the next column
      expect(js, contains("if (dir === 'down') return 'forward'"));
      expect(js, contains("if (dir === 'left') return 'lineNext'"));
    });

    test('caret lookup reuses the selection pipeline', () {
      expect(js, contains('window.hoshiSelection'));
      expect(js, contains('selectFromPosition'));
    });

    test('signals page turns to Dart in paged mode', () {
      expect(js, contains("'pageForward'"));
      expect(js, contains("'pageBackward'"));
    });

    test('draws a fixed focus ring without mutating the text DOM', () {
      expect(js, contains('hoshi-caret-ring'));
      expect(js, contains('position:fixed'));
    });

    test('ring is clamped to the viewport so it never paints outside the host',
        () {
      // _drawRing must intersect the drawn rect with _viewport() before
      // painting, so a stop near the popup edge cannot draw a ring outside the
      // popup.
      expect(js, contains('_viewport()'));
      expect(js, contains('Math.max(rect.left'));
      expect(js, contains('Math.min(rect.left + rect.width'));
    });

    test('popup caret skips lone punctuation/symbol glyphs (e.g. " | ")', () {
      // In the popup (no hoshiReader) a single punctuation/symbol char is not a
      // useful lookup target and must not be a stop, so the caret never lands on
      // the thin "|" separator between source links.
      expect(js, contains(r'\p{P}'));
      expect(js, contains(r'\p{S}'));
    });

    test('vertical caret moves are line-aware (same-row controls not "above")',
        () {
      // Up/Down must cross to a DIFFERENT visual row; a same-row icon (the popup
      // ♪ beside the headword) is a Left/Right neighbour. Up from the top row
      // then finds nothing → blocks → Dart escapes to the Flutter header.
      expect(js, contains('sameRow'));
      expect(js, contains('sameCol'));
    });

    test('popup caret scrolls a partially-clipped stop into view', () {
      // _inViewport is intersection-based; move() must scroll an edge-clipped
      // stop fully into view (popup-only) so the view follows the cursor.
      expect(js, contains('_scrollIntoView(rect)'));
    });

    test('scopeSelector restricts stops to matching elements (popup scope)',
        () {
      expect(js, contains('scopeSelector'));
      expect(js, contains('closest(this.scopeSelector)'));
    });
  });
}
