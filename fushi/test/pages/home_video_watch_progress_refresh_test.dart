import 'dart:async' show unawaited;
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show HomeTab, homeShellTabNotifier;
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-3610：从合集详情页播放 → 退回详情页 → 再退回视频媒体库，库页卡片上的
/// 观看进度停在旧值（看到第 7 集仍显示第 6 集），要下拉同步或杀进程才刷新。
///
/// 根因：库页列表是一次性快照，只有库页**自己**点开播放（`_open`）返回时才重读；
/// 从详情页 / 首页等别的入口播放、或同步回灌写下的进度，库页的 uid 集合监听按
/// 集合去重刻意忽略。修复后库页订阅数据层的「观看进度变了」信号：在前台立即重读，
/// 被盖住时记一笔、露出来时重读。
///
/// 这里不经播放页，直接往库里写进度（与播放页 / 同步回灌落库同一批 DB 写入），
/// 断言库页「继续观看」行跟着变。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_home_watch_progress_pp',
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
    // 本页只在「视频 tab 是当前 tab 且路由在栈顶」时立即重读进度。
    homeShellTabNotifier.value = HomeTab.video;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync(
      'fushi_home_watch_progress_store',
    );
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    homeShellTabNotifier.value = HomeTab.home;
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp({VideoLibrarySection section = VideoLibrarySection.home}) =>
      ProviderScope(
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
                section: section,
              ),
            ),
          ),
        ),
      );

  Future<void> pumpHome(
    WidgetTester tester, {
    VideoLibrarySection section = VideoLibrarySection.home,
  }) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(section: section));
    await tester.pumpAndSettle();
  }

  Future<void> seedEpisode(
    String uid,
    String title, {
    int positionMs = 0,
    bool completed = false,
    int? lastPlayedAt,
  }) => db.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(title),
      videoPath: Value<String>('/abs/$title.mp4'),
      lastPositionMs: Value<int>(positionMs),
      completedAt: Value<DateTime?>(completed ? DateTime.now() : null),
      lastPlayedAt: Value<int?>(lastPlayedAt),
    ),
  );

  Finder nextUpText(int cid, int n, {bool skipOffstage = true}) =>
      find.descendant(
        of: find.byKey(
          ValueKey<String>('home_video_continue_collection_$cid'),
          skipOffstage: skipOffstage,
        ),
        matching: find.text(
          t.video_home_next_episode_number(n: n),
          skipOffstage: skipOffstage,
        ),
        skipOffstage: skipOffstage,
      );

  /// 三集的番：第 1 集看完 → 继续观看行指向「下一集 · 第 2 集」。
  Future<int> seedShow() async {
    final int cid = await db.createMediaCollection(
      'Progress Show',
      collectionType: 'playlist',
    );
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await seedEpisode(
      'video/ps-ep1',
      'PS Ep1',
      positionMs: 1,
      completed: true,
      lastPlayedAt: nowMs - 60000,
    );
    await seedEpisode('video/ps-ep2', 'PS Ep2');
    await seedEpisode('video/ps-ep3', 'PS Ep3');
    for (final String uid in <String>[
      'video/ps-ep1',
      'video/ps-ep2',
      'video/ps-ep3',
    ]) {
      await db.addToCollection(cid, MediaKind.video, uid);
    }
    return cid;
  }

  /// 别处把第 2 集看完了：与播放页退出落库同一批写入（断点 + 时刻 + 看完）。
  Future<void> watchEpisode2ToEnd() async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.updateVideoBookPosition('video/ps-ep2', 1, playedAt: nowMs);
    await db.markVideoCompleted('video/ps-ep2', DateTime.now());
  }

  testWidgets('库页在前台时，别处写下的观看进度立即反映到卡片上', (WidgetTester tester) async {
    final int cid = await seedShow();
    await pumpHome(tester);
    expect(nextUpText(cid, 2), findsOneWidget);

    await watchEpisode2ToEnd();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(
      nextUpText(cid, 3),
      findsOneWidget,
      reason: '第 2 集已看完，库页不下拉刷新也应指向第 3 集',
    );
    expect(nextUpText(cid, 2), findsNothing);
  });

  testWidgets('库页被详情页 / 播放页盖住时写下的进度，退回库页即刷新', (WidgetTester tester) async {
    final int cid = await seedShow();
    await pumpHome(tester);
    expect(nextUpText(cid, 2), findsOneWidget);

    // 模拟「库页 → 合集详情页 → 播放页」：库页路由被盖住。
    final NavigatorState navigator = tester.state<NavigatorState>(
      find.byType(Navigator),
    );
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('detail')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await watchEpisode2ToEnd();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(
      nextUpText(cid, 2, skipOffstage: false),
      findsOneWidget,
      reason: '被盖住期间不在后台重列书架，只记一笔',
    );

    navigator.pop();
    await tester.pumpAndSettle();

    expect(
      nextUpText(cid, 3),
      findsOneWidget,
      reason: '退回库页时补做被推迟的进度重读，不需要下拉同步',
    );
    expect(nextUpText(cid, 2), findsNothing);
  });

  testWidgets('非进度列的写入（封面回写）不触发库页重读', (WidgetTester tester) async {
    final int cid = await seedShow();
    await pumpHome(tester);
    expect(nextUpText(cid, 2), findsOneWidget);

    // 直接改库但只动封面列：进度信号不发，卡片维持原样（防自愈回写重刷环）。
    await db.updateVideoBookCover('video/ps-ep2', '/abs/cover.jpg');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(nextUpText(cid, 2), findsOneWidget);
  });
}
