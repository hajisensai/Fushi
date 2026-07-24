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
import 'package:hibiki/src/pages/implementations/home_page.dart'
    show homeShellTabNotifier, HomeTab;
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

  Widget buildApp({
    Future<void> Function(
      BuildContext context,
      VideoBookRepository repo,
      String bookUid,
      int? playlistCollectionId,
    )? openVideoOverride,
  }) =>
      ProviderScope(
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
              body: HomeDashboardPage(
                videoRepo: VideoBookRepository(db),
                openVideoOverride: openVideoOverride,
              ),
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

  testWidgets('宽屏（1280）有数据：渲染不抛无限高度，三区块结构可见', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 三区块标题结构可见（不依赖异步数据回填即渲染）：阅读活动热力图（置顶）/ 继续 /
    // Activity。原顶部统计卡已移除。
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

  testWidgets('宽屏 1280 + 真实载入数据（异步回填后）：下段两列渲染不抛无限高度',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final DateTime now = DateTime.now();
    for (int i = 0; i < 20; i++) {
      final String dk =
          HibikiTimeFormat.dayKey(now.subtract(Duration(days: i)));
      await db.addReadingStatistic(
        title: '书$i',
        dateKey: dk,
        charsRead: 500 + i * 10,
        timeMs: 300000,
      );
      await db.addActivityEvent(
        eventType: i.isEven ? kActivityRead : kActivityWatch,
        mediaType: i.isEven ? kActivityMediaBook : kActivityMediaVideo,
        title: '活动$i',
        dateKey: dk,
        timestampMs: now.subtract(Duration(days: i)).millisecondsSinceEpoch,
        durationMs: 120000,
      );
    }
    for (int i = 0; i < 3; i++) {
      await db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value('video/watch$i'),
        title: Value('在看$i'),
        videoPath: Value('/abs/w$i.mp4'),
        lastPositionMs: const Value(60000),
      ));
    }

    // runAsync 让真实 DB isolate 的 _loadDashboardData 跑完（fakeAsync 的 pump 不推进
    // 后台 isolate），再退出 runAsync pump 应用 setState → 用真数据重建下段。
    await tester.runAsync(() async {
      await tester.pumpWidget(buildApp());
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(find.text(t.home_continue), findsOneWidget);
    expect(find.text(t.home_activity), findsOneWidget);
    expect(find.byType(StatContributionHeatmap), findsOneWidget);
  });

  testWidgets('BUG-1018：「继续」区显示 override 书名而非 DB 原名',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 一本在读的书（0 < position < duration 才进「继续」区）。
    final MediaItem book = MediaItem(
      mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor('测试书key'),
      title: '原书名',
      mediaTypeIdentifier: ReaderHibikiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderHibikiSource.instance.uniqueKey,
      position: 50,
      duration: 100,
      canDelete: false,
      canEdit: true,
    );
    // 编辑对话框同一写入通道设置 override 书名；测试后清除（instance 是单例）。
    await ReaderHibikiSource.instance.setOverrideTitleFromMediaItem(
      item: book,
      title: '改后的书名',
    );
    addTearDown(() => ReaderHibikiSource.instance
        .setOverrideTitleFromMediaItem(item: book, title: null));

    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(platformServices),
        ankiRepositoryProvider.overrideWithValue(ankiRepository),
        appProvider.overrideWith((ref) => appModel),
        hibikiBooksProvider
            .overrideWith((ref, language) async => <MediaItem>[book]),
        bookLastReadAtProvider
            .overrideWith((ref) async => <String, int>{'测试书key': 1}),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: HomeDashboardPage(videoRepo: VideoBookRepository(db)),
          ),
        ),
      ),
    ));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('改后的书名'), findsOneWidget);
    expect(find.text('原书名'), findsNothing);
  });

  testWidgets('「继续」区是横滑卡片行：书卡带封面底部进度条（percent/100）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final MediaItem book = MediaItem(
      mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor('横滑书key'),
      title: '横滑测试书',
      mediaTypeIdentifier: ReaderHibikiSource.instance.mediaType.uniqueKey,
      mediaSourceIdentifier: ReaderHibikiSource.instance.uniqueKey,
      position: 50,
      duration: 100,
      canDelete: false,
      canEdit: true,
    );
    await tester.pumpWidget(ProviderScope(
      overrides: <Override>[
        platformServicesProvider.overrideWithValue(platformServices),
        ankiRepositoryProvider.overrideWithValue(ankiRepository),
        appProvider.overrideWith((ref) => appModel),
        hibikiBooksProvider
            .overrideWith((ref, language) async => <MediaItem>[book]),
        bookLastReadAtProvider
            .overrideWith((ref) async => <String, int>{'横滑书key': 1}),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: HomeDashboardPage(videoRepo: VideoBookRepository(db)),
          ),
        ),
      ),
    ));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 「继续」区改为横向滑动列表（Jellyfin 式卡片行）。
    expect(
      find.byWidgetPredicate(
          (Widget w) => w is ListView && w.scrollDirection == Axis.horizontal),
      findsOneWidget,
    );
    // 书卡封面底部进度条 = percent/100（50/100 → 0.5）；目标未设（goal=0）时
    // 页面上没有其它 LinearProgressIndicator。
    final LinearProgressIndicator bar = tester
        .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator));
    expect(bar.value, 0.5);
    // 散卡：标题=书名，副标题=「阅读 · 50%」。
    expect(find.text('横滑测试书'), findsOneWidget);
    expect(find.text('${t.home_filter_read} · 50%'), findsOneWidget);
  });

  testWidgets('显示名统一：合集成员的继续卡标题=合集名，活动时间轴拼「合集名 - 名字」',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final DateTime now = DateTime.now();
    final String todayKey = HibikiTimeFormat.dayKey(now);
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('v1'),
      title: Value('S01E01'),
      videoPath: Value('/abs/s01e01.mp4'),
      lastPositionMs: Value(60000),
    ));
    final int cid = await db.createMediaCollection('进击的巨人');
    await db.addToCollection(cid, 'video', 'v1');
    await db.addActivityEvent(
      eventType: kActivityWatch,
      mediaType: kActivityMediaVideo,
      title: 'S01E01',
      mediaKey: 'v1',
      dateKey: todayKey,
      timestampMs: now.millisecondsSinceEpoch,
      durationMs: 60000,
    );

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 继续卡（非合集上下文）：标题行=合集名，副标题=「条目名 · 状态」。
    expect(find.text('进击的巨人'), findsOneWidget);
    expect(find.text('S01E01 · ${t.home_filter_watch}'), findsOneWidget);
    // 活动时间轴：单行拼「合集名 - 名字」。
    expect(find.text('进击的巨人 - S01E01'), findsOneWidget);
    // 裸 'S01E01' 不再单独出现（用户抱怨「分不清是哪部」的根治点）。
    expect(find.text('S01E01'), findsNothing);
  });

  testWidgets('热力图卡「今日目标」行：未设目标只显示设定入口；对话框设 1000 后进度行 = 800/1000',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 未设目标（默认 0）：只显示「设定目标」按钮，无进度条/进度文案。
    // 单次装配全程复用（appProvider 是 ChangeNotifierProvider：重挂第二棵
    // ProviderScope 会让第一个 container 先 dispose 共享 appModel，第二棵再
    // 用到/再 dispose 都是 use-after-dispose——目标变更走真实对话框通道）。
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(find.text(t.stat_goal_set), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // 点设定入口 → 对话框输入 1000 → 保存（_editDailyGoal 真实写回 +
    // setState 刷新，与阅读统计页同一持久化）。
    await tester.tap(find.text(t.stat_goal_set));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), '1000');
    await tester.tap(find.text(t.dialog_save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(
      find.text(t.stat_goal_progress(read: 800, goal: 1000)),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('点热力图某日弹当日明细 sheet：按类型分节列出条目', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    // 网格是热力图内唯一 GestureDetector；1280 宽下自适应列数、FittedBox 不缩放，
    // 格子坐标可按自然坐标（cell=12, spacing=3）直接计算。今天 = 末列、行 =
    // weekday-1（周一在上）。
    final Finder grid = find.descendant(
      of: find.byType(StatContributionHeatmap),
      matching: find.byType(GestureDetector),
    );
    final Size gridSize = tester.getSize(grid);
    const double step = 15; // cell 12 + spacing 3
    final int cols = ((gridSize.width + 3) / step).round();
    final int row = DateTime.now().weekday - 1;
    await tester.tapAt(
      tester.getTopLeft(grid) + Offset((cols - 1) * step + 6, row * step + 6),
    );
    // 明细 sheet：先等 DB 聚合 future，再等 bottom sheet 入场动画。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // 阅读节列出当日读的书（seedSampleData 今天读了 800 字的这本）。
    expect(find.text('吾輩は猫である'), findsOneWidget);
  });

  testWidgets('点继续区视频卡/活动条直接续播（带主合集 id），不再只是切视频 tab',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final DateTime now = DateTime.now();
    final String todayKey = HibikiTimeFormat.dayKey(now);
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('v1'),
      title: Value('S01E01'),
      videoPath: Value('/abs/s01e01.mp4'),
      lastPositionMs: Value(60000),
    ));
    final int cid = await db.createMediaCollection('进击的巨人');
    await db.addToCollection(cid, 'video', 'v1');
    // 活动条命中同一本地 uid：点击也应走同一条续播路径。
    await db.addActivityEvent(
      eventType: kActivityWatch,
      mediaType: kActivityMediaVideo,
      title: 'S01E01',
      mediaKey: 'v1',
      dateKey: todayKey,
      timestampMs: now.millisecondsSinceEpoch,
      durationMs: 60000,
    );

    // 注入打开替身（widget 测试无法构建 media_kit 播放页），记录续播调用。
    final List<(String, int?)> opened = <(String, int?)>[];
    await tester.pumpWidget(buildApp(
      openVideoOverride: (
        BuildContext _,
        VideoBookRepository __,
        String bookUid,
        int? playlistCollectionId,
      ) async {
        opened.add((bookUid, playlistCollectionId));
      },
    ));
    await pumpDashboard(tester);

    final HomeTab tabBefore = homeShellTabNotifier.value;
    // 继续卡点击 → 直接续播（合集成员带 playlistCollectionId 从合集续播）。
    await tester.tap(find.text('S01E01 · ${t.home_filter_watch}'));
    await tester.pump();
    expect(opened, <(String, int?)>[('v1', cid)]);
    // 活动条点击 → 同一条续播路径。
    await tester.tap(find.text('进击的巨人 - S01E01'));
    await tester.pump();
    expect(opened.length, 2);
    expect(opened.last, ('v1', cid));
    // 旧行为（只把首页切到视频 tab）不再发生。
    expect(homeShellTabNotifier.value, tabBefore);
    // 活动条前置已是视频封面缩略槽（68×40，占位图标兜底），不再是裸 20px 图标。
    expect(
      find.byWidgetPredicate(
          (Widget w) => w is SizedBox && w.width == 68 && w.height == 40),
      findsWidgets,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('「最近添加」通栏：按导入时间列出本地视频卡（类型 · 相对时间）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 仅导入（无播放断点）：不进「继续」，只进「最近添加」。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('recent-v'),
      title: const Value('新导入的视频'),
      videoPath: const Value('/abs/recent.mp4'),
      importedAt: Value(DateTime.now()),
    ));

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.text(t.home_recently_added), findsOneWidget);
    expect(find.text('新导入的视频'), findsOneWidget);
    // 副标题 = 类型 · 相对添加时间（刚导入 → 「刚刚」）。
    expect(
      find.text('${t.home_filter_watch} · ${t.activity_just_now}'),
      findsOneWidget,
    );
  });

  /// 合集 Next-Up 三态的公共装配：合集「进击的巨人」+ 两集独立行 E1/E2。
  Future<int> seedCollectionTwoEpisodes({
    required VideoBooksCompanion e1,
    required VideoBooksCompanion e2,
  }) async {
    await db.upsertVideoBook(e1);
    await db.upsertVideoBook(e2);
    final int cid = await db.createMediaCollection('进击的巨人');
    await db.addToCollection(cid, 'video', 'e1');
    await db.addToCollection(cid, 'video', 'e2');
    return cid;
  }

  testWidgets('继续区合集 Next-Up：看完 E1 后合集卡推进为 E2，点击直接打开 E2（带合集 id）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final int cid = await seedCollectionTwoEpisodes(
      // E1 已看完（旧逻辑会把它踢出继续区、整个合集消失——用户实报）。
      e1: VideoBooksCompanion(
        bookUid: const Value('e1'),
        title: const Value('S01E01'),
        videoPath: const Value('/abs/e1.mp4'),
        lastPositionMs: const Value(1200000),
        completedAt: Value(DateTime.now()),
      ),
      // E2 全新未看。
      e2: const VideoBooksCompanion(
        bookUid: Value('e2'),
        title: Value('S01E02'),
        videoPath: Value('/abs/e2.mp4'),
      ),
    );

    final List<(String, int?)> opened = <(String, int?)>[];
    await tester.pumpWidget(buildApp(
      openVideoOverride: (
        BuildContext _,
        VideoBookRepository __,
        String bookUid,
        int? playlistCollectionId,
      ) async {
        opened.add((bookUid, playlistCollectionId));
      },
    ));
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 合集卡仍在，且推进为下一集：标题=合集名、副标题=「S01E02 · 观看」。
    expect(find.text('进击的巨人'), findsOneWidget);
    expect(find.text('S01E02 · ${t.home_filter_watch}'), findsOneWidget);
    expect(find.text('S01E01 · ${t.home_filter_watch}'), findsNothing);
    // 点击 Next-Up 卡 → 直接打开 E2（带合集 id 进合集连播）。
    await tester.tap(find.text('S01E02 · ${t.home_filter_watch}'));
    await tester.pump();
    expect(opened, <(String, int?)>[('e2', cid)]);
  });

  testWidgets('继续区合集 Next-Up：整个合集全部看完 → 不出卡（自然滚出继续区）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedCollectionTwoEpisodes(
      e1: VideoBooksCompanion(
        bookUid: const Value('e1'),
        title: const Value('S01E01'),
        videoPath: const Value('/abs/e1.mp4'),
        lastPositionMs: const Value(1200000),
        completedAt: Value(DateTime.now()),
      ),
      e2: VideoBooksCompanion(
        bookUid: const Value('e2'),
        title: const Value('S01E02'),
        videoPath: const Value('/abs/e2.mp4'),
        lastPositionMs: const Value(1300000),
        completedAt: Value(DateTime.now()),
      ),
    );

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('进击的巨人'), findsNothing);
    expect(find.text('S01E01 · ${t.home_filter_watch}'), findsNothing);
    expect(find.text('S01E02 · ${t.home_filter_watch}'), findsNothing);
  });

  testWidgets('继续区合集 Next-Up：有在看中的集 → 显示该集（回归现行为）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedCollectionTwoEpisodes(
      // E1 在看中（有断点未完成）。
      e1: const VideoBooksCompanion(
        bookUid: Value('e1'),
        title: Value('S01E01'),
        videoPath: Value('/abs/e1.mp4'),
        lastPositionMs: Value(60000),
      ),
      e2: const VideoBooksCompanion(
        bookUid: Value('e2'),
        title: Value('S01E02'),
        videoPath: Value('/abs/e2.mp4'),
      ),
    );

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 每合集最多一张卡：显示在看中的 E1，而不是 E2、也不是两张。
    expect(find.text('进击的巨人'), findsOneWidget);
    expect(find.text('S01E01 · ${t.home_filter_watch}'), findsOneWidget);
    expect(find.text('S01E02 · ${t.home_filter_watch}'), findsNothing);
  });

  testWidgets('中等宽度（700，<900 窄分支）单列堆叠不抛无限高度', (WidgetTester tester) async {
    // 700px < 900：走窄屏单列堆叠分支（热力图置顶 + 继续 + Activity）。曾因把
    // stretch/Expanded 的 Row 直接放进纵向 ListView 而在此宽度崩溃，锁死不再复发。
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
