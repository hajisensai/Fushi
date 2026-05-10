import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/favorite_sentence_repository.dart';

class HighlightBridge {
  HighlightBridge._();

  // language=javascript
  static const String _js = r'''
(function() {
  if (window.__hibikiHighlightsInstalled) return;
  window.__hibikiHighlightsInstalled = true;

  var BASE_COLORS = {
    yellow: [255,220,0],
    green:  [0,200,83],
    blue:   [68,138,255],
    pink:   [255,64,129],
    purple: [170,0,255]
  };
  window.__hibikiHighlightBg = '#ffffff';

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
    var rgb = BASE_COLORS[name] || BASE_COLORS.yellow;
    var a = _pickAlpha(name, _luminance(window.__hibikiHighlightBg));
    return 'rgba('+rgb[0]+','+rgb[1]+','+rgb[2]+','+a+')';
  }

  function _root() {
    return document.body;
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
      for (var i = 0; i < nodeText.length; i++) {
        var inRange;
        try {
          var pt = document.createRange();
          pt.setStart(node, i);
          pt.setEnd(node, Math.min(i + 1, node.length));
          inRange = (range.compareBoundaryPoints(Range.START_TO_END, pt) > 0 &&
                     range.compareBoundaryPoints(Range.END_TO_START, pt) < 0);
        } catch(e) { inRange = false; }

        if (!_skip(nodeText.charCodeAt(i))) {
          if (inRange && startNorm < 0) startNorm = normCount;
          if (inRange) endNorm = normCount + 1;
          normCount++;
        }
      }
    }

    if (startNorm < 0) return null;
    return { offset: startNorm, length: endNorm - startNorm, text: text };
  };

  // ── 应用高亮 ──
  window.__hibikiApplyHighlights = function(highlightsJson) {
    document.querySelectorAll('[data-highlight-id]').forEach(function(el) {
      var parent = el.parentNode;
      while (el.firstChild) parent.insertBefore(el.firstChild, el);
      parent.removeChild(el);
    });
    var root = _root();
    root.normalize();

    if (!highlightsJson || highlightsJson.length === 0) return;

    // 先按 offset 升序排列
    var sorted = highlightsJson.slice().sort(function(a, b) {
      return a.offset - b.offset;
    });

    // 建 offset map
    var walker = _walker(root);
    var map = [];
    var normCount = 0;
    var node;
    while ((node = walker.nextNode()) != null) {
      var txt = node.textContent || '';
      for (var i = 0; i < txt.length; i++) {
        if (!_skip(txt.charCodeAt(i))) {
          map.push({ node: node, rawIdx: i, normIdx: normCount });
          normCount++;
        }
      }
    }

    // 倒序 wrap 以避免 offset 失效
    for (var h = sorted.length - 1; h >= 0; h--) {
      var hl = sorted[h];
      var segments = [];
      for (var m = 0; m < map.length; m++) {
        if (map[m].normIdx >= hl.offset && map[m].normIdx < hl.offset + hl.length) {
          segments.push(map[m]);
        }
      }
      if (segments.length === 0) continue;

      var color = _hlColor(hl.color || 'yellow');
      var groups = [];
      var cur = null;
      for (var s = 0; s < segments.length; s++) {
        if (!cur || cur.node !== segments[s].node) {
          cur = { node: segments[s].node, start: segments[s].rawIdx, end: segments[s].rawIdx + 1 };
          groups.push(cur);
        } else {
          cur.end = segments[s].rawIdx + 1;
        }
      }
      for (var g = groups.length - 1; g >= 0; g--) {
        try {
          var r = document.createRange();
          r.setStart(groups[g].node, groups[g].start);
          r.setEnd(groups[g].node, groups[g].end);
          var span = document.createElement('span');
          span.setAttribute('data-highlight-id', hl.id);
          span.style.backgroundColor = color;
          span.style.borderRadius = '2px';
          r.surroundContents(span);
        } catch (e) {}
      }
    }
  };

  // ── 移除单条高亮 ──
  window.__hibikiRemoveHighlight = function(id) {
    var els = document.querySelectorAll('[data-highlight-id="' + id + '"]');
    els.forEach(function(el) {
      var parent = el.parentNode;
      while (el.firstChild) parent.insertBefore(el.firstChild, el);
      parent.removeChild(el);
      parent.normalize();
    });
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
      source:
          '(function(){try{var r=window.__hibikiGetSelectionNormRange();'
          'return r?JSON.stringify(r):"null";}catch(e){return "null";}})();',
    );
    if (raw is! String || raw.isEmpty || raw == 'null') return null;
    final Map<String, dynamic> json =
        jsonDecode(raw) as Map<String, dynamic>;
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
    final List<Map<String, dynamic>> payload = highlights
        .where((FavoriteSentence h) =>
            h.normCharOffset != null && h.normCharLength != null)
        .map((FavoriteSentence h) => <String, dynamic>{
              'id': h.id,
              'offset': h.normCharOffset,
              'length': h.normCharLength,
              'color': h.color ?? 'yellow',
            })
        .toList();
    final String json = jsonEncode(payload);
    final String escaped = jsonEncode(backgroundHex);
    await controller.evaluateJavascript(
      source:
          'window.__hibikiHighlightBg=$escaped;'
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
