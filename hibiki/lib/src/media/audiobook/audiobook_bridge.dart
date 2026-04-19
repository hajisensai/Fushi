import 'dart:convert';

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

  // ── JS / CSS 常量 ──────────────────────────────────────────────────────────

  /// 注入到 WebView 的 CSS（高亮当前句、打标句子 hover 效果）。
  /// 同时覆盖 [data-hoshi-sid]（annotate 路径）和 [data-cue-id]（字幕 EPUB 路径）。
  static const String _css = '''
.hoshi-active {
  background: rgba(255, 220, 0, 0.42);
  border-radius: 2px;
  transition: background 0.15s ease;
}
[data-hoshi-sid], [data-cue-id] {
  cursor: pointer;
}
[data-hoshi-sid]:hover, [data-cue-id]:hover {
  background: rgba(100, 180, 255, 0.18);
  border-radius: 2px;
}
''';

  /// 高亮函数：移除旧高亮并把目标元素滚动到视口内，同时对齐到整页。
  ///
  /// ttu 在 IDB 字幕 EPUB 路径下是**连续滚动模式**：真正的滚动容器是
  /// `.book-content`（scrollHeight 远大于 clientHeight），body 自身
  /// `overflow: hidden`。因此既不能通过 window.scroll 也不能通过
  /// 向 body 派发 wheel 事件来翻页 —— 必须直接赋值 `.book-content.scrollTop`。
  ///
  /// ## 为什么不用 scrollIntoView
  ///
  /// 浏览器默认把目标元素居中到视口中点，scrollTop 停在任意像素上，
  /// 导致页面上方露出上一页残字、下方露出下一页开头，视觉混乱。
  /// 改为**按 clientHeight 整数倍对齐**：计算 cue 在 content 内的
  /// 绝对 top，除以 pageH 取整得到页索引，scrollTop = pageIndex * pageH。
  /// 这样每次跳转看到的都是一整页的内容，没有跨页残留。
  ///
  /// ttu 的 Svelte store 不监听 `.book-content.scrollTop`（它监听页索引），
  /// 外部赋值不会被覆盖。
  ///
  /// ## 收敛策略：ticker
  ///
  /// 保留 `setInterval` 轮询。每 280ms 检查 scrollTop 是否已到目标页，
  /// 已对齐则停；未对齐则再赋值。新 highlight 替换 pending 目标，旧
  /// ticker 自动收敛到新目标。退路：missing 元素重试上限 30 次（≈ 9s），
  /// scroll 失败上限 30 次。
  static const String _highlightFn = '''
window.__hoshiTarget = window.__hoshiTarget || null;
window.__hoshiTickerId = window.__hoshiTickerId || null;
window.__hoshiTickIntervalMs = 280;

window.__hoshiStopTicker = function() {
  if (window.__hoshiTickerId) {
    clearInterval(window.__hoshiTickerId);
    window.__hoshiTickerId = null;
  }
};

window.__hoshiTick = function() {
  var target = window.__hoshiTarget;
  if (!target) { window.__hoshiStopTicker(); return; }
  target.tickNo = (target.tickNo || 0) + 1;

  var el = document.querySelector(target.selector);
  if (!el) {
    target.missAttempts = (target.missAttempts || 0) + 1;
    if (target.tickNo <= 3) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'diagTickMiss',
        'tickNo': target.tickNo,
        'selector': target.selector,
        'totalCueSpans': document.querySelectorAll('[data-cue-id]').length
      }));
    }
    if (target.missAttempts > 30) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'highlightMiss',
        'selector': target.selector,
        'totalCueSpans': document.querySelectorAll('[data-cue-id]').length,
        'attempts': target.missAttempts
      }));
      window.__hoshiTarget = null;
      window.__hoshiStopTicker();
    }
    return;
  }

  // Element exists. Add highlight class (idempotent).
  if (!el.classList.contains('hoshi-active')) {
    document.querySelectorAll('.hoshi-active').forEach(function(e) {
      e.classList.remove('hoshi-active');
    });
    el.classList.add('hoshi-active');
  }

  var rect = el.getBoundingClientRect();

  // Degenerate rect (ttu still hydrating, or element in collapsed/hidden
  // ancestor). NEVER infer direction from (0,0,0,0) — must retry, not stop.
  var isDegenerate = rect.width === 0 && rect.height === 0 &&
                     rect.left === 0 && rect.top === 0;
  if (isDegenerate) {
    target.staleAttempts = (target.staleAttempts || 0) + 1;
    if (target.staleAttempts > 30) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'highlightStale',
        'selector': target.selector,
        'attempts': target.staleAttempts
      }));
      window.__hoshiTarget = null;
      window.__hoshiStopTicker();
    }
    return;
  }

  var content = document.querySelector('.book-content') ||
                document.querySelector('[class*="book-content"]') ||
                document.scrollingElement || document.documentElement;
  var pageH = content.clientHeight;
  if (!pageH || pageH < 10) {
    // 容器尚未布局，下一 tick 再试。
    return;
  }

  // ttu 分页 stride = clientHeight + column-gap（40px 来自
  // .book-content-container 的 CSS `column-gap: 40px`）。单纯用
  // clientHeight 会导致每页漏掉一段 gap，页边界逐渐偏移。
  var container = content.querySelector('.book-content-container');
  var gap = 40;
  if (container) {
    var gapStr = getComputedStyle(container).columnGap;
    var gapNum = parseFloat(gapStr);
    if (!isNaN(gapNum) && gapNum > 0) gap = gapNum;
  }
  var stride = pageH + gap;

  // 把 cue 的 viewport 坐标换算成 content 内 scroll 坐标。
  var cRect = content.getBoundingClientRect();
  var elTopInContent = rect.top - cRect.top + content.scrollTop;
  var elBotInContent = rect.bottom - cRect.top + content.scrollTop;

  // 按 stride 整数倍对齐到 ttu 的视觉页边界。单纯 Math.floor(top/stride)
  // 在 top 卡在 (N+1)*stride 前几像素（落在第 N 页尾 pageH 和下一页开头
  // 之间的 column-gap 区域）时会把 span 误判到第 N 页 —— 真正可见区是
  // [N*stride, N*stride+pageH]，span 顶部已经越过 pageH，滚到 N*stride
  // 后 span 反而跑出视口下方。
  // 改为"选 span 与 [N*stride, N*stride+pageH] 交集最大的那一页"——候选
  // 只看 floor(top/stride) 和 +1 两页。
  function pageVisible(N) {
    var vTop = N * stride;
    var vBot = vTop + pageH;
    return Math.max(0, Math.min(elBotInContent, vBot) -
                       Math.max(elTopInContent, vTop));
  }
  var pageN = Math.floor(elTopInContent / stride);
  var pageIndex = pageN;
  if (pageVisible(pageN + 1) > pageVisible(pageN)) {
    pageIndex = pageN + 1;
  }
  var maxScroll = Math.max(0, content.scrollHeight - pageH);
  var targetScrollTop = Math.max(0, Math.min(pageIndex * stride, maxScroll));

  // 已对齐到目标页：停。
  if (Math.abs(content.scrollTop - targetScrollTop) < 1) {
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
    return;
  }

  target.scrollAttempts = (target.scrollAttempts || 0) + 1;
  if (target.scrollAttempts > 30) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'highlightScrollCap',
      'selector': target.selector,
      'rect': {l: rect.left, t: rect.top, r: rect.right, b: rect.bottom},
      'curScrollTop': content.scrollTop,
      'targetScrollTop': targetScrollTop
    }));
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
    return;
  }

  if (!target.loggedFirstScroll) {
    target.loggedFirstScroll = true;
    console.log(JSON.stringify({
      'hibiki-message-type': 'highlightScrollStart',
      'selector': target.selector,
      'rect': {l: rect.left, t: rect.top, r: rect.right, b: rect.bottom},
      'elTopInContent': elTopInContent,
      'pageH': pageH,
      'gap': gap,
      'stride': stride,
      'pageIndex': pageIndex,
      'targetScrollTop': targetScrollTop,
      'contentScrollTop': content.scrollTop,
      'contentScrollHeight': content.scrollHeight
    }));
  }

  var beforeWrite = content.scrollTop;
  content.scrollTop = targetScrollTop;
  var afterWrite = content.scrollTop;

  // Diagnostic: does the write stick? Svelte store override / read-only
  // container shows up as afterWrite !== targetScrollTop on first write.
  // Also log tickNo to spot Svelte yanking us back on subsequent ticks.
  if (target.scrollAttempts <= 4) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'diagScrollWrite',
      'tickNo': target.tickNo,
      'attempt': target.scrollAttempts,
      'before': beforeWrite,
      'wanted': targetScrollTop,
      'afterImmediate': afterWrite,
      'stuck': Math.abs(afterWrite - targetScrollTop) < 1
    }));
  }
};

window.__hoshiHighlight = function(selector, reveal) {
  // reveal 对齐 Sasayaki displayCue 的 reveal 参数：false 时只加高亮
  // class、不翻页（用户 Follow audio OFF 或尚未 play 时，保持阅读位置）。
  // 省略该参数视为 true，保持兼容。
  if (reveal === undefined) reveal = true;
  console.log(JSON.stringify({
    'hibiki-message-type': 'diagHighlightEntry',
    'selector': selector || '',
    'reveal': reveal,
    'tickerRunning': !!window.__hoshiTickerId,
    'hasBookContent': !!document.querySelector('.book-content')
  }));
  if (!selector) {
    document.querySelectorAll('.hoshi-active').forEach(function(e) {
      e.classList.remove('hoshi-active');
    });
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
    return;
  }
  if (!reveal) {
    // 停掉可能还在跑的老 ticker（之前一次 reveal=true 留下的）并清旧 class，
    // 然后只把目标元素标上 hoshi-active，不进入 ticker 翻页循环。
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
    document.querySelectorAll('.hoshi-active').forEach(function(e) {
      e.classList.remove('hoshi-active');
    });
    var el = document.querySelector(selector);
    if (el) el.classList.add('hoshi-active');
    return;
  }
  // Replace pending target. Old ticker (if running) will pick up the new
  // selector on its next tick — no double loops fighting over page state.
  window.__hoshiTarget = {
    selector: selector, missAttempts: 0, staleAttempts: 0, scrollAttempts: 0
  };
  if (!window.__hoshiTickerId) {
    window.__hoshiTickerId = setInterval(
      window.__hoshiTick, window.__hoshiTickIntervalMs);
  }
  // Run once immediately so single-page case doesn't wait 280ms.
  window.__hoshiTick();
};
''';

  /// Sasayaki 路径的辅助 JS：
  ///
  /// - `__hoshiLoadSasayakiRefs(ttuBookId)`：从 ttu IndexedDB 读 `sections` +
  ///   `elementHtml`，缓存 `sectionIndex → reference` 和每个 section 的
  ///   **归一化文本长度**（以及累计起点）。ttu 在渲染时会剥掉 section
  ///   原始 id，所以我们放弃"找章节根"这条路，改为用"整本书归一化偏移"
  ///   在 `.book-content-container` 里定位。
  /// - `__hoshiIsSkippable(code)`：镜像 Dart 的 `EpubSrtMatcher._isKeepable`
  ///   的反函数。白名单规则（只留假名/汉字/字母数字），其余一律视为可跳过。
  /// - `__hoshiUnwrapSasayaki()`：拆掉上一次 Sasayaki 高亮包裹的 span。
  /// - `__hoshiHighlightSasayaki(s, ns, ne)`：把 (sectionIndex, normChar*)
  ///   换算成全书归一化全局偏移 → 在 `.book-content-container` 里按归一化
  ///   字符数走 text node 找到 Range → 包 `span.hoshi-active` → 触发 ticker
  ///   滚动。
  ///
  /// 与字幕 EPUB 路径（`[data-cue-id]`）互不冲突：入口在 Dart 侧的
  /// [highlight] 根据 `textFragmentId` 前缀分派。
  static const String _sasayakiFn = '''
window.__hoshiSasayakiRefs = window.__hoshiSasayakiRefs || null;
window.__hoshiSasayakiSectionStarts = window.__hoshiSasayakiSectionStarts || null;
window.__hoshiSasayakiSectionFirstChars = window.__hoshiSasayakiSectionFirstChars || null;
window.__hoshiSasayakiSectionLens = window.__hoshiSasayakiSectionLens || null;
window.__hoshiSasayakiTotalNorm = (typeof window.__hoshiSasayakiTotalNorm === 'number')
  ? window.__hoshiSasayakiTotalNorm : null;
window.__hoshiCurrentMountedSection = (typeof window.__hoshiCurrentMountedSection === 'number')
  ? window.__hoshiCurrentMountedSection : -1;

window.__hoshiLoadSasayakiRefs = function(ttuBookId) {
  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiRefsLoading',
    'ttuBookId': ttuBookId
  }));
  try {
    var req = indexedDB.open('books');
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
          for (var i = 0; i < t.length; i++) {
            if (!window.__hoshiIsSkippable(t.charCodeAt(i))) n++;
          }
          return n;
        }

        // 与运行期 DOM measure 的 firstChars 取样口径严格一致：
        // 只收非 skippable 字符，最多 32 个。用于后续按章节首字识别
        // ttu 当前挂载的是哪一段。
        function firstNormChars(t, cap) {
          var out = '';
          for (var i = 0; i < t.length && out.length < cap; i++) {
            var c = t.charCodeAt(i);
            if (!window.__hoshiIsSkippable(c)) out += t[i];
          }
          return out;
        }

        function stripRubyText(el) {
          var clone = el.cloneNode(true);
          var rts = clone.querySelectorAll('rt, rp');
          for (var j = 0; j < rts.length; j++) rts[j].parentNode.removeChild(rts[j]);
          return clone.textContent || '';
        }

        var refs = [];
        var starts = [];
        var firsts = [];
        var sectionLens = [];
        var cumulative = 0;
        for (var i = 0; i < sections.length; i++) {
          var ref = (sections[i] && sections[i].reference) || '';
          refs.push(ref);
          starts.push(cumulative);
          var el = ref ? doc.getElementById(ref) : null;
          var text = el ? stripRubyText(el) : '';
          firsts.push(firstNormChars(text, 32));
          var segLen = normLen(text);
          sectionLens.push(segLen);
          cumulative += segLen;
        }
        window.__hoshiSasayakiRefs = refs;
        window.__hoshiSasayakiSectionStarts = starts;
        window.__hoshiSasayakiSectionFirstChars = firsts;
        window.__hoshiSasayakiSectionLens = sectionLens;
        window.__hoshiSasayakiTotalNorm = cumulative;
        // 强制下一次 highlight 重新识别当前挂载段（载入后 rootTextLen 可能
        // 相同但 section 定义换了）。
        window.__hoshiDomMeasuredFor = -1;
        window.__hoshiCurrentMountedSection = -1;
        // sectionLens 已在上面按段累计时记下，方便和 Dart matcher 的
        // [sasayaki] matcher.section[N] 日志逐行比对。两侧任何一行的
        // normLen 不一样就是 normalize 规则 / ruby 处理 / DOMParser 行为
        // 的偏移，立刻能定位到具体哪段崩了。
        // 单条消息太长会被 Android logcat 截断，把大数组拆短条打。
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiRefsReady',
          'count': refs.length,
          'totalNormChars': cumulative
        }));
        for (var pi = 0; pi < refs.length; pi++) {
          console.log(JSON.stringify({
            'hibiki-message-type': 'sasayakiRefsSection',
            'i': pi,
            'ref': refs[pi],
            'start': starts[pi],
            'normLen': sectionLens[pi]
          }));
        }
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
  // 与 Dart EpubSrtMatcher._isKeepable 对应的"反函数"：只要不在白名单里
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
  if (c >= 0xFF10 && c <= 0xFF19) return false; // ０-９
  if (c >= 0xFF21 && c <= 0xFF3A) return false; // Ａ-Ｚ
  if (c >= 0xFF41 && c <= 0xFF5A) return false; // ａ-ｚ
  if (c >= 0xFF66 && c <= 0xFF9D) return false; // ｦ-ﾝ
  return true;
};

window.__hoshiUnwrapSasayaki = function() {
  var spans = document.querySelectorAll('span.hoshi-active');
  for (var i = 0; i < spans.length; i++) {
    var span = spans[i];
    var p = span.parentNode;
    if (!p) continue;
    while (span.firstChild) p.insertBefore(span.firstChild, span);
    p.removeChild(span);
    if (p.normalize) p.normalize();
  }
};

window.__hoshiHighlightSasayaki = function(sectionIndex, normCharStart, normCharEnd, expectedCue, reveal) {
  if (reveal === undefined) reveal = true;
  var starts = window.__hoshiSasayakiSectionStarts;
  var refs = window.__hoshiSasayakiRefs;
  if (!starts || !refs) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiRefsMissing',
      'sectionIndex': sectionIndex
    }));
    return;
  }
  if (sectionIndex < 0 || sectionIndex >= starts.length) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiNoRef',
      'sectionIndex': sectionIndex,
      'total': starts.length
    }));
    return;
  }

  // 实测 ttu **只挂载当前 section** 的 DOM 到 .book-content-container（rootText
  // 长度恰好等于当前段 normLen），不是全书共用一个容器。所以 walker 的
  // normPos=0 就是当前段起点，target 直接用段内偏移 (normCharStart/End)，
  // 不能再加 starts[sectionIndex] —— 以前加了 base 等于往后多走了前面所有
  // 段的字符数，高亮就落到后一句。
  //
  // 代价是：如果 cue 的 sectionIndex 与用户当前挂载的 section 不同，walker
  // 会在当前段内找不到（normCharStart 可能超出当前段长度），走 offsetMissing
  // 分支降级。跨 section 自动跳章要等 PR8a ttu fork API 落地。
  var base = starts[sectionIndex];
  var targetStart = normCharStart;
  var targetEnd = normCharEnd;

  var root = document.querySelector('.book-content-container') ||
             document.querySelector('.book-content');
  if (!root) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiContainerMissing'
    }));
    return;
  }

  // ttu 实测默认停在封面：`.book-content-container` 只装封面 SVG，正文
  // 要用户点进去才挂载。rootTextLen 很小（封面通常 < 50 字）说明还在封面。
  // 为了排查 "挂载状态何时变化"，按 tick 序号采样打（前 3 次 + 每 20 次一次），
  // 既能捕捉状态翻转也不会刷屏。
  var rootTextLen = root.textContent ? root.textContent.length : 0;
  if (rootTextLen < 80) {
    window.__hoshiNotMountedCount = (window.__hoshiNotMountedCount || 0) + 1;
    if (window.__hoshiNotMountedCount <= 3 ||
        window.__hoshiNotMountedCount % 20 === 0) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiBookNotMounted',
        'rootTextLen': rootTextLen,
        'count': window.__hoshiNotMountedCount,
        'hint': 'navigate past cover to mount chapter text'
      }));
    }
    return;
  }
  // 挂载上了就清零计数，用户翻回封面再翻回来还能重新打挂载日志。
  window.__hoshiNotMountedCount = 0;

  // 测 walker 看到的 root 里总 norm 字符数 + 首尾采样。用 rootTextLen
  // 作脏标记：rootTextLen 变了说明 ttu 切换了 section 挂载内容，要重新
  // 测。否则一段内反复测浪费 CPU。
  if (window.__hoshiDomMeasuredFor !== rootTextLen) {
    window.__hoshiDomMeasuredFor = rootTextLen;
    try {
      var measureWalker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
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
      var totalNorm = 0;
      var firstChars = '';
      var sampleAt1000 = '';
      var sampleAt10000 = '';
      var mnode;
      while ((mnode = measureWalker.nextNode())) {
        var mtxt = mnode.nodeValue || '';
        for (var mi = 0; mi < mtxt.length; mi++) {
          var mc = mtxt.charCodeAt(mi);
          if (window.__hoshiIsSkippable(mc)) continue;
          if (totalNorm < 32) firstChars += mtxt[mi];
          if (totalNorm === 1000) sampleAt1000 = '';
          if (totalNorm >= 1000 && sampleAt1000.length < 32) sampleAt1000 += mtxt[mi];
          if (totalNorm === 10000) sampleAt10000 = '';
          if (totalNorm >= 10000 && sampleAt10000.length < 32) sampleAt10000 += mtxt[mi];
          totalNorm++;
        }
      }
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiDomMeasure',
        'rootTotalNormChars': totalNorm,
        'rootTextContentLen': root.textContent ? root.textContent.length : 0,
        'firstChars': firstChars,
        'sampleAt1000': sampleAt1000,
        'sampleAt10000': sampleAt10000
      }));

      // ── 识别 ttu 当前挂载的是哪一段 ──
      // ttu 只挂当前 section；如果播放中的 cue 指向别的 section 而我们
      // 仍按"段内偏移"去 walker 找字符，在当前段长度足够长时会命中一个
      // **错误的句子**，然后 ticker 把页面滚到远离真实播放位置的地方。
      // 通过首字 + normLen 匹配找出真正挂载的段 idx，供 highlight 主逻辑
      // 做跨段短路判断。
      var mounted = -1;
      var secFirsts = window.__hoshiSasayakiSectionFirstChars;
      var secLens = window.__hoshiSasayakiSectionLens;
      // 首字匹配：每段前 32 个归一化字符，取前 16 个比对（够区分且抗
      // 段首空白 / 标点 / 章号差异的鲁棒性更好）。
      if (secFirsts && firstChars && firstChars.length > 0) {
        var probe = firstChars.slice(0, 16);
        if (probe.length >= 8) {
          for (var si = 0; si < secFirsts.length; si++) {
            var sf = secFirsts[si];
            if (sf && sf.slice(0, probe.length) === probe) {
              mounted = si;
              break;
            }
          }
        }
      }
      // 首字没匹中（少数纯数字/罗马数字章首）→ 退回 normLen 精确匹配。
      // 多段同长时取第一个；极少见，日志里能看出。
      if (mounted === -1 && secLens) {
        for (var sj = 0; sj < secLens.length; sj++) {
          if (secLens[sj] === totalNorm) {
            mounted = sj;
            break;
          }
        }
      }
      window.__hoshiCurrentMountedSection = mounted;
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiMountedSection',
        'mountedSection': mounted,
        'rootTotalNormChars': totalNorm,
        'firstCharsProbe': firstChars ? firstChars.slice(0, 16) : ''
      }));
    } catch (me) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiDomMeasureErr',
        'error': String(me)
      }));
    }
  }

  // ── 跨段短路 ──
  // DOM 测出的挂载段 != cue 要高亮的段 → 立刻 return，不调 walker、不动
  // 页面。避免"段内偏移命中错误句子 → 滚到无关位置"。高亮留空，等用户
  // 翻到正确段（或 Follow audio 自动跳段）再次 tick 时恢复。
  var mountedSec = window.__hoshiCurrentMountedSection;
  if (mountedSec >= 0 && mountedSec !== sectionIndex) {
    window.__hoshiSectionMismatchCount = (window.__hoshiSectionMismatchCount || 0) + 1;
    if (window.__hoshiSectionMismatchCount <= 3 ||
        window.__hoshiSectionMismatchCount % 20 === 0) {
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiSectionMismatch',
        'mountedSection': mountedSec,
        'cueSection': sectionIndex,
        'count': window.__hoshiSectionMismatchCount,
        'hint': 'cue belongs to a different section; skipping highlight'
      }));
    }
    // 清一次旧高亮避免"上一条高亮留在错误位置"。
    window.__hoshiUnwrapSasayaki();
    var stale = document.querySelectorAll('.hoshi-active');
    for (var sli = 0; sli < stale.length; sli++) {
      stale[sli].classList.remove('hoshi-active');
    }
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
    return;
  }
  // 匹配上了就清 mismatch 计数。
  window.__hoshiSectionMismatchCount = 0;

  // Clear any previous Sasayaki wrap + class-only legacy highlight BEFORE
  // walking, so offsets into text nodes aren't affected by artificial spans.
  window.__hoshiUnwrapSasayaki();
  var legacy = document.querySelectorAll('.hoshi-active');
  for (var li = 0; li < legacy.length; li++) {
    legacy[li].classList.remove('hoshi-active');
  }

  // Walk text nodes under root, skipping <rt>/<rp> (furigana). Dart 侧
  // 匹配用的是剥掉振假名的纯正文；这里必须对齐，否则带 ruby 的章节每过
  // 一段就被读音的额外字符挤偏，高亮会漂到后面几十字。
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
  var startNode = null, startOffset = 0;
  var endNode = null, endOffset = 0;
  var normPos = 0;
  var lastNode = null;
  // 顺便累积 walker 视角的 **纯化文本**（跳过 rt/rp + skippable）。
  // 不能用 range.toString() 做 match 对账：DOM Range 规范会把 Range 跨越
  // 的所有 Text 节点内容拼进去（包括被 walker 跳过的 <rt> 振假名），对
  // 日文带 ruby 的正文必然比 expectedCue 多出一串假名，match 永远假阳性。
  var actualNormText = '';
  var node;
  while ((node = walker.nextNode())) {
    lastNode = node;
    var text = node.nodeValue || '';
    for (var i = 0; i < text.length; i++) {
      var c = text.charCodeAt(i);
      if (window.__hoshiIsSkippable(c)) continue;
      if (startNode === null && normPos >= targetStart) {
        startNode = node;
        startOffset = i;
      }
      if (startNode !== null && normPos < targetEnd) {
        actualNormText += text[i];
      }
      normPos++;
      if (startNode !== null && normPos >= targetEnd) {
        endNode = node;
        endOffset = i + 1;
        break;
      }
    }
    if (endNode !== null) break;
  }

  // targetEnd 超出全书归一化字符数（最后几章的 cue、或 matcher 溢出到尾部）
  // 时高亮到尾节点结束。
  if (startNode !== null && endNode === null && lastNode !== null) {
    endNode = lastNode;
    endOffset = lastNode.nodeValue ? lastNode.nodeValue.length : 0;
  }

  if (!startNode || !endNode) {
    // targetStart 超过当前挂载章节的归一化字符数——cue 在尚未挂载的
    // 章节里。ttu 只在当前显示章节挂载 DOM，用户翻过去就行。
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiOffsetMissing',
      'sectionIndex': sectionIndex,
      'targetStart': targetStart,
      'targetEnd': targetEnd,
      'scannedChars': normPos
    }));
    return;
  }

  var range = document.createRange();
  try {
    range.setStart(startNode, startOffset);
    range.setEnd(endNode, endOffset);
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiRangeErr',
      'error': String(e)
    }));
    return;
  }

  // ★ 关键诊断：在包裹 span 之前用 walker 累积的纯化文本与 expectedCue
  // 直接对账。两者不同 → sectionIndex/normChar 偏移或 normalize 规则有
  // 问题；两者相同但用户视觉上仍错位 → 渲染层 bug（Svelte 重渲染吃掉
  // span 之类）。注意不能用 range.toString()：Range 会把跨越的 <rt>
  // 假名一起拼进字符串，对带 ruby 的正文永远假阳性。
  var actualText = actualNormText;

  // ── 兜底：cue 文本对不上时按 indexOf 重定位 ──
  // 按 Dart 侧 normChar 偏移定位到的 range 落在错位的句子上（ttu 渲染
  // 期对 HTML 做了 Dart 侧 DOMParser 不会做的改写时触发）。用 expectedCue
  // normalize 后的串在当前挂载段里 indexOf 定位，按"离原 targetStart 最
  // 近"的命中重建 range。找不到就放弃本条，不 wrap、不滚动、保持视口不动。
  function normKeep(t) {
    var b = '';
    for (var i = 0; i < t.length; i++) {
      if (!window.__hoshiIsSkippable(t.charCodeAt(i))) b += t[i];
    }
    return b;
  }
  var normActual = actualNormText;
  var normExpected = normKeep(expectedCue || '');
  var usedFallback = false;
  var fallbackDelta = 0;
  if (normExpected.length >= 4 && normActual !== normExpected) {
    var fbNodes = [];
    var fbMap = [];
    var fbStr = '';
    var fbWalker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
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
    var fbNode;
    while ((fbNode = fbWalker.nextNode())) {
      var ti = fbNodes.length;
      fbNodes.push(fbNode);
      var ftext = fbNode.nodeValue || '';
      for (var fi = 0; fi < ftext.length; fi++) {
        var fc = ftext.charCodeAt(fi);
        if (window.__hoshiIsSkippable(fc)) continue;
        fbStr += ftext[fi];
        fbMap.push([ti, fi]);
      }
    }
    // 选离原 targetStart 最近的命中——同一段内同句多次出现时避免 indexOf
    // 总是挑第一个。
    var bestIdx = -1;
    var bestDelta = Infinity;
    var from = 0;
    while (from <= fbStr.length - normExpected.length) {
      var p = fbStr.indexOf(normExpected, from);
      if (p < 0) break;
      var d = Math.abs(p - targetStart);
      if (d < bestDelta) { bestDelta = d; bestIdx = p; }
      from = p + 1;
    }
    if (bestIdx >= 0 && bestIdx + normExpected.length <= fbMap.length) {
      var sMap = fbMap[bestIdx];
      var eMap = fbMap[bestIdx + normExpected.length - 1];
      startNode = fbNodes[sMap[0]];
      startOffset = sMap[1];
      endNode = fbNodes[eMap[0]];
      endOffset = eMap[1] + 1;
      try {
        range = document.createRange();
        range.setStart(startNode, startOffset);
        range.setEnd(endNode, endOffset);
        // 走 fbStr 切片而不是 range.toString()：后者会把 Range 跨越的
        // <rt>/<rp> 拼进来导致日志假阳性。
        actualText = fbStr.slice(bestIdx, bestIdx + normExpected.length);
        usedFallback = true;
        fallbackDelta = bestIdx - targetStart;
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiHighlightFallback',
          'sectionIndex': sectionIndex,
          'origNormStart': targetStart,
          'foundNormStart': bestIdx,
          'delta': fallbackDelta,
          'fbStrLen': fbStr.length
        }));
      } catch (fbErr) {
        console.log(JSON.stringify({
          'hibiki-message-type': 'sasayakiHighlightFallbackErr',
          'error': String(fbErr)
        }));
        return;
      }
    } else {
      // 当前段里确实找不到这条 cue —— 要么 cue 指向别段而挂载识别误判，
      // 要么 cue 文本来源（字幕）和当前章节正文差异超出 indexOf 能容忍的
      // 范围。保持视口不动，放弃本条高亮，等下一条对得上的 cue 恢复。
      var stale3 = document.querySelectorAll('.hoshi-active');
      for (var sl3 = 0; sl3 < stale3.length; sl3++) {
        stale3[sl3].classList.remove('hoshi-active');
      }
      window.__hoshiTarget = null;
      window.__hoshiStopTicker();
      console.log(JSON.stringify({
        'hibiki-message-type': 'sasayakiHighlightFallbackMiss',
        'sectionIndex': sectionIndex,
        'fbStrLen': fbStr.length,
        'normExpectedLen': normExpected.length,
        'expectedHead': normExpected.slice(0, 16)
      }));
      return;
    }
  }

  var span = document.createElement('span');
  span.className = 'hoshi-active';
  try {
    span.appendChild(range.extractContents());
    range.insertNode(span);
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiWrapErr',
      'error': String(e)
    }));
    return;
  }

  function clip(s, n) {
    if (!s) return '';
    s = String(s).replace(/\\n/g, '\\\\n').replace(/\\r/g, '\\\\r');
    return s.length <= n ? s : s.slice(0, n) + '…';
  }

  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiHighlightOk',
    'sectionIndex': sectionIndex,
    'normCharStart': normCharStart,
    'normCharEnd': normCharEnd,
    'targetStart': targetStart,
    'targetEnd': targetEnd,
    'base': base,
    'expectedCue': clip(expectedCue, 32),
    'actualText': clip(actualText, 32),
    'usedFallback': usedFallback,
    'fallbackDelta': fallbackDelta,
    'match': (actualText && expectedCue)
      ? (function() {
          // 用 normalize 后的串比，避免标点差异造成误报
          function norm(t) {
            var b = '';
            for (var i = 0; i < t.length; i++) {
              if (!window.__hoshiIsSkippable(t.charCodeAt(i))) b += t[i];
            }
            return b;
          }
          return norm(actualText) === norm(expectedCue);
        })()
      : null
  }));

  // Reuse existing ticker to scroll to the freshly wrapped span. reveal=false
  // 时（Follow audio OFF / 未 play）跳过 ticker 翻页——span 已经带上
  // hoshi-active class，视觉高亮已达成，但视口保持用户当前位置。
  if (reveal) {
    window.__hoshiHighlight('.hoshi-active', true);
  } else {
    // 停掉可能残留的 ticker（上一条 cue reveal=true 启动的），否则它会
    // 把刚包好的 span 滚进视口，和 reveal=false 的承诺不符。
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
  }
};

// ── 章节挂载时批量预包 span + Map 缓存 ─────────────────────────────────
// 对齐 Sasayaki 原版 reader.js 的 applySasayakiCues / cueWrappers Map /
// highlightSasayakiCue(id) 模型。动机：原有 __hoshiHighlightSasayaki 每次
// 高亮都 TreeWalker 扫一遍整章归一化字符再切 Range，每句触发一次，成本高；
// 改成"章节挂载时一次性遍历，按 normChar 偏移把这一章所有 cue 预先包成
// <span class="hoshi-sasayaki-cue" data-sasayaki-cue-id="...">，cueKey → spans[]
// 塞进 Map"，运行期 O(1) 查表加 class 即可。
//
// cueKey = Dart 侧 cue.textFragmentId（形如 "sasayaki://s=0&ns=100&ne=120"），
// 稳定唯一，不需要单独 id 空间。
//
// 降级：apply 失败（cue 跨节点、跨段、offsetMissing 等）时 Map 里没有 key，
// __hoshiHighlightSasayakiCueById 会自己回退到旧的偏移定位路径 __hoshiHighlightSasayaki，
// 所以全章匹配率不是 100% 也能工作。
window.__hoshiSasayakiCueMap = window.__hoshiSasayakiCueMap || null;
window.__hoshiSasayakiAppliedForSection =
  (typeof window.__hoshiSasayakiAppliedForSection === 'number')
    ? window.__hoshiSasayakiAppliedForSection : -1;
window.__hoshiSasayakiAppliedRootLen =
  (typeof window.__hoshiSasayakiAppliedRootLen === 'number')
    ? window.__hoshiSasayakiAppliedRootLen : -1;

window.__hoshiClearSasayakiApplied = function() {
  // 卸载上一次挂载章节留下的 span 包裹：ttu 切章时 .book-content-container
  // 的旧 innerHTML 会被卸掉，理论上包裹也跟着消失；保留这个方法做显式
  // cleanup，用在"同一章重复 apply 前先解包"的场景（例如 refs 重新载入）。
  if (!window.__hoshiSasayakiCueMap) return;
  try {
    var it = window.__hoshiSasayakiCueMap.values();
    var step = it.next();
    while (!step.done) {
      var spans = step.value;
      for (var i = 0; i < spans.length; i++) {
        var sp = spans[i];
        var p = sp.parentNode;
        if (!p) continue;
        while (sp.firstChild) p.insertBefore(sp.firstChild, sp);
        p.removeChild(sp);
        if (p.normalize) p.normalize();
      }
      step = it.next();
    }
  } catch (e) {
    // Map 迭代失败不致命；下次 apply 会重建。
  }
  window.__hoshiSasayakiCueMap = null;
};

window.__hoshiApplySasayakiCues = function(sectionIndex, cuesJson) {
  // cuesJson：[{key, ns, ne}, ...]，ns/ne 是**段内归一化字符偏移**（Sasayaki
  // 路径 ttu 只挂当前段，不是全书字符）。按 ns 升序排好；调用方保证 ns 单调
  // 不减且 ne >= ns。TreeWalker 一次线性扫，累积 normPos，匹配到就切 Range 包。
  var cues;
  try {
    cues = (typeof cuesJson === 'string') ? JSON.parse(cuesJson) : cuesJson;
  } catch (e) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplyParseErr',
      'error': String(e)
    }));
    return;
  }
  if (!Array.isArray(cues) || cues.length === 0) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplySkip',
      'reason': 'no_cues',
      'sectionIndex': sectionIndex
    }));
    return;
  }
  var root = document.querySelector('.book-content-container') ||
             document.querySelector('.book-content');
  if (!root) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplyNoRoot'
    }));
    return;
  }
  var rootTextLen = root.textContent ? root.textContent.length : 0;
  if (rootTextLen < 80) {
    // 封面 / 尚未挂载，别包；等下次 mountedSection 事件。
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplySkip',
      'reason': 'root_too_short',
      'rootTextLen': rootTextLen
    }));
    return;
  }
  // 同一段 + 同一 root 已经 apply 过就跳过。ttu 切章会换 root innerHTML，
  // rootLen 通常随之变化；同段重复 apply 的情况主要来自 sasayakiMountedSection
  // 连发两条消息。
  if (window.__hoshiSasayakiAppliedForSection === sectionIndex &&
      window.__hoshiSasayakiAppliedRootLen === rootTextLen &&
      window.__hoshiSasayakiCueMap &&
      window.__hoshiSasayakiCueMap.size > 0) {
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiApplySkip',
      'reason': 'already_applied',
      'sectionIndex': sectionIndex,
      'mapSize': window.__hoshiSasayakiCueMap.size
    }));
    return;
  }
  // 切段/换 root：先卸掉旧包裹，释放旧 Map。
  window.__hoshiClearSasayakiApplied();
  window.__hoshiSasayakiCueMap = new Map();

  // 按 ns 升序，防止外部没排好序；同 ns 按 ne 升序作次序。
  cues.sort(function(a, b) {
    if (a.ns !== b.ns) return a.ns - b.ns;
    return (a.ne || 0) - (b.ne || 0);
  });

  // 采集 text node + 归一化字符 → 原节点/节点内 offset 的映射，一次性建好
  // 再批量包 span。不能边扫边 surroundContents：一旦包了 span，DOM 结构变，
  // TreeWalker 的 nextNode 会跳到新插入的 span 内，后续偏移全乱。
  var fbNodes = [];
  var fbMap = [];   // [nodeIdx, charIdx]，长度 = 归一化字符总数
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
  var node;
  while ((node = walker.nextNode())) {
    var ti = fbNodes.length;
    fbNodes.push(node);
    var text = node.nodeValue || '';
    for (var i = 0; i < text.length; i++) {
      if (window.__hoshiIsSkippable(text.charCodeAt(i))) continue;
      fbMap.push([ti, i]);
    }
  }

  var applied = 0;
  var skippedOob = 0;    // 偏移越界
  var skippedCross = 0;  // 跨 text node（当前用 surroundContents，不支持跨节点；留给 fallback 处理）
  for (var ci = 0; ci < cues.length; ci++) {
    var c = cues[ci];
    var ns = c.ns | 0;
    var ne = c.ne | 0;
    if (ne <= ns) { skippedOob++; continue; }
    if (ns < 0 || ne > fbMap.length) { skippedOob++; continue; }
    var sMap = fbMap[ns];
    var eMap = fbMap[ne - 1];
    if (!sMap || !eMap) { skippedOob++; continue; }
    var startNode = fbNodes[sMap[0]];
    var startOffset = sMap[1];
    var endNode = fbNodes[eMap[0]];
    var endOffset = eMap[1] + 1;

    // 跨 text node 的 cue：surroundContents 会失败（DOMException）。直接
    // 跳过留给 __hoshiHighlightSasayakiCueById 的 fallback 用旧路径处理。
    // 这类 cue 通常是跨 <b>/<rt> 包边的长句，占比很小，性能损失可忽略。
    if (startNode !== endNode) { skippedCross++; continue; }

    try {
      var range = document.createRange();
      range.setStart(startNode, startOffset);
      range.setEnd(endNode, endOffset);
      var span = document.createElement('span');
      span.className = 'hoshi-sasayaki-cue';
      span.setAttribute('data-sasayaki-cue-id', c.key);
      range.surroundContents(span);
      // Map 里存数组：未来要支持跨节点拆分时多段 span 都要加 active。
      var arr = window.__hoshiSasayakiCueMap.get(c.key);
      if (!arr) {
        arr = [];
        window.__hoshiSasayakiCueMap.set(c.key, arr);
      }
      arr.push(span);
      applied++;
    } catch (e) {
      skippedCross++;
    }
  }

  window.__hoshiSasayakiAppliedForSection = sectionIndex;
  window.__hoshiSasayakiAppliedRootLen = rootTextLen;

  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiApplied',
    'sectionIndex': sectionIndex,
    'cuesTotal': cues.length,
    'applied': applied,
    'skippedOob': skippedOob,
    'skippedCross': skippedCross,
    'mapSize': window.__hoshiSasayakiCueMap.size
  }));
};

window.__hoshiHighlightSasayakiCueById = function(key, reveal) {
  if (reveal === undefined) reveal = true;
  var map = window.__hoshiSasayakiCueMap;
  var spans = map ? map.get(key) : null;
  if (!spans || spans.length === 0) {
    // Map 未建 / 该 cue 跨节点没包进去 → 回退旧 walker 路径。Dart 侧
    // 不感知，保持单一入口。
    console.log(JSON.stringify({
      'hibiki-message-type': 'sasayakiCueMapMiss',
      'key': key,
      'hasMap': !!map,
      'mapSize': map ? map.size : 0
    }));
    return false;
  }
  // 清旧 active（来自上一条 cue 的这批 span，或者旧偏移路径留下的
  // hoshi-active）；和旧 wrap span 共用 .hoshi-active class，所以统一 classList。
  document.querySelectorAll('.hoshi-active').forEach(function(e) {
    e.classList.remove('hoshi-active');
  });
  for (var i = 0; i < spans.length; i++) {
    spans[i].classList.add('hoshi-active');
  }
  console.log(JSON.stringify({
    'hibiki-message-type': 'sasayakiCueHighlightOk',
    'key': key,
    'spanCount': spans.length,
    'reveal': reveal
  }));
  if (reveal) {
    // 复用现有 ticker：.hoshi-active 选到第一个 span，按页对齐滚动。
    window.__hoshiHighlight('.hoshi-active', true);
  } else {
    window.__hoshiTarget = null;
    window.__hoshiStopTicker();
  }
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
    if (typeof window.__ttuGoToSection === 'function') {
      await window.__ttuGoToSection(n);
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
    'currentSection': null
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

  // ── 公开 API ───────────────────────────────────────────────────────────────

  /// 向 WebView 注入 CSS 样式和 JS 函数（章节加载完成后调用一次）。
  static Future<void> inject(InAppWebViewController controller) async {
    // 注入 CSS
    await controller.evaluateJavascript(source: '''
