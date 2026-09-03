import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// PR#910 审查必修 ①（BUG-1651）：popupRendered 上报的内容高度必须与同一次调用里
/// 上报的 `window.innerHeight` **同单位**（host CSS px）。
///
/// 行为断言跑在 node 里（`pr910_popup_content_zoom_report_test.js`，直接执行 popup.js
/// 的 render-signal 源码块，覆盖 z=1.25 / 0.8 / shadow host / 非法值）；这里再钉死
/// 三镜像的接线，防任一份单独回退成裸 `__fushiScrollHeight()`。
void main() {
  const Map<String, String> jsMirrors = <String, String>{
    'in-app popup': 'assets/popup/popup.js',
    'extension vendor (assets)': 'assets/browser_extension/vendor/popup.js',
    'extension vendor (tools)': '../tools/browser-extension/vendor/popup.js',
  };

  test('popupRendered reports content height in host CSS px (node behavior)',
      () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest =
        File('test/pages/pr910_popup_content_zoom_report_test.js');
    expect(jsTest.existsSync(), isTrue);
    final ProcessResult result = await Process.run(
      nodeExe,
      <String>[jsTest.path],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'popup content-height unit test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(result.stdout.toString(), contains('all assertions passed'));
  });

  jsMirrors.forEach((String name, String relPath) {
    test('[$name] popupRendered 不得再直接上报未乘 zoom 的 layout px', () {
      final String js = File(relPath).readAsStringSync();

      // 断言的关键字面量：'function __fushiReportedContentHeight()' /
      // 'Math.ceil(__fushiScrollHeight() * __fushiPopupContentZoom())'
      expect(js.contains('function __fushiReportedContentHeight()'), isTrue,
          reason: '换算入口缺失');
      expect(
          js.contains(
              'Math.ceil(__fushiScrollHeight() * __fushiPopupContentZoom())'),
          isTrue,
          reason: '内容高度必须乘回当前 CSS zoom 才与 window.innerHeight 同单位');

      // 两处 popupRendered 调用（_reportPopupHeight + updatePopupIncremental）
      // 都必须走换算；漏任何一处都会让「增量追加词条」这条路径按 z 倍收错。
      // 断言的关键字面量："callHandler('popupRendered',"
      const String call = "callHandler('popupRendered',";
      final Iterable<Match> sites = call.allMatches(js);
      expect(sites.length, 2,
          reason: 'popupRendered 的调用点数量变了（${sites.length} 处），守卫须同步更新');
      for (final Match m in sites) {
        // 只看紧跟其后的第一个实参：窗口收窄到 60 字符，防同形 token 抢窗口。
        final int stop = m.end + 60 < js.length ? m.end + 60 : js.length;
        final String argWindow = js.substring(m.end, stop);
        expect(argWindow.contains('__fushiReportedContentHeight()'), isTrue,
            reason: 'popupRendered 的 args[0] 必须是换算后的 host CSS px');
      }

      // 断言的关键字面量（反向）：'__fushiScrollHeight(),' —— 裸的 layout px 作为
      // callHandler 实参正是本次回归的形态（函数定义与换算式里都不会出现这个逗号形态）。
      expect(js.contains('__fushiScrollHeight(),'), isFalse,
          reason: 'BUG-1651 回归：裸 __fushiScrollHeight() 是未乘 zoom 的 layout px，'
              '与 window.innerHeight 不同单位');
    });
  });
}

String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // Try the next executable name.
    }
  }
  return null;
}
