import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 漫画页触屏长按页图 → `onMangaPageLongPress`（Dart 弹全局图片动作面板）。
///
/// 跑的是生成文档里**真实的**长按状态机与 pointerdown / pointermove /
/// pointerup / pointercancel 监听（从文档里截出来），只把它们依赖的翻页 /
/// 缩放函数换成桩，验证：
/// - 按住 500ms 不动 → 上报被按住那页的 `data-page`，松手不再当单击 / swipe；
/// - 移动超过阈值、第二指落下（捏合）、提前松手、系统夺走指针 → 不触发；
/// - 鼠标右键仍走 `onMangaContextMenu`，鼠标左键按住不触发长按；
/// - 翻页动画克隆层（无 data-page）与加载失败页不触发。
void main() {
  String buildDocument() => mangaWindowDocument(
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
    zoomPercent: 100,
  );

  String section(String document, String start, String end) {
    final int from = document.indexOf(start);
    if (from < 0) throw StateError('生成文档里找不到 $start');
    final int to = document.indexOf(end, from);
    if (to < 0) throw StateError('生成文档里找不到 $end');
    return document.substring(from, to);
  }

  String harness(String body) {
    final String gestures = section(
      buildDocument(),
      '  var LONG_PRESS_MS',
      "  document.addEventListener('contextmenu'",
    );
    return '''
const assert=require('node:assert/strict');
var ZOOM=1, ZOOM_SENS=1, has=false, panDrag=null, touchPts={}, pinch=null;
var pinchGuard=false, rightDrag=null, dblArmed=false;
const listeners={};
// 页面：x < 206 是 data-page=3（双页左），否则 data-page=2；
// y > 800 落在一个摘掉 data-page 的克隆层上；failedAt 让命中页标成加载失败。
let failed=false;
function pageEl(index){ return {
  hasAttribute:(k)=>k==='data-page'&&index!==null,
  getAttribute:(k)=>k==='data-page'?String(index):(k==='data-load-failed'&&failed?'1':null),
}; }
const document={
  addEventListener(type,fn){ listeners[type]=fn; },
  elementsFromPoint(x,y){
    const page=y>800?pageEl(null):pageEl(x<206?3:2);
    return [{closest:(sel)=>sel==='.manga-page'?page:null}];
  },
};
let timers=[];
function setTimeout(f){ timers.push(f); return timers.length; }
function clearTimeout(id){ if(id>0) timers[id-1]=null; }
function elapse(){ const t=timers; timers=[]; t.forEach(f=>f&&f()); }
let calls=[], ends=[], released=[];
function _bridge(){ return {callHandler:(n,d)=>{ calls.push(n+':'+d); }}; }
function _pinchGeom(){
  const ids=Object.keys(touchPts); if(ids.length<2) return null;
  const a=touchPts[ids[0]], b=touchPts[ids[1]];
  return {dist:Math.hypot(a.x-b.x,a.y-b.y), cx:(a.x+b.x)/2, cy:(a.y+b.y)/2};
}
function _swipeRelease(turning){ released.push(turning); }
function _stopFlick(){} function _stopScrollAnim(){}
function _armDoubleTapOnDown(){}
function _start(){ has=true; }
function _end(x,y){ ends.push([x,y]); }
function _cancelPendingEmptyTap(){}
function _snapPinchZoom(){} function _zoomAbout(){}
function _startFlick(){} function _releaseVelocity(){ return 0; }
$gestures
function ev(type,o){ listeners[type](Object.assign({
  pointerType:'touch', pointerId:1, isPrimary:true, button:0,
  clientX:100, clientY:400, timeStamp:0, preventDefault(){},
}, o||{})); }
function longPresses(){ return calls.filter(c=>c.startsWith('onMangaPageLongPress')); }
$body
''';
  }

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'manga-long-press-',
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

  test('按住不动：上报被按住那页的 data-page，松手不再当单击', () async {
    await runJs(
      harness('''
ev('pointerdown',{clientX:100});
elapse();
assert.deepEqual(longPresses(),['onMangaPageLongPress:{"page":3}']);
assert.equal(has,false,'触发后本次按压的 swipe 作废');
assert.deepEqual(released,[false],'跟手位移回弹');
ev('pointerup',{clientX:100});
assert.deepEqual(ends,[],'松手不走单击 / swipe');
assert.deepEqual(touchPts,{},'触点表照常清掉');
calls=[];
ev('pointerdown',{clientX:300});
elapse();
assert.deepEqual(longPresses(),['onMangaPageLongPress:{"page":2}'],
  '双页模式取命中的那页，不是当前跨页');
'''),
    );
  });

  test('短按：不触发长按，照常走单击路径', () async {
    await runJs(
      harness('''
ev('pointerdown');
ev('pointerup');
elapse();
assert.deepEqual(longPresses(),[]);
assert.equal(ends.length,1);
'''),
    );
  });

  test('移动超过阈值（滑动 / 滚动）：取消长按', () async {
    await runJs(
      harness('''
ev('pointerdown',{clientX:100,clientY:400});
ev('pointermove',{clientX:105,clientY:404});
ev('pointermove',{clientX:100,clientY:420});
elapse();
assert.deepEqual(longPresses(),[]);
ev('pointerup',{clientX:100,clientY:420});
assert.equal(ends.length,1,'松手照常交给 swipe / tap 判定');
'''),
    );
  });

  test('小幅抖动（阈值内）：仍算长按', () async {
    await runJs(
      harness('''
ev('pointerdown',{clientX:100,clientY:400});
ev('pointermove',{clientX:106,clientY:405});
elapse();
assert.equal(longPresses().length,1);
'''),
    );
  });

  test('第二指落下（捏合）：取消长按', () async {
    await runJs(
      harness('''
ev('pointerdown',{pointerId:1,clientX:100,clientY:400});
ev('pointerdown',{pointerId:2,isPrimary:false,clientX:300,clientY:500});
elapse();
assert.deepEqual(longPresses(),[]);
'''),
    );
  });

  test('系统夺走指针：取消长按', () async {
    await runJs(
      harness('''
ev('pointerdown');
ev('pointercancel');
elapse();
assert.deepEqual(longPresses(),[]);
'''),
    );
  });

  test('鼠标：左键按住不触发，右键照旧弹右键菜单', () async {
    await runJs(
      harness('''
ev('pointerdown',{pointerType:'mouse'});
elapse();
assert.deepEqual(longPresses(),[]);
ev('pointerup',{pointerType:'mouse'});
ev('pointerdown',{pointerType:'mouse',button:2,clientX:50,clientY:60});
ev('pointerup',{pointerType:'mouse',button:2,clientX:50,clientY:60});
assert.deepEqual(calls,['onMangaContextMenu:{"x":50,"y":60}']);
'''),
    );
  });

  test('克隆层（无 data-page）与加载失败页：不触发', () async {
    await runJs(
      harness('''
ev('pointerdown',{clientY:900});
elapse();
ev('pointerup',{clientY:900});
failed=true;
ev('pointerdown');
elapse();
assert.deepEqual(longPresses(),[]);
'''),
    );
  });
}
