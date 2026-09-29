import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_source_browse_page.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// LNReader 插件兼容层在**真 app 的 headless WebView**（CSP 封网络、只放行
/// inline + eval）里跑通的取证，走真网络：
///
/// - kakuyomu 1.0.0：站点改版后热门恒空，由宿主兼容补丁改读排行榜的
///   `__NEXT_DATA__`（浏览页真出卡片）；
/// - wuxiaworld：详情 / 章节走 `fetchProto`（gRPC-web，protobufjs 在 CSP 下跑）；
/// - madara 系（asuralightnovel）：章节日期经 dayjs 扩展格式化，不再是字面量 "LL"。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<bool> until(
    WidgetTester tester,
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) return false;
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pump(const Duration(milliseconds: 500));
    return true;
  }

  Future<T> settle<T>(WidgetTester tester, Future<T> future) async {
    bool done = false;
    late T value;
    Object? error;
    StackTrace? stack;
    unawaited(
      future.then(
        (T v) {
          value = v;
          done = true;
        },
        onError: (Object e, StackTrace s) {
          error = e;
          stack = s;
          done = true;
        },
      ),
    );
    await until(tester, () => done, timeout: const Duration(minutes: 3));
    if (error != null) Error.throwWithStackTrace(error!, stack!);
    if (!done) throw TimeoutException('future did not settle');
    return value;
  }

  Future<LnReaderInstalledPlugin> install(
    WidgetTester tester,
    LnReaderManager manager,
    String id,
  ) async {
    final LnReaderRepoPlugin plugin = manager.available.firstWhere(
      (LnReaderRepoPlugin p) => p.id == id,
    );
    await settle(tester, manager.install(plugin));
    return manager.installedById(id)!;
  }

  /// 热门 → 首部详情 → 首个正文章节，全部经真 WebView 运行时。
  Future<({LnReaderNovel novel, int chapterChars})> chain(
    WidgetTester tester,
    LnReaderManager manager,
    LnReaderInstalledPlugin plugin, {
    int chapterIndex = 0,
  }) async {
    await settle(tester, manager.load(plugin));
    final List<LnReaderNovelItem> popular = await settle(
      tester,
      manager.runtime.popular(plugin.id, page: 1, latest: false),
    );
    expect(popular, isNotEmpty, reason: '${plugin.id} 热门不应为空');
    final LnReaderNovel novel = await settle(
      tester,
      manager.runtime.novel(plugin.id, popular.first.path),
    );
    expect(novel.chapters, isNotEmpty, reason: '${plugin.id} 详情应有章节');
    final LnReaderChapter chapter =
        novel.chapters[chapterIndex.clamp(0, novel.chapters.length - 1)];
    final String html = await settle(
      tester,
      manager.runtime.chapter(plugin.id, chapter.path),
    );
    final int chars = html.replaceAll(RegExp(r'<[^>]*>|\s'), '').length;
    debugPrint(
      '[lnreader-compat] ${plugin.id} popular=${popular.length} '
      'novel=${novel.name} chapters=${novel.chapters.length} '
      'firstRelease=${novel.chapters.first.releaseTime} chapterChars=$chars',
    );
    return (novel: novel, chapterChars: chars);
  }

  testWidgets('LNReader 兼容层：kakuyomu 热门 / wuxiaworld fetchProto / madara 日期', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    final LnReaderManager manager = appModel.lnReaderManager;
    await settle(tester, manager.initialise());
    await settle(tester, manager.refreshStores());

    // ① kakuyomu：真浏览页进页即拉热门，卡片出现即补丁在真 WebView 里生效。
    final LnReaderInstalledPlugin kakuyomu = await install(
      tester,
      manager,
      'kakuyomu',
    );
    unawaited(
      appModel.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              LnReaderSourceBrowsePage(manager: manager, plugin: kakuyomu),
        ),
      ),
    );
    final Finder card = find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('novel_browse_item_'),
    );
    expect(
      await until(tester, () => card.evaluate().isNotEmpty),
      isTrue,
      reason: 'kakuyomu 热门应在 90s 内出卡片',
    );
    await captureFlutterFrame(tester, 'lnreader-compat-01-kakuyomu-browse');
    appModel.navigatorKey.currentState!.popUntil(
      (Route<dynamic> route) => route.isFirst,
    );
    await tester.pump(const Duration(milliseconds: 500));
    final ({LnReaderNovel novel, int chapterChars}) kakuyomuChain = await chain(
      tester,
      manager,
      kakuyomu,
    );
    expect(kakuyomuChain.chapterChars, greaterThan(100));

    // ② wuxiaworld：详情 / 章节是 gRPC-web。
    final ({LnReaderNovel novel, int chapterChars}) wuxia = await chain(
      tester,
      manager,
      await install(tester, manager, 'wuxiaworld'),
    );
    expect(wuxia.chapterChars, greaterThan(100));

    // ③ madara 系：章节日期不再是 dayjs 没装扩展时原样吐出的 "LL"。
    final ({LnReaderNovel novel, int chapterChars}) madara = await chain(
      tester,
      manager,
      await install(tester, manager, 'asuralightnovel'),
    );
    final List<String?> releases = madara.novel.chapters
        .map((LnReaderChapter c) => c.releaseTime)
        .toList();
    expect(releases, isNot(contains('LL')));
    expect(releases, isNot(contains('LLL')));
  });
}
