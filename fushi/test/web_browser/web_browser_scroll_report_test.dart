import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/web_browser/web_browser_layout.dart';
import 'package:fushi/src/web_browser/tab_view/web_browser_page_scripts.dart';

/// 浏览器滚动上报不再逐帧过 JS 桥（滚动发顿的一个来源：每帧一次跨桥回调跟绘制
/// 抢线程）。这里用 node 真执行 [kWebBrowserScrollScript]，喂同一条逐帧滚动轨迹：
///
/// - 旧口径 = 每帧都把 (y, dy) 交给 [WebBrowserCollapseState]；
/// - 新口径 = 只把脚本真正上报的那几次交给它。
///
/// 两条路每一帧的「收起 / 展开」必须完全相同，且上报次数远少于帧数。无 node 时 skip。
void main() {
  test(
    'scroll script reports only collapse-relevant moments, with the same '
    'collapse outcome on every frame (executes the script via node)',
    () async {
      final String? node = _resolveNode();
      if (node == null) {
        markTestSkipped('node not found on PATH; skipping JS execution');
        return;
      }

      final List<List<_Frame>> traces = <List<_Frame>>[
        _steadyRead(),
        _jitterAndReverse(),
        _pausesAndBackToTop(),
        _innerContainerAndTouches(),
      ];

      for (int n = 0; n < traces.length; n++) {
        final List<_Frame> trace = traces[n];
        final List<List<int>> reports = await _runScript(node, trace);

        // 旧口径：逐帧。首帧只是给脚本定基准（与脚本同一口径）。
        final List<bool> perFrame = <bool>[];
        WebBrowserCollapseState old = const WebBrowserCollapseState();
        int? prevY;
        Object? prevTarget;
        for (final _Frame f in trace) {
          if (prevY != null && identical(prevTarget, f.target)) {
            final int dy = f.y - prevY;
            if (dy != 0) old = old.onScroll(y: f.y, dy: dy);
          }
          prevY = f.y;
          prevTarget = f.target;
          perFrame.add(old.collapsed);
        }

        // 新口径：只吃脚本上报。
        final Map<int, List<int>> byFrame = <int, List<int>>{
          for (final List<int> r in reports) r[0]: r,
        };
        WebBrowserCollapseState next = const WebBrowserCollapseState();
        for (int i = 0; i < trace.length; i++) {
          final List<int>? r = byFrame[i];
          if (r != null) next = next.onScroll(y: r[1], dy: r[2]);
          expect(
            next.collapsed,
            perFrame[i],
            reason: 'trace $n frame $i: collapse state diverged from per-frame',
          );
        }

        expect(
          reports.length * 4,
          lessThan(trace.length),
          reason:
              'trace $n: ${reports.length} reports for ${trace.length} frames',
        );
      }
    },
  );
}

class _Frame {
  const _Frame(this.y, this.t, {this.target = 'doc', this.pointer = false});

  /// 本帧滚动位置。
  final int y;

  /// 本帧时间（毫秒）。
  final int t;

  /// 滚的是哪个容器：'doc' = 文档，其它 = 某个内部 div。
  final String target;

  /// 本帧先来一次指针按下 / 触摸。
  final bool pointer;

  Map<String, Object> toJson() => <String, Object>{
    'y': y,
    't': t,
    'target': target,
    'pointer': pointer,
  };
}

List<_Frame> _steadyRead() {
  final List<_Frame> f = <_Frame>[];
  int t = 0;
  for (int i = 0; i <= 400; i++) {
    f.add(_Frame(i * 7, t += 16));
  }
  for (int i = 0; i < 120; i++) {
    f.add(_Frame(2800 - i * 9, t += 16));
  }
  return f;
}

