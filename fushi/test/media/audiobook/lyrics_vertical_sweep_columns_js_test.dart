import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// BUG-3366：iOS 竖排歌词逐字扫过不按阅读顺序。WebKit 回退（BUG-3346）把 `.tx`
/// 变成 inline-block 后整块铺一条 `to bottom` 渐变，各列同步自上而下扫——屏上是
/// 一条横带，每列上半亮、下半暗。修法是按列铺渐变：右起第一列先扫满，下一列才开始。
///
/// 跑的是生成文档里**真实的** `_lyColumnSweepActive` / `_lyLayoutSweepColumns`，
/// DOM 只给最小桩（列几何、注音文本节点、当前句的放大 transform）。像素层只能在
/// 真 WebKit 上验（CI 没有）。
void main() {
  AudioCue cue(int i, String text) => AudioCue()
    ..id = i + 1
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = i
    ..textFragmentId = ''
    ..text = text
    ..startMs = i * 1000
    ..endMs = i * 1000 + 900
    ..audioFileIndex = 0;

  final String document = LyricsModeHtml.generate(
    cues: <AudioCue>[cue(0, 'その音に耳を澄ませてみると、扉の向こうで')],
    currentIndex: 0,
    backgroundColor: 'transparent',
    textColor: '#888888',
    accentColor: '#3366cc',
    fontSize: 24,
    vertical: true,
  );

  String section(String start, String end) {
    final int from = document.indexOf(start);
    if (from < 0) throw StateError('生成文档里找不到 $start');
    final int to = document.indexOf(end, from);
    if (to < 0) throw StateError('生成文档里找不到 $end');
    return document.substring(from, to);
  }

  final String columns = section(
    'function _lyColumnSweepActive()',
    'window.__lyricsSetProgress = function',
  );

  // 布局像素下三列（宽 40）：右列 x∈[80,120] 长 400、中列 [40,80] 长 400、
  // 左列 [0,40] 长 100；每列拆成两个文本节点。外加一个注音节点贴在右列外侧。
  // 当前句放大 1.15，盒子客户区原点 (100, 50)。
  String harness({
    required bool supportsSlice,
    required String display,
    required String body,
  }) =>
      '''
const assert=require('node:assert/strict');
const SCALE=1.15, OX=100, OY=50;
function rect(l,t,r,b){ return {left:OX+l*SCALE, top:OY+t*SCALE, right:OX+r*SCALE,
  bottom:OY+b*SCALE, width:(r-l)*SCALE, height:(b-t)*SCALE}; }
function textNode(rects, inRt){ return {rects:rects,
  parentElement:{closest:function(){ return inRt ? {} : null; }}}; }
const props={};
const tx={
  offsetWidth:120,
  style:{setProperty:function(k,v){ props[k]=v; }},
  getBoundingClientRect:function(){ return rect(0,0,120,400); },
  nodes:[
    textNode([rect(80,0,120,250)]),
    textNode([rect(80,250,120,400), rect(40,0,80,180)]),
    textNode([rect(120,10,135,40)], true),
    textNode([rect(40,180,80,400), rect(0,0,40,100)]),
  ],
};
const cueEl={querySelector:function(){ return tx; }};
var __lyricsVertical=true, _currentIdx=0, _cues=[cueEl];
const window={CSS:{supports:function(){ return $supportsSlice; }}};
const CSS=window.CSS;
const NodeFilter={SHOW_TEXT:4};
function getComputedStyle(){ return {display:'$display'}; }
const document={
  createTreeWalker:function(root){ let i=0;
    return {nextNode:function(){ return root.nodes[i++] || null; }}; },
  createRange:function(){ return {n:null, selectNodeContents:function(n){ this.n=n; },
    getClientRects:function(){ return this.n.rects; }}; },
};
function _lyTx(el){ return el ? el.querySelector('.tx') : null; }
$columns
$body
''';

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync('lyrics-cols-');
    try {
      final File script = File('${dir.path}/verify.js')
        ..writeAsStringSync(code);
      final ProcessResult result = await Process.run('node', <String>[
        script.path,
      ], runInShell: Platform.isWindows);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  test('WebKit 竖排按阅读顺序逐列扫过：右列扫满下一列才开始', () async {
    await runJs(
      harness(
        supportsSlice: false,
        display: 'inline-block',
        body: r'''
window.__lyricsLayoutSweepColumns();
const bg=props['--ly-cols-bg'].split('linear-gradient(').slice(1);
const pos=props['--ly-cols-pos'].split(', ');
const size=props['--ly-cols-size'].split(', ');
// 三列 + 兜底层；注音节点不单独成列。
assert.equal(bg.length, 4);
assert.equal(pos.length, 4);
assert.equal(size.length, 4);
// 右列先读，几何已换回布局像素（除掉放大 transform），两侧各放 2px。
assert.deepEqual(pos.slice(0,3), ['78.0px 0.0px', '38.0px 0.0px', '-2.0px 0.0px']);
assert.deepEqual(size.slice(0,3), ['44.0px 400.0px', '44.0px 400.0px', '44.0px 100.0px']);
assert.match(bg[3], /^var\(--ly-upcoming\), var\(--ly-upcoming\)\)/);
// 列内亮暗分界 = (p - s) * scale：解析真实写出的 calc，算各列在全局进度 p 下的位置。
const cols=bg.slice(0,3).map(function(g){
  const m=g.match(/calc\(\(var\(--ly-p\) - (-?[\d.]+)%\) \* ([\d.]+)\), var\(--ly-upcoming\) calc\(\(var\(--ly-p\) - (-?[\d.]+)%\) \* ([\d.]+)\)/);
  assert.ok(m, g);
  return {lit:+m[1], dim:+m[3], k:+m[2]};
});
function edge(c,p){ return ((p - c.lit) * c.k + (p - c.dim) * c.k) / 2; }
// 全长 900：右列占 [0,44.4%)、中列 [44.4%,88.9%)、左列其余。
const near=(a,b)=>assert.ok(Math.abs(a-b)<0.2, a+' vs '+b);
near(edge(cols[0],20), 45);           // 右列扫到 45%
assert.ok(edge(cols[1],20) < 0);      // 中列未开始
assert.ok(edge(cols[2],20) < 0);
assert.ok(edge(cols[0],50) > 100);    // 右列已满
near(edge(cols[1],50), 12.5);         // 中列刚过顶
assert.ok(edge(cols[2],50) < 0);
assert.ok(edge(cols[1],95) > 100);
near(edge(cols[2],95), 55);
// 软边宽度与整块渐变一致：全长的 ±4%。
near((cols[0].lit - cols[0].dim), 8);
''',
      ),
    );
  });

  test('Blink（认无前缀 slice）不铺列层，保持行内盒 + slice 跨列接续', () async {
    await runJs(
      harness(
        supportsSlice: true,
        display: 'inline-block',
        body: r'''
window.__lyricsLayoutSweepColumns();
assert.deepEqual(props, {});
''',
      ),
    );
  });

  test('暂停 / 查词时 .tx 是行内盒，不按错的坐标系量列', () async {
    await runJs(
      harness(
        supportsSlice: false,
        display: 'inline',
        body: r'''
window.__lyricsLayoutSweepColumns();
assert.deepEqual(props, {});
''',
      ),
    );
  });

  test('回退规则读列层变量，量到前退回整块渐变', () {
    final int at = document.indexOf(
      '@supports not (box-decoration-break: slice)',
    );
    final String block = document.substring(
      at,
      document.indexOf('}\n}', at) + 3,
    );
    expect(block, contains('background-image: var(--ly-cols-bg, '));
    expect(block, contains('background-position: var(--ly-cols-pos, 0 0);'));
    expect(block, contains('background-size: var(--ly-cols-size, 100% 100%);'));
    expect(block, contains('background-repeat: no-repeat;'));
    // 换句、起播、重新适配字号三处都要重量列。
    expect(
      RegExp(r'_lyLayoutSweepColumns\(_cues\[').allMatches(document).length,
      greaterThanOrEqualTo(4),
    );
    expect(
      document,
      contains('if (_lyPlaying) window.__lyricsLayoutSweepColumns();'),
    );
  });
}