(function() {
  var existing = document.getElementById('__hoshi_audio_css');
  if (existing) return;
  var s = document.createElement('style');
  s.id = '__hoshi_audio_css';
  s.textContent = ${jsonEncode(_css)};
  document.head.appendChild(s);
})();
''');

    // 注入 JS 函数
    await controller.evaluateJavascript(source: _highlightFn);
    await controller.evaluateJavascript(source: _sasayakiFn);
    await controller.evaluateJavascript(source: _ttuApiShimFn);
    await controller.evaluateJavascript(source: _annotateFn);
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
      source: '__hoshiTtuProbe();',
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
      );
    } catch (_) {
      return const TtuApiProbe.missing();
    }
  }

  /// 请求跳转到指定 section。fork 未落地时此调用会在 JS 侧打
  /// `ttuForkMissing` 日志后直接 resolve，外层据此降级为 pill 提示。
  static Future<void> requestSectionNav(
    InAppWebViewController controller, {
    required int sectionIndex,
  }) async {
    await controller.evaluateJavascript(
      source: '__sasayakiRequestNav($sectionIndex);',
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
      source: '__hoshiLoadSasayakiRefs($ttuBookId);',
    );
  }

  /// 对齐 Sasayaki 原版 reader.js 的 `applySasayakiCues(cues)`：ttu 章节
  /// 挂载完成（或 sasayakiMountedSection 识别出当前段）后，把该段所有
  /// Sasayaki cue 批量传给 WebView，JS 侧一次性 TreeWalker 扫归一化字符 →
  /// 按每条 cue 的 (normCharStart, normCharEnd) 包 `<span>` 存进
  /// `__hoshiSasayakiCueMap`。之后每句高亮就是 Map 查表，不再走 walker。
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
      });
    }
    if (payload.isEmpty) return;
    await controller.evaluateJavascript(
      source: '__hoshiApplySasayakiCues($sectionIndex, '
          '${jsonEncode(payload)});',
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
      source: '__hoshiAnnotate(${jsonEncode(chapterHref)});',
    );
  }

  /// 高亮 [cue] 对应的句子。
  ///
  /// [cue] 为 null 时清除所有高亮。textFragmentId 以 `sasayaki://` 开头时走
  /// Sasayaki 路径（按 sectionIndex + 归一化字符偏移在 DOM 中定位）；否则
  /// 按普通 CSS selector 处理。
  ///
  /// [reveal] 对齐 Sasayaki 原版 `displayCue(cue, reveal:)`：true 时把
  /// cue 滚进视口（ticker 翻页），false 时**只加高亮 class**，保持用户
  /// 当前阅读位置不动。Reader 端一般传
  /// `controller.shouldRevealCurrentCue`（= followAudio && hasPlayedOnce）。
  ///
  /// 若 textFragmentId 为空（Sasayaki 匹配失败、且不是字幕合成书路径），
  /// 视为"无可用定位"：只清一次高亮，不再每 tick 刷 `[data-cue-id]` 回落。
  static Future<void> highlight(
    InAppWebViewController controller, {
    AudioCue? cue,
    bool reveal = true,
  }) async {
    if (cue == null || cue.textFragmentId.isEmpty) {
      await controller.evaluateJavascript(source: '__hoshiHighlight("");');
      return;
    }
    final String raw = cue.textFragmentId;
    final SasayakiFragment? frag = SasayakiMatchCodec.tryDecode(raw);
    if (frag != null) {
      // 优先走 Sasayaki 原版模型：章节挂载时已经通过 applySasayakiCues
      // 批量预包 span，运行期只是 Map 查表加 class。cueMap 未命中时 JS 自己
      // 回退到旧的 __hoshiHighlightSasayaki（TreeWalker + indexOf 回退）
      // 处理那条 cue，Dart 侧不分支。
      //
      // 为什么不让 Dart 根据 JS 返回值自己分支：evaluateJavascript 的返回
      // 值类型在不同 WebView 实现下不稳定，把控制流放在 JS 里一条链条
      // 到底更可靠。
      final String cueJson = jsonEncode(cue.text);
      await controller.evaluateJavascript(
        source: '(function(){'
            'if (!window.__hoshiHighlightSasayakiCueById(${jsonEncode(raw)}, $reveal)) {'
            '  window.__hoshiHighlightSasayaki(${frag.sectionIndex}, '
            '    ${frag.normCharStart}, ${frag.normCharEnd}, $cueJson, $reveal);'
            '}'
            '})();',
      );
      return;
    }
    await controller.evaluateJavascript(
      source: '__hoshiHighlight(${jsonEncode(raw)}, $reveal);',
    );
  }

  /// 高亮指定 selector（直接传 selector 字符串，不经过 AudioCue）。
  static Future<void> highlightSelector(
    InAppWebViewController controller, {
    required String selector,
  }) async {
    await controller.evaluateJavascript(
      source: '__hoshiHighlight(${jsonEncode(selector)});',
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
  });

  const TtuApiProbe.missing()
      : hasGoToSection = false,
        hasCurrentSection = false,
        hasSectionCount = false,
        sectionCount = null,
        currentSection = null;

  final bool hasGoToSection;
  final bool hasCurrentSection;
  final bool hasSectionCount;
  final int? sectionCount;
  final int? currentSection;

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

/// 用户在 WebView 中点击有声书句子所产生的事件。
class AudiobookClickEvent {
  const AudiobookClickEvent({
    required this.chapterHref,
    required this.sentenceIndex,
  });

  /// 来源章节（EPUB spine href）。
  final String chapterHref;

  /// 点击的句子在章节内的序号（data-hoshi-sid）。
  final int sentenceIndex;
}
