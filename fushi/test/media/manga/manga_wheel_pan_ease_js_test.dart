import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// BUG-2834：放大态（ZOOM>1）的滚轮平移也是无极滚动——一格分帧缓动到 _panBy
/// 钳好的落点，连拨累加，外部改 PAN 就让位，贴边仍按 BUG-1760 进翻页累计。
///
/// 跑的是生成文档里**真实的** _clampPan / _panBy / 滚轮监听三段，不是复刻。
void main() {
  final String document = mangaWindowDocument(
    const <MokuroImage>[
      MokuroImage(
        url: 'page.png',
        size: MokuroSize(1000, 600),
        blocks: <MokuroBlock>[],
      ),
    ],
    const <String>['page.png'],
    mode: MangaReadingMode.spread,
    spreadDirection: 'rtl',
    inlineSelectionJs: '',
  );

  String section(String start, String end) {
    final int from = document.indexOf(start);
    if (from < 0) throw StateError('生成文档里找不到 $start');
    final int to = document.indexOf(end, from);
    if (to < 0) throw StateError('生成文档里找不到 $end');
    return document.substring(from, to);
  }

  final String pan = section('  function _clampPan(){', '  // 方向键平移');
  final String wheel = section(
    '    var _wheelLock = false;',
    '  // ── 抑制原生拖拽残影',
  );

  /// 生产三段 + 最小桩：rAF 排队、flush() 逐帧推进。视口 1000x800、ZOOM 2，
  /// 可平移区间 X∈[-1000,0]、Y∈[-800,0]。
  String harness(String body) =>
      '''
const assert=require('node:assert/strict');
let ZOOM=2, PAN_X=0, PAN_Y=0, PAN_WIDE=true, IS_WEBTOON=false;
const window={innerWidth:1000,innerHeight:800};
let wheelHandler=null;
const document={addEventListener:(t,f)=>{ if(t==='wheel') wheelHandler=f; }};
let canvasWrites=0, turns=[];
function _applyCanvas(){ canvasWrites++; }
function _currentPageIsWide(){ return false; }
function _bridge(){ return {callHandler:(n,d)=>turns.push(d)}; }
function setTimeout(){ return 0; }
let frames=[];
function requestAnimationFrame(cb){ frames.push(cb); return frames.length; }
function cancelAnimationFrame(){}
function flush(n){
  let ran=0;
  while(frames.length && (n===undefined || ran<n)){
    frames.splice(0).forEach(f=>f()); ran++;
    assert.ok(ran<1000,'rAF never settles');
  }
  return ran;
}
function wheel(dy){ wheelHandler({deltaY:dy,deltaX:0,deltaMode:0,ctrlKey:false,metaKey:false,preventDefault(){}}); }
$pan
if (!IS_WEBTOON) {
$wheel
$body
''';

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'manga-wheel-pan-',
    );
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

  test('一格平移分帧缓动到位，不瞬跳', () async {
    await runJs(
      harness('''
wheel(100);
assert.equal(PAN_Y,0,'滚轮事件本身不落地（同任务内已撤回试走）');
flush(1);
assert.ok(PAN_Y<0 && PAN_Y>-100,'首帧在半路，got '+PAN_Y);
const n=1+flush();
assert.ok(n>=5,'跨多帧，ran '+n);
assert.equal(PAN_Y,-100,'终点 = _panBy 一步的落点');
assert.deepEqual(turns,[],'能平移就不翻页');
'''),
    );
  });

  test('连拨同向从未到达的落点累加；贴边钳住', () async {
    await runJs(
      harness('''
for(let i=0;i<3;i++){ wheel(100); flush(1); }
flush();
assert.equal(PAN_Y,-300,'3 格 = 300，不吃距离，got '+PAN_Y);
for(let i=0;i<20;i++){ wheel(100); flush(1); }
flush();
assert.equal(PAN_Y,-800,'钳在下边缘');
assert.deepEqual(turns,[],'飞向边缘途中不翻页');
'''),
    );
  });

  test('贴边后再滚仍进翻页累计（BUG-1760 语义不变）', () async {
    await runJs(
      harness('''
PAN_Y=-800;
wheel(100);
flush();
assert.deepEqual(turns,['next']);
assert.equal(PAN_Y,0,'贴边翻页后从新页顶部接续');
'''),
    );
  });

  test('拖动 / 方向键改了 PAN 时缓动让位', () async {
    await runJs(
      harness('''
wheel(100);
flush(1);
PAN_Y=-500; // 别的路径改了平移
flush();
assert.equal(PAN_Y,-500,'缓动不得把它拉回去');
assert.equal(frames.length,0,'且不再排帧');
'''),
    );
  });

  test('反拨从视觉位置起步', () async {
    await runJs(
      harness('''
PAN_Y=-400;
wheel(100);
flush(2);
const mid=PAN_Y;
assert.ok(mid<-400 && mid>-500,'mid '+mid);
wheel(-100);
flush();
assert.ok(Math.abs(PAN_Y-(mid+100))<1e-9,'反拨 = 视觉位置 + 100，got '+PAN_Y);
'''),
    );
  });
}
