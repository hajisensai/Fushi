/// JavaScript "line caret" for the audiobook **lyrics mode** (`LyricsModeHtml`).
///
/// Lyrics mode is a separate, continuously-scrolled document whose lines are the
/// discrete `.cue` divs. Unlike the paginated reader's [ReaderCaretScripts]
/// (which walks every glyph in the whole DOM and forces a layout per character —
/// far too heavy for a whole-book lyrics document), this caret keeps its stops
/// inside the **current cue** only: Up/Down hop between cue rows by
/// `data-cue-index` (reusing the document's own `__lyricsScrollToCue` to centre
/// the row), Left/Right step character-by-character within the focused cue. Word
/// lookup reuses `window.hoshiSelection.selectFromPosition`, so a caret lookup
/// hits the exact same dictionary pipeline as a tap, with `__lyricsCueContext`
/// set so the favourite/sentence metadata matches the click path.
///
/// Status payloads ({status, rect} / {ok, rect}) are parsed by the generic
/// [ReaderCaretScripts.moveStatus] / [ReaderCaretScripts.rectOf] on the Dart side.
class ReaderLyricsCaretScripts {
  ReaderLyricsCaretScripts._();

  /// Activate the caret on the current playing cue. Returns `{ok, rect}`.
  static String enterInvocation() =>
      'JSON.stringify(window.hoshiLyricsCaret.enter())';

  /// Deactivate the caret and hide the ring.
  static String exitInvocation() => 'window.hoshiLyricsCaret.exit()';

  /// Hide the ring but keep the caret active (mouse switch); [resumeInvocation]
  /// re-shows it for keyboard/gamepad.
  static String suspendInvocation() => 'window.hoshiLyricsCaret.suspend()';
  static String resumeInvocation() =>
      'JSON.stringify(window.hoshiLyricsCaret.resume())';

  /// Move the caret. `up`/`down` hop cue rows; `left`/`right` (and logical
  /// `forward`/`backward`) step characters within the focused cue. Returns
  /// `{status, rect}` with status ∈ moved | blocked.
  static String moveInvocation(String dir) =>
      "JSON.stringify(window.hoshiLyricsCaret.move('$dir'))";

  /// Whole-page accelerator (LB/RB): jump several cue rows. Same `{status, rect}`
  /// shape as [moveInvocation] (moved/blocked).
  static String scrollPageInvocation(bool forward) =>
      'JSON.stringify(window.hoshiLyricsCaret.scrollPage($forward))';

  /// Re-measure the ring after a relayout; re-anchors to the current cue if the
  /// node detached.
  static String refreshInvocation() =>
      'JSON.stringify(window.hoshiLyricsCaret.refresh())';

  /// Look up the word at the caret (reuses the tap dictionary pipeline).
  static String lookupInvocation() => 'window.hoshiLyricsCaret.lookup()';

  /// A/Enter at the caret — lyrics rows are plain text, so this looks up the word.
  static String activateInvocation() => 'window.hoshiLyricsCaret.activate()';

  /// Gamepad hold-A at the caret — also a lookup in lyrics mode.
  static String longPressInvocation() => 'window.hoshiLyricsCaret.longPress()';

  /// Configure the ring colour and viewport insets.
  static String initInvocation({
    required String color,
    required double insetTop,
    required double insetBottom,
  }) =>
      "window.hoshiLyricsCaret.init({color:'$color',insetTop:$insetTop,"
      'insetBottom:$insetBottom})';

