import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 反馈 0rvPl6s6tR：歌词模式没碰屏幕也会「自动对齐中断、弹出跟随音频」。根因是「免判窗口（150 ms）之外的
/// scroll 一律算用户手动滚」——设备忙时自动跟随那一帧的 scroll 事件迟到、视口变化 / 重排钳位也发 scroll，
/// 都被判成用户滚走。现在只认有用户输入的 scroll（node 真跑生成文档里的脚本片段）。
const LyricsHtmlTheme _theme = LyricsHtmlTheme(
  textColor: Color(0xFFFFFFFF),
  currentColor: Color(0xFFFFFFFF),
  accentColor: Color(0xFF66AAFF),
  selectionTextColor: Color(0xFF000000),
  contextOpacities: <double>[0.55, 0.35, 0.25, 0.15],
  browsingOpacity: 0.6,
  deselectedScale: 0.87,
  anchorY: 0.46,
  edgeFade: 0,
  alignStart: true,
  contextBlurPx: 0,
  rowRadius: 12,
);

AudioCue _cue(int i) => AudioCue()
  ..id = i + 1
  ..bookKey = 'book'
  ..chapterHref = 'chapter'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = '行$i'
  ..startMs = i * 1000
  ..endMs = i * 1000 + 900
  ..audioFileIndex = 0;

String _doc() => LyricsModeHtml.generate(
  cues: <AudioCue>[_cue(0), _cue(1)],
  currentIndex: 0,
  backgroundColor: 'transparent',
  textColor: '#888888',
  accentColor: '#3366cc',
  fontSize: 24,
  vertical: false,
  theme: _theme,
);

String _between(String doc, String start, String end) {
  final int from = doc.indexOf(start);
  if (from < 0) throw StateError('生成文档里找不到 $start');
  final int to = doc.indexOf(end, from);
  if (to < 0) throw StateError('生成文档里找不到 $end');
  return doc.substring(from, to + end.length);
}

Future<void> _runJs(String code) async {
  final Directory dir = Directory.systemTemp.createTempSync('lyrics-scroll-');
  try {
    final File script = File('${dir.path}/verify.js')..writeAsStringSync(code);
    final ProcessResult result = await Process.run('node', <String>[
      script.path,
    ], runInShell: Platform.isWindows);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('LYRICS_SCROLL_OK'));
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  test('没有用户输入的 scroll 不进浏览态（迟到的程序化滚动 / 重排）；触摸、指针拖动、键盘才算', () async {
    final String js = _between(
      _doc(),
      'var _LY_USER_INPUT_MS',
      "_lyBrowseDiag('ignored-scroll', now);\n  }\n}, {passive: true, capture: true});",
    );
    await _runJs('''
const assert = require('node:assert/strict');
const listeners = {};
const document = {addEventListener(type, fn) {
  (listeners[type] = listeners[type] || []).push(fn);
}};
function fire(type, e) { for (const fn of listeners[type] || []) fn(e || {}); }
const diag = [];
const window = {flutter_inappwebview: {callHandler(name, ...args) { diag.push([name, ...args]); }}};
let clock = 10000;
const performance = {now: () => clock};
var _lyProgUntil = 0, _lyBrowsing = false, _lyPlaying = true;
let browse = 0;
function _lyEnterBrowse() { browse++; _lyBrowsing = true; }
$js

// 自动跟随刚滚过（免判窗口内）：不算。
_lyProgUntil = clock + 150;
clock += 100; fire('scroll');
assert.equal(browse, 0);
// 设备忙：那一帧的 scroll 晚了 400 ms 才到——旧判据在这里误判成用户滚走。
clock += 400; fire('scroll');
assert.equal(browse, 0, '没有用户输入的迟到 scroll 不能打断跟随');
// 视口变化 / 重排钳位发来的 scroll：同样不算。
clock += 5000; fire('scroll');
assert.equal(browse, 0);
assert.deepEqual(diag.map((d) => [d[0], d[1]]), [['onLyricsBrowseDiag', 'ignored-scroll']],
  '忽略的 scroll 上报诊断，30 秒内只报一次');

// 手指拖动：按着时的 scroll 进浏览态；抬手后的惯性滚动（1 秒内）照算。
fire('touchstart'); clock += 50; fire('touchmove'); fire('scroll');
assert.equal(browse, 1);
clock += 3000; fire('scroll');
assert.equal(browse, 2, '手指一直按着：多久都算');
fire('touchend'); clock += 600; fire('scroll');
assert.equal(browse, 3, '抬手后的惯性滚动');
clock += 2000; fire('scroll');
assert.equal(browse, 3, '离上次输入太久：不再算用户滚');

// 鼠标拖滚动条 / 键盘翻页。
clock += 5000; fire('pointermove', {buttons: 0}); fire('scroll');
assert.equal(browse, 3, '鼠标只是划过（没按键）不算');
fire('pointermove', {buttons: 1}); fire('scroll');
assert.equal(browse, 4);
clock += 5000; fire('keydown'); fire('scroll');
assert.equal(browse, 5);

// 用户 scroll 进入浏览态时也报一次诊断（已在浏览态的后续 scroll 不报）。
assert.ok(diag.some((d) => d[1] === 'user-scroll'));
assert.equal(typeof window.__lyricsIsUserScroll, 'function');
console.log('LYRICS_SCROLL_OK');
''');
  });

  test('诊断行：参数照原样记下，并带上此刻常规 / 复习同步是否在跑', () {
    expect(
      lyricsBrowseDiagLine(
        <dynamic>['ignored-scroll', 412, 61234, false, true],
        regularSyncRunning: false,
        srsSyncRunning: true,
      ),
      'ignored-scroll sinceProgMs=412 sinceInputMs=61234 browsing=false '
      'playing=true sync=false srsSync=true',
    );
    expect(
      lyricsBrowseDiagLine(
        <dynamic>['user-scroll'],
        regularSyncRunning: true,
        srsSyncRunning: false,
      ),
      'user-scroll sinceProgMs=? sinceInputMs=? browsing=? playing=? '
      'sync=true srsSync=false',
    );
  });
}
