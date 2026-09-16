import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2546：MDX 词典自带脚本的作用域必须是**本词典块**，而不是整篇弹窗文档。
///
/// 弹窗 WebView 是常驻热槽：换词只重建结果 DOM、不重载页面，于是同一本词典的同一份
/// `<script>` 会被 `runDictScripts` 一次次重跑。此前脚本拿到的 `window` 是**真** window，
/// scoped document 的隔离被两条路绕过去：
/// ① jQuery 这类库内部 `var document = window.document` 取到真 document，
///    `$(document).on('click', …)` 绑在真 document 上 —— 第二次查词再绑一份，一次点击被
///    两份监听各处理一次，OALD 的 `.unbox` 折叠块展开又立刻收起，用户看到「折叠字段点不开」
///    （第三次查词监听数回到奇数，又能开）。
/// ② `if (window.__inited) return;` 这类幂等守卫更彻底：第二次起直接短路，新 DOM 一次都
///    绑不上，从此永久点不开。
///
/// 两层守护：
/// ① 行为级 —— 用 Node 真跑 `tools/browser-extension/dict-script-exec.test.js`（它把真
///    `dict-media.js` 载进 vm），连开三个词典块，断言每块都完整初始化、window 级监听落在
///    本块、真 window 上不留任何痕迹。无 node 时 skip。
/// ② 源码级 —— 三份镜像（app 弹窗 / 两份浏览器扩展 vendor）都必须真的把 scoped window 交
///    给脚本，且三份的代理实现逐字一致：行为测试只跑得到 vendor 那份，这条把 app 弹窗那份
///    钉在同一实现上。
void main() {
  test(
      'dictionary scripts get a per-block window (runs the JS harness via node)',
      () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File(
      '../tools/browser-extension/dict-script-exec.test.js',
    );
    expect(
      jsTest.existsSync(),
      isTrue,
      reason: 'behavior harness ${jsTest.path} must exist',
    );

    final ProcessResult result = await Process.run(
      nodeExe,
      <String>[jsTest.path],
      workingDirectory: Directory.current.path,
    );

    expect(
      result.exitCode,
      0,
      reason: 'dictionary script execution behavior tests failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );

    // 顺带挡住「一条都没跑也算过」：node:test 摘要里的 pass 数必须覆盖到本 BUG 的用例。
    final RegExpMatch? passes =
        RegExp(r'pass\D+(\d+)').firstMatch(result.stdout.toString());
    expect(
      passes,
      isNotNull,
      reason: 'behavior harness must report how many tests passed',
    );
    expect(
      int.parse(passes!.group(1)!),
      greaterThanOrEqualTo(13),
      reason: 'the per-block-window cases must be part of the run',
    );
  });

  test('all three dict-media.js mirrors hand the scripts a scoped window', () {
    const List<String> mirrors = <String>[
      'assets/popup/dict-media.js',
      'assets/browser_extension/vendor/dict-media.js',
      '../tools/browser-extension/vendor/dict-media.js',
    ];

    final List<String> scopedWindowBodies = <String>[];
    for (final String path in mirrors) {
      final File file = File(path);
      expect(file.existsSync(), isTrue, reason: '$path must exist');
      final String source = file.readAsStringSync();

      expect(
        source.contains('function createScopedWindow('),
        isTrue,
        reason: '$path must define the per-block window proxy',
      );
      expect(
        source.contains(
          'factory.call(scopedWindow, scopedDocument, scopedWindow, scopedWindow,',
        ),
        isTrue,
        reason: '$path must run dictionary scripts against the scoped window, '
            'not the real one',
      );
      // 裸标识符（jQuery 写进 window 后，同词典下一份脚本里的 `$(…)`）也得经代理解析。
      expect(
        source.contains(r'`with (window) {'),
        isTrue,
        reason: '$path must wrap dictionary scripts in `with (window)`',
      );

      final int start = source.indexOf('function createScopedWindow(');
      final int end = source.indexOf('\n}\n', start);
      expect(
        end,
        greaterThan(start),
        reason: '$path: unterminated createScopedWindow',
      );
      scopedWindowBodies.add(source.substring(start, end));
    }

    for (int i = 1; i < scopedWindowBodies.length; i++) {
      expect(
        scopedWindowBodies[i],
        scopedWindowBodies[0],
        reason: 'createScopedWindow drifted between mirrors '
            '(${mirrors[0]} vs ${mirrors[i]})',
      );
    }
  });
}

/// Resolve a usable `node` executable, returning null when none is on PATH.
String? _resolveNode() {
  final List<String> candidates =
      Platform.isWindows ? <String>['node.exe', 'node'] : <String>['node'];
  for (final String name in candidates) {
    try {
      final ProcessResult probe = Process.runSync(name, <String>['--version']);
      if (probe.exitCode == 0) {
        return name;
      }
    } on ProcessException {
      // Not found; try next candidate.
    }
  }
  return null;
}
