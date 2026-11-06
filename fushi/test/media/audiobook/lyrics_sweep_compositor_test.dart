import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/media/audiobook/lyrics_player/lyrics_player_contract.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 歌词逐字扫过只靠合成器可动画的属性推进。
///
/// 旧实现把进度放在注册自定义属性 `--ly-p` 上、用 CSS transition 推：自定义属性
/// 动画在 Blink / WebKit 都不能上合成器，播放全程每帧主线程重算样式、重画当前行，
/// WebView 持续 60fps 出帧（Windows 上 WebView2 每帧逼 Flutter 整帧重合成：手机
/// 发热、PC 歌词滚动掉帧）。现在是「未读色底层 + 当前色副本窗口」，窗口与副本各
/// 一条反向的 transform 关键帧动画。
///
/// 像素与「播放中不再每帧 Paint」只能在真浏览器里验（Chromium trace / Mac WebKit），
/// 这里钉住机制：不再出现主线程动画属性、关键帧只动 transform、进度映射与旧渐变
/// （全长 ±4% 软边、跨行接续、竖排右起逐列）一致、暂停 / 查词不留空转动画。
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

AudioCue _cue(int i, String text) => AudioCue()
  ..id = i + 1
  ..bookKey = 'book'
  ..chapterHref = 'chapter'
  ..sentenceIndex = i
  ..textFragmentId = ''
  ..text = text
  ..startMs = i * 1000
  ..endMs = i * 1000 + 900
  ..audioFileIndex = 0;

String _html({required bool vertical}) => LyricsModeHtml.generate(
  cues: <AudioCue>[_cue(0, 'その音に耳を澄ませてみると、扉の向こうで'), _cue(1, '次の行')],
  currentIndex: 0,
  backgroundColor: 'transparent',
  textColor: '#888888',
  accentColor: '#3366cc',
  fontSize: 24,
  vertical: vertical,
  theme: _theme,
);

String _section(String doc, String start, String end) {
  final int from = doc.indexOf(start);
  if (from < 0) throw StateError('生成文档里找不到 $start');
  final int to = doc.indexOf(end, from);
  if (to < 0) throw StateError('生成文档里找不到 $end');
  return doc.substring(from, to);
}

String _sweepJs(String doc) =>
    _section(doc, '// ── 逐字扫过（Niratan line progress）──', '// 覆盖层主题热更');

Future<void> _runJs(String code) async {
  final Directory dir = Directory.systemTemp.createTempSync('lyrics-sweep-');
  try {
    final File script = File('${dir.path}/verify.js')..writeAsStringSync(code);
    final ProcessResult result = await Process.run('node', <String>[
      script.path,
    ], runInShell: Platform.isWindows);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('SWEEP_OK'));
  } finally {
    dir.deleteSync(recursive: true);
  }
}