  static String source() => r"""
window.hoshiLyricsCaret = {
  active: false,
  cueIndex: -1,
  node: null,
  offset: 0,
  ringColor: 'rgba(255,138,0,0.98)',
  insetTop: 0,
  insetBottom: 0,
  _ring: null,

  init: function(opts) {
    opts = opts || {};
    if (opts.color) this.ringColor = opts.color;
    if (opts.insetTop != null) this.insetTop = opts.insetTop;
    if (opts.insetBottom != null) this.insetBottom = opts.insetBottom;
    this._applyRingStyle();
    if (this.active) {
      var r = this._anchorRect();
      if (r) this._drawRing(r);
    }
    return true;
  },

  _cues: function() { return document.querySelectorAll('.cue'); },
  _walker: function(root) {
    if (window.hoshiSelection && typeof window.hoshiSelection.createWalker === 'function') {
      return window.hoshiSelection.createWalker(root);
    }
    return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
  },
  _charLen: function(text, i) {
    var cp = text.codePointAt(i);
    return (cp !== undefined && cp > 0xFFFF) ? 2 : 1;
  },
  _prevIndex: function(text, i) {
    if (i <= 0) return -1;
    var j = i - 1;
    if (j > 0) {
      var c = text.charCodeAt(j);
      if (c >= 0xDC00 && c <= 0xDFFF) j -= 1;
    }
    return j;
  },
  _isStop: function(node, offset) {
    var text = node.textContent;
    if (offset < 0 || offset >= text.length) return false;
    if (/^[\s　]$/.test(text[offset])) return false;
    return true;
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
  _firstStopInCue: function(cueEl) {
    if (!cueEl) return null;
    var walker = this._walker(cueEl);
    var node;
    while (node = walker.nextNode()) {
      var text = node.textContent;
      for (var i = 0; i < text.length;) {
        if (this._isStop(node, i)) return { node: node, offset: i };
        i += this._charLen(text, i);
      }
    }
    return null;
  },
  _stepInCue: function(forward) {
    var cueEl = this._cues()[this.cueIndex];
    if (!cueEl || !this.node) return null;
    var walker = this._walker(cueEl);
    walker.currentNode = this.node;
    var node = this.node, text = node.textContent, i;
    if (forward) {
      i = this.offset + this._charLen(text, this.offset);
      while (true) {
        while (i < text.length) {
          if (this._isStop(node, i)) return { node: node, offset: i };
          i += this._charLen(text, i);
        }
        var n = walker.nextNode();
        if (!n) return null;
        node = n; text = node.textContent; i = 0;
      }
    } else {
      i = this._prevIndex(text, this.offset);
      while (true) {
        while (i >= 0) {
          if (this._isStop(node, i)) return { node: node, offset: i };
          i = this._prevIndex(text, i);
        }
        var p = walker.previousNode();
        if (!p) return null;
        node = p; text = node.textContent; i = this._prevIndex(text, text.length);
      }
    }
  },

  _applyRingStyle: function() {
    if (!this._ring) return;
    var color = this.ringColor || 'rgba(255,138,0,0.98)';
    this._ring.style.border = '2px solid ' + color;
    this._ring.style.boxShadow = '0 0 0 2px rgba(0,0,0,0.28), 0 0 6px ' + color;
  },
  _ensureRing: function() {
    if (this._ring && this._ring.isConnected) return this._ring;
    var r = document.getElementById('hoshi-lyrics-caret-ring');
    if (!r) {
      r = document.createElement('div');
      r.id = 'hoshi-lyrics-caret-ring';
      r.style.cssText = 'position:fixed;pointer-events:none;z-index:2147483646;' +
        'box-sizing:border-box;border-radius:3px;display:none;';
      document.documentElement.appendChild(r);
    }
    this._ring = r;
    this._applyRingStyle();
    return r;
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
  _hideRing: function() { if (this._ring) this._ring.style.display = 'none'; },
  _rectJson: function(rect) {
    return { x: rect.left, y: rect.top, width: rect.width, height: rect.height };
  },
  _anchorRect: function() {
    if (this.node && document.contains(this.node)) return this._charRect(this.node, this.offset);
    return null;
  },
  _place: function(stop) {
    this.node = stop.node; this.offset = stop.offset;
    var rect = stop.rect || this._charRect(stop.node, stop.offset);
    this._drawRing(rect);
    return rect;
  },

  isActive: function() { return !!this.active; },

  enter: function() {
    this._ensureRing();
    var cues = this._cues();
    if (!cues.length) { this.active = false; return { ok: false }; }
    var idx = -1;
    if (typeof window.__lyricsGetCurrentIndex === 'function') {
      idx = window.__lyricsGetCurrentIndex();
    }
    if (idx < 0 || idx >= cues.length) idx = 0;
    var pos = this._firstStopInCue(cues[idx]);
    while (!pos && idx < cues.length - 1) { idx++; pos = this._firstStopInCue(cues[idx]); }
    if (!pos) { this.active = false; return { ok: false }; }
    this.active = true;
    this.cueIndex = idx;
    var rect = this._place(pos);
    return { ok: true, rect: this._rectJson(rect) };
  },

  exit: function() { this.active = false; this._hideRing(); return true; },
  suspend: function() { this._hideRing(); return true; },
  resume: function() {
    if (!this.active) return { ok: false };
    var r = this._anchorRect();
    if (r) { this._drawRing(r); return { ok: true, rect: this._rectJson(r) }; }
    return this.refresh();
  },

  _lineMove: function(forward) {
    var cues = this._cues();
    var next = forward ? this.cueIndex + 1 : this.cueIndex - 1;
    var pos = null;
    while (next >= 0 && next < cues.length) {
      pos = this._firstStopInCue(cues[next]);
      if (pos) break;
      next = forward ? next + 1 : next - 1;
    }
    if (!pos) return { status: 'blocked' };
    this.cueIndex = next;
    if (typeof window.__lyricsScrollToCue === 'function') window.__lyricsScrollToCue(next);
    var rect = this._place(pos);
    return { status: 'moved', rect: this._rectJson(rect) };
  },

  move: function(dir) {
    if (!this.active || !this.node) return { status: 'blocked' };
    if (!document.contains(this.node)) {
      var re = this.refresh();
      if (!re.ok) return { status: 'blocked' };
    }
    if (dir === 'up') return this._lineMove(false);
    if (dir === 'down') return this._lineMove(true);
    var forward = (dir === 'right' || dir === 'forward');
    var target = this._stepInCue(forward);
    if (!target) return { status: 'blocked' };
    var rect = this._place(target);
    return { status: 'moved', rect: this._rectJson(rect) };
  },

  scrollPage: function(forward) {
    if (!this.active) return { status: 'blocked' };
    var cues = this._cues();
    var STEP = 5;
    var target = forward ? Math.min(cues.length - 1, this.cueIndex + STEP)
                         : Math.max(0, this.cueIndex - STEP);
    var pos = this._firstStopInCue(cues[target]);
    while (!pos && target > 0 && target < cues.length - 1) {
      target = forward ? target + 1 : target - 1;
      pos = this._firstStopInCue(cues[target]);
    }
    if (!pos) return { status: 'blocked' };
    this.cueIndex = target;
    if (typeof window.__lyricsScrollToCue === 'function') window.__lyricsScrollToCue(target);
    var rect = this._place(pos);
    return { status: 'moved', rect: this._rectJson(rect) };
  },

  refresh: function() {
    if (!this.active) return { ok: false };
    if (this.node && document.contains(this.node) && this._isStop(this.node, this.offset)) {
      var rect = this._charRect(this.node, this.offset);
      this._drawRing(rect);
      return { ok: true, rect: this._rectJson(rect) };
    }
    var cues = this._cues();
    var pos = (this.cueIndex >= 0 && this.cueIndex < cues.length)
      ? this._firstStopInCue(cues[this.cueIndex]) : null;
    if (!pos) { this._hideRing(); return { ok: false }; }
    var r = this._place(pos);
    return { ok: true, rect: this._rectJson(r) };
  },

  _setCueContext: function() {
    var cueEl = this._cues()[this.cueIndex];
    if (cueEl) {
      window.__lyricsCueContext = {
        textFragmentId: cueEl.getAttribute('data-text-fragment-id'),
        cueIndex: parseInt(cueEl.getAttribute('data-cue-index'), 10)
      };
    } else {
      window.__lyricsCueContext = null;
    }
  },
  lookup: function() {
    if (!this.active || !this.node) return false;
    var s = window.hoshiSelection;
    if (!s || typeof s.selectFromPosition !== 'function') return false;
    this._setCueContext();
    if (typeof s.clearSelection === 'function') s.clearSelection();
    var text = s.selectFromPosition(this.node, this.offset, 400);
    return !!text;
  },
  activate: function() { return this.lookup() ? 'lookup' : 'none'; },
  longPress: function() { return this.lookup() ? 'lookup' : 'none'; }
};
""";
}
