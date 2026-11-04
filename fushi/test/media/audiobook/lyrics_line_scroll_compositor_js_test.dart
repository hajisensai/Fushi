import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 歌词行切换滚动走合成器（用户 2026-11-04「歌词推动的时候总感觉帧率不够高」）。
///
/// 旧实现每帧 requestAnimationFrame 积分一步弹簧再改 scrollTop：每一帧都要主线程
/// 空闲，换行那一刻主线程最忙，弹簧帧被挤掉。现在滚动位置一次落到终点，再给
/// `#lc` 一条反向 transform 关键帧动画（合成器按刷新率推进）。
///
/// node 真跑生成文档里的脚本片段（DOM 用最小桩），钉住：滚动只改一次、首帧位移
/// 抵消滚动（视觉连续）、关键帧只动 transform 且收敛到 0、中途换目标位移与速度
/// 连续、边界钳制按实际滚动量补偿、远跳 / 减弱动效直接落位、手动浏览冻结在当下
/// 视觉位置。像素与帧率只能在真 WebView 里看。
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

String _doc({required bool vertical}) => LyricsModeHtml.generate(
  cues: <AudioCue>[_cue(0), _cue(1)],
  currentIndex: 0,
  backgroundColor: 'transparent',
  textColor: '#888888',
  accentColor: '#3366cc',
  fontSize: 24,
  vertical: vertical,
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

/// 最小 DOM 桩：一个滚动元素（可钳位）+ `#lc` 的 animate 记录。`el.offset` 是
/// 元素相对锚点的**布局**偏移（不含位移），视觉偏移 = offset − 滚动量 + 当下位移。
String _harness(String js, {required bool vertical}) =>
    '''
const assert = require('node:assert/strict');
var __lyricsVertical = $vertical;
var _lyBrowsing = false;
const window = {innerWidth: 800, innerHeight: 600, __lyricsReduceMotion: false};
const performance = {now: () => 0};
const scroller = {pos: 0, max: 1e9};
function _lyricsScrollTarget() { return scroller; }
function _lyAxisPos(s) { return s.pos; }
let scrollCalls = 0;
function _lyricsScrollByAxis(d) {
  scrollCalls++;
  scroller.pos = Math.max(0, Math.min(scroller.max, scroller.pos + d));
}
let wheelStops = 0;
function _lyWheelStop() { wheelStops++; }
const anims = [];
const lc = {
  animate(frames, opts) {
    const a = {frames, opts, currentTime: 0, cancelled: false,
      cancel() { this.cancelled = true; }};
    anims.push(a);
    return a;
  },
};
const document = {getElementById: (id) => id === 'lc' ? lc : null};
$js
function visualOffset(el) { return el.offset - scroller.pos + _lyShiftState().x; }
function _lyricsCenterDelta(el) { return visualOffset(el); }
function axisValue(frame) {
  const m = /^translate${vertical ? 'X' : 'Y'}\\((-?[0-9.]+)px\\)\$/.exec(frame.transform);
  assert.ok(m, frame.transform);
  return Number(m[1]);
}
''';

void main() {
  for (final bool vertical in <bool>[false, true]) {
    final String doc = _doc(vertical: vertical);
    final String js = _between(
      doc,
      'function _lyricsScrollByAxisMeasured(d) {',
      '\n  _lyShiftStart(cur.x + moved, cur.v);\n}',
    );
    final String axis = vertical ? '竖排' : '横排';

    test('$axis：滚动一次落位，位移动画抵消后弹回 0', () async {
      await _runJs('''
${_harness(js, vertical: vertical)}
// 纯函数：初值与停稳。
let s0 = __lyricsSpringAt(120, 30, 0);
assert.ok(Math.abs(s0.x - 120) < 1e-9 && Math.abs(s0.v - 30) < 1e-9);
const settle = __lyricsSpringSettleSec(120, 0);
assert.ok(settle > 0.3 && settle <= 1.5, String(settle));
const end = __lyricsSpringAt(120, 0, settle);
assert.ok(Math.abs(end.x) < 0.5 && Math.abs(end.v) < 4, JSON.stringify(end));
assert.equal(__lyricsSpringSettleSec(0, 0), 0);

const el = {offset: 120};
scrollToCenter(el);
assert.equal(scrollCalls, 1, '滚动只改一次，不逐帧改');
assert.equal(scroller.pos, 120);
assert.equal(anims.length, 1);
const a = anims[0];
assert.equal(a.opts.easing, 'linear');
assert.equal(a.opts.fill, 'none');
assert.ok(Math.abs(a.opts.duration - settle * 1000) < 1e-6);
for (const f of a.frames) assert.deepEqual(Object.keys(f).sort(), ['offset', 'transform']);
assert.ok(Math.abs(axisValue(a.frames[0]) - 120) < 0.01, '首帧位移抵消滚动：视觉不跳');
assert.equal(axisValue(a.frames.at(-1)), 0);
assert.equal(a.frames.at(-1).offset, 1);
for (let i = 1; i < a.frames.length; i++) assert.ok(a.frames[i].offset > a.frames[i - 1].offset);
// 视觉偏移在换目标前后不变。
assert.ok(Math.abs(visualOffset(el) - 120) < 1e-6);
assert.ok(wheelStops >= 1, '程序化回中接管时停掉在途滚轮动画');
console.log('LYRICS_SCROLL_OK');
''');
    });

    test('$axis：中途换目标，位移与速度连续；边界钳制按实际滚动量补', () async {
      await _runJs('''
${_harness(js, vertical: vertical)}
const a = {offset: 100};
scrollToCenter(a);
anims[0].currentTime = 150;
const mid = __lyricsSpringAt(100, 0, 0.15);
const b = {offset: 260};
const before = visualOffset(b);
scrollToCenter(b);
assert.ok(anims[0].cancelled, '旧动画撤掉');
assert.equal(anims.length, 2);
assert.equal(scroller.pos, 260);
// 新动画从「视觉偏移」起弹，速度接旧动画当下速度。
assert.ok(Math.abs(axisValue(anims[1].frames[0]) - before) < 0.01);
assert.ok(Math.abs(_lyShift.x0 - before) < 1e-9);
assert.ok(Math.abs(_lyShift.v0 - mid.v) < 1e-9, '速度接旧动画当下速度');
assert.ok(Math.abs(before - (160 + mid.x)) < 1e-6, '视觉偏移 = 新目标剩余 160 + 旧动画在途位移');
// 在途状态按动画 currentTime 求。
anims[1].currentTime = 10;
assert.ok(Math.abs(_lyShiftState().x - __lyricsSpringAt(before, mid.v, 0.01).x) < 1e-9);

// 滚到底被钳住：只滚了 40，位移 = 视觉偏移起点，终点停在钳位处。
scroller.pos = 0; scroller.max = 40;
anims.length = 0;
_lyShiftCancel();
const c = {offset: 200};
scrollToCenter(c);
assert.equal(scroller.pos, 40);
assert.ok(Math.abs(axisValue(anims[0].frames[0]) - 40) < 0.01, '只补实际滚动的 40');
console.log('LYRICS_SCROLL_OK');
''');
    });

    test('$axis：远跳 / 减弱动效直接落位；手动浏览冻结在当下视觉位置', () async {
      await _runJs('''
${_harness(js, vertical: vertical)}
const extent = ${vertical ? 'window.innerWidth' : 'window.innerHeight'};
const far = {offset: extent * 3 + 50};
scrollToCenter(far);
assert.equal(anims.length, 0, '超过 3 屏不做动画');
assert.equal(scroller.pos, extent * 3 + 50);

scroller.pos = 0;
window.__lyricsReduceMotion = true;
scrollToCenter({offset: 90});
assert.equal(anims.length, 0);
assert.equal(scroller.pos, 90);
window.__lyricsReduceMotion = false;

// 动画中手动浏览：位移折进滚动量，视觉不动、动画撤掉。
scroller.pos = 0;
const el = {offset: 150};
scrollToCenter(el);
anims[0].currentTime = 120;
const shown = visualOffset(el);
_lyShiftFreeze();
assert.ok(anims[0].cancelled);
assert.equal(_lyShift, null);
assert.ok(Math.abs(visualOffset(el) - shown) < 1e-6, '冻结后视觉位置不变');

// 浏览态下非强制回中不滚。
_lyBrowsing = true;
const pos = scroller.pos;
scrollToCenter({offset: pos + 80});
assert.equal(scroller.pos, pos);
scrollToCenter({offset: pos + 80}, 0, true);
assert.equal(scroller.pos, pos + 80);
console.log('LYRICS_SCROLL_OK');
''');
    });
  }

  test('旧的逐帧滚动积分已删除', () {
    final String doc = _doc(vertical: false);
    final String center = _between(
      doc,
      'function scrollToCenter(',
      '\n  _lyShiftStart(cur.x + moved, cur.v);\n}',
    );
    expect(center, isNot(contains('requestAnimationFrame')));
    expect(doc, isNot(contains('_animId')));
  });
}
