// 复习卡窄版式释义页的页内偏移取证（ARhuDLRX-_ / mCu20adBXg，BUG 文件见 docs/bugs）。
//
// 窄版式释义 WebView 跟内容等高、由外层 Flutter 滚动，页面本身不该有滚动偏移；反馈截图里
// 第一条释义的上沿被切掉。[srsCardMetricsScript] 在页面出现偏移（文档 scrollY、某个元素的
// scrollTop、visual viewport 偏移）时把现场交给宿主记诊断。node 在假 DOM 上真执行：
// - 没有偏移的滚动事件（换卡回顶）不报；
// - 窗口态（宿主钉位置，overflow-y:hidden）不报；
// - 文档偏移 / 元素内偏移各报一次，带上 innerHeight / scrollHeight / 上报高度。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';

void main() {
  test('srsCardMetricsScript：等高页面出现自身偏移时报一次现场（node 真执行）', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final Directory dir = Directory.systemTemp.createTempSync('srs_offset_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String sep = Platform.pathSeparator;
    File(
      '${dir.path}${sep}metrics.js',
    ).writeAsStringSync(srsCardMetricsScript(height: true, wheel: true));
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
  });
}

const String _harness = r'''
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const dir = process.argv[2];
const src = fs.readFileSync(path.join(dir, 'metrics.js'), 'utf8');

function page() {
  const calls = [];
  const docListeners = {};
  const root = { nodeType: 1, style: { overflowY: '' }, scrollHeight: 1200 };
  const body = { nodeType: 1, getBoundingClientRect: () => ({ height: 1200 }) };
  const document = {
    documentElement: root,
    scrollingElement: root,
    body,
    addEventListener(type, fn) { (docListeners[type] = docListeners[type] || []).push(fn); },
  };
  const window = {
    scrollY: 0,
    innerHeight: 1200,
    flutter_inappwebview: { callHandler: (name, v) => calls.push([name, v]) },
    addEventListener() {},
  };
  window.ResizeObserver = function () { this.observe = () => {}; };
  const getComputedStyle = (el) => ({ overflowY: el.style.overflowY || 'visible' });
  new Function('window', 'document', 'getComputedStyle', src)(window, document, getComputedStyle);
  const scroll = (target) => (docListeners.scroll || []).forEach((fn) => fn({ target }));
  const offsets = () => calls.filter((c) => c[0] === 'onSrsPageOffset');
  return { calls, root, document, window, scroll, offsets };
}

// 文档偏移。
{
  const p = page();
  assert.deepStrictEqual(p.calls[0], ['onSrsContentHeight', 1200]);
  // 换卡回顶（scrollY = 0）的滚动事件：没有偏移，不报。
  p.scroll(p.document);
  assert.strictEqual(p.offsets().length, 0);
  // 窗口态：宿主钉住的页内位置是预期的，不报。
  p.root.style.overflowY = 'hidden';
  p.window.scrollY = 4200;
  p.scroll(p.document);
  assert.strictEqual(p.offsets().length, 0);
  // 退出窗口态后页面自己滚走：报一次，带上现场。
  p.root.style.overflowY = '';
  p.window.scrollY = 160;
  p.root.scrollHeight = 1360;
  p.scroll(p.document);
  assert.strictEqual(p.offsets().length, 1);
  const info = JSON.parse(p.offsets()[0][1]);
  assert.strictEqual(info.scrollY, 160);
  assert.strictEqual(info.scrollHeight, 1360);
  assert.strictEqual(info.innerHeight, 1200);
  assert.strictEqual(info.body, 1200);
  assert.strictEqual(info.reported, 1200);
  assert.strictEqual(info.inner, null);
  // 同一页只报一次。
  p.window.scrollY = 300;
  p.scroll(p.document);
  assert.strictEqual(p.offsets().length, 1);
}

// 元素内偏移（收起的主释义是 overflow:hidden 的滚动容器）。
{
  const p = page();
  const gloss = { nodeType: 1, className: 'fc-gloss fc-gloss--main', scrollTop: 0 };
  p.scroll(gloss);
  assert.strictEqual(p.offsets().length, 0);
  gloss.scrollTop = 90.4;
  p.scroll(gloss);
  assert.strictEqual(p.offsets().length, 1);
  assert.strictEqual(JSON.parse(p.offsets()[0][1]).inner, 'fc-gloss fc-gloss--main@90');
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
