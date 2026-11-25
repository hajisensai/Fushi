import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

/// BUG-4042（反馈 SwFjAzjBqq：macOS 查词弹窗最右的「高级制卡」按钮与第三列词典被右缘
/// 裁掉）。宿主把 `#entries-container` 钉在 Flutter 平台视图整宽，没减文档竖向滚动条的
/// 占位 gutter（macOS「始终显示滚动条」/ 接鼠标时的 legacy 滚动条），内容比可见区宽出
/// 一截被裁。Playwright WebKit 探针（15px classic 滚动条）实测：修前 scrollWidth 390 >
/// clientWidth 385、按钮右缘 390；修后 scrollWidth == clientWidth。
///
/// 这里用 node 在假 DOM 上**真执行**宿主注入的脚本（`popupViewportScript`），钉住宽度
/// 算式与「内容变长后滚动条才出现」时的 ResizeObserver 重算。无 node 时 skip。
void main() {
  test(
    'popup viewport script subtracts the scrollbar gutter and recomputes '
    'when the gutter appears later (executes the injected JS via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final String script = DictionaryPopupWebViewState.popupViewportScript(
        400,
        300,
      );
      final Directory dir = Directory.systemTemp.createTempSync('bug4011_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final File scriptFile = File('${dir.path}${Platform.pathSeparator}s.js')
        ..writeAsStringSync(script);
      final File harness = File('${dir.path}${Platform.pathSeparator}h.js')
        ..writeAsStringSync(_harness);

      final ProcessResult result = await Process.run(nodeExe, <String>[
        harness.path,
        scriptFile.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'));
    },
  );
}

const String _harness = r'''
const fs = require('fs');
const assert = require('assert');
const src = fs.readFileSync(process.argv[2], 'utf8');

function makeEnv({ innerWidth, clientWidth, zoom, withObserver }) {
  const observers = [];
  const frames = [];
  const container = { style: {} };
  const rootStyle = { zoom: zoom || '', setProperty() {} };
  const documentElement = { style: rootStyle, clientWidth };
  const window = { innerWidth, relayouts: 0 };
  window.requestAnimationFrame = (cb) => { frames.push(cb); return frames.length; };
  window.__fushiRelayoutPopupColumns = () => { window.relayouts++; };
  if (withObserver) {
    window.ResizeObserver = function (cb) {
      this.cb = cb;
      this.targets = [];
      this.observe = (t) => { this.targets.push(t); };
      observers.push(this);
    };
  }
  const document = {
    documentElement,
    body: {},
    getElementById: (id) => (id === 'entries-container' ? container : null),
  };
  const getComputedStyle = () => ({ paddingLeft: '10px', paddingRight: '10px' });
  const run = new Function('window', 'document', 'getComputedStyle', src);
  return {
    window, document, container, observers, frames,
    inject: () => run(window, document, getComputedStyle),
    flushFrames: () => { frames.splice(0).forEach((cb) => cb()); },
  };
}

// 1. 占位滚动条 15px：可排版宽 = (400 − 15) − 两侧 body 内边距 20。
{
  const e = makeEnv({ innerWidth: 400, clientWidth: 385 });
  e.inject();
  assert.strictEqual(e.container.style.width, '365px');
  assert.strictEqual(e.container.style.maxWidth, '365px');
}
// 2. overlay 滚动条（gutter 0）：与修前同值，不回归。
{
  const e = makeEnv({ innerWidth: 400, clientWidth: 400 });
  e.inject();
  assert.strictEqual(e.container.style.width, '380px');
}
// 3. zoom 1.25：gutter 是视口 px，先减再按 zoom 折回 layout px。
{
  const e = makeEnv({ innerWidth: 400, clientWidth: 385, zoom: '1.25' });
  e.inject();
  assert.strictEqual(e.container.style.width, (385 / 1.25 - 20) + 'px');
}
// 4. BUG-1812 iOS innerWidth == 0：取不到 gutter 按 0，仍用 Flutter 宽度。
{
  const e = makeEnv({ innerWidth: 0, clientWidth: 0 });
  e.inject();
  assert.strictEqual(e.container.style.width, '380px');
}
// 5. 滚动条在内容变长后才出现：ResizeObserver 回调里 gutter 变了才重算；
//    重复注入不叠加观察者。
//    重算挪到下一帧：回调投递期间不写布局（写会改被观察的 documentElement 自身尺寸，
//    浏览器抛「ResizeObserver loop completed with undelivered notifications」）。
{
  const e = makeEnv({ innerWidth: 400, clientWidth: 400, withObserver: true });
  e.inject();
  e.inject();
  assert.strictEqual(e.observers.length, 1, 'observer must be installed once');
  assert.deepStrictEqual(e.observers[0].targets, [e.document.documentElement]);
  assert.strictEqual(e.container.style.width, '380px');
  const before = e.window.relayouts;
  e.observers[0].cb();
  assert.strictEqual(e.frames.length, 0, 'no gutter change -> no frame queued');
  assert.strictEqual(e.window.relayouts, before, 'no gutter change -> no relayout');
  e.document.documentElement.clientWidth = 385;
  e.observers[0].cb();
  e.observers[0].cb();
  assert.strictEqual(e.container.style.width, '380px',
    'callback must not write layout during ResizeObserver delivery');
  assert.strictEqual(e.window.relayouts, before, 'relayout waits for the next frame');
  assert.strictEqual(e.frames.length, 1, 'repeated callbacks queue a single frame');
  e.flushFrames();
  assert.strictEqual(e.container.style.width, '365px');
  assert.strictEqual(e.window.relayouts, before + 1);
  // 那一帧之前 gutter 又回到已应用的值（别的重算追平）：不重复铺。
  e.document.documentElement.clientWidth = 400;
  e.observers[0].cb();
  e.document.documentElement.clientWidth = 385;
  e.flushFrames();
  assert.strictEqual(e.window.relayouts, before + 1, 'gutter already applied -> skip');
}
console.log('all assertions passed');
''';

String? _resolveNode() {
  final String exe = Platform.isWindows ? 'node.exe' : 'node';
  final String pathEnv = Platform.environment['PATH'] ?? '';
  final String separator = Platform.isWindows ? ';' : ':';
  for (final String dir in pathEnv.split(separator)) {
    if (dir.isEmpty) continue;
    final File candidate = File('$dir${Platform.pathSeparator}$exe');
    if (candidate.existsSync()) return candidate.path;
  }
  return null;
}
