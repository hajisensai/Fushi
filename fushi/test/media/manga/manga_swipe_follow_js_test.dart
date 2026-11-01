import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// BUG-3219：漫画横滑翻页「不跟手」。此前 spread 模式的横滑是「松手才翻页」：
/// 拖动全程 `#manga-root` 的 translateX 一像素不动（拖 N px 的跟随误差恒为 N），
/// 松手后才从静止状态播翻页动画。
///
/// 翻页动画升级（四选一 + 速度 + 跟手开关）后，这里同时咬住：
/// - 跟手提交阈值：拖过 0.25 个视口宽，或往翻页方向甩动 > 0.6 px/ms 才翻，否则回弹；
/// - 首 / 末页（没有相邻跨页）0.3× 阻尼、松手仍交给 Dart（跨章）并回弹；
/// - 松手后 Dart 换页：从手指停下的位置接着动画，剩余时长按剩余距离缩短；
/// - 连按：上一段动画直接落到终点再开始下一次；长距离跳页瞬时；
/// - 「覆盖」效果：克隆层随手 / 自己动，strip 瞬时定位；
/// - 第二指落下（捏合）立即复位。
///
/// 跑的是生成文档里**真实的** `_translateToSpread` … `__mangaApplyTranslate` /
/// `_clampPan` / `_panBy` / `_start` / `_swipeMove` / `_swipeRelease` / `_end`，不是
/// 复刻；pointermove 按生产监听器的顺序（先 `_panBy` 再 `_swipeMove`）逐步喂。
void main() {
  final String document = mangaWindowDocument(
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
  );

  String section(String start, String end) {
    final int from = document.indexOf(start);
    if (from < 0) throw StateError('生成文档里找不到 $start');
    final int to = document.indexOf(end, from);
    if (to < 0) throw StateError('生成文档里找不到 $end');
    return document.substring(from, to);
  }

  final String translate = section(
    '  function _translateToSpread(target){',
    '  // 运行中换翻页动画设置',
  );
  final String pan = section('  function _clampPan(){', '  // 方向键平移');
  final String start = section(
    '  var sx = 0, sy = 0, st = 0, spx = 0, has = false;',
    '  // ── 触屏双指捏合缩放 ──',
  );
  final String end = section(
    '  function _end(x, y){',
    "  document.addEventListener('pointerdown', function(e){",
  );

  /// 视口 412×860、RTL、5 个跨页：RTL 倒序排布，跨页 i 的 offsetLeft =
  /// (4-i)×412。当前停在跨页 2（落位 translateX = -824）。动画时长 220ms。
  String harness(String body) =>
      '''
const assert=require('node:assert/strict');
let ZOOM=1, PAN_X=0, PAN_Y=0, PAN_WIDE=true, IS_WEBTOON=false, IS_RTL=true;
let SPLIT_ACTIVE=false, CURRENT=2, PAGE_HALF=0;
let PAGE_ANIM='slide', PAGE_ANIM_MS=220, FOLLOW_DRAG=true;
const MAX_ANIM_DIST=1, FOLLOW_COMMIT=0.25, FOLLOW_FLING=0.6;
const FOLLOW_EDGE_DAMPING=0.3, PAGE_EASE='ease';
const window={innerWidth:412,innerHeight:860};
function mkEl(props){
  const el={style:{transform:'',transition:'',opacity:''}, attrs:{}, children:[],
    parentNode:null, offsetHeight:860, offsetWidth:412,
    removeAttribute(k){ delete this.attrs[k]; },
    querySelectorAll(){ return []; },
    appendChild(c){ c.parentNode=this; this.children.push(c); return c; },
    removeChild(c){ this.children=this.children.filter(x=>x!==c); c.parentNode=null; },
    cloneNode(){ return mkEl({cloneOf:this.spread}); }};
  return Object.assign(el, props||{});
}
const spreads=[0,1,2,3,4].map(i=>mkEl({spread:i, offsetLeft:(4-i)*412}));
const root=mkEl({querySelector(sel){
  const m=/data-spread="(-?\\d+)"/.exec(sel);
  return spreads[Number(m[1])]||null;
}});
const vp=mkEl();
const document={
  body:{},
  getElementById(id){ return id==='manga-root'?root:(id==='manga-viewport'?vp:null); },
  querySelectorAll(){ return []; },
  createElement(){ return mkEl(); },
};
function _applyWidePolicy(){}
function _hintWillChange(){}
function _updateAutomaticBackground(){}
function _applyCanvas(){}
function _currentPageIsWide(){ return false; }
function _flashPageChange(){}
function _retryFailedPagesWhere(){}
let zoomResets=0;
function _resetZoomForNewPage(){ zoomResets++; }
let turns=[], taps=0, dart=null;
function _bridge(){ return {callHandler:(n,d)=>{
  if(n!=='onMangaTurn') return undefined;
  turns.push(d);
  return dart ? dart(d) : undefined;
}}; }
function _onTap(){ taps++; }
let now=1000;
Date.now=()=>now;
$translate
$pan
$start
$end
function pxOf(el){ return Number(/translateX\\((-?[\\d.]+)px\\)/.exec(el.style.transform)[1]); }
function tx(){ return pxOf(root); }
function msOf(el){ const m=/^transform (\\d+)ms/.exec(el.style.transition); assert.ok(m,'没有过渡：'+el.style.transition); return Number(m[1]); }
_translateToSpread(CURRENT);
const BASE=tx();
assert.equal(BASE,-824);
function centerAt(zoom){ ZOOM=zoom; PAN_X=window.innerWidth*(1-ZOOM)/2; PAN_Y=window.innerHeight*(1-ZOOM)/2; }
// 生产 pointermove：先 _panBy（放大态平移），再 _swipeMove（跟手）。
let lastX=0, lastY=0;
function down(x,y){ lastX=x; lastY=y; _start(x,y); }
function move(x,y,dt){ now+=dt||16; _panBy(x-lastX,y-lastY); lastX=x; lastY=y; _swipeMove(x,y); }
function up(x,y){ return _end(x,y); }
function later(ms, fn){ setTimeout(fn, ms); }
$body
''';

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'manga-swipe-follow-',
    );
    try {
      final File script = File('${dir.path}/verify.js')
        ..writeAsStringSync(code);
      final ProcessResult result = await Process.run('node', <String>[
        script.path,
      ], runInShell: Platform.isWindows);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      // ignore: avoid_print
      if ('${result.stdout}'.trim().isNotEmpty) print(result.stdout);
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  test('拖动 N px，页面位移恰好 N px（逐步测量跟随误差 = 0）', () async {
    await runJs(
      harness('''
centerAt(1);
down(200,600);
let maxErr=0;
for(let i=1;i<=20;i++){
  const x=200+i*12;
  move(x,600+(i%2));
  const err=Math.abs((tx()-BASE)-(x-200));
  maxErr=Math.max(maxErr,err);
}
assert.equal(root.style.transition,'none','拖动中不许挂过渡（否则每帧追 ease-out，慢半拍）');
console.log('follow: dragged 240px in 20 moves, max |page dx - finger dx| = '+maxErr+'px');
assert.equal(maxErr,0);
// 反向拖回来同样逐像素跟随。
for(let i=1;i<=10;i++){ const x=440-i*30; move(x,600); assert.equal(tx()-BASE,x-200); }
'''),
    );
  });

  test('越过阈值松手：Dart 换了页就从松手位置接着动画，剩余时长按比例缩短', () async {
    await runJs(
      harness('''
centerAt(1);
let settled=null;
dart=(d)=>{ return new Promise(r=>{ settled=r; }); };
down(200,600);
for(let i=1;i<=10;i++) move(200+i*15,600);
up(350,600);
assert.deepEqual(turns,['next'],'RTL 右滑 = 下一页');
assert.equal(root.style.transition,'none','等 Dart 答复期间停在手指松开的位置');
assert.equal(tx(),BASE+150);
// Dart 推进到跨页 3，处理完才答复。
window.__mangaApplyTranslate(3);
settled();
assert.equal(CURRENT,3);
assert.equal(tx(),-412);
assert.equal(msOf(root),Math.round(220*262/412),'剩余 262px / 412px 的时长');
later(300,()=>{
  assert.equal(tx(),-412,'翻页落位不被回弹覆盖');
  assert.equal(root.style.transition,'','动画结束还原过渡');
});
'''),
    );
  });

  test('越过阈值松手但 Dart 没换页（到头 / 换章中）：答复后回弹到当前跨页', () async {
    await runJs(
      harness('''
centerAt(1);
dart=()=>Promise.resolve();
down(200,600);
for(let i=1;i<=10;i++) move(200+i*15,600);
up(350,600);
assert.deepEqual(turns,['next']);
later(0,()=>{
  assert.equal(tx(),BASE,'没换页就回弹');
  assert.ok(msOf(root)>0,'回弹是动画，不是瞬移');
});
later(300,()=>{ assert.equal(root.style.transition,''); });
'''),
    );
  });

  test('没过阈值（慢拖 < 1/4 视口宽）：不翻页、回弹', () async {
    await runJs(
      harness('''
centerAt(1);
down(200,600);
for(let i=1;i<=9;i++) move(200+i*10,600,100);
assert.equal(tx(),BASE+90);
up(290,600);
assert.deepEqual(turns,[],'90px < 0.25×412，速度 0.1px/ms：回弹');
assert.equal(tx(),BASE);
later(300,()=>{ assert.equal(root.style.transition,''); });
'''),
    );
  });

  test('慢拖过 1/4 视口宽：提交翻页', () async {
    await runJs(
      harness('''
centerAt(1);
down(200,600);
for(let i=1;i<=12;i++) move(200+i*10,600,100);
up(320,600);
assert.deepEqual(turns,['next'],'120px > 103px');
'''),
    );
  });

  test('短距离快甩（> 0.6 px/ms）：提交翻页', () async {
    await runJs(
      harness('''
centerAt(1);
down(200,600);
for(let i=1;i<=4;i++) move(200-i*10,600,10);
up(160,600);
assert.deepEqual(turns,['prev'],'40px、1px/ms：RTL 左甩 = 上一页');
'''),
    );
  });

  test('拖过阈值再快速往回甩 = 取消，回弹', () async {
    await runJs(
      harness('''
centerAt(1);
down(200,600);
for(let i=1;i<=10;i++) move(200+i*15,600);
move(320,600,10);
up(320,600);
assert.deepEqual(turns,[],'松手瞬时速度反向 3000px/s：取消');
assert.equal(tx(),BASE);
'''),
    );
  });

  test('纵向手势不横向跟随', () async {
    await runJs(
      harness('''
centerAt(1);
down(200,600);
for(let i=1;i<=10;i++) move(200+i,600+i*20);
assert.equal(tx(),BASE,'纵向锁定后 translateX 不动');
up(210,800);
assert.deepEqual(turns,[]);
'''),
    );
  });

  test('放大态：平移先吃位移，只有贴边后的余量跟手', () async {
    await runJs(
      harness('''
centerAt(2);
PAN_X=-40;
down(200,600);
for(let i=1;i<=12;i++) move(200+i*10,600);
assert.equal(PAN_X,0,'先贴边');
assert.equal(tx()-BASE,80,'120px 手指位移里 40px 给了平移，余 80px 跟手');
up(320,600);
assert.deepEqual(turns,['next']);
'''),
    );
  });

  test('宽页切半态不跟手（翻的是同一跨页的另一半）', () async {
    await runJs(
      harness('''
centerAt(1);
SPLIT_ACTIVE=true;
down(200,600);
for(let i=1;i<=10;i++) move(200+i*15,600);
assert.equal(tx(),BASE);
up(350,600);
assert.deepEqual(turns,['next'],'松手判定照旧');
'''),
    );
  });

  test('跟手开关关：拖动中页面不动，松手沿用固定阈值', () async {
    await runJs(
      harness('''
centerAt(1);
FOLLOW_DRAG=false;
down(200,600);
for(let i=1;i<=10;i++) move(200+i*8,600,40);
assert.equal(tx(),BASE,'不跟手');
up(280,600);
assert.deepEqual(turns,['next'],'80px ≥ 72px 旧阈值');
'''),
    );
  });

  // BUG-3624：跟手与翻页效果无关（对齐 Mihon）。无动画 = 墨水屏 / 系统「减弱动态
  // 效果」/ 旧版关过「页面切换动画」的用户，此前拖动全程页面不动。
  test('无动画也逐像素跟手；提交后瞬时落位，没过阈值瞬时回位', () async {
    await runJs(
      harness('''
centerAt(1);
PAGE_ANIM='none';
down(200,600);
for(let i=1;i<=10;i++){ move(200+i*15,600); assert.equal(tx()-BASE,i*15,'第 '+i+' 步跟手'); }
up(350,600);
assert.deepEqual(turns,['next']);
window.__mangaApplyTranslate(3);
assert.equal(tx(),-412,'无动画：从手指位置瞬时落到目标');
assert.equal(root.style.transition,'');
turns=[];
down(200,600);
for(let i=1;i<=9;i++) move(200+i*10,600,100);
assert.equal(tx(),-412+90,'慢拖照样跟手');
up(290,600);
assert.deepEqual(turns,[]);
assert.equal(tx(),-412,'没过阈值：瞬时回位');
'''),
    );
  });

  test('淡入淡出也跟手；被拖过的翻页按平移收尾，不再叠一段淡出', () async {
    await runJs(
      harness('''
centerAt(1);
PAGE_ANIM='fade';
let settled=null;
dart=()=>new Promise(r=>{ settled=r; });
down(200,600);
for(let i=1;i<=10;i++) move(200+i*15,600);
assert.equal(tx(),BASE+150,'跟手');
up(350,600);
window.__mangaApplyTranslate(3);
settled();
assert.equal(tx(),-412);
assert.equal(msOf(root),Math.round(220*262/412),'从松手位置平移收尾');
assert.notEqual(root.style.opacity,'0','没有淡出');
'''),
    );
  });

  test('末页朝外拖：0.3× 阻尼，松手仍交给 Dart（跨章），没换页就回弹', () async {
    await runJs(
      harness('''
centerAt(1);
_translateToSpread(4);
const LAST=tx();
assert.equal(LAST,0);
dart=()=>Promise.resolve();
down(200,600);
for(let i=1;i<=10;i++) move(200+i*15,600);
assert.equal(tx(),LAST+45,'RTL 右拖 = 下一跨页，不存在：150px × 0.3');
up(350,600);
assert.deepEqual(turns,['next'],'交给 Dart 判断要不要换章');
later(0,()=>{ assert.equal(tx(),LAST,'回弹'); });
'''),
    );
  });

  test('连按：上一段动画立即落到终点再开始下一次；长距离跳页瞬时', () async {
    await runJs(
      harness('''
window.__mangaApplyTranslate(3);
assert.equal(msOf(root),220);
assert.equal(tx(),-412);
window.__mangaApplyTranslate(4);
assert.equal(CURRENT,4);
assert.equal(msOf(root),220,'第二次从上一段终点起播完整一段，不排队');
assert.equal(tx(),0);
window.__mangaApplyTranslate(0);
assert.equal(root.style.transition,'','跳 4 个跨页：瞬时');
assert.equal(tx(),-1648);
assert.equal(_pageAnim,null,'没有在播的动画');
'''),
    );
  });

  test('第二指落下（捏合）：跟到一半的页面立即复位，不播回弹', () async {
    await runJs(
      harness('''
centerAt(1);
down(200,600);
for(let i=1;i<=6;i++) move(200+i*15,600);
assert.equal(tx(),BASE+90);
_swipeRelease(false, true);
assert.equal(tx(),BASE);
assert.equal(root.style.transition,'');
'''),
    );
  });

  test('覆盖：前进拖动是当前页的克隆层跟手，strip 底下已是目标页；提交后克隆层移走', () async {
    await runJs(
      harness('''
centerAt(1);
PAGE_ANIM='cover';
let settled=null;
dart=()=>new Promise(r=>{ settled=r; });
down(200,600);
for(let i=1;i<=10;i++) move(200+i*15,600);
assert.equal(vp.children.length,1,'一个覆盖层');
const layer=vp.children[0];
assert.equal(layer.children[0].cloneOf,2,'前进：克隆的是当前页');
assert.equal(pxOf(layer),150,'覆盖层随手');
assert.equal(tx(),-412,'strip 底下已是目标页 3');
up(350,600);
assert.deepEqual(turns,['next']);
window.__mangaApplyTranslate(3);
settled();
assert.equal(pxOf(layer),412,'当前页整屏移走');
assert.equal(msOf(layer),Math.round(220*262/412));
later(300,()=>{
  assert.equal(vp.children.length,0,'动画结束移除覆盖层');
  assert.equal(CURRENT,3);
  assert.equal(tx(),-412);
});
'''),
    );
  });

  test('覆盖：后退拖动是目标页盖回来；没过阈值就退回去并移除', () async {
    await runJs(
      harness('''
centerAt(1);
PAGE_ANIM='cover';
down(200,600);
for(let i=1;i<=6;i++) move(200-i*10,600,100);
const layer=vp.children[0];
assert.equal(layer.children[0].cloneOf,1,'后退：克隆的是上一跨页');
assert.equal(pxOf(layer),412-60,'从右侧屏外盖进来 60px');
assert.equal(tx(),BASE,'strip 留在当前页');
up(140,600);
assert.deepEqual(turns,[]);
assert.equal(pxOf(layer),412,'退回屏外');
later(300,()=>{
  assert.equal(vp.children.length,0);
  assert.equal(tx(),BASE);
});
'''),
    );
  });

  test('覆盖：拖动中换方向就按新方向重建克隆层', () async {
    await runJs(
      harness('''
centerAt(1);
PAGE_ANIM='cover';
down(200,600);
move(260,600);
assert.equal(vp.children[0].children[0].cloneOf,2);
move(140,600);
assert.equal(vp.children.length,1,'旧层拆掉');
assert.equal(vp.children[0].children[0].cloneOf,1);
assert.equal(tx(),BASE);
'''),
    );
  });

  test('覆盖：按键 / 点击后退，目标页从屏外盖回，结束后 strip 才落到目标', () async {
    await runJs(
      harness('''
PAGE_ANIM='cover';
window.__mangaApplyTranslate(1);
assert.equal(CURRENT,1);
const layer=vp.children[0];
assert.equal(layer.children[0].cloneOf,1);
assert.equal(pxOf(layer),0,'盖到位');
assert.equal(msOf(layer),220);
assert.equal(tx(),BASE,'动画期间 strip 仍是旧页');
later(300,()=>{
  assert.equal(vp.children.length,0);
  assert.equal(tx(),-1236);
});
'''),
    );
  });

  // 反馈 8HxGrnNy3x：换到另一跨页复位缩放；原地重放（窗口就绪 / resize 重投影
  // 调到同一跨页）不能把用户正在看的放大清掉。
  test('换页才复位缩放：翻到别的跨页复位一次，原地重放不复位', () async {
    await runJs(
      harness('''
PAGE_ANIM='none';
window.__mangaApplyTranslate(2);
assert.equal(zoomResets,0,'同一跨页重放不复位');
window.__mangaApplyTranslate(3);
assert.equal(zoomResets,1,'翻页复位');
window.__mangaApplyTranslate(1);
assert.equal(zoomResets,2,'跳页同样复位');
'''),
    );
  });
}
