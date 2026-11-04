import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi_audio/fushi_audio.dart';

import '../../pages/reader_fushi_page_source_corpus.dart';

/// BUG-4007 R2：播放态同步不能挂在「当前句落在已载窗口里」上。
///
/// 手动浏览中播放句被滑动窗口卸出窗口时，旧码只下发 `__lyricsSetCue(-1,false)` 就返回，
/// `__lyricsSetPlaying` 一起被跳过：JS 的 `_lyPlaying` 与真实播放态脱节——
/// A：暂停浏览后按播放，JS 不起「4 秒回到跟随」计时，歌词层一直卡在浏览态；
/// B：播放中浏览后暂停，JS 不停计时，4 秒后仍把视口拽回播放句（整页重开）。
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
  cues: <AudioCue>[for (int i = 0; i < 5; i++) _cue(i)],
  currentIndex: 2,
  hasCuesAfter: true,
  backgroundColor: 'transparent',
  textColor: '#888888',
  accentColor: '#3366cc',
  fontSize: 24,
);

String _section(String source, String start, String end) {
  final int from = source.indexOf(start);
  if (from < 0) throw StateError('找不到 $start');
  final int to = source.indexOf(end, from + start.length);
  if (to < 0) throw StateError('找不到 $end');
  return source.substring(from, to);
}

/// 生成文档里真实的浏览态 / 回中计时 / 播放态代码，跑在最小桩上（假计时器、
/// 记录 onLyricsBrowse 调用），再执行 Dart 真实下发的同步脚本。
String _harness({required String browseJs, required String playingJs}) =>
    '''
const assert=require('node:assert/strict');
function classList(){ const s=new Set(); return {add:(...a)=>a.forEach(x=>s.add(x)),
  remove:(...a)=>a.forEach(x=>s.delete(x)), contains:(x)=>s.has(x),
  toggle:(x,on)=>{ if(on===undefined) on=!s.has(x); if(on) s.add(x); else s.delete(x); }}; }
const document={body:{classList:classList()}};
document.body.classList.add('ly-themed');
const browseCalls=[];
const window={__fushiLyricsLoadGeneration:7, flutter_inappwebview:{callHandler(n,...a){
  if(n==='onLyricsBrowse') browseCalls.push(a[0]); }}};
let timers=new Map(), nextId=1;
function setTimeout(fn,ms){ const id=nextId++; timers.set(id,{fn,ms}); return id; }
function clearTimeout(id){ timers.delete(id); }
function runTimers(){ const t=[...timers.values()]; timers.clear(); t.forEach(x=>x.fn()); }
var _animId=0, _currentIdx=2, _cues=[], _lySw=null;
function scrollToCenter(){}
function _lySweepProgressNow(){ return 0; }
function _lySweepRelayout(){}
function _lySweepClearCue(){}
window.__lyricsSetCue=function(i){ _currentIdx=i<0?-1:i; };
window.__lyricsSetProgress=function(){};
$browseJs
$playingJs
module.exports={get playing(){ return _lyPlaying; }, get browsing(){ return _lyBrowsing; },
  enter:_lyEnterBrowse, timers, runTimers, browseCalls, window, document};
''';

Future<void> _runNode(String code) async {
  final Directory dir = Directory.systemTemp.createTempSync('lyrics-play-');
  try {
    final File script = File('${dir.path}/verify.js')..writeAsStringSync(code);
    final ProcessResult result = await Process.run('node', <String>[
      script.path,
    ], runInShell: Platform.isWindows);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('PLAY_OK'));
  } finally {
    dir.deleteSync(recursive: true);
  }
}

