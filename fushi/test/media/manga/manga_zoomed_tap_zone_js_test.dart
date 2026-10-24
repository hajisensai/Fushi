import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// BUG-3634：用户放大看细节时，点左右热区不再翻页；阅读器自己放大的倍率
/// （默认缩放 / 宽页切半 / 宽页自动放大 / 分镜聚焦）不算「用户放大」。
///
/// 跑的是生成文档里**真实的** `_userZoomedIn` / `_tapZoneTurn` / `_onTap` /
/// `_applyWidePolicy`，不是复刻。
void main() {
  String buildDocument({int zoomPercent = 100, int? restZoomPercent}) =>
      mangaWindowDocument(
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
      );

  String section(String document, String start, String end) {
    final int from = document.indexOf(start);
    if (from < 0) throw StateError('生成文档里找不到 $start');
    final int to = document.indexOf(end, from);
    if (to < 0) throw StateError('生成文档里找不到 $end');
    return document.substring(from, to);
  }

  /// 视口 412×860（竖屏手机）、RTL、默认左右热区布局。`tap(x)` = 一次单击；
  /// `flush()` 跑掉挂起的定时器（空白单击延后上报的 onTapEmpty）。
  String harness(String document, String body) {
    final String zoom = section(
      document,
      '  var ZOOM = Math.min(',
      '  var SPLIT_WIDE',
    );
    final String wide = section(
      document,
      '  function _recenterPan(){',
      '  function _applyPageHalf(){',
    );
    final String tap = section(
      document,
      '  var TAP_ZONE_PAGING',
      '  function _end(x, y){',
    );
    return '''
const assert=require('node:assert/strict');
var ZOOM_MIN=0.5, ZOOM_MAX=5, PAN_X=0, PAN_Y=0, IS_WEBTOON=false;
var SPLIT_WIDE=false, ROTATE_WIDE=false, AUTO_ZOOM_WIDE=false, SPLIT_ACTIVE=false;
var CURRENT=0, PAGE_W=1000, PAGE_H=1414;
const window={innerWidth:412,innerHeight:860};
const page={offsetWidth:412,getAttribute:(k)=>k==='data-pw'?String(PAGE_W):String(PAGE_H)};
const document={
  addEventListener(){}, getElementById(){ return null; },
  createElement(){ return {style:{},appendChild(){}}; },
  body:{appendChild(){}}, querySelector(){ return page; },
};
let timers=[];
function setTimeout(f){ timers.push(f); return timers.length; }
function clearTimeout(id){ if(id>0) timers[id-1]=null; }
function flush(){ const t=timers; timers=[]; t.forEach(f=>f&&f()); }
let calls=[], zoomTo=[];
function _bridge(){ return {callHandler:(n,d)=>{ calls.push(d===undefined?n:n+':'+d); }}; }
function _selectOcrChar(){ return false; }
function _retryFailedPageAt(){ return false; }
function _applyCanvas(){}
function _clampPan(){}
function _applyPageHalf(){}
function _clampZoom(z){ return Math.min(ZOOM_MAX, Math.max(ZOOM_MIN, z)); }
function _doubleTapZoom(x,y){ zoomTo.push(Math.abs(ZOOM-1)>0.01 ? 1 : 2); }
let now=1000;
Date.now=()=>now;
$zoom
$wide
$tap
function tap(x){ now+=1000; _onTap(x, 430); }
function turns(){ return calls.filter(c=>c.startsWith('onMangaTurn')); }
$body
''';
  }

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'manga-zoomed-tap-',
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

  test('未放大：点左右热区照常翻页（RTL 左 = 下一页）', () async {
    await runJs(
      harness(buildDocument(), '''
tap(20);
tap(400);
assert.deepEqual(turns(),['onMangaTurn:next','onMangaTurn:prev']);
'''),
    );
  });

  test('用户放大到 200%：点左右热区不翻页，落到空白点语义', () async {
    await runJs(
      harness(buildDocument(), '''
ZOOM=2;
tap(20);
assert.deepEqual(turns(),[],'放大态点左边不能翻页');
flush();
assert.deepEqual(calls,['onTapEmpty'],'这一击退回空白单击：切悬浮栏');
calls=[];
tap(400);
assert.deepEqual(turns(),[],'右边同样不翻');
'''),
    );
  });

  test('放大态在热区双击：缩回而不是翻页', () async {
    await runJs(
      harness(buildDocument(), '''
ZOOM=2;
now+=1000; _onTap(20,430);
now+=100; _onTap(22,432);
assert.deepEqual(turns(),[]);
assert.deepEqual(zoomTo,[1],'第二击把放大态缩回 100%');
flush();
assert.deepEqual(calls,[],'双击取消了第一击挂起的 onTapEmpty');
'''),
    );
  });

  // 反馈 IDF2uWUvlf：双击窗口按「第一击松手 → 第二击按下」计。第二击按住
  // ~130ms、松手已超出 DBL_MS，也必须缩放，且挂起的 onTapEmpty 不得发出。
  test('第二击按下在窗口内、松手超出窗口：仍判双击缩放，不切悬浮栏', () async {
    await runJs(
      harness(buildDocument(), '''
ZOOM=2;
now+=1000; _onTap(206,430);
now+=250; _armDoubleTapOnDown(208,432);
flush();
assert.deepEqual(calls,[],'第二击按下即取消挂起的 onTapEmpty（手指还按着时不能切栏）');
now+=130; _onTap(208,432);
assert.deepEqual(zoomTo,[1],'松手时按双击缩放');
flush();
assert.deepEqual(calls,[]);
'''),
    );
  });

  test('第二击按下离第一击太远：不算双击，不缩放，退回空白单击', () async {
    await runJs(
      harness(buildDocument(), '''
ZOOM=2;
now+=1000; _onTap(150,430);
now+=150; _armDoubleTapOnDown(260,600);
now+=100; _onTap(260,600);
assert.deepEqual(zoomTo,[]);
flush();
assert.deepEqual(calls,['onTapEmpty']);
'''),
    );
  });

  test('第二击按下晚于窗口（挂起单击已发出）：各算一次单击', () async {
    await runJs(
      harness(buildDocument(), '''
ZOOM=2;
now+=1000; _onTap(206,430);
flush();
assert.deepEqual(calls,['onTapEmpty']);
now+=400; _armDoubleTapOnDown(206,430);
now+=80; _onTap(206,430);
assert.deepEqual(zoomTo,[]);
flush();
assert.deepEqual(calls,['onTapEmpty','onTapEmpty']);
'''),
    );
  });

  test('捏合残留 101%（吸附阈值内的抖动）：仍可点击翻页', () async {
    await runJs(
      harness(buildDocument(), '''
ZOOM=1.005;
tap(20);
assert.deepEqual(turns(),['onMangaTurn:next']);
'''),
    );
  });

  test('设置里默认缩放 150%：静止在默认倍率时点击照常翻页，再放大才不翻', () async {
    await runJs(
      harness(buildDocument(zoomPercent: 150, restZoomPercent: 150), '''
ZOOM=1.5;
tap(20);
assert.deepEqual(turns(),['onMangaTurn:next'],'默认倍率不是用户放大');
ZOOM=2.2;
tap(20);
assert.deepEqual(turns(),['onMangaTurn:next'],'超出默认倍率才是用户放大');
'''),
    );
  });

  test('跨窗口重建：会话倍率 200% 而默认 100%，重建后放大态仍不点翻', () async {
    await runJs(
      harness(buildDocument(zoomPercent: 200, restZoomPercent: 100), '''
assert.equal(ZOOM,2,'重建文档带回会话倍率');
tap(20);
assert.deepEqual(turns(),[],'静止倍率取偏好默认值，不取会话倍率');
'''),
    );
  });

  test('宽页自动放大：自动放大的倍率可点击翻页，翻离宽页倍率复原', () async {
    await runJs(
      harness(buildDocument(), '''
AUTO_ZOOM_WIDE=true;
PAGE_W=2000; PAGE_H=1414;
page.offsetWidth=206;
_applyWidePolicy();
assert.equal(ZOOM,2,'宽页按宽度适配放大到 2×');
tap(20);
assert.deepEqual(turns(),['onMangaTurn:next'],'阅读器自己放大的不算用户放大');
PAGE_W=1000;
_applyWidePolicy();
assert.equal(ZOOM,1,'翻到普通页：自动放大复原到放大前的倍率');
tap(20);
assert.deepEqual(turns(),['onMangaTurn:next','onMangaTurn:next']);
'''),
    );
  });

  test('宽页自动放大后用户又捏了：翻离时不覆盖用户的倍率', () async {
    await runJs(
      harness(buildDocument(), '''
AUTO_ZOOM_WIDE=true;
PAGE_W=2000; PAGE_H=1414;
page.offsetWidth=206;
_applyWidePolicy();
ZOOM=3;
tap(20);
assert.deepEqual(turns(),[],'在自动放大之上再放大 = 用户放大');
PAGE_W=1000;
_applyWidePolicy();
assert.equal(ZOOM,3,'用户改过倍率就保留');
'''),
    );
  });
}
