import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-2147：词典自带 CSS 里的相对 `url()` 必须被重写到媒体通道。
///
/// 样式表被**内联成 `<style>`** 注入弹窗文档，所以里面的相对 URL 是相对**弹窗文档**
/// 解析的（Android 是 `file:///android_asset/.../popup/`，Windows/iOS 是
/// `initialData` 的 opaque origin），与词典目录毫无关系 —— 不重写就永远 404，
/// 雪碧图/背景图/图标全部不显示。
///
/// 两道守卫：
/// 1) 行为 —— node 真跑 `assets/popup/dict-media.js` 的 `constructDictCss`
///    （见同名 .js）。node 不在 PATH 时跳过。
/// 2) 镜像 —— `dict-media.js` 实际有**三份**：
///      a. `fushi/assets/popup/dict-media.js`（app 内弹窗）
///      b. `tools/browser-extension/vendor/dict-media.js`（扩展源，是 a 的**超集**）
///      c. `fushi/assets/browser_extension/vendor/dict-media.js`（随包的扩展副本）
///    b↔c 由 `dart run fushi/tool/sync_browser_extension.dart` 保持字节一致，已有
///    守卫（`browser_extension_installer_test` 等三条）钉死。**a→b 没有任何工具覆盖**
///    （`sync-mirrors.mjs` 不做这一向），只能靠这里钉住：改了 a 忘了 b，扩展弹窗里的
///    词典背景图/雪碧图会全部 404，而 a 的测试照绿。
void main() {
  test('dictionary CSS url() is rewritten to the media channel (node)',
      () async {
    final String? nodeExe = _resolveNode();
    if (nodeExe == null) {
      markTestSkipped('node not found on PATH; skipping JS behavior execution');
      return;
    }

    final File jsTest = File('test/pages/popup_dict_css_url_rewrite_test.js');
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
      reason: 'dict CSS url() rewrite JS behavior test failed.\n'
          'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
    );
    expect(
      result.stdout.toString(),
      contains('all assertions passed'),
      reason: 'behavior harness must reach its success marker',
    );
  });

  test('both dict-media.js mirrors carry the url() rewrite', () {
    const List<String> mirrors = <String>[
      'assets/popup/dict-media.js',
      '../tools/browser-extension/vendor/dict-media.js',
    ];
    for (final String relative in mirrors) {
      final File file = File(relative);
      expect(file.existsSync(), isTrue, reason: '$relative must exist');
      final String source = file.readAsStringSync();
      expect(
        source.contains('function rewriteDictCssUrls('),
        isTrue,
        reason: '$relative 缺 url() 重写：该镜像里的词典背景图/雪碧图会全部 404',
      );
      expect(
        source.contains('css = rewriteDictCssUrls(css, dictName);'),
        isTrue,
        reason: '$relative 定义了 rewriteDictCssUrls 却没在 constructDictCssUncached '
            '里调用——定义不调用等于没写',
      );
    }
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