/// 最小 DOM 桩：当前句放大 1.25、客户区原点 (100, 50)；文字两行（横排）或两列
/// （竖排），外加一个注音文本节点。动画只记录参数。
String _domHarness({required bool vertical, required String sweepJs}) {
  final String lines = vertical
      // 竖排：右列 x∈[80,120] 长 300（两段）、左列 x∈[40,80] 长 100。
      ? 'textNode([rect(80,0,120,180)]), textNode([rect(80,180,120,300), rect(40,0,80,100)]),'
      // 横排：上行 y∈[0,40] 长 300（两段）、下行 y∈[40,80] 长 100。
      : 'textNode([rect(0,0,180,40)]), textNode([rect(180,0,300,40), rect(0,40,100,80)]),';
  return '''
const assert=require('node:assert/strict');
const SCALE=1.25, OX=100, OY=50;
function rect(l,t,r,b){ return {left:OX+l*SCALE, top:OY+t*SCALE, right:OX+r*SCALE,
  bottom:OY+b*SCALE, width:(r-l)*SCALE, height:(b-t)*SCALE}; }
function textNode(rects, inRt){ return {rects:rects,
  parentElement:{closest:function(){ return inRt ? {} : null; }}}; }
function classList(){ const s=new Set(); return {add:(...a)=>a.forEach(x=>s.add(x)),
  remove:(...a)=>a.forEach(x=>s.delete(x)), contains:(x)=>s.has(x),
  toggle:(x,on)=>{ if(on===undefined) on=!s.has(x); if(on) s.add(x); else s.delete(x); }}; }
const animations=[];
let now=1000;
const performance={now:()=>now};
function makeEl(tag){
  const el={tag:tag, style:{cssText:'', transform:''}, children:[], className:'',
    attrs:{}, classList:null,
    setAttribute(k,v){ this.attrs[k]=v; },
    appendChild(c){ this.children.push(c); c.parentNode=this; return c; },
    removeChild(c){ this.children.splice(this.children.indexOf(c),1); },
    attachShadow(){ this.shadow=makeEl('#shadow'); return this.shadow; },
    animate(frames, opts){ const a={el:this, frames:frames, opts:opts, cancelled:false,
      cancel(){ this.cancelled=true; }}; animations.push(a); return a; },
  };
  el.classList={contains:(x)=>el.className.split(' ').indexOf(x)>=0};
  return el;
}
const tx={nodes:[ $lines textNode([rect(0,-12,20,0)], true) ], cloneNode(){ return {clone:true}; }};
const cue=makeEl('div');
cue.classList=classList();
cue.classList.add('cue','current');
cue.querySelector=()=>tx;
cue.getBoundingClientRect=()=>rect(0,0,300,${vertical ? 400 : 120});
const body={classList:classList()};
body.classList.add('ly-themed','ly-sweep');
const document={body:body,
  createElement:makeEl,
  createTreeWalker(root){ let i=0; return {nextNode(){ return root.nodes[i++]||null; }}; },
  createRange(){ return {n:null, selectNodeContents(n){ this.n=n; },
    getClientRects(){ return this.n.rects; }}; },
};
const window={};
const NodeFilter={SHOW_TEXT:4};
function getComputedStyle(){ return {transform:'matrix(1.25, 0, 0, 1.25, 0, 0)',
  paddingTop:'10px', paddingRight:'14px', paddingBottom:'10px', paddingLeft:'14px'}; }
var __lyricsVertical=$vertical, _currentIdx=0, _cues=[cue], _lyPlaying=false, _lyResumeTimer=0;
function _lyScheduleResume(){}
$sweepJs
''';
}

