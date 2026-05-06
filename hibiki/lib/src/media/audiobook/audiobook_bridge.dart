import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/sasayaki_match_codec.dart';

/// WebView ↔ Flutter 双向通道，用于有声书句子高亮和点击跳转。
///
/// 使用方式：
/// 1. 章节加载完成后调用 [inject]，注入 CSS + JS。
/// 2. 若 XHTML 没有句子级 span，调用 [annotate] 自动分割并打标。
/// 3. 播放器 currentCue 变化时调用 [highlight]。
/// 4. WebView onConsoleMessage 中调用 [parseMessage] 解析点击事件。
class AudiobookBridge {
  AudiobookBridge._();

  // ── JS / CSS ────────────────────────────────────────────────────────────────

  /// 根据主题色生成高亮 CSS。
  static String _buildCss(Color primaryColor) {
    final int r = (primaryColor.r * 255.0).round().clamp(0, 255);
    final int g = (primaryColor.g * 255.0).round().clamp(0, 255);
    final int b = (primaryColor.b * 255.0).round().clamp(0, 255);
    return '''
.hoshi-active {
  background: rgba($r, $g, $b, 0.35);
  border-radius: 2px;
  transition: background 0.15s ease;
}
[data-hoshi-sid], [data-cue-id] {
  cursor: pointer;
}
[data-hoshi-sid]:hover, [data-cue-id]:hover {
  background: rgba($r, $g, $b, 0.15);
  border-radius: 2px;
}
''';
  }

  /// 对齐到整页：anchor = rect 中心的绝对坐标，pageIndex = floor(anchor / stride)，
  /// 通过 ttu 的 `__ttuScrollToPos` API 同步写 scrollTop 和 virtualScrollPos$。
  static const String _highlightFn = '''
if (window.__hoshiAutoScrollInFlight === undefined) window.__hoshiAutoScrollInFlight = false;
if (window.__hoshiAutoScrollTimer === undefined) window.__hoshiAutoScrollTimer = null;
window.__hoshiAlignToRect = function(rect) {
  if (!rect) return;
  if (window.__hoshiAutoScrollInFlight && !window.__hoshiRestoreInFlight) return;
  var isDegenerate = rect.width === 0 && rect.height === 0 &&
                     rect.left === 0 && rect.top === 0;
  if (isDegenerate) return;

  if (typeof window.__ttuGetPageInfo !== 'function') { console.log('alignToRect:noApi'); return; }
  var info = window.__ttuGetPageInfo();
  if (!info || (!info.stride && info.stride !== 0)) { console.log('alignToRect:noInfo ' + JSON.stringify(info)); return; }
  if (info.stride < 10) {
    if (info.stride === 0) {
      var vpW = window.innerWidth;
      var vpH = window.innerHeight;
      var margin = 0.15;
      var dx = 0, dy = 0;
      var needScroll = false;
      if (info.verticalMode) {
        var safeL = vpW * margin;
        var safeR = vpW * (1 - margin);
        if (rect.left < safeL || rect.right > safeR) {
          dx = -(vpW * 0.67 - rect.right);
          needScroll = true;
        }
      } else {
        var safeT = vpH * margin;
        var safeB = vpH * (1 - margin);
        if (rect.top < safeT || rect.bottom > safeB) {
          dy = rect.top - vpH * 0.33;
          needScroll = true;
        }
      }
      console.log(JSON.stringify({
        'hibiki-message-type': 'alignDiag',
        'mode': 'continuous',
        'verticalMode': info.verticalMode,
        'rectT': Math.round(rect.top), 'rectB': Math.round(rect.bottom),
        'rectL': Math.round(rect.left), 'rectR': Math.round(rect.right),
        'dx': Math.round(dx), 'dy': Math.round(dy),
        'needScroll': needScroll
      }));
      if (needScroll) {
        window.scrollBy({ left: dx, top: dy });
        window.__hoshiAutoScrollInFlight = true;
        if (window.__hoshiAutoScrollTimer) clearTimeout(window.__hoshiAutoScrollTimer);
        window.__hoshiAutoScrollTimer = setTimeout(function() {
          window.__hoshiAutoScrollInFlight = false;
          window.__hoshiAutoScrollTimer = null;
        }, 250);
      }
    }
    return;
  }
  var content = document.querySelector('.book-content') ||
                document.scrollingElement || document.documentElement;
  var cRect = content.getBoundingClientRect();
  var virtualPos = info.virtualScrollPos;
  var actualPos = info.verticalMode ? content.scrollTop : content.scrollLeft;
  var anchor;
  if (info.verticalMode) {
    anchor = (rect.top + rect.bottom) / 2 - cRect.top + virtualPos;
  } else {
    anchor = (rect.left + rect.right) / 2 - cRect.left + virtualPos;
  }
  var s = info.stride;
  var vp = info.viewportSize;
  var rawPage = anchor / s;
  var floorPage = Math.floor(rawPage);
  var pageContentEnd = floorPage * s + vp;
  var targetPage = (anchor >= pageContentEnd) ? floorPage + 1 : floorPage;
  targetPage = Math.max(0, Math.min(targetPage, info.totalPages - 1));
  var prevPage = info.currentPage;
  console.log(JSON.stringify({
    'hibiki-message-type': 'alignDiag',
    'rectT': Math.round(rect.top), 'rectB': Math.round(rect.bottom),
    'rectL': Math.round(rect.left), 'rectR': Math.round(rect.right),
    'cRectT': Math.round(cRect.top), 'cRectL': Math.round(cRect.left),
    'virtual': virtualPos, 'actual': actualPos,
    'anchor': Math.round(anchor), 'rawPage': rawPage.toFixed(3),
    'floorPage': floorPage, 'target': targetPage, 'cur': prevPage,
    'stride': s, 'vp': vp, 'gap': info.pageGap,
    'scrollH': content.scrollHeight, 'scrollW': content.scrollWidth,
    'clientH': content.clientHeight, 'clientW': content.clientWidth
  }));
  if (targetPage !== prevPage) {
    if (typeof window.__ttuScrollToAnchor === 'function') {
      window.__ttuScrollToAnchor(anchor);
    } else if (typeof window.__ttuGoToPage === 'function') {
      window.__ttuGoToPage(targetPage);
    }
    window.__hoshiAutoScrollInFlight = true;
    if (window.__hoshiAutoScrollTimer) clearTimeout(window.__hoshiAutoScrollTimer);
    window.__hoshiAutoScrollTimer = setTimeout(function() {
      window.__hoshiAutoScrollInFlight = false;
      window.__hoshiAutoScrollTimer = null;
    }, 800);
  }
};

window.__hoshiAlignToElement = function(el) {
  if (!el) return;
  var rect;
  try { rect = el.getBoundingClientRect(); } catch (e) { return; }
  window.__hoshiAlignToRect(rect);
};

window.__hoshiHighlight = function(selector, reveal) {
  if (reveal === undefined) reveal = true;
  console.log(JSON.stringify({
    'hibiki-message-type': 'diagHighlightEntry',
    'selector': selector || '',
    'reveal': reveal,
    'hasBookContent': !!document.querySelector('.book-content')
  }));
  // 无论 selector 是否非空，先清一轮旧 class。
  document.querySelectorAll('.hoshi-active').forEach(function(e) {
    e.classList.remove('hoshi-active');
  });
  if (!selector) return;
  var el = document.querySelector(selector);
  if (el) {
    el.classList.add('hoshi-active');
    if (reveal) window.__hoshiAlignToElement(el);
  }
};

''';


