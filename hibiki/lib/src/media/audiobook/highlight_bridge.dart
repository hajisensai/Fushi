import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

class HighlightBridge {
  HighlightBridge._();

  // language=javascript
  static const String _js = '''
(function() {
  if (window.__hibikiHighlightsInstalled) return;
  window.__hibikiHighlightsInstalled = true;
  window.__hoshiCssHighlightsSupported = !!(window.CSS && CSS.highlights && window.Highlight);

  var BASE_COLORS = {
    yellow: [255,220,0],
    green:  [0,200,83],
    blue:   [68,138,255],
    pink:   [255,64,129],
    purple: [170,0,255]
  };
  var MARK_COLORS = {
    yellow: [184,132,0],
    green:  [0,126,54],
    blue:   [36,92,190],
    pink:   [196,38,92],
    purple: [126,0,190]
  };
  var MARK_VAR_NAMES = {
    yellow: '--hoshi-hl-yellow-mark',
    green:  '--hoshi-hl-green-mark',
    blue:   '--hoshi-hl-blue-mark',
    pink:   '--hoshi-hl-pink-mark',
    purple: '--hoshi-hl-purple-mark'
  };
  window.__hibikiHighlightBg = '#ffffff';
  window.__hibikiCustomHighlightColor = null;
  window.__hibikiHighlightRangeMap = {};
  window.__hibikiHighlightRubyElements = [];
  window.__hibikiFallbackHighlightRubyMap = {};

  function _luminance(hex) {
    var h = hex.replace('#','');
    if (h.length === 3) h = h[0]+h[0]+h[1]+h[1]+h[2]+h[2];
    var r = parseInt(h.substr(0,2),16)/255;
    var g = parseInt(h.substr(2,2),16)/255;
    var b = parseInt(h.substr(4,2),16)/255;
    return 0.2126*r + 0.7152*g + 0.0722*b;
  }

  function _pickAlpha(colorName, bgLum) {
    var dark = bgLum < 0.4;
    var alphas = {
      yellow: dark ? 0.45 : 0.35,
      green:  dark ? 0.40 : 0.30,
      blue:   dark ? 0.40 : 0.30,
      pink:   dark ? 0.40 : 0.30,
      purple: dark ? 0.40 : 0.25
    };
    return alphas[colorName] || (dark ? 0.40 : 0.30);
  }

  function _hlColor(name) {
    if (window.__hibikiCustomHighlightColor) return window.__hibikiCustomHighlightColor;
    var rgb = BASE_COLORS[name] || BASE_COLORS.yellow;
    var a = _pickAlpha(name, _luminance(window.__hibikiHighlightBg));
    return 'rgba('+rgb[0]+','+rgb[1]+','+rgb[2]+','+a+')';
  }

  function _hlMarkColor(name) {
    if (window.__hibikiCustomHighlightColor) return window.__hibikiCustomHighlightColor;
    var rgb = MARK_COLORS[name] || MARK_COLORS.yellow;
    return 'rgb('+rgb[0]+','+rgb[1]+','+rgb[2]+')';
  }

  function _root() {
    return document.body;
  }

  function _syncHighlightVars() {
    var root = document.documentElement;
    for (var ci = 0; ci < ALL_COLORS.length; ci++) {
      var cn = ALL_COLORS[ci];
      root.style.setProperty('--hoshi-hl-' + cn, _hlColor(cn));
      root.style.setProperty(MARK_VAR_NAMES[cn], _hlMarkColor(cn));
    }
  }

  function _rubyForNode(node) {
    var el = node && node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return el && el.closest ? el.closest('ruby') : null;
  }

  function _removeFavoriteRubyClasses(ruby) {
    if (!ruby || !ruby.classList) return;
    for (var i = 0; i < ALL_COLORS.length; i++) {
      ruby.classList.remove('hoshi-hl-' + ALL_COLORS[i] + '-ruby-active');
    }
  }

  function _addRubyHighlightClass(ruby, color, bucket) {
    if (!ruby || !ruby.classList) return;
    color = color || 'yellow';
    ruby.classList.add('hoshi-hl-' + color + '-ruby-active');
    if (bucket && bucket.indexOf(ruby) < 0) bucket.push(ruby);
  }

  function _clearCssRubyHighlights() {
    var elements = window.__hibikiHighlightRubyElements || [];
    for (var i = 0; i < elements.length; i++) {
      _removeFavoriteRubyClasses(elements[i]);
    }
    window.__hibikiHighlightRubyElements = [];
  }

  function _clearFallbackRubyHighlights() {
    var map = window.__hibikiFallbackHighlightRubyMap || {};
    for (var id in map) {
      if (!Object.prototype.hasOwnProperty.call(map, id)) continue;
      var elements = map[id].elements || [];
      for (var i = 0; i < elements.length; i++) {
        _removeFavoriteRubyClasses(elements[i]);
      }
    }
    window.__hibikiFallbackHighlightRubyMap = {};
  }

  function _reapplyFallbackRubyHighlights() {
    var map = window.__hibikiFallbackHighlightRubyMap || {};
    var touched = [];
    for (var id in map) {
      if (!Object.prototype.hasOwnProperty.call(map, id)) continue;
      var elements = map[id].elements || [];
      for (var i = 0; i < elements.length; i++) {
        if (touched.indexOf(elements[i]) < 0) {
          _removeFavoriteRubyClasses(elements[i]);
          touched.push(elements[i]);
        }
      }
    }
    for (var id2 in map) {
      if (!Object.prototype.hasOwnProperty.call(map, id2)) continue;
      var entry = map[id2];
      var color = entry.color || 'yellow';
      var rubyElements = entry.elements || [];
      for (var j = 0; j < rubyElements.length; j++) {
        _addRubyHighlightClass(rubyElements[j], color);
      }
    }
  }

  function _walker(root) {
    return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function(n) {
        var p = n.parentNode;
        while (p && p !== root) {
          var tag = (p.nodeName || '').toLowerCase();
          if (tag === 'rt' || tag === 'rp') return NodeFilter.FILTER_REJECT;
          p = p.parentNode;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
  }

  function _skip(c) {
    if (typeof __hoshiIsSkippable === 'function') return __hoshiIsSkippable(c);
    if (window.hoshiReader && window.hoshiReader.isMatchableChar) {
      return !window.hoshiReader.isMatchableChar(String.fromCodePoint(c));
    }
    return false;
  }

  function _buildOffsetMap() {
    var root = _root();
    var walker = _walker(root);
    var map = [];
    var normCount = 0;
    var node;
    while ((node = walker.nextNode()) != null) {
      var txt = node.textContent || '';
      for (var i = 0; i < txt.length;) {
        var cp = txt.codePointAt(i);
        var charLen = cp > 0xFFFF ? 2 : 1;
        if (!_skip(cp)) {
          map.push({ node: node, rawIdx: i, normIdx: normCount, rawLen: charLen });
          normCount++;
        }
        i += charLen;
      }
    }
    return map;
  }

  function _bisect(map, target) {
    var lo = 0, hi = map.length;
    while (lo < hi) {
      var mid = (lo + hi) >>> 1;
      if (map[mid].normIdx < target) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  function _buildGroups(map, offset, length) {
    var start = _bisect(map, offset);
    var end = _bisect(map, offset + length);
    var groups = [];
    var cur = null;
    for (var s = start; s < end; s++) {
      if (!cur || cur.node !== map[s].node) {
        cur = { node: map[s].node, start: map[s].rawIdx, end: map[s].rawIdx + map[s].rawLen };
        groups.push(cur);
      } else {
        cur.end = map[s].rawIdx + map[s].rawLen;
      }
    }
    return groups;
  }

  var ALL_COLORS = ['yellow','green','blue','pink','purple'];
  var _rebuildPending = false;

  function _rebuildCssHighlightsNow() {
    _rebuildPending = false;
    _clearCssRubyHighlights();
    var colorGroups = {};
    var activeRubyElements = [];
    var rangeMap = window.__hibikiHighlightRangeMap;
    for (var id in rangeMap) {
      var entry = rangeMap[id];
      var color = entry.color || 'yellow';
      if (!colorGroups[color]) colorGroups[color] = [];
      for (var i = 0; i < entry.ranges.length; i++) {
        colorGroups[color].push(entry.ranges[i]);
      }
      var rubyElements = entry.rubyElements || [];
      for (var ri = 0; ri < rubyElements.length; ri++) {
        _addRubyHighlightClass(rubyElements[ri], color, activeRubyElements);
      }
    }
    for (var ci = 0; ci < ALL_COLORS.length; ci++) {
      var c = ALL_COLORS[ci];
      var hlName = 'hoshi-hl-' + c;
      var ranges = colorGroups[c];
      if (ranges && ranges.length) {
        var highlight = new Highlight(...ranges);
        highlight.priority = 1;
        CSS.highlights.set(hlName, highlight);
      } else {
        CSS.highlights.delete(hlName);
      }
    }
    window.__hibikiHighlightRubyElements = activeRubyElements;
    _syncHighlightVars();
  }

  function _rebuildCssHighlights() {
    if (_rebuildPending) return;
    _rebuildPending = true;
    requestAnimationFrame(_rebuildCssHighlightsNow);
  }

  // ── 从 selection 计算 normCharOffset + length ──
  window.__hibikiGetSelectionNormRange = function() {
    var sel = window.getSelection();
    if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
    var range = sel.getRangeAt(0);
    var text = sel.toString().trim();
    if (!text) return null;

    var root = _root();
    var walker = _walker(root);

    var normCount = 0;
    var startNorm = -1;
    var endNorm = -1;
    var node;

    while ((node = walker.nextNode()) != null) {
      var nodeText = node.textContent || '';
      for (var i = 0; i < nodeText.length;) {
        var cp = nodeText.codePointAt(i);
        var charLen = cp > 0xFFFF ? 2 : 1;
        var inRange;
        try {
          var pt = document.createRange();
          pt.setStart(node, i);
          pt.setEnd(node, Math.min(i + charLen, node.length));
          inRange = (range.compareBoundaryPoints(Range.START_TO_END, pt) > 0 &&
                     range.compareBoundaryPoints(Range.END_TO_START, pt) < 0);
        } catch(e) { inRange = false; }

        if (!_skip(cp)) {
          if (inRange && startNorm < 0) startNorm = normCount;
          if (inRange) endNorm = normCount + 1;
          normCount++;
        }
        i += charLen;
      }
    }

    if (startNorm < 0) return null;
    return { offset: startNorm, length: endNorm - startNorm, text: text };
  };

  // ── 应用高亮 ──
  window.__hibikiApplyHighlights = function(highlightsJson) {
    _syncHighlightVars();
    if (window.__hoshiCssHighlightsSupported) {
      window.__hibikiHighlightRangeMap = {};
      _clearCssRubyHighlights();
      if (!highlightsJson || highlightsJson.length === 0) {
        for (var i = 0; i < ALL_COLORS.length; i++) {
          CSS.highlights.delete('hoshi-hl-' + ALL_COLORS[i]);
        }
        return;
      }
      var map = _buildOffsetMap();
      for (var h = 0; h < highlightsJson.length; h++) {
        var hl = highlightsJson[h];
        var color = hl.color || 'yellow';
        var groups = _buildGroups(map, hl.offset, hl.length);
        var ranges = [];
        var rubyElements = [];
        for (var g = 0; g < groups.length; g++) {
          var ruby = _rubyForNode(groups[g].node);
          if (ruby) {
            if (rubyElements.indexOf(ruby) < 0) rubyElements.push(ruby);
            continue;
          }
          try {
            var r = document.createRange();
            r.setStart(groups[g].node, groups[g].start);
            r.setEnd(groups[g].node, groups[g].end);
            ranges.push(r);
          } catch (e) { console.warn('[hoshi-hl] range error:', e); }
        }
        if (ranges.length || rubyElements.length) {
          window.__hibikiHighlightRangeMap[hl.id] = {
            color: color,
            ranges: ranges,
            rubyElements: rubyElements
          };
        }
      }
      _rebuildCssHighlightsNow();
    } else {
      _clearFallbackRubyHighlights();
      document.querySelectorAll('[data-highlight-id]').forEach(function(el) {
        var parent = el.parentNode;
        while (el.firstChild) parent.insertBefore(el.firstChild, el);
        parent.removeChild(el);
      });
      var root = _root();
      root.normalize();
      if (!highlightsJson || highlightsJson.length === 0) return;
      var sorted = highlightsJson.slice().sort(function(a, b) {
        return a.offset - b.offset;
      });
      var map = _buildOffsetMap();
      for (var h = sorted.length - 1; h >= 0; h--) {
        var hl = sorted[h];
        var groups = _buildGroups(map, hl.offset, hl.length);
        if (groups.length === 0) continue;
        var color = hl.color || 'yellow';
        var highlightColor = _hlColor(color);
        var markColor = _hlMarkColor(color);
        var rubyElements = [];
        for (var g = groups.length - 1; g >= 0; g--) {
          var ruby = _rubyForNode(groups[g].node);
          if (ruby) {
            if (rubyElements.indexOf(ruby) < 0) rubyElements.push(ruby);
            continue;
          }
          try {
            var r = document.createRange();
            r.setStart(groups[g].node, groups[g].start);
            r.setEnd(groups[g].node, groups[g].end);
            var span = document.createElement('span');
            span.setAttribute('data-highlight-id', hl.id);
            span.className = 'hoshi-hl hoshi-hl-' + color;
            span.style.backgroundColor = highlightColor;
            span.style.borderRadius = '2px';
            span.style.textDecorationLine = 'underline';
            span.style.textDecorationColor = markColor;
            span.style.textDecorationThickness = '0.12em';
            span.style.textUnderlineOffset = '0.18em';
            r.surroundContents(span);
          } catch (e) { console.warn('[hoshi-hl] wrap error:', e); }
        }
        if (rubyElements.length) {
          window.__hibikiFallbackHighlightRubyMap[hl.id] = {
            color: color,
            elements: rubyElements
          };
        }
      }
      _reapplyFallbackRubyHighlights();
    }
  };

  // ── 文本搜索回退：为没有偏移量的收藏查找位置 ──
  window.__hibikiFindTextNormRange = function(text) {
    if (!text) return null;
    var root = _root();
    var walker = _walker(root);
    var normChars = [];
    var node;
    while ((node = walker.nextNode()) != null) {
      var txt = node.textContent || '';
      for (var i = 0; i < txt.length;) {
        var cp = txt.codePointAt(i);
        var charLen = cp > 0xFFFF ? 2 : 1;
        if (!_skip(cp)) {
          normChars.push(String.fromCodePoint(cp));
        }
        i += charLen;
      }
    }
    var haystack = normChars.join('');
    var needleChars = [];
    for (var i = 0; i < text.length;) {
      var cp = text.codePointAt(i);
      var charLen = cp > 0xFFFF ? 2 : 1;
      if (!_skip(cp)) {
        needleChars.push(String.fromCodePoint(cp));
      }
      i += charLen;
    }
    var needle = needleChars.join('');
    if (!needle) return null;
    var idx = haystack.indexOf(needle);
    if (idx < 0) return null;
    return { offset: idx, length: needle.length };
  };

  // ── 移除单条高亮 ──
  window.__hibikiRemoveHighlight = function(id) {
    if (window.__hoshiCssHighlightsSupported) {
      delete window.__hibikiHighlightRangeMap[id];
      _rebuildCssHighlights();
    } else {
      var rubyEntry = window.__hibikiFallbackHighlightRubyMap[id];
      if (rubyEntry) {
        var rubyElements = rubyEntry.elements || [];
        for (var i = 0; i < rubyElements.length; i++) {
          _removeFavoriteRubyClasses(rubyElements[i]);
        }
        delete window.__hibikiFallbackHighlightRubyMap[id];
        _reapplyFallbackRubyHighlights();
      }
      var els = document.querySelectorAll('[data-highlight-id="' + id + '"]');
      els.forEach(function(el) {
        var parent = el.parentNode;
        while (el.firstChild) parent.insertBefore(el.firstChild, el);
        parent.removeChild(el);
        parent.normalize();
      });
    }
  };
})();
''';

