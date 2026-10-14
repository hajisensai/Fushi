import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/highlight_bridge.dart';
import 'package:fushi/src/reader/reader_css_highlight_capability.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';

/// BUG-3343：Blink 105–119 的 `::highlight()` 在竖排里画在转置后的错误位置（标题字高亮
/// 跑到左上邻列，正文字高亮落到别处 / 看不见）。修法是把「能否用 CSS Custom Highlight」
/// 收成一个判据 [kReaderCssHighlightsSupportedJs]，旧 Blink 退回元素包裹兜底。
///
/// 覆盖边界：判据本身用 node 真跑（各 UA 的结论）；四个赋值点都用同一个判据（装配契约）。
/// 「Blink 119 竖排画错 / 120 画对 / 兜底 span 在 113 画对」只能在真 Chromium 里验，
/// 逐版 Chrome for Testing 截图证据记在 bug 文件。
void main() {
  const String assign =
      'window.__fushiCssHighlightsSupported = $kReaderCssHighlightsSupportedJs;';
  const String legacy =
      '__fushiCssHighlightsSupported = !!(window.CSS && CSS.highlights && window.Highlight);';

  // 四处都是逐字副本（它们的源码文本会被 node 行为测试按原样切出来跑，不能写 Dart 插值），
  // 这里按运行时拿到的 JS 逐字比对：改判据只改常量，副本没跟上就红。
  test('四个赋值点都用同一个判据，不再各写「API 在不在」', () {
    final Map<String, String> sources = <String, String>{
      'selection': ReaderSelectionScripts.source(),
      'highlightBridge': HighlightBridge.debugScriptSource,
      'paginated': ReaderPaginationScripts.paginatedShellSource(),
      'continuous': ReaderPaginationScripts.continuousShellSource(),
    };
    sources.forEach((String name, String js) {
      expect(js, contains(assign), reason: '$name 没用共享判据');
      expect(js, isNot(contains(legacy)), reason: '$name 还留着旧的裸判据');
    });
  });

  test('判据结论：旧 Blink 竖排画错的区间退回兜底，其它照用 API', () async {
    // 每个用例：[UA 或 null（无 navigator）, 有无 CSS.highlights, 期望]。
    const List<List<Object?>> cases = <List<Object?>>[
      // 旧 Android System WebView 的 UA 形态（示例版本）。
      <Object?>[
        'Mozilla/5.0 (Linux; Android 12) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/114.0.5735.196 Mobile Safari/537.36',
        true,
        false,
      ],
      <Object?>['Chrome/105.0.5195.0', true, false],
      <Object?>['Chrome/119.0.6045.105', true, false],
      <Object?>['Chrome/120.0.6099.109', true, true],
      <Object?>['Chrome/154.0.0.0 Edg/154.0.0.0', true, true],
      // WKWebView（iOS / macOS）不带 Chrome/。
      <Object?>[
        'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
        true,
        true,
      ],
      // API 不在：无论 UA 都是 false。
      <Object?>['Chrome/125.0.0.0', false, false],
      // 测试桩里没有 navigator 也不能抛。
      <Object?>[null, true, true],
    ];
    final StringBuffer js = StringBuffer()
      ..writeln('const vm = require("vm");')
      ..writeln('const expr = ${jsonEncode(kReaderCssHighlightsSupportedJs)};')
      ..writeln('const cases = ${jsonEncode(cases)};')
      ..writeln('let bad = 0;')
      ..writeln('for (const [ua, api, want] of cases) {')
      ..writeln('  const window = {};')
      ..writeln('  const ctx = { window };')
      ..writeln(
        '  if (api) { window.CSS = { highlights: new Map() }; window.Highlight = function() {}; ctx.CSS = window.CSS; }',
      )
      ..writeln('  if (ua !== null) ctx.navigator = { userAgent: ua };')
      ..writeln('  const got = vm.runInNewContext(expr, ctx);')
      ..writeln(
        '  if (got !== want) { bad++; console.log("FAIL", ua, api, "want", want, "got", got); }',
      )
      ..writeln('}')
      ..writeln('if (bad) process.exit(1);')
      ..writeln('console.log("all assertions passed");');
    final Directory dir = await Directory.systemTemp.createTemp('bug3328');
    try {
      final File f = File('${dir.path}/probe.js')
        ..writeAsStringSync(js.toString());
      final ProcessResult result = await Process.run(
        Platform.isWindows ? 'node.exe' : 'node',
        <String>[f.path],
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('all assertions passed'));
    } finally {
      dir.deleteSync(recursive: true);
    }
  });
}
