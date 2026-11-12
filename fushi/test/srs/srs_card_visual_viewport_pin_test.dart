// BUG-4172（NoerCpP877 / cQFqqg193s）：复习卡释义 WebView 的视觉视口偏移与选区菜单。
//
// - kSrsVisualViewportPinScript：node 在假 DOM 上真执行。未缩放时视觉视口偏移 ≥ 1px 就把
//   钉在布局视口原点的锚点 scrollIntoView 回去；缩放 / 选区还在 / 正在输入时不动；
//   选区收起后 selectionchange 再复位；装两次不重复挂监听、锚点复用；根节点 zoom 折算。
// - srsPageWindowScript：每次钉完布局视口位置都调一次视觉视口复位。
// - 换卡 `__fushiSrsSetCard` 在 scrollTo(0, 0) 后复位视觉视口；外壳页先装复位脚本再装换卡脚本。
// - 卡面 InAppWebView 在触屏端不关系统选区菜单（长按选词后唯一的复制入口）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';

import '../helpers/source_guard.dart';

void main() {
  test(
    'kSrsVisualViewportPinScript / srsPageWindowScript：视觉视口复位（node 真执行）',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final Directory dir = Directory.systemTemp.createTempSync('srs_vv_pin_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final String sep = Platform.pathSeparator;
      File(
        '${dir.path}${sep}pin.js',
      ).writeAsStringSync(kSrsVisualViewportPinScript);
      File(
        '${dir.path}${sep}on.js',
      ).writeAsStringSync(srsPageWindowScript(4200));
      File(
        '${dir.path}${sep}off.js',
      ).writeAsStringSync(srsPageWindowScript(null));
      final File harness = File('${dir.path}${sep}h.js')
        ..writeAsStringSync(_harness);
      final ProcessResult result = await Process.run(nodeExe, <String>[
        harness.path,
        dir.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'));
    },
  );

  test('换卡在 scrollTo(0, 0) 之后复位视觉视口', () {
    const String shell = kSrsCardShellScript;
    final int setCard = shell.indexOf('window.__fushiSrsSetCard = function(');
    expect(setCard, greaterThan(0));
    final int inner = shell.indexOf('q.innerHTML = html;', setCard);
    final int top = shell.indexOf('window.scrollTo(0, 0);', inner);
    final int pin = shell.indexOf('window.__fushiSrsPinViewport()', top);
    final int replay = shell.indexOf('replayFrom(scripts, 0, my)', top);
    expect(inner, greaterThan(setCard));
    expect(top, greaterThan(inner));
    expect(
      pin,
      allOf(greaterThan(top), lessThan(replay)),
      reason: 'scrollTo 只回布局视口，上一张卡的视觉视口偏移要在换卡时一并复位',
    );
  });

  test('外壳页先装视觉视口复位脚本，再装换卡脚本', () {
    final String html = srsCardShellHtml(themeCss: '', classes: '');
    final int pin = html.indexOf(kSrsVisualViewportPinScript);
    final int shell = html.indexOf(kSrsCardShellScript);
    expect(pin, greaterThan(0));
    expect(shell, greaterThan(pin));
  });

  test('守卫：卡面 InAppWebView 在触屏端保留系统选区菜单（复制）', () {
    final String src = maskComments(
      File(
        'lib/src/pages/implementations/srs/srs_card_face.dart',
      ).readAsStringSync(),
    );
    final int at = src.indexOf('initialSettings: InAppWebViewSettings(');
    expect(at, greaterThan(0));
    final int end = src.indexOf('shouldOverrideUrlLoading:', at);
    expect(end, greaterThan(at));
    final String settings = src.substring(at, end);
    expect(
      RegExp(r'disableContextMenu:\s*!isMobilePlatform').hasMatch(settings),
      isTrue,
      reason:
          'Android / iOS 长按选词后系统选区菜单是唯一的复制入口（cQFqqg193s）；'
          '桌面端原生右键菜单带「刷新」，会把外壳页重载成空卡，照旧关',
    );
    expect(
      RegExp(r'disableContextMenu:\s*true').hasMatch(settings),
      isFalse,
      reason: '无条件关掉会让触屏端选中释义后没有复制按钮',
    );
  });
}

const String _harness = r'''
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const dir = process.argv[2];
const read = (n) => fs.readFileSync(path.join(dir, n), 'utf8');

function env() {
  const vvListeners = {};
  const docListeners = {};
  const winListeners = {};
  const into = [];
  const state = { collapsed: true };
  const vv = {
    offsetTop: 0, offsetLeft: 0, height: 306, scale: 1,
    addEventListener(t, fn) { (vvListeners[t] = vvListeners[t] || []).push(fn); },
  };
  const root = {
    nodeType: 1, tagName: 'HTML', style: { overflowY: '' }, zoom: '1', children: [],
    appendChild(c) { this.children.push(c); c.isConnected = true; },
  };
  const body = { nodeType: 1, tagName: 'BODY' };
  const document = {
    documentElement: root,
    body,
    activeElement: body,
    createElement(tag) {
      return {
        tagName: tag.toUpperCase(), style: {}, attrs: {}, isConnected: false,
        setAttribute(k, v) { this.attrs[k] = v; },
        // Chromium：根视口（布局 + 视觉）把锚点对齐到视觉视口起点；布局视口已在锚点上，
        // 只剩视觉视口回到 0。
        scrollIntoView(o) {
          into.push({ top: this.style.top, left: this.style.left, opts: o });
          vv.offsetTop = 0;
          vv.offsetLeft = 0;
        },
      };
    },
    addEventListener(t, fn) { (docListeners[t] = docListeners[t] || []).push(fn); },
  };
  const window = {
    scrollX: 0, scrollY: 0, visualViewport: vv,
    getSelection: () => ({ isCollapsed: state.collapsed }),
    scrollTo(x, y) { this.scrollX = x; this.scrollY = y; },
    addEventListener(t, fn) { (winListeners[t] = winListeners[t] || []).push(fn); },
  };
  window.ResizeObserver = function () { this.observe = () => {}; };
  const getComputedStyle = (el) => ({ zoom: el.zoom, overflowY: el.style.overflowY });
  const run = (src) => new Function('window', 'document', 'getComputedStyle', src)(
    window, document, getComputedStyle);
  const fireVv = (t) => (vvListeners[t] || []).forEach((fn) => fn());
  const fireDoc = (t) => (docListeners[t] || []).forEach((fn) => fn());
  return { vv, root, body, document, window, into, state, run, fireVv, fireDoc,
    vvListeners, docListeners };
}

// 现场（NoerCpP877）：scrollY = 0、视觉视口 offsetTop 58.9、scale 1 → 复位。
{
  const e = env();
  e.run(read('pin.js'));
  assert.strictEqual(typeof e.window.__fushiSrsPinViewport, 'function');
  e.vv.offsetTop = 58.85714340209961;
  e.fireVv('scroll');
  assert.strictEqual(e.into.length, 1);
  assert.strictEqual(e.into[0].top, '0px');
  assert.strictEqual(e.into[0].left, '0px');
  assert.deepStrictEqual(e.into[0].opts, { block: 'start', inline: 'start', behavior: 'instant' });
  assert.strictEqual(e.vv.offsetTop, 0);
  assert.strictEqual(e.root.children.length, 1);
  assert.strictEqual(e.root.children[0].attrs['aria-hidden'], 'true');
  assert.ok(/visibility:hidden/.test(e.root.children[0].style.cssText));
  assert.ok(/pointer-events:none/.test(e.root.children[0].style.cssText));
  // 横向偏移同样复位；resize 也触发。
  e.vv.offsetLeft = 12;
  e.fireVv('resize');
  assert.strictEqual(e.into.length, 2);
  // 没有偏移（< 1px）：不动。
  e.vv.offsetTop = 0.5;
  e.fireVv('scroll');
  assert.strictEqual(e.into.length, 2);
  // 再装一次：不重复挂监听，锚点复用。
  e.run(read('pin.js'));
  assert.strictEqual(e.vvListeners.scroll.length, 1);
  assert.strictEqual(e.vvListeners.resize.length, 1);
  assert.strictEqual(e.docListeners.selectionchange.length, 1);
  e.vv.offsetTop = 30;
  e.fireVv('scroll');
  assert.strictEqual(e.into.length, 3);
  assert.strictEqual(e.root.children.length, 1);
}

// 缩放中（用户意图）：不动。
{
  const e = env();
  e.run(read('pin.js'));
  e.vv.scale = 2;
  e.vv.offsetTop = 100;
  e.fireVv('scroll');
  assert.strictEqual(e.into.length, 0);
}

// 选区还在（拖手柄时 Chromium 自动滚视觉视口跟手）：不动；选区收起后 selectionchange 复位。
{
  const e = env();
  e.run(read('pin.js'));
  e.state.collapsed = false;
  e.vv.offsetTop = 40;
  e.fireVv('scroll');
  e.fireDoc('selectionchange');
  assert.strictEqual(e.into.length, 0);
  e.state.collapsed = true;
  e.fireDoc('selectionchange');
  assert.strictEqual(e.into.length, 1);
  assert.strictEqual(e.vv.offsetTop, 0);
}

// 焦点在输入框（软键盘要让光标可见）：不动；失焦后复位。
{
  const e = env();
  e.run(read('pin.js'));
  e.document.activeElement = { tagName: 'INPUT' };
  e.vv.offsetTop = 80;
  e.fireVv('resize');
  assert.strictEqual(e.into.length, 0);
  e.document.activeElement = { tagName: 'DIV', isContentEditable: true };
  e.fireVv('resize');
  assert.strictEqual(e.into.length, 0);
  e.document.activeElement = e.body;
  e.fireVv('resize');
  assert.strictEqual(e.into.length, 1);
}

// 窗口态（BUG-4038）：锚点 = 布局视口原点；根节点 zoom 折算回 CSS px。
// srsPageWindowScript 每次钉完布局视口都复位视觉视口。
{
  const e = env();
  e.run(read('pin.js'));
  e.root.zoom = '2';
  e.vv.offsetTop = 25;
  e.run(read('on.js'));
  assert.strictEqual(e.window.scrollY, 4200);
  assert.strictEqual(e.root.style.overflowY, 'hidden');
  assert.strictEqual(e.into.length, 1);
  assert.strictEqual(e.into[0].top, '2100px');
  assert.strictEqual(e.vv.offsetTop, 0);
  // 退出窗口态：回到顶，同样复位。
  e.root.zoom = '1';
  e.vv.offsetTop = 9;
  e.run(read('off.js'));
  assert.strictEqual(e.window.scrollY, 0);
  assert.strictEqual(e.into.length, 2);
  assert.strictEqual(e.into[1].top, '0px');
}

// 外壳没装复位脚本（旧页面）：窗口脚本照常工作、不抛。
{
  const e = env();
  e.run(read('on.js'));
  assert.strictEqual(e.window.scrollY, 4200);
  assert.strictEqual(e.into.length, 0);
}
console.log('all assertions passed');
''';

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String d in pathEnv.split(separator)) {
    if (d.isEmpty) continue;
    final File candidate = File('$d${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
