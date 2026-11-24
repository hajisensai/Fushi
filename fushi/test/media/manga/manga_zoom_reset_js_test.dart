import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// BUG-2908：缩小到贴合以下后回不到正常比例。双击在任何非 100% 倍率下都要一击
/// 回到正好 100%（旧判据 ZOOM>1.01 让缩小态先跳 2×）；捏合松手落在 100% ±10%
/// 内要吸附回正好 100%（无级捏合人手凑不准）——但只在这次捏合真的改变了缩放时；
/// 两指只是搭上屏幕不能把设置里定的 105% 拉回 100%。
///
/// 跑的是生成文档里**真实的** `_clampZoom` / `_zoomAbout` / `_animateZoomTo` /
/// `_doubleTapZoom` / `_snapPinchZoom`，不是复刻。
void main() {
  String documentFor({required bool animate}) => mangaWindowDocument(
    const <MokuroImage>[
      MokuroImage(
        url: 'page.png',
        size: MokuroSize(1000, 1414),
        blocks: <MokuroBlock>[],
      ),
    ],
    const <String>['page.png'],
    mode: MangaReadingMode.spread,
    spreadDirection: 'rtl',
    inlineSelectionJs: '',
    animateDoubleTap: animate,
  );

  String section(String document, String start, String end) {
    final int from = document.indexOf(start);
    if (from < 0) throw StateError('生成文档里找不到 $start');
    final int to = document.indexOf(end, from);
    if (to < 0) throw StateError('生成文档里找不到 $end');
    return document.substring(from, to);
  }

  String harness(String document, String body) {
    // 缩放下限 / 快速缩回的设置变量（反馈 EjyFnomM6w）：默认值下双击与吸附
    // 行为不变，这里注入的就是默认值。
    final String vars = section(document, '  var ZOOM_OUT_LIMIT', '  // 灵敏度倍率');
    final String zoom = section(
      document,
      '  function _clampZoom(z){',
      "  document.addEventListener('pointerdown',_cancelDoubleTapZoom",
    );
    return '''
const assert=require('node:assert/strict');
var ZOOM_MIN=0.5, ZOOM_MAX=4, ZOOM=1, PAN_X=0, PAN_Y=0, IS_WEBTOON=false;
const window={innerWidth:412,innerHeight:860,scrollY:0,scrollTo(){}};
let reported=[];
function _bridge(){ return {callHandler:(n,v)=>{ if(n==='onMangaZoomChanged') reported.push(v); }}; }
let frames=[];
function _applyCanvas(){ frames.push([ZOOM,PAN_X,PAN_Y]); }
function _recenterPan(){ PAN_X=window.innerWidth*(1-ZOOM)/2; PAN_Y=window.innerHeight*(1-ZOOM)/2; }
let rafQueue=[], rafTime=0;
function requestAnimationFrame(cb){ rafQueue.push(cb); return rafQueue.length; }
function cancelAnimationFrame(){ rafQueue=[]; }
function flushFrames(){ while(rafQueue.length){ const cb=rafQueue.shift(); rafTime+=16; cb(rafTime); } }
$vars
$zoom
function setZoom(z){ ZOOM=z; _recenterPan(); }
// 缩放动画的每一帧（含落定那一帧）都要在同一条「以某个不动点缩放」的路径上：
// 平移的增量与倍率的增量成正比。落定后再回中 / 摆正的旧实现在最后一帧折出去。
function assertOnePath(z0,p0,axis,label){
  const ks=frames.filter(f=>Math.abs(f[0]-z0)>1e-6).map(f=>(f[axis]-p0)/(f[0]-z0));
  assert.ok(ks.length>=1,label+'：没有缩放帧');
  for (const k of ks) assert.ok(Math.abs(k-ks[0])<1e-6,label+'：缩放路径在第 '+ks.indexOf(k)+' 帧折了 '+JSON.stringify(ks));
}
const near=(a,b,msg)=>assert.ok(Math.abs(a-b)<1e-6,msg+': '+a+' vs '+b);
$body
''';
  }

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'manga-zoom-reset-',
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

  for (final bool animate in <bool>[true, false]) {
    final String document = documentFor(animate: animate);
    final String label = animate ? '动画' : '无动画';

    test('$label：缩小态双击一击回到正好 100% 并回中', () async {
      await runJs(
        harness(document, '''
setZoom(0.62);
_doubleTapZoom(100,300);
flushFrames();
assert.equal(ZOOM,1,'缩小态双击必须回到正常比例，不能先跳 2×');
assert.equal(PAN_X,0); assert.equal(PAN_Y,0);
assert.equal(reported.at(-1),100);
'''),
      );
    });

    test('$label：放大态双击回 100%，正好 100% 双击放大到 2×', () async {
      await runJs(
        harness(document, '''
setZoom(2.7);
_doubleTapZoom(100,300);
flushFrames();
assert.equal(ZOOM,1);
_doubleTapZoom(100,300);
flushFrames();
assert.equal(ZOOM,2);
'''),
      );
    });

    // BUG-5351（反馈 5VHASFiDKy）：放大与缩回的双击点不在同一处时，旧实现缩回动画以
    // 第二击为锚停在偏位，落定那一帧才跳回中间（录屏里最后一帧跳 15px）。
    test('$label：双击点不同处缩回，动画直接落到回中位置，最后一帧不跳', () async {
      await runJs(
        harness(document, '''
setZoom(1);
_doubleTapZoom(100,300);
flushFrames();
assert.equal(ZOOM,2);
near(PAN_X,-100,'放大以双击点为锚'); near(PAN_Y,-300,'放大以双击点为锚');
frames=[];
_doubleTapZoom(320,700);
flushFrames();
assert.equal(ZOOM,1);
assert.equal(PAN_X,0); assert.equal(PAN_Y,0);
if ($animate) { assertOnePath(2,-100,1,'横向'); assertOnePath(2,-300,2,'纵向'); }
'''),
      );
    });

    test('$label：放大后拖动过再双击缩回，同样一条路径落到回中', () async {
      await runJs(
        harness(document, '''
setZoom(2);
PAN_X=-380; PAN_Y=-40;
frames=[];
_doubleTapZoom(50,800);
flushFrames();
assert.equal(ZOOM,1);
assert.equal(PAN_X,0); assert.equal(PAN_Y,0);
if ($animate) { assertOnePath(2,-380,1,'横向'); assertOnePath(2,-40,2,'纵向'); }
'''),
      );
    });

    test('$label：条漫缩回横向回中、纵向保住第二击下的内容', () async {
      await runJs(
        harness(document, '''
IS_WEBTOON=true;
var lastReaderScroll=0;
const scrolls=[];
window.scrollY=1000;
window.scrollTo=(x,y)=>{ window.scrollY=y; scrolls.push([ZOOM,y]); };
setZoom(1); PAN_Y=0;
_doubleTapZoom(100,300);
flushFrames();
assert.equal(ZOOM,2);
near(PAN_X,-100,'横向以双击点为锚'); near(window.scrollY,2300,'纵向以双击点为锚');
frames=[]; scrolls.length=0;
_doubleTapZoom(300,500);
flushFrames();
assert.equal(ZOOM,1);
assert.equal(PAN_X,0); assert.equal(PAN_Y,0);
near(window.scrollY,900,'第二击下的内容不动');
for (const [z,y] of scrolls) near((y+500)/z,1400,'每帧纵向锚点不动');
if ($animate) assertOnePath(2,-100,1,'横向');
'''),
      );
    });

    test('$label：捏合松手落在 100% ±10% 内吸附到正好 100%', () async {
      await runJs(
        harness(document, '''
for (const [from, z] of [[0.6, 0.9], [0.7, 0.95], [1.5, 1.04], [2, 1.1], [1.05, 0.97]]) {
  setZoom(z); PAN_X+=7;
  _snapPinchZoom(200,400,from);
  flushFrames();
  assert.equal(ZOOM,1,'吸附 '+z);
  assert.equal(PAN_X,0,'吸附后回中 '+z);
}
'''),
      );
    });

    test('$label：明显缩放的捏合结果不被吸附', () async {
      await runJs(
        harness(document, '''
for (const z of [0.6, 0.85, 1.2, 2]) {
  setZoom(z);
  _snapPinchZoom(200,400,1);
  flushFrames();
  assert.equal(ZOOM,z,'不该吸附 '+z);
}
'''),
      );
    });

    test('$label：起点 105% 的两指触碰几乎没缩放就抬起，保持 105%', () async {
      await runJs(
        harness(document, '''
for (const end of [1.05, 1.052, 1.06, 1.035]) {
  setZoom(end); const panX=PAN_X;
  _snapPinchZoom(200,400,1.05);
  flushFrames();
  assert.equal(ZOOM,end,'没缩放的两指触碰不该吸附 '+end);
  assert.equal(PAN_X,panX);
}
'''),
      );
    });
  }

  test('捏合结束（不足两指）时吸附，锚点取最后的捏合中心、起点取捏合开始的倍率', () {
    final String document = documentFor(animate: true);
    expect(
      document.contains(
        'pinch = {dist: g.dist, zoom: ZOOM, cx: g.cx, cy: g.cy,',
      ),
      isTrue,
    );
    expect(document.contains('pinch.cx = g.cx;'), isTrue);
    // 捏合结束先分流双指轻点（快速缩回，反馈 EjyFnomM6w；没选该手势时恒为假），
    // 其余照旧吸附。
    final int nullAt = document.indexOf(
      '          pinch = null;\n'
      '          if (_isTwoFingerTap(lastPinch)) {',
    );
    expect(nullAt, greaterThanOrEqualTo(0));
    final int snapAt = document.indexOf(
      '            _snapPinchZoom(lastPinch.cx, lastPinch.cy, lastPinch.zoom);',
      nullAt,
    );
    expect(snapAt, greaterThan(nullAt));
  });
}
