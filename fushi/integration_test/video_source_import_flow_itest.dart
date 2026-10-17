import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'support/test_app_launcher.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
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
    final Directory fixture = Directory.systemTemp.createTempSync(
      'fushi_video_source_itest_',
    );
    addTearDown(() {
      debugRealDirectoryPathOverride = null;
      if (fixture.existsSync()) fixture.deleteSync(recursive: true);
    });
    final Directory nested = Directory(p.join(fixture.path, 'Show', 'Season 1'))
      ..createSync(recursive: true);
    File(
      p.join(nested.path, 'ITest Show S01E02.mkv'),
    ).writeAsBytesSync(<int>[0]);
    File(
      p.join(nested.path, 'ITest Show S01E01.mkv'),
    ).writeAsBytesSync(<int>[0]);
    debugRealDirectoryPathOverride = fixture.path;

    await runFushiItest(
      label: 'video-source-import',
      body: () async {
        await launchFushiTestApp();
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
                .byType(FushiAdjustableSegmented<VideoLibrarySection>)
                .evaluate()
                .isNotEmpty,
          ),
          isTrue,
          reason: '视频库视图导航应出现',
        );

        // 顶栏是分组（媒体库 / 发现 / 媒体服务器 / 在线源 / 导入），媒体库组内
        // 的首页 / 系列 / 全部视频在二级胶囊里：两个焦点停靠点各走各的。
        await _stepVideoSections(
          tester,
          driver,
          _kVideoSubNav,
          expected: const <VideoLibrarySection>[
            VideoLibrarySection.series,
            VideoLibrarySection.allVideos,
          ],
          delta: 1,
        );
        await _adjustVideoSectionsUntil(
          tester,
          driver,
          _kVideoTopNav,
          target: VideoLibrarySection.sources,
          delta: 1,
        );

        final Finder addSource = find.byWidgetPredicate(
          (Widget widget) =>
              widget is FushiIconButton && widget.tooltip == t.media_source_add,
        );
        expect(
          await _waitFor(tester, () => addSource.evaluate().isNotEmpty),
          isTrue,
        );
        expect(await driver.focusWidget(addSource), isTrue);
        await driver.activate();

        final Finder localFolder = find.text(t.media_source_add_local_folder);
        expect(
          await _waitFor(tester, () => localFolder.evaluate().isNotEmpty),
          isTrue,
          reason: '添加来源应先出现本地文件夹/网络来源选择',
        );
        expect(await driver.focusWidget(localFolder), isTrue);
        await driver.activate();

        expect(
          await _waitFor(tester, () async {
            final List<VideoBookRow> videos = await appModel.database
                .allVideoBooks();
            final List<MediaCollectionRow> collections = await appModel.database
                .getAllMediaCollections();
            return videos.length == 2 &&
                collections.length == 1 &&
                collections.single.name == 'ITest Show';
          }, maxTicks: 160),
          isTrue,
          reason: '添加来源后应递归扫描两集并自动形成一个作品合集',
        );
        final ObserveShot sourcesShot = await captureFlutterFrame(
          tester,
          'video-source-after-scan',
        );
        expect(sourcesShot.saved && sourcesShot.nonBlank, isTrue);

        // 回到媒体库组（组页签回到组内上次停留的「全部视频」），再在二级胶囊里
        // 退回首页。
        await _adjustVideoSectionsUntil(
          tester,
          driver,
          _kVideoTopNav,
          target: VideoLibrarySection.allVideos,
          delta: -1,
        );
        await _stepVideoSections(
          tester,
          driver,
          _kVideoSubNav,
          expected: const <VideoLibrarySection>[
            VideoLibrarySection.series,
            VideoLibrarySection.home,
          ],
          delta: -1,
        );
        expect(
          await _waitFor(
            tester,
            () => find.text('ITest Show').evaluate().isNotEmpty,
          ),
          isTrue,
          reason: '切回保活媒体库后应立即看到新合集，无需重启或手动刷新',
        );
        final ObserveShot libraryShot = await captureFlutterFrame(
          tester,
          'video-library-after-scan',
        );
        expect(libraryShot.saved && libraryShot.nonBlank, isTrue);

        await _adjustVideoSectionsUntil(
          tester,
          driver,
          _kVideoTopNav,
          target: VideoLibrarySection.sources,
          delta: 1,
        );
        final Finder scrapeAll = find.byWidgetPredicate(
          (Widget widget) =>
              widget is FushiIconButton && widget.tooltip == t.scrape_all,
        );
        if (scrapeAll.evaluate().isNotEmpty) {
          expect(await driver.focusWidget(scrapeAll), isTrue);
          await driver.activate();
        } else {
          final Finder moreActions = find.byWidgetPredicate(
            (Widget widget) =>
                widget is FushiIconButton &&
                widget.tooltip == t.common_more_actions,
          );
          expect(
            await _waitFor(tester, () => moreActions.evaluate().isNotEmpty),
            isTrue,
            reason: '窄屏应把来源页动作收进更多操作菜单',
          );
          expect(await driver.focusWidget(moreActions), isTrue);
          await driver.activate();
          final Finder scrapeMenuItem = find.text(t.scrape_all);
          expect(
            await _waitFor(tester, () => scrapeMenuItem.evaluate().isNotEmpty),
            isTrue,
            reason: '更多操作菜单应保留全部刮削能力',
          );
          expect(await driver.focusWidget(scrapeMenuItem), isTrue);
          await driver.activate();
        }
        expect(
          await _waitFor(
            tester,
            () =>
                find.byType(AlertDialog).evaluate().isNotEmpty &&
                find
                    .text(t.video_source_scrape_tasks_open)
                    .evaluate()
                    .isNotEmpty,
          ),
          isTrue,
          reason: '来源页全部刮削应启动后台任务并打开任务面板',
        );
        final ObserveShot scrapeShot = await captureFlutterFrame(
          tester,
          'video-source-scrape-task-panel',
        );
        expect(scrapeShot.saved && scrapeShot.nonBlank, isTrue);

        // 真实任务会访问在线元数据源；本 UI 验收只验证启动、任务面板与观察入口。
        final Finder close = find.text(t.dialog_close);
        expect(await driver.focusWidget(close), isTrue);
        await driver.activate();
        expect(
          await _waitFor(
            tester,
            () => find.byType(AlertDialog).evaluate().isEmpty,
          ),
          isTrue,
        );
      },
    );
  });
}