  /// Sasayaki 路径的辅助 JS：
  ///
  /// - `__hoshiLoadSasayakiRefs(ttuBookId)`：从 ttu IndexedDB 读 `sections` +
  ///   `elementHtml`，缓存 `sectionIndex → reference` 和每个 section 的
  ///   **归一化文本长度**（以及累计起点）。ttu 在渲染时会剥掉 section
  ///   原始 id，所以我们放弃"找章节根"这条路，改为用"整本书归一化偏移"
  ///   在 `.book-content-container` 里定位。
  /// - `__hoshiIsSkippable(code)`：镜像 Dart 的 `AudioTextNormalizer._isKeepable`
  ///   的反函数。白名单规则（只留假名/汉字/字母数字），其余一律视为可跳过。
  ///
  /// 与字幕 EPUB 路径（`[data-cue-id]`）互不冲突：入口在 Dart 侧的
  /// [highlight] 根据 `textFragmentId` 前缀分派。
  static const String _sasayakiFn = '''
window.__hoshiSasayakiSectionLens = window.__hoshiSasayakiSectionLens || null;
window.__hoshiSasayakiTotalNorm = (typeof window.__hoshiSasayakiTotalNorm === 'number')
  ? window.__hoshiSasayakiTotalNorm : null;

window.__hoshiLoadSasayakiRefs = function(ttuBookId) {
  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiRefsLoading',
    'ttuBookId': ttuBookId
  }));
  if (ttuBookId === undefined || ttuBookId === null) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiRefsErr',
      'error': 'missing_ttu_book_id'
    }));
    return;
  }
  try {
    var req = indexedDB.open('books');
    req.onupgradeneeded = function(e) {
      e.target.transaction.abort();
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiRefsErr',
        'error': 'db_not_initialized'
      }));
    };
    req.onsuccess = function(ev) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiRefsDbOpen',
        'stores': Array.prototype.slice.call(ev.target.result.objectStoreNames)
      }));
      var db = ev.target.result;
      if (!db.objectStoreNames.contains('data')) {
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiRefsErr',
          'error': 'no_data_store'
        }));
        return;
      }
      var tx = db.transaction(['data'], 'readonly');
      var g = tx.objectStore('data').get(ttuBookId);
      g.onsuccess = function(e) {
        var rec = e.target.result;
        var sections = (rec && rec.sections) || [];
        var html = (rec && rec.elementHtml) || '';
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiRefsRecord',
          'ttuBookId': ttuBookId,
          'recFound': !!rec,
          'sectionsLen': sections.length,
          'htmlLen': html.length
        }));

        // 每段正文归一化字符数 —— 复用 DOMParser 从原始 elementHtml 中按
        // section.reference 取元素的 textContent 再数字符。必须和 Dart 侧
        // `EpubSrtMatcher._buildIndex` 的累加方式严格一致，否则累计起点
        // 会漂移。剥 <rt>/<rp> 的规则也必须和 TtuIdbReader 保持一致，否则
        // 匹配时的偏移基准 vs 运行期高亮基准会错位。
        var parser = new DOMParser();
        var doc = parser.parseFromString('<div>' + html + '</div>', 'text/html');

        function normLen(t) {
          var n = 0;
          for (var i = 0; i < t.length; ) {
            var c = t.codePointAt(i);
            var w = (c > 0xFFFF) ? 2 : 1;
            if (!window.__hoshiIsSkippable(c)) n += w;
            i += w;
          }
          return n;
        }

        function stripRubyText(el) {
          var clone = el.cloneNode(true);
          var rts = clone.querySelectorAll('rt, rp');
          for (var j = 0; j < rts.length; j++) rts[j].parentNode.removeChild(rts[j]);
          return clone.textContent || '';
        }

        var sectionLens = [];
        var cumulative = 0;
        for (var i = 0; i < sections.length; i++) {
          var ref = (sections[i] && sections[i].reference) || '';
          var el = ref ? doc.getElementById(ref) : null;
          var text = el ? stripRubyText(el) : '';
          var segLen = normLen(text);
          sectionLens.push(segLen);
          cumulative += segLen;
        }
        window.__hoshiSasayakiSectionLens = sectionLens;
        window.__hoshiSasayakiTotalNorm = cumulative;
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiRefsReady',
          'count': sections.length,
          'totalNormChars': cumulative
        }));
      };
      g.onerror = function(e) {
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiRefsErr',
          'error': String(e.target.error)
        }));
      };
    };
    req.onerror = function(e) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiRefsErr',
        'error': String(e.target.error)
      }));
    };
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiRefsErr',
      'error': String(e)
    }));
  }
};

window.__hoshiIsSkippable = function(c) {
  // 与 Dart AudioTextNormalizer._isKeepable 对应的"反函数"：只要不在白名单里
  // 就视为 skippable（不计入 normChar 计数）。白名单必须与 Dart 严格一致，
  // 否则匹配期写回的 normCharStart/End 与 WebView 运行期计数对不上 → 高亮漂。
  if (c >= 0x30 && c <= 0x39) return false;   // 0-9
  if (c >= 0x41 && c <= 0x5A) return false;   // A-Z
  if (c >= 0x61 && c <= 0x7A) return false;   // a-z
  if (c === 0x3005 || c === 0x3006 || c === 0x3007) return false; // 々 〆 〇
  if (c >= 0x3041 && c <= 0x3096) return false; // ぁ-ゖ
  if (c >= 0x309D && c <= 0x309F) return false; // ゝゞゟ
  if (c >= 0x30A1 && c <= 0x30FA) return false; // ァ-ヺ
  if (c >= 0x30FC && c <= 0x30FF) return false; // ー ヽ ヾ ヿ
  if (c >= 0x3400 && c <= 0x4DBF) return false; // CJK Ext A
  if (c >= 0x4E00 && c <= 0x9FFF) return false; // CJK Unified
  if (c === 0x25CB || c === 0x25EF) return false; // ○ ◯
  if (c === 0x303B) return false; // 〻
  if (c >= 0x2E80 && c <= 0x2EFF) return false; // CJK Radicals Supplement
  if (c >= 0x2F00 && c <= 0x2FDF) return false; // Kangxi Radicals
  if (c >= 0xF900 && c <= 0xFAFF) return false; // CJK Compat Ideographs
  if (c >= 0x20000 && c <= 0x2A6DF) return false; // CJK Ext B
  if (c >= 0x2A700 && c <= 0x2EBE0) return false; // CJK Ext C-F
  if (c >= 0x2F800 && c <= 0x2FA1F) return false; // CJK Compat Ideo Suppl
  if (c >= 0x30000 && c <= 0x323AF) return false; // CJK Ext G-I
  if (c >= 0xFF10 && c <= 0xFF19) return false; // ０-９
  if (c >= 0xFF21 && c <= 0xFF3A) return false; // Ａ-Ｚ
  if (c >= 0xFF41 && c <= 0xFF5A) return false; // ａ-ｚ
  if (c >= 0xFF66 && c <= 0xFF9D) return false; // ｦ-ﾝ
  return true;
};


// ── 章节挂载时批量预包 span + Map 缓存（对齐 iOS Sasayaki） ─────────────
// sectionChanged 触发 → Dart 调 applySasayakiCues → JS 一次性 TreeWalker
// 把该章所有 cue 包进 <span class="hoshi-sasayaki-cue">，存入 cueMap。
// 运行期 __hoshiHighlightSasayakiCueById 做 O(1) Map 查表 + class toggle。
// cueMap miss → 清高亮，不做回退（对齐 iOS Hoshi Reader）。
// Sasayaki cue span 的点击：回传 textFragmentId 供 Dart 定位 cue。
// 使用 document 级事件委托，section 切换后新 DOM 上的 span 自动命中。
if (!document.__hoshiSasayakiClickRegistered) {
  document.__hoshiSasayakiClickRegistered = true;
  document.addEventListener('click', function(e) {
    var span = e.target.closest('[data-sasayaki-key]');
    if (!span) return;
    var key = span.getAttribute('data-sasayaki-key');
    if (!key) return;
    console.log(JSON.stringify({
      'hibiki-message-type': 'seekToSentence',
      'sasayakiKey': key
    }));
  }, true);
}

window.__hoshiSasayakiCueMap = window.__hoshiSasayakiCueMap || null;
window.__hoshiSasayakiAppliedForSection =
  (typeof window.__hoshiSasayakiAppliedForSection === 'number')
    ? window.__hoshiSasayakiAppliedForSection : -1;
window.__hoshiSasayakiAppliedRootLen =
  (typeof window.__hoshiSasayakiAppliedRootLen === 'number')
    ? window.__hoshiSasayakiAppliedRootLen : -1;

window.__hoshiClearSasayakiApplied = function() {
  if (typeof window.__ttuClearCueSpans === 'function') {
    window.__ttuClearCueSpans();
  }
  window.__hoshiSasayakiCueMap = null;
};

window.__hoshiApplySasayakiCues = function(sectionIndex, cuesJson) {
  if (!document.body && !document.documentElement) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplySkip',
      'reason': 'no_dom',
      'sectionIndex': sectionIndex
    }));
    return;
  }
  if (typeof window.__ttuWrapCueSpans !== 'function') {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplySkip',
      'reason': 'ttu_api_missing',
      'sectionIndex': sectionIndex
    }));
    return;
  }
  var savedPos = null;
  try {
    if (typeof window.__ttuGetPageInfo === 'function') {
      var info = window.__ttuGetPageInfo();
      if (info) savedPos = info.virtualScrollPos;
    }
  } catch(e) {}
  var result = window.__ttuWrapCueSpans(cuesJson, window.__hoshiIsSkippable);
  var afterPos = null;
  try {
    if (typeof window.__ttuGetPageInfo === 'function') {
      var ai = window.__ttuGetPageInfo();
      if (ai) afterPos = ai.virtualScrollPos;
    }
  } catch(e2) {}
  if (savedPos !== null && typeof window.__ttuScrollToPos === 'function') {
    if (afterPos !== savedPos) {
      window.__ttuScrollToPos(savedPos);
    }
    window.__hoshiAutoScrollInFlight = true;
    if (window.__hoshiAutoScrollTimer) clearTimeout(window.__hoshiAutoScrollTimer);
    window.__hoshiAutoScrollTimer = setTimeout(function() {
      window.__hoshiAutoScrollInFlight = false;
      window.__hoshiAutoScrollTimer = null;
    }, 1200);
  }
  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiScrollRestore',
    'savedPos': savedPos, 'afterPos': afterPos,
    'restored': savedPos !== null && afterPos !== savedPos
  }));
  window.__hoshiSasayakiAppliedForSection = sectionIndex;
  var root = document.querySelector('.book-content-container') ||
             document.querySelector('.book-content');
  window.__hoshiSasayakiAppliedRootLen = root ? (root.textContent || '').length : -1;
  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiApplied',
    'sectionIndex': sectionIndex,
    'applied': result ? result.applied : 0,
    'mapSize': result ? result.mapSize : 0,
    'total': result ? result.total : 0
  }));
};

window.__hoshiHighlightSasayakiCueById = function(key, reveal) {
  if (reveal === undefined) reveal = true;
  var map = window.__hoshiSasayakiCueMap;
  var wrappers = map ? map.get(key) : null;
  // 先清上一条 cue 的 active class。class toggle 不动 DOM 结构，不会触发
  // CSS columns 重排，相邻 cue 切换时视觉稳定。
  var prev = document.querySelectorAll('.hoshi-sasayaki-cue.hoshi-active');
  for (var pi = 0; pi < prev.length; pi++) {
    prev[pi].classList.remove('hoshi-active');
  }
  if (!wrappers || wrappers.length === 0) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiCueMapMiss',
      'key': key,
      'hasMap': !!map,
      'mapSize': map ? map.size : 0
    }));
    return false;
  }
  for (var wi = 0; wi < wrappers.length; wi++) {
    wrappers[wi].classList.add('hoshi-active');
  }
  if (reveal) window.__hoshiAlignToElement(wrappers[0]);
  return true;
};
''';