  static Future<void> inject(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: _js);
  }

  static Future<({int offset, int length, String text})?> getSelectionRange(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source: '(function(){try{var r=window.__hibikiGetSelectionNormRange();'
          'return r?JSON.stringify(r):"null";}catch(e){return "null";}})();',
    );
    if (raw is! String || raw.isEmpty || raw == 'null') return null;
    final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;
    final int? offset = (json['offset'] as num?)?.toInt();
    final int? length = (json['length'] as num?)?.toInt();
    final String? text = json['text'] as String?;
    if (offset == null || length == null || text == null) return null;
    return (offset: offset, length: length, text: text);
  }

  static Future<void> applyHighlights(
    InAppWebViewController controller,
    List<FavoriteSentence> highlights, {
    String backgroundHex = '#ffffff',
    String? customHighlightCss,
  }) async {
    final List<Map<String, dynamic>> payload = [];
    int backfillCount = 0;
    for (final FavoriteSentence h in highlights) {
      if (h.normCharOffset != null && h.normCharLength != null) {
        payload.add(<String, dynamic>{
          'id': h.id,
          'offset': h.normCharOffset,
          'length': h.normCharLength,
          'color': h.color ?? 'yellow',
        });
        continue;
      }
      if (h.text.isEmpty) continue;
      final String escapedText = jsonEncode(h.text);
      final Object? raw = await controller.evaluateJavascript(
        source:
            '(function(){try{var r=window.__hibikiFindTextNormRange($escapedText);'
            'return r?JSON.stringify(r):"null";}catch(e){return "null";}})();',
      );
      if (raw is String && raw != 'null' && raw.isNotEmpty) {
        try {
          final Map<String, dynamic> found =
              jsonDecode(raw) as Map<String, dynamic>;
          final int? offset = (found['offset'] as num?)?.toInt();
          final int? length = (found['length'] as num?)?.toInt();
          if (offset != null && length != null) {
            payload.add(<String, dynamic>{
              'id': h.id,
              'offset': offset,
              'length': length,
              'color': h.color ?? 'yellow',
            });
            backfillCount++;
          }
        } catch (e, stack) {
          ErrorLogService.instance
              .log('HighlightBridge.backfillDecode', e, stack);
        }
      }
    }
    if (backfillCount > 0) {
      debugPrint(
          '[hoshi-hl] backfilled $backfillCount favorites via text search');
    }
    final String json = jsonEncode(payload);
    final String escapedBg = jsonEncode(backgroundHex);
    final String escapedCustom =
        customHighlightCss != null ? jsonEncode(customHighlightCss) : 'null';
    await controller.evaluateJavascript(
      source: 'window.__hibikiHighlightBg=$escapedBg;'
          'window.__hibikiCustomHighlightColor=$escapedCustom;'
          'window.__hibikiApplyHighlights && window.__hibikiApplyHighlights($json);',
    );
  }

  static Future<void> removeHighlight(
    InAppWebViewController controller,
    String highlightId,
  ) async {
    final String escaped = jsonEncode(highlightId);
    await controller.evaluateJavascript(
      source:
          'window.__hibikiRemoveHighlight && window.__hibikiRemoveHighlight($escaped);',
    );
  }
}