void main() {
  test('every sync script carries the play state, whatever the cue', () {
    final String out = LyricsModeHtml.overlaySyncScript(
      playing: true,
      clearCue: true,
    );
    expect(out, contains('window.__lyricsSetCue(-1,false);'));
    expect(out, contains('window.__lyricsSetPlaying(true);'));
    expect(out, isNot(contains('__lyricsSetProgress')));

    final String gap = LyricsModeHtml.overlaySyncScript(playing: false);
    expect(gap, contains('window.__lyricsSetPlaying(false);'));
    expect(gap, isNot(contains('__lyricsSetCue')));

    final String full = LyricsModeHtml.overlaySyncScript(
      playing: true,
      cue: (
        index: 3,
        scroll: true,
        forceReveal: true,
        fraction: 0.25,
        ratePerSec: 1.5,
        sentAtMs: 42,
      ),
    );
    final int setCue = full.indexOf('window.__lyricsSetCue(3, true);');
    final int reveal = full.indexOf('window.__lyricsScrollToCue(3);');
    final int playing = full.indexOf('window.__lyricsSetPlaying(true);');
    final int progress = full.indexOf(
      'window.__lyricsSetProgress(3,0.2500,1.50000,42);',
    );
    expect(setCue, isNonNegative);
    expect(reveal, greaterThan(setCue));
    expect(playing, greaterThan(reveal));
    expect(progress, greaterThan(playing));
  });

  test('play state reaches the JS resume timer while the cue is outside the '
      'window', () async {
    final String doc = _doc();
    final String browseJs = _section(
      doc,
      'var _lyBrowsing = false, _lyResumeTimer = 0, _lyPlaying = false;',
      "window.addEventListener('wheel'",
    );
    final String playingJs = _section(
      doc,
      'window.__lyricsSetPlaying = function(playing) {',
      '// 覆盖层主题热更',
    );
    final String resumeOnPlay = LyricsModeHtml.overlaySyncScript(
      playing: true,
      clearCue: true,
    );
    final String pauseWhileAway = LyricsModeHtml.overlaySyncScript(
      playing: false,
      clearCue: true,
    );
    await _runNode('''
${_harness(browseJs: browseJs, playingJs: playingJs)}
const m=module.exports;
// A：暂停中手动浏览（不起计时），播放句被卸出窗口后按播放。
m.enter();
assert.equal(m.browsing, true);
assert.equal(m.timers.size, 0);
(function(window){ $resumeOnPlay })(m.window);
assert.equal(m.playing, true);
assert.equal(m.document.body.classList.contains('ly-paused'), false);
assert.equal(m.timers.size, 1, '继续播放必须起 4 秒回到跟随计时');
assert.equal([...m.timers.values()][0].ms, 4000);
m.runTimers();
assert.equal(m.browsing, false);
assert.deepEqual(m.browseCalls, [true, false]);
// B：播放中浏览（起计时），播放句已出窗口时暂停：计时必须停，视口不被拽走。
m.browseCalls.length=0;
m.enter();
assert.equal(m.timers.size, 1);
(function(window){ $pauseWhileAway })(m.window);
assert.equal(m.playing, false);
assert.equal(m.document.body.classList.contains('ly-paused'), true);
assert.equal(m.timers.size, 0, '暂停必须停掉回中计时');
m.runTimers();
assert.equal(m.browsing, true);
assert.deepEqual(m.browseCalls, [true]);
console.log('PLAY_OK');
''');
  });

  test('reader sync sends play state through the shared script on every '
      'non-reload exit', () {
    final String source = readReaderPageSource();
    final String sync = _section(
      source,
      '  void _syncLyricsOverlayCue(',
      '  /// BUG-3777 R2：回前台',
    );
    // 播放态只经 overlaySyncScript 下发，不在这里手拼（手拼就会有出口漏掉它）。
    expect(sync, isNot(contains('__lyricsSetPlaying')));
    expect(sync, isNot(contains('__lyricsSetCue')));
    expect(
      'LyricsModeHtml.overlaySyncScript('.allMatches(sync).length,
      3,
      reason: 'cue 间隙 / 播放句出窗口 / 正常三条出口都要下发播放态',
    );
    expect(
      sync,
      contains('overlaySyncScript(playing: playing, clearCue: true)'),
    );
  });
}