  /// PR8a 的 Flutter 侧准备：ttu fork 之前就把"调用面"铺好，所有消费者只
  /// 认 `__sasayakiRequestNav` 这个统一入口，fork 落地后只改这一段 JS，其他
  /// 位置无感。
  ///
  /// ### 组件
  ///
  /// - `window.__sasayakiAutoNav`：系统触发的章节跳转期间为 true，用户翻页
  ///   为 false。PR8b 的 "Follow audio" 判断用户意图靠这个 flag，不用时间
  ///   窗。ttu fork 暴露 section API 时也必须在"恢复阅读位置"这类程序化
  ///   调用里手动置 true（或用另起的 `__ttuInternalNav`），否则会被误判。
  /// - `window.__sasayakiRequestNav(n)`：PR8b 调用的入口。当前实现两条分支：
  ///   ttu fork 已落地（`__ttuGoToSection` 存在）→ 调用并 await；否则打
  ///   `ttuForkMissing` 日志直接 resolve，让上层降级为 pill 提示。两种状态
  ///   调用面一致，上层不做分支。
  /// - `window.__hoshiTtuProbe()`：一次性探针，返回 `{hasGoToSection,
  ///   hasCurrentSection, hasSectionCount, sectionCount, currentSection}`，
  ///   供 [AudiobookBridge.probeTtuApi] 消费写进 AudiobookHealth.reason。
  static const String _ttuApiShimFn = '''
window.__sasayakiAutoNav = window.__sasayakiAutoNav || false;

window.__sasayakiRequestNav = async function(n) {
  window.__sasayakiAutoNav = true;
  try {
    if (typeof window.__ttuSectionCount === 'function') {
      var sectionCount = window.__ttuSectionCount();
      if (!sectionCount || n < 0 || n >= sectionCount) {
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiNavErr',
          'section': n,
          'error': 'section out of range',
          'sectionCount': sectionCount
        }));
        return;
      }
    }
    if (typeof window.__ttuGoToSection === 'function') {
      await window.__ttuGoToSection(n);
      // ttu 跳章（哪怕目标段等于当前段）会整体替换 .book-content-container
      // 的 innerHTML，cueMap 里的 span 立刻变成孤儿节点——再给它们 addClass
      // 也找不到 .hoshi-active 了（见 highlightMiss 病症）。所以这里强制
      // 失效 applied 状态 + 丢掉旧 map，sectionChanged 事件会让 Dart 侧
      // 重新 applySasayakiCues，新 DOM 上重建 cueMap。
      window.__hoshiSasayakiAppliedForSection = -1;
      window.__hoshiSasayakiAppliedRootLen = -1;
      if (typeof window.__hoshiClearSasayakiApplied === 'function') {
        window.__hoshiClearSasayakiApplied();
      }
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiNavOk', 'section': n
      }));
    } else {
      console.log(JSON.stringify({
        'hibiki-message-type': 'ttuForkMissing',
        'api': '__ttuGoToSection',
        'requestedSection': n
      }));
    }
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiNavErr',
      'section': n,
      'error': String(e)
    }));
  } finally {
    // queueMicrotask 保证 ttu 的 sectionChange 回调读到 true —— 它们通常
    // 在同一个 task 里同步派发，再下一个 microtask 才轮到我们复位。
    queueMicrotask(function() { window.__sasayakiAutoNav = false; });
  }
};

window.__hoshiTtuProbe = function() {
  var result = {
    'hibiki-message-type': 'ttuProbe',
    'hasGoToSection': typeof window.__ttuGoToSection === 'function',
    'hasCurrentSection': typeof window.__ttuCurrentSection === 'function',
    'hasSectionCount': typeof window.__ttuSectionCount === 'function',
    'sectionCount': null,
    'currentSection': null,
    'currentPage': null,
    'totalPages': null
  };
  try {
    if (result.hasSectionCount) {
      result.sectionCount = window.__ttuSectionCount();
    }
    if (result.hasCurrentSection) {
      result.currentSection = window.__ttuCurrentSection();
    }
  } catch (e) {
    result.probeError = String(e);
  }
  try {
    var el = document.querySelector('.book-content');
    if (el) {
      var isPaginated = document.body.classList.contains('overflow-hidden');
      if (isPaginated) {
        var cs = getComputedStyle(el);
        var isVertical = cs.writingMode === 'vertical-rl';
        var gap = 0;
        var container = document.querySelector('.book-content-container');
        if (container) {
          var g = parseFloat(getComputedStyle(container).columnGap);
          if (isFinite(g)) gap = g;
        }
        if (isVertical) {
          var sz = el.clientHeight + gap;
          result.totalPages = Math.max(1, Math.ceil(el.scrollHeight / sz));
          result.currentPage = Math.floor(el.scrollTop / sz) + 1;
        } else {
          var sz = el.clientWidth + gap;
          result.totalPages = Math.max(1, Math.ceil(el.scrollWidth / sz));
          result.currentPage = Math.floor(Math.abs(el.scrollLeft) / sz) + 1;
        }
      } else {
        var vh = window.innerHeight;
        var sh = document.documentElement.scrollHeight;
        var st = window.scrollY || document.documentElement.scrollTop;
        if (vh > 0) {
          result.totalPages = Math.max(1, Math.ceil(sh / vh));
          result.currentPage = Math.floor(st / vh) + 1;
        }
      }
    }
  } catch (e) {}
  console.log(JSON.stringify(result));
  return JSON.stringify(result);
};
''';