List<_Frame> _jitterAndReverse() {
  final List<_Frame> f = <_Frame>[];
  int t = 0;
  int y = 500;
  const List<int> pattern = <int>[5, 5, -3, 6, 8, -2, -9, -12, 4, 30, -1, -40];
  for (int i = 0; i < 360; i++) {
    y = (y + pattern[i % pattern.length]).clamp(1, 1 << 20);
    f.add(_Frame(y, t += 8));
  }
  return f;
}

List<_Frame> _pausesAndBackToTop() {
  final List<_Frame> f = <_Frame>[];
  int t = 0;
  int y = 0;
  for (int seg = 0; seg < 12; seg++) {
    for (int i = 0; i < 20; i++) {
      y += 3;
      f.add(_Frame(y, t += 16));
    }
    t += 400; // 停顿
  }
  while (y > 0) {
    y = (y - 25).clamp(0, 1 << 20);
    f.add(_Frame(y, t += 16));
  }
  for (int i = 0; i < 60; i++) {
    y += 4;
    f.add(_Frame(y, t += 16));
  }
  return f;
}

List<_Frame> _innerContainerAndTouches() {
  final List<_Frame> f = <_Frame>[];
  int t = 0;
  int y = 100;
  for (int i = 0; i < 150; i++) {
    y += 6;
    f.add(_Frame(y, t += 16, pointer: i % 40 == 0));
  }
  int inner = 0;
  for (int i = 0; i < 150; i++) {
    inner += (i ~/ 30).isEven ? 5 : -7;
    if (inner < 1) inner = 1;
    f.add(_Frame(inner, t += 16, target: 'div', pointer: i % 50 == 0));
  }
  return f;
}

/// 在 node 里搭一个最小的 window / document，逐帧派发 scroll 并跑 rAF，返回
/// `[帧号, y, dy]` 形式的上报列表。
Future<List<List<int>>> _runScript(String node, List<_Frame> trace) async {
  final Directory dir = await Directory.systemTemp.createTemp('fushi_scroll_');
  try {
    final File js = File('${dir.path}${Platform.pathSeparator}harness.js');
    await js.writeAsString('''
var now = 0, frame = -1, rafs = [], reports = [];
var listeners = {};
function on(map, type, fn){ (map[type] = map[type] || []).push(fn); }
var docEl = { scrollTop: 0 };
var body = {};
var div = { scrollTop: 0 };
var document = {
  documentElement: docEl, body: body,
  addEventListener: function(type, fn){ on(listeners, 'doc:' + type, fn); }
};
var window = {
  scrollY: 0,
  addEventListener: function(type, fn){ on(listeners, 'win:' + type, fn); },
  flutter_inappwebview: { callHandler: function(name, y, dy){
    if (name !== ${jsonEncode(kWebBrowserScrollHandler)}) throw new Error('handler ' + name);
    reports.push([frame, y, dy]);
  } }
};
Date.now = function(){ return now; };
function requestAnimationFrame(fn){ rafs.push(fn); }
$kWebBrowserScrollScript
var trace = ${jsonEncode(trace.map((_Frame f) => f.toJson()).toList())};
trace.forEach(function(f, i){
  frame = i; now = f.t;
  if (f.pointer) (listeners['win:pointerdown'] || []).forEach(function(fn){ fn({}); });
  var target;
  if (f.target === 'doc') { window.scrollY = f.y; target = document; }
  else { div.scrollTop = f.y; target = div; }
  (listeners['doc:scroll'] || []).forEach(function(fn){ fn({ target: target }); });
  var run = rafs; rafs = [];
  run.forEach(function(fn){ fn(); });
});
process.stdout.write(JSON.stringify(reports));
''');
    final ProcessResult result = await Process.run(node, <String>[js.path]);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final List<dynamic> decoded = jsonDecode(result.stdout as String) as List;
    return decoded
        .map(
          (dynamic r) =>
              (r as List).cast<num>().map((num v) => v.toInt()).toList(),
        )
        .toList();
  } finally {
    await dir.delete(recursive: true);
  }
}

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
