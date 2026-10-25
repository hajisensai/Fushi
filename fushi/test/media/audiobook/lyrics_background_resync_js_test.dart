import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-3770 R2：歌词层在后台 / 节流后回前台的两处 JS 行为（node vm 真跑生成文档里的
/// 脚本片段）。
///
/// * 扫过进度：Dart 在发送时刻按真实播放位置算出 fraction，JS 却可能晚很久才执行
///   （WebView 被节流 / 积压）；旧码在执行时才取 t0，整段扫过落后于声音。现在 Dart
///   带上发送时刻，JS 按速率补上这段延迟。
/// * 文档变回可见（visibilitychange）时请 Dart 重推快照。
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
  final Directory dir = Directory.systemTemp.createTempSync('lyrics-bg-');
  try {
    final File script = File('${dir.path}/verify.js')..writeAsStringSync(code);
    final ProcessResult result = await Process.run('node', <String>[
      script.path,
    ], runInShell: Platform.isWindows);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('LYRICS_BG_OK'));
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  final String doc = _doc();

  test('扫过进度按发送时刻补上 JS 执行延迟', () async {
    final String js = _between(
      doc,
      'function __lyricsProgressAtArrival(',
      '\n};',
    );
    await _runJs('''
const assert = require('node:assert/strict');
const window = {};
var _currentIdx = 0, _lyPlaying = true, _cues = [{id: 'cue0'}];
const builds = [];
function _lySweepBuild(el, p, rate) { builds.push({el, p, rate}); }
let wall = 100000;
Date.now = () => wall;
$js
// 及时到达：原样。
window.__lyricsSetProgress(0, 0.25, 0.5, wall);
assert.equal(builds.at(-1).p, 0.25);
assert.equal(builds.at(-1).rate, 0.5);
// 晚到 400 ms（节流积压）：补上 0.4 s × 0.5/s = 0.2。
window.__lyricsSetProgress(0, 0.25, 0.5, wall - 400);
assert.ok(Math.abs(builds.at(-1).p - 0.45) < 1e-9, String(builds.at(-1).p));
// 晚太久：钳在 1。
window.__lyricsSetProgress(0, 0.25, 0.5, wall - 60000);
assert.equal(builds.at(-1).p, 1);
// 未在推进（rate 0）、没带发送时刻（旧调用）、时钟回拨：都不补。
window.__lyricsSetProgress(0, 0.25, 0, wall - 400);
assert.equal(builds.at(-1).p, 0.25);
window.__lyricsSetProgress(0, 0.25, 0.5);
assert.equal(builds.at(-1).p, 0.25);
window.__lyricsSetProgress(0, 0.25, 0.5, wall + 400);
assert.equal(builds.at(-1).p, 0.25);
// 不是当前行 / 暂停中：不搭。
const n = builds.length;
window.__lyricsSetProgress(1, 0.25, 0.5, wall);
_lyPlaying = false;
window.__lyricsSetProgress(0, 0.25, 0.5, wall);
assert.equal(builds.length, n);
console.log('LYRICS_BG_OK');
''');
  });

  test('文档变回可见时请 Dart 重推快照，变不可见不请', () async {
    final String js = _between(
      doc,
      "document.addEventListener('visibilitychange'",
      '\n});',
    );
    await _runJs('''
const assert = require('node:assert/strict');
const listeners = {};
const document = {visibilityState: 'visible',
  addEventListener(type, fn) { listeners[type] = fn; }};
const calls = [];
const window = {flutter_inappwebview: {callHandler(name) { calls.push(name); }}};
$js
assert.equal(typeof listeners.visibilitychange, 'function');
document.visibilityState = 'hidden';
listeners.visibilitychange();
assert.deepEqual(calls, []);
document.visibilityState = 'visible';
listeners.visibilitychange();
assert.deepEqual(calls, ['onLyricsVisible']);
// 桥还没装好 / 桥抛错：不炸文档。
window.flutter_inappwebview = undefined;
listeners.visibilitychange();
window.flutter_inappwebview = {callHandler() { throw new Error('bridge gone'); }};
listeners.visibilitychange();
assert.deepEqual(calls, ['onLyricsVisible']);
console.log('LYRICS_BG_OK');
''');
  });
}
