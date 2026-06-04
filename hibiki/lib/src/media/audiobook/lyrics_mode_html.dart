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

    return '''
<!DOCTYPE html>
<html lang="ja">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
:root { --cue-scale: 1.15; }
html, body {
  width: 100%;
  background: $backgroundColor;
  overflow-x: hidden;
  -webkit-tap-highlight-color: transparent;
  -webkit-touch-callout: none;
}
body { font-family: "Noto Serif JP", "Noto Sans JP", serif; }
.lyrics-container {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: calc(45vh + ${marginTop}vh) ${marginLeft > 0 ? marginLeft : 2.5}vw calc(45vh + ${marginBottom}vh) ${marginRight > 0 ? marginRight : 2.5}vw;
  gap: 0;
}
.cue {
  position: relative;
  text-align: center;
  color: $textColor;
  font-size: ${fontSize}px;
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
<body>
<div class="lyrics-container" id="lc">
$cueHtml
</div>
<script>
$selectionJs

// ── 滚动动画 ──
var _animId = 0;
function scrollToCenter(el, duration) {
  if (!el) return;
  _animId++;
  var myId = _animId;
  var targetY = el.offsetTop - (window.innerHeight / 2) + (el.offsetHeight / 2);
  var startY = window.scrollY;
  var diff = targetY - startY;
  if (Math.abs(diff) < 1) return;
  var absDiff = Math.abs(diff);
  var adaptDuration = Math.min(700, Math.max(300, absDiff * 0.5));
  if (duration) adaptDuration = duration;
  var startTime = performance.now();
  function easeOutCubic(t) { return 1 - Math.pow(1 - t, 3); }
  function step(now) {
    if (myId !== _animId) return;
    var elapsed = now - startTime;
    var progress = Math.min(elapsed / adaptDuration, 1);
    window.scrollTo(0, startY + diff * easeOutCubic(progress));
    if (progress < 1) requestAnimationFrame(step);
  }
  requestAnimationFrame(step);
}

// ── cue 切换 ──
var _currentIdx = -1;
var _cues = document.querySelectorAll('.cue');

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
      _cues[i].classList.remove('current', 'near-1', 'near-2', 'near-3');
  }
  for (var i = Math.max(0, index - 3), e = Math.min(len - 1, index + 3); i <= e; i++) {
    var d = Math.abs(i - index);
    if (d === 0) _cues[i].classList.add('current');
    else _cues[i].classList.add('near-' + d);
  }
  if (scroll !== false) scrollToCenter(_cues[index]);
}

// ── Dart bridge ──
window.__lyricsSetCue = function(index, scroll) { setCue(index, scroll); };
window.__lyricsGetCurrentIndex = function() { return _currentIdx; };

// ── 点击：所有句子→查词 ──
document.getElementById('lc').addEventListener('click', function(e) {
  var el = e.target.closest('.cue');
  if (!el) return;
  if (window.hoshiSelection) {
    window.hoshiSelection.selectText(e.clientX, e.clientY, 400);
  }
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
      r.style.fontSize = fontSize + 'px';
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
      var lv = (ml != null && ml > 0) ? ml : 2.5;
      var rv = (mr != null && mr > 0) ? mr : 2.5;
      r.style.padding = 'calc(45vh + ' + (mt||0) + 'vh) ' + lv + 'vw calc(45vh + ' + (mb||0) + 'vh) ' + rv + 'vw';
    }
  }
};

// ── 初始定位（即时跳转，不用动画，避免与 Dart 端 setCue 竞争） ──
_currentIdx = $currentIndex;
if ($currentIndex >= 0 && $currentIndex < _cues.length) {
  var _initEl = _cues[$currentIndex];
  if (_initEl) {
    var _iy = _initEl.offsetTop - (window.innerHeight / 2) + (_initEl.offsetHeight / 2);
    window.scrollTo(0, Math.max(0, _iy));
  }
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
