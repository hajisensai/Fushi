// TODO-909 (M0): Visual-Novel reader view-mode, ported from hoshi a
// (Hoshi-Reader-Android origin/main @ 24361a9):
//   app/src/main/assets/hoshi-web/reader/{reader-text-semantics,
//   reader-vn-content-stream, reader-vn-range-map, reader-visual-novel}.js
//
// VN is the third book view-mode (alongside 'paginated' / 'continuous'): it
// detaches the chapter into an off-screen source root, splits it into per-Block
// screens, renders one screen at a time onto a `fushi-vn-stage`, advances on
// `paginate("forward")`, and restores by char-offset -> screen index.
//
// Hibiki adaptations vs hoshi a (see [vnShellScript]):
//   * The 4 injected dependency scripts (text-semantics / vn-content-stream /
//     vn-range-map / media-semantics) are inlined ahead of `window.fushiReader`.
//   * `notifyRestoreComplete` forwards to InAppWebView's `onRestoreComplete`
//     handler instead of hoshi's native `FushiReaderRestore.postMessage`.
//   * media-semantics is an M0 no-op stub (images render from cloned chapter
//     markup); Sasayaki / highlights / E-Ink overlay are M1 (their hoshi calls
//     are guarded by `window.fushiHighlights` / popupHost checks, safe at M0).
//   * Config placeholders become Dart interpolation; `clickAdvance` is NOT a
//     hoshi JS concern -- the host (webview.part.dart) binds blank-tap ->
//     `paginate("forward")`.
//
// `window.fushiReader` here exposes the same method names the Dart side already
// invokes via short-circuit guards (paginate / calculateProgress /
// applySasayakiCues / highlightSasayakiCue / clearSasayakiCue). Methods the VN
// object does not define (pageInfo / scrollToCharOffset / beginUiScaleReanchor /
// fushiProgressDetails) stay no-op via those `&&` / `typeof` guards.
//
// ignore_for_file: lines_longer_than_80_chars
library;

import 'package:fushi/src/reader/reader_pagination_scripts.dart'
    show ReaderPaginationScripts;
import 'package:fushi/src/reader/reader_content_styles.dart'
    show ReaderLayoutDefaults;

/// Builds the VN-mode reader shell `<script>` for the reader WebView. Mirrors
/// [ReaderPaginationScripts.shellScript]'s shells but installs the hoshi a
/// Visual-Novel `window.fushiReader`.
class ReaderVisualNovelScripts {
  ReaderVisualNovelScripts._();

  /// VN shell 的静态源码（`<script>…</script>`，零 per-nav 插值）。
  ///
  /// BUG-1140 第二阶段①：原来 `vnShellScript({initialProgress, revealSpeed, …})`
  /// 把每次导航的参数插进源码；现在整段被包成 `window.__fushiShells.vn = function(C)`，
  /// 参数由运行时读 `C`。恢复锚三选一的优先级与旧 Dart 三元式逐条相同。
  static String vnShellScript() => _shell();

  /// 恢复锚三选一的运行时分派（旧实现在 Dart 侧三元式挑一条语句）。
  static const String _initialRestoreJs = '''
    if (C.initialFragment !== null && C.initialFragment !== undefined) {
      window.fushiReader.jumpToFragment(C.initialFragment);
    } else if (C.initialCharOffset >= 0) {
      window.fushiReader.restoreToCharOffset(C.initialCharOffset);
    } else {
      window.fushiReader.restoreProgress(C.initialProgress);
    }''';

