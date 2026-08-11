// Windows 真 runner 的下载中心宽屏验收：在隔离数据库播种稳定任务/订阅，
// 逐页断言任务、订阅、设置占满内容区，并抓取 Flutter 图层证据；最后推入
// 发现订阅独立路由，确认它与资源搜索一样是全屏页面而非居中弹窗。

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/main.dart' as app;
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi/src/media/video/download/video_resource_registry.dart';
import 'package:fushi/src/media/video/metadata/video_metadata_models.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/downloads_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomePage, HomeTab;
import 'package:fushi/src/pages/implementations/torrent_settings_section.dart';
import 'package:fushi/src/pages/implementations/video_discovery_acquisition_dialogs.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/library_fixture.dart' show readyAppModel;
import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'test_helpers.dart';

Future<void> _pumpFrames(
  WidgetTester tester, {
  int frames = 8,
}) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _seedDownloadRows(AppModel model) async {
  final int now = DateTime.now().millisecondsSinceEpoch;
  await model.database.upsertVideoDownloadJob(
    VideoDownloadJobsCompanion(
      jobId: const Value<String>('full-width-itest-job'),
      resourceProvider: const Value<String>('nyaa:default'),
      selectedResourceId: const Value<String>('full-width-release'),
      resourceTitle: const Value<String>(
        '[Group] Full Width Verification S01E03 1080p',
      ),
      metadataProvider: const Value<String?>('anilist'),
      externalId: const Value<String?>('100'),
      mediaKind: const Value<String>('tv'),
      discoveryCategory: const Value<String?>('anime'),
      title: const Value<String>('Full Width Download Verification'),
      year: const Value<int?>(2026),
      season: const Value<int?>(1),
      backendKind: const Value<String>('embedded'),
      fingerprint: const Value<String>('embedded-full-width-itest'),
      category: const Value<String?>('fushi-video'),
      lifecycle: const Value<String>(VideoDownloadJobLifecycle.completed),
      stage: const Value<String>(VideoDownloadJobStage.scrape),
      stageProgress: const Value<double>(1),
      createdAt: Value<int>(now),
      updatedAt: Value<int>(now),
      completedAt: Value<int?>(now),
    ),
  );
  await model.database.upsertVideoDownloadSubscription(
    VideoDownloadSubscriptionsCompanion.insert(
      subscriptionId: 'full-width-itest-subscription',
      resourceProvider: 'nyaa:default',
      metadataProvider: const Value<String?>('anilist'),
      externalId: const Value<String?>('100'),
      mediaKind: 'tv',
      discoveryCategory: const Value<String?>('anime'),
      title: 'Full Width Subscription Verification',
      year: const Value<int?>(2026),
      season: const Value<int?>(1),
      searchQuery: 'Full Width Subscription Verification',
      filterJson: const Value<String>(
        '{"strict":true,"releaseGroup":"Group","resolution":"1080p"}',
      ),
      backendKind: 'embedded',
      fingerprint: 'embedded-full-width-itest',
      category: const Value<String?>('fushi-video'),
      enabled: const Value<bool>(false),
      createdAt: now,
      updatedAt: now,
    ),
  );
}

Future<void> _expectShot(
  WidgetTester tester,
  String name,
) async {
  final ObserveShot shot = await captureFlutterFrame(tester, name);
  expect(shot.saved, isTrue, reason: '$name should be saved');
  expect(shot.nonBlank, isTrue, reason: '$name should not be blank');
  expect(shot.bytes, greaterThan(10000));
}

Future<void> _activateTab(
  WidgetTester tester,
  FocusDriver focus,
  Finder tab,
) async {
  expect(await focus.focusWidget(tab), isTrue);
  await focus.activate();
  await _pumpFrames(tester);
}

VideoDiscoveryItem _discoveryItem() => VideoDiscoveryItem(
      reference: VideoMediaReference(
        providerId: 'anilist',
        mediaId: '100',
        mediaKind: VideoMetadataMediaKind.tv,
        discoveryCategory: VideoDiscoveryCategory.anime,
        title: 'Full Width Subscription Verification',
        originalTitle: '全幅購読テスト',
        aliases: const <String>['Full Width Subscription Verification'],
        year: 2026,
        anilistId: 100,
      ),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('下载中心与发现订阅在 Windows 真 app 中全宽显示', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[full-width-itest] ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue);
      final AppModel model = await readyAppModel(tester);
      await enableFocusNavigation(tester);
      final FocusDriver focus = FocusDriver(tester);
      await _seedDownloadRows(model);

      expect(HomePage.debugSelectTab, isNotNull);
      HomePage.debugSelectTab!(HomeTab.downloads);
      await _pumpFrames(tester);

      final Size downloadsSize = tester.getSize(find.byType(DownloadsPage));
      expect(downloadsSize.width, greaterThan(900));
      final Finder tabs = find.byType(Tab);
      expect(tabs, findsNWidgets(4));

      await _activateTab(tester, focus, tabs.at(1));
      final Finder jobCard = find.byKey(
        const ValueKey<String>('video-download-job-full-width-itest-job'),
      );
      expect(jobCard, findsOneWidget);
      expect(
        tester.getSize(jobCard).width,
        greaterThan(downloadsSize.width * 0.9),
      );
      expect(
        find.text(t.anime_download_no_tasks),
        findsNothing,
        reason: '旧番剧队列为空时不得显示第二个空态并遮挡新版任务列表',
      );
      await _expectShot(tester, 'subscription-download-full-width-tasks');

      await _activateTab(tester, focus, tabs.at(2));
      final Finder subscriptionCard = find.byKey(
        const ValueKey<String>(
          'video-subscription-card-full-width-itest-subscription',
        ),
      );
      expect(subscriptionCard, findsOneWidget);
      expect(
        tester.getSize(subscriptionCard).width,
        greaterThan(downloadsSize.width * 0.9),
      );
      await _expectShot(
        tester,
        'subscription-download-full-width-subscriptions',
      );

      await _activateTab(tester, focus, tabs.at(3));
      final Finder settings = find.byType(TorrentSettingsSection);
      expect(settings, findsOneWidget);
      expect(
        tester.getSize(settings).width,
        greaterThan(downloadsSize.width * 0.9),
      );
      await _expectShot(tester, 'subscription-download-full-width-settings');

      final NavigatorState navigator =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => VideoDiscoverySubscriptionPage(
            item: _discoveryItem(),
            registry: VideoResourceRegistry(
              const <VideoResourceProvider>[],
            ),
            sources: const <MediaSourceRow>[
              MediaSourceRow(
                id: 1,
                label: 'itest-video-library',
                mediaKind: 'video',
                transport: 'local',
                rootPath: r'D:\itest-video-library',
                mediaCount: 0,
                recursive: true,
                sortOrder: 0,
                createdAt: 1,
              ),
            ],
            defaultSourceId: 1,
            onSubmit: (_) async {},
          ),
        ),
      );
      await _pumpFrames(tester);
      final Finder subscriptionPage =
          find.byType(VideoDiscoverySubscriptionPage);
      expect(subscriptionPage, findsOneWidget);
      expect(
        tester.getSize(subscriptionPage).width,
        greaterThan(downloadsSize.width + 60),
        reason: '独立路由应覆盖左侧主导航，而不只占下载模块内容区',
      );
      await _expectShot(tester, 'discovery-subscription-full-screen');

      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
