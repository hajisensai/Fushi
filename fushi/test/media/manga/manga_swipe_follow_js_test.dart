import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// BUG-3219：漫画横滑翻页「不跟手」。此前 spread 模式的横滑是「松手才翻页」：
/// 拖动全程 `#manga-root` 的 translateX 一像素不动（拖 N px 的跟随误差恒为 N），
/// 松手后才从静止状态播翻页动画。
///
/// 跑的是生成文档里**真实的** `_translateToSpread` / `_clampPan` / `_panBy` /
/// `_start` / `_swipeMove` / `_swipeRelease` / `_end`，不是复刻；pointermove 按生产
/// 监听器的顺序（先 `_panBy` 再 `_swipeMove`）逐步喂。每一步断言「页面位移 ==
/// 手指位移」——这就是跟手误差的度量，期望恒为 0。
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
    '  window.__mangaApplyTranslate = function(target){',
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
  /// (4-i)×412。当前停在跨页 2（落位 translateX = -824）。
  String harness(String body) =>
      '''
const assert=require('node:assert/strict');
let ZOOM=1, PAN_X=0, PAN_Y=0, PAN_WIDE=true, IS_WEBTOON=false, IS_RTL=true;
let SPLIT_ACTIVE=false, CURRENT=2;
const window={innerWidth:412,innerHeight:860};
const root={style:{transform:'',transition:''},
  querySelector(sel){
    const m=/data-spread="(-?\\d+)"/.exec(sel);
    const i=Number(m[1]);
    return (i>=0&&i<5)?{offsetLeft:(4-i)*412}:null;
  }};
const document={
  getElementById(id){ return id==='manga-root'?root:null; },
  querySelectorAll(){ return []; },
};
function _applyWidePolicy(){}
function _hintWillChange(){}
const PAGE_ANIM_MS=220;
function _updateAutomaticBackground(){}
function _applyCanvas(){}
function _currentPageIsWide(){ return false; }
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
function tx(){ return Number(/translateX\\((-?[\\d.]+)px\\)/.exec(root.style.transform)[1]); }
_translateToSpread(CURRENT);
const BASE=tx();
assert.equal(BASE,-824);
function centerAt(zoom){ ZOOM=zoom; PAN_X=window.innerWidth*(1-ZOOM)/2; PAN_Y=window.innerHeight*(1-ZOOM)/2; }
// 生产 pointermove：先 _panBy（放大态平移），再 _swipeMove（跟手）。
let lastX=0, lastY=0;
function down(x,y){ lastX=x; lastY=y; _start(x,y); }
function move(x,y,dt){ now+=dt||16; _panBy(x-lastX,y-lastY); lastX=x; lastY=y; _swipeMove(x,y); }
function up(x,y){ return _end(x,y); }
const errors=[];
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

  test('越过阈值松手：交给 Dart 翻页；Dart 换了页就由翻页动画接管、不回弹', () async {
    await runJs(
      harness('''
centerAt(1);
let settled=null;
dart=(d)=>{ return new Promise(r=>{ settled=r; }); };
down(200,600);
for(let i=1;i<=10;i++) move(200+i*15,600);
up(350,600);
assert.deepEqual(turns,['next'],'RTL 右滑 = 下一页');
assert.equal(root.style.transition,'','松手前还原过渡，翻页动画从手指停下的位置接着走');
assert.equal(tx(),BASE+150,'Dart 还没答复：页面停在手指松开的位置');
// Dart 推进到跨页 3（等价 __mangaApplyTranslate），处理完才答复。
TURN_SERIAL++; _translateToSpread(3);
settled();
setTimeout(()=>{
  assert.equal(CURRENT,3);
  assert.equal(tx(),-412,'翻页落位不被回弹覆盖');
},0);
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
setTimeout(()=>{ assert.equal(tx(),BASE,'没换页就回弹'); },0);
'''),
    );
  });

  test('没过阈值：不翻页、立即回弹', () async {
    await runJs(
      harness('''
centerAt(1);
down(200,600);
for(let i=1;i<=10;i++) move(200+i*4,600,40);
assert.equal(tx(),BASE+40);
up(240,600);
assert.deepEqual(turns,[]);
assert.equal(root.style.transition,'');
assert.equal(tx(),BASE);
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
}