  /// 自动句子标注函数：按日文句末标点分割文本节点，包裹 data-hoshi-sid span。
  ///
  /// 跳过 ruby 内部节点，避免破坏振假名结构。
  static const String _annotateFn = '''
window.__hoshiAnnotate = function(chapterHref) {
  if (document.__hoshiAnnotated) return;
  document.__hoshiAnnotated = true;

  var sidCounter = 0;
  var sentenceEnd = /[。！？」』）]/;

  function isInsideRuby(node) {
    var p = node.parentNode;
    while (p) {
      if (p.nodeName === 'RUBY' || p.nodeName === 'RT' || p.nodeName === 'RP') {
        return true;
      }
      p = p.parentNode;
    }
    return false;
  }

  function wrapText(textNode) {
    if (isInsideRuby(textNode)) return;
    var text = textNode.nodeValue;
    if (!text || text.trim().length === 0) return;

    var frag = document.createDocumentFragment();
    var buf = '';
    for (var i = 0; i < text.length; i++) {
      buf += text[i];
      if (sentenceEnd.test(text[i]) || i === text.length - 1) {
        var span = document.createElement('span');
        span.dataset.hoshiSid = String(sidCounter++);
        span.dataset.hoshiChapter = chapterHref;
        span.textContent = buf;
        frag.appendChild(span);
        buf = '';
      }
    }
    textNode.parentNode.replaceChild(frag, textNode);
  }

  var walker = document.createTreeWalker(
    document.body,
    NodeFilter.SHOW_TEXT,
    null,
    false
  );
  var nodes = [];
  while (walker.nextNode()) nodes.push(walker.currentNode);
  nodes.forEach(wrapText);

  // 点击事件：回传 {type, chapter, sid}
  document.addEventListener('click', function(e) {
    var span = e.target.closest('[data-hoshi-sid]');
    if (!span) return;
    console.log(JSON.stringify({
      'hibiki-message-type': 'seekToSentence',
      'chapter': span.dataset.hoshiChapter || '',
      'sid': parseInt(span.dataset.hoshiSid, 10)
    }));
  }, true);
};
''';

  /// 图片检测 JS。
  ///
  /// 核心思路：highlight 滚动前先调 `__hoshiSaveScrollPos()` 快照当前位置，
  /// 滚动后调 `__hoshiCheckNewImage()` 比较新旧位置之间是否有被跳过的
  /// `<img>`。分页模式下 cue 跳页可能直接越过图片页，viewport 检测抓不到；
  /// 基于滚动距离的检测能覆盖这种场景。
  ///
  /// 同时也检查当前视口（同页图片的情况）。`__hoshiSeenImages` WeakSet 避免
  /// 同一张图重复触发暂停。发现图片后自动把视口滚到图片所在页。
  static const String _imagePauseFn = '''
window.__hoshiSeenImages = window.__hoshiSeenImages || new WeakSet();
window.__hoshiPreScrollPos = -1;

window.__hoshiSaveScrollPos = function() {
  if (typeof window.__ttuGetPageInfo !== 'function') { window.__hoshiPreScrollPos = -1; return; }
  var info = window.__ttuGetPageInfo();
  window.__hoshiPreScrollPos = info ? info.virtualScrollPos : -1;
};

window.__hoshiCheckNewImage = function() {
  var content = document.querySelector('.book-content') ||
                document.querySelector('[class*="book-content"]') ||
                document.scrollingElement || document.documentElement;
  if (!content) return false;
  var imgs = content.querySelectorAll('img');
  if (!imgs || imgs.length === 0) return false;

  if (typeof window.__ttuGetPageInfo !== 'function') return false;
  var info = window.__ttuGetPageInfo();
  if (!info || !info.stride || info.stride < 10) return false;
  var isVertical = info.verticalMode;
  var curScroll = info.virtualScrollPos;
  var stride = info.stride;
  var actualScroll = isVertical ? content.scrollTop : content.scrollLeft;

  var prevScroll = window.__hoshiPreScrollPos;
  var vw = window.innerWidth || 360;
  var vh = window.innerHeight || 640;

  var minPos = (prevScroll >= 0) ? Math.min(prevScroll, curScroll) : curScroll;
  var maxPos = (prevScroll >= 0) ? Math.max(prevScroll, curScroll) : curScroll;

  var bestImg = null;
  var bestImgPos = -1;

  for (var i = 0; i < imgs.length; i++) {
    var img = imgs[i];
    if (window.__hoshiSeenImages.has(img)) continue;
    var w = img.naturalWidth || img.width;
    var h = img.naturalHeight || img.height;
    if (w < 20 && h < 20) continue;
    try {
      var rect = img.getBoundingClientRect();
      if (rect.width < 10 || rect.height < 10) continue;
      var cRect = content.getBoundingClientRect();
      var imgAbsPos = isVertical
        ? (rect.top - cRect.top + actualScroll)
        : (rect.left - cRect.left + actualScroll);

      if (prevScroll >= 0 && Math.abs(maxPos - minPos) > stride * 0.5) {
        if (imgAbsPos >= minPos && imgAbsPos <= maxPos) {
          if (!bestImg || imgAbsPos < bestImgPos) {
            bestImg = img;
            bestImgPos = imgAbsPos;
          }
          continue;
        }
      }

      var inViewport = rect.bottom > 0 && rect.top < vh &&
                       rect.right > 0 && rect.left < vw;
      if (inViewport) {
        if (!bestImg) {
          bestImg = img;
          bestImgPos = imgAbsPos;
        }
      }
    } catch (e) {}
  }

  if (!bestImg) return false;
  window.__hoshiSeenImages.add(bestImg);

  var imgPage = Math.floor(bestImgPos / stride);
  if (imgPage !== info.currentPage) {
    window.__ttuGoToPage(imgPage);
  }
  return true;
};

window.__hoshiClearSeenImages = function() {
  window.__hoshiSeenImages = new WeakSet();
  window.__hoshiPreScrollPos = -1;
};
''';

