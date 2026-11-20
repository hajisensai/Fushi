import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 气泡原位放大（方案 A）：跑生成文档里**真实的**脚本片段（阅读顺序 / 浮层几何 /
/// 手势状态机 / `_onTap` / barrier 入口 / 悬停查词判据），DOM 量测函数用桩替换。
void main() {
  const MokuroImage page = MokuroImage(
    url: 'page.png',
    size: MokuroSize(1000, 1414),
    blocks: <MokuroBlock>[],
  );

  String buildDocument({
    MangaReaderPreferences preferences = const MangaReaderPreferences(),
    MangaReadingMode mode = MangaReadingMode.spread,
    String direction = 'rtl',
  }) => mangaWindowDocument(
    const <MokuroImage>[page],
    const <String>['page.png'],
    mode: mode,
    spreadDirection: direction,
    inlineSelectionJs: '',
    readerPreferences: preferences,
    bubbleZoomOpenMs: 0,
    bubbleZoomCloseMs: 0,
  );

  String section(String document, String start, String end) {
    final int from = document.indexOf(start);
    if (from < 0) throw StateError('生成文档里找不到 $start');
    final int to = document.indexOf(end, from);
    if (to < 0) throw StateError('生成文档里找不到 $end');
    return document.substring(from, to);
  }

  String gestureScript(String document) {
    final int open = document.lastIndexOf('<script>');
    final int close = document.lastIndexOf('</script>');
    return document.substring(open + '<script>'.length, close);
  }

  Future<void> runJs(String code) async {
    final Directory dir = Directory.systemTemp.createTempSync('manga-bz-');
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

  group('生成的脚本', () {
    test('各模式 / 开关组合下整段手势脚本都能解析', () async {
      final List<String> scripts = <String>[
        for (final MangaReadingMode mode in MangaReadingMode.values)
          for (final bool on in <bool>[true, false])
            gestureScript(
              buildDocument(
                mode: mode,
                preferences: MangaReaderPreferences(
                  bubbleZoom: on,
                  einkMode: !on,
                ),
              ),
            ),
      ];
      final StringBuffer js = StringBuffer();
      for (int i = 0; i < scripts.length; i++) {
        js.writeln('new Function(${jsonEncode(scripts[i])});');
      }
      await runJs(js.toString());
    });

    test('偏好注入：开关、触发方式、时长、倍率；墨水屏动效归零', () {
      final String doc = mangaWindowDocument(
        const <MokuroImage>[page],
        const <String>['page.png'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'ltr',
        inlineSelectionJs: '',
        readerPreferences: const MangaReaderPreferences(
          bubbleZoomHover: 'ctrl',
          bubbleZoomDelay: 500,
          bubbleZoomScale: 280,
          einkMode: true,
        ),
        bubbleZoomOpenMs: 325,
        bubbleZoomCloseMs: 165,
      );
      expect(doc, contains('var BZ_ENABLED = true;'));
      expect(doc, contains("var BZ_HOVER = 'ctrl';"));
      expect(doc, contains('var BZ_DELAY = 500;'));
      expect(doc, contains('var BZ_SCALE = 2.8;'));
      expect(doc, contains('var BZ_RTL = false;'));
      expect(doc, contains('var BZ_OPEN_MS = 0, BZ_CLOSE_MS = 0;'));
      expect(doc, contains('.manga-zoom-page{overflow:hidden;}'));
    });

    test('动效时长原样来自调用方（Dart 的 FushiMotion）', () {
      final String doc = mangaWindowDocument(
        const <MokuroImage>[page],
        const <String>['page.png'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        readerPreferences: const MangaReaderPreferences(),
        bubbleZoomOpenMs: 325,
        bubbleZoomCloseMs: 165,
      );
      expect(doc, contains('var BZ_OPEN_MS = 325, BZ_CLOSE_MS = 165;'));
    });
  });

  group('纯几何', () {
    String geometryHarness(String body) {
      final String doc = buildDocument();
      final String pure = section(
        doc,
        '  // ── 气泡放大：纯几何 ──',
        '  // ── 气泡放大：DOM ──',
      );
      return '''
const assert=require('node:assert/strict');
$pure
function box(key,l,t,r,b){ return {key:key,l:l,t:t,r:r,b:b}; }
function keys(list){ return list.map(function(x){ return x.key; }); }
$body
''';
    }

    test('同一行内 RTL 从右到左、行与行从上到下；LTR 反过来', () async {
      await runJs(
        geometryHarness('''
var items=[
  box('topLeft',10,10,60,120), box('topRight',300,20,350,110),
  box('midRight',280,200,330,300), box('midLeft',20,210,70,290),
  box('bottom',150,400,250,450),
];
assert.deepEqual(keys(_bzOrderRows(items,true)),['topRight','topLeft','midRight','midLeft','bottom']);
assert.deepEqual(keys(_bzOrderRows(items,false)),['topLeft','topRight','midLeft','midRight','bottom']);
'''),
      );
    });

    test('纵向重叠不足较矮者 40% 的两块分属两行', () async {
      await runJs(
        geometryHarness('''
var items=[box('a',300,0,350,100), box('b',10,80,60,180)];
// 重叠 20px < 40% × 100：b 在下一行，即使它更靠左（RTL 里本该排后）也排在 a 之后。
assert.deepEqual(keys(_bzOrderRows(items,true)),['a','b']);
var together=[box('a',10,0,60,100), box('b',300,50,350,150)];
// 重叠 50px ≥ 40px：同一行，RTL 先右边的 b。
assert.deepEqual(keys(_bzOrderRows(together,true)),['b','a']);
'''),
      );
    });

    test('双页连成一个序列：RTL 先右页、LTR 先左页；条漫从上到下', () async {
      await runJs(
        geometryHarness('''
var left={l:0,t:0,bubbles:[box('L1',10,10,50,50)]};
var right={l:500,t:0,bubbles:[box('R1',510,10,550,50),box('R2',600,10,640,50)]};
assert.deepEqual(keys(_bzSequence([left,right],true,false)),['R2','R1','L1']);
assert.deepEqual(keys(_bzSequence([left,right],false,false)),['L1','R1','R2']);
var p2={l:0,t:900,bubbles:[box('B',10,910,50,950)]};
var p1={l:0,t:-100,bubbles:[box('A',10,-90,50,-50)]};
assert.deepEqual(keys(_bzSequence([p2,p1],false,true)),['A','B']);
'''),
      );
    });

    test('浮层以气泡中心为锚放大、夹进视口、放不下就降倍率（不低于 1）', () async {
      await runJs(
        geometryHarness('''
// 视口中部的小气泡：100×50，边距 max(6, 50×0.18=9)=9 → 118×68 × 2.4。
var g=_bzLayerGeom({l:150,t:400,r:250,b:450},412,860,2.4);
assert.equal(g.s,2.4);
assert.ok(Math.abs(g.w-118*2.4)<1e-9 && Math.abs(g.h-68*2.4)<1e-9);
assert.ok(Math.abs((g.l+g.w/2)-200)<1e-9 && Math.abs((g.t+g.h/2)-425)<1e-9);
// 贴右上角：浮层整体夹进视口（留 8px），倍率不变。
var c=_bzLayerGeom({l:360,t:10,r:400,b:60},412,860,2.4);
assert.equal(c.s,2.4);
assert.ok(Math.abs(c.l+c.w-(412-8))<1e-9);
assert.equal(c.t,8);
assert.equal(c.cx,380); assert.equal(c.cy,35);
// 高竖排气泡放大后比视口高：倍率降到刚好放下。
var tall=_bzLayerGeom({l:100,t:100,r:140,b:600},412,860,2.4);
assert.ok(tall.s<2.4 && tall.s>=1);
assert.ok(Math.abs(tall.h-(860-16))<1e-6);
// 比视口还大的气泡：倍率不低于 1。
var huge=_bzLayerGeom({l:0,t:0,r:900,b:900},412,860,2.4);
assert.equal(huge.s,1);
'''),
      );
    });
  });

  group('手势', () {
    /// 桩：一个气泡 key 'p0:3'，范围 x∈[100,200] y∈[100,300]；里面 x<150 是字。
    /// 打开的浮层占 [40,40]-[360,560]。`now` 推进时钟，`advance(ms)` 跑到期定时器。
    String harness(
      String body, {
      MangaReaderPreferences preferences = const MangaReaderPreferences(),
      MangaReadingMode mode = MangaReadingMode.spread,
    }) {
      final String doc = buildDocument(preferences: preferences, mode: mode);
      final String tap = section(
        doc,
        '  var TAP_ZONE_PAGING',
        '  function _end(x, y){',
      );
      final String barrier = section(
        doc,
        '  window.__mangaBarrierTapAt = function',
        '  // Desktop Shift-hover lookup',
      );
      final String hover = section(
        doc,
        '  var shiftHoverX = -1',
        '  // 点击热区翻页。',
      );
      final String module = section(
        doc,
        '  // ── 气泡放大：配置 ──',
        '  window.__mangaBubbleZoomClose',
      );
      final bool webtoon = mode != MangaReadingMode.spread;
      return '''
const assert=require('node:assert/strict');
var ZOOM=1, ZOOM_REST=1, PAN_X=0, PAN_Y=0, IS_WEBTOON=$webtoon, CURRENT=0, has=false;
var listeners={};
const window={innerWidth:412,innerHeight:860,
  addEventListener(t,f){ (listeners['w:'+t]=listeners['w:'+t]||[]).push(f); }};
const document={
  addEventListener(t,f){ (listeners['d:'+t]=listeners['d:'+t]||[]).push(f); },
  documentElement:{addEventListener(t,f){ (listeners['e:'+t]=listeners['e:'+t]||[]).push(f); }},
  getElementById(){ return null; }, createElement(){ return {style:{},appendChild(){}}; },
  body:{appendChild(){}}, querySelector(){ return null; }, querySelectorAll(){ return []; },
};
function fire(key,e){ (listeners[key]||[]).forEach(function(f){ f(e); }); }
let now=1000;
Date.now=()=>now;
let timers=[];
function setTimeout(f,ms){ timers.push({f:f,due:now+(ms||0)}); return timers.length; }
function clearTimeout(id){ if(id>0&&timers[id-1]) timers[id-1].f=null; }
function advance(ms){
  var end=now+ms;
  for(;;){
    var next=null;
    timers.forEach(function(t){ if(t.f&&t.due<=end&&(!next||t.due<next.due)) next=t; });
    if(!next) break;
    now=next.due; var f=next.f; next.f=null; f();
  }
  now=end;
}
let calls=[], selects=[], pageZooms=0, turns=[];
function _bridge(){ return {callHandler:function(){ calls.push(Array.prototype.slice.call(arguments).join(':')); }}; }
window.fushiSelection={selection:null, clearSelection(){ this.selection=null; }};
var LAYER={contains:function(n){ return n==='layerNode'; }, getBoundingClientRect(){ return {left:40,top:40,right:360,bottom:560}; }};
function _selectOcrCharDetail(x,y,fromHover){
  var inLayer=!!_bzScopeAt(x,y);
  var onChar = inLayer ? true : (x>=100&&x<150&&y>=100&&y<=300);
  if(!onChar) return 'miss';
  selects.push((fromHover?'hover':'tap')+(inLayer?'@layer':'@page'));
  window.fushiSelection.selection={startNode: inLayer?'layerNode':'pageNode'};
  return 'hit';
}
function _selectOcrChar(x,y,h){ return _selectOcrCharDetail(x,y,h)!=='miss'; }
function _retryFailedPageAt(){ return false; }
function _userZoomedIn(){ return false; }
function _doubleTapZoom(){ pageZooms++; }
function _armLongPress(){}
$tap
$barrier
$hover
$module
// DOM 桩（声明在后，覆盖生成文档里的同名函数）。
function _bzBubbleAt(x,y){
  return (x>=100&&x<=200&&y>=100&&y<=300) ? {key:'p0:3',l:100,t:100,r:200,b:300} : null;
}
function _bzBuild(b){ return {el:LAYER,geom:{},bubble:b}; }
function _bzAnimateIn(){}
function _bzDestroy(){}
function _bzScopeAt(x,y){
  if(!bzLayer) return null;
  return (x>=40&&x<=360&&y>=40&&y<=560) ? LAYER : null;
}
var SEQ=[{key:'p0:1'},{key:'p0:3'},{key:'p0:5'}];
function _bzSequenceOnScreen(){ return SEQ; }
bzPointerType='touch';
// 一次直接打在 WebView 上的单击：按下（武装双击）→ 松手走 _onTap。
function tap(x,y,gap){ now+=(gap===undefined?1000:gap); _bzArmOnDown(x,y); now+=60; _onTap(x,y); }
function opens(){ return calls.filter(function(c){ return c.indexOf('onMangaBubbleZoom')===0; }); }
$body
''';
    }

    test('单击字零延迟查词，不弹放大层', () async {
      await runJs(
        harness('''
tap(120,200);
assert.deepEqual(selects,['tap@page']);
assert.deepEqual(opens(),[]);
'''),
      );
    });

    test('双击气泡里的字：第一击查词，第二击改判放大并撤回查词', () async {
      await runJs(
        harness('''
tap(120,200);
tap(124,204,150);
assert.deepEqual(selects,['tap@page']);
assert.deepEqual(opens(),['onMangaBubbleZoom:open:true']);
assert.equal(window.fushiSelection.selection,null);
assert.ok(bzLayer);
assert.equal(pageZooms,0);
'''),
      );
    });

    test('双击气泡空白处也放大（不撤回，因为没查词）；双击画格空白仍是普通缩放', () async {
      await runJs(
        harness('''
tap(180,200);
tap(182,202,150);
assert.deepEqual(opens(),['onMangaBubbleZoom:open:false']);
assert.equal(pageZooms,0);
_bzClose(true,false);
calls=[];
tap(300,600);
tap(302,602,150);
assert.deepEqual(opens(),[]);
assert.equal(pageZooms,1);
'''),
      );
    });

    test('两击相隔超过双击窗口：各自查词，不放大', () async {
      await runJs(
        harness('''
tap(120,200);
tap(120,200,DBL_MS+100);
assert.deepEqual(opens(),[]);
'''),
      );
    });

    test('弹窗已出来时第二击经 barrier 转进来：返回 zoom 并放大', () async {
      await runJs(
        harness('''
tap(120,200);
now+=DBL_MS+100; // 第二击按住时长 + 桥延迟，落在 barrier 宽限内
assert.equal(window.__mangaBarrierTapAt(122,202),'zoom');
assert.deepEqual(opens(),['onMangaBubbleZoom:open:false']);
assert.equal(window.fushiSelection.selection,null);
'''),
      );
    });

    test('放大层里单击字查词；点层外收起并消费这一击', () async {
      await runJs(
        harness('''
_bzOpen({key:'p0:3',l:100,t:100,r:200,b:300},false);
_bzPointerDown({pointerId:1,clientX:300,clientY:300,pointerType:'touch'});
now+=60;
_bzRelease(_bzTakePress(1),300,300);
assert.deepEqual(selects,['tap@layer']);
tap(390,700);
assert.equal(bzLayer,null);
assert.equal(opens().pop(),'onMangaBubbleZoom:close:false');
assert.equal(selects.length,1);
'''),
      );
    });

    test('放大层里再双击 = 收起，并撤回第一击的查词', () async {
      await runJs(
        harness('''
_bzOpen({key:'p0:3',l:100,t:100,r:200,b:300},false);
function layerTap(x,y,gap){ now+=gap; _bzPointerDown({pointerId:1,clientX:x,clientY:y,pointerType:'touch'}); now+=60; _bzRelease(_bzTakePress(1),x,y); }
layerTap(300,300,1000);
layerTap(303,302,150);
assert.equal(bzLayer,null);
assert.equal(opens().pop(),'onMangaBubbleZoom:close:true');
'''),
      );
    });

    test('弹窗开着时点层外：barrier 返回 miss 并收起放大层', () async {
      await runJs(
        harness('''
_bzOpen({key:'p0:3',l:100,t:100,r:200,b:300},false);
assert.equal(window.__mangaBarrierTapAt(390,700),'miss');
assert.equal(bzLayer,null);
'''),
      );
    });

    test('左右滑换相邻气泡：RTL 书向右滑 = 下一个，向左滑 = 上一个', () async {
      await runJs(
        harness('''
_bzOpen({key:'p0:3',l:100,t:100,r:200,b:300},false);
_bzPointerDown({pointerId:1,clientX:150,clientY:300,pointerType:'touch'});
now+=200;
_bzRelease(_bzTakePress(1),290,310);
assert.equal(bzLayer.bubble.key,'p0:5');
_bzPointerDown({pointerId:2,clientX:290,clientY:300,pointerType:'touch'});
now+=200;
_bzRelease(_bzTakePress(2),100,300);
_bzPointerDown({pointerId:3,clientX:290,clientY:300,pointerType:'touch'});
now+=200;
_bzRelease(_bzTakePress(3),100,300);
assert.equal(bzLayer.bubble.key,'p0:1');
// 已是第一个：再滑不动。
_bzPointerDown({pointerId:4,clientX:290,clientY:300,pointerType:'touch'});
now+=200;
_bzRelease(_bzTakePress(4),100,300);
assert.equal(bzLayer.bubble.key,'p0:1');
assert.equal(selects.length,0);
'''),
      );
    });

    test('条漫关了「双击缩放」：双击气泡不放大', () async {
      await runJs(
        harness(
          '''
tap(120,200);
tap(122,202,150);
assert.deepEqual(opens(),[]);
''',
          mode: MangaReadingMode.webtoon,
          preferences: const MangaReaderPreferences(
            webtoonDoubleTapZoom: false,
          ),
        ),
      );
    });

    test('功能关掉：双击气泡不放大', () async {
      await runJs(
        harness('''
tap(120,200);
tap(122,202,150);
assert.deepEqual(opens(),[]);
''', preferences: const MangaReaderPreferences(bubbleZoom: false)),
      );
    });

    test('桌面悬停：停留够时长才放大，只路过不弹', () async {
      await runJs(
        harness('''
function move(x,y){ fire('d:pointermove',{pointerType:'mouse',clientX:x,clientY:y,buttons:0,ctrlKey:false}); }
move(150,200);
advance(BZ_DELAY-50);
move(300,700); // 离开气泡
advance(500);
assert.deepEqual(opens(),[]);
move(150,200);
advance(BZ_DELAY);
assert.deepEqual(opens(),['onMangaBubbleZoom:open:false']);
'''),
      );
    });

    test('鼠标移出放大层 300ms 收起；查词面板开着（选区在层里）时保持', () async {
      await runJs(
        harness('''
function move(x,y){ fire('d:pointermove',{pointerType:'mouse',clientX:x,clientY:y,buttons:0,ctrlKey:false}); }
_bzOpen({key:'p0:3',l:100,t:100,r:200,b:300},false);
window.fushiSelection.selection={startNode:'layerNode'};
move(390,700);
advance(400);
assert.ok(bzLayer);
window.fushiSelection.selection=null;
move(395,705);
advance(BZ_LEAVE_MS-1);
assert.ok(bzLayer);
advance(1);
assert.equal(bzLayer,null);
'''),
      );
    });

    test('触屏的 pointermove 不触发悬停放大', () async {
      await runJs(
        harness('''
fire('d:pointermove',{pointerType:'touch',clientX:150,clientY:200,buttons:0});
advance(2000);
assert.deepEqual(opens(),[]);
'''),
      );
    });

    test('按住 Ctrl 模式：不按 Ctrl 不弹，按住立即弹', () async {
      await runJs(
        harness('''
fire('d:pointermove',{pointerType:'mouse',clientX:150,clientY:200,buttons:0,ctrlKey:false});
advance(2000);
assert.deepEqual(opens(),[]);
fire('w:keydown',{key:'Control',repeat:false});
advance(0);
assert.deepEqual(opens(),['onMangaBubbleZoom:open:false']);
''', preferences: const MangaReaderPreferences(bubbleZoomHover: 'ctrl')),
      );
    });

    test('悬停查词与悬停放大并存：原图上只放大，查词只在放大层里', () async {
      await runJs(
        harness('''
fire('d:mousemove',{clientX:120,clientY:200,shiftKey:false,ctrlKey:false});
assert.deepEqual(selects,[]);
assert.equal(window.__mangaBarrierHoverAt(120,200),false);
_bzOpen({key:'p0:3',l:100,t:100,r:200,b:300},false);
fire('d:mousemove',{clientX:300,clientY:300,shiftKey:false,ctrlKey:false});
assert.deepEqual(selects,['hover@layer']);
''', preferences: const MangaReaderPreferences(lookupOnHover: true)),
      );
    });

    test('悬停触发关掉时，原图悬停查词照旧', () async {
      await runJs(
        harness(
          '''
fire('d:mousemove',{clientX:120,clientY:200,shiftKey:false,ctrlKey:false});
assert.deepEqual(selects,['hover@page']);
''',
          preferences: const MangaReaderPreferences(
            lookupOnHover: true,
            bubbleZoomHover: 'off',
          ),
        ),
      );
    });
  });

  test('偏好读写：默认值、越界钳位、非法枚举回落', () {
    const MangaReaderPreferences defaults = MangaReaderPreferences();
    expect(defaults.bubbleZoom, isTrue);
    expect(defaults.bubbleZoomHover, 'dwell');
    expect(defaults.bubbleZoomDelay, 350);
    expect(defaults.bubbleZoomScale, 240);
    final MangaReaderPreferences parsed =
        MangaReaderPreferences.fromJson(const <String, Object?>{
          'bubbleZoom': false,
          'bubbleZoomHover': 'shake',
          'bubbleZoomDelay': 5,
          'bubbleZoomScale': 900,
        });
    expect(parsed.bubbleZoom, isFalse);
    expect(parsed.bubbleZoomHover, 'dwell');
    expect(parsed.bubbleZoomDelay, kMangaBubbleZoomDelayMin);
    expect(parsed.bubbleZoomScale, kMangaBubbleZoomScaleMax);
    final MangaReaderPreferences back = MangaReaderPreferences.fromJson(
      const MangaReaderPreferences(
        bubbleZoomHover: 'ctrl',
        bubbleZoomScale: 260,
      ).toJson(),
    );
    expect(back.bubbleZoomHover, 'ctrl');
    expect(back.bubbleZoomScale, 260);
  });
}
