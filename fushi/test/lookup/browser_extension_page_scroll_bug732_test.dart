import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-732: Hibiki 的浏览器扩展把 popup.js 作为 content script 注入到所有网页
/// （`<all_urls>`）。popup.js 的 document 'wheel' 监听为「查词弹窗」重写了滚动
/// （按 POPUP_WHEEL_PIXEL_FACTOR=0.24 缩放 + preventDefault）。当滚轮落在宿主页
/// （不在弹窗 shadow 内）时，旧代码回落到 `window.scrollBy`，等于把每个普通网页的
/// 滚动都接管并降速到 24%。
///
/// 根因修复：扩展 content-script 上下文（`chrome.runtime.id` 存在）里，滚轮不在
/// 弹窗 shadow 内时必须回落原生滚动（不 preventDefault）。in-app 弹窗
/// （`flutter_inappwebview`，无 chrome）与「滚轮就在弹窗内」两条路径保持原有缩放滚动。
///
/// 两层守护：
/// ① 行为级——用 Node 真执行 popup.js 的 wheel 监听，断言四种表面下 preventDefault /
///    window.scrollBy / host.scrollBy 的调用。无 node 时 skip。
/// ② 源码级 + 三镜像一致——保证守卫存在、按 `chrome.runtime.id` 判定，且
///    assets/popup 与两份扩展 vendor 镜像逐字节一致（TODO-1267）。
void main() {
  test(
    'BUG-732: extension host-page wheel falls through to native (executes popup.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
            'node not found on PATH; skipping JS behavior execution');
        return;
      }

      final File jsTest = File(
        'test/lookup/browser_extension_page_scroll_bug732_test.js',
      );
      expect(jsTest.existsSync(), isTrue,
          reason: 'behavior harness ${jsTest.path} must exist');

      final ProcessResult result = await Process.run(
        nodeExe,
        <String>[jsTest.path],
        workingDirectory: Directory.current.path,
      );

      expect(
        result.exitCode,
        0,
        reason: 'BUG-732 wheel behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'),
          reason: 'behavior harness must reach its success marker');
    },
  );

  test('popup.js wheel guard bails on the extension host page (source guard)',
      () {
    const List<String> popupCopies = <String>[
      'assets/popup/popup.js',
      'assets/browser_extension/vendor/popup.js',
      '../tools/browser-extension/vendor/popup.js',
    ];

    for (final String path in popupCopies) {
      final String src = File(path).readAsStringSync();

      // The extension content-script discriminator: chrome.runtime.id present.
      expect(src.contains('chrome.runtime && chrome.runtime.id'), isTrue,
          reason: '[$path] 必须用 chrome.runtime.id 判定扩展 content-script 上下文');
      // The bail: not over the popup shadow (scroller null) AND in the extension
      // -> return before preventDefault so native scrolling wins.
      expect(src.contains('if (!scroller && inExtensionContentScript) return;'),
          isTrue,
          reason: '[$path] 扩展宿主页（滚轮不在弹窗内）必须回落原生滚动，禁止 preventDefault');
      // The guard must sit BEFORE preventDefault, otherwise the scaled scroll
      // still hijacks the host page.
      final int guardIdx =
          src.indexOf('if (!scroller && inExtensionContentScript) return;');
      final int preventIdx = src.indexOf('e.preventDefault();', guardIdx - 400);
      expect(guardIdx >= 0 && preventIdx > guardIdx, isTrue,
          reason: '[$path] 放行守卫必须在 e.preventDefault() 之前');
    }
  });

  test('the three popup.js copies stay byte-identical (TODO-1267 parity)', () {
    final String a = File('assets/popup/popup.js').readAsStringSync();
    final String b =
        File('assets/browser_extension/vendor/popup.js').readAsStringSync();
    final String c =
        File('../tools/browser-extension/vendor/popup.js').readAsStringSync();
    expect(a == b, isTrue, reason: 'assets/popup 与扩展 vendor 镜像必须逐字节一致');
    expect(a == c, isTrue, reason: 'assets/popup 与 tools 扩展镜像必须逐字节一致');
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
