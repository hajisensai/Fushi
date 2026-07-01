import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';

class LyricsModeHtml {
  LyricsModeHtml._();

  static String generate({
    required List<AudioCue> cues,
    required int currentIndex,
    required String backgroundColor,
    required String textColor,
    required String accentColor,
    required double fontSize,
    double marginTop = 0,
    double marginBottom = 0,
    double marginLeft = 0,
    double marginRight = 0,
    bool vertical = false,
    bool blur = false,
  }) {
    final StringBuffer cueHtml = StringBuffer();
    for (int i = 0; i < cues.length; i++) {
      final String escaped = _escapeHtml(cues[i].text);
      final String fragId = _escapeAttr(cues[i].textFragmentId);
      final int dist = (i - currentIndex).abs();
      final String cls = dist == 0
          ? 'cue current'
          : dist <= 3
              ? 'cue near-$dist'
              : 'cue';
      cueHtml.write(
        '<div class="$cls" data-cue-index="$i" '
        'data-text-fragment-id="$fragId">'
        '$escaped</div>\n',
      );
    }

    final String selectionJs = ReaderSelectionScripts.source();

    // ── TODO-907: 轴依赖样式（横排=纵滚，竖排 vertical-rl=横滚） ──
    // 把横/竖排差异收敛成三段 CSS 片段，模板里只插一次，正文逻辑不再撒分支。
    // 竖排 vertical-rl 是右起左推：主轴为列、横向滚动、纵向溢出隐藏。
    final String htmlBodyAxisCss = vertical
        ? 'writing-mode: vertical-rl; overflow-x: auto; overflow-y: hidden;'
        : 'overflow-x: hidden;';
    final String containerAxisCss = vertical
        ? 'flex-direction: row; justify-content: flex-start; align-items: center;'
        : 'flex-direction: column; align-items: center;';
    // 主轴方向的「45vh/45vw 居中余量 + 用户边距」。横排=上下(vh)，竖排=左右(vw)。
    // 注意竖排 vertical-rl 视觉「先读」在右，但 padding 仍按物理 left/right 写，
    // 由 writing-mode 决定读序，无需翻 padding 值。
    final double padTop = vertical ? marginTop : 45 + marginTop;
    final double padBottom = vertical ? marginBottom : 45 + marginBottom;
    final double padLeft =
        vertical ? 45 + marginLeft : (marginLeft > 0 ? marginLeft : 2.5);
    final double padRight =
        vertical ? 45 + marginRight : (marginRight > 0 ? marginRight : 2.5);
    final String containerPaddingCss = vertical
        ? 'padding: ${padTop}vh ${padRight}vw ${padBottom}vh ${padLeft}vw;'
        : 'padding: calc(45vh + ${marginTop}vh) ${marginLeft > 0 ? marginLeft : 2.5}vw '
            'calc(45vh + ${marginBottom}vh) ${marginRight > 0 ? marginRight : 2.5}vw;';
    // JS 端轴标记：true=竖排横滚（用 scrollBy 增量绕开 vertical-rl 负向 scrollX）。
    final String verticalJs = vertical ? 'true' : 'false';
    // TODO-908：听力沉浸模糊。blur=true 时给 body 挂 `lyrics-blur` class，CSS 只对
    // 当前句（.cue.current）盖 8px 高斯模糊；hover 或点击（.revealed）显形。模糊维度
    // 与 writing-mode 正交——blur CSS 只作用在 cue 元素上，与轴/竖排无关。
    final String blurBodyClass = blur ? ' class="lyrics-blur"' : '';

    return '''
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
:root { --cue-scale: 1.15; --cue-font-size: ${fontSize}px; }
html, body {
  width: 100%;
  height: 100%;
  background: $backgroundColor;
  $htmlBodyAxisCss
  -webkit-tap-highlight-color: transparent;
  -webkit-touch-callout: none;
  /* Themed scrollbar: transparent track shows the lyrics background, thumb
     takes the cue text colour so it matches the theme instead of the default
     grey bar. ::-webkit-scrollbar covers the classic scrollbar; the standard
     props cover overlay scrollbars on newer engines. */
  scrollbar-width: thin;
  scrollbar-color: $textColor transparent;
}
body { font-family: "Noto Serif JP", "Noto Sans JP", serif; }
::-webkit-scrollbar {
  width: 8px;
  height: 8px;
}
::-webkit-scrollbar-track {
  background: transparent;
}
::-webkit-scrollbar-thumb {
  background-color: $textColor;
  background-clip: padding-box;
  border: 2px solid transparent;
  border-radius: 8px;
}
.lyrics-container {
  display: flex;
  $containerAxisCss
  $containerPaddingCss
  gap: 0;
}
.cue {
  position: relative;
  text-align: center;
  color: $textColor;
  /* TODO-1080: per-cue font-size flows from --cue-font-size so JS can shrink one
     over-long cue via inline font-size (see __lyricsFitCues) without touching the
     shared base every other cue uses. */
  font-size: var(--cue-font-size);
  line-height: 1.7;
  padding: 12px 8px;
  max-width: calc(100% / var(--cue-scale) - 1%);
  overflow-wrap: break-word;
  word-break: break-word;
  opacity: 0.15;
  transform: scale(1);
  transition: opacity 0.35s ease-out, transform 0.3s ease-out, color 0.3s ease-out;
  will-change: transform, opacity;
  cursor: pointer;
}
.cue.current {
  opacity: 1.0;
  transform: scale(var(--cue-scale));
  font-weight: 700;
  color: $accentColor;
}
.cue.near-1 { opacity: 0.55; transform: scale(1.05); }
.cue.near-2 { opacity: 0.35; }
.cue.near-3 { opacity: 0.25; }
/* TODO-908: 听力沉浸模糊 —— body.lyrics-blur 时只对当前句盖 8px 高斯模糊，
   hover 或点击显形（.revealed）。与视频字幕的 ImageFilter.blur(sigma:8) 等价。
   仅作用 .cue（与 writing-mode 正交，不碰 TODO-907 轴 CSS）。 */
body.lyrics-blur .cue.current {
  filter: blur(8px);
  transition: filter 0.2s ease-out, opacity 0.35s ease-out,
      transform 0.3s ease-out, color 0.3s ease-out;
}
body.lyrics-blur .cue.current:hover,
body.lyrics-blur .cue.current.revealed {
  filter: blur(0);
}
::highlight(hoshi-selection) {
  background-color: $accentColor;
  color: $backgroundColor;
}
.hoshi-dict-highlight {
  background-color: $accentColor !important;
  color: inherit;
  border-radius: 2px;
}
.cue.current .hoshi-dict-highlight {
  color: $backgroundColor;
}
.cue.favorited::before {
  content: '\\2605';
  position: absolute;
  right: -2px;
  top: 50%;
  transform: translateY(-50%);
  font-size: 0.5em;
  opacity: 0.6;
}
</style>
</head>
<body$blurBodyClass>
<div class="lyrics-container" id="lc">
$cueHtml
</div>
<script>
$selectionJs

// ── 滚动动画 ──
// TODO-907: 横/竖排统一走「getBoundingClientRect 相对视口中线的 delta + 增量
// scrollBy」。delta 是轴无关的相对量，竖排 vertical-rl 的 scrollX 是负向坐标，
// 用相对 delta 增量滚动绕开 RTL 绝对坐标符号坑（参考正文横排亚像素累积教训）。
var __lyricsVertical = $verticalJs;
var _animId = 0;
// 返回元素中心相对视口中线的偏移（沿当前滚动轴）：>0 表示需正向 scrollBy。
function _lyricsCenterDelta(el) {
  var r = el.getBoundingClientRect();
  if (__lyricsVertical) {
    var elCenterX = r.left + r.width / 2;
    return elCenterX - (window.innerWidth / 2);
  }
  var elCenterY = r.top + r.height / 2;
  return elCenterY - (window.innerHeight / 2);
}
function _lyricsScrollByAxis(d) {
  if (__lyricsVertical) window.scrollBy(d, 0);
  else window.scrollBy(0, d);
}
function scrollToCenter(el, duration) {
  if (!el) return;
  _animId++;
  var myId = _animId;
  var diff = _lyricsCenterDelta(el);
  if (Math.abs(diff) < 1) return;
  var absDiff = Math.abs(diff);
  var adaptDuration = Math.min(700, Math.max(300, absDiff * 0.5));
  if (duration) adaptDuration = duration;
  var startTime = performance.now();
  var lastApplied = 0;
  function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }
  function step(now) {
    if (myId !== _animId) return;
    var elapsed = now - startTime;
    var progress = Math.min(elapsed / adaptDuration, 1);
    var want = diff * easeOutCubic(progress);
    _lyricsScrollByAxis(want - lastApplied);
    lastApplied = want;
    if (progress < 1) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}

// ── cue 切换 ──
var _currentIdx = -1;
var _cues = document.querySelectorAll('.cue');

// ── TODO-1080: over-long cue auto-shrink ──────────────────────────────────
// A single sentence can be longer than the screen fits. In vertical-rl the cue
// column runs top-to-bottom and the body clips overflow-y, so a too-tall column
// is silently cut off; in horizontal the cue wraps and grows vertically but a
// single unbreakable run can still spill past the content-box width. Instead of
// letting either clip, measure each cue against the constraining cross-axis and,
// only when it truly overflows, override THAT cue's inline font-size down by the
// overflow ratio (clamped to a readable floor). Cues that already fit keep the
// user's base font-size untouched (never-break: no change for the common case).
//
// The base size lives in --cue-font-size; the .current cue is transform:scaled
// by --cue-scale, so we discount the available extent by that factor to leave
// headroom (a cue that fits un-scaled but overflows once enlarged still fits).
var __LYRICS_MIN_FONT_PX = 12;
function _lyricsCueScale() {
  var raw = getComputedStyle(document.documentElement)
      .getPropertyValue('--cue-scale');
  var v = parseFloat(raw);
  return (isFinite(v) && v > 0) ? v : 1;
}
function _lyricsBaseFontPx() {
  var raw = getComputedStyle(document.documentElement)
      .getPropertyValue('--cue-font-size');
  var v = parseFloat(raw);
  return (isFinite(v) && v > 0) ? v : 24;
}
// Available cross-axis extent (px) a cue may occupy without clipping, already
// discounted for the enlarged .current scale. Vertical clips on height, so the
// limit is the viewport height minus the container's top+bottom padding; the
// horizontal path scrolls vertically so its only hard limit is width.
function _lyricsAvailExtent(container) {
  var cs = getComputedStyle(container);
  var scale = _lyricsCueScale();
  if (__lyricsVertical) {
    var padV = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom);
    return Math.max(1, (window.innerHeight - padV) / scale);
  }
  var padH = parseFloat(cs.paddingLeft) + parseFloat(cs.paddingRight);
  return Math.max(1, (window.innerWidth - padH) / scale);
}
// Fit one cue: clear any prior override, measure at base size, and if it still
// overflows the available extent, set an inline font-size scaled by the overflow
// ratio down to the floor. Returns nothing; idempotent.
function _lyricsFitCue(el, avail, base) {
  el.style.fontSize = '';
  // offsetHeight/offsetWidth are the layout-box extents and (unlike
  // getBoundingClientRect) exclude the .current scale transform, so the
  // measurement is scale-independent and the shared avail (already discounted
  // by --cue-scale) applies uniformly to current and non-current cues alike.
  var measured = __lyricsVertical ? el.offsetHeight : el.offsetWidth;
  if (measured <= avail) return;
  var shrunk = Math.max(__LYRICS_MIN_FONT_PX, base * (avail / measured));
  if (shrunk < base) el.style.fontSize = shrunk + 'px';
}
function __lyricsFitCues() {
  var container = document.getElementById('lc');
  if (!container) return;
  var base = _lyricsBaseFontPx();
  var avail = _lyricsAvailExtent(container);
  for (var i = 0; i < _cues.length; i++) _lyricsFitCue(_cues[i], avail, base);
}
window.__lyricsFitCues = __lyricsFitCues;
// Re-fit on viewport changes (rotation / window resize) so a cue that fit at the
// old size is re-measured; debounced via rAF to coalesce burst resize events.
var _lyricsFitPending = false;
window.addEventListener('resize', function() {
  if (_lyricsFitPending) return;
  _lyricsFitPending = true;
  requestAnimationFrame(function() { _lyricsFitPending = false; __lyricsFitCues(); });
});

// scroll === false (audio-follow OFF) updates the current/near highlight but
// does NOT auto-scroll, so the user can freely scroll the lyrics while playback
// continues — mirrors the non-lyrics path where `followAudio` gates reveal.
function setCue(index, scroll) {
  if (index === _currentIdx) return;
  var old = _currentIdx;
  _currentIdx = index;
  var len = _cues.length;
  if (old >= 0) {
    for (var i = Math.max(0, old - 3), e = Math.min(len - 1, old + 3); i <= e; i++)
      _cues[i].classList.remove('current', 'near-1', 'near-2', 'near-3', 'revealed');
  }
  for (var i = Math.max(0, index - 3), e = Math.min(len - 1, index + 3); i <= e; i++) {
    var d = Math.abs(i - index);
    if (d === 0) _cues[i].classList.add('current');
    else _cues[i].classList.add('near-' + d);
  }
  // 焦点 caret 激活时，播放推进只换高亮，不把屏幕从用户正读的行拽走；跟随关闭(scroll===false)时也不滚。
  if (scroll !== false && !window.__lyricsCaretActive) scrollToCenter(_cues[index]);
}

// ── Dart bridge ──
window.__lyricsSetCue = function(index, scroll) { setCue(index, scroll); };
window.__lyricsGetCurrentIndex = function() { return _currentIdx; };
// 供 hoshiLyricsCaret 行间移动时把目标 cue 居中（复用同一滚动动画）。
window.__lyricsScrollToCue = function(index) {
  if (index >= 0 && index < _cues.length) scrollToCenter(_cues[index]);
};

// ── 点击：所有句子→查词 ──
// BUG-280: 原来用 DOM 'click' 事件触发查词。click 只在「pointerdown→pointerup 全程
// 未被宿主层认领」时由浏览器合成；当 Flutter 端弹窗可见时，整屏有一层 translucent
// 手势屏障（base_source_page 的 Positioned.fill GestureDetector，onTap=关闭弹窗）会在
// 手势竞技场里认领这次点按 → WebView 收不到合成 click → 查完一个词后再点下一句只关掉
// 弹窗、不发新查词（无法连续查）。阅读器正文连续查词靠的是自绘的 touchend / pointerup
// （passive:false）原始指针监听，绕过合成 click；这里对齐同一机制：用原始 pointerup /
// touchend + 小位移门控（拖动滚动不误触发），使弹窗屏障在场时 WebView 仍能拿到点按并
// 发起下一次查词。
var _lyTapX = 0, _lyTapY = 0, _lyTapMoved = false, _lyHasTap = false;
function _lyTapStart(x, y) {
  _lyTapX = x; _lyTapY = y; _lyTapMoved = false; _lyHasTap = true;
}
function _lyTapMove(x, y) {
  if (!_lyHasTap) return;
  if (Math.abs(x - _lyTapX) > 12 || Math.abs(y - _lyTapY) > 12) _lyTapMoved = true;
}
function _lyTapEnd(x, y) {
  if (!_lyHasTap) return;
  _lyHasTap = false;
  if (_lyTapMoved) return;
  var el = document.elementFromPoint(x, y);
  var cueEl = el ? el.closest('.cue') : null;
  if (!cueEl) return;
  // TODO-908: 模糊态下点句显形（同视频「点击显形」语义）；非模糊态无影响。
  if (document.body.classList.contains('lyrics-blur')) cueEl.classList.add('revealed');
  if (window.hoshiSelection) {
    window.hoshiSelection.selectText(x, y, 400);
  }
}
var _lc = document.getElementById('lc');
_lc.addEventListener('touchstart', function(e) {
  var t = e.touches[0]; _lyTapStart(t.clientX, t.clientY);
}, {passive: true});
_lc.addEventListener('touchmove', function(e) {
  var t = e.touches[0]; _lyTapMove(t.clientX, t.clientY);
}, {passive: true});
_lc.addEventListener('touchend', function(e) {
  var t = e.changedTouches[0]; _lyTapEnd(t.clientX, t.clientY);
}, {passive: false});
_lc.addEventListener('pointerdown', function(e) {
  if (e.pointerType === 'touch' || e.button !== 0) return;
  _lyTapStart(e.clientX, e.clientY);
}, {passive: true});
_lc.addEventListener('pointermove', function(e) {
  if (e.pointerType === 'touch') return;
  _lyTapMove(e.clientX, e.clientY);
}, {passive: true});
_lc.addEventListener('pointerup', function(e) {
  if (e.pointerType === 'touch' || e.button !== 0) return;
  _lyTapEnd(e.clientX, e.clientY);
}, {passive: false});

// ── 中键点句 → seek 到该 cue 并播放（标准 click 不触发中键，单列 mousedown）──
_lc.addEventListener('mousedown', function(e) {
  if (e.button === 0) return;
  var el = e.target.closest('.cue');
  if (!el) return;
  e.preventDefault();
  var idx = parseInt(el.getAttribute('data-cue-index'), 10);
  if (isNaN(idx)) return;
  window.flutter_inappwebview.callHandler('onLyricsPointerSeek', e.button, idx);
});

// ── 歌词模式：覆写 selection 回调，附加 cue 元数据 ──
(function() {
  var origSelectText = window.hoshiSelection.selectText;
  window.hoshiSelection.selectText = function(x, y, maxLen) {
    var hitEl = document.elementFromPoint(x, y);
    var cueEl = hitEl ? hitEl.closest('.cue') : null;
    if (cueEl) {
      window.__lyricsCueContext = {
        textFragmentId: cueEl.getAttribute('data-text-fragment-id'),
        cueIndex: parseInt(cueEl.getAttribute('data-cue-index'), 10),
      };
    } else {
      window.__lyricsCueContext = null;
    }
    return origSelectText.call(window.hoshiSelection, x, y, maxLen);
  };
})();

// ── 收藏标记 ──
window.__lyricsMarkFavorites = function(texts) {
  var set = new Set(texts || []);
  var cues = document.querySelectorAll('.cue');
  for (var i = 0; i < cues.length; i++) {
    var t = cues[i].textContent.trim();
    if (set.has(t)) cues[i].classList.add('favorited');
    else cues[i].classList.remove('favorited');
  }
};

// ── 实时样式更新（避免整页重载） ──
window.__lyricsUpdateStyle = function(bgColor, textColor, accentColor, fontSize, mt, mb, ml, mr) {
  var root = document.documentElement;
  document.body.style.background = bgColor;
  root.style.background = bgColor;

  var sheet = document.styleSheets[0];
  var rules = sheet.cssRules || sheet.rules;
  for (var i = 0; i < rules.length; i++) {
    var r = rules[i];
    if (r.selectorText === '.cue') {
      r.style.color = textColor;
      // TODO-1080: the base size is now the --cue-font-size custom prop that .cue
      // reads via var(); update the prop (not a fixed .cue font-size) so the refit
      // below re-measures against the new base and clears/re-applies per-cue
      // shrink overrides. Setting .cue's own font-size would beat the var and
      // strand overflowing cues at the un-shrunk size.
      root.style.setProperty('--cue-font-size', fontSize + 'px');
    } else if (r.selectorText === 'html, body') {
      r.style.setProperty('scrollbar-color', textColor + ' transparent');
    } else if (r.selectorText === '::-webkit-scrollbar-thumb') {
      r.style.backgroundColor = textColor;
    } else if (r.selectorText === '.cue.current') {
      r.style.color = accentColor;
    } else if (r.type === CSSRule.STYLE_RULE && r.selectorText === '.cue.current .hoshi-dict-highlight') {
      r.style.color = bgColor;
    } else if (r.selectorText === '.hoshi-dict-highlight') {
      r.style.setProperty('background-color', accentColor, 'important');
    } else if (r.selectorText === '::highlight(hoshi-selection)') {
      r.style.setProperty('background-color', accentColor);
      r.style.color = bgColor;
    } else if (r.selectorText === '.lyrics-container') {
      if (__lyricsVertical) {
        // 竖排 vertical-rl：居中余量在左右(45vw)，上下吃用户 vh 边距。
        r.style.padding = (mt||0) + 'vh calc(45vw + ' + (mr||0) + 'vw) ' + (mb||0) + 'vh calc(45vw + ' + (ml||0) + 'vw)';
      } else {
        var lv = (ml != null && ml > 0) ? ml : 2.5;
        var rv = (mr != null && mr > 0) ? mr : 2.5;
        r.style.padding = 'calc(45vh + ' + (mt||0) + 'vh) ' + lv + 'vw calc(45vh + ' + (mb||0) + 'vh) ' + rv + 'vw';
      }
    }
  }
  // Base font-size / margins just changed, so cues re-flow; re-measure overflow
  // and re-apply (or clear) the per-cue shrink so a now-fitting cue reverts to
  // the base and a now-overflowing cue shrinks — without a full page reload.
  __lyricsFitCues();
};

// ── 实时模糊开关（TODO-908，仿 __lyricsUpdateStyle，不重建整页） ──
// on=true 给 body 挂 lyrics-blur（CSS 只模糊当前句，hover/点击显形）；off 摘掉并
// 清掉所有遗留的 .revealed，回到无模糊态。
window.__lyricsSetBlur = function(on) {
  if (on) {
    document.body.classList.add('lyrics-blur');
  } else {
    document.body.classList.remove('lyrics-blur');
    var revealed = document.querySelectorAll('.cue.revealed');
    for (var i = 0; i < revealed.length; i++) revealed[i].classList.remove('revealed');
  }
};

// TODO-1080: shrink any over-long cue before positioning so the initial-scroll
// geometry (and the caret ring) is measured against the final, fitted sizes.
__lyricsFitCues();

// ── 初始定位（即时跳转，不用动画，避免与 Dart 端 setCue 竞争） ──
// TODO-907: 同样走 delta 增量滚动，横竖排一致；竖排 vertical-rl 的负向 scrollX
// 用 scrollBy 增量打到位，不硬算绝对坐标。
_currentIdx = $currentIndex;
if ($currentIndex >= 0 && $currentIndex < _cues.length) {
  var _initEl = _cues[$currentIndex];
  if (_initEl) _lyricsScrollByAxis(_lyricsCenterDelta(_initEl));
}
</script>
</body>
</html>
''';
  }

  static String _escapeHtml(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&#39;');
  }

  static String _escapeAttr(String text) {
    return text
        .replaceAll('&', '&amp;')
        .replaceAll('"', '&quot;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
  }
}
