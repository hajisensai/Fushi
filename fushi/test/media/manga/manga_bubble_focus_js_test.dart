import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_bubble_focus_js.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reader_preferences.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/pages/implementations/manga_fushi_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 逐格读（聚焦模式）+ 文字条 / 台词栏（方案 C）：跑生成文档里**真实的**脚本片段
/// （聚焦几何、跳气泡 / 跨页、手势归属、滚轮 / Tab、文字条换气泡与命中范围），
/// DOM 量测与画布函数用桩替换；偏好注入、让位边距、快捷键接线按值断言。
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
    MangaTextStripLayout layout = MangaTextStripLayout.strip,
    String resume = '',
  }) => mangaWindowDocument(
    const <MokuroImage>[page],
    const <String>['page.png'],
    mode: mode,
    spreadDirection: direction,
    inlineSelectionJs: '',
    readerPreferences: preferences,
    bubbleZoomOpenMs: 0,
    bubbleZoomCloseMs: 0,
    textStripLayout: layout,
    bubbleFocusLabel: 'Read panel by panel',
    bubbleFocusResume: resume,
    textStripEmptyLabel: 'No text',
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
    final Directory dir = Directory.systemTemp.createTempSync('manga-fc-');
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
    test('各模式 × 文字条开关 × 版式下整段手势脚本都能解析', () async {
      final List<String> scripts = <String>[
        for (final MangaReadingMode mode in MangaReadingMode.values)
          for (final bool on in <bool>[true, false])
            for (final MangaTextStripLayout layout
                in MangaTextStripLayout.values)
              gestureScript(
                buildDocument(
                  mode: mode,
                  layout: layout,
                  resume: on ? 'last' : '',
                  preferences: MangaReaderPreferences(
                    bubbleTextStrip: on,
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

    test('偏好注入：压暗默认浅、文字条默认关；跨窗落点与版式原样注入', () {
      final String defaults = buildDocument();
      expect(defaults, contains("var FC_DIM = 'light';"));
      expect(defaults, contains('var TS_ON = false;'));
      expect(defaults, contains("var FC_RESUME = '';"));
      expect(defaults, contains('var RESERVE_R = 0, RESERVE_B = 0;'));
      final String custom = buildDocument(
        layout: MangaTextStripLayout.panel,
        resume: 'first',
        preferences: const MangaReaderPreferences(
          bubbleFocusDim: 'medium',
          bubbleTextStrip: true,
          bubbleTextStripSize: 30,
        ),
      );
      expect(custom, contains("var FC_DIM = 'medium';"));
      expect(custom, contains('var TS_ON = true;'));
      expect(custom, contains("var TS_LAYOUT = 'panel';"));
      expect(custom, contains('var TS_SIZE = 30;'));
      expect(custom, contains("var FC_RESUME = 'first';"));
      expect(custom, contains('var RESERVE_R = 320, RESERVE_B = 0;'));
      // spread 在让出右边后的区域里居中。
      expect(custom, contains('padding-right:320px;'));
    });

    test('让位边距：桌面台词栏占右边，触屏文字条占底边（随字号），关闭时为零', () {
      const MangaReaderPreferences off = MangaReaderPreferences();
      expect(mangaTextStripReserve(off, MangaTextStripLayout.panel), (
        right: 0.0,
        bottom: 0.0,
      ));
      const MangaReaderPreferences on = MangaReaderPreferences(
        bubbleTextStrip: true,
        bubbleTextStripSize: 22,
      );
      expect(mangaTextStripReserve(on, MangaTextStripLayout.panel), (
        right: kMangaTextPanelWidth,
        bottom: 0.0,
      ));
      expect(mangaTextStripReserve(on, MangaTextStripLayout.strip), (
        right: 0.0,
        bottom: 94.0,
      ));
      final String webtoon = buildDocument(
        mode: MangaReadingMode.webtoon,
        preferences: on,
      );
      expect(webtoon, contains('body{padding-bottom:94px;}'));
    });

    test('墨水屏：聚焦动画归零', () {
      final String doc = mangaWindowDocument(
        const <MokuroImage>[page],
        const <String>['page.png'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        readerPreferences: const MangaReaderPreferences(einkMode: true),
        bubbleZoomOpenMs: 325,
        bubbleZoomCloseMs: 165,
      );
      expect(doc, contains('var FC_MS = 0;'));
      final String animated = mangaWindowDocument(
        const <MokuroImage>[page],
        const <String>['page.png'],
        mode: MangaReadingMode.spread,
        spreadDirection: 'rtl',
        inlineSelectionJs: '',
        readerPreferences: const MangaReaderPreferences(),
        bubbleZoomOpenMs: 325,
        bubbleZoomCloseMs: 165,
      );
      expect(animated, contains('var FC_MS = 325;'));
    });

    test('捏合退出逐格读并保留缩放；同窗翻页后交给逐格读接落点', () {
      final String doc = buildDocument();
      expect(
        doc,
        contains("if (typeof _fcExit === 'function') _fcExit(true);"),
      );
      expect(
        doc,
        contains(
          "if (typeof _bzAfterTranslate === 'function') _bzAfterTranslate();",
        ),
      );
    });
  });

  group('手势与跳转', () {
    /// 桩：屏上三个气泡（阅读顺序 a → b → c），b 的范围 x∈[100,200] y∈[100,300]，
    /// 里面 x<150 是字。文字条范围 y≥760。
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
      final String zoom = section(
        doc,
        '  // ── 气泡放大：配置 ──',
        '  window.__mangaBubbleZoomClose',
      );
      final String focus = section(doc, '  // ── 逐格读（聚焦模式）──', '})();');
      final bool webtoon = mode != MangaReadingMode.spread;
      return '''
const assert=require('node:assert/strict');
var ZOOM=1, ZOOM_REST=1, ZOOM_MAX=8, PAN_X=0, PAN_Y=0, IS_WEBTOON=$webtoon, CURRENT=0, has=false;
var RESERVE_R=0, RESERVE_B=0;
var listeners={};
const window={innerWidth:400,innerHeight:800,scrollY:0,
  addEventListener(t,f){ (listeners['w:'+t]=listeners['w:'+t]||[]).push(f); }};
const document={
  addEventListener(t,f){ (listeners['d:'+t]=listeners['d:'+t]||[]).push(f); },
  documentElement:{addEventListener(t,f){ (listeners['e:'+t]=listeners['e:'+t]||[]).push(f); }},
  getElementById(){ return null; },
  createElement(){ return {style:{},appendChild(){},remove(){},setAttribute(){},classList:{add(){},remove(){},toggle(){}}}; },
  body:{appendChild(){}}, querySelector(){ return null; }, querySelectorAll(){ return []; },
};
function fire(key,e){ (listeners[key]||[]).forEach(function(f){ f(e); }); }
let now=1000;
Date.now=()=>now;
let timers=[];
function setTimeout(f,ms){ timers.push({f:f,due:now+(ms||0)}); return timers.length; }
function clearTimeout(id){ if(id>0&&timers[id-1]) timers[id-1].f=null; }
function requestAnimationFrame(f){ return setTimeout(function(){ f(now); },16); }
function cancelAnimationFrame(id){ clearTimeout(id); }
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
let calls=[], selects=[], pageZooms=0, zoomTargets=[];
function _bridge(){ return {callHandler:function(){ calls.push(Array.prototype.slice.call(arguments).join(':')); }}; }
window.fushiSelection={selection:null, clearSelection(){ this.selection=null; }};
function _selectOcrCharDetail(x,y,fromHover){
  var inStrip=!!_tsScopeAt(x,y);
  var onChar = inStrip ? true : (x>=100&&x<150&&y>=100&&y<=300);
  if(!onChar) return 'miss';
  selects.push((fromHover?'hover':'tap')+(inStrip?'@strip':'@page'));
  window.fushiSelection.selection={startNode:'n'};
  return 'hit';
}
function _selectOcrChar(x,y,h){ return _selectOcrCharDetail(x,y,h)!=='miss'; }
function _retryFailedPageAt(){ return false; }
function _userZoomedIn(){ return false; }
function _doubleTapZoom(){ pageZooms++; }
function _armLongPress(){}
function _applyCanvas(){ if (typeof _bzViewportChanged==='function') _bzViewportChanged(); }
function _zoomAnchorScrollTo(y){ window.scrollY=y; }
function _animateZoomTo(z,x,y,after){ zoomTargets.push(z); ZOOM=z; if(after) after(); }
function _recenterPan(){ PAN_X=0; PAN_Y=0; }
function _animMs(){ return 0; }
$tap
$zoom
$focus
// DOM 桩（声明在后，覆盖生成文档里的同名函数）。
var A={key:'0:1',l:250,t:100,r:350,b:200}, B={key:'0:3',l:100,t:100,r:200,b:300}, C={key:'0:5',l:20,t:400,r:120,b:500};
var SEQ=[A,B,C];
function _bzSequenceOnScreen(){ return SEQ; }
function _bzBubbleAt(x,y){
  for (var i=0;i<SEQ.length;i++){ var b=SEQ[i]; if(x>=b.l&&x<=b.r&&y>=b.t&&y<=b.b) return b; }
  return null;
}
function _bzBuild(b){ return {el:{getBoundingClientRect(){ return {left:0,top:0,right:0,bottom:0}; }},geom:{},bubble:b}; }
function _bzAnimateIn(){}
function _bzDestroy(){}
var STRIP=false;
function _tsScopeAt(x,y){ return STRIP && y>=760 ? {strip:true} : null; }
function _tsBuild(){ calls.push('tsBuild'); }
function _tsSetCurrent(k){ calls.push('tsCurrent:'+k); }
bzPointerType='touch';
function focusCalls(){ return calls.filter(function(c){ return c.indexOf('onMangaBubbleFocus')===0; }); }
function press(x,y,type,target){
  var e={pointerId:7,clientX:x,clientY:y,pointerType:type||'touch',target:target||null};
  return _bzPointerDown(e);
}
function release(x,y,dt){ now+=(dt===undefined?60:dt); var p=_bzTakePress(7); _bzRelease(p,x,y); return p; }
$body
''';
    }

    test('目标视图：气泡放到可用视口 85%，最多 4×、居中；平移钳在合法区间', () async {
      await runJs(
        harness('''
var t=_fcTarget({l:100,t:100,r:200,b:300},400,800);
// 宽 100 → 3.4×、高 200 → 3.4×；中心 (150,200) 落到视口中心。
assert.ok(Math.abs(t.z-3.4)<1e-9);
assert.ok(Math.abs(t.px-(200-150*3.4))<1e-9);
assert.ok(Math.abs(t.py-(400-200*3.4))<1e-9);
var tiny=_fcTarget({l:0,t:0,r:10,b:10},400,800);
assert.equal(tiny.z,4);
assert.equal(tiny.px,0); // 贴左缘的气泡：平移钳住，不露出页外
assert.equal(tiny.py,0);
var huge=_fcTarget({l:0,t:0,r:400,b:800},400,800);
assert.equal(huge.z,1);
'''),
      );
    });

    test('屏幕 ↔ 画布坐标互逆（缩放平移后量到的气泡回到同一布局位置）', () async {
      await runJs(
        harness('''
ZOOM=2.5; PAN_X=-120; PAN_Y=-40;
var L=_fcLocalRect({l:100,t:100,r:200,b:300});
var S=_fcScreenRect(L);
assert.deepEqual([S.l,S.t,S.r,S.b].map(Math.round),[100,100,200,300]);
'''),
      );
    });

    test('Z / ⤢ 进入：聚焦当前气泡、收起放大层；再按退出并缩回', () async {
      await runJs(
        harness('''
_bzOpen(B,false);
assert.ok(bzLayer);
assert.equal(window.__mangaFocusToggle(),'enter');
assert.equal(bzLayer,null);
assert.equal(fcOn,true);
assert.equal(fcKey,'0:3');
assert.ok(ZOOM>1);
assert.ok(focusCalls().indexOf('onMangaBubbleFocus:enter:1:3:')>=0);
assert.equal(window.__mangaFocusToggle(),'exit');
assert.equal(fcOn,false);
assert.deepEqual(zoomTargets,[1]);
assert.equal(focusCalls().pop(),'onMangaBubbleFocus:exit:-1:0:');
'''),
      );
    });

    test('没开放大层时进入：鼠标下的气泡优先，否则阅读顺序第一个', () async {
      await runJs(
        harness('''
bzMouseX=30; bzMouseY=450;
window.__mangaFocusToggle();
assert.equal(fcKey,'0:5');
_fcExit(true);
bzMouseX=-1;
window.__mangaFocusToggle();
assert.equal(fcKey,'0:1');
'''),
      );
    });

    test('跳气泡按阅读顺序；尽头交给翻页并记下落点，同窗翻页落定后聚焦新跨页首个', () async {
      await runJs(
        harness('''
_fcEnter(A);
assert.equal(_fcStep(1),true); assert.equal(fcKey,'0:3');
assert.equal(_fcStep(1),true); assert.equal(fcKey,'0:5');
calls=[];
assert.equal(_fcStep(1),true);
assert.equal(fcPendingEdge,'first');
assert.ok(calls.indexOf('onMangaTurn:next')>=0);
assert.ok(focusCalls().indexOf('onMangaBubbleFocus:turn:2:3:first')>=0);
SEQ=[{key:'1:2',l:200,t:100,r:300,b:200},{key:'1:4',l:50,t:100,r:150,b:200}];
_bzAfterTranslate();
advance(200);
assert.equal(fcOn,true);
assert.equal(fcKey,'1:2');
assert.equal(fcPendingEdge,null);
// 往回翻：落到上一跨页的最后一个。
_fcStep(-1);
assert.equal(fcPendingEdge,'last');
assert.ok(calls.indexOf('onMangaTurn:prev')>=0);
SEQ=[A,B,C];
_bzAfterTranslate();
advance(200);
assert.equal(fcKey,'0:5');
'''),
      );
    });

    test('不是逐格读自己翻的页（点热区 / 拖动）：退出逐格读、保留视图', () async {
      await runJs(
        harness('''
_fcEnter(B);
zoomTargets=[];
_bzAfterTranslate();
assert.equal(fcOn,false);
assert.deepEqual(zoomTargets,[]);
'''),
      );
    });

    test('条漫到书尾不翻页（整本已在一个文档里）', () async {
      await runJs(
        harness('''
_fcEnter(C);
calls=[];
assert.equal(_fcStep(1),false);
assert.equal(fcKey,'0:5');
assert.deepEqual(calls.filter(function(c){ return c.indexOf('onMangaTurn')===0; }),[]);
''', mode: MangaReadingMode.webtoon),
      );
    });

    test('触屏：逐格读接管按压——左右滑换气泡（RTL 向右滑是下一个），不平移', () async {
      await runJs(
        harness('''
_fcEnter(B);
assert.equal(press(200,500),true);
assert.equal(bzPress.kind,'fc');
release(320,505,120);
assert.equal(fcKey,'0:5');
press(320,500); release(200,505,120);
assert.equal(fcKey,'0:3');
'''),
      );
    });

    test('触屏：点字查词；点当前气泡空白不动；点气泡外退出；双击退出并撤回查词', () async {
      await runJs(
        harness('''
_fcEnter(B);
var r=_fcScreenRect(fcLocal);
// 字格：桩按屏幕坐标判字，聚焦后原图字格移到了别处——直接打到桩认的字区。
press(120,200); release(120,200);
assert.deepEqual(selects,['tap@page']);
assert.equal(fcOn,true);
// 再按一下立刻（双击）：退出，并撤回第一击的查词。
calls=[];
press(121,201); release(121,201);
assert.equal(fcOn,false);
assert.ok(calls.indexOf('onMangaBubbleZoom:close:true')>=0);
assert.equal(window.fushiSelection.selection,null);
_fcEnter(B);
r=_fcScreenRect(fcLocal);
now+=1000;
press((r.l+r.r)/2+30,(r.t+r.b)/2); release((r.l+r.r)/2+30,(r.t+r.b)/2);
assert.equal(fcOn,true);
now+=1000;
press(395,795); release(395,795);
assert.equal(fcOn,false);
'''),
      );
    });

    test('鼠标：按压不被接管（照常拖动平移）；单击经 _onTap 进逐格读的点击判定', () async {
      await runJs(
        harness('''
_fcEnter(B);
bzPointerType='mouse';
assert.equal(press(395,795,'mouse'),false);
_onTap(120,200);
assert.deepEqual(selects,['tap@page']);
assert.equal(fcOn,true);
_onTap(395,795);
assert.equal(fcOn,false);
'''),
      );
    });

    test('滚轮跳气泡（节流、Ctrl+滚轮仍归缩放）；Tab / Shift+Tab 跳气泡', () async {
      await runJs(
        harness('''
_fcEnter(A);
var stopped=0, prevented=0;
function wheel(dy,ctrl){ fire('w:wheel',{deltaY:dy,ctrlKey:!!ctrl,target:null,
  preventDefault(){ prevented++; }, stopImmediatePropagation(){ stopped++; }, stopPropagation(){}}); }
wheel(100);
assert.equal(fcKey,'0:3');
wheel(100); // 节流窗口内
assert.equal(fcKey,'0:3');
now+=400; wheel(-100);
assert.equal(fcKey,'0:1');
var before=stopped;
now+=400; wheel(100,true);
assert.equal(fcKey,'0:1');
assert.equal(stopped,before);
function key(shift){ var p=0; fire('w:keydown',{key:'Tab',shiftKey:!!shift,preventDefault(){ p++; }}); return p; }
assert.equal(key(false),1);
assert.equal(fcKey,'0:3');
key(true);
assert.equal(fcKey,'0:1');
_fcExit(true);
assert.equal(key(false),0); // 不在逐格读：Tab 不拦
'''),
      );
    });

    test('逐格读中不弹悬停放大，原图上的悬停查词照常', () async {
      await runJs(
        harness('''
_fcEnter(B);
bzPointerType='mouse';
_bzHover(150,200,false,0);
advance(2000);
assert.equal(bzLayer,null);
assert.equal(_bzBlocksHoverLookup(150,200,false),false);
_fcExit(true);
assert.equal(_bzBlocksHoverLookup(150,200,false),true);
'''),
      );
    });

    test('放大层的「⤢」：按下松开进入逐格读', () async {
      await runJs(
        harness('''
_bzOpen(B,false);
bzLayer.el={firstChild:{},getBoundingClientRect(){ return {left:0,top:0,right:400,bottom:800}; }};
var btn={closest(sel){ return sel==='.manga-bz-focus' ? btn : null; }};
assert.equal(press(380,20,'touch',btn),true);
assert.equal(bzPress.btn,true);
release(381,21);
assert.equal(fcOn,true);
assert.equal(fcKey,'0:3');
'''),
      );
    });

    test('文字条：按压归文字条，左右滑换气泡、单击走现有字格命中', () async {
      await runJs(
        harness('''
STRIP=true;
tsKey='0:1';
assert.equal(press(200,780),true);
assert.equal(bzPress.kind,'ts');
release(320,782,120);
assert.equal(tsKey,'0:3');
press(200,780); release(200,780);
assert.deepEqual(selects,['tap@strip']);
// 范围：放大层没开时，字格命中限定到文字条（_hitOcrChar 经 _bzScopeAt 取到它）。
assert.deepEqual(_bzScopeAt(10,790),{strip:true});
assert.equal(_bzScopeAt(10,100),null);
// 文字条上的悬停不触发放大，悬停查词放行。
assert.equal(_bzBlocksHoverLookup(10,790,false),false);
''', preferences: const MangaReaderPreferences(bubbleTextStrip: true)),
      );
    });

    test('逐格读中文字条换气泡 = 聚焦跟着换', () async {
      await runJs(
        harness('''
STRIP=true;
_fcEnter(A);
tsKey='0:1';
_tsStep(1);
assert.equal(fcKey,'0:3');
''', preferences: const MangaReaderPreferences(bubbleTextStrip: true)),
      );
    });
  });

  group('偏好与快捷键', () {
    test('偏好 JSON 往返与钳制', () {
      const MangaReaderPreferences prefs = MangaReaderPreferences(
        bubbleFocusDim: 'off',
        bubbleTextStrip: true,
        bubbleTextStripSize: 33,
      );
      final MangaReaderPreferences back = MangaReaderPreferences.fromJson(
        prefs.toJson(),
      );
      expect(back.bubbleFocusDim, 'off');
      expect(back.bubbleTextStrip, isTrue);
      expect(back.bubbleTextStripSize, 33);
      final MangaReaderPreferences bad = MangaReaderPreferences.fromJson(
        <String, Object?>{'bubbleFocusDim': 'heavy', 'bubbleTextStripSize': 99},
      );
      expect(bad.bubbleFocusDim, 'light');
      expect(bad.bubbleTextStripSize, kMangaBubbleTextStripSizeMax);
      expect(const MangaReaderPreferences().bubbleTextStrip, isFalse);
    });

    test('逐格读快捷键：manga scope 默认 Z，不吃翻页门控，进命令键桥', () {
      expect(ShortcutAction.mangaToggleBubbleFocus.scope, ShortcutScope.manga);
      final FushiShortcutRegistry registry = FushiShortcutRegistry()
        ..loadDefaults(TargetPlatform.windows);
      expect(
        registry.resolveKeyboard(
          LogicalKeyboardKey.keyZ,
          modifiers: const <ModifierKey>{},
          scope: ShortcutScope.manga,
        ),
        ShortcutAction.mangaToggleBubbleFocus,
      );
      for (final bool dictionaryShown in <bool>[false, true]) {
        for (final MangaReadingMode mode in MangaReadingMode.values) {
          expect(
            MangaFushiPage.inputActionForShortcut(
              action: ShortcutAction.mangaToggleBubbleFocus,
              crossPageStep: false,
              dictionaryShown: dictionaryShown,
              mode: mode,
            ),
            MangaReaderInputAction.toggleBubbleFocus,
          );
        }
      }
      expect(
        MangaFushiPage.commandKeyActions,
        contains(ShortcutAction.mangaToggleBubbleFocus),
      );
      expect(MangaFushiPage.commandKeyBridgeTokens(registry), contains('KeyZ'));
    });
  });
}
