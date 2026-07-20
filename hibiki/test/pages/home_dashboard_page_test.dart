import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_dashboard_page.dart';
import 'package:hibiki/src/platform/platform_providers.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki/src/utils/components/stat_contribution_heatmap.dart';
import 'package:hibiki/src/utils/misc/hibiki_time_format.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 首页仪表盘布局回归：**宽屏（PC/横屏）曾因把 stretch/Expanded 的 Row 直接放进纵向
/// ListView（高度无界）而在 layout 阶段抛「BoxConstraints forces an infinite height」，
/// 导致整页空白**。本测试锁死宽/窄两分支渲染都不抛异常、各区块结构可见。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_dashboard_pp');
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
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late HibikiDatabase db;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_dashboard');
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
          // 覆盖书列表 provider：真实实现依赖 _epubBookKeysProvider 的 drift .watch()
          // 流，会让 widget 测试进程永不终止（drift watch teardown 挂起 gotcha）。本
          // 测试聚焦布局不崩 + 视频继续/热力图/活动渲染，书列表用空值即可。
          hibikiBooksProvider
              .overrideWith((ref, language) async => <MediaItem>[]),
          bookLastReadAtProvider.overrideWith((ref) async => <String, int>{}),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: HomeDashboardPage(videoRepo: VideoBookRepository(db)),
            ),
          ),
        ),
      );

  // 有界 pump：不用 pumpAndSettle（真实 DB isolate + FutureProvider 在 fakeAsync 下
  // 不会 settle，会挂起）。三帧足够跑完 build + initState 异步载入回填。
  Future<void> pumpDashboard(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> seedSampleData() async {
    final DateTime now = DateTime.now();
    final String todayKey = HibikiTimeFormat.dayKey(now);
    await db.addReadingStatistic(
      title: '吾輩は猫である',
      dateKey: todayKey,
      charsRead: 800,
      timeMs: 600000,
    );
    await db.addActivityEvent(
      eventType: kActivityRead,
      mediaType: kActivityMediaBook,
      title: '活动书名',
      dateKey: todayKey,
      timestampMs: now.millisecondsSinceEpoch,
      durationMs: 600000,
      charsDelta: 800,
    );
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/keep-watching'),
      title: Value('继续看的视频'),
      videoPath: Value('/abs/keep.mp4'),
      lastPositionMs: Value(754000),
    ));
  }

  testWidgets('宽屏（1280）有数据：渲染不抛无限高度，四区块结构可见', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 四区块标题结构可见（不依赖异步数据回填即渲染）。
    expect(find.text(t.home_continue), findsOneWidget);
    expect(find.text(t.reading_activity), findsOneWidget);
    expect(find.text(t.home_activity), findsOneWidget);
    expect(find.byType(StatContributionHeatmap), findsOneWidget);
  });

  testWidgets('窄屏（420）空 DB：堆叠分支渲染不抛异常', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(StatContributionHeatmap), findsOneWidget);
    expect(find.text(t.home_activity), findsOneWidget);
  });

  testWidgets('宽屏 560~900 临界（4 格横排统计卡）不抛无限高度', (WidgetTester tester) async {
    // 700px：走「统计卡 4 格横排」但「主体单列堆叠」——曾是 stretch Row 崩溃点。
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.byType(StatContributionHeatmap), findsOneWidget);
  });
}
