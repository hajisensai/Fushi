// WebView 卡面的指针脚本（kSrsCardLookupScript）里的卡面手势分支：与原生卡面
// （SrsCardGestureRegion）同一套判据，在 node 里用最小 DOM 桩跑真脚本。
//
// - 点按归属：可点元素归页面、点在字上归取词、其余才回报 `tap`；
// - 双击只在开了时等第二击；长按只认触屏 / 空白；
// - 滑动只认触屏、只认开着的轴，落点所在容器还能往手指方向滚时是滚动；接管后逐帧报
//   `drag`、松手报 `release`（带速度），途中容器真的滚了报 `cancel`；
// - 没下发门控（网页浏览器标签页）：旧路径原样（只取词，不报手势）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_lookup.dart';
import 'package:fushi/src/srs/srs_review_gestures.dart';

import '../helpers/node_runtime.dart';

/// 最小 DOM 桩：document 级监听、elementFromPoint 返回的元素、计算样式（cursor /
/// overflow）、选区；fushiSelection 的逐字命中按 `textAt` 判；宿主 callHandler 记账。
/// 时间（Date.now / setTimeout / requestAnimationFrame）由 `advance(ms)` / `frame()` 手动推。
String _harness(String body) =>
    '''
const assert = require('node:assert/strict');
globalThis.window = globalThis;
window.innerWidth = 400; window.innerHeight = 800;
let now = 1000;
Date.now = function(){ return now; };
let timers = [];
let nextId = 1;
globalThis.setTimeout = function(f, ms){ const id = nextId++; timers.push({id, at: now + ms, f}); return id; };
globalThis.clearTimeout = function(id){ timers = timers.filter(t => t.id !== id); };
let rafs = [];
globalThis.requestAnimationFrame = function(f){ const id = nextId++; rafs.push({id, f}); return id; };
globalThis.cancelAnimationFrame = function(id){ rafs = rafs.filter(r => r.id !== id); };
function advance(ms){
  now += ms;
  const due = timers.filter(t => t.at <= now);
  timers = timers.filter(t => t.at > now);
  due.forEach(t => t.f());
}
function frame(){ const r = rafs; rafs = []; r.forEach(x => x.f()); }

const sent = [];
const selects = [];
const listeners = {};
let selection = '';
let textAt = null;
function el(tag, attrs, parent, style){
  return {
    nodeType: 1, tagName: tag.toUpperCase(), attrs: attrs || {}, parentElement: parent || null,
    isContentEditable: false, style: style || {},
    scrollLeft: 0, scrollTop: 0, scrollWidth: 400, scrollHeight: 800, clientWidth: 400, clientHeight: 800,
    hasAttribute(n){ return Object.prototype.hasOwnProperty.call(this.attrs, n); },
    getAttribute(n){ return this.hasAttribute(n) ? this.attrs[n] : null; },
    closest(){ return null; },
  };
}
const html = el('html');
const body = el('body', {}, html);
const blank = el('div', {}, body);
let hitEl = blank;
globalThis.document = {
  body, documentElement: html, scrollingElement: html,
  addEventListener(t, f){ (listeners[t] = listeners[t] || []).push(f); },
  elementFromPoint(){ return hitEl; },
};
window.getComputedStyle = function(n){
  return { cursor: n.style.cursor || 'auto', overflowX: n.style.overflowX || 'visible', overflowY: n.style.overflowY || 'visible' };
};
window.getSelection = function(){ return { isCollapsed: !selection, toString(){ return selection; } }; };
window.flutter_inappwebview = { callHandler(name, v){ if (name === '$kSrsGestureHandler') sent.push(JSON.parse(v)); } };
window.fushiSelection = {
  selectText(x, y, max, hover){ selects.push([x, y]); },
  getCharacterAtPoint(x, y){ return textAt && textAt(x, y) ? {} : null; },
};
function fire(type, ev){ (listeners[type] || []).forEach(f => f(ev)); }
function touch(type, x, y, target){
  const t = {clientX: x, clientY: y};
  fire(type, {target: target || hitEl, touches: type === 'touchend' ? [] : [t], changedTouches: [t]});
}
function mouse(type, x, y){ fire(type, {pointerType: 'mouse', button: 0, clientX: x, clientY: y, target: hitEl}); }
function tapTouch(x, y){ touch('touchstart', x, y); advance(40); touch('touchend', x, y); }
function tapMouse(x, y){ mouse('pointerdown', x, y); advance(40); mouse('pointerup', x, y); }
// 触屏拖动：分 n 步、每步 16ms，每步后跑一帧。
function swipe(x, y, dx, dy, n){
  n = n || 8;
  touch('touchstart', x, y);
  for (let i = 1; i <= n; i++) {
    advance(16);
    touch('touchmove', x + dx * i / n, y + dy * i / n);
    frame();
  }
  touch('touchend', x + dx, y + dy);
}
function kinds(){ return sent.map(e => e.t); }
function gestures(o){ window.__fushiSrsGestures = Object.assign({on: true}, o || {}); }
window.__fushiSrsLookup = {tap: true, hover: false, hostHover: false, open: false};
$kSrsCardLookupScript
$body
''';

