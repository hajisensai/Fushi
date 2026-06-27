import 'dart:convert';
import 'dart:ui';

/// JavaScript "char caret" for the reader: a single focused character inside the
/// EPUB DOM that the keyboard/gamepad can step character-by-character, with a
/// fixed-position focus ring drawn over it. The caret lives in JS because the
/// text lives in the WebView DOM (Flutter focus can only reach the WebView
/// widget, not a glyph inside it).
///
/// Writing-mode (horizontal vs. vertical-rl) and continuous-vs-paged scrolling
/// are resolved here, against the live computed style / `window.hoshiReader`
/// state — the single source of truth. Word lookup reuses
/// `window.hoshiSelection.selectFromPosition`, so a caret lookup hits the exact
/// same dictionary pipeline as a tap.
///
/// This Dart class only builds the script and the `evaluateJavascript`
/// invocation strings, and parses the small JSON status payloads returned by
/// [moveInvocation] / [reanchorInvocation] / [enterInvocation].
class ReaderCaretScripts {
  ReaderCaretScripts._();

  /// Activate the caret (restore remembered position if still visible, else the
  /// first visible character). Returns `{ok, rect}`.
  static String enterInvocation() =>
      'JSON.stringify(window.hoshiCaret.enter())';

  /// Deactivate the caret and hide the ring (keeps the remembered position).
  static String exitInvocation() => 'window.hoshiCaret.exit()';

  /// Hide the ring but keep the caret active/owned (used when the user switches
  /// to the mouse); [resumeInvocation] re-shows it for keyboard/gamepad.
  static String suspendInvocation() => 'window.hoshiCaret.suspend()';
  static String resumeInvocation() =>
      'JSON.stringify(window.hoshiCaret.resume())';

  /// Move the caret. [dir] is a physical direction (`up`/`down`/`left`/`right`)
  /// or a logical one (`forward`/`backward`/`lineNext`/`linePrev`). Returns
  /// `{status, rect}` where status ∈ moved | pageForward | pageBackward |
  /// blocked.
  static String moveInvocation(String dir) =>
      "JSON.stringify(window.hoshiCaret.move('$dir'))";

  /// Whole-page scroll accelerator (LB/RB) on the active caret surface.
  /// [forward] true scrolls toward reading order. Returns the same
  /// `{status, rect}` shape as [moveInvocation] (popup → moved/blocked,
  /// paged reader → pageForward/pageBackward) so callers reuse [moveStatus].
  static String scrollPageInvocation(bool forward) =>
      'JSON.stringify(window.hoshiCaret.scrollPage($forward))';

  /// Jump the popup caret to the next/previous dictionary section header
  /// (`summary.dict-label`), Yomitan-style "go to dictionary". [forward] true
  /// jumps to the next dictionary below the cursor, false to the previous one
  /// above. Returns the same `{status, rect}` shape as [moveInvocation]
  /// (`moved`/`blocked`) so callers reuse [moveStatus] / [rectOf]. Popup-only:
  /// the reader has no dictionary sections, so this no-ops there (`blocked`).
  static String jumpDictInvocation(bool forward) =>
      'JSON.stringify(window.hoshiCaret.jumpDict($forward))';

  /// Toggle popup caret scrolling between the default browser movement and
  /// explicit instant movement for e-ink screens.
  static String instantScrollInvocation(bool enabled) =>
      'window.hoshiCaret.setInstantScroll($enabled)';

  /// After a page turn, place the caret at the entering edge of the new page
  /// ([edge] = `forward` → first visible char, `backward` → last visible char).
  static String reanchorInvocation(String edge) =>
      "JSON.stringify(window.hoshiCaret.reanchor('$edge'))";

  /// Look up the word at the caret (reuses the tap dictionary pipeline).
  static String lookupInvocation() => 'window.hoshiCaret.lookup()';

  /// Context "click" at the caret: follow a hyperlink, click an interactive
  /// control (popup audio/expand buttons), or — on plain text — look up the
  /// word. Returns `'link'` | `'activated'` | `'lookup'` | `'none'`.
  static String activateInvocation() => 'window.hoshiCaret.activate()';

  /// Long-press at the caret. Used by gamepad hold-A for actions that are not
  /// the same as short activation, such as marking a popup dictionary summary
  /// without toggling its disclosure row.
  static String longPressInvocation() => 'window.hoshiCaret.longPress()';

  /// Re-measure the ring after a relayout; re-anchors if the node detached.
  static String refreshInvocation() =>
      'JSON.stringify(window.hoshiCaret.refresh())';

  /// Configure the ring colour and the chrome insets used for the
  /// "is on the current page" viewport test. [scopeSelector] (a CSS selector)
  /// restricts the cursor to text inside matching elements — the dictionary
  /// popup passes `.glossary-content`; the reader omits it (whole document).
  static String initInvocation({
    required String color,
    required double insetTop,
    required double insetBottom,
    String? scopeSelector,
  }) {
    final String scope = scopeSelector == null ? 'null' : "'$scopeSelector'";
    return "window.hoshiCaret.init({color:'$color',insetTop:$insetTop,"
        'insetBottom:$insetBottom,scopeSelector:$scope})';
  }

  /// Status field of a [moveInvocation] / [reanchorInvocation] / [enterInvocation]
  /// result; defaults to `blocked` when the payload is missing/unparseable.
  static String moveStatus(Object? raw) {
    final Map<String, dynamic>? data = _decode(raw);
    if (data == null) return 'blocked';
    final Object? status = data['status'];
    if (status is String) return status;
    // enter()/reanchor() return {ok:bool,...}; treat ok as moved/blocked.
    final Object? ok = data['ok'];
    if (ok is bool) return ok ? 'moved' : 'blocked';
    return 'blocked';
  }