/// 视频库顶栏分组导航的焦点前缀。
const String _kVideoTopNav = 'video-library-view';

/// 组内二级胶囊（首页 / 系列 / 全部视频；来源 / 扩展）的焦点前缀。
const String _kVideoSubNav = 'video-library-subview';

Finder _videoNav(String prefix) => find.byWidgetPredicate(
  (Widget widget) =>
      widget is FushiAdjustableSegmented<VideoLibrarySection> &&
      widget.focusIdPrefix == prefix,
);

/// 在 [prefix] 那条导航上每步按一次方向键，逐步断言落到 [expected]。
Future<void> _stepVideoSections(
  WidgetTester tester,
  FocusDriver driver,
  String prefix, {
  required List<VideoLibrarySection> expected,
  required int delta,
}) async {
  final Finder navigation = _videoNav(prefix);
  for (final VideoLibrarySection section in expected) {
    expect(
      await driver.requestFocusInside(
        navigation,
        debugLabelContains: '$prefix-sections',
      ),
      isTrue,
    );
    await driver.adjust(steps: delta);
    expect(
      await _waitFor(
        tester,
        () =>
            tester
                .widget<FushiAdjustableSegmented<VideoLibrarySection>>(
                  navigation,
                )
                .selected ==
            section,
      ),
      isTrue,
      reason: '视频库分段导航应逐步切到 $section',
    );
  }
}

/// 在 [prefix] 那条导航上按方向键直到选中 [target]（中间经过哪些分组随平台合规门
/// 增减，不逐步钉死）。
Future<void> _adjustVideoSectionsUntil(
  WidgetTester tester,
  FocusDriver driver,
  String prefix, {
  required VideoLibrarySection target,
  required int delta,
}) async {
  final Finder navigation = _videoNav(prefix);
  for (int step = 0; step < 8; step++) {
    if (tester
            .widget<FushiAdjustableSegmented<VideoLibrarySection>>(navigation)
            .selected ==
        target) {
      return;
    }
    expect(
      await driver.requestFocusInside(
        navigation,
        debugLabelContains: '$prefix-sections',
      ),
      isTrue,
    );
    final VideoLibrarySection before = tester
        .widget<FushiAdjustableSegmented<VideoLibrarySection>>(navigation)
        .selected;
    await driver.adjust(steps: delta);
    expect(
      await _waitFor(
        tester,
        () =>
            tester
                .widget<FushiAdjustableSegmented<VideoLibrarySection>>(
                  navigation,
                )
                .selected !=
            before,
      ),
      isTrue,
      reason: '视频库顶栏导航应离开 $before',
    );
  }
  fail('视频库顶栏导航 8 步内没有走到 $target');
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
