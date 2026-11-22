import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 拍板台 6uasoIUvSR：查词弹窗的汉字卡仍排在词条之上，但整块默认折叠成一行
/// （「汉字 · 粉  词典名…」），点开才展开；折叠态吃词典管理「汉字」分区的逐本三态
/// （混合词典的汉字部分单记一份，BUG-3573）与全局「折叠词典」开关。
///
/// 行为由 `popup_kanji_collapse_test.js` 用 node 真执行 popup.js 的 `buildKanjiCards`
/// 钉住；这里在 `flutter test` 里驱动它，并守住宿主把两个名单注入给 popup.js。
void main() {
  test(
    'kanji block is a collapsed-by-default <details> (executes popup.js via node)',
    () async {
      final String? nodeExe = _resolveNode();
      if (nodeExe == null) {
        markTestSkipped(
          'node not found on PATH; skipping JS behavior execution',
        );
        return;
      }
      final ProcessResult result = await Process.run(nodeExe, <String>[
        'test/pages/popup_kanji_collapse_test.js',
      ], workingDirectory: Directory.current.path);
      expect(
        result.exitCode,
        0,
        reason:
            'popup kanji collapse JS behavior test failed.\n'
            'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
      );
      expect(result.stdout.toString(), contains('all assertions passed'));
    },
  );

  test(
    'the in-app popup injection hands the kanji collapse lists to popup.js',
    () {
      final String injection = File(
        'lib/src/pages/implementations/popup_settings_injection.dart',
      ).readAsStringSync();
      expect(
        injection,
        contains(
          r'window.kanjiCollapsedDictionaryNames = $kanjiCollapsedNames;',
        ),
      );
      expect(
        injection,
        contains(r'window.kanjiExpandedDictionaryNames = $kanjiExpandedNames;'),
      );
      expect(injection, contains('window.i18nKanjiSection = '));
      // 静态设置 memo 的命中判据必须包含这两个名单，否则改了汉字分区的三态弹窗不跟。
      expect(
        injection,
        contains('cached.kanjiCollapsedNames == kanjiCollapsedNames'),
      );
      expect(
        injection,
        contains('cached.kanjiExpandedNames == kanjiExpandedNames'),
      );
    },
  );
}

String? _resolveNode() {
  final List<String> candidates = Platform.isWindows
      ? <String>['node.exe', 'node']
      : <String>['node'];
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
