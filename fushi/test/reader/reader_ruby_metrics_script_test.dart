import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2777：iOS 换 Klee One 这类 ascent/descent 大的字体后，振假名离本列远、贴上一列。
///
/// 根因：Apple 注音规则用固定 `-0.2em` 把注音往基字拉，那是按 Hiragino（内容区≈em 盒）
/// 标定的；注音与基字间的两截空白（基字内容区超出 em 盒的量 + 注音盒半行距）由字体
/// 度量决定，CSS 拿不到。修法：`reader_ruby_metrics_script.dart` 在页面里量真实
/// `<ruby>`，写 `--fushi-ruby-pull`，CSS 吃这个变量。
///
/// ① 行为级：node 真执行 `kReaderRubyMetricsJs`，喂 iOS 模拟器实测的矩形，断言写出的
///    变量（Klee 竖排 0.813、Hiragino 0.106、无开关/无 ruby 不写）。
/// ② 接线级：脚本必须装进阅读器引擎（三种 view-mode 共用的 `__fushiEngine.install`），
///    否则变量永远不写、CSS 永远落回旧的 `-0.2em`。
void main() {
  test(
      'BUG-2777: ruby metrics script writes --fushi-ruby-pull from measured '
      'font geometry (executes script via node)', () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }
    final ProcessResult result = await Process.run(
      nodeExe,
      <String>['test/reader/reader_ruby_metrics_behavior_test.js'],
      workingDirectory: Directory.current.path,
    );
    expect(result.exitCode, 0,
        reason: 'stdout:\n${result.stdout}\nstderr:\n${result.stderr}');
    expect(result.stdout.toString(), contains('all assertions passed'));
  });

  test('BUG-2777: the metrics script is installed by the reader engine', () {
    final String webview = File(
      'lib/src/pages/implementations/reader_fushi/webview.part.dart',
    ).readAsStringSync();
    final int install = webview.indexOf('window.__fushiEngine = {');
    final int shell =
        webview.indexOf('window.__fushiInstallShell(C);', install);
    final int metrics = webview.indexOf(r'$kReaderRubyMetricsJs', install);
    expect(install, greaterThanOrEqualTo(0));
    expect(metrics, greaterThan(shell),
        reason: '度量脚本必须在 __fushiEngine.install 里、shell 安装之后注入'
            '（分页 / 连续 / VN 三种模式都走这里）');
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
      // Not found; try next candidate.
    }
  }
  return null;
}
