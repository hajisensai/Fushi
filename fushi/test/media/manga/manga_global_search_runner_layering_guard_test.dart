import 'dart:io';

import 'package:test/test.dart';

/// 全源搜索的聚合执行层（`manga_global_search_runner.dart`）不直接依赖 widget 文件。
///
/// 路线图 #3722 c09 遗留：runner 为认 Cloudflare 挑战与 `OnlineMangaUnavailable`，
/// 直接 import 了 widget 文件 `mihon_cloudflare_action.dart`（后者又经带登录页依赖的
/// `online_manga_runtime_adapter.dart`）。这两个类型挪进
/// `online_manga_unavailable.dart` 之后，钉住两件事：runner 的每个 `package:fushi`
/// 直接依赖自己都不 import UI 包；那份类型文件也不 import UI 包。
void main() {
  final RegExp uiImport = RegExp(
    r"^import 'package:(material_ui|cupertino_ui|flutter/(material|cupertino|widgets))\b",
    multiLine: true,
  );
  final RegExp fushiImport = RegExp(
    r"^import 'package:fushi/([^']+)'",
    multiLine: true,
  );

  test('runner 的直接依赖都不带 UI import', () {
    final File runner = File(
      'lib/src/media/manga/manga_global_search_runner.dart',
    );
    expect(runner.existsSync(), isTrue, reason: '须在 fushi/ 下运行');
    final String source = runner.readAsStringSync();
    expect(uiImport.hasMatch(source), isFalse);
    final List<String> deps = fushiImport
        .allMatches(source)
        .map((RegExpMatch m) => 'lib/${m.group(1)}')
        .toList();
    expect(deps, isNotEmpty);
    final List<String> offenders = <String>[
      for (final String dep in deps)
        if (uiImport.hasMatch(File(dep).readAsStringSync())) dep,
    ];
    expect(offenders, isEmpty, reason: 'runner 直接 import 了 widget 文件');
  });

  test('online_manga_unavailable.dart 不带 UI import', () {
    final File file = File(
      'lib/src/media/manga/library/online_manga_unavailable.dart',
    );
    final String source = file.readAsStringSync();
    expect(source, contains('class OnlineMangaUnavailable '));
    expect(source, contains('mihonCloudflareChallenge('));
    expect(uiImport.hasMatch(source), isFalse);
  });
}