  /// Reader 位置持久化的 JS 反查 + 跳转 API。
  ///
  /// - `__hibikiGetViewportNormOffset()`：从视口左上探针点反查当前挂载段和
  ///   章内 Sasayaki 归一化字符偏移（和 AudioCue.normCharStart 同基准）。
  ///   用 `caretRangeFromPoint` 找视口顶部第一个可见文本节点，再用 Sasayaki
  ///   那套 walker 逐字符累加到命中位置。用于 Flutter 节流后写 Isar
  ///   [ReaderPosition]。
  /// - `__hibikiScrollToNormOffset(section, offset)`：调用 ttu fork 的
  ///   `__ttuScrollToCharOffset` 把目标位置滚进视口。
  ///
  /// 依赖 `__hoshiIsSkippable`，必须在 _sasayakiFn 之后 evaluate。
  static const String _readerPosFn = '''
window.__hibikiGetSectionRoot = function(sectionIndex) {
  if (typeof window.__ttuGetSectionRef === 'function') {
    var ref = window.__ttuGetSectionRef(sectionIndex);
    if (ref) {
      var el = document.getElementById(ref);
      if (el) return el;
    }
  }
  return document.querySelector('.book-content-container') ||
         document.querySelector('.book-content');
};

window.__hibikiGetViewportNormOffset = function() {
  var section = -1;
  try {
    if (typeof window.__ttuCurrentSection === 'function') {
      var v = window.__ttuCurrentSection();
      if (typeof v === 'number') section = v;
    }
  } catch (e) {}
  if (section < 0) return null;

  var root = window.__hibikiGetSectionRoot(section);
  if (!root) return null;

  var vh = window.innerHeight || 640;
  var vw = window.innerWidth || 360;

  var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
    acceptNode: function(n) {
      var p = n.parentNode;
      while (p && p !== root) {
        var tag = p.nodeName ? p.nodeName.toLowerCase() : '';
        if (tag === 'rt' || tag === 'rp') return NodeFilter.FILTER_REJECT;
        p = p.parentNode;
      }
      return NodeFilter.FILTER_ACCEPT;
    }
  });
  var normPos = 0;
  var node;
  while ((node = walker.nextNode())) {
    var txt = node.nodeValue || '';
    if (!txt) continue;
    var nr = document.createRange();
    nr.selectNodeContents(node);
    var nrect = nr.getBoundingClientRect();
    if (nrect.right < 0 || nrect.bottom < 0) {
      for (var k = 0; k < txt.length; ) {
        var ck = txt.codePointAt(k);
        var wk = (ck > 0xFFFF) ? 2 : 1;
        if (!window.__hoshiIsSkippable(ck)) normPos += wk;
        k += wk;
      }
      continue;
    }
    var overlaps = !(nrect.left > vw || nrect.top > vh);
    if (!overlaps) {
      for (var k = 0; k < txt.length; ) {
        var ck = txt.codePointAt(k);
        var wk = (ck > 0xFFFF) ? 2 : 1;
        if (!window.__hoshiIsSkippable(ck)) normPos += wk;
        k += wk;
      }
      continue;
    }
    for (var k = 0; k < txt.length; ) {
      var ck = txt.codePointAt(k);
      var wk = (ck > 0xFFFF) ? 2 : 1;
      if (!window.__hoshiIsSkippable(ck)) {
        var cr = document.createRange();
        cr.setStart(node, k);
        cr.collapse(true);
        var crect = cr.getBoundingClientRect();
        if (crect.top >= -2 && crect.top < vh &&
            crect.left >= -2 && crect.left < vw &&
            !(crect.width === 0 && crect.height === 0 &&
              crect.left === 0 && crect.top === 0)) {
          return { section: section, offset: normPos };
        }
        normPos += wk;
      }
      k += wk;
    }
  }
  return null;
};

window.__hibikiScrollToNormOffset = function(section, offset, _retryCount) {
  var retry = _retryCount || 0;
  var maxRetries = 15;
  if (!retry) {
    window.__hoshiRestoreToken = (window.__hoshiRestoreToken || 0) + 1;
  }
  var myToken = window.__hoshiRestoreToken;
  function signalDone(ok) {
    try {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('scrollToNormOffsetDone', {success: !!ok});
      }
    } catch(e2) {}
  }
  function signalStable(sec, off, success) {
    try {
      if (window.flutter_inappwebview) {
        window.flutter_inappwebview.callHandler('viewportStable', {
          section: sec, offset: off, success: !!success, token: myToken
        });
      }
    } catch(e2) {}
  }
  function scrollToCharOffset(targetOffset) {
    var root = window.__hibikiGetSectionRoot(section);
    if (!root) return {ok: false, reason: 'no-root'};
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: function(n) {
        var p = n.parentNode;
        while (p && p !== root) {
          var tag = p.nodeName ? p.nodeName.toLowerCase() : '';
          if (tag === 'rt' || tag === 'rp') return NodeFilter.FILTER_REJECT;
          p = p.parentNode;
        }
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    var normPos = 0;
    var node;
    while ((node = walker.nextNode())) {
      var txt = node.nodeValue || '';
      for (var k = 0; k < txt.length; ) {
        var ck = txt.codePointAt(k);
        var wk = (ck > 0xFFFF) ? 2 : 1;
        if (!window.__hoshiIsSkippable(ck)) {
          if (normPos + wk > targetOffset) {
            var r = document.createRange();
            r.setStart(node, k);
            r.collapse(true);
            var rect = r.getBoundingClientRect();
            if (typeof window.__hoshiAlignToRect === 'function') {
              window.__hoshiAlignToRect(rect);
            } else {
              window.scrollBy(0, rect.top - 16);
            }
            return {ok: true};
          }
          normPos += wk;
        }
        k += wk;
      }
    }
    return {ok: false, reason: normPos === 0 ? 'empty' : 'exhausted'};
  }
  function waitStable(targetSection, targetOffset, rescrollsLeft) {
    var stableCount = 0;
    var prevOffset = -1;
    var maxFrames = 45;
    var frame = 0;
    function check() {
      if (myToken !== window.__hoshiRestoreToken) return;
      frame++;
      if (frame > maxFrames) {
        signalStable(targetSection, targetOffset, false);
        return;
      }
      var cur = null;
      try {
        if (typeof window.__hibikiGetViewportNormOffset === 'function') {
          cur = window.__hibikiGetViewportNormOffset();
        }
      } catch(e) {}
      if (!cur) {
        requestAnimationFrame(check);
        return;
      }
      if (cur.section === targetSection && Math.abs(cur.offset - targetOffset) <= 5) {
        if (prevOffset === cur.offset) {
          stableCount++;
        } else {
          stableCount = 1;
          prevOffset = cur.offset;
        }
        if (stableCount >= 6) {
          setTimeout(function() {
            if (myToken !== window.__hoshiRestoreToken) return;
            var recheck = null;
            try {
              if (typeof window.__hibikiGetViewportNormOffset === 'function') {
                recheck = window.__hibikiGetViewportNormOffset();
              }
            } catch(e2) {}
            if (recheck && recheck.section === targetSection &&
                Math.abs(recheck.offset - targetOffset) <= 5) {
              signalStable(recheck.section, recheck.offset, true);
            } else if (rescrollsLeft > 0) {
              rescrollsLeft--;
              scrollToCharOffset(targetOffset);
              stableCount = 0;
              prevOffset = -1;
              frame = 0;
              requestAnimationFrame(check);
            } else {
              signalStable(targetSection, targetOffset, false);
            }
          }, 150);
          return;
        }
        requestAnimationFrame(check);
        return;
      }
      stableCount = 0;
      prevOffset = -1;
      if (rescrollsLeft > 0) {
        rescrollsLeft--;
        scrollToCharOffset(targetOffset);
        frame = 0;
        requestAnimationFrame(check);
        return;
      }
      signalStable(targetSection, targetOffset, false);
    }
    requestAnimationFrame(check);
  }
  try {
    var result = scrollToCharOffset(offset);
    if (!result.ok) {
      if (result.reason !== 'exhausted' && retry < maxRetries) {
        setTimeout(function() {
          window.__hibikiScrollToNormOffset(section, offset, retry + 1);
        }, 100);
        return;
      }
      signalDone(false);
      return;
    }
    requestAnimationFrame(function() {
      signalDone(true);
      waitStable(section, offset, 2);
    });
  } catch (e) {
    signalDone(false);
  }
};
''';

  // ── 公开 API ───────────────────────────────────────────────────────────────