void main() {
  for (final bool vertical in <bool>[false, true]) {
    final String doc = _html(vertical: vertical);
    final String sweep = _sweepJs(doc);
    final String tag = vertical ? '竖排' : '横排';

    test('$tag：不再用会走主线程的动画属性推进扫过', () {
      // 注册自定义属性 + transition / 背景裁切渐变是旧的主线程路径。
      expect(doc, isNot(contains('@property --')));
      // 旧进度变量（--ly-pad-* / --ly-past-k / --ly-pill-* 是别的变量）。
      expect(doc, isNot(matches(RegExp(r'--ly-p(?![\w-])'))));
      expect(doc, isNot(contains('background-clip: text')));
      expect(doc, isNot(contains('--ly-cols-')));
      // 扫过段不写 CSS 变量、不挂 transition、不逐帧回调。
      expect(sweep, isNot(contains("setProperty('--")));
      expect(sweep, isNot(contains('.transition')));
      expect(sweep, isNot(contains('requestAnimationFrame')));
      expect(sweep, isNot(contains('setInterval')));
      expect(sweep, isNot(contains('background')));
      // 推进只靠 Web Animations，关键帧对象只有 offset + transform。
      expect(sweep, contains('.animate('));
      final Iterable<RegExpMatch> frames = RegExp(
        r'\bf[wi]\.push\(\{[^}]*\}\)',
      ).allMatches(sweep);
      expect(frames, hasLength(2));
      for (final RegExpMatch m in frames) {
        final String obj = m.group(0)!;
        final Iterable<String> keys = RegExp(
          r'([A-Za-z]+): ',
        ).allMatches(obj).map((RegExpMatch k) => k.group(1)!);
        expect(keys.toSet(), <String>{'offset', 'transform'}, reason: obj);
      }
    });

    test('$tag：搭出的动画只动 transform、窗口与副本反向、时长按进度与倍速', () async {
      await _runJs('''
${_domHarness(vertical: vertical, sweepJs: sweep)}
// 未播放：不搭（暂停态整行点亮）。
window.__lyricsSetProgress(0, 0.25, 0.5);
assert.equal(animations.length, 0);
assert.equal(cue.classList.contains('ly-sw-on'), false);
window.__lyricsSetPlaying(true);
window.__lyricsSetProgress(0, 0.25, 0.5);
// 两行（列）× 窗口 + 副本。
assert.equal(animations.length, 4);
assert.equal(cue.classList.contains('ly-sw-on'), true);
// Dart 每次同步都先重复下发播放态：没翻转就不重搭、不取消在跑的动画。
window.__lyricsSetPlaying(true);
assert.equal(animations.length, 4);
assert.ok(animations.every((a) => !a.cancelled));
const fn = __lyricsVertical ? 'translateY(' : 'translateX(';
for (let i = 0; i < animations.length; i += 2) {
  const w = animations[i], inner = animations[i + 1];
  assert.equal(w.opts.duration, (1 - 0.25) / 0.5 * 1000);
  assert.equal(w.opts.fill, 'forwards');
  assert.equal(w.opts.easing, 'linear');
  assert.equal(w.frames.length, inner.frames.length);
  for (let f = 0; f < w.frames.length; f++) {
    assert.deepEqual(Object.keys(w.frames[f]).sort(), ['offset', 'transform']);
    assert.ok(w.frames[f].transform.startsWith(fn), w.frames[f].transform);
    const a = parseFloat(w.frames[f].transform.slice(fn.length));
    const b = parseFloat(inner.frames[f].transform.slice(fn.length));
    assert.ok(Math.abs(a + b) < 1e-9, 'inner must cancel window: ' + a + ' / ' + b);
  }
  assert.equal(w.frames[0].offset, 0);
  assert.equal(w.frames[w.frames.length - 1].offset, 1);
}
// 副本放在影子树里（不进 TreeWalker / textContent / 选区），盒子是布局像素。
const host = cue.children[0];
assert.equal(host.className, 'ly-sw');
assert.equal(host.attrs['aria-hidden'], 'true');
const inner0 = host.shadow.children[1].children[0];
assert.match(inner0.style.cssText, /width:300px;height:${vertical ? 400 : 120}px;/);
// seek / 倍速：重搭，旧动画取消。
const old = animations.slice();
now += 500;
window.__lyricsSetProgress(0, 0.6, 1);
assert.ok(old.every((a) => a.cancelled));
assert.equal(cue.children.length, 1);
assert.equal(animations[4].opts.duration, 400);
// 暂停：冻结进度、拆掉上层，不留空转动画。
now += 100;  // 0.6 + 0.1 = 0.7
window.__lyricsSetPlaying(false);
assert.ok(animations.every((a) => a.cancelled));
assert.equal(cue.children.length, 0);
assert.equal(cue.classList.contains('ly-sw-on'), false);
// 暂停中重排（字号适配）不搭、不推进。
now += 5000;
window.__lyricsRelayoutSweep();
assert.equal(cue.children.length, 0);
// 继续播放：从冻结处接着推（0.7 → 剩 300ms）。
window.__lyricsSetPlaying(true);
const resumed = animations[animations.length - 2];
assert.ok(Math.abs(resumed.opts.duration - 300) < 1e-6, resumed.opts.duration);
// 查词：.ly-nosweep → 不再搭。
cue.classList.add('ly-nosweep');
window.__lyricsSetProgress(0, 0.8, 1);
assert.equal(cue.children.length, 0);
cue.classList.remove('ly-nosweep');
// 关掉扫过（主题热更摘 ly-sweep）同理。
body.classList.remove('ly-sweep');
window.__lyricsSetProgress(0, 0.8, 1);
assert.equal(cue.children.length, 0);
console.log('SWEEP_OK');
''');
    });
  }

  test('进度映射与旧渐变一致：软边中心 = 全句进度，跨行接续，竖排右起逐列', () async {
    final String sweep = _sweepJs(_html(vertical: true));
    final String pure = _section(
      sweep,
      'function __lyricsSweepLines(',
      'function _lyCueScale(',
    );
    await _runJs('''
const assert=require('node:assert/strict');
$pure
// 竖排：三列（右 → 左先读），每列两段；注音之外的段按列合并。
const v = __lyricsSweepLines([
  {l:40,r:80,t:0,b:180}, {l:80,r:120,t:0,b:250}, {l:80,r:120,t:250,b:400},
  {l:40,r:80,t:180,b:400}, {l:0,r:40,t:0,b:100},
], true);
assert.deepEqual(v.map((c) => [c.v0, c.v1, c.u0, c.u1]),
  [[80,120,0,400],[40,80,0,400],[0,40,0,100]]);
// 条带：相邻列中线分界，首尾外扩半列。
assert.deepEqual(v.map((c) => [c.b0, c.b1]), [[80,140],[40,80],[-20,40]]);
// 横排：自上而下。
const h = __lyricsSweepLines([
  {l:0,r:100,t:40,b:80}, {l:0,r:300,t:0,b:40},
], false);
assert.deepEqual(h.map((c) => [c.v0, c.u1]), [[0,300],[40,100]]);
// 进度映射：全长 900（400/400/100），软边半宽 = 4%·900 = 36。
const total = 900, half = 36;
const lens = [400, 400, 100];
let acc = 0;
const spans = lens.map((len) => { const s = acc / total; acc += len; return {s, e: acc / total, len}; });
// 软边中心在行内的位置 = len + offset；换回全句比例应等于 p（未被钳住时）。
for (const p of [0.1, 0.3, 0.44, 0.5, 0.9, 0.95]) {
  for (const sp of spans) {
    const off = __lyricsSweepOffset(p, sp.e, sp.len, total, half);
    const centre = sp.s + (sp.len + off) / total;
    const clampLo = sp.s - half / total, clampHi = sp.e + half / total;
    if (p >= clampLo && p <= clampHi) assert.ok(Math.abs(centre - p) < 1e-9, p + ' ' + centre);
    else if (p < clampLo) assert.ok(centre < sp.s - half / total + 1e-9);   // 整行未读
    else assert.ok(centre > sp.e + half / total - 1e-9);                    // 整行已读
  }
}
// 跨行接续：p 落在第一列尾附近时，第二列首的软边已经开始进场（与 slice 渐变一致）。
const pEdge = spans[0].e;  // 0.444
const off1 = __lyricsSweepOffset(pEdge, spans[1].e, spans[1].len, total, half);
assert.ok(spans[1].len + off1 > -half && spans[1].len + off1 < half);
// 关键帧：线性插值后与逐点映射处处一致。
for (const p0 of [0, 0.2, 0.5, 0.97]) {
  for (const sp of spans) {
    const fr = __lyricsSweepFrames(p0, sp.s, sp.e, sp.len, total, half);
    assert.equal(fr[0].offset, 0);
    assert.equal(fr[fr.length - 1].offset, 1);
    for (let k = 1; k < fr.length; k++) assert.ok(fr[k].offset > fr[k - 1].offset);
    for (let q = 0; q <= 100; q++) {
      const o = q / 100, p = p0 + (1 - p0) * o;
      let j = 0; while (j < fr.length - 2 && fr[j + 1].offset < o) j++;
      const a = fr[j], b = fr[j + 1];
      const lerp = a.shift + (b.shift - a.shift) * ((o - a.offset) / (b.offset - a.offset));
      assert.ok(Math.abs(lerp - __lyricsSweepOffset(p, sp.e, sp.len, total, half)) < 1e-6);
    }
  }
}
console.log('SWEEP_OK');
''');
  });
}
