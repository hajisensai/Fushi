import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/tracking/bangumi_api_client.dart';
import 'package:fushi/src/media/tracking/media_tracking_repository.dart';
import 'package:fushi/src/media/tracking/media_tracking_service.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart'
    show homeShellTabNotifier, HomeTab;
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/hibiki_design_tokens.dart';
import 'package:fushi/src/utils/components/stat_contribution_heatmap.dart';
import 'package:fushi/src/utils/misc/hibiki_time_format.dart';
import 'package:fushi_core/fushi_core.dart';
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

  /// 提到外层：Bangumi 同步卡的状态全部来自偏好（令牌/账号名/上次同步），测试要能写。
  late PreferencesRepository prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
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

  /// 区块作用域 finder：`_sectionCard` 最外层是 DecoratedBox，`find.ancestor` 由近及
  /// 远，第一个即本区块卡。**断言不收进区块就会被另一个区块里的同名文本 /
  /// 同款封面兜住**——游戏同时出现在「继续」「最近添加」「活动」三处，裸
  /// `find.text` / 裸 FileImage 谓词会让本文件的游戏用例变成假阳性（把被测分支删光
  /// 仍全绿）。
  Finder sectionCard(String title) => find
      .ancestor(of: find.text(title), matching: find.byType(DecoratedBox))
      .first;
  Finder inSection(String title, Finder matching) =>
      find.descendant(of: sectionCard(title), matching: matching);

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
    await db.addToCollection(cid, MediaKind.video, 'v1');
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
    await db.addToCollection(cid, MediaKind.video, 'v1');
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
      importedAt: Value(DateTime.now().millisecondsSinceEpoch),
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

  /// BUG-1111/BUG-1112 公共装配：塞一个游戏行；[playedAt] 非空则再塞一条游玩会话
  /// （仓储的 lastPlayedMs 由 `galgame_sessions` 现算，不是 `galgames` 上的列）。
  Future<void> seedGame({
    required String id,
    required String name,
    required DateTime addedAt,
    DateTime? playedAt,
    String? coverPath,
  }) async {
    await db.upsertGalgame(GalgamesCompanion(
      id: Value(id),
      name: Value(name),
      exePath: Value('/abs/$id.exe'),
      workdir: const Value('/abs'),
      addedAt: Value(addedAt.millisecondsSinceEpoch),
      coverPath: Value(coverPath),
    ));
    if (playedAt != null) {
      await db.insertGalgameSession(GalgameSessionsCompanion(
        gameId: Value(id),
        startMs: Value(playedAt.millisecondsSinceEpoch - 60000),
        endMs: Value(playedAt.millisecondsSinceEpoch),
        durationSeconds: const Value(60),
        dateKey: Value(HibikiTimeFormat.dayKey(playedAt)),
      ));
    }
  }

  testWidgets('BUG-1111：玩过的游戏进「继续」区，且「游戏」筛选档只留游戏', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final DateTime now = DateTime.now();
    // 在看的视频（进继续区）+ 玩过的游戏（本条修复前**结构上进不来**）。
    // 刻意不设 importedAt：让视频只出现在「继续」区，不进「最近添加」——否则
    // 下面按文本断言「游戏档滤掉视频」会被「最近添加」里的同名卡干扰。
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('v-1'),
      title: Value('某视频'),
      videoPath: Value('/abs/v1.mp4'),
      lastPositionMs: Value(5000),
    ));
    await seedGame(
      id: 'g-1',
      name: '某游戏',
      addedAt: now.subtract(const Duration(days: 3)),
      playedAt: now,
    );

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.text(t.home_continue), findsOneWidget);
    // 游戏出现在「继续」区（修复前恒不出现）。断言必须收进本区块：同一只游戏
    // 的 addedAt 也落在「最近添加」，裸 find.text('某游戏') 会被那张卡兜住——把继续
    // 区的游戏循环删光也照样绿（实测过的假阳性）。
    expect(inSection(t.home_continue, find.text('某游戏')), findsOneWidget);

    // 「游戏」筛选档存在（与热力图同一组档位），点它只剩游戏、视频被滤掉。
    // 页面上共有三组档位（热力图 / 继续 / 活动时间轴）都含「游戏」档，且游戏卡
    // 的状态副标题本身也是「游戏」——按裸文本或按树序取都会点错。
    final Finder gameChip = inSection(
      t.home_continue,
      find.widgetWithText(ChoiceChip, t.home_filter_game),
    );
    expect(gameChip, findsOneWidget);
    await tester.tap(gameChip);
    await tester.pump(const Duration(milliseconds: 200));
    expect(inSection(t.home_continue, find.text('某游戏')), findsOneWidget);
    expect(inSection(t.home_continue, find.text('某视频')), findsNothing);
  });

  testWidgets('BUG-1111：同合集的多个游戏在「继续」区收敛成一张卡（与视频侧同口径）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final DateTime now = DateTime.now();
    await seedGame(
      id: 'gc-1',
      name: '游戏A',
      addedAt: now.subtract(const Duration(days: 9)),
      playedAt: now.subtract(const Duration(days: 2)),
    );
    await seedGame(
      id: 'gc-2',
      name: '游戏B',
      addedAt: now.subtract(const Duration(days: 8)),
      playedAt: now,
    );
    final int cid = await db.createMediaCollection('某系列');
    await db.addToCollection(cid, MediaKind.game, 'gc-1');
    await db.addToCollection(cid, MediaKind.game, 'gc-2');

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 一合集一卡：标题=合集名，只出一张（不收敛时这里是两张同名卡）。
    expect(inSection(t.home_continue, find.text('某系列')), findsOneWidget);
    // 续玩目标=组内最近玩过的那部（副标题=条目名 · 状态）。
    expect(
      inSection(t.home_continue, find.text('游戏B · ${t.home_filter_game}')),
      findsOneWidget,
    );
    expect(
      inSection(t.home_continue, find.text('游戏A · ${t.home_filter_game}')),
      findsNothing,
    );
  });

  testWidgets('BUG-1111：新添加的游戏进「最近添加」（类型 · 相对时间）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 只添加、没玩过：不进「继续」，只进「最近添加」（与视频「只导入」同口径）。
    await seedGame(id: 'g-2', name: '刚加的游戏', addedAt: DateTime.now());

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(find.text(t.home_recently_added), findsOneWidget);
    expect(find.text('刚加的游戏'), findsWidgets);
    expect(
      find.text('${t.home_filter_game} · ${t.activity_just_now}'),
      findsOneWidget,
    );
  });

  testWidgets('BUG-1112/BUG-1284：旧 exePath 活动身份也能反查并渲染游戏封面',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 真封面文件：1x1 PNG（Image.file 需要真实可解码文件）。
    final File cover = File('${storeDir.path}/g3_cover.png')
      ..writeAsBytesSync(_kOnePixelPng);

    final DateTime now = DateTime.now();
    await seedGame(
      id: 'g-3',
      name: '有封面的游戏',
      addedAt: now,
      playedAt: now,
      coverPath: cover.path,
    );
    // 历史启动链路把 exePath 误写进 mediaKey，而且路径大小写/分隔符不一定一致；
    // 活动展示必须兼容回查，不能只认 galgames.id。
    await db.addActivityEvent(
      eventType: kActivityGame,
      mediaType: kActivityMediaGame,
      title: '有封面的游戏',
      dateKey: HibikiTimeFormat.dayKey(now),
      timestampMs: now.millisecondsSinceEpoch,
      mediaKey: r'\ABS\G-3.EXE',
      durationMs: 60000,
    );

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 修复前 `_gameById(mediaKey)` 拿 exePath 去比 id，时间轴上不会有任何本地封面。
    // 必须收进「活动」区块：同一只游戏同时在「继续」与「最近添加」里各有一张
    // `_gameCover`，裸本地 Image 谓词会被它们兜住——把 _activityLeading 的 game 分支
    // 删光也照样绿（实测过的假阳性）。
    // BUG-1299 后 `_gameCover` 走 [PortraitCoverImage]：朝向不合槽时同图再渲染一张
    // 模糊垫底，活动条里的 Image 数量因此可能 >1，数量断言放宽为 ≥1；但**谓词仍要求
    // ResizeImage 包 FileImage**（`resolveMediaCoverImage` 的解码上限口径），
    // 不放宽成裸 FileImage，否则少了这层就测不出来源解析被绕过。
    final Finder fileImages = inSection(
      t.home_activity,
      find.byWidgetPredicate(
        (Widget w) =>
            w is Image &&
            w.image is ResizeImage &&
            (w.image as ResizeImage).imageProvider is FileImage,
      ),
    );
    expect(fileImages, findsWidgets,
        reason: '游戏活动条应兼容旧 exePath 并渲染 galgames.coverPath 封面（BUG-1284）');
  });

  testWidgets('BUG-1412：活动身份门禁——不因重复标题、deleted id 或脏 key 误绑现存游戏封面',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final File cover = File('${storeDir.path}/identity_guard_cover.png')
      ..writeAsBytesSync(_kOnePixelPng);
    final DateTime now = DateTime.now();
    await seedGame(
      id: 'duplicate-a',
      name: '重复标题',
      addedAt: now,
      coverPath: cover.path,
    );
    await seedGame(
      id: 'duplicate-b',
      name: '重复标题',
      addedAt: now,
      coverPath: cover.path,
    );
    await seedGame(
      id: 'replacement',
      name: '已删除游戏的标题',
      addedAt: now,
      coverPath: cover.path,
    );
    await seedGame(
      id: 'dirty-current',
      name: '脏键标题',
      addedAt: now,
      coverPath: cover.path,
    );

    Future<void> addLegacyActivity({
      required String title,
      String? mediaKey,
      required int offsetMs,
    }) =>
        db.addActivityEvent(
          eventType: kActivityGame,
          mediaType: kActivityMediaGame,
          title: title,
          dateKey: HibikiTimeFormat.dayKey(now),
          timestampMs: now.millisecondsSinceEpoch - offsetMs,
          mediaKey: mediaKey,
          durationMs: 60000,
        );

    await addLegacyActivity(title: '重复标题', offsetMs: 1000);
    await addLegacyActivity(
      title: '已删除游戏的标题',
      mediaKey: 'deleted-stable-id',
      offsetMs: 2000,
    );
    await addLegacyActivity(
      title: '脏键标题',
      mediaKey: 'dirty-key',
      offsetMs: 3000,
    );

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final Finder fileImages = inSection(
      t.home_activity,
      find.byWidgetPredicate(
        (Widget w) =>
            w is Image &&
            w.image is ResizeImage &&
            (w.image as ResizeImage).imageProvider is FileImage,
      ),
    );
    expect(
      fileImages,
      findsNothing,
      reason: '身份不唯一或 key 不可信时必须回退类型图标，不能借标题取任意现存封面',
    );
  });

  testWidgets('BUG-1112：点活动时间轴的游戏条切到「游戏」tab，不再落到视频 tab',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final HomeTab tabBefore = homeShellTabNotifier.value;
    addTearDown(() => homeShellTabNotifier.value = tabBefore);

    final DateTime now = DateTime.now();
    await seedGame(id: 'g-4', name: '点开的游戏', addedAt: now, playedAt: now);
    await db.addActivityEvent(
      eventType: kActivityGame,
      mediaType: kActivityMediaGame,
      title: '点开的游戏',
      dateKey: HibikiTimeFormat.dayKey(now),
      timestampMs: now.millisecondsSinceEpoch,
      mediaKey: 'g-4',
      durationMs: 60000,
    );

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    // 同名文本在「继续」「最近添加」也各有一张卡，点击必须锁到活动区那一条。
    final Finder activityRow = inSection(t.home_activity, find.text('点开的游戏'));
    expect(activityRow, findsOneWidget);
    await tester.tap(activityRow);
    await tester.pump();

    // 修复前游戏条没分支，直接掉进 else → HomeTab.video。
    expect(homeShellTabNotifier.value, HomeTab.games);
    expect(tester.takeException(), isNull);
  });

  /// 合集 Next-Up 三态的公共装配：合集「进击的巨人」+ 两集独立行 E1/E2。
  Future<int> seedCollectionTwoEpisodes({
    required VideoBooksCompanion e1,
    required VideoBooksCompanion e2,
  }) async {
    await db.upsertVideoBook(e1);
    await db.upsertVideoBook(e2);
    final int cid = await db.createMediaCollection('进击的巨人');
    await db.addToCollection(cid, MediaKind.video, 'e1');
    await db.addToCollection(cid, MediaKind.video, 'e2');
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

  /// BUG-1073 用的装配：继续区 + 最近添加 + 活动 + 热力图四块都有内容。
  Future<void> seedAllSections() async {
    await seedSampleData();
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('recent-added-v'),
      title: const Value('刚导入的视频'),
      videoPath: const Value('/abs/recent-added.mp4'),
      importedAt: Value(DateTime.now().millisecondsSinceEpoch),
    ));
  }

  testWidgets('BUG-1073 宽屏排版：学习活动/继续/最近添加同在主列，活动时间轴独占侧列',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedAllSections();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 主列三块左边缘对齐（此前是「热力图通栏 → 继续|活动两栏 → 最近添加通栏」的
    // 三明治：热力图/最近添加被拉到整页宽，继续区一行 4 张卡右侧全空）。
    final double mainX = tester.getTopLeft(find.text(t.reading_activity)).dx;
    expect(tester.getTopLeft(find.text(t.home_continue)).dx, mainX);
    expect(tester.getTopLeft(find.text(t.home_recently_added)).dx, mainX);
    // 活动时间轴在右侧列（天然最长，独占一列才和主列高度对得上）。
    expect(
      tester.getTopLeft(find.text(t.home_activity)).dx,
      greaterThan(mainX + 200),
    );
    // 热力图不再被拉到整页宽。
    expect(
      tester.getSize(find.byType(StatContributionHeatmap)).width,
      lessThan(1600 * 0.7),
    );
  });

  testWidgets('BUG-1073 病灶 1 根因守卫：热力图空周底色必须与卡底拉开对比',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedAllSections();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    final Finder heatmapFinder = find.byType(StatContributionHeatmap);
    final StatContributionHeatmap heatmap =
        tester.widget<StatContributionHeatmap>(heatmapFinder);
    final HibikiDesignTokens tokens =
        HibikiDesignTokens.of(tester.element(heatmapFinder));
    // 此前传的是 surfaces.card（surfaceContainer），与区块卡底 surfaces.group
    // （surfaceContainerLow）几乎同色 → 没活动的周等于没画（用户看到「大片死黑」）。
    expect(heatmap.emptyColor, isNot(tokens.surfaces.group));
    expect(
      (heatmap.emptyColor.computeLuminance() -
              tokens.surfaces.group.computeLuminance())
          .abs(),
      greaterThan(0.01),
    );
  });

  testWidgets('超宽屏（1920）：内容随窗口铺满，不再限宽居中（撤 BUG-1073 的 1600px 上限）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedAllSections();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    // 用户实报「首页左右强制的间距」：旧 1600px 限宽居中在 1920 宽下左侧凭空
    // 挤出 ~140px 空带。撤限宽后内容左缘只剩页面 padding + 卡片内边距。
    expect(
      tester.getTopLeft(find.text(t.reading_activity)).dx,
      lessThan(100),
    );
  });

  /// 撤整页 1600 限宽后的**宽屏兜底**：1920 恰好是「主列 ~1076 < 网格自然上限
  /// 1110」的临界点，热力图刚好被填满，所以只测 1920 结构上测不到 BUG-1073 症状 3
  /// 的复发。2560 起主列就宽过 1110，热力图卡再拉满就是右侧死空白（3840 下实测卡内
  /// 2244 对网格 1110，空 1134px）。这里直接量真实几何：网格必须长到自然上限，且卡
  /// 内不许剩下富余宽度；同时侧列位置仍随窗口走，证明没有把整页限宽偷偷加回来。
  for (final double width in <double>[2560, 3840]) {
    testWidgets('宽屏兜底（$width）：热力图卡按网格自然上限封顶，卡内无右侧死空白',
        (WidgetTester tester) async {
      tester.view.physicalSize = Size(width, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await seedAllSections();
      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      expect(tester.takeException(), isNull);

      // 网格 = 热力图内最后一个 GestureDetector（Column 里翻页箭头在前、网格在后）。
      final Finder heatmapFinder = find.byType(StatContributionHeatmap);
      final Finder gridFinder = find
          .descendant(
            of: heatmapFinder,
            matching: find.byType(GestureDetector),
          )
          .last;
      // 卡内可用宽（= 卡宽 − 两侧内边距）：热力图在 stretch 的 Column 里，宽度就是它。
      final double cardInnerWidth = tester.getSize(heatmapFinder).width;
      final double gridWidth = tester.getSize(gridFinder).width;

      // 网格铺到自身两道封顶（53 列 × 18px 格 + 52 × 3px 间距 = 1110）。
      expect(gridWidth, statHeatmapMaxGridWidth(), reason: 'width=$width');
      // 富余宽度必须为零——回归时这里是 2244 − 1110 = 1134px 死空白。
      expect(
        cardInnerWidth - gridWidth,
        lessThanOrEqualTo(1.0),
        reason: 'width=$width 卡内右侧死空白',
      );
      // 只封顶热力图这一块：整页没有重新限宽居中，左缘仍贴页面 padding，
      // 侧列（活动时间轴）起点仍按窗口宽的 ~60% 走。
      expect(
        tester.getTopLeft(find.text(t.reading_activity)).dx,
        lessThan(100),
        reason: 'width=$width 左缘',
      );
      expect(
        tester.getTopLeft(find.text(t.home_activity)).dx,
        greaterThan(width * 0.5),
        reason: 'width=$width 侧列起点',
      );
    });
  }

  testWidgets('BUG-1073 窄屏（420）：四个区块仍单列堆叠、左边缘一致', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await seedAllSections();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    final double x = tester.getTopLeft(find.text(t.reading_activity)).dx;
    expect(tester.getTopLeft(find.text(t.home_continue)).dx, x);
    expect(tester.getTopLeft(find.text(t.home_activity)).dx, x);
  });

  testWidgets('BUG-1075 目标对话框：单位 + 口径说明 + 近 7 日日均 + 预设 chip 填入',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 今天读了 800 字（seedSampleData）→ 近 7 日日均 = 800 ~/ 7 = 114。
    await seedSampleData();
    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    await tester.tap(find.text(t.stat_goal_set));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final Finder dialog = find.byType(AlertDialog);
    // 单位（suffixText）+ 近 7 日日均：用户「不知道该填什么」的解药。口径说明行按用户
    // 要求删除，这里守卫它不再出现（i18n key 也已下线）。
    expect(
      find.descendant(of: dialog, matching: find.text(t.stat_goal_unit_chars)),
      findsOneWidget,
    );
    final TextField dailyField = tester.widget<TextField>(
      find.descendant(of: dialog, matching: find.byType(TextField)).first,
    );
    expect(dailyField.decoration?.helperText, isNull);
    // 参考值：与目标同口径（全来源合计）的近 7 日日均。
    expect(
      find.descendant(
        of: dialog,
        matching: find.text(t.stat_goal_recent_average(n: 114)),
      ),
      findsOneWidget,
    );

    // 预设 chip 点一下就填进输入框。
    await tester.tap(find.widgetWithText(ActionChip, '5000'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller?.text,
      '5000',
    );

    // 保存后目标行按填入值生效（与阅读统计页同一持久化）。
    await tester.tap(find.text(t.dialog_save));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(
      find.text(t.stat_goal_progress(read: 800, goal: 5000)),
      findsOneWidget,
    );
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

  // BUG-1220：追踪链路原本零可观测（成功即删 outbox 行、失败只进错误日志并退避、
  // 没建映射就静默返回），用户「看完了没反应」时无处可看。这张卡是唯一出口，
  // 三种断裂状态各自必须说得出话。
  group('Bangumi 同步卡（BUG-1220）', () {
    void useWideSurface(WidgetTester tester) {
      tester.view.physicalSize = const Size(1400, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
    }

    Future<void> connect({String account = 'Alice'}) async {
      await prefs.setPref(kBangumiAccessTokenPref, 'token');
      await prefs.setPref(kBangumiAccountNamePref, account);
    }

    testWidgets('未连接：明说未连接并给出连接入口', (WidgetTester tester) async {
      useWideSurface(tester);
      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      expect(tester.takeException(), isNull);
      expect(find.text(t.media_tracking_card_title), findsOneWidget);
      expect(find.text(t.media_tracking_not_connected), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, t.media_tracking_connect),
        findsOneWidget,
      );
    });

    testWidgets('已连接但没有本地历史：不再显示泛化的零关联警告', (WidgetTester tester) async {
      useWideSurface(tester);
      await connect();
      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      expect(tester.takeException(), isNull);
      // 账号名从偏好读回（不只是本次会话的连接结果）。
      expect(find.text('Alice'), findsOneWidget);
      // 从未同步必须与「同步过零待办」区分：成功即删 outbox 行，两者否则同形。
      expect(
          find.textContaining(t.media_tracking_never_synced), findsOneWidget);
      expect(find.text(t.media_tracking_no_local_history), findsOneWidget);
      expect(find.text(t.media_tracking_watched_show), findsOneWidget);
    });

    testWidgets('以前看完但未映射的视频会明确列为需要手动关联', (WidgetTester tester) async {
      useWideSurface(tester);
      await connect();
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'old-video',
          title: '以前看过的番剧',
          videoPath: 'C:/video/old.mkv',
          completedAt: Value<DateTime?>(DateTime.now()),
        ),
      );

      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('以前看过的番剧'), findsOneWidget);
      expect(
        find.text(
          '${t.media_tracking_anime} · '
          '${t.media_tracking_manual_required}',
        ),
        findsOneWidget,
      );
      expect(
        find.text(t.media_tracking_manual_required_count(n: 1)),
        findsOneWidget,
      );
    });

    testWidgets('已关联条目列出本地标题 + Bangumi 条目名，并给出打开入口',
        (WidgetTester tester) async {
      useWideSurface(tester);
      await connect();
      await MediaTrackingRepository(db).saveMapping(
        mediaType: TrackingMediaType.videoCollection,
        mediaKey: '8',
        mediaTitle: '本地动画合集',
        kind: TrackingKind.anime,
        subjectId: 88,
        subjectName: 'Remote anime',
        progressMode: TrackingProgressMode.episode,
        progressOffset: 1,
      );

      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('本地动画合集'), findsOneWidget);
      expect(find.textContaining('Remote anime'), findsOneWidget);
      expect(find.byIcon(Icons.open_in_new), findsOneWidget);
      expect(
        find.textContaining(t.media_tracking_linked_count(n: 1)),
        findsOneWidget,
      );
      expect(find.text(t.media_tracking_no_local_history), findsNothing);
    });

    testWidgets('上报失败：退避窗口内也照说失败原因', (WidgetTester tester) async {
      useWideSurface(tester);
      await connect();
      final MediaTrackingRepository repository = MediaTrackingRepository(db);
      await repository.saveMapping(
        mediaType: TrackingMediaType.videoCollection,
        mediaKey: '8',
        mediaTitle: '失败的动画',
        kind: TrackingKind.anime,
        subjectId: 88,
        subjectName: 'Remote anime',
        progressMode: TrackingProgressMode.episode,
        progressOffset: 1,
      );
      await repository.enqueueProgress(
        mediaType: TrackingMediaType.videoCollection,
        mediaKey: '8',
        localProgress: 1,
        completed: false,
      );
      final List<PendingTrackingUpdate> due = await repository.dueUpdates();
      await repository.markFailed(
        due.single.outbox,
        const BangumiApiException(statusCode: 500, message: 'boom'),
      );
      // 退避后发送侧已看不到这一行——展示侧仍必须说得出原因。
      expect(await repository.dueUpdates(), isEmpty);

      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      expect(tester.takeException(), isNull);
      // 失败原因挂在条目行上，标题只出现一次（不另开「失败」段重复一遍）。
      expect(find.text('失败的动画'), findsOneWidget);
      expect(
        find.textContaining('${t.media_tracking_last_error}: '),
        findsOneWidget,
      );
      expect(find.textContaining('500'), findsOneWidget);
      expect(find.byIcon(Icons.sync_problem_outlined), findsOneWidget);
      expect(
        find.textContaining(t.media_tracking_pending_count(n: 1)),
        findsOneWidget,
      );
    });

    testWidgets('令牌被拒：给出「重新连接」提示', (WidgetTester tester) async {
      useWideSurface(tester);
      await connect();
      await prefs.setPref(kMediaTrackingLastSyncUnauthorizedPref, true);
      await prefs.setPref(
        kMediaTrackingLastSyncAtPref,
        DateTime.now().millisecondsSinceEpoch,
      );

      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      expect(tester.takeException(), isNull);
      expect(find.text(t.media_tracking_unauthorized), findsOneWidget);
    });

    testWidgets('自动关联 miss 后显示真实重试入口并回显结果', (WidgetTester tester) async {
      useWideSurface(tester);
      await connect();
      // 不存在的本地游戏会形成一次可重试 miss，且不访问真实网络。
      await appModel.mediaTrackingService.recordGameStatus(
        gameId: 'missing-game',
        status: 3,
      );

      await tester.pumpWidget(buildApp());
      await pumpDashboard(tester);

      final Finder retryButton = find.widgetWithText(
        FilledButton,
        t.media_tracking_retry_mapping,
      );
      expect(retryButton, findsOneWidget);

      await tester.tap(retryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(
        find.text(t.media_tracking_retry_no_match),
        findsOneWidget,
        reason: '重试不能被 10 分钟退避无声吞掉，匹配结果必须回显',
      );
      expect(tester.takeException(), isNull);
    });
  });
}

/// 1x1 透明 PNG：BUG-1112 需要一个**真实可解码**的封面文件（`Image.file` 对不存在
/// 或损坏的文件走 errorBuilder，断言不到 FileImage）。
const List<int> _kOnePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
