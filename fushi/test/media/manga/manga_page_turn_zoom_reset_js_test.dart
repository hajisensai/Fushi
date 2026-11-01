import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 反馈 8HxGrnNy3x：漫画翻到另一页后，缩放倍率与平移复位到默认缩放 + 起始位置，
/// 不把上一页捏出来的放大带到下一页（所有者定为默认行为，无开关）。
///
/// 跑的是生成文档里**真实的** `_applyStartPan` / `_resetZoomForNewPage` /
/// `_applyWidePolicy`，不是复刻。换页才调复位（原地重放不调）由
/// `manga_swipe_follow_js_test.dart` 咬住。
void main() {
  String buildDocument({
    int zoomPercent = 100,
    int restZoomPercent = 100,
    String zoomStartPosition = 'automatic',
  }) => mangaWindowDocument(
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
    zoomPercent: zoomPercent,
    restZoomPercent: restZoomPercent,
    zoomStartPosition: zoomStartPosition,
  );

  String section(String document, String start, String end) {
    final int from = document.indexOf(start);
    if (from < 0) throw StateError('生成文档里找不到 $start');
    final int to = document.indexOf(end, from);
    if (to < 0) throw StateError('生成文档里找不到 $end');
    return document.substring(from, to);
  }

  /// 视口 412×860。`turnTo(w, h)` 模拟 `__mangaApplyTranslate` 换到另一跨页：
  /// 先复位，再按新页套宽页策略（与生产顺序一致：复位在 `_translateToSpread`
  /// → `_applyWidePolicy` 之前）。
  String harness(String document, String body) {
    final String rest = section(
      document,
      '  var ZOOM_REST_DEFAULT = ',
      '  function _userZoomedIn(){',
    );
    final String wide = section(
      document,
      '  function _recenterPan(){',
      '  function _applyPageHalf(){',
    );
    final String reset = section(
      document,
      '  function _applyStartPan(){',
      '  var rightDrag = null;',
    );
    return '''
const assert=require('node:assert/strict');
var ZOOM_MIN=0.5, ZOOM_MAX=5, ZOOM=1, PAN_X=0, PAN_Y=0, IS_WEBTOON=false;
var SPLIT_WIDE=false, ROTATE_WIDE=false, AUTO_ZOOM_WIDE=false, SPLIT_ACTIVE=false;
var CURRENT=0, PAGE_W=1000, PAGE_H=1414;
const window={innerWidth:412,innerHeight:860};
const page={get offsetWidth(){ return PAGE_W>PAGE_H*1.15 ? 206 : 300; },
  getAttribute:(k)=>k==='data-pw'?String(PAGE_W):String(PAGE_H)};
const document={querySelector(){ return page; }};
let reported=[], cancels=0;
function _bridge(){ return {callHandler:(n,v)=>{ if(n==='onMangaZoomChanged') reported.push(v); }}; }
function _applyCanvas(){}
function _clampPan(){}
function _applyPageHalf(){}
function _cancelDoubleTapZoom(){ cancels++; }
function _clampZoom(z){ return Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, z)); }
$rest
$wide
$reset
function turnTo(w,h){ CURRENT++; _resetZoomForNewPage(); PAGE_W=w; PAGE_H=h; _applyWidePolicy(); }
const close=(a,b,m)=>assert.ok(Math.abs(a-b)<1e-9,m+'：'+a+' ≠ '+b);
$body
''';
  }

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'manga-turn-zoom-',
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

  test('用户放大并平移后翻页：回到默认缩放并回中，回报 Dart 一次', () async {
    await runJs(
      harness(buildDocument(), '''
ZOOM=2.5; PAN_X=-300; PAN_Y=-500;
turnTo(1000,1414);
assert.equal(ZOOM,1,'上一页的放大不能带到下一页');
close(PAN_X,0,'横向回中'); close(PAN_Y,0,'纵向回中');
assert.deepEqual(reported,[100]);
assert.ok(cancels>0,'在播的双击缩放动画要先停掉，否则它会把倍率又推回去');
turnTo(1000,1414);
assert.deepEqual(reported,[100],'倍率没变就不再回报');
'''),
    );
  });

  test('快速缩回的整页适配跟页：按新页重新适应、静止倍率跟着走；捏合放大不跟页', () async {
    await runJs(
      harness(buildDocument(), '''
var QUICK_ZOOM_TARGET='fit_width';
var measured=[];
function _contentLocalRect(spread){ measured.push(spread); return {l:0,t:0,r:300,b:424}; }
function _fitZoomFor(axis,rect){ return window.innerWidth/(rect.r-rect.l); }
ZOOM=412/300; QUICK_FIT_ZOOM=ZOOM; ZOOM_REST=ZOOM;
_resetZoomForNewPage(1);
assert.deepEqual(measured,[1],'适配量的是将要显示的跨页，不是当前页');
close(ZOOM,412/300,'整页适配保持');
close(ZOOM_REST,ZOOM,'静止倍率跟着适配，点热区照常翻页');
close(QUICK_FIT_ZOOM,ZOOM,'仍持有适配');
_applyWidePolicy();
close(ZOOM_REST,412/300,'宽页策略不把适配打回「用户放大」');
ZOOM=2.4;
turnTo(1000,1414);
assert.equal(ZOOM,1,'适配之后又捏合放大：放大不跟页，回默认');
assert.equal(QUICK_FIT_ZOOM,null,'适配状态随之放弃');
'''),
    );
  });

  test('复位落点受缩小下限约束：默认缩放低于下限时落到下限', () async {
    await runJs(
      harness(buildDocument(restZoomPercent: 60), '''
ZOOM=2; ZOOM_MIN=0.8;
turnTo(1000,1414);
close(ZOOM,0.8,'不低于缩小下限');
'''),
    );
  });

  test('默认缩放 150%：复位到默认缩放而不是 100%', () async {
    await runJs(
      harness(buildDocument(zoomPercent: 300, restZoomPercent: 150), '''
ZOOM=3; PAN_X=-900;
turnTo(1000,1414);
close(ZOOM,1.5,'复位目标是设置里的默认缩放');
close(PAN_X,412*(1-1.5)/2,'自动起始位置 = 居中');
assert.deepEqual(reported,[150]);
'''),
    );
  });

  test('缩放起始位置「右」：新页从右侧开始看', () async {
    await runJs(
      harness(
        buildDocument(restZoomPercent: 200, zoomStartPosition: 'right'),
        '''
ZOOM=3; PAN_X=-50;
turnTo(1000,1414);
close(ZOOM,2,'默认缩放');
close(PAN_X,412*(1-2),'贴右');
''',
      ),
    );
  });

  test('宽页自动放大：放大态翻到普通页回默认缩放，翻到宽页按新页重新适配', () async {
    await runJs(
      harness(buildDocument(), '''
AUTO_ZOOM_WIDE=true;
ZOOM=3;
turnTo(1000,1414);
assert.equal(ZOOM,1,'普通页回默认缩放');
ZOOM=3;
turnTo(2000,1000);
close(ZOOM,2,'宽页按新页重新适配到贴满视口宽（412/206）');
assert.equal(AUTO_ZOOM.from,1,'自动放大的「放大前」是复位后的默认缩放，不是上一页的 300%');
ZOOM=2;
turnTo(1000,1414);
assert.equal(ZOOM,1,'翻离宽页回默认缩放');
assert.equal(AUTO_ZOOM,null);
'''),
    );
  });

  test('离开切半的宽页：回默认缩放，不回文档初值里残留的会话放大', () async {
    await runJs(
      harness(buildDocument(zoomPercent: 250, restZoomPercent: 100), '''
SPLIT_WIDE=true; SPLIT_ACTIVE=true; ZOOM=2.2;
turnTo(1000,1414);
assert.equal(SPLIT_ACTIVE,false);
assert.equal(ZOOM,1,'文档以会话倍率 250% 重建过，离开宽页也不能回到 250%');
'''),
    );
  });
}
