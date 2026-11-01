import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 反馈 EjyFnomM6w（墨水屏 Mobiscribe Wave）：漫画阅读器放大态的三项设置——
/// 放大时拖过边缘翻页可关、缩小下限可设为「适应页高」、快速缩回手势（双击 /
/// 双指轻点）缩回「适应页高 / 页宽」。
///
/// 跑的是生成文档里**真实的**脚本片段（按注释锚点截取），DOM / 视口用最小桩代替。
void main() {
  String documentFor(MangaReaderPreferences prefs) => mangaWindowDocument(
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
    readerPreferences: prefs,
  );

  String section(String document, String start, String end) {
    final int from = document.indexOf(start);
    if (from < 0) throw StateError('生成文档里找不到 $start');
    final int to = document.indexOf(end, from);
    if (to < 0) throw StateError('生成文档里找不到 $end');
    return document.substring(from, to);
  }

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync('manga-zoom-');
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

  group('放大时拖过边缘翻页', () {
    String harness(MangaReaderPreferences prefs, String body) {
      final String document = documentFor(prefs);
      final String pan = section(
        document,
        '  function _clampPan(){',
        '  // 方向键平移',
      );
      final String start = section(
        document,
        '  var sx = 0, sy = 0, st = 0, spx = 0, has = false;',
        '  // ── 触屏双指捏合缩放 ──',
      );
      final String end = section(
        document,
        '  function _end(x, y){',
        "  document.addEventListener('pointerdown', function(e){",
      );
      return '''
const assert=require('node:assert/strict');
let ZOOM=1, PAN_X=0, PAN_Y=0, PAN_WIDE=true, IS_WEBTOON=false, IS_RTL=true;
let ZOOM_REST=1;
function _userZoomedIn(){ return ZOOM > Math.max(1, ZOOM_REST) + 0.01; }
const window={innerWidth:412,innerHeight:860};
let turns=[], taps=0;
function _applyCanvas(){}
function _currentPageIsWide(){ return false; }
function _bridge(){ return {callHandler:(n,d)=>{ if(n==='onMangaTurn') turns.push(d); }}; }
function _onTap(){ taps++; }
let PAGE_ANIM='slide', FOLLOW_DRAG=true;
const FOLLOW_COMMIT=0.25, FOLLOW_FLING=0.6;
function _animMs(){ return 240; }
function _finishPageAnim(){}
function _dropDragHandoff(){}
let now=1000;
Date.now=()=>now;
$pan
$start
$end
function centerAt(zoom){ ZOOM=zoom; PAN_X=window.innerWidth*(1-ZOOM)/2; PAN_Y=window.innerHeight*(1-ZOOM)/2; }
function drag(dx){
  const x0=200, y=600;
  _start(x0,y);
  for(let i=1;i<=10;i++){ now+=30; _panBy(dx/10,0); }
  _end(x0+dx,y);
}
$body
''';
    }

    test('默认开：放大后拖到边缘继续拖照旧翻页', () async {
      await runJs(
        harness(const MangaReaderPreferences(), '''
centerAt(2);
PAN_X=-40;
drag(120);
assert.equal(PAN_X,0);
assert.deepEqual(turns,['next']);
'''),
      );
    });

    test('关掉后：放大态拖过边缘只贴边、不翻页，也不跟手', () async {
      await runJs(
        harness(const MangaReaderPreferences(zoomedEdgeTurn: false), '''
centerAt(2);
PAN_X=-40;
_start(200,600);
assert.equal(swipe.follow,false,'放大态不跟手');
_end(200,600);
drag(120);
assert.equal(PAN_X,0,'仍然先贴边');
assert.deepEqual(turns,[],'余量不交给翻页');
drag(300);
assert.deepEqual(turns,[],'再大的余量也不翻页');
'''),
      );
    });

    test('关掉后：没放大（默认倍率）照样滑动翻页', () async {
      await runJs(
        harness(const MangaReaderPreferences(zoomedEdgeTurn: false), '''
centerAt(1);
drag(120);
drag(-120);
assert.deepEqual(turns,['next','prev']);
'''),
      );
    });
  });

  group('缩小下限与快速缩回', () {
    /// 视口 412×860（竖屏），当前跨页一页，[page] 是它在 #manga-canvas 本地坐标里
    /// 的框（未乘 ZOOM）。动画关掉（animateDoubleTap:false）让缩放同步落定。
    String harness(
      MangaReaderPreferences prefs,
      String page,
      String body, {
      double zoomMin = 0.5,
    }) {
      final String document = documentFor(prefs);
      final String vars = section(
        document,
        '  var ZOOM_OUT_LIMIT',
        '  // 灵敏度倍率',
      );
      final String zoom = section(
        document,
        '  function _clampZoom(z){',
        '  // 捏合结束吸附',
      );
      final String pan = section(
        document,
        '  function _clampPan(){',
        '  function _panBy(',
      );
      final String twoTap = section(
        document,
        '  var TWO_TAP_MS',
        '  // 捏合结束后要吞掉配对的松手事件',
      );
      return '''
const assert=require('node:assert/strict');
const window={innerWidth:412,innerHeight:860};
let ZOOM=1, PAN_X=0, PAN_Y=0, IS_WEBTOON=false, IS_RTL=true, CURRENT=0;
let ZOOM_MIN=$zoomMin, ZOOM_MAX=4, ZOOM_REST_DEFAULT=1, ZOOM_REST=1;
const PINCH_NOOP=0.02;
const PAGE=$page;
const document={querySelectorAll:()=>[{getBoundingClientRect:()=>({
  left:PAN_X+PAGE.l*ZOOM, top:PAN_Y+PAGE.t*ZOOM,
  right:PAN_X+PAGE.r*ZOOM, bottom:PAN_Y+PAGE.b*ZOOM,
  width:(PAGE.r-PAGE.l)*ZOOM, height:(PAGE.b-PAGE.t)*ZOOM})}]};
let reported=[];
function _bridge(){ return {callHandler:(n,d)=>{ if(n==='onMangaZoomChanged') reported.push(d); }}; }
function _recenterPan(){ PAN_X=window.innerWidth*(1-ZOOM)/2; PAN_Y=window.innerHeight*(1-ZOOM)/2; }
function _applyCanvas(){}
function requestAnimationFrame(){ throw new Error('动画应已关闭'); }
function cancelAnimationFrame(){}
let now=1000;
Date.now=()=>now;
$vars
$pan
$zoom
$twoTap
const near=(a,b,msg)=>assert.ok(Math.abs(a-b)<1e-6,msg+': '+a+' vs '+b);
$body
''';
    }

    // 适应屏幕下的竖页：宽撑满、上下留白（页高 582.6 < 视口 860）。
    const String shortPage = '{l:0,t:138.7,r:412,b:721.3}';
    // 适应宽度下的长页：页高 1200 > 视口 860。
    const String tallPage = '{l:0,t:0,r:412,b:1200}';

    test('缩小下限「适应页高」：页比视口高时最多缩到页高撑满视口', () async {
      await runJs(
        harness(
          const MangaReaderPreferences(
            zoomOutLimit: 'fit_height',
            animateDoubleTap: false,
          ),
          tallPage,
          '''
near(_clampZoom(0.5), 860/1200, '不能缩到页高以下');
near(_clampZoom(0.8), 0.8, '下限以上不受影响');
''',
        ),
      );
    });

    test('缩小下限「适应页高」：页已比视口矮时下限就是默认适配（不强行放大）', () async {
      await runJs(
        harness(
          const MangaReaderPreferences(
            zoomOutLimit: 'fit_height',
            animateDoubleTap: false,
          ),
          shortPage,
          '''
near(_clampZoom(0.6), 1, '下限停在 100%');
near(_clampZoom(1.3), 1.3, '放大不受影响');
''',
        ),
      );
    });

    test('缩小下限默认「不限」：只受最小倍率约束', () async {
      await runJs(
        harness(
          const MangaReaderPreferences(animateDoubleTap: false),
          tallPage,
          "near(_clampZoom(0.5), 0.5, '照旧可缩到最小倍率');",
        ),
      );
    });

    test('双击缩回「适应页高」：放大态一击缩回页高撑满视口并摆正，再双击放大', () async {
      await runJs(
        harness(
          const MangaReaderPreferences(
            quickZoomGesture: 'double_tap',
            quickZoomTarget: 'fit_height',
            animateDoubleTap: false,
          ),
          shortPage,
          '''
ZOOM=3; PAN_X=-500; PAN_Y=-900;
_doubleTapZoom(100,100);
const fit=860/(721.3-138.7);
near(ZOOM, fit, '缩回适应页高');
near(PAN_Y, 430-(138.7+721.3)/2*fit, '纵向居中（页高正好撑满）');
near(PAN_X, 412-412*fit, '比视口宽：右开本从右侧起读');
near(ZOOM_REST, fit, '缩回的倍率记作静止倍率');
assert.equal(reported.at(-1), Math.round(fit*100));
_doubleTapZoom(100,100);
near(ZOOM, fit*2, '已在目标上：放大一倍');
''',
        ),
      );
    });

    test('双击缩回「适应页宽」：长页缩回页宽撑满并从页顶开始', () async {
      await runJs(
        harness(
          const MangaReaderPreferences(
            quickZoomGesture: 'double_tap',
            quickZoomTarget: 'fit_width',
            animateDoubleTap: false,
          ),
          '{l:56,t:0,r:356,b:860}',
          '''
ZOOM=2.5; PAN_X=-300; PAN_Y=-700;
_doubleTapZoom(50,50);
const fit=412/300;
near(ZOOM, fit, '缩回适应页宽');
near(PAN_X, 206-206*fit, '横向居中');
near(PAN_Y, 0, '页比视口高：从页顶开始');
''',
        ),
      );
    });

    test('快速缩回手势为「关闭」时双击照旧在 100% 与 2× 之间切换', () async {
      await runJs(
        harness(
          const MangaReaderPreferences(animateDoubleTap: false),
          shortPage,
          '''
ZOOM=3;
_doubleTapZoom(100,100);
near(ZOOM, 1, '回 100%');
_doubleTapZoom(100,100);
near(ZOOM, 2, '再放大到 2×');
''',
        ),
      );
    });

    test('双指轻点判定：快、几乎不动、没捏动倍率才算；没选这个手势一律不算', () async {
      const String body = '''
ZOOM=2;
const tap={t0:now-120,cx0:200,cy0:300,cx:206,cy:303,span:4,zoom:2};
assert.equal(_isTwoFingerTap(tap), EXPECT, '轻点');
assert.equal(_isTwoFingerTap({...tap,t0:now-450}), false, '按太久');
assert.equal(_isTwoFingerTap({...tap,span:60}), false, '指距变了 = 捏合');
assert.equal(_isTwoFingerTap({...tap,cx:260}), false, '中点挪了 = 拖动');
assert.equal(_isTwoFingerTap({...tap,zoom:1.5}), false, '倍率被捏动了');
''';
      await runJs(
        harness(
          const MangaReaderPreferences(quickZoomGesture: 'two_finger_tap'),
          shortPage,
          body.replaceAll('EXPECT', 'true'),
        ),
      );
      await runJs(
        harness(
          const MangaReaderPreferences(quickZoomGesture: 'double_tap'),
          shortPage,
          body.replaceAll('EXPECT', 'false'),
        ),
      );
    });

    test('双指轻点在第一根手指抬起时分流到快速缩回', () {
      final String document = documentFor(
        const MangaReaderPreferences(quickZoomGesture: 'two_finger_tap'),
      );
      final String release = section(
        document,
        '          var lastPinch = pinch;',
        '        } else {',
      );
      expect(release, contains('_isTwoFingerTap(lastPinch)'));
      expect(release, contains('_quickZoom();'));
    });
  });

  test('偏好往返：新字段落 JSON、非法值回默认', () {
    const MangaReaderPreferences prefs = MangaReaderPreferences(
      zoomedEdgeTurn: false,
      zoomOutLimit: 'fit_height',
      quickZoomGesture: 'two_finger_tap',
      quickZoomTarget: 'fit_width',
    );
    final MangaReaderPreferences back = MangaReaderPreferences.fromJson(
      prefs.toJson(),
    );
    expect(back.zoomedEdgeTurn, isFalse);
    expect(back.zoomOutLimit, 'fit_height');
    expect(back.quickZoomGesture, 'two_finger_tap');
    expect(back.quickZoomTarget, 'fit_width');
    final MangaReaderPreferences bad =
        MangaReaderPreferences.fromJson(const <String, Object?>{
          'zoomOutLimit': 'tiny',
          'quickZoomGesture': 'triple_tap',
          'quickZoomTarget': 'fit_screen',
        });
    expect(bad.zoomedEdgeTurn, isTrue);
    expect(bad.zoomOutLimit, 'free');
    expect(bad.quickZoomGesture, 'off');
    expect(bad.quickZoomTarget, 'fit_height');
  });
}
