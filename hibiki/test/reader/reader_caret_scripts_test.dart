import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';

void main() {
  group('ReaderCaretScripts invocations', () {
    test('enter / exit / lookup / refresh', () {
      expect(ReaderCaretScripts.enterInvocation(),
          'JSON.stringify(window.hoshiCaret.enter())');
      expect(ReaderCaretScripts.exitInvocation(), 'window.hoshiCaret.exit()');
      expect(ReaderCaretScripts.suspendInvocation(),
          'window.hoshiCaret.suspend()');
      expect(ReaderCaretScripts.resumeInvocation(),
          'JSON.stringify(window.hoshiCaret.resume())');
      expect(
          ReaderCaretScripts.lookupInvocation(), 'window.hoshiCaret.lookup()');
      expect(ReaderCaretScripts.activateInvocation(),
          'window.hoshiCaret.activate()');
      expect(ReaderCaretScripts.longPressInvocation(),
          'window.hoshiCaret.longPress()');
      expect(ReaderCaretScripts.refreshInvocation(),
          'JSON.stringify(window.hoshiCaret.refresh())');
    });

    test('move passes the direction token through', () {
      expect(ReaderCaretScripts.moveInvocation('left'),
          "JSON.stringify(window.hoshiCaret.move('left'))");
      expect(ReaderCaretScripts.moveInvocation('forward'),
          "JSON.stringify(window.hoshiCaret.move('forward'))");
    });

    test('scrollPage passes the direction boolean through (LB/RB page flip)',
        () {
      expect(ReaderCaretScripts.scrollPageInvocation(true),
          'JSON.stringify(window.hoshiCaret.scrollPage(true))');
      expect(ReaderCaretScripts.scrollPageInvocation(false),
          'JSON.stringify(window.hoshiCaret.scrollPage(false))');
      expect(ReaderCaretScripts.instantScrollInvocation(true),
          'window.hoshiCaret.setInstantScroll(true)');
      expect(ReaderCaretScripts.instantScrollInvocation(false),
          'window.hoshiCaret.setInstantScroll(false)');
    });

    test('jumpDict passes the direction boolean through (TODO-070 go-to-dict)',
        () {
      expect(ReaderCaretScripts.jumpDictInvocation(true),
          'JSON.stringify(window.hoshiCaret.jumpDict(true))');
      expect(ReaderCaretScripts.jumpDictInvocation(false),
          'JSON.stringify(window.hoshiCaret.jumpDict(false))');
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
      expect(js, contains('longPress:'));
      expect(js, contains('jumpDict:'));
      expect(js, contains('refresh:'));
      expect(js, contains('init:'));
      expect(js, contains('setInstantScroll:'));
      expect(js, contains('isActive:'));
    });

    test(
        'popup glossary images are caret-reachable (img in the interactive '
        'selector so A bubbles img.click() to open the image lightbox)', () {
      expect(js, contains('[role="link"], img'));
    });

    test('popup Up/Down jump by row, Left/Right per-glyph (上下跳项 / 左右逐字)', () {
      // _collectVisibleStops takes a lineLevel flag; popup vertical moves keep
      // one text stop per visual row (rounded top), so Up/Down hops rows /
      // elements instead of every glyph, while Left/Right and the reader stay
      // per-glyph (window.hoshiReader → lineLevel false).
      expect(js, contains('_collectVisibleStops: function(lineLevel)'));
      expect(js, contains('Math.round(rect.top)'));
      expect(js, contains('!window.hoshiReader &&'));
      expect(js, contains("physicalDir !== 'left' && physicalDir !== 'right'"));
    });

    test('scrollPage reuses the line-edge scroll primitive (no new branch)',
        () {
      // LB/RB page flip must share _pageOrScroll with a line move that runs off
      // the page edge, so popup-scroll and paged page-turn semantics never
      // diverge. scrollPage only guards on `active` then delegates.
      expect(js, contains('scrollPage: function(forwardish)'));
      expect(js, contains('return this._pageOrScroll(!!forwardish);'));
    });

    test(
        'jumpDict steps the caret between dictionary section headers (TODO-070)',
        () {
      // Yomitan-style "go to dictionary": jumpDict collects every
      // summary.dict-label, picks the next/previous one relative to the anchor,
      // and places it as an element stop (reusing _place/_elRect/_scrollIntoView
      // so the ring hugs the header and A toggles its disclosure). No further
      // dictionary → blocked; the reader (no dict-label) → blocked, a no-op.
      expect(js, contains('jumpDict: function(forward)'));
      expect(js, contains("querySelectorAll('summary.dict-label')"));
      expect(js, contains('_dictHeaders:'));
      // Reuses the element-stop placement machinery — no parallel ring code.
      expect(js, contains('this._scrollIntoView(target.rect);'));
      expect(js, contains('el: target.el'));
      // No headers (single-dictionary or empty) blocks instead of throwing.
      expect(
          js, contains("if (!headers.length) return { status: 'blocked' };"));
    });

    test('popup scroll can switch to instant movement for e-ink', () {
      expect(js, contains('instantScroll: false'));
      expect(js, contains('setInstantScroll: function(value)'));
      expect(js, contains('_scrollWindowBy: function(dx, dy)'));
      expect(js, contains("behavior: this.instantScroll ? 'instant' : 'auto'"));
      expect(
        js,
        isNot(contains('window.scrollBy(0, forwardish ? dist : -dist)')),
        reason: 'Viewport page scroll must go through the shared helper so the '
            'e-ink preference controls the behavior.',
      );
    });

    test('reader element stops are block illustrations (img.block-img)', () {
      // The reader's only element stops are block illustrations — the same
      // img.block-img the tap-gesture path opens (>256px, non-gaiji). A D-pad
      // line move reaches them via _collectVisibleStops; inline images/gaiji are
      // excluded so they never interrupt text navigation.
      expect(js, contains("querySelectorAll('img.block-img')"));
    });

    test('A on a reader illustration opens it via onImageTap (not el.click)',
        () {
      // Reader block images have no DOM click→lightbox listener, so activate()
      // must call the same onImageTap handler the pointer-gesture path uses;
      // el.click() would be a no-op.
      expect(js, contains("window.hoshiReader && this.el.tagName === 'IMG'"));
      expect(js, contains("callHandler('onImageTap', this.el.src)"));
    });

    test('caret can enter/re-anchor a pure-illustration page (element stop)',
        () {
      // _firstVisibleStop walks text only, so a page that is just an image needs
      // a fallback to the first visible element stop, or enter()/reanchor() would
      // refuse to place the caret.
      expect(js, contains('_firstVisibleElementStop:'));
      expect(js, contains('pos = this._firstVisibleElementStop();'));
    });

    test('activate is a context click: link/control click else lookup', () {
      // A hyperlink is followed, any clickable ancestor is clicked, and plain
      // text falls back to the lookup pipeline.
      expect(js, contains("closest('a[href]')"));
      expect(js, contains('link.click()'));
      expect(js, contains("closest('[data-hoshi-clk]')"));
      expect(js, contains('control.click()'));
    });

    test('long-press can mark popup dictionary summaries without toggling', () {
      expect(js, contains('longPress: function()'));
      expect(js, contains("closest('summary.dict-label')"));
      expect(js, contains('window.__hoshiDictLongPress(summary)'));
      expect(js, contains("return 'dict'"));
    });

    test('popup clickable detection is unified (control/onclick/pointer)', () {
      // _markClickables tags every clickable element with data-hoshi-clk so
      // _isStop (text rejection) and _interactiveEls (element stops) agree on
      // what is a control — covering pointer-cursor collapsibles with no role.
      expect(js, contains('_markClickables:'));
      expect(js, contains('data-hoshi-clk'));
      expect(js, contains("cursor === 'pointer'"));
    });

    test('popup caret excludes disabled controls from element stops', () {
      // A disabled mine/action button is visible but not actionable. It must not
      // receive data-hoshi-clk, otherwise the gamepad ring can land on a dead
      // control and A becomes a no-op.
      expect(js, contains(':disabled, [aria-disabled="true"]'));
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

    test('directional element moves use a cross-axis beam', () {
      // A candidate whose cross-axis overlaps the anchor (same row for L/R, same
      // column for U/D) beats a nearer-but-misaligned one, so RIGHT from the
      // headword picks the same-row ♪ over the definition text just below.
      expect(js, contains('beam'));
      expect(js, contains('beamN > bestBeam'));
    });

    test('popup text moves are physical geometry, not reading-order stepping',
        () {
      expect(js, contains('if (!window.hoshiReader) {'));
      expect(js, contains('target = this._geomMove(physical);'));
    });

    test('Left/Right off an element-stop row end blocks (no fly-off)', () {
      // RIGHT from the rightmost control (e.g. +) has no candidate; it must
      // block, not scroll + line-jump to an off-screen stop.
      expect(
        js,
        contains(
            "!window.hoshiReader && (physical === 'left' || physical === 'right')"),
      );
    });

    test('suspend/resume hide and re-show the ring without dropping the caret',
        () {
      // Mouse hides the ring (suspend) but keeps `active`, so keyboard/gamepad
      // resume keeps the caret on its surface instead of paging the reader.
      expect(js, contains('suspend:'));
      expect(js, contains('resume:'));
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

    test('element-stop ring hugs visible ink, not the full border box', () {
      // 元素停靠点（弹窗 ♪/+ 按钮、折叠词典段 summary）必须把焦点环画在元素的
      // 可见内容 rect（_elRect → _elInk：内容 client rects 并集，clamp 到 border
      // box）上，而不是 el.getBoundingClientRect()——后者含 padding/行盒/transform，
      // 渲染成比字形大且错位的空盒子。(BUG-018)
      expect(js, contains('_elInk:'));
      expect(js, contains('_elRect:'));
      expect(js, contains('selectNodeContents'));
      expect(js, contains('getClientRects'));
    });

    test('element stops route ring + geometry through _elRect (no raw box)',
        () {
      // _stopRect 与 _anchorRect 必须经 _elRect 取元素 rect，使焦点环、命中测试、
      // 方向几何都用收紧后的可见 rect。
      expect(js, contains('if (stop.el) return this._elRect(stop.el);'));
      expect(
        js,
        contains(
            'if (this.el && document.contains(this.el)) return this._elRect(this.el);'),
      );
    });

    test('empty clickable wrappers are not element stops (ink or image only)',
        () {
      // 无文字 ink 且非替换元素（图片）的 clickable 是空 wrapper，必须跳过，
      // 焦点环不得落在空白盒子上；图片本身无文字 ink，其 border box 即内容。
      expect(js, contains('!this._elInk(e)'));
      expect(js, contains('picture, video, canvas, svg'));
    });
  });
}
