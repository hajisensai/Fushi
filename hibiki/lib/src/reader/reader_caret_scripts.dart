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

  /// Move the caret. [dir] is a physical direction (`up`/`down`/`left`/`right`)
  /// or a logical one (`forward`/`backward`/`lineNext`/`linePrev`). Returns
  /// `{status, rect}` where status ∈ moved | pageForward | pageBackward |
  /// blocked.
  static String moveInvocation(String dir) =>
      "JSON.stringify(window.hoshiCaret.move('$dir'))";

  /// After a page turn, place the caret at the entering edge of the new page
  /// ([edge] = `forward` → first visible char, `backward` → last visible char).
  static String reanchorInvocation(String edge) =>
      "JSON.stringify(window.hoshiCaret.reanchor('$edge'))";

  /// Look up the word at the caret (reuses the tap dictionary pipeline).
  static String lookupInvocation() => 'window.hoshiCaret.lookup()';

  /// Re-measure the ring after a relayout; re-anchors if the node detached.
  static String refreshInvocation() =>
      'JSON.stringify(window.hoshiCaret.refresh())';

  /// Configure the ring colour and the chrome insets used for the
  /// "is on the current page" viewport test.
  static String initInvocation({
    required String color,
    required double insetTop,
    required double insetBottom,
  }) =>
      "window.hoshiCaret.init({color:'$color',insetTop:$insetTop,"
      'insetBottom:$insetBottom})';

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
    return Rect.fromLTWH(x.toDouble(), y.toDouble(), w.toDouble(), h.toDouble());
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
  insetTop: 0,
  insetBottom: 0,
  ringColor: 'rgba(255,138,0,0.98)',
  _ring: null,
  _memNode: null,
  _memOffset: null,

  // ── Mode / writing-mode ────────────────────────────────────────────
  _vertical: function() {
    if (window.hoshiReader && typeof window.hoshiReader.isVertical === 'function') {
      return window.hoshiReader.isVertical();
    }
    return (window.getComputedStyle(document.body).writingMode || '').indexOf('vertical') === 0;
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
  _collectVisibleStops: function() {
    var walker = this._walker();
    var out = [];
    var node;
    while (node = walker.nextNode()) {
      var text = node.textContent;
      for (var i = 0; i < text.length;) {
        var len = this._charLen(text, i);
        if (this._isStop(node, i)) {
          var rect = this._charRect(node, i);
          if (this._inViewport(rect)) {
            out.push({
              node: node, offset: i, rect: rect,
              cx: rect.left + rect.width / 2,
              cy: rect.top + rect.height / 2
            });
          }
        }
        i += len;
      }
    }
    return out;
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
    return { node: s.node, offset: s.offset, rect: s.rect };
  },

  // ── Geometric line move ────────────────────────────────────────────
  _lineMove: function(isNext, vertical) {
    var anchor = this._charRect(this.node, this.offset);
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
        // lines stacked vertically; primary axis = y, cross axis = x
        primary = s.cy; cross = Math.abs(s.cx - acx);
        ahead = isNext ? (s.cy > acy + eps) : (s.cy < acy - eps);
        if (!ahead) continue;
        nearer = isNext ? (bestLine === null || primary < bestLine - eps)
                        : (bestLine === null || primary > bestLine + eps);
      } else {
        // columns stacked horizontally; primary axis = x, cross axis = y.
        // isNext (next column) advances leftwards in vertical-rl.
        primary = s.cx; cross = Math.abs(s.cy - acy);
        ahead = isNext ? (s.cx < acx - eps) : (s.cx > acx + eps);
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
    return best ? { node: best.node, offset: best.offset } : null;
  },

  // ── Page / scroll handling ─────────────────────────────────────────
  _offPage: function(target, forwardish) {
    if (this._paged()) {
      return { status: forwardish ? 'pageForward' : 'pageBackward' };
    }
    this._scrollIntoView(this._charRect(target.node, target.offset));
    var rect = this._charRect(target.node, target.offset);
    this._place(target.node, target.offset, rect);
    return { status: 'moved', rect: this._rectJson(rect) };
  },
  _pageOrScroll: function(forwardish) {
    if (this._paged()) {
      return { status: forwardish ? 'pageForward' : 'pageBackward' };
    }
    this._scrollViewport(forwardish);
    var target = this._lineMove(forwardish, this._vertical());
    if (target) {
      var rect = this._charRect(target.node, target.offset);
      this._place(target.node, target.offset, rect);
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
      if (rect.left < vp.left + margin) window.scrollBy(rect.left - vp.left - margin, 0);
      else if (rect.right > vp.right - margin) window.scrollBy(rect.right - vp.right + margin, 0);
    } else {
      if (rect.top < vp.top + margin) window.scrollBy(0, rect.top - vp.top - margin);
      else if (rect.bottom > vp.bottom - margin) window.scrollBy(0, rect.bottom - vp.bottom + margin);
    }
  },
  _scrollViewport: function(forwardish) {
    var dist = this._viewportSize() * 0.6;
    if (this._vertical()) {
      window.scrollBy(forwardish ? -dist : dist, 0); // vertical-rl forward = left
    } else {
      window.scrollBy(0, forwardish ? dist : -dist);
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
    r.style.display = 'block';
    r.style.left = (rect.left - pad) + 'px';
    r.style.top = (rect.top - pad) + 'px';
    r.style.width = (rect.width + pad * 2) + 'px';
    r.style.height = (rect.height + pad * 2) + 'px';
  },
  _hideRing: function() {
    if (this._ring) this._ring.style.display = 'none';
  },
  _rectJson: function(rect) {
    return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
  },
  _place: function(node, offset, rect) {
    this.node = node;
    this.offset = offset;
    this._memNode = node;
    this._memOffset = offset;
    this._drawRing(rect || this._charRect(node, offset));
  },

  // ── Public API ─────────────────────────────────────────────────────
  isActive: function() { return !!this.active; },

  init: function(opts) {
    opts = opts || {};
    if (opts.color) this.ringColor = opts.color;
    if (opts.insetTop != null) this.insetTop = opts.insetTop;
    if (opts.insetBottom != null) this.insetBottom = opts.insetBottom;
    this._applyRingStyle();
    if (this.active && this.node && document.contains(this.node)) {
      var rect = this._charRect(this.node, this.offset);
      if (this._inViewport(rect)) this._drawRing(rect);
    }
    return true;
  },

  enter: function() {
    this._ensureRing();
    var pos = null;
    if (this._memNode && document.contains(this._memNode) && this._memOffset != null &&
        this._isStop(this._memNode, this._memOffset)) {
      var rr = this._charRect(this._memNode, this._memOffset);
      if (this._inViewport(rr)) pos = { node: this._memNode, offset: this._memOffset, rect: rr };
    }
    if (!pos) pos = this._firstVisibleStop();
    if (!pos) { this.active = false; return { ok: false }; }
    this.active = true;
    this._place(pos.node, pos.offset, pos.rect);
    return { ok: true, rect: this._rectJson(pos.rect || this._charRect(pos.node, pos.offset)) };
  },

  exit: function() {
    this.active = false;
    this._hideRing();
    return true;
  },

  reanchor: function(edge) {
    this.active = true;
    this._ensureRing();
    var pos = (edge === 'backward') ? this._lastVisibleStop() : this._firstVisibleStop();
    if (!pos) return { ok: false };
    this._place(pos.node, pos.offset, pos.rect);
    return { ok: true, rect: this._rectJson(pos.rect) };
  },

  move: function(dir) {
    if (!this.active || !this.node) return { status: 'blocked' };
    if (!document.contains(this.node)) {
      var re = this.reanchor('forward');
      return re.ok ? { status: 'moved', rect: re.rect } : { status: 'blocked' };
    }
    var vertical = this._vertical();
    var logical = this._logicalDir(dir, vertical);
    var forwardish = (logical === 'forward' || logical === 'lineNext');
    var target = null;
    if (logical === 'forward') target = this._nextStop(this.node, this.offset);
    else if (logical === 'backward') target = this._prevStop(this.node, this.offset);
    else target = this._lineMove(logical === 'lineNext', vertical);
    if (!target) {
      if (logical === 'forward' || logical === 'backward') return { status: 'blocked' };
      return this._pageOrScroll(forwardish); // line move ran out on this page
    }
    var rect = this._charRect(target.node, target.offset);
    if (this._inViewport(rect)) {
      this._place(target.node, target.offset, rect);
      return { status: 'moved', rect: this._rectJson(rect) };
    }
    return this._offPage(target, forwardish);
  },

  refresh: function() {
    if (!this.active) return { ok: false };
    if (this.node && document.contains(this.node) && this._isStop(this.node, this.offset)) {
      var rect = this._charRect(this.node, this.offset);
      if (this._inViewport(rect)) { this._drawRing(rect); return { ok: true, rect: this._rectJson(rect) }; }
    }
    var pos = this._firstVisibleStop();
    if (!pos) { this._hideRing(); return { ok: false }; }
    this._place(pos.node, pos.offset, pos.rect);
    return { ok: true, rect: this._rectJson(pos.rect) };
  },

  lookup: function() {
    if (!this.active || !this.node) return false;
    var s = window.hoshiSelection;
    if (!s || typeof s.selectFromPosition !== 'function') return false;
    s.clearSelection();
    var text = s.selectFromPosition(this.node, this.offset, 400);
    return !!text;
  }
};
""";
}
