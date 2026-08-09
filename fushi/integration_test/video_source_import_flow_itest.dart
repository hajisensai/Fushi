import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/main.dart' as app;
import 'package:fushi/models.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/metadata/scrape_batch.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/media_library_shell.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('视频来源添加文件夹、自动归组、即时回库与全部刮削', (WidgetTester tester) async {
    final Directory fixture =
        Directory.systemTemp.createTempSync('fushi_video_source_itest_');
    addTearDown(() {
      debugRealDirectoryPathOverride = null;
      if (fixture.existsSync()) fixture.deleteSync(recursive: true);
    });
    final Directory nested = Directory(p.join(fixture.path, 'Show', 'Season 1'))
      ..createSync(recursive: true);
    File(p.join(nested.path, 'ITest Show S01E02.mkv'))
        .writeAsBytesSync(<int>[0]);
    File(p.join(nested.path, 'ITest Show S01E01.mkv'))
        .writeAsBytesSync(<int>[0]);
    debugRealDirectoryPathOverride = fixture.path;

    await runFushiItest(
      label: 'video-source-import',
      body: () async {
        app.main();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        final AppModel appModel = await enableFocusNavigation(tester);
        await appModel.setVideoAutoScrape(false);
        final FocusDriver driver = FocusDriver(tester);

        expect(HomePage.debugSelectTab, isNotNull);
        HomePage.debugSelectTab!(HomeTab.video);
        expect(
          await _waitFor(
            tester,
            () => find
                .byType(FushiAdjustableSegmented<MediaLibraryViewKind>)
                .evaluate()
                .isNotEmpty,
          ),
          isTrue,
          reason: '视频库视图导航应出现',
        );

        final Finder navigation =
            find.byType(FushiAdjustableSegmented<MediaLibraryViewKind>);
        expect(await driver.focusWidget(navigation), isTrue);
        await driver.adjust(steps: 1); // 媒体库 → 来源

        final Finder addSource = find.byWidgetPredicate(
          (Widget widget) =>
              widget is FushiIconButton &&
              widget.tooltip == t.media_source_add,
        );
        expect(await _waitFor(tester, () => addSource.evaluate().isNotEmpty),
            isTrue);
        expect(await driver.focusWidget(addSource), isTrue);
        await driver.activate();

        expect(
          await _waitFor(tester, () async {
            final List<VideoBookRow> videos =
                await appModel.database.allVideoBooks();
            final List<MediaCollectionRow> collections =
                await appModel.database.getAllMediaCollections();
            return videos.length == 2 &&
                collections.length == 1 &&
                collections.single.name == 'ITest Show';
          }, maxTicks: 160),
          isTrue,
          reason: '添加来源后应递归扫描两集并自动形成一个作品合集',
        );
        final ObserveShot sourcesShot =
            await captureFlutterFrame(tester, 'video-source-after-scan');
        expect(sourcesShot.saved && sourcesShot.nonBlank, isTrue);

        expect(await driver.focusWidget(navigation), isTrue);
        await driver.adjust(steps: -1); // 来源 → 媒体库
        expect(
          await _waitFor(
            tester,
            () => find.text('ITest Show').evaluate().isNotEmpty,
          ),
          isTrue,
          reason: '切回保活媒体库后应立即看到新合集，无需重启或手动刷新',
        );
        final ObserveShot libraryShot =
            await captureFlutterFrame(tester, 'video-library-after-scan');
        expect(libraryShot.saved && libraryShot.nonBlank, isTrue);

        expect(await driver.focusWidget(navigation), isTrue);
        await driver.adjust(steps: 1); // 媒体库 → 来源
        final Finder scrapeAll = find.byWidgetPredicate(
          (Widget widget) =>
              widget is FushiIconButton && widget.tooltip == t.scrape_all,
        );
        expect(await _waitFor(tester, () => scrapeAll.evaluate().isNotEmpty),
            isTrue);
        expect(await driver.focusWidget(scrapeAll), isTrue);
        await driver.activate();
        expect(
          await _waitFor(
            tester,
            () => find.byType(ScrapeBatchDialog).evaluate().isNotEmpty,
          ),
          isTrue,
          reason: '来源页全部刮削应打开共享视频批处理弹窗',
        );
        final ObserveShot scrapeShot =
            await captureFlutterFrame(tester, 'video-source-scrape-dialog');
        expect(scrapeShot.saved && scrapeShot.nonBlank, isTrue);

        // 真实批处理会访问在线元数据源，Windows UI 验收只验证入口、依赖组装与弹窗；
        // 覆盖保护和逐项结果由 CoverScraperService / scrape batch 定向测试验证。
        final Finder cancel = find.text(t.dialog_cancel);
        expect(await driver.focusWidget(cancel), isTrue);
        await driver.activate();
        expect(
          await _waitFor(
            tester,
            () => find.byType(ScrapeBatchDialog).evaluate().isEmpty,
          ),
          isTrue,
        );
      },
    );
  });
}

Future<bool> _waitFor(
  WidgetTester tester,
  FutureOr<bool> Function() predicate, {
  int maxTicks = 80,
}) async {
  for (int i = 0; i < maxTicks; i++) {
    if (await predicate()) return true;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return false;
}
