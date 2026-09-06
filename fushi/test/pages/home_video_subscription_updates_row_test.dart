import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 视频首页「已更新未看」行（订阅的番剧「更新了就看，跟收菜一样」）的行为门：
///
/// * 订阅（Drift `video_download_subscriptions`）经条目 → 任务 → 合集落到库里的
///   作品，有集没看 → 出现在本行，副标题写目标集 + 未看数，点开播的是 Next-Up
///   那一集；
/// * 同样的合集**没有订阅** → 不进本行（这一行只装订阅过的作品）；
/// * 订阅作品全看完 → 不进本行。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_home_subscription_row_pp',
    );
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (pathProviderDir.existsSync()) {
      try {
        pathProviderDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync(
      'fushi_home_subscription_row_store',
    );
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: HomeVideoPage(
                repo: VideoBookRepository(db),
                section: VideoLibrarySection.home,
              ),
            ),
          ),
        ),
      );

  Future<void> sizeUp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 三集合集：第 1 集看完、第 2 集看完（最近播放）、第 3 集没看。
  /// [allWatched] = 第 3 集也看完。
  Future<int> seedCollection({required bool allWatched}) async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final int cid = await db.createMediaCollection(
      'MyShow',
      collectionType: 'collection',
    );
    for (int ep = 1; ep <= 3; ep++) {
      final bool watched = ep < 3 || allWatched;
      await db.upsertVideoBook(
        VideoBooksCompanion(
          bookUid: Value<String>('video/ep$ep'),
          title: Value<String>('Ep$ep'),
          videoPath: Value<String>('/abs/ep$ep.mp4'),
          importedAt: Value<int?>(nowMs - (4 - ep) * 1000),
          lastPlayedAt: Value<int?>(watched ? nowMs - (4 - ep) * 500 : null),
          completedAt: Value<DateTime?>(
            watched ? DateTime.fromMillisecondsSinceEpoch(nowMs) : null,
          ),
        ),
      );
      await db.addToCollection(cid, MediaKind.video, 'video/ep$ep');
    }
    return cid;
  }

  /// 订阅 → 条目 → 已入库任务（`collectionId` 回写）→ 合集。
  Future<void> seedSubscription(int cid) async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.upsertVideoDownloadSubscription(
      VideoDownloadSubscriptionsCompanion.insert(
        subscriptionId: 'sub-myshow',
        resourceProvider: 'nyaa',
        mediaKind: 'tv',
        title: 'MyShow',
        searchQuery: 'MyShow',
        backendKind: 'embedded',
        fingerprint: 'fp',
        createdAt: nowMs,
        updatedAt: nowMs,
      ),
    );
    await db.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: 'job-ep3',
        resourceProvider: 'nyaa',
        selectedResourceId: 'r-ep3',
        mediaKind: 'tv',
        title: 'MyShow',
        backendKind: 'embedded',
        fingerprint: 'fp-ep3',
        collectionId: Value<int?>(cid),
        lifecycle: const Value<String>(VideoDownloadJobLifecycle.completed),
        createdAt: nowMs,
        updatedAt: nowMs,
      ),
    );
    await db.upsertVideoDownloadSubscriptionItem(
      VideoDownloadSubscriptionItemsCompanion.insert(
        subscriptionId: 'sub-myshow',
        logicalItemKey: 's1e3',
        resourceProvider: 'nyaa',
        selectedResourceId: 'r-ep3',
        title: 'MyShow - 03',
        jobId: const Value<String?>('job-ep3'),
        status: const Value<String>(
          VideoDownloadSubscriptionItemStatus.processed,
        ),
        discoveredAt: nowMs,
        updatedAt: nowMs,
      ),
    );
  }

  testWidgets('订阅作品有集没看 → 出现在「已更新未看」行，目标是第 3 集、1 集未看', (
    WidgetTester tester,
  ) async {
    await sizeUp(tester);
    final int cid = await seedCollection(allWatched: false);
    await seedSubscription(cid);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text(t.video_home_subscription_updates), findsOneWidget);
    expect(
      find.byKey(ValueKey<String>('home_video_subscription_collection_$cid')),
      findsOneWidget,
      reason: '订阅过、且第 3 集没看 → 合集卡必须在本行',
    );
    expect(
      find.text(t.video_home_subscription_unwatched_episode(n: 3, count: 1)),
      findsOneWidget,
      reason: 'Next-Up：最近播放是第 2 集，目标第 3 集；未看数 1',
    );
  });

  testWidgets('同样的合集没有订阅 → 不进本行', (WidgetTester tester) async {
    await sizeUp(tester);
    final int cid = await seedCollection(allWatched: false);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text(t.video_home_subscription_updates), findsNothing);
    expect(
      find.byKey(ValueKey<String>('home_video_subscription_collection_$cid')),
      findsNothing,
      reason: '本行只装订阅过的作品，普通合集有未看集也不进',
    );
  });

  testWidgets('订阅作品全看完 → 不进本行', (WidgetTester tester) async {
    await sizeUp(tester);
    final int cid = await seedCollection(allWatched: true);
    await seedSubscription(cid);

    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text(t.video_home_subscription_updates), findsNothing);
    expect(
      find.byKey(ValueKey<String>('home_video_subscription_collection_$cid')),
      findsNothing,
      reason: '收完的菜不该再摆在「已更新未看」里',
    );
  });
}