  /// 向 WebView 注入 CSS 样式和 JS 函数（章节加载完成后调用一次）。
  /// [primaryColor] 用于高亮当前句和 hover 效果，跟随应用主题色。
  static Future<void> inject(
    InAppWebViewController controller, {
    Color primaryColor = const Color(0xFFFFDC00),
  }) async {
    final String css = _buildCss(primaryColor);
    final String cssJsonStr = jsonEncode(css);
    // 注入 CSS（主题切换时移除旧样式再插入新样式）
    await controller.evaluateJavascript(source: '''
(function() {
  var existing = document.getElementById('__hoshi_audio_css');
  if (existing) existing.remove();
  var s = document.createElement('style');
  s.id = '__hoshi_audio_css';
  s.textContent = $cssJsonStr;
  var parent = document.head || document.documentElement || document.body;
  if (parent) {
    parent.appendChild(s);
  }
})();
''');

    await controller.evaluateJavascript(source: _highlightFn);
    await controller.evaluateJavascript(source: _sasayakiFn);
    await controller.evaluateJavascript(source: _ttuApiShimFn);
    await controller.evaluateJavascript(source: _annotateFn);
    // _readerPosFn 依赖 __hoshiIsSkippable，必须在 _sasayakiFn 之后 evaluate
    await controller.evaluateJavascript(source: _readerPosFn);
    await controller.evaluateJavascript(source: _imagePauseFn);
  }

  /// highlight 前快照当前滚动位置，供 [checkNewImage] 比较。
  static Future<void> saveScrollPos(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(
      source:
          'if(typeof __hoshiSaveScrollPos!=="undefined")__hoshiSaveScrollPos();',
    );
  }

