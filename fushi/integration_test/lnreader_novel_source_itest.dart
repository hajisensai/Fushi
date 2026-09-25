import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/novel/online/lnreader_book_download.dart';
import 'package:fushi/src/media/novel/online/lnreader_extensions_section.dart';
import 'package:fushi/src/media/novel/online/lnreader_installed_sources_section.dart';
import 'package:fushi/src/media/novel/online/lnreader_manager.dart';
import 'package:fushi/src/media/novel/online/lnreader_models.dart';
import 'package:fushi/src/media/novel/online/lnreader_novel_detail_page.dart';
import 'package:fushi/src/media/novel/online/lnreader_source_browse_page.dart';
import 'package:fushi/src/media/novel/online/novel_online_sources_gate.dart';
import 'package:fushi/src/pages/implementations/media_sources_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 小说在线源（LNReader）真 app 端到端取证：内置官方仓库 → 装真 Syosetu 插件 →
/// headless WebView 里跑插件（热门 / 详情 / 章节）→ 下载三章成 EPUB 真入库。
///
/// 走**真网络**（官方仓库 + syosetu.com），只有显式跑它时才打；页面都用
/// `navigatorKey` 确定性压栈，截图证明版式与漫画 / 视频扩展 UI 一致。
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

  Future<void> push(AppModel appModel, Widget page) async {
    unawaited(
      appModel.navigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => page),
      ),
    );
  }

  Future<void> popAll(WidgetTester tester, AppModel appModel) async {
    appModel.navigatorKey.currentState!.popUntil(
      (Route<dynamic> route) => route.isFirst,
    );
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('LNReader：内置仓库 → 装 Syosetu → 浏览 / 详情 → 下载三章入书架', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    expect(isNovelOnlineSourcesAvailable, isTrue);

    // ① 书导入页：本地段之外多出仓库 / 扩展 / 在线源三段（与视频同一条选择器）。
    await push(
      appModel,
      const Scaffold(body: MediaSourcesPage(mediaKind: 'book')),
    );
    expect(
      await until(
        tester,
        () =>
            find
                .byKey(const ValueKey<String>('import_segment_extensions'))
                .evaluate()
                .isNotEmpty,
      ),
      isTrue,
      reason: '书导入页应出现「扩展」段',
    );
    await captureFlutterFrame(tester, 'lnreader-01-book-import-segments');
    await popAll(tester, appModel);

    // ② 内置官方仓库真刷新出目录。
    final LnReaderManager manager = appModel.lnReaderManager;
    await settle(tester, manager.initialise());
    await settle(tester, manager.refreshStores());
    debugPrint(
      '[lnreader-itest] stores=${manager.stores.map((LnReaderStore s) => '${s.indexUrl} err=${s.lastError}').toList()} '
      'available=${manager.available.length}',
    );
    final LnReaderRepoPlugin syosetu = manager.available.firstWhere(
      (LnReaderRepoPlugin p) => p.id == 'yomou.syosetu',
    );

    await push(
      appModel,
      Scaffold(
        body: CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: SliverMainAxisGroup(
                slivers: <Widget>[
                  LnReaderExtensionsSection(
                    manager: manager,
                    showStores: true,
                    showCatalog: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    await captureFlutterFrame(tester, 'lnreader-02-stores-and-catalog');
    await popAll(tester, appModel);

    // ③ 安装真插件。
    await settle(tester, manager.install(syosetu));
    final LnReaderInstalledPlugin installed = manager.installedById(
      'yomou.syosetu',
    )!;
    await push(
      appModel,
      Scaffold(
        body: CustomScrollView(
          slivers: <Widget>[
            SliverPadding(
              padding: const EdgeInsets.all(16),
              sliver: LnReaderInstalledSourcesSection(
                manager: manager,
                onOpenSource: (_) {},
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await captureFlutterFrame(tester, 'lnreader-03-installed-sources');
    await popAll(tester, appModel);

    // ④ 浏览页：真 headless WebView 跑插件的 popularNovels。
    await push(
      appModel,
      LnReaderSourceBrowsePage(manager: manager, plugin: installed),
    );
    final Finder firstCard = find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('novel_browse_item_'),
    );
    expect(
      await until(tester, () => firstCard.evaluate().isNotEmpty),
      isTrue,
      reason: '热门列表应在 90s 内出现（插件真跑通）',
    );
    await captureFlutterFrame(tester, 'lnreader-04-browse');
    final LnReaderPluginInfo info = await settle(
      tester,
      manager.load(installed),
    );
    final List<LnReaderNovelItem> popular = await settle(
      tester,
      manager.runtime.popular(installed.id, page: 1, latest: false),
    );
    debugPrint(
      '[lnreader-itest] popular=${popular.length} first=${popular.first.name} filters=${info.filters.length}',
    );
    await popAll(tester, appModel);

    // ⑤ 详情页：真目录。
    final LnReaderNovelItem item = popular.first;
    await push(
      appModel,
      LnReaderNovelDetailPage(
        manager: manager,
        plugin: installed,
        item: item,
        imageHeaders: info.imageHeaders,
      ),
    );
    expect(
      await until(
        tester,
        () => find
            .byKey(const ValueKey<String>('novel_detail_library_add'))
            .evaluate()
            .isNotEmpty &&
            find.byType(ListView).evaluate().isNotEmpty &&
            find.textContaining('第').evaluate().length > 2,
      ),
      isTrue,
    );
    await captureFlutterFrame(tester, 'lnreader-05-detail');
    await popAll(tester, appModel);

    // ⑥ 下载前三章 → EPUB → 真入库。
    final LnReaderNovel novel = await settle(
      tester,
      manager.runtime.novel(installed.id, item.path),
    );
    debugPrint(
      '[lnreader-itest] novel=${novel.name} chapters=${novel.chapters.length}',
    );
    final List<LnReaderChapter> first3 = novel.chapters.take(3).toList();
    final String bookKey = await settle(
      tester,
      LnReaderBookDownload(
        manager: manager,
        database: appModel.database,
        httpClientFactory: createAppHttpClient,
      ).run(
        plugin: installed,
        novel: novel,
        chapters: first3,
        policy: const DuplicatePolicy.suffix(),
      ),
    );
    final EpubBookRow? row = await settle(
      tester,
      appModel.database.getEpubBook(bookKey),
    );
    debugPrint(
      '[lnreader-itest] imported bookKey=$bookKey chapters=${row?.chapterCount} title=${row?.title}',
    );
    expect(row, isNotNull);
    expect(row!.chapterCount, 3);
    expect(t.novel_download_done(title: novel.name), isNotEmpty);
  });
}