  static String _shell() {
    const String initialRestoreScript = _initialRestoreJs;
    // BUG-1688：与分页/连续 shell 同一份视口 meta 重写（单一真相源）。
    const String sharedInitViewport =
        ReaderPaginationScripts.sharedInitViewportJs;
    // TODO-1085 (BUG-513): single source of truth for the image viewport ratio,
    // shared with the paginated shell (ReaderLayoutDefaults.imageWidthViewportRatio),
    // consumed by applyImageMaxVars below.
    const double imageWidthRatio = ReaderLayoutDefaults.imageWidthViewportRatio;
    return '''<script>
window.__fushiShells.vn = function(C) {
(function(global) {
  'use strict';

  var readerRegexNegated = /[^0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\\p{Radical}\\p{Unified_Ideograph}]+/gimu;
  var readerRegex = /[0-9A-Za-z○◯々-〇〻ぁ-ゖゝ-ゞァ-ヺー０-９Ａ-Ｚａ-ｚｦ-ﾝ\\p{Radical}\\p{Unified_Ideograph}]/iu;

  function normalizeText(text) {
    return String(text || '').replace(readerRegexNegated, '');
  }

  function isMatchableChar(char) {
    return readerRegex.test(char || '');
  }

  // 学习单位口径，与分页 shell / Dart countStudyChars 同源（window.fushiStudyUnits
  // 由 ReaderPaginationScripts.engineShell 在任何 shell 安装之前注入）。
  function countChars(text) {
    return window.fushiStudyUnits.count(text);
  }

  function countRawChars(text) {
    return Array.from(text || '').length;
  }

  global.fushiReaderTextSemantics = {
    normalizeText: normalizeText,
    isMatchableChar: isMatchableChar,
    countChars: countChars,
    countRawChars: countRawChars
  };
})(window);
(function(global) {
  'use strict';
  // TODO-909 M0 stub: hoshi a's media-semantics bridges images to an
  // Android native @JavascriptInterface (FushiReaderImage). Hibiki has no
  // such bridge at M0, so images render from the chapter's own <img> markup
  // cloned into the VN screen. These no-ops keep reader-visual-novel.js's
  // setupReaderImage(s) calls safe. M1 wires Hibiki image interception.
  function noop() { return null; }
  global.fushiReaderMediaSemantics = {
    setupReaderImage: noop,
    setupReaderImages: noop
  };
})(window);
(function(global) {
  'use strict';

  var TEXT_NODE = 3;
  var ELEMENT_NODE = 1;
  var DOCUMENT_FRAGMENT_NODE = 11;
  var ignoredTags = new Set(['rt', 'rp', 'script', 'style']);
  var mediaTags = new Set(['img', 'svg', 'image', 'video', 'canvas', 'audio', 'picture', 'figure', 'table', 'iframe', 'object', 'embed']);

  function tagName(node) {
    return node && node.nodeType === ELEMENT_NODE ? String(node.tagName || '').toLowerCase() : '';
  }

  function childrenOf(node) {
    return Array.from(node && node.childNodes ? node.childNodes : []);
  }

  function textSemantics() {
    if (!global.fushiReaderTextSemantics) {
      throw new Error('fushiReaderTextSemantics is required for VN content stream');
    }
    return global.fushiReaderTextSemantics;
  }

  function normalizeText(text) {
    return textSemantics().normalizeText(text);
  }

  function countChars(text) {
    return textSemantics().countChars(text);
  }

  function countRawChars(text) {
    return textSemantics().countRawChars(text);
  }

  function isMatchableChar(char) {
    return textSemantics().isMatchableChar(char);
  }

  function ownIdsForNode(node) {
    var ids = new Set();
    if (node && node.nodeType === ELEMENT_NODE) {
      var id = node.getAttribute && node.getAttribute('id');
      if (id) ids.add(id);
      var name = node.getAttribute && node.getAttribute('name');
      if (name) ids.add(name);
    }
    return ids;
  }

  function mergeIds(into, from) {
    (from || new Set()).forEach(function(id) { into.add(id); });
    return into;
  }

  function hasClass(node, className) {
    if (!node || node.nodeType !== ELEMENT_NODE) return false;
    if (node.classList && node.classList.contains) return node.classList.contains(className);
    var value = node.getAttribute && node.getAttribute('class');
    return String(value || '').split(/\\s+/).indexOf(className) >= 0;
  }

  function hasMeaningfulText(node) {
    return !!String(node && node.textContent || '').trim();
  }

  function hasOwnMeaningfulText(node) {
    return childrenOf(node).some(function(child) {
      return child.nodeType === TEXT_NODE && !!String(child.textContent || '').trim();
    });
  }

  function hasMeaningfulTextOutsideChild(node, childOnMediaPath) {
    return childrenOf(node).some(function(child) {
      return child !== childOnMediaPath && hasMeaningfulText(child);
    });
  }

  function isTextMediaContextRoot(node) {
    var tag = tagName(node);
    return [
      'address',
      'blockquote',
      'dd',
      'dt',
      'figcaption',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'li',
      'p',
      'pre',
      'td',
      'th'
    ].indexOf(tag) >= 0 || hasOwnMeaningfulText(node);
  }

  function mediaTextContextRoot(node, stopRoot) {
    var current = node;
    var candidate = node;
    while (current && current.parentNode) {
      var parent = current.parentNode;
      if (parent === stopRoot) {
        if (
          candidate === node &&
          parent.nodeType === ELEMENT_NODE &&
          !mediaTags.has(tagName(parent)) &&
          isTextMediaContextRoot(parent)
        ) {
          candidate = parent;
        }
        break;
      }
      if (parent.nodeType === ELEMENT_NODE && !mediaTags.has(tagName(parent))) {
        candidate = parent;
      }
      current = parent;
    }
    return candidate || node;
  }

  function computedDisplay(node) {
    if (!global.getComputedStyle) return '';
    try {
      return String(global.getComputedStyle(node).display || '').toLowerCase();
    } catch (_error) {
      return '';
    }
  }

  function isBlockDisplay(display) {
    return [
      'block',
      'flex',
      'grid',
      'list-item',
      'table',
      'table-caption',
      'flow-root'
    ].indexOf(display) >= 0;
  }

  function isLargeImage(node) {
    return Number(node && node.naturalWidth || 0) > 256 || Number(node && node.naturalHeight || 0) > 256;
  }

  function isInlineGlyphImage(node) {
    return hasClass(node, 'gaiji') || hasClass(node, 'gaiji-line');
  }

  function isStandaloneImageNode(node, contextRoot) {
    if (isInlineGlyphImage(node)) return false;
    var textContext = mediaTextContextRoot(node, contextRoot);
    if (!hasMeaningfulText(textContext)) return true;
    if (isLargeImage(node)) return true;
    if (hasClass(node, 'block-img')) return true;
    return isBlockDisplay(computedDisplay(node));
  }

  function isStandaloneMediaNode(node, contextRoot) {
    var tag = tagName(node);
    if (tag === 'img') return isStandaloneImageNode(node, contextRoot || node);
    return mediaTags.has(tag);
  }

  function isIgnoredNode(node, root) {
    var current = node && node.nodeType === TEXT_NODE ? node.parentNode : node;
    while (current && current !== root) {
      if (current.nodeType === ELEMENT_NODE && ignoredTags.has(tagName(current))) return true;
      current = current.parentNode;
    }
    return !!(current && current.nodeType === ELEMENT_NODE && ignoredTags.has(tagName(current)));
  }

  function isContainerNode(node) {
    return !!(node && (node.nodeType === ELEMENT_NODE || node.nodeType === DOCUMENT_FRAGMENT_NODE));
  }

  function topLevelNodeFor(root, node) {
    var current = node;
    while (current && current.parentNode && current.parentNode !== root) {
      current = current.parentNode;
    }
    return current;
  }

  function nearestMediaRenderRoot(root, node) {
    var current = node;
    var candidate = node;
    while (current && current.parentNode && current.parentNode !== root) {
      var parent = current.parentNode;
      if (parent.nodeType === ELEMENT_NODE && !mediaTags.has(tagName(parent))) {
        if (hasMeaningfulTextOutsideChild(parent, current)) break;
        candidate = parent;
      }
      current = parent;
    }
    return candidate || node;
  }

  function closestAncestor(node, root, targetTag) {
    var current = node && node.nodeType === TEXT_NODE ? node.parentNode : node;
    while (current && current !== root) {
      if (current.nodeType === ELEMENT_NODE && tagName(current) === targetTag) return current;
      current = current.parentNode;
    }
    return current && current.nodeType === ELEMENT_NODE && tagName(current) === targetTag ? current : null;
  }

  function ReaderVnContentStream(root, options) {
    this.root = root;
    this.options = options || {};
    this.textEntries = [];
    this.totalMatchableChars = 0;
    this.totalRawChars = 0;
    this.sourceTextOffsets = new WeakMap();
    this.sourceTextRawOffsets = new WeakMap();
    this.sourceNodeStats = new WeakMap();
    this.sourceOrderIndexes = new WeakMap();
    this.sourcePreorderIndexes = new WeakMap();
    this.mediaNodeEntries = [];
    this.rebuild();
  }

  ReaderVnContentStream.prototype = {
    normalizeText: normalizeText,
    isMatchableChar: isMatchableChar,
    countChars: countChars,
    countRawChars: countRawChars,

    rebuild: function() {
      this.textEntries = [];
      this.sourceTextOffsets = new WeakMap();
      this.sourceTextRawOffsets = new WeakMap();
      this.sourceNodeStats = new WeakMap();
      this.sourceOrderIndexes = new WeakMap();
      this.sourcePreorderIndexes = new WeakMap();
      this.mediaNodeEntries = [];
      this.indexSourcePreorder();

      var topLevelNodes = childrenOf(this.root);
      for (var order = 0; order < topLevelNodes.length; order++) {
        this.sourceOrderIndexes.set(topLevelNodes[order], order);
      }

      var count = 0;
      var rawCount = 0;
      this.walkTextNodes(this.root, (function(node) {
        this.sourceTextOffsets.set(node, count);
        this.sourceTextRawOffsets.set(node, rawCount);
        var entry = {
          node: node,
          order: this.sourceOrderForTextNode(node),
          preorder: this.sourcePreorderForNode(node),
          rubyRoot: this.rubyRootForTextNode(node),
          startChar: count,
          startRaw: rawCount,
          text: node.textContent || ''
        };
        count += countChars(entry.text);
        rawCount += countRawChars(entry.text);
        entry.endChar = count;
        entry.endRaw = rawCount;
        this.textEntries.push(entry);
        this.updateSourceNodeStats(node, entry);
      }).bind(this));

      this.totalMatchableChars = count;
      this.totalRawChars = rawCount;
      this.mediaNodeEntries = this.collectMediaNodeEntries();
    },

    indexSourcePreorder: function() {
      var index = 0;
      var visit = (function(node) {
        if (!node) return;
        this.sourcePreorderIndexes.set(node, index);
        index += 1;
        childrenOf(node).forEach(visit);
      }).bind(this);
      visit(this.root);
    },

    walkTextNodes: function(root, visit) {
      if (!root || isIgnoredNode(root, this.root)) return;
      if (root.nodeType === TEXT_NODE) {
        visit(root);
        return;
      }
      if (!isContainerNode(root)) return;
      var children = childrenOf(root);
      for (var i = 0; i < children.length; i++) {
        this.walkTextNodes(children[i], visit);
      }
    },

    updateSourceNodeStats: function(node, entry) {
      var current = node;
      while (current) {
        var stats = this.sourceNodeStats.get(current);
        if (!stats) {
          this.sourceNodeStats.set(current, {
            hasText: true,
            startChar: entry.startChar,
            endChar: entry.endChar,
            startRaw: entry.startRaw,
            endRaw: entry.endRaw
          });
        } else {
          stats.startChar = Math.min(stats.startChar, entry.startChar);
          stats.endChar = Math.max(stats.endChar, entry.endChar);
          stats.startRaw = Math.min(stats.startRaw, entry.startRaw);
          stats.endRaw = Math.max(stats.endRaw, entry.endRaw);
        }
        if (current === this.root) break;
        current = current.parentNode;
      }
    },

    statsForNode: function(node) {
      return this.sourceNodeStats.get(node) || { hasText: false, startChar: 0, endChar: 0, startRaw: 0, endRaw: 0 };
    },

    sourceOrderForTextNode: function(node) {
      var root = topLevelNodeFor(this.root, node);
      var order = this.sourceOrderIndexes.get(root);
      return order === undefined ? 0 : order;
    },

    idsForNode: function(root, extraIds) {
      var ids = new Set(extraIds || []);
      var visit = function(node) {
        mergeIds(ids, ownIdsForNode(node));
        childrenOf(node).forEach(visit);
      };
      visit(root);
      return ids;
    },

    idsForMediaUnit: function(renderRoot, mediaNode) {
      if (renderRoot === mediaNode) return this.idsForNode(renderRoot);
      var ids = this.idsForNode(mediaNode);
      var current = mediaNode ? mediaNode.parentNode : null;
      while (current) {
        mergeIds(ids, ownIdsForNode(current));
        if (current === renderRoot || current === this.root) break;
        current = current.parentNode;
      }
      return ids;
    },

    textItems: function() {
      var items = [];
      for (var e = 0; e < this.textEntries.length; e++) {
        var entry = this.textEntries[e];
        var text = entry.text;
        var offset = 0;
        var rawOffset = 0;
        var matchableOffset = 0;
        while (offset < text.length) {
          var char = String.fromCodePoint(text.codePointAt(offset));
          var next = offset + char.length;
          // chapterCharStart/End 是**进度偏移**坐标（entry.startChar 同源），所以
          // 用学习单位判据；有声书 cue 的 collectMatchableSegments 仍走 isMatchableChar。
          var matchable = window.fushiStudyUnits.isUnitEnd(text, offset);
          items.push({
            node: entry.node,
            order: entry.order,
            preorder: entry.preorder,
            rubyRoot: entry.rubyRoot,
            char: char,
            start: offset,
            end: next,
            chapterRawStart: entry.startRaw + rawOffset,
            chapterRawEnd: entry.startRaw + rawOffset + 1,
            chapterCharStart: entry.startChar + matchableOffset,
            chapterCharEnd: entry.startChar + matchableOffset + (matchable ? 1 : 0)
          });
          if (matchable) matchableOffset += 1;
          rawOffset += 1;
          offset = next;
        }
      }
      return items;
    },

    containsStandaloneMedia: function(root) {
      return this.containsStandaloneMediaInContext(root, root);
    },

    containsStandaloneMediaInContext: function(root, contextRoot) {
      if (!root || isIgnoredNode(root, this.root)) return false;
      if (root.nodeType === ELEMENT_NODE && isStandaloneMediaNode(root, contextRoot || root)) return true;
      return childrenOf(root).some((function(child) {
        return this.containsStandaloneMediaInContext(child, contextRoot || root);
      }).bind(this));
    },

    isInlineMediaNode: function(node, contextRoot) {
      return !!(
        node &&
        node.nodeType === ELEMENT_NODE &&
        mediaTags.has(tagName(node)) &&
        !isStandaloneMediaNode(node, contextRoot || this.root)
      );
    },

    collectMediaNodeEntries: function() {
      var result = [];
      var visit = (function(node) {
        if (!node || isIgnoredNode(node, this.root)) return;
        if (node.nodeType === ELEMENT_NODE && mediaTags.has(tagName(node))) {
          result.push({
            node: node,
            preorder: this.sourcePreorderForNode(node)
          });
          return;
        }
        childrenOf(node).forEach(visit);
      }).bind(this);
      visit(this.root);
      result.sort(function(a, b) {
        return a.preorder - b.preorder;
      });
      return result;
    },

    mediaNodes: function() {
      return this.mediaNodeEntries || [];
    },

    hasVisibleTextBetweenPreorder: function(_root, start, end) {
      if (end <= start) return false;
      for (var i = 0; i < this.textEntries.length; i++) {
        var entry = this.textEntries[i];
        if (entry.preorder <= start) continue;
        if (entry.preorder >= end) break;
        if (String(entry.text || '').trim()) return true;
      }
      return false;
    },

    mediaUnits: function() {
      var result = [];
      var visit = (function(node) {
        if (!node || isIgnoredNode(node, this.root)) return;
        if (node.nodeType === ELEMENT_NODE && isStandaloneMediaNode(node, this.root)) {
          var renderRoot = this.renderRootForMediaNode(node);
          var position = this.sourcePositionForNode(renderRoot);
          result.push({
            node: renderRoot,
            mediaNode: node,
            renderRoot: renderRoot,
            tagName: tagName(node),
            mediaTagName: tagName(node),
            renderRootTagName: tagName(renderRoot),
            sourceOrder: this.sourceOrderForNode(renderRoot),
            preorder: this.sourcePreorderForNode(node),
            startChar: position.startChar,
            endChar: position.endChar,
            startRaw: position.startRaw,
            endRaw: position.endRaw,
            ids: this.idsForMediaUnit(renderRoot, node)
          });
          return;
        }
        childrenOf(node).forEach(visit);
      }).bind(this);
      visit(this.root);
      result.sort(function(a, b) {
        return a.preorder - b.preorder;
      });
      return result;
    },

    renderRootForMediaNode: function(node) {
      return nearestMediaRenderRoot(this.root, node);
    },

    sourceOrderForNode: function(node) {
      var root = topLevelNodeFor(this.root, node);
      var order = this.sourceOrderIndexes.get(root);
      return order === undefined ? 0 : order;
    },

    sourcePreorderForNode: function(node) {
      var order = this.sourcePreorderIndexes.get(node);
      return order === undefined ? 0 : order;
    },

    sourcePositionForNode: function(node) {
      var stats = this.statsForNode(node);
      if (stats.hasText) return stats;
      var preorder = this.sourcePreorderForNode(node);
      var previous = null;
      for (var i = 0; i < this.textEntries.length; i++) {
        var entry = this.textEntries[i];
        if (entry.preorder > preorder) {
          return {
            hasText: false,
            startChar: entry.startChar,
            endChar: entry.startChar,
            startRaw: entry.startRaw,
            endRaw: entry.startRaw
          };
        }
        if (entry.preorder < preorder) previous = entry;
      }
      var char = previous ? previous.endChar : 0;
      var raw = previous ? previous.endRaw : 0;
      return { hasText: false, startChar: char, endChar: char, startRaw: raw, endRaw: raw };
    },

    rubyRootForTextNode: function(node) {
      return closestAncestor(node, this.root, 'ruby');
    }
  };

  global.fushiReaderVnContentStream = {
    create: function(root, options) {
      return new ReaderVnContentStream(root, options);
    }
  };
})(window);
(function(global) {
  'use strict';

  function ReaderVnRangeMap(reader) {
    this.reader = reader;
    this.cloneTextOffsets = new WeakMap();
    this.cloneTextRawOffsets = new WeakMap();
  }

  ReaderVnRangeMap.prototype = {
    registerCloneTextOffset: function(node, charOffset, rawOffset) {
      this.cloneTextOffsets.set(node, charOffset === undefined ? 0 : charOffset);
      this.cloneTextRawOffsets.set(node, rawOffset === undefined ? 0 : rawOffset);
    },

    cloneTextOffsetForNode: function(node) {
      return this.cloneTextOffsets.get(node);
    },

    cloneTextRawOffsetForNode: function(node) {
      return this.cloneTextRawOffsets.get(node);
    },

    collectRawSegments: function(offset, length) {
      var start = Number(offset) || 0;
      var end = start + Math.max(0, Number(length) || 0);
      var segments = [];
      var walker = this.reader.createWalker();
      var node;
      while (node = walker.nextNode()) {
        var nodeStart = this.reader.nodeStartRawOffsets.get(node);
        if (nodeStart === undefined) continue;
        var text = node.textContent || '';
        var rawCursor = nodeStart;
        var i = 0;
        var segment = null;
        var flushSegment = function() {
          if (!segment) return;
          segments.push(segment);
          segment = null;
        };
        while (i < text.length && rawCursor < end) {
          var char = String.fromCodePoint(text.codePointAt(i));
          var next = i + char.length;
          if (rawCursor >= start) {
            if (!segment) {
              segment = { node: node, start: i, end: next };
            } else {
              segment.end = next;
            }
          }
          rawCursor += 1;
          i = next;
        }
        flushSegment();
      }
      return segments;
    },

    collectMatchableCueRanges: function(cues) {
      var result = [];
      for (var i = 0; i < cues.length; i++) {
        var cue = cues[i];
        if (!cue || !cue.id) continue;
        var start = Math.max(0, Number(cue.start) || 0);
        var length = Math.max(0, Number(cue.length) || 0);
        result.push({
          id: cue.id,
          ranges: this.collectMatchableSegments(start, start + length)
        });
      }
      return result;
    },

    collectMatchableSegments: function(startOffset, endOffset) {
      var start = Math.max(0, Number(startOffset) || 0);
      var end = Math.max(start, Number(endOffset) || 0);
      var ranges = [];
      if (end <= start) return ranges;
      var walker = this.reader.createWalker();
      var node;
      while (node = walker.nextNode()) {
        var nodeStart = this.reader.nodeStartOffsets.get(node);
        if (nodeStart === undefined) continue;
        var text = node.textContent || '';
        var cursor = nodeStart;
        var offset = 0;
        var segment = null;
        var flushSegment = function() {
          if (!segment) return;
          ranges.push(segment);
          segment = null;
        };
        while (offset < text.length && cursor < end) {
          var char = String.fromCodePoint(text.codePointAt(offset));
          var next = offset + char.length;
          if (this.reader.isMatchableChar(char)) {
            if (cursor >= start && cursor < end) {
              if (!segment) {
                segment = { node: node, start: offset, end: next };
              } else {
                segment.end = next;
              }
            } else {
              flushSegment();
            }
            cursor += 1;
            if (cursor === end) flushSegment();
          } else if (segment) {
            segment.end = next;
          } else if (cursor > start && cursor < end) {
            segment = { node: node, start: offset, end: next };
          }
          offset = next;
        }
        flushSegment();
      }
      return ranges;
    }
  };

  global.fushiReaderVnRangeMap = {
    create: function(reader) {
      return new ReaderVnRangeMap(reader);
    }
  };
})(window);

window.fushiReader = {
  revealSpeed: C.vnRevealSpeed,
  screenMode: C.vnScreenMode,
  sentencesPerScreen: C.vnSentencesPerScreen,
  preserveDialogue: C.vnPreserveDialogue,
  mergeCrossScreenSentenceAudioCues: C.vnMergeCrossScreenSentenceAudioCues,
  initialSentenceAudioCues: C.sentenceAudioCues,
  initialProgress: C.initialProgress,
  initialFragment: C.initialFragment,
  initialHighlights: [],
  nativeSelectionActive: false,
  activeCueId: null,
  sentenceAudioCues: [],
  sentenceAudioCueMap: new Map(),
  sentenceAudioCuesSignature: null,
  cueWrappers: new Map(),
  cueSourceRanges: new Map(),
  cueGeometryRanges: new Map(),
  nodeStartOffsets: new WeakMap(),
  nodeStartRawOffsets: new WeakMap(),
  contentStream: null,
  rangeMap: null,
  sentenceDelimiters: '。！？.!?',
  totalChapterChars: 0,
  currentScreenIndex: 0,
  revealComplete: true,
  revealTimer: null,
  revealSegments: [],
  revealCursor: 0,
  readyPromise: null,

  isVertical: function() {
    var targets = [
      this.screen,
      document.querySelector('.fushi-vn-content'),
      this.stage,
      document.body,
      document.documentElement
    ];
    for (var i = 0; i < targets.length; i++) {
      var target = targets[i];
      if (!target) continue;
      var writingMode = window.getComputedStyle(target).writingMode || '';
      if (writingMode.indexOf('vertical') === 0) return true;
    }
    return this.readerCssVariable('--fushi-reader-vertical-writing') === '1';
  },
  readerCssVariable: function(name) {
    return window.getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  },
  isEInkMode: function() {
    return this.readerCssVariable('--fushi-reader-eink-mode') === '1';
  },
  isFurigana: function(node) {
    var el = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return !!(el && el.closest('rt, rp'));
  },
  isIgnoredElement: function(node) {
    var el = node && node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return !!(el && el.closest('rt, rp, script, style'));
  },
  isDiscardedCloneElement: function(node) {
    var el = node && node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return !!(el && el.closest('script, style'));
  },
  isUnrevealed: function(node) {
    var el = node && node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    return !!(el && el.closest('[data-fushi-visual-novel-unrevealed]'));
  },
  textSemantics: function() {
    if (!window.fushiReaderTextSemantics) {
      throw new Error('fushiReaderTextSemantics is required for reader text semantics');
    }
    return window.fushiReaderTextSemantics;
  },
  normalizeText: function(text) {
    return this.textSemantics().normalizeText(text);
  },
  countChars: function(text) {
    return this.textSemantics().countChars(text);
  },
  countRawChars: function(text) {
    return this.textSemantics().countRawChars(text);
  },
  isMatchableChar: function(char) {
    return this.textSemantics().isMatchableChar(char);
  },
  createWalker: function(rootNode) {
    var root = rootNode || this.screen || document.body;
    return document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => {
        if (this.isIgnoredElement(n) || this.isUnrevealed(n)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
  },
  getRect: function(target) {
    var rect = target.getClientRects()[0];
    return rect || target.getBoundingClientRect();
  },
  notifyRestoreComplete: function() {
    // Hibiki adaptation: hoshi a posts to a native @JavascriptInterface
    // (FushiReaderRestore). Hibiki is InAppWebView, so forward to the same
    // 'onRestoreComplete' handler the paginated/continuous shells use.
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler(
        'onRestoreComplete',
        null,
        C.navigationGeneration
      );
    }
  },
  buildNodeOffsets: function() {
    var offsets = new WeakMap();
    var rawOffsets = new WeakMap();
    var walker = this.createWalker();
    var currentScreen = this.screens && this.screens[this.currentScreenIndex];
    var fallbackCount = currentScreen ? this.screenStartCharCount(currentScreen) : 0;
    var fallbackRawCount = currentScreen ? this.screenStartRawCount(currentScreen) : 0;
    var node;
    while (node = walker.nextNode()) {
      var mappedCount = this.rangeMap.cloneTextOffsetForNode(node);
      var mappedRawCount = this.rangeMap.cloneTextRawOffsetForNode(node);
      var startCount = mappedCount !== undefined ? mappedCount : fallbackCount;
      var startRawCount = mappedRawCount !== undefined ? mappedRawCount : fallbackRawCount;
      offsets.set(node, startCount);
      rawOffsets.set(node, startRawCount);
      fallbackCount = startCount + this.countChars(node.textContent);
      fallbackRawCount = startRawCount + this.countRawChars(node.textContent);
    }
    this.nodeStartOffsets = offsets;
    this.nodeStartRawOffsets = rawOffsets;
  },
  waitForImages: function() {
    var images = this.sourceRoot && this.sourceRoot.querySelectorAll
      ? Array.from(this.sourceRoot.querySelectorAll('img'))
      : [];
    var promises = images.map(function(img) {
      return new Promise(function(resolve) {
        if (img.complete) {
          resolve();
          return;
        }
        img.onload = function() { resolve(); };
        img.onerror = function() { resolve(); };
      });
    });
    return Promise.all(promises);
  },
  initialize: function() {
    if (this.readyPromise) return this.readyPromise;
    this.readyPromise = Promise.resolve(document.fonts && document.fonts.ready)
      .then(() => {
        this.detachChapterSource();
        return this.waitForImages();
      })
      .then(() => {
        // BUG-1688：视口 meta 必须最先落地。缺了它 WKWebView 按 980 CSS px 布局再
        // 缩放，文档的 CSS 像素空间与 Dart 逻辑像素空间差 ~2.6 倍（iOS 实测
        // innerWidth=980 vs dartPageWidth=375），下面写进去的 px 全是错单位。
        this.applyViewportMeta();
        // 几何变量必须在建舞台/量屏之前落地——`fitScreensToViewport` 是按当前
        // `.fushi-vn-screen` 盒切屏的，晚一步就会先按错的盒切一遍。
        this.applyViewportVars();
        this.ensureStage();
        this.applyImageMaxVars();
        this.buildSourceIndexes();
        this.setSentenceAudioCueData(this.initialSentenceAudioCues);
        this.buildScreens();
        this.renderInitialScreen();
        this.notifyRestoreComplete();
      })
      .catch((error) => {
        // TODO-1085 (BUG-513): notifyRestoreComplete is the ONLY signal that
        // clears the Dart-side loading mask (reader_fushi_page.dart's
        // `if (!_readerContentReady) Positioned.fill(ColoredBox)`). It is the
        // last statement of the happy path AND every restore method awaits this
        // same readyPromise, so a reject anywhere in the chain (buildSourceIndexes
        // / buildScreens / renderInitialScreen throwing on odd chapter markup)
        // silently swallows the notify -> the mask hangs until the 8s content
        // -ready timeout fallback. Fail-open: still fire notifyRestoreComplete so
        // the mask is released (degrades to empty/partial screen, never a
        // permanent black cover).
        try {
          if (window.console && console.error) {
            console.error('[FushiVN] initialize failed', error);
          }
        } catch (_ignored) {}
        this.notifyRestoreComplete();
      });
    return this.readyPromise;
  },
  ensureReady: function() {
    return this.readyPromise || this.initialize();
  },
  detachChapterSource: function() {
    if (this.sourceRoot) return;
    this.sourceRoot = document.createElement('div');
    var children = Array.from(document.body.childNodes);
    for (var i = 0; i < children.length; i++) {
      this.sourceRoot.appendChild(children[i]);
    }
    if (document.body.replaceChildren) {
      document.body.replaceChildren();
    } else {
      while (document.body.firstChild) document.body.removeChild(document.body.firstChild);
    }
  },
  applyViewportMeta: function() {
$sharedInitViewport
  },
  applyViewportVars: function() {
    // BUG-1688：VN 舞台的可用盒由 `_vnLayoutCss` 写成
    // `padding-top: calc(<margin>vh + var(--chrome-top-inset, 0px))`，量尺
    // `createScreenMeasurement` 又读 `--page-width / --page-height`。这四个变量原先
    // **只有**分页/连续 shell 的 `initialize` 会写（reader_pagination_scripts.dart
    // 的 `--chrome-*-inset` / `--page-*`），VN 从来不写 → 全部落到 0px / 100vw /
    // 100vh 兜底：舞台按整个视口排版、量尺比真实屏大出整条 chrome 预留带，于是每屏
    // 首尾行都被顶栏/底栏盖住（iOS 上还要再叠刘海与 home indicator，所以最严重）。
    // 这里与分页 shell 用同一份 C 字段、同一组变量名对齐，VN 不再自成一套几何。
    var root = document.documentElement;
    if (!root || !root.style) return;
    root.style.setProperty('--chrome-top-inset', (Number(C.chromeTopInset) || 0) + 'px');
    root.style.setProperty('--chrome-bottom-inset', (Number(C.chromeBottomInset) || 0) + 'px');
    var pageWidth = Number(C.dartPageWidth) || window.innerWidth || 0;
    var pageHeight = Number(C.dartPageHeight) || window.innerHeight || 0;
    if (pageWidth > 0) root.style.setProperty('--page-width', pageWidth + 'px');
    if (pageHeight > 0) {
      root.style.setProperty('--page-height', pageHeight + 'px');
      root.style.setProperty('--reader-viewport-height', pageHeight + 'px');
    }
  },
  ensureStage: function() {
    if (this.stage && this.screen) return;
    this.stage = document.createElement('div');
    this.stage.className = 'fushi-vn-stage';
    this.screen = document.createElement('div');
    this.screen.className = 'fushi-vn-screen';
    this.stage.appendChild(this.screen);
    document.body.appendChild(this.stage);
  },
  applyImageMaxVars: function() {
    // TODO-1085 (BUG-513): the shared reader image CSS
    // (reader_content_styles.dart: `img.block-img`, `img:not(.block-img)`, `svg`)
    // sizes images against `--fushi-image-max-width` / `--fushi-image-max-height`.
    // The paginated/continuous shell sets those vars in initialize/updatePageSize
    // from its content-box; the VN shell never did, so they stayed at the CSS
    // fallbacks (`95vw` / `calc(--page-height - 22px)`). Combined with a
    // never-promoted `<img>` (see setupReaderImages) that collapses inside the
    // shrink-to-fit `.fushi-vn-content` flex item, VN images rendered tiny. Set
    // the vars to the actual VN viewport so a promoted `.block-img` fills the
    // screen the same way it does in paginated mode.
    var root = document.documentElement;
    if (!root || !root.style) return;
    var ratio = $imageWidthRatio;
    // BUG-1688：「实际 VN 视口」就是 `.fushi-vn-screen` 这个盒——它已扣掉 chrome
    // 预留带与用户边距。原来读 window.innerWidth/Height（整个视口）会把插图算到
    // 能盖住顶栏/底栏的尺寸。取不到盒时才回退整视口（首屏极早期调用）。
    var screenBox = this.screen && this.screen.getBoundingClientRect
      ? this.screen.getBoundingClientRect()
      : null;
    var vw = Math.max(1, (screenBox && screenBox.width) || window.innerWidth || 0);
    var vh = Math.max(1, (screenBox && screenBox.height) || window.innerHeight || 0);
    root.style.setProperty('--fushi-image-max-width', Math.max(1, Math.floor(vw * ratio)) + 'px');
    root.style.setProperty('--fushi-image-max-height', vh + 'px');
  },
  buildSourceIndexes: function() {
    var contentStreamFactory = window.fushiReaderVnContentStream && window.fushiReaderVnContentStream.create;
    if (!contentStreamFactory) {
      throw new Error('fushiReaderVnContentStream is required for visual novel reader');
    }
    var rangeMapFactory = window.fushiReaderVnRangeMap && window.fushiReaderVnRangeMap.create;
    if (!rangeMapFactory) {
      throw new Error('fushiReaderVnRangeMap is required for visual novel reader');
    }
    this.contentStream = contentStreamFactory(this.sourceRoot);
    this.rangeMap = rangeMapFactory(this);
    this.totalChapterChars = this.contentStream.totalMatchableChars;
  },
  buildScreens: function() {
    var mode = String(this.screenMode || '').toLowerCase();
    var baseScreens;
    if (mode === 'sentence' || mode === 'sentences') {
      baseScreens = this.buildSentenceScreens();
    } else {
      baseScreens = this.buildBlockScreens();
    }
    // BUG-1244：纯图片 screen 没有字符范围。有声书逐句跟随按 cue 字符偏移直接跳到
    // 下一条文字 screen 时会永久略过这种零宽 screen，图片在整次自动播放里都不可见。
    // 把连续的前导图片附到下一句/下一块一起渲；章尾没有下一句时附到上一屏，保证媒体
    // 至少随相邻文字出现一次。
    baseScreens = this.attachMediaScreensToAdjacentText(baseScreens);
    this.baseScreens = baseScreens;
    this.screens = this.mergeSentenceAudioCrossScreenScreens(baseScreens);
    if (!this.screens.length) {
      this.screens.push(this.screenDescriptor({
        startCharCount: 0,
        endCharCount: 0,
        startRawCount: 0,
        endRawCount: 0,
        ids: new Set(),
        splittable: false,
        render: () => document.createDocumentFragment()
      }));
    }
    this.screens = this.fitScreensToViewport(this.screens);
    this.assignScreenProgressAnchors();
  },
  screenDescriptor: function(options) {
    var source = options || {};
    var startChar = this.normalizedScreenCount(source.startCharCount, 0);
    var endChar = Math.max(startChar, this.normalizedScreenCount(source.endCharCount, startChar));
    var startRaw = this.normalizedScreenCount(source.startRawCount, 0);
    var endRaw = Math.max(startRaw, this.normalizedScreenCount(source.endRawCount, startRaw));
    var render = typeof source.render === 'function'
      ? source.render
      : function() { return document.createDocumentFragment(); };
    return {
      standalone: !!source.standalone,
      order: source.order,
      preorder: source.preorder,
      startCharCount: startChar,
      endCharCount: endChar,
      startRawCount: startRaw,
      endRawCount: endRaw,
      progressAnchor: Number.isFinite(Number(source.progressAnchor)) ? Number(source.progressAnchor) : null,
      ids: source.ids instanceof Set ? new Set(source.ids) : new Set(source.ids || []),
      splittable: !!source.splittable,
      mediaStop: !!source.mediaStop,
      render: render
    };
  },
  attachMediaScreensToAdjacentText: function(screens) {
    if (!Array.isArray(screens) || !screens.length) return screens || [];
    var result = [];
    var pendingMedia = [];
    for (var i = 0; i < screens.length; i++) {
      var screen = screens[i];
      var mediaOnly = !!screen.mediaStop &&
        this.screenStartCharCount(screen) === this.screenEndCharCount(screen);
      if (mediaOnly) {
        pendingMedia.push(screen);
        continue;
      }
      if (pendingMedia.length) {
        result.push(this.mergeAdjacentScreenParts(pendingMedia.concat([screen])));
        pendingMedia = [];
      } else {
        result.push(screen);
      }
    }
    if (pendingMedia.length) {
      if (result.length) {
        var previous = result.pop();
        result.push(this.mergeAdjacentScreenParts([previous].concat(pendingMedia)));
      } else {
        result.push(this.mergeAdjacentScreenParts(pendingMedia));
      }
    }
    return result;
  },
  mergeAdjacentScreenParts: function(parts) {
    var first = parts[0];
    var last = parts[parts.length - 1];
    var ids = new Set();
    parts.forEach(function(part) {
      (part.ids || new Set()).forEach(function(id) { ids.add(id); });
    });
    return this.screenDescriptor({
      startCharCount: this.screenStartCharCount(first),
      endCharCount: parts.reduce(function(max, part) {
        return Math.max(max, this.screenEndCharCount(part));
      }.bind(this), this.screenEndCharCount(first)),
      startRawCount: this.screenStartRawCount(first),
      endRawCount: parts.reduce(function(max, part) {
        return Math.max(max, this.screenEndRawCount(part));
      }.bind(this), this.screenEndRawCount(last)),
      ids: ids,
      splittable: false,
      mediaStop: true,
      render: function() {
        var fragment = document.createDocumentFragment();
        parts.forEach(function(part) { fragment.appendChild(part.render()); });
        return fragment;
      }
    });
  },
  normalizedScreenCount: function(value, fallback) {
    var parsed = Number(value);
    if (!Number.isFinite(parsed)) return fallback;
    return Math.max(0, parsed);
  },
  screenStartCharCount: function(screen) {
    return this.normalizedScreenCount(screen && screen.startCharCount, 0);
  },
  screenEndCharCount: function(screen) {
    return Math.max(this.screenStartCharCount(screen), this.normalizedScreenCount(screen && screen.endCharCount, this.screenStartCharCount(screen)));
  },
  screenStartRawCount: function(screen) {
    return this.normalizedScreenCount(screen && screen.startRawCount, 0);
  },
  screenEndRawCount: function(screen) {
    return Math.max(this.screenStartRawCount(screen), this.normalizedScreenCount(screen && screen.endRawCount, this.screenStartRawCount(screen)));
  },
  screenIds: function(screen) {
    return screen && screen.ids instanceof Set ? screen.ids : new Set();
  },
  screenContainsFragment: function(screen, fragment) {
    return this.screenIds(screen).has(fragment);
  },
  screenContainsCharOffset: function(screen, offset) {
    var start = this.screenStartCharCount(screen);
    var end = this.screenEndCharCount(screen);
    return offset >= start && offset < end;
  },
  screenIntersectsCharRange: function(screen, start, end) {
    var screenStart = this.screenStartCharCount(screen);
    var screenEnd = this.screenEndCharCount(screen);
    if (end <= start) return start >= screenStart && start <= screenEnd;
    return end > screenStart && start < screenEnd;
  },
  assignScreenProgressAnchors: function() {
    if (!this.screens || !this.screens.length) return;
    if (!this.totalChapterChars) {
      var denominator = Math.max(1, this.screens.length - 1);
      for (var emptyIndex = 0; emptyIndex < this.screens.length; emptyIndex++) {
        this.screens[emptyIndex].progressAnchor = this.screens.length === 1 ? 0 : emptyIndex / denominator;
      }
      return;
    }
    var index = 0;
    var previousAnchor = 0;
    var hasPreviousAnchor = false;
    while (index < this.screens.length) {
      var runStart = index;
      var endChar = this.screenEndCharCount(this.screens[index]);
      index += 1;
      while (index < this.screens.length && this.screenEndCharCount(this.screens[index]) === endChar) {
        index += 1;
      }
      var runEnd = index;
      var count = runEnd - runStart;
      var baseProgress = this.progressForCharCount(endChar);
      var nextProgress = runEnd < this.screens.length
        ? this.progressForCharCount(this.screenEndCharCount(this.screens[runEnd]))
        : 1;
      var previous = hasPreviousAnchor ? previousAnchor : 0;
      var anchors = this.progressAnchorsForScreenRun(
        count,
        baseProgress,
        previous,
        nextProgress,
        runStart === 0,
      );
      for (var runIndex = 0; runIndex < count; runIndex++) {
        var anchor = Math.min(1, Math.max(0, anchors[runIndex]));
        this.screens[runStart + runIndex].progressAnchor = anchor;
        previousAnchor = anchor;
        hasPreviousAnchor = true;
      }
    }
  },
  progressForCharCount: function(charCount) {
    if (!this.totalChapterChars) return 0;
    return Math.min(1, Math.max(0, this.normalizedScreenCount(charCount, 0) / this.totalChapterChars));
  },
  progressAnchorsForScreenRun: function(count, baseProgress, previousProgress, nextProgress, startsChapter) {
    if (count <= 1) return [baseProgress];
    var anchors = [];
    if (nextProgress <= baseProgress && baseProgress > previousProgress) {
      var trailingStep = (baseProgress - previousProgress) / count;
      for (var trailingIndex = 0; trailingIndex < count; trailingIndex++) {
        anchors.push(previousProgress + trailingStep * (trailingIndex + 1));
      }
      return anchors;
    }
    if (baseProgress > previousProgress || startsChapter) {
      anchors.push(baseProgress);
      var gap = Math.max(0, nextProgress - baseProgress);
      var step = gap / count;
      for (var afterBaseIndex = 1; afterBaseIndex < count; afterBaseIndex++) {
        anchors.push(baseProgress + step * afterBaseIndex);
      }
      return anchors;
    }
    var duplicateStep = Math.max(0, nextProgress - previousProgress) / (count + 1);
    for (var duplicateIndex = 0; duplicateIndex < count; duplicateIndex++) {
      anchors.push(previousProgress + duplicateStep * (duplicateIndex + 1));
    }
    return anchors;
  },
  screenProgressAnchor: function(screen) {
    var anchor = Number(screen && screen.progressAnchor);
    if (Number.isFinite(anchor)) return Math.min(1, Math.max(0, anchor));
    return this.progressForCharCount(this.screenEndCharCount(screen));
  },
  progressForScreen: function(screen) {
    return this.screenProgressAnchor(screen);
  },
  mergeSentenceAudioCrossScreenScreens: function(screens) {
    if (!this.mergeCrossScreenSentenceAudioCues || !Array.isArray(screens) || screens.length < 2) return screens || [];
    if (!Array.isArray(this.sentenceAudioCues) || !this.sentenceAudioCues.length) return screens;
    var cues = [];
    for (var cueIndex = 0; cueIndex < this.sentenceAudioCues.length; cueIndex++) {
      var cue = this.sentenceAudioCueForInput(this.sentenceAudioCues[cueIndex]);
      if (cue) cues.push(cue);
    }
    if (!cues.length) return screens;
    cues.sort((a, b) => {
      var startDelta = this.sentenceAudioCueStart(a) - this.sentenceAudioCueStart(b);
      if (startDelta !== 0) return startDelta;
      return this.sentenceAudioCueEnd(a) - this.sentenceAudioCueEnd(b);
    });
    var intervals = [];
    var searchStart = 0;
    for (var i = 0; i < cues.length; i++) {
      var cue = cues[i];
      var first = -1;
      var last = -1;
      var cueStart = this.sentenceAudioCueStart(cue);
      var cueEnd = this.sentenceAudioCueEnd(cue);
      var zeroLengthCue = cueEnd <= cueStart;
      while (searchStart < screens.length) {
        var screenEnd = this.screenEndCharCount(screens[searchStart]);
        if (zeroLengthCue) {
          if (cueStart <= screenEnd) break;
        } else if (cueEnd > this.screenStartCharCount(screens[searchStart])) {
          if (cueStart < screenEnd) break;
        }
        searchStart += 1;
      }
      for (var screenIndex = searchStart; screenIndex < screens.length; screenIndex++) {
        var screen = screens[screenIndex];
        var screenStart = this.screenStartCharCount(screen);
        var screenEnd = this.screenEndCharCount(screen);
        if (!this.sentenceAudioCueIntersectsScreen(cue, screen)) {
          if (zeroLengthCue ? cueStart < screenStart : cueEnd <= screenStart) break;
          continue;
        }
        if (first < 0) first = screenIndex;
        last = screenIndex;
        if (zeroLengthCue) {
          if (cueStart < screenEnd) break;
        } else if (cueEnd <= screenEnd) {
          break;
        }
      }
      if (first < 0 || last <= first) continue;
      var canMerge = true;
      for (var mergeIndex = first; mergeIndex <= last; mergeIndex++) {
        if (!screens[mergeIndex].splittable) {
          canMerge = false;
          break;
        }
      }
      if (canMerge) intervals.push({ start: first, end: last });
    }
    if (!intervals.length) return screens;
    intervals.sort(function(a, b) {
      if (a.start !== b.start) return a.start - b.start;
      return a.end - b.end;
    });
    var mergedIntervals = [];
    for (var intervalIndex = 0; intervalIndex < intervals.length; intervalIndex++) {
      var interval = intervals[intervalIndex];
      var current = mergedIntervals[mergedIntervals.length - 1];
      if (current && interval.start <= current.end) {
        current.end = Math.max(current.end, interval.end);
      } else {
        mergedIntervals.push({ start: interval.start, end: interval.end });
      }
    }
    var result = [];
    var cursor = 0;
    for (var mergedIndex = 0; mergedIndex < mergedIntervals.length; mergedIndex++) {
      var merged = mergedIntervals[mergedIndex];
      while (cursor < merged.start) {
        result.push(screens[cursor]);
        cursor += 1;
      }
      result.push(this.mergeScreenRange(screens, merged.start, merged.end));
      cursor = merged.end + 1;
    }
    while (cursor < screens.length) {
      result.push(screens[cursor]);
      cursor += 1;
    }
    return result;
  },
  mergeScreenRange: function(screens, start, end) {
    var parts = screens.slice(start, end + 1);
    var ids = new Set();
    parts.forEach(function(screen) {
      (screen.ids || new Set()).forEach(function(id) { ids.add(id); });
    });
    var first = parts[0];
    var last = parts[parts.length - 1];
    return this.screenDescriptor({
      startCharCount: this.screenStartCharCount(first),
      endCharCount: parts.reduce(function(max, screen) {
        return Math.max(max, this.screenEndCharCount(screen));
      }.bind(this), this.screenEndCharCount(first)),
      startRawCount: this.screenStartRawCount(first),
      endRawCount: parts.reduce(function(max, screen) {
        return Math.max(max, this.screenEndRawCount(screen));
      }.bind(this), this.screenEndRawCount(last)),
      ids: ids,
      splittable: true,
      mediaStop: parts.some(function(screen) { return !!screen.mediaStop; }),
      render: () => {
        var fragment = document.createDocumentFragment();
        parts.forEach(function(screen) {
          fragment.appendChild(screen.render());
        });
        return fragment;
      }
    });
  },
  fitScreensToViewport: function(screens) {
    if (!screens || !screens.length || !this.stage || !this.screen) return screens || [];
    var measurement = this.createScreenMeasurement();
    if (!measurement) return screens;
    var fitted = [];
    try {
      for (var i = 0; i < screens.length; i++) {
        var screen = screens[i];
        if (!screen.splittable || this.measureScreenFits(screen, measurement)) {
          fitted.push(screen);
          continue;
        }
        var splitScreens = this.splitScreenToViewport(screen, measurement);
        if (splitScreens.length) {
          fitted = fitted.concat(splitScreens);
        } else {
          fitted.push(screen);
        }
      }
    } finally {
      if (measurement.root && measurement.root.parentNode) {
        measurement.root.parentNode.removeChild(measurement.root);
      }
    }
    return fitted.length ? fitted : screens;
  },
  createScreenMeasurement: function() {
    if (!this.stage || !this.screen || !document.createRange) return null;
    var root = document.createElement('div');
    root.className = 'fushi-vn-screen';
    root.setAttribute('aria-hidden', 'true');
    root.style.position = 'fixed';
    root.style.zIndex = '-1';
    root.style.opacity = '0';
    root.style.pointerEvents = 'none';
    // BUG-1688：量尺必须是真实 `.fushi-vn-screen` 的镜像。原来它固定在 (0,0) 并用
    // `var(--page-width, 100vw) / var(--page-height, 100vh)` 撑开——VN 下这两个变量
    // 从没人写（见 applyViewportVars），恒取 100vw/100vh 整视口，比真实屏盒大出整条
    // chrome 预留带。于是 `measureScreenFits` 判「装得下」的屏，渲到真实盒里首尾行
    // 正好落在被顶栏/底栏覆盖的区域——每一屏都如此，这就是 VN 不可用的直接成因。
    // `.fushi-vn-screen` 是 border-box，把 rect 的宽高原样搬过来即得同一个内容盒。
    var screenBox = this.screen && this.screen.getBoundingClientRect
      ? this.screen.getBoundingClientRect()
      : null;
    if (screenBox && screenBox.width > 0 && screenBox.height > 0) {
      root.style.left = screenBox.left + 'px';
      root.style.top = screenBox.top + 'px';
      root.style.width = screenBox.width + 'px';
      root.style.height = screenBox.height + 'px';
    } else {
      root.style.left = '0';
      root.style.top = '0';
      root.style.width = 'var(--page-width, 100vw)';
      root.style.height = 'var(--page-height, 100vh)';
    }
    var content = document.createElement('div');
    content.className = 'fushi-vn-content';
    root.appendChild(content);
    this.stage.appendChild(root);
    return { root: root, content: content };
  },
  measureScreenFits: function(screen, measurement) {
    if (!screen || !measurement || !measurement.content) return true;
    if (measurement.content.replaceChildren) {
      measurement.content.replaceChildren();
    } else {
      while (measurement.content.firstChild) measurement.content.removeChild(measurement.content.firstChild);
    }
    measurement.content.appendChild(screen.render());
    if (this.measurementScrollFits(measurement)) return true;
    var bounds = this.measurementBounds(measurement);
    if (!bounds) return true;
    return this.renderedTextFitsBounds(measurement.content, bounds);
  },
  measurementScrollFits: function(measurement) {
    var root = measurement && measurement.root;
    var content = measurement && measurement.content;
    if (!root || !content) return false;
    var rootWidth = Number(root.clientWidth) || Number(root.offsetWidth) || 0;
    var rootHeight = Number(root.clientHeight) || Number(root.offsetHeight) || 0;
    var contentWidth = Number(content.clientWidth) || Number(content.offsetWidth) || rootWidth;
    var contentHeight = Number(content.clientHeight) || Number(content.offsetHeight) || rootHeight;
    var width = rootWidth && contentWidth ? Math.min(rootWidth, contentWidth) : rootWidth || contentWidth;
    var height = rootHeight && contentHeight ? Math.min(rootHeight, contentHeight) : rootHeight || contentHeight;
    var scrollWidth = Number(content.scrollWidth) || 0;
    var scrollHeight = Number(content.scrollHeight) || 0;
    if (!width || !height || !scrollWidth || !scrollHeight) return false;
    var tolerance = 1;
    return scrollWidth <= width + tolerance && scrollHeight <= height + tolerance;
  },
  measurementBounds: function(measurement) {
    var content = measurement && measurement.content;
    if (!content || !content.getBoundingClientRect) return null;
    var bounds = content.getBoundingClientRect();
    if (!bounds || (!bounds.width && !bounds.height)) {
      bounds = {
        left: 0,
        top: 0,
        right: window.innerWidth || 0,
        bottom: window.innerHeight || 0,
        width: window.innerWidth || 0,
        height: window.innerHeight || 0
      };
    }
    if (!bounds.width && !bounds.height) return null;
    if (measurement.root && measurement.root.getBoundingClientRect) {
      var rootBounds = measurement.root.getBoundingClientRect();
      if (rootBounds && (rootBounds.width || rootBounds.height)) {
        if (this.isVertical()) {
          bounds = {
            left: bounds.left,
            right: bounds.right,
            top: rootBounds.top,
            bottom: rootBounds.bottom,
            width: bounds.width,
            height: rootBounds.bottom - rootBounds.top
          };
        } else {
          bounds = {
            left: rootBounds.left,
            right: rootBounds.right,
            top: bounds.top,
            bottom: bounds.bottom,
            width: rootBounds.right - rootBounds.left,
            height: bounds.height
          };
        }
      }
    }
    return bounds;
  },
  renderedTextFitsBounds: function(root, bounds) {
    var walker = this.createWalker(root);
    var range = document.createRange();
    var tolerance = 1;
    var node;
    while (node = walker.nextNode()) {
      if (!(node.textContent || '').trim()) continue;
      range.selectNodeContents(node);
      var rects = Array.from(range.getClientRects ? range.getClientRects() : []);
      for (var i = 0; i < rects.length; i++) {
        var rect = rects[i];
        if (!rect || (!rect.width && !rect.height)) continue;
        if (!this.rectFitsBounds(rect, bounds, tolerance)) {
          if (range.detach) range.detach();
          return false;
        }
      }
    }
    if (range.detach) range.detach();
    return true;
  },
  rectFitsBounds: function(rect, bounds, tolerance) {
    return rect.left >= bounds.left - tolerance &&
      rect.right <= bounds.right + tolerance &&
      rect.top >= bounds.top - tolerance &&
      rect.bottom <= bounds.bottom + tolerance;
  },
  splitScreenToViewport: function(screen, measurement) {
    var items = this.textItemsForScreen(screen);
    if (!items.length) return [];
    var units = this.viewportSplitUnitsForItems(items);
    if (!units.length) return [];
    var result = [];
    var start = 0;
    while (start < units.length) {
      var low = start + 1;
      var high = units.length;
      var best = -1;
      while (low <= high) {
        var mid = Math.floor((low + high) / 2);
        var candidateItems = this.textItemsFromViewportUnits(units, start, mid);
        var candidate = this.screenFromTextItems(candidateItems, 0, candidateItems.length, screen.ids);
        if (this.measureScreenFits(candidate, measurement)) {
          best = mid;
          low = mid + 1;
        } else {
          high = mid - 1;
        }
      }
      if (best <= start) best = start + 1;
      var splitItems = this.textItemsFromViewportUnits(units, start, best);
      result.push(this.screenFromTextItems(splitItems, 0, splitItems.length, screen.ids));
      start = best;
    }
    return result;
  },
  viewportSplitUnitsForItems: function(items) {
    var units = [];
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      var rubyRoot = item.rubyRoot || (this.contentStream && this.contentStream.rubyRootForTextNode
        ? this.contentStream.rubyRootForTextNode(item.node)
        : null);
      var last = units[units.length - 1];
      if (rubyRoot && last && last.rubyRoot === rubyRoot) {
        last.items.push(item);
      } else {
        units.push({ rubyRoot: rubyRoot, items: [item] });
      }
    }
    return units;
  },
  textItemsFromViewportUnits: function(units, start, end) {
    var result = [];
    for (var i = start; i < end; i++) {
      Array.prototype.push.apply(result, units[i].items);
    }
    return result;
  },
  textItemsForScreen: function(screen) {
    if (!this.viewportFitTextItems) this.viewportFitTextItems = this.buildTextItems();
    var startRaw = this.screenStartRawCount(screen);
    var endRaw = this.screenEndRawCount(screen);
    var items = this.viewportFitTextItems;
    var startIndex = this.lowerBoundTextItemsByRawStart(items, startRaw);
    var result = [];
    for (var i = startIndex; i < items.length; i++) {
      var item = items[i];
      if (item.chapterRawStart >= endRaw) break;
      if (item.chapterRawEnd <= endRaw) result.push(item);
    }
    return result;
  },
  lowerBoundTextItemsByRawStart: function(items, targetRaw) {
    var low = 0;
    var high = items.length;
    while (low < high) {
      var mid = Math.floor((low + high) / 2);
      if (items[mid].chapterRawStart < targetRaw) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  },
  screenFromTextItems: function(items, start, end, baseIds) {
    var slice = items.slice(start, end);
    var ranges = this.rangesFromItems(slice);
    var ids = new Set(baseIds || []);
    ranges.forEach((range) => {
      this.collectIdsForTextNode(range.node).forEach((id) => ids.add(id));
    });
    var first = slice[0];
    return this.screenDescriptor({
      startCharCount: first.chapterCharStart,
      endCharCount: slice.reduce(function(max, item) {
        return Math.max(max, item.chapterCharEnd);
      }, first.chapterCharStart),
      startRawCount: first.chapterRawStart,
      endRawCount: slice.reduce(function(max, item) {
        return Math.max(max, item.chapterRawEnd);
      }, first.chapterRawStart),
      ids: ids,
      splittable: false,
      mediaStop: false,
      render: () => this.cloneRangesWithOffsets(ranges)
    });
  },
  buildBlockScreens: function() {
    var screens = [];
    var runningEnd = 0;
    var runningRawEnd = 0;
    var sources = this.collectBlockScreenSources(this.sourceRoot);
    for (var i = 0; i < sources.length; i++) {
      let child = sources[i].node;
      var stats = this.statsForSourceNode(child);
      var hasStandaloneMedia = this.containsStandaloneMedia(child);
      if (hasStandaloneMedia && this.isMediaOnlySource(child)) {
        var mediaScreens = this.mediaScreensForSourceNode(child, sources[i].extraIds);
        if (mediaScreens.length) {
          screens = screens.concat(mediaScreens);
          continue;
        }
      }
      var start = stats.hasText ? stats.startChar : runningEnd;
      var end = stats.hasText ? stats.endChar : start;
      var rawStart = stats.hasText ? stats.startRaw : runningRawEnd;
      var rawEnd = stats.hasText ? stats.endRaw : rawStart;
      runningEnd = end;
      runningRawEnd = rawEnd;
      screens.push(this.screenDescriptor({
        startCharCount: start,
        endCharCount: end,
        startRawCount: rawStart,
        endRawCount: rawEnd,
        ids: this.collectIdsForNode(child, sources[i].extraIds),
        splittable: stats.hasText && !hasStandaloneMedia,
        mediaStop: hasStandaloneMedia,
        render: () => {
          var fragment = document.createDocumentFragment();
          fragment.appendChild(this.cloneSourceNodeWithOffsets(child));
          return fragment;
        }
      }));
    }
    return screens;
  },
  collectBlockScreenSources: function(root, inheritedIds) {
    var sources = [];
    var pendingIds = new Set(inheritedIds || []);
    var children = Array.from(root.childNodes || []);
    for (var i = 0; i < children.length; i++) {
      var child = children[i];
      if (!this.isRenderableBlockSource(child)) continue;
      if (child.nodeType === Node.ELEMENT_NODE && this.isSplittableBlockContainer(child)) {
        var nestedIds = this.mergeIds(pendingIds, this.ownIdsForNode(child));
        var nested = this.collectBlockScreenSources(child, nestedIds);
        if (nested.length) {
          sources = sources.concat(nested);
          pendingIds = new Set();
          continue;
        }
      }
      sources.push({
        node: child,
        extraIds: new Set(pendingIds)
      });
      pendingIds = new Set();
    }
    return sources;
  },
  isRenderableBlockSource: function(node) {
    if (!node) return false;
    if (node.nodeType === Node.TEXT_NODE) return !!(node.textContent || '').trim();
    if (node.nodeType !== Node.ELEMENT_NODE) return false;
    if (this.isIgnoredElement(node)) return false;
    return !!((node.textContent || '').trim() || this.containsStandaloneMedia(node));
  },
  isSplittableBlockContainer: function(node) {
    if (!node || node.nodeType !== Node.ELEMENT_NODE) return false;
    var tag = String(node.tagName || '').toLowerCase();
    if (['body', 'section', 'article', 'main', 'div'].indexOf(tag) < 0) return false;
    var candidates = this.renderableBlockChildren(node);
    if (candidates.length > 1) return true;
    return candidates.length === 1
      && candidates[0].nodeType === Node.ELEMENT_NODE
      && this.isSplittableBlockContainer(candidates[0]);
  },
  renderableBlockChildren: function(node) {
    var children = Array.from(node.childNodes || []);
    var result = [];
    for (var i = 0; i < children.length; i++) {
      var child = children[i];
      if (!this.isRenderableBlockSource(child)) continue;
      if (child.nodeType === Node.TEXT_NODE) {
        result.push(child);
        continue;
      }
      var tag = String(child.tagName || '').toLowerCase();
      if (this.isBlockScreenElement(tag) || this.isSplittableBlockContainer(child)) {
        result.push(child);
      }
    }
    return result;
  },
  isBlockScreenElement: function(tag) {
    return [
      'address',
      'aside',
      'blockquote',
      'canvas',
      'details',
      'dialog',
      'dl',
      'fieldset',
      'figcaption',
      'figure',
      'footer',
      'form',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'header',
      'hr',
      'iframe',
      'img',
      'li',
      'object',
      'ol',
      'p',
      'picture',
      'pre',
      'section',
      'svg',
      'table',
      'ul',
      'video'
    ].indexOf(tag) >= 0;
  },
  mergeIds: function(first, second) {
    var merged = new Set();
    (first || new Set()).forEach(function(id) { merged.add(id); });
    (second || new Set()).forEach(function(id) { merged.add(id); });
    return merged;
  },
  ownIdsForNode: function(node) {
    var ids = new Set();
    if (node && node.nodeType === Node.ELEMENT_NODE) {
      var id = node.getAttribute && node.getAttribute('id');
      if (id) ids.add(id);
      var name = node.getAttribute && node.getAttribute('name');
      if (name) ids.add(name);
    }
    return ids;
  },
  buildSentenceScreens: function() {
    this.sentenceAtomicRoots = this.buildSentenceAtomicRoots();
    var units = this.buildSentenceUnits()
      .concat(this.buildStandaloneSentenceUnits())
      .sort(function(a, b) {
        if (a.order !== b.order) return a.order - b.order;
        if (a.startRawCount !== b.startRawCount) return a.startRawCount - b.startRawCount;
        return (a.preorder || 0) - (b.preorder || 0);
      });
    var groupSize = this.clampSentenceCount(this.sentencesPerScreen);
    var screens = [];
    var pendingTextUnits = [];
    var flushTextUnits = () => {
      while (pendingTextUnits.length) {
        screens.push(this.screenFromSentenceUnits(pendingTextUnits.splice(0, groupSize)));
      }
    };
    for (var i = 0; i < units.length; i++) {
      var unit = units[i];
      if (unit.standalone) {
        flushTextUnits();
        screens.push(unit);
      } else {
        pendingTextUnits.push(unit);
        if (pendingTextUnits.length >= groupSize) flushTextUnits();
      }
    }
    flushTextUnits();
    return screens;
  },
  screenFromSentenceUnits: function(groupedUnits) {
    let ranges = [];
    let ids = new Set();
    groupedUnits.forEach((unit) => {
      ranges = ranges.concat(unit.ranges);
      unit.ids.forEach((id) => ids.add(id));
    });
    let firstUnit = groupedUnits[0];
    let lastUnit = groupedUnits[groupedUnits.length - 1];
    return this.screenDescriptor({
      startCharCount: firstUnit.startCharCount,
      endCharCount: lastUnit.endCharCount,
      startRawCount: firstUnit.startRawCount,
      endRawCount: lastUnit.endRawCount,
      ids: ids,
      splittable: true,
      mediaStop: groupedUnits.some(function(unit) { return !!unit.mediaStop; }),
      render: () => this.cloneRangesWithOffsets(ranges)
    });
  },
  buildSentenceAtomicRoots: function() {
    var roots = new WeakSet();
    var sources = this.collectBlockScreenSources(this.sourceRoot);
    for (var i = 0; i < sources.length; i++) {
      var source = sources[i].node;
      if (source && source.nodeType === Node.ELEMENT_NODE && this.containsStandaloneMedia(source)) {
        roots.add(source);
      }
    }
    return roots;
  },
  buildStandaloneSentenceUnits: function() {
    var units = [];
    var sources = this.collectBlockScreenSources(this.sourceRoot);
    for (var i = 0; i < sources.length; i++) {
      let child = sources[i].node;
      if (child.nodeType === Node.TEXT_NODE && !(child.textContent || '').trim()) continue;
      if (child.nodeType === Node.ELEMENT_NODE && this.isIgnoredElement(child)) continue;
      var stats = this.statsForSourceNode(child);
      var atomic = this.sentenceAtomicRoots && this.sentenceAtomicRoots.has(child);
      if (!atomic && stats.hasText) continue;
      if (atomic && this.isMediaOnlySource(child)) {
        var mediaUnits = this.mediaScreensForSourceNode(child, sources[i].extraIds);
        if (mediaUnits.length) {
          units = units.concat(mediaUnits);
          continue;
        }
      }
      var position = stats.hasText ? stats : this.sourcePositionForNode(child, i);
      var hasStandaloneMedia = child.nodeType === Node.ELEMENT_NODE && this.containsStandaloneMedia(child);
      units.push(this.screenDescriptor({
        standalone: true,
        order: this.sourceOrderForNode(child),
        preorder: this.sourcePreorderForNode(child),
        startCharCount: position.startChar,
        endCharCount: position.endChar,
        startRawCount: position.startRaw,
        endRawCount: position.endRaw,
        ids: this.collectIdsForNode(child, sources[i].extraIds),
        splittable: false,
        mediaStop: hasStandaloneMedia,
        render: () => {
          var fragment = document.createDocumentFragment();
          fragment.appendChild(this.cloneSourceNodeWithOffsets(child));
          return fragment;
        }
      }));
    }
    return units;
  },
  sourcePositionForNode: function(node, fallbackOrder) {
    var stats = this.statsForSourceNode(node);
    if (stats.hasText) return stats;
    if (this.contentStream && typeof this.contentStream.sourcePositionForNode === 'function') {
      return this.contentStream.sourcePositionForNode(node);
    }
    return { hasText: false, startChar: 0, endChar: 0, startRaw: 0, endRaw: 0 };
  },
  containsStandaloneMedia: function(root) {
    if (this.contentStream && typeof this.contentStream.containsStandaloneMedia === 'function') {
      return this.contentStream.containsStandaloneMedia(root);
    }
    if (!root || root.nodeType !== Node.ELEMENT_NODE) return false;
    var tag = String(root.tagName || '').toLowerCase();
    if (this.isStandaloneMediaTag(tag)) return true;
    return !!(root.querySelector && root.querySelector('img, svg, image, video, canvas, audio, picture, table, iframe, object, embed'));
  },
  isStandaloneMediaTag: function(tag) {
    return [
      'img',
      'svg',
      'image',
      'video',
      'canvas',
      'audio',
      'picture',
      'table',
      'iframe',
      'object',
      'embed'
    ].indexOf(tag) >= 0;
  },
  isMediaOnlySource: function(root) {
    return this.containsStandaloneMedia(root) && !(root && String(root.textContent || '').trim());
  },
  mediaUnitsForSourceNode: function(root) {
    if (!this.contentStream || typeof this.contentStream.mediaUnits !== 'function') return [];
    return this.contentStream.mediaUnits().filter((unit) => this.isDescendantOf(unit.mediaNode || unit.node, root));
  },
  mediaScreensForSourceNode: function(root, extraIds) {
    var units = this.mediaUnitsForSourceNode(root);
    var result = [];
    for (var i = 0; i < units.length; i++) {
      result.push(this.screenFromMediaUnit(units[i], extraIds));
    }
    return result;
  },
  screenFromMediaUnit: function(unit, extraIds) {
    var ids = this.mergeIds(extraIds || new Set(), unit.ids || new Set());
    return this.screenDescriptor({
      standalone: true,
      order: unit.sourceOrder,
      preorder: unit.preorder,
      startCharCount: unit.startChar,
      endCharCount: unit.endChar,
      startRawCount: unit.startRaw,
      endRawCount: unit.endRaw,
      ids: ids,
      splittable: false,
      mediaStop: true,
      render: () => {
        var fragment = document.createDocumentFragment();
        fragment.appendChild(this.cloneMediaUnit(unit));
        return fragment;
      }
    });
  },
  cloneMediaUnit: function(unit) {
    var renderSource = this.renderSourceForMediaUnit(unit);
    if (!unit || renderSource === unit.renderRoot) {
      return this.cloneSourceNodeWithOffsets(renderSource);
    }
    var renderRoot = unit.renderRoot;
    var mediaNode = unit.mediaNode || unit.node;
    var path = [];
    var current = mediaNode;
    while (current && current !== renderRoot) {
      path.unshift(current);
      current = current.parentNode;
    }
    if (!renderRoot || current !== renderRoot) return this.cloneSourceNodeWithOffsets(mediaNode);
    var rootClone = renderRoot.cloneNode ? renderRoot.cloneNode(false) : document.createElement(renderRoot.tagName.toLowerCase());
    var parentClone = rootClone;
    for (var i = 0; i < path.length; i++) {
      var source = path[i];
      if (source === mediaNode) {
        parentClone.appendChild(this.cloneSourceNodeWithOffsets(source));
      } else {
        var clone = source.cloneNode ? source.cloneNode(false) : document.createElement(source.tagName.toLowerCase());
        parentClone.appendChild(clone);
        parentClone = clone;
      }
    }
    return rootClone;
  },
  renderSourceForMediaUnit: function(unit) {
    if (!unit || unit.renderRoot === unit.mediaNode) return unit && unit.renderRoot;
    var units = this.contentStream && typeof this.contentStream.mediaUnits === 'function'
      ? this.contentStream.mediaUnits()
      : [];
    var sharedRootCount = units.filter(function(candidate) {
      return candidate.renderRoot === unit.renderRoot;
    }).length;
    return sharedRootCount <= 1 ? unit.renderRoot : unit.mediaNode;
  },
  buildSentenceUnits: function() {
    var items = this.buildTextItems();
    if (!items.length) return [];
    var units = [];
    var unitStart = 0;
    var dialogueDepth = 0;
    var segmenterBoundaries = this.sentenceSegmenterBoundaryIndexes(items);
    for (var i = 0; i < items.length; i++) {
      var char = items[i].char;
      var split = false;
      if (this.preserveDialogue && (char === '「' || char === '『')) {
        dialogueDepth += 1;
      } else if (this.preserveDialogue && (char === '」' || char === '』')) {
        if (dialogueDepth > 0) dialogueDepth -= 1;
        if (dialogueDepth === 0) split = true;
      } else if (this.sentenceDelimiters.indexOf(char) >= 0 && (!this.preserveDialogue || dialogueDepth === 0)) {
        split = true;
      } else if (!this.preserveDialogue && segmenterBoundaries && segmenterBoundaries.has(i + 1)) {
        split = true;
      }
      if (split) {
        this.pushSentenceUnit(units, items, unitStart, i + 1);
        unitStart = i + 1;
      }
    }
    this.pushSentenceUnit(units, items, unitStart, items.length);
    return units;
  },
  sentenceSegmenterBoundaryIndexes: function(items) {
    if (this.preserveDialogue || typeof Intl === 'undefined' || typeof Intl.Segmenter !== 'function') return null;
    try {
      var text = items.map(function(item) { return item.char; }).join('');
      var segmenter = new Intl.Segmenter(undefined, { granularity: 'sentence' });
      var boundaries = new Set();
      var cursor = 0;
      for (var segment of segmenter.segment(text)) {
        cursor += Array.from(segment.segment || '').length;
        if (cursor > 0) boundaries.add(cursor);
      }
      return boundaries.size ? boundaries : null;
    } catch (_error) {
      return null;
    }
  },
  pushSentenceUnit: function(units, items, start, end) {
    if (start >= end) return;
    var slice = items.slice(start, end);
    var text = slice.map(function(item) { return item.char; }).join('');
    if (!text.trim()) return;
    var ranges = this.rangesFromItems(slice);
    var ids = new Set();
    ranges.forEach((range) => {
      this.collectIdsForTextNode(range.node).forEach((id) => ids.add(id));
    });
    units.push({
      standalone: false,
      ranges: ranges,
      ids: ids,
      order: ranges.reduce(function(min, range) {
        return Math.min(min, range.order);
      }, Number.POSITIVE_INFINITY),
      startCharCount: slice[0].chapterCharStart,
      endCharCount: slice.reduce(function(max, item) {
        return Math.max(max, item.chapterCharEnd);
      }, slice[0].chapterCharStart),
      startRawCount: slice[0].chapterRawStart,
      endRawCount: slice.reduce(function(max, item) {
        return Math.max(max, item.chapterRawEnd);
      }, slice[0].chapterRawStart)
    });
  },
  buildTextItems: function() {
    if (this.contentStream && typeof this.contentStream.textItems === 'function') {
      var streamItems = this.contentStream.textItems();
      return streamItems.filter((item) => !this.isSentenceAtomicTextNode(item.node));
    }
    return [];
  },
  sourceOrderForTextNode: function(node) {
    if (this.contentStream && typeof this.contentStream.sourceOrderForTextNode === 'function') {
      return this.contentStream.sourceOrderForTextNode(node);
    }
    return 0;
  },
  isSentenceAtomicTextNode: function(node) {
    if (!this.sentenceAtomicRoots) return false;
    var current = node;
    while (current && current !== this.sourceRoot) {
      if (this.sentenceAtomicRoots.has(current)) return true;
      current = current.parentNode;
    }
    return false;
  },
  sourceOrderForNode: function(node) {
    if (this.contentStream && typeof this.contentStream.sourceOrderForNode === 'function') {
      return this.contentStream.sourceOrderForNode(node);
    }
    return 0;
  },
  sourcePreorderForNode: function(node) {
    if (this.contentStream && typeof this.contentStream.sourcePreorderForNode === 'function') {
      return this.contentStream.sourcePreorderForNode(node);
    }
    return 0;
  },
  rangesFromItems: function(items) {
    var ranges = [];
    for (var i = 0; i < items.length; i++) {
      var item = items[i];
      var rubyRoot = item.rubyRoot || (this.contentStream && this.contentStream.rubyRootForTextNode
        ? this.contentStream.rubyRootForTextNode(item.node)
        : null);
      if (rubyRoot) {
        var rubyStats = this.statsForSourceNode(rubyRoot);
        var lastRuby = ranges[ranges.length - 1];
        if (lastRuby && lastRuby.rubyRoot === rubyRoot) {
          lastRuby.end = item.end;
          lastRuby.endCharCount = rubyStats.hasText ? rubyStats.endChar : Math.max(lastRuby.endCharCount, item.chapterCharEnd);
          lastRuby.chapterRawEnd = rubyStats.hasText ? rubyStats.endRaw : Math.max(lastRuby.chapterRawEnd, item.chapterRawEnd);
          continue;
        }
        ranges.push({
          node: item.node,
          rubyRoot: rubyRoot,
          order: item.order,
          start: item.start,
          end: item.end,
          chapterCharStart: rubyStats.hasText ? rubyStats.startChar : item.chapterCharStart,
          chapterRawStart: rubyStats.hasText ? rubyStats.startRaw : item.chapterRawStart,
          chapterRawEnd: rubyStats.hasText ? rubyStats.endRaw : item.chapterRawEnd,
          endCharCount: rubyStats.hasText ? rubyStats.endChar : item.chapterCharEnd
        });
        continue;
      }
      var last = ranges[ranges.length - 1];
      if (last && last.node === item.node && last.end === item.start) {
        last.end = item.end;
        last.endCharCount = Math.max(last.endCharCount, item.chapterCharEnd);
        last.chapterRawEnd = Math.max(last.chapterRawEnd, item.chapterRawEnd);
      } else {
        ranges.push({
          node: item.node,
          order: item.order,
          start: item.start,
          end: item.end,
          chapterCharStart: item.chapterCharStart,
          chapterRawStart: item.chapterRawStart,
          chapterRawEnd: item.chapterRawEnd,
          endCharCount: item.chapterCharEnd
        });
      }
    }
    return ranges;
  },
  clampSentenceCount: function(value) {
    var parsed = Number(value);
    if (!Number.isFinite(parsed)) return 1;
    return Math.min(12, Math.max(1, Math.floor(parsed)));
  },
  statsForSourceNode: function(root) {
    if (this.contentStream && typeof this.contentStream.statsForNode === 'function') {
      return this.contentStream.statsForNode(root);
    }
    return { hasText: false, startChar: 0, endChar: 0, startRaw: 0, endRaw: 0 };
  },
  isDescendantOf: function(node, root) {
    var current = node;
    while (current) {
      if (current === root) return true;
      current = current.parentNode;
    }
    return false;
  },
  collectIdsForNode: function(root, extraIds) {
    var ids = new Set(extraIds || []);
    var visit = function(node) {
      if (node.nodeType === Node.ELEMENT_NODE) {
        var id = node.getAttribute && node.getAttribute('id');
        if (id) ids.add(id);
        var name = node.getAttribute && node.getAttribute('name');
        if (name) ids.add(name);
      }
      var children = node.childNodes || [];
      for (var i = 0; i < children.length; i++) visit(children[i]);
    };
    visit(root);
    return ids;
  },
  collectIdsForTextNode: function(node) {
    var ids = new Set();
    var current = node.parentNode;
    while (current && current !== this.sourceRoot) {
      if (current.nodeType === Node.ELEMENT_NODE) {
        var id = current.getAttribute && current.getAttribute('id');
        if (id) ids.add(id);
        var name = current.getAttribute && current.getAttribute('name');
        if (name) ids.add(name);
      }
      current = current.parentNode;
    }
    return ids;
  },
  cloneSourceNodeWithOffsets: function(sourceNode) {
    if (sourceNode.nodeType === Node.TEXT_NODE) {
      var cloneText = document.createTextNode(sourceNode.textContent || '');
      var charOffset = this.sourceTextOffsetForNode(sourceNode);
      var rawOffset = this.sourceTextRawOffsetForNode(sourceNode);
      if (charOffset !== undefined || rawOffset !== undefined) {
        this.rangeMap.registerCloneTextOffset(cloneText, charOffset, rawOffset);
      }
      return cloneText;
    }
    if (sourceNode.nodeType !== Node.ELEMENT_NODE && sourceNode.nodeType !== Node.DOCUMENT_FRAGMENT_NODE) {
      return sourceNode.cloneNode ? sourceNode.cloneNode(true) : document.createTextNode('');
    }
    if (sourceNode.nodeType === Node.ELEMENT_NODE && this.isDiscardedCloneElement(sourceNode)) {
      return document.createDocumentFragment();
    }
    var clone = sourceNode.cloneNode ? sourceNode.cloneNode(false) : document.createElement(sourceNode.tagName.toLowerCase());
    var children = Array.from(sourceNode.childNodes || []);
    for (var i = 0; i < children.length; i++) {
      clone.appendChild(this.cloneSourceNodeWithOffsets(children[i]));
    }
    return clone;
  },
  sourceTextOffsetForNode: function(node) {
    if (!this.contentStream || !this.contentStream.sourceTextOffsets) return undefined;
    return this.contentStream.sourceTextOffsets.get(node);
  },
  sourceTextRawOffsetForNode: function(node) {
    if (!this.contentStream || !this.contentStream.sourceTextRawOffsets) return undefined;
    return this.contentStream.sourceTextRawOffsets.get(node);
  },
  cloneRangesWithOffsets: function(ranges) {
    var fragment = document.createDocumentFragment();
    var cloneMap = new WeakMap();
    var clonePreorder = new WeakMap();
    var clonedRubyRoots = new WeakSet();
    var insertedInlineMedia = new WeakSet();
    var boundsByRoot = [];
    var mediaNodeEntries = null;
    var topLevelSourceNodeFor = (sourceNode) => {
      var current = sourceNode;
      while (current && current.parentNode && current.parentNode !== this.sourceRoot) {
        current = current.parentNode;
      }
      return current || sourceNode;
    };
    var boundsForRoot = (root) => {
      for (var i = 0; i < boundsByRoot.length; i++) {
        if (boundsByRoot[i].root === root) return boundsByRoot[i];
      }
      var bounds = { root: root, min: Number.POSITIVE_INFINITY, max: Number.NEGATIVE_INFINITY, ranges: [] };
      boundsByRoot.push(bounds);
      return bounds;
    };
    var recordRangeBounds = (range) => {
      var sourceNode = range.rubyRoot || range.node;
      if (!sourceNode) return;
      var root = topLevelSourceNodeFor(sourceNode);
      var preorder = this.sourcePreorderForNode(sourceNode);
      var bounds = boundsForRoot(root);
      bounds.min = Math.min(bounds.min, preorder);
      bounds.max = Math.max(bounds.max, preorder);
      bounds.ranges.push(range);
    };
    ranges.forEach(recordRangeBounds);
    var appendCloneInSourceOrder = (parentClone, cloneNode, preorder) => {
      clonePreorder.set(cloneNode, preorder);
      if (parentClone && parentClone.childNodes && parentClone.insertBefore) {
        var children = Array.from(parentClone.childNodes);
        for (var i = 0; i < children.length; i++) {
          var childPreorder = clonePreorder.get(children[i]);
          if (childPreorder !== undefined && childPreorder > preorder) {
            parentClone.insertBefore(cloneNode, children[i]);
            return;
          }
        }
      }
      parentClone.appendChild(cloneNode);
    };
    var ensureElementClone = (sourceElement) => {
      if (cloneMap.has(sourceElement)) return cloneMap.get(sourceElement);
      var clone = sourceElement.cloneNode ? sourceElement.cloneNode(false) : document.createElement(sourceElement.tagName.toLowerCase());
      cloneMap.set(sourceElement, clone);
      var preorder = this.sourcePreorderForNode(sourceElement);
      var parent = sourceElement.parentNode;
      if (!parent || parent === this.sourceRoot) {
        appendCloneInSourceOrder(fragment, clone, preorder);
      } else {
        appendCloneInSourceOrder(ensureElementClone(parent), clone, preorder);
      }
      return clone;
    };
    var appendCloneUnderSourceParent = (sourceNode, cloneNode) => {
      var parent = sourceNode.parentNode;
      var preorder = this.sourcePreorderForNode(sourceNode);
      if (!parent || parent === this.sourceRoot) {
        appendCloneInSourceOrder(fragment, cloneNode, preorder);
      } else {
        appendCloneInSourceOrder(ensureElementClone(parent), cloneNode, preorder);
      }
    };
    var isInlineMediaNodeForRangeClone = (sourceNode, contextRoot) => {
      return !!(
        this.contentStream &&
        typeof this.contentStream.isInlineMediaNode === 'function' &&
        this.contentStream.isInlineMediaNode(sourceNode, contextRoot)
      );
    };
    var appendInlineMediaClone = (sourceNode) => {
      if (insertedInlineMedia.has(sourceNode)) return;
      insertedInlineMedia.add(sourceNode);
      appendCloneUnderSourceParent(sourceNode, this.cloneSourceNodeWithOffsets(sourceNode));
    };
    var hasVisibleTextBetweenPreorder = (root, start, end) => {
      if (this.contentStream && typeof this.contentStream.hasVisibleTextBetweenPreorder === 'function') {
        return this.contentStream.hasVisibleTextBetweenPreorder(root, start, end);
      }
      var found = false;
      var visit = (sourceNode) => {
        if (found || !sourceNode) return;
        if (sourceNode.nodeType === Node.TEXT_NODE) {
          var preorder = this.sourcePreorderForNode(sourceNode);
          if (preorder > start && preorder < end && !this.isIgnoredElement(sourceNode) && String(sourceNode.textContent || '').trim()) {
            found = true;
          }
          return;
        }
        var children = Array.from(sourceNode.childNodes || []);
        for (var i = 0; i < children.length; i++) visit(children[i]);
      };
      visit(root);
      return found;
    };
    var mediaNodesForRangeClone = () => {
      if (mediaNodeEntries !== null) return mediaNodeEntries;
      mediaNodeEntries = this.contentStream && typeof this.contentStream.mediaNodes === 'function'
        ? this.contentStream.mediaNodes()
        : [];
      return mediaNodeEntries;
    };
    var mediaNodeForEntry = (entry) => entry && entry.node ? entry.node : entry;
    var mediaPreorderForEntry = (entry) => {
      var value = Number(entry && entry.preorder);
      if (Number.isFinite(value)) return value;
      return this.sourcePreorderForNode(mediaNodeForEntry(entry));
    };
    var rangeStartsAtSourceBoundary = (bounds) => {
      return bounds.ranges.some((range) => {
        var sourceNode = range.rubyRoot || range.node;
        return this.sourcePreorderForNode(sourceNode) === bounds.min && (range.rubyRoot || range.start <= 0);
      });
    };
    var rangeEndsAtSourceBoundary = (bounds) => {
      return bounds.ranges.some((range) => {
        var sourceNode = range.rubyRoot || range.node;
        var textLength = range.node && range.node.textContent ? range.node.textContent.length : 0;
        return this.sourcePreorderForNode(sourceNode) === bounds.max && (range.rubyRoot || range.end >= textLength);
      });
    };
    var appendInlineMediaForBounds = (bounds) => {
      var entries = mediaNodesForRangeClone();
      if (!entries.length) return;
      var startsAtBoundary = rangeStartsAtSourceBoundary(bounds);
      var endsAtBoundary = rangeEndsAtSourceBoundary(bounds);
      for (var i = 0; i < entries.length; i++) {
        var sourceNode = mediaNodeForEntry(entries[i]);
        if (!sourceNode || !this.isDescendantOf(sourceNode, bounds.root)) continue;
        var preorder = mediaPreorderForEntry(entries[i]);
        var insideRange = preorder > bounds.min && preorder < bounds.max;
        var leadingBoundary = startsAtBoundary &&
          preorder < bounds.min &&
          !hasVisibleTextBetweenPreorder(bounds.root, preorder, bounds.min);
        var trailingBoundary = endsAtBoundary &&
          preorder > bounds.max &&
          !hasVisibleTextBetweenPreorder(bounds.root, bounds.max, preorder);
        if (
          (insideRange || leadingBoundary || trailingBoundary) &&
          isInlineMediaNodeForRangeClone(sourceNode, bounds.root)
        ) {
          appendInlineMediaClone(sourceNode);
        }
      }
    };
    for (var i = 0; i < ranges.length; i++) {
      var range = ranges[i];
      if (range.rubyRoot) {
        if (clonedRubyRoots.has(range.rubyRoot)) continue;
        clonedRubyRoots.add(range.rubyRoot);
        appendCloneUnderSourceParent(range.rubyRoot, this.cloneSourceNodeWithOffsets(range.rubyRoot));
        continue;
      }
      var text = (range.node.textContent || '').slice(range.start, range.end);
      if (!text) continue;
      var cloneText = document.createTextNode(text);
      this.rangeMap.registerCloneTextOffset(cloneText, range.chapterCharStart, range.chapterRawStart);
      var parent = range.node.parentNode;
      if (!parent || parent === this.sourceRoot) {
        appendCloneInSourceOrder(fragment, cloneText, this.sourcePreorderForNode(range.node));
      } else {
        appendCloneInSourceOrder(ensureElementClone(parent), cloneText, this.sourcePreorderForNode(range.node));
      }
    }
    boundsByRoot.forEach((bounds) => {
      if (Number.isFinite(bounds.min) && Number.isFinite(bounds.max)) {
        appendInlineMediaForBounds(bounds);
      }
    });
    return fragment;
  },
  setupReaderImage: function(element, src, wrap, blurElement) {
    return window.fushiReaderMediaSemantics.setupReaderImage(element, src, {
      blurImages: C.blurImages,
      imageBridge: window.FushiReaderImage,
      wrap: wrap,
      blurElement: blurElement
    });
  },
  setupReaderImages: function(root) {
    var scope = root || this.screen;
    // TODO-1085 (BUG-513): the media-semantics stub is a no-op at M0, so cloned
    // VN images never received the `.block-img` class that the shared reader CSS
    // (reader_content_styles.dart) needs to give an image a page-sized centred
    // box. Without it they fell through to `img:not(.block-img){max-width:100%}`,
    // whose 100% resolves against the shrink-to-fit `.fushi-vn-content` flex item
    // and collapses to a few px. Promote large standalone images to `.block-img`
    // (+ `.block-img-wrapper` for centering) exactly like the paginated shell's
    // _sharedInitImages, so `--fushi-image-max-width/height` (set by
    // applyImageMaxVars) drive their size. Gaiji glyph images are left inline.
    this.promoteBlockImages(scope);
    return window.fushiReaderMediaSemantics.setupReaderImages(scope, {
      blurImages: C.blurImages,
      imageBridge: window.FushiReaderImage,
      waitForImages: false
    });
  },
  promoteBlockImages: function(scope) {
    if (!scope || !scope.querySelectorAll) return;
    var svgs = Array.from(scope.querySelectorAll('svg'));
    for (var s = 0; s < svgs.length; s++) {
      var svg = svgs[s];
      if (svg.classList.contains('gaiji') || svg.classList.contains('gaiji-line')) continue;
      if (svg.classList.contains('block-img') || svg.closest('.block-img-wrapper')) continue;
      var svgImage = svg.querySelector('image');
      if (!svgImage) continue;
      if (svg.getAttribute('preserveAspectRatio') === 'none') {
        svg.setAttribute('preserveAspectRatio', 'xMidYMid meet');
      }
      var iw = parseFloat(svgImage.getAttribute('width')) || 0;
      var ih = parseFloat(svgImage.getAttribute('height')) || 0;
      if (iw <= 256 && ih <= 256) {
        var vb = (svg.getAttribute('viewBox') || '').split(/[ ,]+/);
        iw = parseFloat(vb[2]) || iw;
        ih = parseFloat(vb[3]) || ih;
      }
      if (iw > 256 || ih > 256) {
        svg.classList.add('block-img');
        this.wrapBlockImage(svg);
      }
    }
    var imgs = Array.from(scope.querySelectorAll('img'));
    for (var i = 0; i < imgs.length; i++) {
      var img = imgs[i];
      if (img.classList.contains('gaiji') || img.classList.contains('gaiji-line')) continue;
      if (img.classList.contains('block-img') || img.closest('.block-img-wrapper')) continue;
      if ((img.naturalWidth || 0) > 256 || (img.naturalHeight || 0) > 256) {
        img.classList.add('block-img');
        this.wrapBlockImage(img);
      }
    }
  },
  wrapBlockImage: function(element) {
    var parent = element.parentNode;
    if (!parent) return;
    if (parent.classList && parent.classList.contains('block-img-wrapper')) return;
    var wrapper = document.createElement('div');
    wrapper.className = 'block-img-wrapper';
    parent.insertBefore(wrapper, element);
    wrapper.appendChild(element);
  },
  renderInitialScreen: function() {
    var index = 0;
    if (this.initialFragment) {
      var fragmentIndex = this.screenIndexForFragment(this.initialFragment);
      if (fragmentIndex >= 0) index = fragmentIndex;
    } else if (this.initialProgress > 0) {
      index = this.screenIndexForProgress(this.initialProgress);
    }
    this.renderScreen(index, !!this.initialFragment || index !== 0 || this.revealSpeed <= 0 || this.initialProgress > 0);
  },
  renderScreen: function(index, fullyRevealed) {
    if (!this.screens.length) return;
    var safeIndex = Math.min(Math.max(0, index), this.screens.length - 1);
    this.clearRevealTimer();
    this.currentScreenIndex = safeIndex;
    this.clearCurrentSentenceAudioScreenTargets();
    if (this.screen.replaceChildren) {
      this.screen.replaceChildren();
    } else {
      while (this.screen.firstChild) this.screen.removeChild(this.screen.firstChild);
    }
    var content = document.createElement('div');
    content.className = 'fushi-vn-content';
    content.appendChild(this.screens[safeIndex].render());
    this.screen.appendChild(content);
    if (fullyRevealed || this.revealSpeed <= 0) {
      this.revealComplete = true;
    } else {
      this.hideCurrentScreenForReveal();
    }
    this.setupReaderImages(this.screen);
    this.buildNodeOffsets();
    if (this.revealComplete) this.applyCurrentScreenHighlights();
    if (this.revealComplete) this.refreshSentenceAudioCuePresentation();
  },
  hideCurrentScreenForReveal: function() {
    this.revealSegments = [];
    this.revealCursor = 0;
    var walker = this.createWalker();
    var textNodes = [];
    var node;
    while (node = walker.nextNode()) {
      if (node.textContent) textNodes.push(node);
    }
    for (var i = 0; i < textNodes.length; i++) {
      this.prepareTextNodeForReveal(textNodes[i]);
    }
    if (!this.revealSegments.length) {
      this.revealComplete = true;
      return;
    }
    this.revealComplete = false;
    this.scheduleRevealTick();
  },
  prepareTextNodeForReveal: function(node) {
    var parent = node.parentNode;
    if (!parent) return;
    var text = node.textContent || '';
    if (!text) return;
    var charOffset = this.rangeMap.cloneTextOffsetForNode(node);
    var rawOffset = this.rangeMap.cloneTextRawOffsetForNode(node);
    var visible = document.createTextNode('');
    var hidden = document.createElement('span');
    hidden.setAttribute('data-fushi-visual-novel-unrevealed', '');
    hidden.setAttribute('aria-hidden', 'true');
    hidden.appendChild(document.createTextNode(text));
    parent.insertBefore(visible, node);
    parent.insertBefore(hidden, node);
    parent.removeChild(node);
    this.rangeMap.registerCloneTextOffset(visible, charOffset, rawOffset);
    this.revealSegments.push({
      visible: visible,
      hidden: hidden,
      hiddenText: hidden.firstChild,
      chars: Array.from(text),
      revealed: 0
    });
  },
  scheduleRevealTick: function() {
    var speed = Number(this.revealSpeed);
    if (!Number.isFinite(speed) || speed <= 0) {
      this.completeCurrentReveal();
      return;
    }
    var delay = Math.max(1, 1000 / speed);
    this.revealTimer = setTimeout(() => this.revealNextCharacter(), delay);
  },
  revealNextCharacter: function() {
    this.revealTimer = null;
    if (this.revealComplete) return;
    if (!this.revealOneCharacter()) {
      this.completeCurrentReveal();
      return;
    }
    if (this.revealCursor >= this.totalRevealCharacters()) {
      this.completeCurrentReveal();
      return;
    }
    this.scheduleRevealTick();
  },
  revealOneCharacter: function() {
    for (var i = 0; i < this.revealSegments.length; i++) {
      var segment = this.revealSegments[i];
      if (segment.revealed >= segment.chars.length) continue;
      segment.revealed += 1;
      segment.visible.textContent = segment.chars.slice(0, segment.revealed).join('');
      segment.hiddenText.textContent = segment.chars.slice(segment.revealed).join('');
      this.revealCursor += 1;
      return true;
    }
    return false;
  },
  totalRevealCharacters: function() {
    return this.revealSegments.reduce(function(total, segment) {
      return total + segment.chars.length;
    }, 0);
  },
  clearRevealTimer: function() {
    if (this.revealTimer !== null && this.revealTimer !== undefined) {
      clearTimeout(this.revealTimer);
    }
    this.revealTimer = null;
  },
  completeCurrentReveal: function() {
    this.clearRevealTimer();
    this.revealSegments.forEach(function(segment) {
      segment.visible.textContent = segment.chars.join('');
      if (segment.hidden.parentNode) {
        segment.hidden.parentNode.removeChild(segment.hidden);
      }
    });
    this.revealSegments = [];
    this.revealCursor = 0;
    this.revealComplete = true;
    this.buildNodeOffsets();
    this.applyCurrentScreenHighlights();
    this.refreshSentenceAudioCuePresentation();
  },
  patchHighlightsForVisualNovel: function() {
    var highlights = window.fushiHighlights;
    if (!highlights || highlights.fushiVisualNovelPatched) return;
    var reader = this;
    var originalCreateHighlight = typeof highlights.createHighlight === 'function'
      ? highlights.createHighlight.bind(highlights)
      : null;
    var originalRemoveHighlight = typeof highlights.removeHighlight === 'function'
      ? highlights.removeHighlight.bind(highlights)
      : null;
    highlights.collectSegments = function(offset, length) {
      return reader.highlightSegmentsForChapterRawRange(offset, length);
    };
    if (originalCreateHighlight) {
      highlights.createHighlight = function(color, id) {
        var result = originalCreateHighlight(color, id);
        if (result) reader.rememberCreatedHighlight(id, color, result);
        return result;
      };
    }
    if (originalRemoveHighlight) {
      highlights.removeHighlight = function(id) {
        reader.forgetHighlight(id);
        return originalRemoveHighlight(id);
      };
    }
    highlights.fushiVisualNovelPatched = true;
  },
  highlightSegmentsForChapterRawRange: function(offset, length) {
    return this.rangeMap.collectRawSegments(offset, length);
  },
  rememberCreatedHighlight: function(id, color, result) {
    var highlights = Array.isArray(this.initialHighlights) ? this.initialHighlights.slice() : [];
    highlights = highlights.filter(function(highlight) { return highlight.id !== id; });
    highlights.push({
      id: id,
      color: color,
      offset: result.offset,
      text: result.text
    });
    this.initialHighlights = highlights;
  },
  forgetHighlight: function(id) {
    if (!Array.isArray(this.initialHighlights)) return;
    this.initialHighlights = this.initialHighlights.filter(function(highlight) {
      return highlight.id !== id;
    });
  },
  clearCurrentHighlightWrappers: function() {
    var highlights = window.fushiHighlights;
    if (!highlights || !highlights.wrappers || typeof highlights.wrappers.forEach !== 'function') return;
    var wrapperGroups = [];
    highlights.wrappers.forEach(function(wrappers) {
      wrapperGroups.push(wrappers);
    });
    highlights.wrappers.clear();
    for (var i = 0; i < wrapperGroups.length; i++) {
      this.unwrap(wrapperGroups[i]);
    }
  },
  applyCurrentScreenHighlights: function() {
    var highlights = Array.isArray(this.initialHighlights) ? this.initialHighlights : [];
    if (!highlights.length || !window.fushiHighlights || typeof window.fushiHighlights.applyHighlights !== 'function') return;
    this.patchHighlightsForVisualNovel();
    this.clearCurrentHighlightWrappers();
    window.fushiHighlights.applyHighlights(highlights);
  },
  paginate: function(direction) {
    if (this.nativeSelectionActive) return "limit";
    if (!this.screens.length) return "limit";
    if (direction === "forward") {
      if (!this.revealComplete) {
        this.completeCurrentReveal();
        return "revealed";
      }
      if (this.currentScreenIndex >= this.screens.length - 1) return "limit";
      this.renderScreen(this.currentScreenIndex + 1, false);
      return "scrolled";
    }
    if (this.currentScreenIndex <= 0) return "limit";
    this.renderScreen(this.currentScreenIndex - 1, true);
    return "scrolled";
  },
  calculateProgress: function() {
    if (!this.screens.length) return 0;
    return this.progressForScreen(this.screens[this.currentScreenIndex]);
  },
  // BUG-1241：VN 的末屏可能与末尾字符共享进度锚；完成态以屏索引为准。
  isAtEnd: function() {
    return !!this.screens.length &&
      this.currentScreenIndex >= this.screens.length - 1;
  },
  screenIndexForProgress: function(progress) {
    if (!this.screens.length) return 0;
    var target = Math.min(1, Math.max(0, Number(progress) || 0));
    for (var i = 0; i < this.screens.length; i++) {
      if (this.screenProgressAnchor(this.screens[i]) + 1e-9 >= target) return i;
    }
    return this.screens.length - 1;
  },
  restoreProgress: async function(progress) {
    await this.ensureReady();
    this.renderScreen(this.screenIndexForProgress(progress), true);
    this.notifyRestoreComplete();
  },
  screenIndexForFragment: function(fragment) {
    var raw = (fragment || '').trim();
    if (!raw) return -1;
    for (var i = 0; i < this.screens.length; i++) {
      if (this.screenContainsFragment(this.screens[i], raw)) return i;
    }
    return -1;
  },
  jumpToFragment: async function(fragment) {
    await this.ensureReady();
    var index = this.screenIndexForFragment(fragment);
    if (index < 0) {
      this.notifyRestoreComplete();
      return false;
    }
    this.renderScreen(index, true);
    this.notifyRestoreComplete();
    return true;
  },
  sentenceAudioCueSignature: function(cues) {
    var items = Array.isArray(cues) ? cues : [];
    return JSON.stringify(items.map((cue) => ({
      id: cue && cue.id ? String(cue.id) : '',
      start: this.sentenceAudioCueStart(cue),
      length: Math.max(0, Number(cue && cue.length) || 0)
    })));
  },
  sentenceAudioCueDataChanged: function(cues) {
    return this.sentenceAudioCueSignature(cues) !== this.sentenceAudioCuesSignature;
  },
  setSentenceAudioCueData: function(cues) {
    this.sentenceAudioCues = Array.isArray(cues) ? cues : [];
    this.sentenceAudioCueMap = new Map();
    for (var i = 0; i < this.sentenceAudioCues.length; i++) {
      var cue = this.sentenceAudioCues[i];
      if (cue && cue.id) this.sentenceAudioCueMap.set(cue.id, cue);
    }
    this.sentenceAudioCuesSignature = this.sentenceAudioCueSignature(this.sentenceAudioCues);
  },
  sentenceAudioCueForInput: function(cue) {
    if (!cue) return null;
    if (typeof cue === 'string') return this.sentenceAudioCueMap.get(cue) || null;
    if (cue.id) {
      this.sentenceAudioCueMap.set(cue.id, cue);
    }
    return cue;
  },
  sentenceAudioCueStart: function(cue) {
    return Math.max(0, Number(cue && cue.start) || 0);
  },
  sentenceAudioCueEnd: function(cue) {
    var start = this.sentenceAudioCueStart(cue);
    return start + Math.max(0, Number(cue && cue.length) || 0);
  },
  sentenceAudioCueIntersectsScreen: function(cue, screen) {
    if (!cue || !screen) return false;
    var start = this.sentenceAudioCueStart(cue);
    var end = this.sentenceAudioCueEnd(cue);
    return this.screenIntersectsCharRange(screen, start, end);
  },
  screenIndexForSentenceAudioCue: function(cue) {
    if (!cue || !this.screens || !this.screens.length) return -1;
    var start = this.sentenceAudioCueStart(cue);
    for (var i = 0; i < this.screens.length; i++) {
      if (this.screenContainsCharOffset(this.screens[i], start)) return i;
    }
    for (var j = 0; j < this.screens.length; j++) {
      if (this.sentenceAudioCueIntersectsScreen(cue, this.screens[j])) return j;
    }
    return -1;
  },
  collectSentenceAudioCueRanges: function(cues) {
    var normalized = [];
    for (var i = 0; i < cues.length; i++) {
      var cue = this.sentenceAudioCueForInput(cues[i]);
      if (!cue || !cue.id) continue;
      var start = this.sentenceAudioCueStart(cue);
      normalized.push({ id: cue.id, start: start, length: this.sentenceAudioCueEnd(cue) - start });
    }
    return this.rangeMap.collectMatchableCueRanges(normalized);
  },
  rememberSentenceAudioCueSources: function(cueRanges) {
    for (var i = 0; i < cueRanges.length; i++) {
      this.cueSourceRanges.set(cueRanges[i].id, cueRanges[i]);
    }
  },
  sentenceAudioInlineTargetsForCue: function(cueId) {
    return this.cueWrappers.get(cueId) || [];
  },
  wrapSentenceAudioCueRanges: function(cueRanges) {
    var wrapped = new Map();
    var range = document.createRange();
    for (var i = cueRanges.length - 1; i >= 0; i--) {
      var id = cueRanges[i].id;
      var ranges = cueRanges[i].ranges;
      if (!ranges.length) continue;
      var wrappers = [];
      for (var j = ranges.length - 1; j >= 0; j--) {
        var segment = ranges[j];
        range.setStart(segment.node, segment.start);
        range.setEnd(segment.node, segment.end);
        var wrapper = document.createElement('span');
        wrapper.className = 'fushi-sentence-audio-cue';
        wrapper.appendChild(range.extractContents());
        range.insertNode(wrapper);
        wrappers.push(wrapper);
      }
      wrappers.reverse();
      this.cueWrappers.set(id, wrappers);
      wrapped.set(id, wrappers);
    }
    return wrapped;
  },
  buildSentenceAudioGeometryRanges: function(cueRanges) {
    var geometryRanges = new Map();
    for (var i = 0; i < cueRanges.length; i++) {
      var id = cueRanges[i].id;
      var ranges = cueRanges[i].ranges;
      if (!ranges.length) continue;
      var cueGeometryRanges = [];
      for (var j = 0; j < ranges.length; j++) {
        var segment = ranges[j];
        var range = document.createRange();
        range.setStart(segment.node, segment.start);
        range.setEnd(segment.node, segment.end);
        cueGeometryRanges.push(range);
      }
      if (cueGeometryRanges.length) geometryRanges.set(id, cueGeometryRanges);
    }
    return geometryRanges;
  },
  prepareSentenceAudioInlineTargets: function(cueRanges) {
    if (!this.isEInkMode()) {
      this.wrapSentenceAudioCueRanges(cueRanges);
      this.buildNodeOffsets();
    }
  },
  ensureSentenceAudioInlineTargetsForCue: function(cueId) {
    if (this.isEInkMode() || this.sentenceAudioInlineTargetsForCue(cueId).length) return;
    var cue = this.sentenceAudioCueMap.get(cueId);
    if (!cue) return;
    var cueRanges = this.collectSentenceAudioCueRanges([cue]);
    this.rememberSentenceAudioCueSources(cueRanges);
    this.prepareSentenceAudioInlineTargets(cueRanges);
  },
  ensureSentenceAudioCueGeometry: function(cue) {
    var cueId = typeof cue === 'string' ? cue : cue && cue.id;
    if (!cueId) return;
    var existing = this.cueGeometryRanges.get(cueId);
    if (existing && existing.length) return;
    var cueObject = this.sentenceAudioCueForInput(cue) || this.sentenceAudioCueMap.get(cueId);
    if (!cueObject) return;
    var cueRanges = this.collectSentenceAudioCueRanges([cueObject]);
    this.rememberSentenceAudioCueSources(cueRanges);
    var geometryRanges = this.buildSentenceAudioGeometryRanges(cueRanges).get(cueId) || [];
    if (geometryRanges.length) this.cueGeometryRanges.set(cueId, geometryRanges);
  },
  sentenceAudioOverlayRects: function(cueId) {
    var ranges = this.cueGeometryRanges.get(cueId) || [];
    var rects = [];
    ranges.forEach(function(range) {
      if (window.fushiRubyGeometry) {
        window.fushiRubyGeometry.rectsForRange(range).forEach(function(rect) { rects.push(rect); });
      } else {
        Array.from(range.getClientRects()).forEach(function(rect) {
          rects.push({ x: rect.x, y: rect.y, width: rect.width, height: rect.height });
        });
      }
    });
    return window.fushiRubyGeometry ? window.fushiRubyGeometry.mergeInlineRects(rects) : rects;
  },
  renderSentenceAudioOverlay: function() {
    if (!this.activeCueId || !this.isEInkMode()) {
      this.clearSentenceAudioOverlay();
      return;
    }
    if (window.fushiReaderPopupHost && window.fushiReaderPopupHost.renderSentenceAudioHighlight) {
      window.fushiReaderPopupHost.renderSentenceAudioHighlight({
        rects: this.sentenceAudioOverlayRects(this.activeCueId),
        eInkMode: true,
        verticalWriting: this.isVertical()
      });
    }
  },
  clearSentenceAudioOverlay: function() {
    if (window.fushiReaderPopupHost && window.fushiReaderPopupHost.clearSentenceAudioHighlight) {
      window.fushiReaderPopupHost.clearSentenceAudioHighlight();
    }
  },
  clearInlineSentenceAudioCue: function(cueId) {
    var clearWrappers = function(wrappers) {
      wrappers.forEach(function(wrapper) {
        wrapper.classList.remove('fushi-sentence-audio-active');
      });
    };
    if (cueId) {
      clearWrappers(this.cueWrappers.get(cueId) || []);
      return;
    }
    this.cueWrappers.forEach(clearWrappers);
  },
  applyInlineSentenceAudioCue: function(cueId) {
    var wrappers = this.cueWrappers.get(cueId) || [];
    wrappers.forEach(function(wrapper) {
      wrapper.classList.add('fushi-sentence-audio-active');
    });
    return wrappers.length > 0;
  },
  clearSentenceAudioCuePresentation: function() {
    this.clearInlineSentenceAudioCue();
    this.clearSentenceAudioOverlay();
  },
  clearCurrentSentenceAudioScreenTargets: function() {
    this.cueSourceRanges.clear();
    this.cueGeometryRanges.clear();
    this.cueWrappers.clear();
    this.clearSentenceAudioOverlay();
  },
  clearSentenceAudioTargets: function() {
    this.clearSentenceAudioCuePresentation();
    var self = this;
    this.cueWrappers.forEach(function(wrappers) {
      self.unwrap(wrappers);
    });
    this.cueWrappers.clear();
    this.cueSourceRanges.clear();
    this.cueGeometryRanges.clear();
    this.buildNodeOffsets();
  },
  applySentenceAudioCues: function(cues) {
    var activeCueId = this.activeCueId;
    var nextCues = Array.isArray(cues) ? cues : [];
    var shouldRebuildScreens = this.mergeCrossScreenSentenceAudioCues && this.sentenceAudioCueDataChanged(nextCues);
    var progress = shouldRebuildScreens ? this.calculateProgress() : null;
    this.clearSentenceAudioTargets();
    this.setSentenceAudioCueData(nextCues);
    this.activeCueId = activeCueId && this.sentenceAudioCueMap.has(activeCueId) ? activeCueId : null;
    if (shouldRebuildScreens) {
      this.buildScreens();
      this.renderScreen(this.screenIndexForProgress(progress), true);
      return;
    }
    this.buildNodeOffsets();
    if (this.activeCueId) this.refreshSentenceAudioCuePresentation();
  },
  highlightSentenceAudioCue: function(cue, reveal) {
    var cueObject = this.sentenceAudioCueForInput(cue);
    var cueId = typeof cue === 'string' ? cue : cueObject && cueObject.id;
    if (!cueId) return null;
    this.clearSentenceAudioCuePresentation();
    this.activeCueId = cueId;
    if (!cueObject) {
      this.refreshSentenceAudioCuePresentation();
      return null;
    }
    var targetIndex = this.screenIndexForSentenceAudioCue(cueObject);
    if (targetIndex < 0) {
      this.refreshSentenceAudioCuePresentation();
      return null;
    }
    if (targetIndex !== this.currentScreenIndex) {
      if (!reveal) {
        this.refreshSentenceAudioCuePresentation();
        return null;
      }
      this.renderScreen(targetIndex, true);
      this.refreshSentenceAudioCuePresentation();
      return this.calculateProgress();
    }
    if (!this.revealComplete) this.completeCurrentReveal();
    this.refreshSentenceAudioCuePresentation();
    return null;
  },
  clearSentenceAudioCue: function() {
    this.clearSentenceAudioCuePresentation();
    this.activeCueId = null;
  },
  refreshSentenceAudioCuePresentation: function() {
    if (!this.activeCueId) {
      this.clearSentenceAudioOverlay();
      return;
    }
    this.clearInlineSentenceAudioCue(this.activeCueId);
    var cue = this.sentenceAudioCueMap.get(this.activeCueId);
    var screen = this.screens && this.screens[this.currentScreenIndex];
    if (!cue || !this.sentenceAudioCueIntersectsScreen(cue, screen) || !this.revealComplete) {
      this.clearSentenceAudioOverlay();
      return;
    }
    if (this.isEInkMode()) {
      this.ensureSentenceAudioCueGeometry(cue);
      this.renderSentenceAudioOverlay();
    } else {
      this.clearSentenceAudioOverlay();
      this.ensureSentenceAudioInlineTargetsForCue(this.activeCueId);
      this.applyInlineSentenceAudioCue(this.activeCueId);
    }
  },
  resetSentenceAudioCues: function() {
    this.clearSentenceAudioTargets();
    this.setSentenceAudioCueData([]);
    this.activeCueId = null;
  },
  unwrap: function(wrappers) {
    var parents = [];
    wrappers.forEach(function(wrapper) {
      var parent = wrapper.parentNode;
      if (!parent) return;
      while (wrapper.firstChild) {
        parent.insertBefore(wrapper.firstChild, wrapper);
      }
      parent.removeChild(wrapper);
      if (parents.indexOf(parent) < 0) parents.push(parent);
    });
    parents.forEach(function(parent) {
      if (parent.normalize) parent.normalize();
    });
    this.buildNodeOffsets();
  }
};



// ── Hibiki host-compat shims (TODO-909 M0) ───────────────────────────────────
// The Dart side calls a few methods on window.fushiReader that hoshi a's VN
// object does not define. Add minimal, correct equivalents so the shared Dart
// reader paths behave under VN mode.
(function() {
  var vn = window.fushiReader;
  if (!vn) return;
  // BUG-1688：可用盒变了（视口尺寸 or chrome 预留带）就得按新盒重切屏并停在原处。
  // updatePageSize / setChromeInsets 只在「写哪几个 CSS 变量」上不同，重切动作同一份。
  if (typeof vn.refitScreensToCurrentViewport !== 'function') {
    vn.refitScreensToCurrentViewport = function() {
      if (!this.screens || !this.screens.length) return;
      var progress = this.calculateProgress();
      this.applyImageMaxVars();
      this.screens = this.fitScreensToViewport(this.baseScreens
        ? this.mergeSentenceAudioCrossScreenScreens(this.baseScreens)
        : this.screens);
      this.assignScreenProgressAnchors();
      this.renderScreen(this.screenIndexForProgress(progress), true);
    };
  }
  if (typeof vn.updatePageSize !== 'function') {
    vn.updatePageSize = function(width, height) {
      // BUG-1688：原实现整个忽略入参，`--page-width/--page-height` 于是永远是 VN
      // 从没写过的空值，量尺只能退回 100vw/100vh。这里与分页 shell 的 updatePageSize
      // 写同一组变量（含 `--reader-viewport-height`），再按新盒重切屏。
      var root = document.documentElement;
      var w = Math.round(Number(width) || 0);
      var h = Math.round(Number(height) || 0);
      if (root && root.style) {
        if (w > 0) root.style.setProperty('--page-width', w + 'px');
        if (h > 0) {
          root.style.setProperty('--page-height', h + 'px');
          root.style.setProperty('--reader-viewport-height', h + 'px');
        }
      }
      if (window.__fushiApplyReaderMargins) {
        window.__fushiApplyReaderMargins(w, h);
      }
      this.refitScreensToCurrentViewport();
    };
  }
  if (typeof vn.getFirstVisibleCharOffset !== 'function') {
    vn.getFirstVisibleCharOffset = function() {
      var screen = this.screens && this.screens[this.currentScreenIndex];
      return screen ? this.screenStartCharCount(screen) : -1;
    };
  }
  // 当前屏可见字符区间终点（半开 end）。VN 的 progress 口径本就是屏尾，start / end 都
  // 直接取屏表（screenStartCharCount / screenEndCharCount），不做几何探测。
  if (typeof vn.getLastVisibleCharOffset !== 'function') {
    vn.getLastVisibleCharOffset = function() {
      var screen = this.screens && this.screens[this.currentScreenIndex];
      return screen ? this.screenEndCharCount(screen) : -1;
    };
  }
  if (typeof vn.setChromeInsets !== 'function') {
    vn.setChromeInsets = function(topPx, bottomPx) {
      // BUG-1688：这里原来是 `return null` 的空壳，于是 Dart 侧
      // `_applyChromeInsets`（chrome.part.dart）每次下发的顶栏/底栏预留在 VN 下全部
      // 丢掉，`.fushi-vn-stage` 的 `var(--chrome-*-inset, 0px)` 恒取兜底 0px。
      // 与分页/连续 shell 的 setChromeInsets 写同一组变量，再按新的可用盒重切屏
      // （预留带变化会改变每屏能装多少行，只改 padding 不重切会留下溢出的旧屏）。
      var root = document.documentElement;
      if (root && root.style) {
        root.style.setProperty('--chrome-top-inset', (Number(topPx) || 0) + 'px');
        root.style.setProperty('--chrome-bottom-inset', (Number(bottomPx) || 0) + 'px');
      }
      this.refitScreensToCurrentViewport();
      return null;
    };
  }
  // BUG-1742：VN 在 detachChapterSource 里把整章正文搬进一个**游离**的 div
  // (this.sourceRoot)，document.body 里从此只剩当前一屏的克隆。任何靠
  // document.querySelector 找正文元素的宿主路径在 VN 下都必然落空——这正是
  // 「非 sasayaki 书的有声书自动跟随失效」的根。正文根必须从这里取。
  if (typeof vn.contentRoot !== 'function') {
    vn.contentRoot = function() {
      return this.sourceRoot || document.body;
    };
  }
  // 章内字符偏移 → 屏索引：**唯一**一份两段式查找（先找覆盖该偏移的屏，再取第一个
  // 末尾越过它的屏，覆盖偏移落在屏间空白 / 媒体单元的情况）。跟随
  // （highlightSelectorCue）、搜索（scrollToSearchMatch）、恢复（restoreToCharOffset）
  // 三条路都调它——restoreToCharOffset 里那份内联双循环已经删掉，不是「提取后留着
  // 原拷贝」：那正是两份实现开始分叉的方式（本注释此前就说了提取、代码却没删）。
  //
  // 查无返回 -1。「查无之后该怎么办」按调用方分：恢复要兜底到进度比例最近的一屏，
  // 跟随 / 搜索则必须什么都不做（乱翻屏比不翻更糟），所以兜底不在本 helper 里。
  if (typeof vn.screenIndexForCharOffset !== 'function') {
    vn.screenIndexForCharOffset = function(charOffset) {
      var target = Number(charOffset);
      if (!Number.isFinite(target) || target < 0) return -1;
      if (!this.screens || !this.screens.length) return -1;
      for (var i = 0; i < this.screens.length; i++) {
        if (this.screenContainsCharOffset(this.screens[i], target)) return i;
      }
      for (var j = 0; j < this.screens.length; j++) {
        if (this.screenEndCharCount(this.screens[j]) >= target) return j;
      }
      return -1;
    };
  }
  // BUG-1742：非 sasayaki 书（SRT/VTT/LRC 合成书）的 cue 是纯 CSS 选择器
  // `[data-cue-id="N"]`，宿主原本用 __fushiHighlight → document.querySelector
  // 找它。在 VN 下目标多半根本不在 document 里，querySelector 返回 null 后那条
  // 路径静默早退，跟随永远不翻屏。
  //
  // VN 的「跟随」语义本来就不是滚动而是翻屏，所以这里与 sasayaki 的
  // highlightSentenceAudioCue 收敛到同一条链路：选择器 → 源节点 → 字符偏移 →
  // 屏索引 → renderScreen。
  if (typeof vn.highlightSelectorCue !== 'function') {
    // async + await ensureReady()：与 restoreToCharOffset / restoreProgress /
    // jumpToFragment 同款。章节加载期到达的 cue 此前因为 this.screens 还是空的而被
    // screenIndexForCharOffset 判成 -1、静默丢弃——正是 BUG-1742 本身的形状。
    // 宿主（audiobook_bridge.dart）是 fire-and-forget 的 evaluateJavascript，不消费
    // 返回值，改成 Promise 对调用方零影响。
    vn.highlightSelectorCue = async function(selector, reveal) {
      if (!selector) return null;
      await this.ensureReady();
      var root = this.contentRoot();
      var node = (root && root.querySelector) ? root.querySelector(selector) : null;
      if (!node) return null;
      var stream = this.contentStream;
      if (!stream || typeof stream.sourcePositionForNode !== 'function') return null;
      var position = stream.sourcePositionForNode(node);
      var index = this.screenIndexForCharOffset(position ? position.startChar : -1);
      if (index < 0) return null;
      var markActive = (function() {
        // 当前屏是克隆出来的，class 每次 renderScreen 都会重建——所以只能在
        // 渲染之后打，且不必清理旧的（下一次渲染自然没有）。
        try {
          var scope = this.screen;
          if (!scope || !scope.querySelectorAll) return;
          Array.prototype.forEach.call(
            scope.querySelectorAll('.fushi-active'),
            function(el) { el.classList.remove('fushi-active'); }
          );
          var clone = scope.querySelector(selector);
          if (clone && clone.classList) clone.classList.add('fushi-active');
        } catch (_ignored) {}
      }).bind(this);
      if (index !== this.currentScreenIndex) {
        // reveal=false 是「别打断用户当前阅读位置」的显式请求，不许翻屏。
        if (!reveal) return null;
        this.renderScreen(index, true);
        markActive();
        return this.calculateProgress();
      }
      if (reveal && !this.revealComplete) this.completeCurrentReveal();
      markActive();
      return null;
    };
  }
  // BUG-1743：VN 此前完全没有 scrollToSearchMatch，而宿主是裸调
  // `window.fushiReader.scrollToSearchMatch(...)`——VN 下必抛 TypeError，表现为
  // 「搜索结果点了没反应」/「跨章只跳到目标章第一屏」。
  //
  // 不能沿用分页版实现：那一版用 createWalker() 只走当前屏，且靠 scrollToRange
  // 滚动，两个前提在 VN 下都不成立。VN 版在整章的 contentStream 上匹配，再走
  // 与 restoreToCharOffset 同款的「字符偏移 → 屏」链路翻屏。
  if (typeof vn.scrollToSearchMatch !== 'function') {
    vn.scrollToSearchMatch = function(query, hintOffset) {
      if (!query) return null;
      var stream = this.contentStream;
      if (!stream || !stream.textEntries || !stream.textEntries.length) return null;
      var entries = stream.textEntries;
      var segments = [];
      var full = '';
      for (var i = 0; i < entries.length; i++) {
        var text = String(entries[i].text || '');
        segments.push({ entry: entries[i], start: full.length, text: text });
        full += text;
      }
      var lowerQuery = String(query).toLowerCase();
      var lowerFull = full.toLowerCase();
      var matches = [];
      var searchFrom = 0;
      while (searchFrom <= lowerFull.length) {
        var idx = lowerFull.indexOf(lowerQuery, searchFrom);
        if (idx < 0) break;
        matches.push(idx);
        searchFrom = idx + 1;
      }
      if (!matches.length) return null;
      // 就近策略与分页版一致：同章多处命中时取离 hintOffset 最近的一处。
      var hint = Number(hintOffset);
      if (!Number.isFinite(hint)) hint = 0;
      var best = matches[0];
      var bestDist = Math.abs(best - hint);
      for (var m = 1; m < matches.length; m++) {
        var dist = Math.abs(matches[m] - hint);
        if (dist < bestDist) { best = matches[m]; bestDist = dist; }
      }
      var seg = null;
      for (var s = 0; s < segments.length; s++) {
        if (best < segments[s].start + segments[s].text.length) { seg = segments[s]; break; }
      }
      if (!seg) seg = segments[segments.length - 1];
      // 命中下标是「拼接后的原始文本」坐标，而屏索引吃的是**可匹配字符**坐标
      // （countChars 会跳过空白/不可匹配字符）。直接拿 best 当 charOffset 用会
      // 在任何含空白的章节上系统性偏移，必须经命中所在 entry 的前缀换算。
      var localRaw = Math.max(0, best - seg.start);
      var prefix = seg.text.slice(0, localRaw);
      var countChars = (typeof stream.countChars === 'function')
        ? stream.countChars.bind(stream)
        : function(t) { return String(t || '').length; };
      var charOffset = seg.entry.startChar + countChars(prefix);
      var index = this.screenIndexForCharOffset(charOffset);
      if (index < 0) return null;
      if (index !== this.currentScreenIndex) {
        this.renderScreen(index, true);
      } else if (!this.revealComplete) {
        // 停在当前屏时也得先把这一屏渲完，否则命中词还没被打字机揭开，屏内
        // 文本节点里根本没有它 → 高亮建不出来。
        this.completeCurrentReveal();
      }
      this.highlightSearchMatchOnScreen(query);
      return this.calculateProgress();
    };
  }
  // BUG-1743 ②：翻到屏之后还得给出**视觉命中标记**。分页版一直有
  // （`CSS.highlights.set('fushi-search', …)`，reader_pagination_scripts.dart），
  // VN 版此前只有下面 clearSearchHighlight 的「删」、没有「建」——那把删除是死代码，
  // 用户翻到屏之后仍要自己在满屏文字里找那个词。
  //
  // 不能拿源流节点建 Range：VN 的整章正文在**游离**的 sourceRoot 里（BUG-1742），
  // ::highlight 只对 document 内的 Range 生效。所以在**当前屏的克隆**上重新定位一次
  // ——命中就在这一屏（否则不会翻到这里），按屏内文本节点的拼接坐标建 Range。
  // 命中横跨屏边界时屏内找不到完整串，如实返回 false 不建高亮（翻屏本身仍然生效）。
  if (typeof vn.highlightSearchMatchOnScreen !== 'function') {
    vn.highlightSearchMatchOnScreen = function(query) {
      if (!window.__fushiCssHighlightsSupported) return false;
      var scope = this.screen;
      var needle = String(query || '');
      if (!scope || !needle) return false;
      try {
        var walker = document.createTreeWalker(scope, NodeFilter.SHOW_TEXT, null);
        var segments = [];
        var full = '';
        var node;
        while ((node = walker.nextNode())) {
          var text = String(node.textContent || '');
          if (!text) continue;
          segments.push({ node: node, start: full.length, length: text.length });
          full += text;
        }
        var from = full.toLowerCase().indexOf(needle.toLowerCase());
        if (from < 0) return false;
        var to = from + needle.length;
        var startNode = null, startOffset = 0, endNode = null, endOffset = 0;
        for (var i = 0; i < segments.length; i++) {
          var seg = segments[i];
          var segEnd = seg.start + seg.length;
          if (!startNode && from < segEnd) {
            startNode = seg.node;
            startOffset = from - seg.start;
          }
          if (startNode && to <= segEnd) {
            endNode = seg.node;
            endOffset = to - seg.start;
            break;
          }
        }
        if (!startNode || !endNode) return false;
        var range = document.createRange();
        range.setStart(startNode, startOffset);
        range.setEnd(endNode, endOffset);
        CSS.highlights.set('fushi-search', new Highlight(range));
        return true;
      } catch (_ignored) {
        return false;
      }
    };
  }
  if (typeof vn.clearSearchHighlight !== 'function') {
    vn.clearSearchHighlight = function() {
      if (window.__fushiCssHighlightsSupported) {
        try { CSS.highlights.delete('fushi-search'); } catch (_ignored) {}
      }
    };
  }
  if (typeof vn.restoreToCharOffset !== 'function') {
    vn.restoreToCharOffset = async function(charOffset) {
      await this.ensureReady();
      var target = Number(charOffset);
      // 两段式查找只有 screenIndexForCharOffset 一份（此处曾是逐字重复的第二份，
      // 且已经和 helper 分叉）。恢复独有的进度兜底留在这里：helper 查无 = -1 时，
      // 恢复必须落到某一屏，不能像跟随 / 搜索那样什么都不做。
      var index = this.screenIndexForCharOffset(target);
      if (index < 0) {
        index = this.screenIndexForProgress(this.totalChapterChars
          ? target / this.totalChapterChars
          : 0);
      }
      this.renderScreen(index, true);
      this.notifyRestoreComplete();
    };
  }
})();

// Hibiki adaptation: initialize on load, then run the restore script. This MUST
// run AFTER the host-compat shim IIFE above: a charOffset restore calls
// window.fushiReader.restoreToCharOffset, which only the shim defines. Placed
// before the shim it threw a synchronous TypeError that aborted the outer
// reader-setup IIFE before its tail removed #fushi-cloak, leaving the page
// visibility:hidden (blank) on any restore-by-charOffset VN entry. The
// try/catch also stops a future restore error from ever stranding the cloak.
window.addEventListener('load', function() {
  try {
    window.fushiReader.initialize();
    $initialRestoreScript
  } catch (e) {
    try { if (window.console && console.error) console.error('[FushiVN] boot restore failed', e); } catch (_ignored) {}
  }
});
if (document.readyState === 'complete') {
  try {
    window.fushiReader.initialize();
    $initialRestoreScript
  } catch (e) {
    try { if (window.console && console.error) console.error('[FushiVN] boot restore failed', e); } catch (_ignored) {}
  }
}
};
</script>''';
  }
}