  /// 检查新旧滚动位置之间或当前视口中是否出现了新图片。
  /// 发现时自动滚到图片页。调用前需先 [saveScrollPos]。
  static Future<bool> checkNewImage(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source:
          '(function(){try{return window.__hoshiCheckNewImage ? window.__hoshiCheckNewImage() : false;}catch(e){return false;}})()',
    );
    return raw == true || raw == 'true';
  }

  /// 切章时清空已见图片记录。
  static Future<void> clearSeenImages(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(
      source:
          'if(typeof __hoshiClearSeenImages!=="undefined")__hoshiClearSeenImages();',
    );
  }

  /// 探测 ttu 侧是否已挂出 PR8a 的 section 导航 API。
  ///
  /// fork 落地前预期全部 `hasXxx` 为 false；落地后为 true。调用方据此填
  /// AudiobookHealth.reason / UI 角标。在 [inject] 之后任何时候调用都行，
  /// 结果反映当次 WebView 上下文。
  ///
  /// 返回结构镜像 `window.__hoshiTtuProbe()` 的 JSON：
  /// `hasGoToSection` / `hasCurrentSection` / `hasSectionCount` /
  /// `sectionCount` / `currentSection`。
  static Future<TtuApiProbe> probeTtuApi(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source:
          'if(typeof __hoshiTtuProbe!=="undefined")__hoshiTtuProbe();',
    );
    if (raw is! String) {
      return const TtuApiProbe.missing();
    }
    try {
      final Map<String, dynamic> json =
          jsonDecode(raw) as Map<String, dynamic>;
      return TtuApiProbe(
        hasGoToSection: json['hasGoToSection'] == true,
        hasCurrentSection: json['hasCurrentSection'] == true,
        hasSectionCount: json['hasSectionCount'] == true,
        sectionCount: (json['sectionCount'] as num?)?.toInt(),
        currentSection: (json['currentSection'] as num?)?.toInt(),
        currentPage: (json['currentPage'] as num?)?.toInt(),
        totalPages: (json['totalPages'] as num?)?.toInt(),
      );
    } catch (_) {
      return const TtuApiProbe.missing();
    }
  }

  /// 请求跳转到指定 section。
  ///
  /// 优先使用 `__sasayakiRequestNav`（有声书桥），它会同步清理 cueMap
  /// 并发 sasayakiNavOk 日志。桥未注入时回退到 ttu fork 的
  /// `__ttuGoToSection`（纯 EPUB 场景）。两者都不存在时最多等 2 秒后报错。
  static Future<void> requestSectionNav(
    InAppWebViewController controller, {
    required int sectionIndex,
  }) async {
    await controller.evaluateJavascript(
      source: '''
(async function(){
  var target = $sectionIndex;
  function sectionCount() {
    try {
      if (typeof __ttuSectionCount === "function") return __ttuSectionCount();
    } catch(e) {}
    try {
      if (typeof __ttuGetToc === "function") return (__ttuGetToc() || []).length;
    } catch(e) {}
    return null;
  }
  function validTarget() {
    var count = sectionCount();
    if (count === null) return true;
    return count > 0 && target >= 0 && target < count;
  }
  try {
    for(var i=0;i<20;i++){
      if(!validTarget()){
        console.log(JSON.stringify({"hibiki-message-type":"sasayakiNavErr",
          "section":target,"error":"section out of range","sectionCount":sectionCount()}));
        return;
      }
      if(typeof __sasayakiRequestNav!=="undefined"){
        await __sasayakiRequestNav(target);
        return;
      }
      if(typeof __ttuGoToSection==="function"){
        await __ttuGoToSection(target);
        console.log(JSON.stringify({"hibiki-message-type":"sasayakiNavOk",
          "section":target}));
        return;
      }
      await new Promise(function(r){setTimeout(r,100)});
    }
    console.log(JSON.stringify({"hibiki-message-type":"sasayakiNavErr",
      "section":target,"error":"bridge not injected after 2s"}));
  } catch(e) {
    console.log(JSON.stringify({"hibiki-message-type":"sasayakiNavErr",
      "section":target,"error":String(e),"sectionCount":sectionCount()}));
  }
})();
''',
    );
  }

  /// 拿 ttu 的章节列表（`window.__ttuGetToc()`）。ttu fork 未就绪时
  /// 返回空列表。
  static Future<List<TtuTocEntry>> fetchToc(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source:
          '(function(){try{return JSON.stringify(window.__ttuGetToc?window.__ttuGetToc():[]);}catch(e){return "[]";}})();',
    );
    if (raw is! String || raw.isEmpty) return const <TtuTocEntry>[];
    try {
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! List) return const <TtuTocEntry>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((Map<String, dynamic> m) => TtuTocEntry(
                index: (m['index'] as num?)?.toInt() ?? -1,
                label: (m['label'] as String?) ?? '',
                parent: m['parent'] as String?,
              ))
          .where((TtuTocEntry e) =>
              e.index >= 0 && !e.label.startsWith('ttu-'))
          .toList(growable: false);
    } catch (_) {
      return const <TtuTocEntry>[];
    }
  }

  /// 触发 ttu 的"添加当前位置为书签"（`window.__ttuBookmarkPage()`）。
  /// fork 已处理 paginated / continuous 分支 + selection bookmark +
  /// database.putBookmark 落库。fork 未落地时是 no-op。
  static Future<void> bookmarkCurrentPage(
    InAppWebViewController controller,
  ) async {
    await controller.evaluateJavascript(
      source:
          '(async function(){try{if(window.__ttuBookmarkPage){await window.__ttuBookmarkPage();}}catch(e){console.error("[hibiki] __ttuBookmarkPage",e);}})();',
    );
  }

  static Future<TtuReaderSettings> getReaderSettings(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source:
          '(function(){try{return JSON.stringify(window.__ttuReaderSettings.get());}catch(e){return "{}";}})();',
    );
    if (raw is String && raw.isNotEmpty && raw != '{}') {
      try {
        final Map<String, dynamic> json =
            jsonDecode(raw) as Map<String, dynamic>;
        return TtuReaderSettings.fromMap(json);
      } catch (e) {
        debugPrint('[Hibiki] failed to parse ttu reader settings: $e');
      }
    }
    return TtuReaderSettings.fromMap(const <String, dynamic>{});
  }

  static Future<void> setReaderSetting(
    InAppWebViewController controller, {
    required String key,
    required Object value,
  }) async {
    final String jsValue;
    if (value is String) {
      jsValue = '"${value.replaceAll('"', r'\"')}"';
    } else if (value is bool) {
      jsValue = value ? 'true' : 'false';
    } else {
      jsValue = '$value';
    }
    await controller.evaluateJavascript(
      source:
          '(function(){try{window.__ttuReaderSettings.set("$key",$jsValue);}catch(e){}})();',
    );
  }

  /// Full-text search across all book sections via ttu's `__ttuSearchBook`.
  static Future<List<BookSearchResult>> searchBook(
    InAppWebViewController controller,
    String query,
  ) async {
    if (query.trim().isEmpty) return const [];
    final String escaped = jsonEncode(query);
    final Object? raw = await controller.evaluateJavascript(
      source:
          '(function(){try{return window.__ttuSearchBook($escaped);}catch(e){return "[]";}})()',
    );
    if (raw == null) return const [];
    final String jsonStr = raw.toString();
    if (jsonStr.isEmpty || jsonStr == 'null') return const [];
    final List<dynamic> list = jsonDecode(jsonStr) as List<dynamic>;
    return list
        .map((e) => BookSearchResult.fromMap(e as Map<String, dynamic>))
        .toList();
  }

  /// 从视口左上探针反查当前挂载段和章内归一化字符偏移。
  ///
  /// null 代表视口里没命中文本节点 / Sasayaki refs 还没挂上 / ttu 还没就位 ——
  /// 调用方直接跳过这一次保存，别拿 offset=0 瞎写（会覆盖之前保存的有效位置）。
  static Future<ReaderViewportPos?> getViewportNormOffset(
    InAppWebViewController controller,
  ) async {
    final Object? raw = await controller.evaluateJavascript(
      source:
          '(function(){try{return JSON.stringify(window.__hibikiGetViewportNormOffset ? (window.__hibikiGetViewportNormOffset()||null) : null);}catch(e){return "null";}})();',
    );
    if (raw is! String || raw.isEmpty || raw == 'null') {
      return null;
    }
    try {
      final dynamic json = jsonDecode(raw);
      if (json is! Map<String, dynamic>) return null;
      final int? section = (json['section'] as num?)?.toInt();
      final int? offset = (json['offset'] as num?)?.toInt();
      if (section == null || section < 0 || offset == null || offset < 0) {
        return null;
      }
      return ReaderViewportPos(section: section, offset: offset);
    } catch (_) {
      return null;
    }
  }

  /// 跳到给定 section + 章内归一化偏移。桥未注入时重试最多 2 秒。
  static Future<void> scrollToNormOffset(
    InAppWebViewController controller, {
    required int section,
    required int offset,
  }) async {
    await controller.evaluateJavascript(
      source: '''
(async function(){
  for(var i=0;i<20;i++){
    if(typeof __hibikiScrollToNormOffset!=="undefined"){
      __hibikiScrollToNormOffset($section, $offset);
      return;
    }
    await new Promise(function(r){setTimeout(r,100)});
  }
  try{if(window.flutter_inappwebview)window.flutter_inappwebview.callHandler('scrollToNormOffsetDone',{success:false});}catch(e){}
})();
''',
    );
  }

  /// 初始化 Sasayaki 路径所需的 `sectionIndex → DOM id` 映射。
  ///
  /// 在 [inject] 之后、首次 [highlight] Sasayaki-encoded cue 之前调用一次；
  /// 异步读 ttu IndexedDB，完成后控制台会打 `sasayakiRefsReady`。
  static Future<void> initSasayakiRefs(
    InAppWebViewController controller, {
    required int ttuBookId,
  }) async {
    await controller.evaluateJavascript(
      source: '''
(async function(){
  for(var i=0;i<20;i++){
    if(typeof __hoshiLoadSasayakiRefs!=="undefined"){
      __hoshiLoadSasayakiRefs($ttuBookId);
      return;
    }
    await new Promise(function(r){setTimeout(r,100)});
  }
})();
''',
    );
  }

  /// 对齐 iOS Sasayaki 的 `applySasayakiCues`：sectionChanged 后把该段所有
  /// cue 传给 WebView，JS 侧一次性 TreeWalker 按 normChar 偏移包 `<span>`
  /// 存进 `__hoshiSasayakiCueMap`。运行期 O(1) Map 查表 + class toggle。
  ///
  /// [cues] 只需包含本段的 Sasayaki cue（非 Sasayaki 的 cue.textFragmentId
  /// 解码会返回 null，调用方已过滤）。同段重复调用会被 JS 侧 appliedForSection
  /// 缓存守卫跳过，不会重新包。
  static Future<void> applySasayakiCues(
    InAppWebViewController controller, {
    required int sectionIndex,
    required List<AudioCue> cues,
  }) async {
    final List<Map<String, dynamic>> payload = <Map<String, dynamic>>[];
    for (final AudioCue cue in cues) {
      final SasayakiFragment? frag =
          SasayakiMatchCodec.tryDecode(cue.textFragmentId);
      if (frag == null) continue;
      if (frag.sectionIndex != sectionIndex) continue;
      payload.add(<String, dynamic>{
        'key': cue.textFragmentId,
        'ns': frag.normCharStart,
        'ne': frag.normCharEnd,
        't': cue.text,
      });
    }
    if (payload.isEmpty) return;
    final String json = jsonEncode(payload);
    await controller.evaluateJavascript(
      source: '''
(async function(){
  if(!document.body&&!document.documentElement)return;
  for(var i=0;i<20;i++){
    if(typeof __hoshiApplySasayakiCues!=="undefined"
       && typeof __ttuWrapCueSpans==="function"){
      __hoshiApplySasayakiCues($sectionIndex, $json);
      return;
    }
    await new Promise(function(r){setTimeout(r,100)});
  }
  console.log(JSON.stringify({
    'hibiki-message-type':'sasayakiApplySkip',
    'reason':'timeout',
    'sectionIndex':$sectionIndex
  }));
})();
''',
    );
  }

  /// 自动标注当前章节的句子（在 [inject] 之后调用）。
  ///
  /// [chapterHref] 用于 click 回传，标识来源章节。
  static Future<void> annotate(
    InAppWebViewController controller, {
    required String chapterHref,
  }) async {
    await controller.evaluateJavascript(
      source:
          'if(typeof __hoshiAnnotate!=="undefined")'
          '__hoshiAnnotate(${jsonEncode(chapterHref)});',
    );
  }

  /// 高亮 [cue] 对应的句子。
  ///
  /// [cue] 为 null 时清除所有高亮。textFragmentId 以 `sasayaki://` 开头时走
  /// Sasayaki 路径（按 sectionIndex + 归一化字符偏移在 DOM 中定位）；否则
  /// 按普通 CSS selector 处理。
  ///
  /// [reveal] 对齐 Sasayaki 原版 `displayCue(cue, reveal:)`：true 时把
  /// cue 滚进视口，false 时**只加高亮 class**，保持用户当前阅读位置不动。
  /// Reader 端一般传
  /// `controller.shouldRevealCurrentCue`（= followAudio && hasPlayedOnce）。
  static Future<void> highlight(
    InAppWebViewController controller, {
    AudioCue? cue,
    bool reveal = true,
  }) async {
    if (cue == null || cue.textFragmentId.isEmpty) {
      await controller.evaluateJavascript(
        source:
            'if(typeof __hoshiHighlight!=="undefined")__hoshiHighlight("");',
      );
      return;
    }
    final String raw = cue.textFragmentId;
    final SasayakiFragment? frag = SasayakiMatchCodec.tryDecode(raw);
    if (frag != null) {
      await controller.evaluateJavascript(
        source:
            'if(typeof __hoshiHighlightSasayakiCueById!=="undefined")'
            'window.__hoshiHighlightSasayakiCueById('
            '${jsonEncode(raw)}, $reveal);',
      );
      return;
    }
    await controller.evaluateJavascript(
      source:
          'if(typeof __hoshiHighlight!=="undefined")'
          '__hoshiHighlight(${jsonEncode(raw)}, $reveal);',
    );
  }

  /// 高亮指定 selector（直接传 selector 字符串，不经过 AudioCue）。
  static Future<void> highlightSelector(
    InAppWebViewController controller, {
    required String selector,
  }) async {
    await controller.evaluateJavascript(
      source:
          'if(typeof __hoshiHighlight!=="undefined")'
          '__hoshiHighlight(${jsonEncode(selector)});',
    );
  }

  /// 为字幕 EPUB 中的 `[data-cue-id]` span 注册点击事件。
  ///
  /// 调用此方法后，点击 span 会向 Flutter 回传
  /// `{hibiki-message-type: 'seekToSentence', chapter: chapterHref, sid: N}`。
  ///
  /// 与 [annotate] 互斥：字幕 EPUB 已有预打标的 span，不需要 annotate。
  ///
  /// 若页面中未找到 `[data-cue-id]` span，会输出 warn 日志但不抛出异常。
  static Future<void> injectCueClickHandler(
    InAppWebViewController controller, {
    required String chapterHref,
  }) async {
    final String chapterJson = jsonEncode(chapterHref);
    await controller.evaluateJavascript(source: '''
(function() {
  if (document.__hoshiCueClickRegistered) return;
  document.__hoshiCueClickRegistered = true;

  var count = document.querySelectorAll('[data-cue-id]').length;
  if (count === 0) {
    console.log('[hibiki] warn: no [data-cue-id] spans found in this page');
  }

  document.addEventListener('click', function(e) {
    var span = e.target.closest('[data-cue-id]');
    if (!span) return;
    var sid = parseInt(span.getAttribute('data-cue-id'), 10);
    if (isNaN(sid)) return;
    console.log(JSON.stringify({
      'hibiki-message-type': 'seekToSentence',
      'chapter': $chapterJson,
      'sid': sid
    }));
  }, true);
})();
''');
  }

  /// 解析 WebView console 消息，若为有声书点击事件则返回 [AudiobookClickEvent]。
  ///
  /// 返回 null 表示消息与有声书无关，调用方应继续正常处理。
  static AudiobookClickEvent? parseMessage(Map<String, dynamic> json) {
    if (json['hibiki-message-type'] != 'seekToSentence') {
      return null;
    }
    final String? sasayakiKey = json['sasayakiKey'] as String?;
    if (sasayakiKey != null && sasayakiKey.isNotEmpty) {
      return AudiobookClickEvent(sasayakiKey: sasayakiKey);
    }
    final String chapter = json['chapter'] as String? ?? '';
    final int sid = (json['sid'] as num?)?.toInt() ?? -1;
    if (sid < 0) {
      return null;
    }
    return AudiobookClickEvent(chapterHref: chapter, sentenceIndex: sid);
  }
}