  /// Caret rect from a result payload, if present.
  static Rect? rectOf(Object? raw) {
    final Map<String, dynamic>? data = _decode(raw);
    if (data == null) return null;
    final Object? r = data['rect'];
    if (r is! Map) return null;
    final Map<String, dynamic> rect = Map<String, dynamic>.from(r);
    final num? x = rect['x'] as num?;
    final num? y = rect['y'] as num?;
    final num? w = rect['width'] as num?;
    final num? h = rect['height'] as num?;
    if (x == null || y == null || w == null || h == null) return null;
    if (w <= 0 || h <= 0) return null;
    return Rect.fromLTWH(
        x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
  }

  static Map<String, dynamic>? _decode(Object? raw) {
    if (raw == null) return null;
    try {
      if (raw is Map) return Map<String, dynamic>.from(raw);
      if (raw is String) {
        final String trimmed = raw.trim();
        if (trimmed.isEmpty || trimmed == 'null') return null;
        final Object? decoded = jsonDecode(trimmed);
        if (decoded is Map) return Map<String, dynamic>.from(decoded);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  static String source() => r"""
window.hoshiCaret = {
  active: false,
  node: null,
  offset: 0,
  // When the cursor sits on an interactive element (a button / link / control
  // with no usable text glyph — e.g. an icon-only popup action), `el` holds it
  // and `node` is null. Plain text stops set `node`/`offset` and leave `el` null.
  el: null,
  insetTop: 0,
  insetBottom: 0,
  ringColor: 'rgba(255,138,0,0.98)',
  // When set (a CSS selector), the cursor only stops on text whose nearest
  // element ancestor matches it — used in the dictionary popup to keep the
  // cursor inside the definition body (.glossary-content), exactly like the tap
  // path. Empty/null = stop on any text (reader content).
  scopeSelector: null,
  instantScroll: false,
  _ring: null,
  _memNode: null,
  _memOffset: null,

  // ── Mode / writing-mode ────────────────────────────────────────────
  _vertical: function() {
    if (window.hoshiReader && typeof window.hoshiReader.isVertical === 'function') {
      return window.hoshiReader.isVertical();
    }
    // Match hoshiReader.isVertical(): the reader only lays out vertical-rl.
    return window.getComputedStyle(document.body).writingMode === 'vertical-rl';
  },
  _paged: function() {
    return !!(window.hoshiReader && ('paginationMetrics' in window.hoshiReader));
  },
  _logicalDir: function(dir, vertical) {
    if (dir === 'forward' || dir === 'backward' || dir === 'lineNext' || dir === 'linePrev') {
      return dir;
    }
    if (!vertical) {
      if (dir === 'right') return 'forward';
      if (dir === 'left') return 'backward';
      if (dir === 'down') return 'lineNext';
      if (dir === 'up') return 'linePrev';
    } else {
      // vertical-rl: glyphs flow top→bottom, columns advance right→left.
      if (dir === 'down') return 'forward';
      if (dir === 'up') return 'backward';
      if (dir === 'left') return 'lineNext';
      if (dir === 'right') return 'linePrev';
    }
    return 'forward';
  },

  // ── Character model ────────────────────────────────────────────────
  _charLen: function(text, i) {
    var cp = text.codePointAt(i);
    return (cp !== undefined && cp > 0xFFFF) ? 2 : 1;
  },
  _prevIndex: function(text, i) {
    if (i <= 0) return -1;
    var j = i - 1;
    if (j > 0) {
      var c = text.charCodeAt(j);
      if (c >= 0xDC00 && c <= 0xDFFF) j -= 1; // step over a low surrogate
    }
    return j;
  },
  _isStop: function(node, offset) {
    var text = node.textContent;
    if (offset < 0 || offset >= text.length) return false;
    var ch = text[offset];
    if (/^[\s　]$/.test(ch)) return false; // skip whitespace/newlines
    if (!window.hoshiReader) {
      // Popup-only: a lone punctuation/symbol glyph (the " | " separator between
      // source links, list bullets, brackets) is not a useful lookup target —
      // don't stop on it, so the cursor never lands on a thin separator sliver.
      // Words/kanji (the real targets) are unaffected. `ch` is one UTF-16 unit,
      // so this only matches BMP punctuation/symbols; a non-BMP symbol's lone
      // high surrogate (cat. Cs) won't match — fail-safe (it stays stoppable),
      // and such separators don't occur in dictionary glossaries.
      if (/^[\p{P}\p{S}]$/u.test(ch)) return false;
      // Text inside a clickable element is not its own stop — the element is an
      // atomic stop (the ring covers the whole control, e.g. a ▶ Grammar collapse
      // toggle) so A clicks the control instead of looking up a glyph inside it.
      // Passive term/POS tags (.glossary-tag, e.g. "name") are labels, not lookup
      // targets, so they are not reachable at all. data-hoshi-clk is refreshed by
      // _markClickables at every entry point before this runs.
      var ie = node.parentElement;
      if (ie && (ie.closest('[data-hoshi-clk]') || ie.closest('.glossary-tag'))) {
        return false;
      }
    }
    if (this.scopeSelector) {
      var el = node.parentElement;
      if (!el || !el.closest(this.scopeSelector)) return false;
    }
    return true;
  },
  _walker: function() {
    if (window.hoshiSelection && typeof window.hoshiSelection.createWalker === 'function') {
      return window.hoshiSelection.createWalker(document.body); // rejects furigana
    }
    return document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, null);
  },
  _charRect: function(node, offset) {
    var len = this._charLen(node.textContent, offset);
    var range = document.createRange();
    range.setStart(node, offset);
    range.setEnd(node, offset + len);
    var rects = range.getClientRects();
    if (rects && rects.length) {
      for (var i = 0; i < rects.length; i++) {
        if (rects[i].width > 0 && rects[i].height > 0) return rects[i];
      }
    }
    return range.getBoundingClientRect();
  },

  // ── Element-stop ink rect ──────────────────────────────────────────
  // _elInk: the union of an element's OWN content client rects (text glyphs /
  // inline children), i.e. the visible ink — the ♪/+ glyph, the dict-label
  // text. Pseudo-elements (a summary's ▶ ::before) are not in the Range and are
  // intentionally excluded. Returns null when the element has no own text/inline
  // ink (an <img>, or a truly empty wrapper).
  _elInk: function(el) {
    var range = document.createRange();
    var rects;
    // Both selectNodeContents and getClientRects can throw on a detached /
    // display:contents node in some WebViews; treat any failure as "no ink"
    // (return null) so an element stop never escalates into an uncaught throw
    // that would break move()/refresh().
    try { range.selectNodeContents(el); rects = range.getClientRects(); }
    catch (e) { return null; }
    var L = Infinity, T = Infinity, R = -Infinity, B = -Infinity, found = false;
    for (var i = 0; i < rects.length; i++) {
      var r = rects[i];
      if (r.width <= 0 || r.height <= 0) continue;
      found = true;
      if (r.left < L) L = r.left;
      if (r.top < T) T = r.top;
      if (r.right > R) R = r.right;
      if (r.bottom > B) B = r.bottom;
    }
    if (!found) return null;
    return { left: L, top: T, right: R, bottom: B, width: R - L, height: B - T };
  },
  // _elRect: rect for an element stop's ring / geometry. Prefer the visible ink
  // (clamped to the border box so a descendant overflow can't paint outside),
  // falling back to the border box for ink-less stops (images fill their box).
  // The element-stop analogue of _charRect for text stops, so element rings hug
  // their glyph/label instead of a padded, line-box-tall, transform-shifted box.
  _elRect: function(el) {
    var box = el.getBoundingClientRect();
    var ink = this._elInk(el);
    if (!ink) return box;
    var left = Math.max(ink.left, box.left);
    var top = Math.max(ink.top, box.top);
    var right = Math.min(ink.right, box.right);
    var bottom = Math.min(ink.bottom, box.bottom);
    if (right <= left || bottom <= top) return box;
    return { left: left, top: top, right: right, bottom: bottom,
             width: right - left, height: bottom - top };
  },

  // ── Interactive element stops ──────────────────────────────────────
  // Besides text glyphs, the cursor can land on interactive elements so a
  // gamepad can reach buttons/links/controls (e.g. the dictionary popup's
  // collapse toggles, audio/pitch controls and action buttons — many of which
  // are icon-only with no text glyph to land on). A then clicks them.
  // `summary` is the dictionary popup's collapse toggle (a native <details>
  // disclosure); treat it as one whole interactive stop so the ring covers the
  // whole row and A toggles the section, rather than landing on a child sliver.
  // `img` is the dictionary popup's glossary image (`a.gloss-image-link` has no
  // href, so the cursor could not reach it before): the caret stops on it and A
  // bubbles img.click() to its parent link → openImageLightbox. This selector is
  // popup-only (`_markClickables` returns early in the reader); the reader's own
  // element stops (block illustrations) come from the `_interactiveEls` reader
  // branch, not from this selector.
  _interactiveSelector:
      'a[href], button, summary, [role="button"], [role="link"], img',
  // Tag every clickable element (popup-only) with data-hoshi-clk, so text-stop
  // rejection (_isStop) and element-stop collection (_interactiveEls) share ONE
  // definition of "clickable": an explicit control, an onclick handler, or a
  // pointer cursor. Wiktionary collapsibles (▶ Grammar/Etymology) and icon-only
  // controls bound via addEventListener carry no semantic tag/role, so the
  // pointer-cursor probe is what catches them. Cheap for the small popup DOM;
  // returns early in the reader (whose only element stops are block images,
  // collected by _interactiveEls directly — no data-hoshi-clk tagging needed).
  // Called from every public entry point (move/enter/reanchor/refresh/activate)
  // so tags are always fresh.
  _markClickables: function() {
    if (window.hoshiReader) return;
    var all = document.body.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      var e = all[i], clk = false;
      if (e.matches(':disabled, [aria-disabled="true"]')) {
        clk = false;
      } else if (e.matches(this._interactiveSelector) || e.onclick) {
        clk = true;
      } else {
        try {
          if (window.getComputedStyle(e).cursor === 'pointer') {
            // cursor:pointer INHERITS, so the headword/kanji-tag's ruby/spans all
            // report pointer too. Only the OUTERMOST pointer element is the real
            // control; a descendant that merely inherits pointer is part of the
            // same control, not its own stop — otherwise the ring would fragment
            // onto a child glyph instead of covering the whole control.
            var p = e.parentElement;
            var pPointer = false;
            try { pPointer = !!p && window.getComputedStyle(p).cursor === 'pointer'; } catch (x2) {}
            clk = !pPointer;
          }
        } catch (x) {}
      }
      if (clk) { if (!e.hasAttribute('data-hoshi-clk')) e.setAttribute('data-hoshi-clk', ''); }
      else if (e.hasAttribute('data-hoshi-clk')) e.removeAttribute('data-hoshi-clk');
    }
  },
  _interactiveEls: function() {
    // In the reader the only element stops are block illustrations: img.block-img
    // is the reader's own tag for an image wider/taller than 256px and not gaiji
    // (reader_pagination_scripts _sharedInitImages), i.e. the exact set the
    // tap-gesture path opens. They are block-level, on their own row, so a D-pad
    // line move — which consults these via _collectVisibleStops/_lineMove — can
    // land on one without disturbing text-row navigation, and activate() opens it
    // through onImageTap. Inline images and gaiji are excluded so they never
    // interrupt reading; hyperlinks stay reachable as text stops.
    if (window.hoshiReader) {
      return Array.prototype.slice.call(
        document.body.querySelectorAll('img.block-img'));
    }
    var marked = document.body.querySelectorAll('[data-hoshi-clk]');
    var out = [];
    for (var i = 0; i < marked.length; i++) {
      var e = marked[i];
      var r = this._elRect(e);
      if (r.width < 6 || r.height < 6) continue; // skip degenerate/sliver elements
      // A clickable with no visible ink and no replaced content (image) is an
      // empty wrapper — skip it so the ring never lands on a blank box. Images
      // legitimately have no text ink; their border box IS their content.
      if (!this._elInk(e) &&
          !e.matches('img, picture, video, canvas, svg, [role="img"]')) {
        continue;
      }
      // Prefer the innermost control: a clickable that wraps another clickable is
      // a container — descend so the ring lands on the real icon/button — unless
      // it is an atomic disclosure/control we always want whole (summary/role).
      if (!e.matches('summary, [role="button"], [role="link"]') &&
          e.querySelector('[data-hoshi-clk]')) {
        continue;
      }
      out.push(e);
    }
    return out;
  },
  _stopRect: function(stop) {
    if (stop.el) return this._elRect(stop.el);
    return this._charRect(stop.node, stop.offset);
  },
  _anchorRect: function() {
    if (this.el && document.contains(this.el)) return this._elRect(this.el);
    if (this.node && document.contains(this.node)) return this._charRect(this.node, this.offset);
    return null;
  },

  // ── Viewport (current page) ────────────────────────────────────────
  _viewport: function() {
    return {
      left: 0,
      top: this.insetTop || 0,
      right: window.innerWidth,
      bottom: window.innerHeight - (this.insetBottom || 0)
    };
  },
  _inViewport: function(rect) {
    if (!rect || rect.width <= 0 || rect.height <= 0) return false;
    var vp = this._viewport();
    return rect.right > vp.left && rect.left < vp.right &&
           rect.bottom > vp.top && rect.top < vp.bottom;
  },

  // ── Stepping ───────────────────────────────────────────────────────
  _nextStop: function(node, offset) {
    var walker = this._walker();
    walker.currentNode = node;
    var text = node.textContent;
    var i = offset + this._charLen(text, offset);
    while (true) {
      while (i < text.length) {
        if (this._isStop(node, i)) return { node: node, offset: i };
        i += this._charLen(text, i);
      }
      var n = walker.nextNode();
      if (!n) return null;
      node = n; text = node.textContent; i = 0;
    }
  },
  _prevStop: function(node, offset) {
    var walker = this._walker();
    walker.currentNode = node;
    var text = node.textContent;
    var i = this._prevIndex(text, offset);
    while (true) {
      while (i >= 0) {
        if (this._isStop(node, i)) return { node: node, offset: i };
        i = this._prevIndex(text, i);
      }
      var n = walker.previousNode();
      if (!n) return null;
      node = n; text = node.textContent; i = this._prevIndex(text, text.length);
    }
  },
  // [lineLevel] (popup vertical moves): keep ONE text stop per visual row
  // (keyed by rounded top) so Up/Down hops between rows/elements instead of
  // every glyph — "上下跳项". Left/Right and the reader pass it falsy so text
  // stays per-character — "左右逐字". Element (interactive) stops are always
  // kept in both modes.
  _collectVisibleStops: function(lineLevel) {
    var walker = this._walker();
    var out = [];
    var node;
    var seenRows = {};
    while (node = walker.nextNode()) {
      var text = node.textContent;
      for (var i = 0; i < text.length;) {
        var len = this._charLen(text, i);
        if (this._isStop(node, i)) {
          var rect = this._charRect(node, i);
          if (this._inViewport(rect)) {
            var rowKey = lineLevel ? Math.round(rect.top) : -1;
            if (!lineLevel || !seenRows[rowKey]) {
              if (lineLevel) seenRows[rowKey] = true;
              out.push({
                node: node, offset: i, el: null, rect: rect,
                cx: rect.left + rect.width / 2,
                cy: rect.top + rect.height / 2
              });
            }
          }
        }
        i += len;
      }
    }
    var els = this._interactiveEls();
    for (var k = 0; k < els.length; k++) {
      var er = this._elRect(els[k]);
      if (this._inViewport(er)) {
        out.push({
          node: null, offset: 0, el: els[k], rect: er,
          cx: er.left + er.width / 2,
          cy: er.top + er.height / 2
        });
      }
    }
    return out;
  },
  _geomMove: function(physicalDir) {
    var a = this._anchorRect();
    if (!a) return null;
    var acx = a.left + a.width / 2;
    var acy = a.top + a.height / 2;
    // Popup: Up/Down jump by row/element (skip per-glyph stops), Left/Right
    // step per-glyph within the current text. The reader keeps per-glyph both
    // ways (window.hoshiReader → lineLevel false).
    var lineLevel = !window.hoshiReader &&
      physicalDir !== 'left' && physicalDir !== 'right';
    var stops = this._collectVisibleStops(lineLevel);
    var eps = 2;
    // Directional move with a "beam": a candidate whose cross-axis OVERLAPS the
    // anchor (same row for left/right, same column for up/down) always beats one
    // that doesn't, THEN nearest along the move axis, then nearest cross. A plain
    // distance score (along + k*cross) lets a near-but-misaligned target win — e.g.
    // RIGHT from the headword would pick the definition text just below over the
    // ♪ on the same row far to the right. The beam keeps directional moves honest.
    var best = null;
    var bestBeam = -1; // 1 = inside the beam, 0 = outside
    var bestAlong = Infinity;
    var bestCross = Infinity;
    var horizontal = (physicalDir === 'left' || physicalDir === 'right');
    for (var i = 0; i < stops.length; i++) {
      var s = stops[i];
      if (s.el && this.el && s.el === this.el) continue;
      if (!s.el && this.node && s.node === this.node && s.offset === this.offset) continue;
      var dx = s.cx - acx, dy = s.cy - acy;
      var ovY = Math.min(a.bottom, s.rect.bottom) - Math.max(a.top, s.rect.top);
      var ovX = Math.min(a.right, s.rect.right) - Math.max(a.left, s.rect.left);
      // Up/Down must cross to a DIFFERENT row: a same-row control (e.g. the ♪
      // beside the headword, whose centre sits a hair above it) is reachable only
      // via Left/Right, so Up from the top row blocks and Dart escapes to the
      // Flutter header instead of hopping sideways.
      var sameRow = ovY > 0.5 * Math.min(a.height, s.rect.height);
      var ahead, along, cross, beam;
      if (physicalDir === 'up') {
        ahead = !sameRow && dy < -eps; along = -dy; cross = Math.abs(dx); beam = ovX > 0;
      } else if (physicalDir === 'down') {
        ahead = !sameRow && dy > eps; along = dy; cross = Math.abs(dx); beam = ovX > 0;
      } else if (physicalDir === 'left') {
        ahead = dx < -eps; along = -dx; cross = Math.abs(dy); beam = ovY > 0;
      } else { // right
        ahead = dx > eps; along = dx; cross = Math.abs(dy); beam = ovY > 0;
      }
      if (!ahead) continue;
      var beamN = beam ? 1 : 0;
      var better;
      if (best === null) better = true;
      else if (beamN !== bestBeam) better = beamN > bestBeam;
      else if (Math.abs(along - bestAlong) > eps) better = along < bestAlong;
      else better = cross < bestCross;
      if (better) { best = s; bestBeam = beamN; bestAlong = along; bestCross = cross; }
    }
    return best;
  },
  _physicalDir: function(dir, vertical, logical) {
    if (dir === 'up' || dir === 'down' || dir === 'left' || dir === 'right') return dir;
    // logical → physical for the current writing-mode
    if (logical === 'forward') return vertical ? 'down' : 'right';
    if (logical === 'backward') return vertical ? 'up' : 'left';
    if (logical === 'lineNext') return vertical ? 'left' : 'down';
    return vertical ? 'right' : 'up'; // linePrev
  },
  _firstVisibleStop: function() {
    var walker = this._walker();
    var node;
    while (node = walker.nextNode()) {
      var text = node.textContent;
      for (var i = 0; i < text.length;) {
        var len = this._charLen(text, i);
        if (this._isStop(node, i)) {
          var rect = this._charRect(node, i);
          if (this._inViewport(rect)) return { node: node, offset: i, rect: rect };
        }
        i += len;
      }
    }
    return null;
  },
  _lastVisibleStop: function() {
    var stops = this._collectVisibleStops();
    if (!stops.length) return null;
    var s = stops[stops.length - 1];
    return { node: s.node, offset: s.offset, el: s.el, rect: s.rect };
  },
  // First visible ELEMENT stop (e.g. a reader block illustration). Lets the
  // caret enter / re-anchor on a pure-image page where _firstVisibleStop (text
  // only) finds nothing. _lastVisibleStop already covers the backward edge.
  _firstVisibleElementStop: function() {
    var stops = this._collectVisibleStops();
    for (var i = 0; i < stops.length; i++) {
      if (stops[i].el) {
        var s = stops[i];
        return { node: s.node, offset: s.offset, el: s.el, rect: s.rect };
      }
    }
    return null;
  },

  // ── Geometric line move ────────────────────────────────────────────
  _lineMove: function(isNext, vertical) {
    var anchor = this._anchorRect();
    if (!anchor) return null;
    var acx = anchor.left + anchor.width / 2;
    var acy = anchor.top + anchor.height / 2;
    var stops = this._collectVisibleStops();
    var eps = 2;
    var best = null;
    var bestLine = null; // nearest line's primary coordinate
    var bestCross = Infinity;
    for (var i = 0; i < stops.length; i++) {
      var s = stops[i];
      var primary, cross, ahead, nearer;
      if (!vertical) {
        // lines stacked vertically; primary axis = y, cross axis = x. A line move
        // must cross to a different ROW: a stop overlapping the anchor's row by
        // >half the shorter height is the same line (e.g. a same-row icon) and is
        // not "ahead", so Up/Down skip it (it's a Left/Right neighbour).
        var ov = Math.min(anchor.bottom, s.rect.bottom) - Math.max(anchor.top, s.rect.top);
        var sameRow = ov > 0.5 * Math.min(anchor.height, s.rect.height);
        primary = s.cy; cross = Math.abs(s.cx - acx);
        ahead = !sameRow && (isNext ? (s.cy > acy + eps) : (s.cy < acy - eps));
        if (!ahead) continue;
        nearer = isNext ? (bestLine === null || primary < bestLine - eps)
                        : (bestLine === null || primary > bestLine + eps);
      } else {
        // columns stacked horizontally; primary axis = x, cross axis = y.
        // isNext (next column) advances leftwards in vertical-rl. Same-column
        // guard mirrors the horizontal case on the x axis.
        var ow = Math.min(anchor.right, s.rect.right) - Math.max(anchor.left, s.rect.left);
        var sameCol = ow > 0.5 * Math.min(anchor.width, s.rect.width);
        primary = s.cx; cross = Math.abs(s.cy - acy);
        ahead = !sameCol && (isNext ? (s.cx < acx - eps) : (s.cx > acx + eps));
        if (!ahead) continue;
        nearer = isNext ? (bestLine === null || primary > bestLine + eps)
                        : (bestLine === null || primary < bestLine - eps);
      }
      if (nearer) {
        bestLine = primary; best = s; bestCross = cross;
      } else if (Math.abs(primary - bestLine) <= eps && cross < bestCross) {
        best = s; bestCross = cross;
      }
    }
    return best || null;
  },

  // ── Page / scroll handling ─────────────────────────────────────────
  _offPage: function(target, forwardish) {
    if (this._paged()) {
      return { status: forwardish ? 'pageForward' : 'pageBackward' };
    }
    this._scrollIntoView(this._stopRect(target));
    var rect = this._stopRect(target);
    this._place({ node: target.node, offset: target.offset, el: target.el, rect: rect });
    return { status: 'moved', rect: this._rectJson(rect) };
  },
  _pageOrScroll: function(forwardish) {
    if (this._paged()) {
      return { status: forwardish ? 'pageForward' : 'pageBackward' };
    }
    this._scrollViewport(forwardish);
    var target = this._lineMove(forwardish, this._vertical());
    if (target) {
      var rect = this._stopRect(target);
      this._place({ node: target.node, offset: target.offset, el: target.el, rect: rect });
      return { status: 'moved', rect: this._rectJson(rect) };
    }
    return { status: 'blocked' };
  },
  _viewportSize: function() {
    return this._vertical() ? window.innerWidth : window.innerHeight;
  },
  _scrollIntoView: function(rect) {
    var vertical = this._vertical();
    var vp = this._viewport();
    var margin = 48;
    if (vertical) {
      if (rect.left < vp.left + margin) this._scrollWindowBy(rect.left - vp.left - margin, 0);
      else if (rect.right > vp.right - margin) this._scrollWindowBy(rect.right - vp.right + margin, 0);
    } else {
      if (rect.top < vp.top + margin) this._scrollWindowBy(0, rect.top - vp.top - margin);
      else if (rect.bottom > vp.bottom - margin) this._scrollWindowBy(0, rect.bottom - vp.bottom + margin);
    }
  },
  _scrollViewport: function(forwardish) {
    var dist = this._viewportSize() * 0.6;
    if (this._vertical()) {
      this._scrollWindowBy(forwardish ? -dist : dist, 0); // vertical-rl forward = left
    } else {
      this._scrollWindowBy(0, forwardish ? dist : -dist);
    }
  },
  _scrollWindowBy: function(dx, dy) {
    try {
      window.scrollBy({
        left: dx,
        top: dy,
        behavior: this.instantScroll ? 'instant' : 'auto'
      });
    } catch (e) {
      window.scrollBy(dx, dy);
    }
  },

  // ── Ring ───────────────────────────────────────────────────────────
  _ensureRing: function() {
    if (this._ring && this._ring.isConnected) return this._ring;
    var r = document.getElementById('hoshi-caret-ring');
    if (!r) {
      r = document.createElement('div');
      r.id = 'hoshi-caret-ring';
      r.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483646;' +
        'box-sizing:border-box;border-radius:3px;display:none;';
      document.documentElement.appendChild(r);
    }
    this._ring = r;
    this._applyRingStyle();
    return r;
  },
  _applyRingStyle: function() {
    if (!this._ring) return;
    var color = this.ringColor || 'rgba(255,138,0,0.98)';
    this._ring.style.border = '2px solid ' + color;
    this._ring.style.boxShadow = '0 0 0 2px rgba(0,0,0,0.28), 0 0 6px ' + color;
  },
  _drawRing: function(rect) {
    var r = this._ensureRing();
    var pad = 1;
    // Clamp the ring to the current viewport: a stop whose rect overflows the
    // host (e.g. a popup-edge element taller than the popup) must never paint a
    // ring outside it. _viewport() is the host client area (the whole popup,
    // since the popup passes zero insets; the reading viewport in the reader).
    var vp = this._viewport();
    var left = Math.max(rect.left - pad, vp.left);
    var top = Math.max(rect.top - pad, vp.top);
    var right = Math.min(rect.left + rect.width + pad, vp.right);
    var bottom = Math.min(rect.top + rect.height + pad, vp.bottom);
    r.style.display = 'block';
    r.style.left = left + 'px';
    r.style.top = top + 'px';
    r.style.width = Math.max(0, right - left) + 'px';
    r.style.height = Math.max(0, bottom - top) + 'px';
  },
  _hideRing: function() {
    if (this._ring) this._ring.style.display = 'none';
  },
  _rectJson: function(rect) {
    return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
  },
  _place: function(stop) {
    this.node = stop.node || null;
    this.offset = stop.offset || 0;
    this.el = stop.el || null;
    // Only text stops are remembered for restore-on-re-enter; an interactive
    // element stop is transient (the cursor returns to text on the next enter).
    if (!this.el) {
      this._memNode = this.node;
      this._memOffset = this.offset;
    }
    this._drawRing(stop.rect || this._stopRect(stop));
  },

  // ── Public API ─────────────────────────────────────────────────────
  isActive: function() { return !!this.active; },

  init: function(opts) {
    opts = opts || {};
    if (opts.color) this.ringColor = opts.color;
    if (opts.insetTop != null) this.insetTop = opts.insetTop;
    if (opts.insetBottom != null) this.insetBottom = opts.insetBottom;
    if (opts.scopeSelector !== undefined) this.scopeSelector = opts.scopeSelector;
    this._applyRingStyle();
    if (this.active) {
      var rect = this._anchorRect();
      if (rect && this._inViewport(rect)) this._drawRing(rect);
    }
    return true;
  },

  setInstantScroll: function(value) {
    this.instantScroll = !!value;
    return true;
  },

  enter: function() {
    this._ensureRing();
    this._markClickables();
    var pos = null;
    if (this._memNode && document.contains(this._memNode) && this._memOffset != null &&
        this._isStop(this._memNode, this._memOffset)) {
      var rr = this._charRect(this._memNode, this._memOffset);
      if (this._inViewport(rr)) pos = { node: this._memNode, offset: this._memOffset, rect: rr };
    }
    if (!pos) pos = this._firstVisibleStop();
    if (!pos) pos = this._firstVisibleElementStop(); // pure-illustration page
    if (!pos) { this.active = false; return { ok: false }; }
    this.active = true;
    this._place(pos);
    return { ok: true, rect: this._rectJson(pos.rect || this._stopRect(pos)) };
  },

  exit: function() {
    this.active = false;
    this._hideRing();
    return true;
  },

  // Suspend/resume hide and re-show the ring WITHOUT changing `active`, so the
  // caret keeps its position and ownership. Used when the user switches to the
  // mouse (ring vanishes) and back to keyboard/gamepad (ring returns) — unlike
  // exit(), this never drops the caret, so directional keys keep driving the
  // popup instead of falling through to the reader's page-turn.
  suspend: function() {
    this._hideRing();
    return true;
  },
  resume: function() {
    if (!this.active) return { ok: false };
    var r = this._anchorRect();
    if (r && this._inViewport(r)) {
      this._drawRing(r);
      return { ok: true, rect: this._rectJson(r) };
    }
    return this.refresh();
  },

  reanchor: function(edge) {
    this._ensureRing();
    this._markClickables();
    var pos = (edge === 'backward') ? this._lastVisibleStop() : this._firstVisibleStop();
    if (!pos) pos = this._firstVisibleElementStop(); // pure-illustration page
    if (!pos) return { ok: false }; // empty page — leave active state untouched
    this.active = true;
    this._place(pos);
    return { ok: true, rect: this._rectJson(pos.rect) };
  },

  move: function(dir) {
    if (!this.active || (!this.node && !this.el)) return { status: 'blocked' };
    this._markClickables();
    var detached = this.el ? !document.contains(this.el)
                           : !document.contains(this.node);
    if (detached) {
      var re = this.reanchor('forward');
      return re.ok ? { status: 'moved', rect: re.rect } : { status: 'blocked' };
    }
    var vertical = this._vertical();
    var logical = this._logicalDir(dir, vertical);
    var forwardish = (logical === 'forward' || logical === 'lineNext');
    var physical = this._physicalDir(dir, vertical, logical);
    var target = null;
    if (!window.hoshiReader) {
      // Dictionary popups are mixed DOM: text, links, buttons and disclosure
      // controls share one visual plane. Directional input must therefore use
      // physical geometry for every stop, including plain text.
      target = this._geomMove(physical);
    } else if (this.el) {
      // No text offset to step from an element stop — every move is geometric:
      // jump to the nearest stop (text or element) in the physical direction.
      target = this._geomMove(physical);
    } else if (logical === 'forward') {
      target = this._nextStop(this.node, this.offset);
    } else if (logical === 'backward') {
      target = this._prevStop(this.node, this.offset);
    } else {
      target = this._lineMove(logical === 'lineNext', vertical);
    }
    if (!target) {
      // Left/Right off the end of an element stop's row has nowhere to go:
      // block, rather than scroll the view and jump to another line (which made
      // the cursor "fly off" to an off-screen stop after +). Popup-only: the
      // reader's element stops (block images) are reached by Up/Down line moves,
      // and its Left/Right is reading-order text stepping handled just below;
      // Up/Down here still scroll for more rows.
      if (!window.hoshiReader && (physical === 'left' || physical === 'right')) {
        return { status: 'blocked' };
      }
      if (!this.el && (logical === 'forward' || logical === 'backward')) {
        return { status: 'blocked' };
      }
      return this._pageOrScroll(forwardish); // line move ran out on this page
    }
    var rect = this._stopRect(target);
    if (this._inViewport(rect)) {
      // _inViewport is an intersection test, so a stop near the popup edge can be
      // half-clipped yet "visible". Scroll it fully into view (follow focus) and
      // re-measure, so the view tracks the cursor instead of leaving the ring
      // pinned at the edge. Popup-only (continuous scroll); the paged reader
      // turns pages via _offPage and isn't touched.
      if (!window.hoshiReader) {
        this._scrollIntoView(rect);
        rect = this._stopRect(target);
      }
      this._place({ node: target.node, offset: target.offset, el: target.el, rect: rect });
      return { status: 'moved', rect: this._rectJson(rect) };
    }
    return this._offPage(target, forwardish);
  },
  // ── Page flip (LB/RB) ──────────────────────────────────────────────
  // Whole-page accelerator: in the popup it scrolls one viewport fraction and
  // re-anchors the ring to the next line so the cursor follows the view; in the
  // paged reader it returns a page-turn status for Dart to action. Reuses the
  // exact primitive a line move uses when it runs off the page edge
  // (_pageOrScroll), so page-flip and edge-scroll semantics never diverge.
  scrollPage: function(forwardish) {
    if (!this.active) return { status: 'blocked' };
    return this._pageOrScroll(!!forwardish);
  },

  // ── Jump to dictionary section (Yomitan-style "go to dictionary") ──────
  // Step the caret to the next/previous dictionary section header
  // (summary.dict-label) so a pure gamepad/keyboard user can skip whole
  // dictionaries at once instead of D-padding through every line. Forward
  // jumps to the first dict header whose top is below the current anchor;
  // backward to the last header whose top is above it (DOM order ties broken by
  // position, so jumping is deterministic even with multiple stacked sections).
  // The header is placed as an element stop (the same machinery move() uses for
  // an interactive stop), so the ring hugs the dict-label and A toggles the
  // section open/closed exactly as it does after a D-pad landing. Reader-only
  // surfaces have no summary.dict-label → blocked (no-op). The chosen header is
  // scrolled fully into view so the cursor follows the jump.
  _dictHeaders: function() {
    var out = [];
    var nodes = document.body.querySelectorAll('summary.dict-label');
    for (var i = 0; i < nodes.length; i++) {
      var r = this._elRect(nodes[i]);
      if (r.width <= 0 || r.height <= 0) continue;
      out.push({ el: nodes[i], top: r.top, rect: r });
    }
    // DOM order already follows visual order top→bottom; sort by top as a guard
    // for any reflow/transform that reorders rects.
    out.sort(function(a, b) { return a.top - b.top; });
    return out;
  },
  jumpDict: function(forward) {
    if (!this.active) return { status: 'blocked' };
    this._markClickables();
    var headers = this._dictHeaders();
    if (!headers.length) return { status: 'blocked' };
    var anchor = this._anchorRect();
    // No anchor yet (just entered an empty-text page): jump to the first/last.
    var refTop = anchor ? (anchor.top + anchor.height / 2) : -Infinity;
    var eps = 2;
    var target = null;
    if (forward) {
      for (var i = 0; i < headers.length; i++) {
        if (headers[i].top > refTop + eps) { target = headers[i]; break; }
      }
    } else {
      for (var j = headers.length - 1; j >= 0; j--) {
        if (headers[j].top < refTop - eps) { target = headers[j]; break; }
      }
    }
    if (!target) return { status: 'blocked' };
    // The header may sit off the current scroll position; scroll it in and
    // re-measure before placing, so the ring lands on the visible header.
    this._scrollIntoView(target.rect);
    var rect = this._elRect(target.el);
    this._place({ node: null, offset: 0, el: target.el, rect: rect });
    return { status: 'moved', rect: this._rectJson(rect) };
  },

  refresh: function() {
    if (!this.active) return { ok: false };
    this._markClickables();
    if (this.el && document.contains(this.el)) {
      var er = this._elRect(this.el);
      if (this._inViewport(er)) { this._drawRing(er); return { ok: true, rect: this._rectJson(er) }; }
    } else if (this.node && document.contains(this.node) && this._isStop(this.node, this.offset)) {
      var rect = this._charRect(this.node, this.offset);
      if (this._inViewport(rect)) { this._drawRing(rect); return { ok: true, rect: this._rectJson(rect) }; }
    }
    var pos = this._firstVisibleStop();
    if (!pos) { this._hideRing(); return { ok: false }; }
    this._place(pos);
    return { ok: true, rect: this._rectJson(pos.rect) };
  },

  lookup: function() {
    if (!this.active || !this.node) return false;
    var s = window.hoshiSelection;
    if (!s || typeof s.selectFromPosition !== 'function') return false;
    s.clearSelection();
    var text = s.selectFromPosition(this.node, this.offset, 400);
    return !!text;
  },

  // Context "click" at the caret, like a mouse click / Enter on whatever the
  // cursor sits on:
  //  - a hyperlink is followed (a.click() → the host WebView's URL routing: the
  //    reader's shouldOverrideUrlLoading, or the popup's cross-reference handler);
  //  - an interactive control is clicked (popup buttons / collapse / audio etc.);
  //  - plain text (words, kanji) is looked up directly via the selection
  //    pipeline. Looking up directly — rather than synthesising a tap — avoids
  //    the reader tap handler toggling the (hidden) chrome instead of looking up.
  activate: function() {
    if (!this.active) return 'none';
    this._markClickables();
    // On an interactive element stop, click it directly.
    if (this.el && document.contains(this.el)) {
      // Reader block images have no DOM click→lightbox listener (the reader opens
      // images from the pointer-gesture path, not a synthesised click), so call
      // the same onImageTap handler that path uses instead of a no-op el.click().
      if (window.hoshiReader && this.el.tagName === 'IMG' && this.el.src) {
        // TODO-861④：键盘/手柄激活仍带 `blurred` 类的防剧透图时，先揭开（移除类）
        // 而非放大；揭开后再次激活才走 onImageTap 放大（与指针点击语义一致）。
        if (this.el.classList && this.el.classList.contains('blurred')) {
          this.el.classList.remove('blurred');
          return 'activated';
        }
        window.flutter_inappwebview.callHandler('onImageTap', this.el.src);
        return 'activated';
      }
      var asLink = this.el.matches('a[href]') || !!this.el.closest('a[href]');
      this.el.click();
      return asLink ? 'link' : 'activated';
    }
    if (!this.node) return 'none';
    var el = this.node.parentElement;
    var link = el && el.closest('a[href]');
    if (link) { link.click(); return 'link'; }
    // Any clickable ancestor (control, onclick, or pointer-cursor collapsible).
    var control = el && el.closest('[data-hoshi-clk]');
    if (control) { control.click(); return 'activated'; }
    return this.lookup() ? 'lookup' : 'none';
  },

  longPress: function() {
    if (!this.active) return 'none';
    this._markClickables();
    var target = null;
    if (this.el && document.contains(this.el)) {
      target = this.el;
    } else if (this.node && document.contains(this.node)) {
      target = this.node.parentElement;
    }
    if (!target) return 'none';

    var summary = target.closest && target.closest('summary.dict-label');
    if (summary && typeof window.__hoshiDictLongPress === 'function') {
      window.__hoshiDictLongPress(summary);
      return 'dict';
    }

    if (!this.el && this.node) {
      return this.lookup() ? 'lookup' : 'none';
    }

    var rect = target.getBoundingClientRect ? target.getBoundingClientRect() : null;
    if (rect) {
      var ev = new MouseEvent('contextmenu', {
        bubbles: true,
        cancelable: true,
        view: window,
        clientX: rect.left + rect.width / 2,
        clientY: rect.top + rect.height / 2
      });
      target.dispatchEvent(ev);
      return 'contextmenu';
    }
    return 'none';
  }
};
""";
}
