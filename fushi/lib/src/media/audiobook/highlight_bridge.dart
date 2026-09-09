import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi_audio/fushi_audio.dart';

class HighlightBridge {
  HighlightBridge._();

  // language=javascript
  static const String _js = '''
(function() {
  if (window.__fushiHighlightsInstalled) return;
  window.__fushiHighlightsInstalled = true;
  window.__fushiCssHighlightsSupported = !!(window.CSS && CSS.highlights && window.Highlight);

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
    yellow: '--fushi-hl-yellow-mark',
    green:  '--fushi-hl-green-mark',
    blue:   '--fushi-hl-blue-mark',
    pink:   '--fushi-hl-pink-mark',
    purple: '--fushi-hl-purple-mark'
  };
  // G14：背景深/浅由 Dart 侧单一真相（ReaderContentStyles.isDarkBackground，
  // Rec.601/0.5）算好经 applyHighlights 注入；JS 不再自带亮度公式（此前的
  // Rec.709/0.4 与滚动条判定对同一背景色会得出不同深浅）。默认 false = 浅色，
  // 与旧默认背景 #ffffff 的判定一致。
  window.__fushiHighlightBgDark = false;
  window.__fushiHighlightRangeMap = {};
  window.__fushiHighlightRubyElements = [];
  window.__fushiFallbackHighlightRubyMap = {};

  function _pickAlpha(colorName) {
    var dark = window.__fushiHighlightBgDark === true;
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
    var rgb = BASE_COLORS[name] || BASE_COLORS.yellow;
    var a = _pickAlpha(name);
    return 'rgba('+rgb[0]+','+rgb[1]+','+rgb[2]+','+a+')';
  }

  function _hlMarkColor(name) {
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
      root.style.setProperty('--fushi-hl-' + cn, _hlColor(cn));
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
      ruby.classList.remove('fushi-hl-' + ALL_COLORS[i] + '-ruby-active');
    }
  }

  function _addRubyHighlightClass(ruby, color, bucket) {
    if (!ruby || !ruby.classList) return;
    color = color || 'yellow';
    ruby.classList.add('fushi-hl-' + color + '-ruby-active');
    if (bucket && bucket.indexOf(ruby) < 0) bucket.push(ruby);
  }

  function _clearCssRubyHighlights() {
    var elements = window.__fushiHighlightRubyElements || [];
    for (var i = 0; i < elements.length; i++) {
      _removeFavoriteRubyClasses(elements[i]);
    }
    window.__fushiHighlightRubyElements = [];
  }

  function _clearFallbackRubyHighlights() {
    var map = window.__fushiFallbackHighlightRubyMap || {};
    for (var id in map) {
      if (!Object.prototype.hasOwnProperty.call(map, id)) continue;
      var elements = map[id].elements || [];
      for (var i = 0; i < elements.length; i++) {
        _removeFavoriteRubyClasses(elements[i]);
      }
    }
    window.__fushiFallbackHighlightRubyMap = {};
  }

  function _reapplyFallbackRubyHighlights() {
    var map = window.__fushiFallbackHighlightRubyMap || {};
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

  // Text anchors retain punctuation and every script. Only layout whitespace
  // is ignored; audio's character whitelist is not a favorite-text coordinate.
  function _anchorText(text) {
    return Array.from(text || '').filter(function(ch) { return ch.trim() !== ''; }).join('');
  }

  function _buildOffsetMap() {
    var walker = _walker(_root());
    var map = [];
    var normCount = 0, studyCount = 0;
    var node;
    while ((node = walker.nextNode()) != null) {
      var txt = node.textContent || '';
      for (var i = 0; i < txt.length;) {
        var cp = txt.codePointAt(i);
        var ch = String.fromCodePoint(cp);
        if (_anchorText(ch)) {
          map.push({ node: node, rawIdx: i, normIdx: normCount,
            rawLen: ch.length, text: ch, studyIdx: studyCount });
          normCount += ch.length;
        }
        if (window.fushiStudyUnits && window.fushiStudyUnits.isUnitEnd(txt, i)) studyCount++;
        i += ch.length;
      }
    }
    return map;
  }

  function _resolveTextRange(map, text, studyHint) {
    var needle = _anchorText(text);
    if (!needle) return null;
    var haystack = map.map(function(entry) { return entry.text; }).join('');
    var best = null, distance = Infinity, tied = false;
    for (var at = haystack.indexOf(needle); at >= 0;
         at = haystack.indexOf(needle, at + 1)) {
      var entry = map[_bisect(map, at)];
      if (!entry || entry.normIdx !== at) continue;
      var d = typeof studyHint === 'number' ? Math.abs(entry.studyIdx - studyHint) : 0;
      if (d < distance) {
        best = { offset: at, length: needle.length };
        distance = d;
        tied = false;
      } else if (d === distance) tied = true;
    }
    // A stale offset may narrow repeated text, but cannot invent a text match.
    // Ambiguous matches remain unpainted rather than highlighting another copy.
    return tied ? null : best;
  }

  function _resolveHighlights(map, highlights) {
    return (highlights || []).map(function(hl) {
      var range = _resolveTextRange(map, hl.text, hl.offset);
      return range ? { id: hl.id, color: hl.color,
        offset: range.offset, length: range.length } : null;
    }).filter(function(hl) { return hl !== null; });
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
    var rangeMap = window.__fushiHighlightRangeMap;
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
      var hlName = 'fushi-hl-' + c;
      var ranges = colorGroups[c];
      if (ranges && ranges.length) {
        var highlight = new Highlight(...ranges);
        highlight.priority = 1;
        CSS.highlights.set(hlName, highlight);
      } else {
        CSS.highlights.delete(hlName);
      }
    }
    window.__fushiHighlightRubyElements = activeRubyElements;
    _syncHighlightVars();
  }

  function _rebuildCssHighlights() {
    if (_rebuildPending) return;
    _rebuildPending = true;
    requestAnimationFrame(_rebuildCssHighlightsNow);
  }

  // ── 从 selection 计算 normCharOffset + length ──
  window.__fushiGetSelectionNormRange = function() {
    var data = window.fushiSelection && window.fushiSelection.nativeSelectionSentenceRange();
    return data && data.normalizedOffset !== null && data.normalizedLength !== null
      ? { offset: data.normalizedOffset, length: data.normalizedLength, text: data.text }
      : null;
  };

  // ── 应用高亮 ──
  window.__fushiApplyHighlights = function(highlightsJson) {
    _syncHighlightVars();
    if (window.__fushiCssHighlightsSupported) {
      window.__fushiHighlightRangeMap = {};
      _clearCssRubyHighlights();
      if (!highlightsJson || highlightsJson.length === 0) {
        for (var i = 0; i < ALL_COLORS.length; i++) {
          CSS.highlights.delete('fushi-hl-' + ALL_COLORS[i]);
        }
        return;
      }
      var map = _buildOffsetMap();
      highlightsJson = _resolveHighlights(map, highlightsJson);
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
          } catch (e) { console.warn('[fushi-hl] range error:', e); }
        }
        if (ranges.length || rubyElements.length) {
          window.__fushiHighlightRangeMap[hl.id] = {
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
      var map = _buildOffsetMap();
      var sorted = _resolveHighlights(map, highlightsJson).sort(function(a, b) {
        return a.offset - b.offset;
      });
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
            span.className = 'fushi-hl fushi-hl-' + color;
            span.style.backgroundColor = highlightColor;
            span.style.borderRadius = '2px';
            span.style.textDecorationLine = 'underline';
            span.style.textDecorationColor = markColor;
            span.style.textDecorationThickness = '0.12em';
            span.style.textUnderlineOffset = '0.18em';
            r.surroundContents(span);
          } catch (e) { console.warn('[fushi-hl] wrap error:', e); }
        }
        if (rubyElements.length) {
          window.__fushiFallbackHighlightRubyMap[hl.id] = {
            color: color,
            elements: rubyElements
          };
        }
      }
      _reapplyFallbackRubyHighlights();
    }
  };

  // ── 文本搜索回退：为没有偏移量的收藏查找位置 ──
  window.__fushiFindTextNormRange = function(text, studyHint) {
    return _resolveTextRange(_buildOffsetMap(), text, studyHint);
  };

  // ── 移除单条高亮 ──
  window.__fushiRemoveHighlight = function(id) {
    if (window.__fushiCssHighlightsSupported) {
      delete window.__fushiHighlightRangeMap[id];
      _rebuildCssHighlights();
    } else {
      var rubyEntry = window.__fushiFallbackHighlightRubyMap[id];
      if (rubyEntry) {
        var rubyElements = rubyEntry.elements || [];
        for (var i = 0; i < rubyElements.length; i++) {
          _removeFavoriteRubyClasses(rubyElements[i]);
        }
        delete window.__fushiFallbackHighlightRubyMap[id];
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
      source: '(function(){try{var r=window.__fushiGetSelectionNormRange();'
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
  }) async {
    // Stored offsets are navigation hints, not highlight character indexes.
    // Always send the text, including for old favorites with a non-null offset.
    final List<Map<String, dynamic>> payload = highlights
        .where((FavoriteSentence h) => h.text.isNotEmpty)
        .map(
          (FavoriteSentence h) => <String, dynamic>{
            'id': h.id,
            'text': h.text,
            'offset': h.normCharOffset,
            'length': h.normCharLength,
            'color': h.color ?? 'yellow',
          },
        )
        .toList();
    final String json = jsonEncode(payload);
    final bool backgroundIsDark = ReaderContentStyles.isDarkBackground(
      backgroundHex,
    );
    await controller.evaluateJavascript(
      source: 'window.__fushiHighlightBgDark=$backgroundIsDark;'
          'window.__fushiApplyHighlights && window.__fushiApplyHighlights($json);',
    );
  }

  static Future<void> removeHighlight(
    InAppWebViewController controller,
    String highlightId,
  ) async {
    final String escaped = jsonEncode(highlightId);
    await controller.evaluateJavascript(
      source:
          'window.__fushiRemoveHighlight && window.__fushiRemoveHighlight($escaped);',
    );
  }
}