/// PR8a 的 ttu section 导航 API 探针结果。
///
/// fork 未落地时 [hasGoToSection] / [hasCurrentSection] / [hasSectionCount]
/// 全部为 false，[sectionCount] 与 [currentSection] 为 null。UI 不会显示
/// 跨章自动跳转开关（PR8b 的 "Follow audio"），仅显示 pill 提示。
class TtuApiProbe {
  const TtuApiProbe({
    required this.hasGoToSection,
    required this.hasCurrentSection,
    required this.hasSectionCount,
    this.sectionCount,
    this.currentSection,
    this.currentPage,
    this.totalPages,
  });

  const TtuApiProbe.missing()
      : hasGoToSection = false,
        hasCurrentSection = false,
        hasSectionCount = false,
        sectionCount = null,
        currentSection = null,
        currentPage = null,
        totalPages = null;

  final bool hasGoToSection;
  final bool hasCurrentSection;
  final bool hasSectionCount;
  final int? sectionCount;
  final int? currentSection;
  final int? currentPage;
  final int? totalPages;

  /// 三项都挂上才算 fork 就绪；任何一项缺失都走兼容路径。
  bool get forkReady =>
      hasGoToSection && hasCurrentSection && hasSectionCount;

  /// 人话版摘要，方便写进 `AudiobookHealth.reason` 或 debug 日志。
  String describe() {
    if (forkReady) {
      return 'ttu fork ready (sections=$sectionCount, cur=$currentSection)';
    }
    final List<String> missing = <String>[];
    if (!hasGoToSection) missing.add('goToSection');
    if (!hasCurrentSection) missing.add('currentSection');
    if (!hasSectionCount) missing.add('sectionCount');
    return 'ttu fork missing: ${missing.join(", ")}';
  }
}

/// ttu 章节列表（`__ttuGetToc`）的单项。`index` 可直接传给
/// [AudiobookBridge.requestSectionNav] / ttu fork 的 `__ttuGoToSection`。
class TtuTocEntry {
  const TtuTocEntry({
    required this.index,
    required this.label,
    this.parent,
  });

  final int index;
  final String label;

  /// ttu `Section.parentChapter` —— 父章节 reference 字符串。UI 侧据此
  /// 缩进渲染二级章节（null 表示顶级章节）。
  final String? parent;
}

/// Reader 当前视口在全书中的位置 —— 章内 Sasayaki 归一化字符偏移。
///
/// 跟 AudioCue.normCharStart 同基准（ruby 剥、skippable 跳过），字号 /
/// pageColumns 变了也不会飘。对应 Isar 里的 [ReaderPosition]。
class ReaderViewportPos {
  const ReaderViewportPos({required this.section, required this.offset});
  final int section;
  final int offset;

  @override
  String toString() => 'ReaderViewportPos(section=$section, offset=$offset)';
}

/// ttu 阅读器设定的快照，由 `__ttuReaderSettings.get()` 返回。
class TtuReaderSettings {
  TtuReaderSettings({
    required this.fontSize,
    required this.lineHeight,
    required this.writingMode,
    required this.viewMode,
    required this.theme,
    required this.hideFurigana,
    required this.fontFamilyGroupOne,
    required this.fontFamilyGroupTwo,
  });

  factory TtuReaderSettings.fromMap(Map<String, dynamic> m) {
    return TtuReaderSettings(
      fontSize: (m['fontSize'] as num?)?.toDouble() ?? 20,
      lineHeight: (m['lineHeight'] as num?)?.toDouble() ?? 1.65,
      writingMode: m['writingMode'] as String? ?? 'vertical-rl',
      viewMode: m['viewMode'] as String? ?? 'paginated',
      theme: m['theme'] as String? ?? 'light-theme',
      hideFurigana: m['hideFurigana'] as bool? ?? false,
      fontFamilyGroupOne: m['fontFamilyGroupOne'] as String? ?? 'Noto Serif JP',
      fontFamilyGroupTwo: m['fontFamilyGroupTwo'] as String? ?? 'Noto Sans JP',
    );
  }

  double fontSize;
  double lineHeight;
  String writingMode;
  String viewMode;
  String theme;
  bool hideFurigana;
  String fontFamilyGroupOne;
  String fontFamilyGroupTwo;

  static const List<String> availableThemes = [
    'light-theme',
    'ecru-theme',
    'water-theme',
    'gray-theme',
    'dark-theme',
    'black-theme',
  ];

  static Map<String, String> get themeLabels => {
    'light-theme': t.reader_theme_light,
    'ecru-theme': t.reader_theme_ecru,
    'water-theme': t.reader_theme_water,
    'gray-theme': t.reader_theme_gray,
    'dark-theme': t.reader_theme_dark,
    'black-theme': t.reader_theme_black,
  };
}

/// 用户在 WebView 中点击有声书句子所产生的事件。
class AudiobookClickEvent {
  const AudiobookClickEvent({
    this.chapterHref = '',
    this.sentenceIndex = -1,
    this.sasayakiKey,
  });

  /// 来源章节（EPUB spine href）。
  final String chapterHref;

  /// 点击的句子在章节内的序号（data-hoshi-sid / data-cue-id）。
  final int sentenceIndex;

  /// Sasayaki cue 的 textFragmentId（data-sasayaki-key），非空时优先使用。
  final String? sasayakiKey;
}

class BookSearchResult {
  const BookSearchResult({
    required this.sectionIndex,
    required this.charOffset,
    required this.context,
    required this.matchStart,
  });

  final int sectionIndex;
  final int charOffset;
  final String context;
  final int matchStart;

  factory BookSearchResult.fromMap(Map<String, dynamic> m) {
    return BookSearchResult(
      sectionIndex: (m['sectionIndex'] as num).toInt(),
      charOffset: (m['charOffset'] as num).toInt(),
      context: m['context'] as String? ?? '',
      matchStart: (m['matchStart'] as num?)?.toInt() ?? 0,
    );
  }
}
