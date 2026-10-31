import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-3274：视频页换词时查词弹窗先闪「未找到」、结果多时滑动掉帧（Node 真执行
/// popup.js，见同名 .js）。
///
/// 守的是：空闲占位（`lookupIdle`）不画「未找到」；浏览器跳过渲染的屏外词条不被
/// masonry 强制排版、滚进视口时就地铺好；列数读内联值不触发整页样式重算。Dart 侧
/// `lookupIdle` 的注入守卫在 popup_settings_injection 相关测试。无 node 时 skip。
void main() {
  test(
    'BUG-3274 popup idle placeholder + lazy entries (executes popup.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }

      final File jsTest = File('test/pages/popup_lookup_perf_bug3274_test.js');
      expect(
        jsTest.existsSync(),
        isTrue,
        reason: 'behavior harness ${jsTest.path} must exist',
      );

      final ProcessResult result = await Process.run(nodeExe, <String>[
        jsTest.path,
      ], workingDirectory: Directory.current.path);

      expect(
        result.exitCode,
        0,
        reason:
            'BUG-3274 popup JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'));
    },
  );
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) return name;
    } on ProcessException {
      // try next candidate
    }
  }
  return null;
}