void main() {
  final NodeTestRuntime nodeRuntime = NodeTestRuntime.probe();

  Future<void> runJs(String body) async {
    final Directory dir = Directory.systemTemp.createTempSync('srs-gesture-');
    try {
      final File script = File('${dir.path}/verify.js')
        ..writeAsStringSync(_harness(body));
      final ProcessResult result = await Process.run(
        nodeRuntime.requireNode(),
        <String>[script.path],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    } finally {
      dir.deleteSync(recursive: true);
    }
  }

  group('卡面手势脚本（node）', skip: nodeRuntime.skipReason, () {
    test('门控与 Dart 侧识别器开关同形', () {
      expect(
        srsCardGestureGateScript(
          const SrsCardGestureArming(doubleTap: true, swipeVertical: true),
        ),
        'window.__fushiSrsGestures = {"on":true,"doubleTap":true,'
        '"longPress":false,"swipeX":false,"swipeY":true};',
      );
      expect(
        srsCardGestureGateScript(null),
        'window.__fushiSrsGestures = null;',
      );
    });

    test('点空白：报 tap（带落点与视口尺寸）；点字归取词；点可点元素归页面', () async {
      await runJs(r'''
gestures();
tapTouch(20, 30);
assert.deepEqual(sent, [{t: 'tap', x: 20, y: 30, vw: 400, vh: 800}]);
assert.deepEqual(selects, []);

sent.length = 0;
textAt = () => true;
tapMouse(50, 60);
assert.deepEqual(sent, [], '点在字上不是空白');
assert.deepEqual(selects, [[50, 60]], '照常取词');

sent.length = 0; selects.length = 0; textAt = null;
hitEl = el('span', {}, el('button', {}, body));
tapTouch(70, 80);
hitEl = el('div', {}, body, {cursor: 'pointer'});
tapTouch(70, 80);
hitEl = el('div', {onclick: 'x()'}, body);
tapTouch(70, 80);
assert.deepEqual(sent, [], '按钮 / cursor:pointer（#2665 点按显示翻译）/ onclick 归页面');
assert.deepEqual(selects, []);

hitEl = blank;
selection = 'abc';
tapTouch(70, 80);
assert.deepEqual(sent, [], '拖选出选区时不算点空白');
''');
    });

    test('取词关掉时点空白照报（与原生卡面一致）；弹窗开着时不报', () async {
      await runJs(r'''
gestures();
window.__fushiSrsLookup = {tap: false};
tapTouch(10, 10);
assert.deepEqual(kinds(), ['tap']);
sent.length = 0;
window.__fushiSrsLookup = {tap: true, open: true};
tapTouch(10, 10);
assert.deepEqual(sent, [], '弹窗开着：点按交给宿主的关闭遮罩');
''');
    });

    test('双击：没开时单击立即报；开了时两下成双击、单独一下等满时限再报', () async {
      await runJs(r'''
gestures();
tapTouch(10, 10);
assert.deepEqual(kinds(), ['tap'], '没开双击不推迟');

sent.length = 0;
gestures({doubleTap: true});
tapTouch(100, 100);
assert.deepEqual(sent, [], '等第二击');
advance(80);
tapTouch(110, 104);
assert.deepEqual(kinds(), ['doubleTap']);
advance(1000);
assert.deepEqual(kinds(), ['doubleTap'], '没有补发单击');

sent.length = 0;
tapTouch(100, 100);
advance(310);
assert.deepEqual(kinds(), ['tap']);

sent.length = 0;
tapTouch(10, 10);
advance(80);
tapTouch(390, 700);
advance(1000);
assert.deepEqual(kinds(), ['tap', 'tap'], '离得太远：各算单击');
''');
    });

    test('长按：触屏空白满时限报一次、松手不再报单击；鼠标 / 字上 / 没开都不报', () async {
      await runJs(r'''
gestures({longPress: true});
touch('touchstart', 50, 50);
advance(520);
assert.deepEqual(kinds(), ['longPress']);
touch('touchend', 50, 50);
assert.deepEqual(kinds(), ['longPress']);

sent.length = 0;
mouse('pointerdown', 50, 50);
advance(520);
mouse('pointerup', 50, 50);
assert.deepEqual(kinds(), ['tap'], '鼠标按久了仍是单击');

sent.length = 0;
textAt = () => true;
touch('touchstart', 50, 50);
advance(520);
touch('touchend', 50, 50);
assert.deepEqual(sent, [], '字上的长按归选词');

textAt = null;
gestures();
touch('touchstart', 50, 50);
advance(520);
touch('touchend', 50, 50);
assert.deepEqual(kinds(), ['tap'], '没开长按就不识别');
''');
    });

    test('横滑：逐帧报 drag、松手报 release 带位移与速度；没开的轴 / 鼠标拖不接管', () async {
      await runJs(r'''
gestures({swipeX: true});
swipe(300, 400, -160, 6);
const k = kinds();
assert.equal(k[0], 'drag');
assert.equal(k[k.length - 1], 'release');
assert.equal(k.filter(x => x === 'drag').length, 8, '每帧至多一次');
const rel = sent[sent.length - 1];
assert.equal(rel.dx, -160); assert.equal(rel.dy, 6);
assert.ok(rel.vx < -1000, 'vx=' + rel.vx);

sent.length = 0;
swipe(200, 100, 0, 200);
assert.deepEqual(sent, [], '竖轴没开：不接管，也不算点按');

sent.length = 0;
mouse('pointerdown', 300, 400);
for (let i = 1; i <= 8; i++) { advance(16); mouse('pointermove', 300 - 20 * i, 400); frame(); }
mouse('pointerup', 140, 400);
assert.deepEqual(sent, [], '鼠标拖是拖选');

sent.length = 0;
touch('touchstart', 300, 400);
advance(600);
touch('touchmove', 100, 400);
frame();
touch('touchend', 100, 400);
assert.deepEqual(sent, [], '超过长按时限才起动的拖动不是滑动');
''');
    });

    test('竖滑与滚动：容器还能往手指方向滚是滚动；滚到头才是滑动；途中滚了报 cancel', () async {
      await runJs(r'''
gestures({swipeY: true});
const box = el('div', {}, body, {overflowY: 'auto'});
box.scrollHeight = 2000; box.clientHeight = 500;
hitEl = el('p', {}, box);

// 在顶端往上划（内容往下滚）：是滚动。
swipe(200, 400, 0, -200);
assert.deepEqual(sent, []);

// 顶端往下划：滚不动了，是滑动。
swipe(200, 100, 0, 200);
assert.equal(kinds().pop(), 'release');

// 中途两个方向都能滚。
sent.length = 0;
box.scrollTop = 300;
swipe(200, 100, 0, 200);
swipe(200, 400, 0, -200);
assert.deepEqual(sent, []);

// 页面本身能滚也一样。
sent.length = 0;
box.scrollTop = 0;
hitEl = blank;
html.scrollHeight = 3000; html.scrollTop = 0;
swipe(200, 600, 0, -200);
assert.deepEqual(sent, [], '页面还能往下滚');

// 判定接管后容器真的滚了（惯性等）：作废。
sent.length = 0;
html.scrollHeight = 800;
touch('touchstart', 200, 100);
advance(16); touch('touchmove', 200, 140); frame();
assert.deepEqual(kinds(), ['drag']);
html.scrollTop = 40;
advance(16); touch('touchmove', 200, 180); frame();
touch('touchend', 200, 220);
assert.deepEqual(kinds(), ['drag', 'cancel']);
''');
    });

    test('第二根手指 / 系统取消：作废，不触发', () async {
      await runJs(r'''
gestures({swipeX: true});
touch('touchstart', 300, 400);
advance(16); touch('touchmove', 240, 400); frame();
fire('touchstart', {target: hitEl, touches: [{clientX: 1, clientY: 1}, {clientX: 2, clientY: 2}], changedTouches: []});
touch('touchend', 100, 400);
assert.deepEqual(kinds(), ['drag', 'cancel']);
''');
    });

    test('没下发门控（网页浏览器标签页共用本脚本）：旧路径原样，只取词、不报手势', () async {
      await runJs(r'''
window.__fushiSrsGestures = null;
tapTouch(20, 30);
assert.deepEqual(selects, [[20, 30]], '旧路径：点哪里都交给选区脚本判');
swipe(300, 400, -160, 0);
touch('touchstart', 50, 50); advance(600); touch('touchend', 50, 50);
assert.deepEqual(sent, []);
window.__fushiSrsLookup = {tap: false};
selects.length = 0;
tapTouch(20, 30);
assert.deepEqual(selects, [], '取词关掉：旧路径什么都不做');
''');
    });
  });
}
