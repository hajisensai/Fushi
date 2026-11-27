// 视频库页 initState 半途抛错时，后台任务不得在孤儿 State 上读 ref。
//
// initState 抛错时 Flutter 把这个元素停用（`_deactivateFailedChildSilently`）
// 但**永远不调 dispose**、`mounted` 也一直是 true。旧代码在 initState 前半段就
// 起了自动刮削 / 远端清单等后台任务，它们只认 `mounted`，之后在停用的元素上
// `ref.read` → 「Looking up a deactivated widget's ancestor is unsafe」（BUG-5602）。
// 修法：后台任务改在 initState 的同步装配全部完成后才起，自动刮削服务的闭包改读
// 挂载时缓存的 AppModel。
//
// 第二条（BUG-5604）：抛错点之前挂上的订阅 / 监听 / 落点也必须回滚——框架不调
// dispose，靠 StateResourceScope 的失败路径撤销；之后库表变化、切 tab 都不再触达
// 孤儿 State。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/pages/implementations/video_library_drop_port.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_video_failed_mount_pp',
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
    storeDir = Directory.systemTemp.createTempSync('fushi_video_failed_mount');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  testWidgets('initState 半途抛错：后台任务不在停用的元素上读 ref', (WidgetTester tester) async {
    // 本地库里有一本兼容导入的本地视频，自动刮削那一轮真的会跑到底。
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/loose',
        title: '散片',
        videoPath: '/abs/video/loose.mp4',
      ),
    );

    await tester.pumpWidget(
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
                section: VideoLibrarySection.allVideos,
                // 让 initState 在挂库页刷新信号那一步抛错（代表装配中任何一步失败）。
                libraryRefreshSignal: _ThrowingListenable(),
              ),
            ),
          ),
        ),
      ),
    );
    final Object? mountError = tester.takeException();
    expect(
      mountError.toString(),
      contains(_ThrowingListenable.message),
      reason: '前置：initState 确实半途抛错',
    );

    // 让已起的后台任务（库查询 → 自动刮削一轮 → 远端清单）都走完。旧代码在这里
    // 由异步区抛出「deactivated widget's ancestor」，测试框架直接判红。
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 700));
    }
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets('initState 半途抛错：抛错点之前挂上的订阅与监听全部回滚（BUG-5604）', (
    WidgetTester tester,
  ) async {
    final HomeTab tabBefore = homeShellTabNotifier.value;
    addTearDown(() => homeShellTabNotifier.value = tabBefore);
    final VideoLibraryDropPort dropPort = VideoLibraryDropPort();

    await tester.pumpWidget(
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
                section: VideoLibrarySection.allVideos,
                importDropPort: dropPort,
                libraryRefreshSignal: _ThrowingListenable(),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      tester.takeException().toString(),
      contains(_ThrowingListenable.message),
      reason: '前置：initState 确实半途抛错',
    );
    // 落点处理在抛错点之前挂上：不回滚的话导入视图的拖放会交给一个孤儿页。
    expect(dropPort.attached, isFalse, reason: '导入落点已撤下');
    await tester.pump(const Duration(milliseconds: 700));
    expect(tester.takeException(), isNull);

    // 库表变化（uid 集合 / 合集表订阅）与切回视频 tab（基类的 shell tab 监听）都
    // 发生在失败之后：订阅已取消、监听已摘，孤儿 State 收不到，不会再读 ref。
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/late',
        title: '后来入库',
        videoPath: '/abs/video/late.mp4',
      ),
    );
    homeShellTabNotifier.value = HomeTab.video == tabBefore
        ? HomeTab.values.firstWhere((HomeTab t) => t != HomeTab.video)
        : tabBefore;
    homeShellTabNotifier.value = HomeTab.video;
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 700));
    }
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });
}

/// 一挂监听就抛错的信号：模拟 initState 装配半途失败。
class _ThrowingListenable implements Listenable {
  static const String message = 'simulated initState failure';

  @override
  void addListener(VoidCallback listener) => throw StateError(message);

  @override
  void removeListener(VoidCallback listener) {}
}
