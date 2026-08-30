import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../helpers/source_guard.dart';

/// BUG-1924 的两条链路不变式。两者都住在私有 `State` 方法里，行为测试够不到
/// （`_openShelfChapter` / 两个 `catch` 分支都不是可从外部驱动的 API），所以在
/// 源码层钉住。
void main() {
  test('书架在线章必须显式给 initialPage，不得回落到书级 reader_positions', () {
    final String source = File(
      'lib/src/media/manga/reader/manga_fushi_page.dart',
    ).readAsStringSync();
    final String body = methodBody(
      source,
      'Future<void> _openShelfChapter({',
    );
    final String code = maskComments(body);

    // 关键判据：声明必须是**非空** `int`。写成 `int? initialPage;` 时，未读章
    // 与已读完章都会带着 null 走进 `_loadOnlineChapter`，那里
    // （`if (input.persistProgress && input.initialPage == null && ...)`）会去
    // 读整本**唯一那行** `reader_positions` —— 装的是上一章读到哪。读完第 3 话
    // 第 20 页自动换到第 4 话，第 4 话就从第 20 页开始，整章整章跳过内容。
    expect(
      code,
      contains('int initialPage = 0;'),
      reason: '每章进度的真相源是 manga_chapter_states，不是书级那一行',
    );
    expect(
      code,
      isNot(contains('int? initialPage')),
      reason: '可空的 initialPage 会把「未读章」交给书级位置行去猜',
    );
    expect(
      code,
      contains('initialPage: initialPage'),
      reason: '算出来的页码必须真的传给 openChapter',
    );
  });

  test('在线漫画的主流失败路径必须记日志（OnlineMangaUnavailable 不是兜底分支）',
      () {
    final String source = File(
      'lib/src/media/manga/library/manga_series_page.dart',
    ).readAsStringSync();
    final String code = maskComments(source);

    // adapter 把 Mihon/Aidoku 的运行时与网络异常全包成了 OnlineMangaUnavailable，
    // 所以 `on Object` 那支基本收不到东西。这两处不记，用户报「漫画打不开 / 刷
    // 不出来」时事后捞日志就是空的 —— 而 stage/diagnostics 这套东西本来就是为
    // 排障建的。
    final List<String> sites = <String>[
      'MangaSeriesPage.refresh',
      'MangaSeriesPage.openChapter',
    ];
    for (final String site in sites) {
      final int typed = code.indexOf('} on OnlineMangaUnavailable catch');
      expect(typed, greaterThanOrEqualTo(0));
      expect(
        code,
        contains("ErrorLogService.instance.log(\n        '$site["),
        reason: '$site 的 OnlineMangaUnavailable 分支必须记日志（带 reason 分流）',
      );
    }

    // 负向：不得退回「只有兜底 on Object 记日志」的形状。
    expect(
      RegExp(r'\} on OnlineMangaUnavailable catch \(error\) \{')
          .hasMatch(code),
      isFalse,
      reason: '只捕 error 不捕 stack 说明这一支没在记日志',
    );
  });
}
