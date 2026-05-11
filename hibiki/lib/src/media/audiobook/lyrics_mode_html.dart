import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
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
  }) {
    final StringBuffer cueHtml = StringBuffer();
    for (int i = 0; i < cues.length; i++) {
      final String escaped = _escapeHtml(cues[i].text);
      final String fragId = _escapeAttr(cues[i].textFragmentId);
      cueHtml.write(
        '<div class="cue" data-cue-index="$i" '
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
html, body {
  width: 100%; height: 100%;
  background: $backgroundColor;
  overflow-x: hidden;
  overflow-y: scroll;
  -webkit-overflow-scrolling: touch;
  -webkit-tap-highlight-color: transparent;
  -webkit-touch-callout: none;
}
body { font-family: "Noto Serif JP", "Noto Sans JP", serif; }
.lyrics-container {
  display: flex;
  flex-direction: column;
  align-items: center;
  padding: 45vh 20px 45vh 20px;
  gap: 0;
}
.cue {
  text-align: center;
  color: $textColor;
  font-size: ${fontSize}px;
  line-height: 1.7;
  padding: 12px 8px;
  max-width: 92vw;
  opacity: 0.15;
  transition: opacity 0.35s ease-out, font-size 0.3s ease-out, font-weight 0.3s ease-out;
  cursor: pointer;
  -webkit-user-select: text;
  user-select: text;
}
.cue.current {
  opacity: 1.0;
  font-size: ${(fontSize * 1.45).round()}px;
  font-weight: 700;
  color: $accentColor;
}
.cue.near-1 { opacity: 0.55; font-size: ${(fontSize * 1.15).round()}px; }
.cue.near-2 { opacity: 0.35; font-size: ${(fontSize * 1.05).round()}px; }
.cue.near-3 { opacity: 0.25; }
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

function setCue(index) {
  if (index === _currentIdx) return;
  _currentIdx = index;
  for (var i = 0; i < _cues.length; i++) {
    _cues[i].classList.remove('current', 'near-1', 'near-2', 'near-3');
    var dist = Math.abs(i - index);
    if (dist === 0) _cues[i].classList.add('current');
    else if (dist === 1) _cues[i].classList.add('near-1');
    else if (dist === 2) _cues[i].classList.add('near-2');
    else if (dist === 3) _cues[i].classList.add('near-3');
  }
  scrollToCenter(_cues[index]);
}

// ── Dart bridge ──
window.__lyricsSetCue = function(index) { setCue(index); };
window.__lyricsGetCurrentIndex = function() { return _currentIdx; };

// ── 点击句子跳转播放 ──
document.getElementById('lc').addEventListener('click', function(e) {
  if (_longPressed) { _longPressed = false; return; }
  var el = e.target.closest('.cue');
  if (!el) return;
  var idx = parseInt(el.getAttribute('data-cue-index'), 10);
  if (isNaN(idx)) return;
  if (window.flutter_inappwebview) {
    window.flutter_inappwebview.callHandler('onLyricsCueTap', idx);
  }
});

// ── 长按选词 (long-press to select; 短按→跳转，长按→查词) ──
var _tapStartX = 0, _tapStartY = 0, _tapStartTime = 0;
var _longPressed = false;
document.addEventListener('touchstart', function(e) {
  var t = e.touches[0];
  _tapStartX = t.clientX;
  _tapStartY = t.clientY;
  _tapStartTime = Date.now();
  _longPressed = false;
}, {passive: true});

document.addEventListener('touchend', function(e) {
  var t = e.changedTouches[0];
  var dx = Math.abs(t.clientX - _tapStartX);
  var dy = Math.abs(t.clientY - _tapStartY);
  var elapsed = Date.now() - _tapStartTime;
  if (dx < 20 && dy < 20 && elapsed >= 500) {
    _longPressed = true;
    if (window.hoshiSelection) {
      window.hoshiSelection.selectText(t.clientX, t.clientY, 400);
    }
  }
}, {passive: true});

// ── 歌词模式：覆写 selection 回调，附加 cue 元数据 ──
(function() {
  var origSelectText = window.hoshiSelection.selectText;
  window.hoshiSelection.selectText = function(x, y, maxLen) {
    origSelectText.call(window.hoshiSelection, x, y, maxLen);
    var sel = window.getSelection();
    if (sel && sel.anchorNode) {
      var cueEl = sel.anchorNode.nodeType === 1
        ? sel.anchorNode.closest('.cue')
        : sel.anchorNode.parentElement
          ? sel.anchorNode.parentElement.closest('.cue')
          : null;
      if (cueEl) {
        window.__lyricsCueContext = {
          textFragmentId: cueEl.getAttribute('data-text-fragment-id'),
          cueIndex: parseInt(cueEl.getAttribute('data-cue-index'), 10),
        };
      } else {
        window.__lyricsCueContext = null;
      }
    }
  };
})();

// ── 初始定位 ──
if ($currentIndex >= 0 && $currentIndex < _cues.length) {
  setCue($currentIndex);
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
