// BUG-4038：复习卡窄版式释义超过纹理上限后的「滚动窗口」。
// - srsDefsWindowTop：可见段落在窗口里就不换窗口，滑出时把可见段居中进新窗口、不越界；
// - srsPageWindowScript：node 在假 DOM 上真执行，钉住「页面本身不可滚、页内位置由宿主钉死、
//   页面自己滚走或内容变高后拉回」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/srs/srs_card_face.dart';
import 'package:fushi/src/pages/implementations/srs/srs_defs_scroll_window.dart';

void main() {
  group('srsDefsWindowTop', () {
    double top(double current, double visibleTop) => srsDefsWindowTop(
      current: current,
      visibleTop: visibleTop,
      visibleHeight: 800,
      contentHeight: 9000,
      windowHeight: 4800,
    );

    test('可见段仍在窗口里：不换窗口', () {
      expect(top(0, 0), 0);
      expect(top(0, 4000), 0);
      expect(top(4200, 5000), 4200);
    });

    test('滑出窗口：可见段居中进新窗口（整数 px）', () {
      // 可见 [4100, 4900] 越过窗口 [0, 4800] 底：新起点 = 4100 − (4800 − 800) / 2。
      expect(top(0, 4100), 2100);
      expect(top(4200, 3000), 1000);
    });

    test('窗口不越出内容：末尾 / 开头贴边', () {
      expect(top(0, 8200), 4200); // 最后一屏：窗口 [4200, 9000] 盖住最后一本词典
      expect(top(4200, -300), 0); // 释义区还在视口下方
      expect(top(9999, 0), 0); // 当前值越界先夹回
    });
  });

  test('srsPageWindowScript：窗口态页面不可滚、位置钉死、退出后复原（node 真执行）', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final Directory dir = Directory.systemTemp.createTempSync('bug4007_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final String sep = Platform.pathSeparator;
    File('${dir.path}${sep}on.js').writeAsStringSync(srsPageWindowScript(4200));
    File(
      '${dir.path}${sep}move.js',
    ).writeAsStringSync(srsPageWindowScript(1000.4));
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
  });
}

const String _harness = r'''
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const dir = process.argv[2];
const read = (n) => fs.readFileSync(path.join(dir, n), 'utf8');

const listeners = {};
const observers = [];
const root = { style: { overflowY: '' } };
const window = {
  scrollY: 0,
  scrollTo(x, y) { this.scrollY = y; },
  addEventListener(type, fn) { (listeners[type] = listeners[type] || []).push(fn); },
};
window.ResizeObserver = function (cb) {
  this.observe = (t) => observers.push({ cb, t });
};
const document = { documentElement: root, body: {} };
const run = (src) => new Function('window', 'document', src)(window, document);
const fire = (type) => (listeners[type] || []).forEach((fn) => fn());

// 进入窗口态：页面本身不可滚（滚轮 / 触屏都滚不动），页内位置 = 宿主给的值。
run(read('on.js'));
assert.strictEqual(root.style.overflowY, 'hidden');
assert.strictEqual(window.scrollY, 4200);
// 页面自己滚走（换卡重放内容、聚焦、锚点）：拉回宿主的值。
window.scrollY = 0;
fire('scroll');
assert.strictEqual(window.scrollY, 4200);
// 内容变高（展开词典）后同样重新钉一次。
assert.strictEqual(observers.length, 1);
assert.strictEqual(observers[0].t, document.body);
window.scrollY = 10;
observers[0].cb();
assert.strictEqual(window.scrollY, 4200);
// 换窗口：整数 px，守卫不重复安装。
run(read('move.js'));
assert.strictEqual(window.scrollY, 1000);
assert.strictEqual(listeners.scroll.length, 1);
assert.strictEqual(observers.length, 1);
// 退出窗口态：复原可滚、回到顶，之后不再拉回。
run(read('off.js'));
assert.strictEqual(root.style.overflowY, '');
assert.strictEqual(window.scrollY, 0);
window.scrollY = 50;
fire('scroll');
assert.strictEqual(window.scrollY, 50);
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
