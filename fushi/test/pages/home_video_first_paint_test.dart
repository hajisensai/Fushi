import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_continue_hero.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-3235：视频库首屏「一块块加载」（用户实报：点开视频库，里面的视频是一块块
/// 出来的）。
///
/// 根因：本地列表与分组映射各自 setState——列表先到就拿**空映射**画出全员散卡，
/// 映射（十几张表）到了再收拢成合集、换刮削海报。这里钉死：映射未就位时三个
/// 分区都只画骨架，任何一帧都不拿空映射渲染散卡；映射一到整墙一次换成终态。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_video_first_paint_pp',
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

  late _GatedMapsDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = _GatedMapsDatabase();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_video_first_paint');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    db.release();
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp(VideoLibrarySection section) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: HomeVideoPage(repo: VideoBookRepository(db), section: section),
        ),
      ),
    ),
  );

  Future<void> seedVideo(String uid, String title) => db.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(title),
      videoPath: Value<String>('/abs/$uid.mp4'),
      importedAt: Value<int>(DateTime(2026, 1, 4).millisecondsSinceEpoch),
    ),
  );

  /// 一部两集的番（合集）+ 一部没归系列的散片。
  Future<int> seedSeriesAndLoose() async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    await seedVideo('video/loose', '散片');
    final int cid = await db.createMediaCollection(
      '我的番',
      collectionType: 'playlist',
    );
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');
    return cid;
  }

  Finder cardOf(String uid) => find.byKey(ValueKey<String>('home_video_$uid'));
  final Finder skeleton = find.byKey(
    const ValueKey<String>('home_video_library_maps_pending'),
  );

  for (final VideoLibrarySection section in <VideoLibrarySection>[
    VideoLibrarySection.series,
    VideoLibrarySection.allVideos,
    VideoLibrarySection.home,
  ]) {
    testWidgets('映射未就位时 ${section.name} 只画骨架，不拿空映射铺散卡', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final int cid = await seedSeriesAndLoose();
      db.hold();

      await tester.pumpWidget(buildApp(section));
      // 列表早已到位、映射被卡住：逐帧推进，任何一帧都不许出现散卡。
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(skeleton, findsOneWidget, reason: '第 $i 帧：映射未到应画骨架');
        expect(cardOf('video/ep1'), findsNothing, reason: '第 $i 帧：成员散卡提前出现');
        expect(cardOf('video/ep2'), findsNothing);
        expect(cardOf('video/loose'), findsNothing);
      }

      db.release();
      await tester.pumpAndSettle();

      expect(skeleton, findsNothing);
      switch (section) {
        case VideoLibrarySection.series:
          expect(
            find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
            findsOneWidget,
          );
          expect(cardOf('video/ep1'), findsNothing, reason: '成员折进合集卡');
          expect(cardOf('video/loose'), findsOneWidget);
        case VideoLibrarySection.allVideos:
          // BUG-2835 默认「非系列」：映射到了才知道谁是成员。
          expect(cardOf('video/ep1'), findsNothing);
          expect(cardOf('video/loose'), findsOneWidget);
        default:
          break;
      }
    });
  }

  // 审查阻塞点 1：扫描 / 导入期间 uid 流约每秒触发一次整页刷新，每次都重发一轮
  // 映射加载。大库上一轮查询慢于触发间隔时，「每个信号都作废在途轮次」会让每一轮
  // 都在落地前被下一轮作废——首屏门永远打不开、整页一直骨架。走真实的 uid 流：
  // 每秒落库一条新视频。
  testWidgets('扫描期间 uid 流持续触发、每轮映射查询都慢于触发间隔时首屏仍会就绪', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final int cid = await seedSeriesAndLoose();
    // 每轮 2.5 s，每秒落库一条：uid 流按 1 s 节流（节流按墙钟判、尾沿计时器走测试
    // 假时钟，实际约每 1–2 s 发一次刷新），任何一轮落地时都已有更新的一轮在途。
    db.mapsDelay = const Duration(milliseconds: 2500);

    await tester.pumpWidget(buildApp(VideoLibrarySection.series));
    expect(skeleton, findsOneWidget);
    final int callsBefore = db.mapsCalls;
    for (int i = 1; i <= 8; i++) {
      await tester.pump(const Duration(milliseconds: 1000));
      await seedVideo('video/scan$i', '扫描$i');
      await tester.pump();
    }
    expect(
      db.mapsCalls - callsBefore,
      greaterThanOrEqualTo(3),
      reason: 'uid 流的每次变化都应重发一轮映射加载',
    );
    expect(skeleton, findsNothing, reason: '变更信号不得作废在途轮次，首屏门必须能打开');
    expect(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
      findsOneWidget,
    );
    expect(cardOf('video/loose'), findsOneWidget);
    expect(cardOf('video/ep1'), findsNothing, reason: '成员折进合集卡，不画散卡');

    // 停止触发，在途的最新一轮落地后照常覆盖：扫描进来的新片都在墙上。
    // 之后再发起的轮次（尾沿节流 / 合集表防抖）不再延迟，冲掉全部在途计时器。
    db.mapsDelay = null;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
      findsOneWidget,
    );
    expect(cardOf('video/scan8'), findsOneWidget);
  });

  // 清理不变式：作废式刷新（清理 / 删除等页面自己的写入后走的 [_refresh]）一旦
  // 请求，此前在途的轮次即使先完成也不得落地——首屏期间同样成立。
  testWidgets('作废式刷新之后，在途的旧轮先完成也不落地（首屏期间同样）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final int cid = await seedSeriesAndLoose();
    db.mapsDelay = const Duration(milliseconds: 1500);

    await tester.pumpWidget(buildApp(VideoLibrarySection.series));
    await tester.pump(const Duration(milliseconds: 500));
    // 首轮（t=0 发起，t=1.5 s 完成）在途时请求作废式刷新（t=0.5 s 发起，t=2 s 完成）。
    HomeVideoPage.debugRefreshVideos!();
    await tester.pump(const Duration(milliseconds: 1100)); // t=1.6 s
    expect(skeleton, findsOneWidget, reason: '首轮已被作废，先完成也不得落地');
    await tester.pump(const Duration(milliseconds: 500)); // t=2.1 s
    expect(skeleton, findsNothing, reason: '作废式刷新那一轮落地，首屏就绪');
    expect(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
      findsOneWidget,
    );
    db.mapsDelay = null;
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  // 审查阻塞点 2：首页分区真实版面是横滚行，骨架不能是网格墙。
  testWidgets('首页分区骨架是横滚行，与真实行同几何', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 刚入库的散片：真实首页只有「最近添加」一条行。
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/fresh'),
        title: const Value<String>('新片'),
        videoPath: const Value<String>('/abs/video/fresh.mp4'),
        importedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    db.hold();

    await tester.pumpWidget(buildApp(VideoLibrarySection.home));
    // 跑完进场错峰，量的是静止位置。
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(skeleton, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('home_video_row_skeleton_0')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: skeleton, matching: find.byType(SliverGrid)),
      findsNothing,
      reason: '首页没有墙格，骨架不能画网格',
    );
    // 2026-10 首页重设计后首屏可能有主卡（继续观看第一项）：库里一条播放痕迹都
    // 没有时真实首页不会有主卡，骨架也不得画主卡位——否则换真行时整段下跳一个
    // 主卡高（重设计后实测 611 → 219）。
    expect(
      find.byKey(const ValueKey<String>('home_video_hero_skeleton')),
      findsNothing,
      reason: '没有任何播放痕迹 → 真实首页无主卡，骨架不画主卡位',
    );
    final Rect skeletonCard = tester.getRect(
      find.byKey(const ValueKey<String>('home_video_row_skeleton_0_0')),
    );

    db.release();
    await tester.pumpAndSettle();

    expect(skeleton, findsNothing);
    final Finder realCard = find.byKey(
      const ValueKey<String>('home_video_recent_video/fresh'),
    );
    expect(realCard, findsOneWidget);
    final Rect real = tester.getRect(realCard);
    expect(real.topLeft, skeletonCard.topLeft, reason: '骨架卡与真卡同位，换场不跳');
    expect(real.width, skeletonCard.width, reason: '行卡恒竖版 2:3，骨架同宽');
  });

  // 同一几何门的「有主卡」分支：库里有在看的条目 → 骨架画主卡位，主卡位与真主卡
  // 同位同高，主卡下第一条行的骨架卡与真行首卡同位。
  testWidgets('首页分区骨架：有在看条目时主卡位与真主卡、首行与真行同几何', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 在看的旧片（提成主卡；入库早，不进「最近添加」）+ 刚入库的新片（「最近添加」）。
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/watching'),
        title: const Value<String>('在看'),
        videoPath: const Value<String>('/abs/video/watching.mp4'),
        importedAt: Value<int>(DateTime(2026, 1, 4).millisecondsSinceEpoch),
        lastPositionMs: const Value<int>(60000),
      ),
    );
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/fresh'),
        title: const Value<String>('新片'),
        videoPath: const Value<String>('/abs/video/fresh.mp4'),
        importedAt: Value<int>(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    db.hold();

    await tester.pumpWidget(buildApp(VideoLibrarySection.home));
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(skeleton, findsOneWidget);
    final Finder heroSkeleton = find.byKey(
      const ValueKey<String>('home_video_hero_skeleton'),
    );
    expect(heroSkeleton, findsOneWidget, reason: '有播放痕迹 → 骨架画主卡位');
    // 主卡位 KeyedSubtree 包着「主卡 + 下边距」，取其子孙里第一个骨架块当主卡本体。
    final Rect skeletonHero = tester.getRect(
      find
          .descendant(of: heroSkeleton, matching: find.byType(FushiSkeleton))
          .first,
    );
    final Rect skeletonCard = tester.getRect(
      find.byKey(const ValueKey<String>('home_video_row_skeleton_0_0')),
    );

    db.release();
    await tester.pumpAndSettle();

    expect(skeleton, findsNothing);
    final Finder realHero = find.byKey(
      const ValueKey<String>('home_video_continue_video/watching'),
    );
    expect(realHero, findsOneWidget);
    expect(
      find.ancestor(of: realHero, matching: find.byType(FushiContinueHero)),
      findsOneWidget,
      reason: '前提：在看那部被提成了首屏主卡',
    );
    final Rect hero = tester.getRect(realHero);
    expect(hero.topLeft, skeletonHero.topLeft, reason: '主卡位与真主卡同位');
    expect(hero.size, skeletonHero.size, reason: '横排版主卡位与真主卡同尺寸');
    final Rect real = tester.getRect(
      find.byKey(const ValueKey<String>('home_video_recent_video/fresh')),
    );
    expect(real.topLeft, skeletonCard.topLeft, reason: '主卡下首行：骨架卡与真卡同位');
    expect(real.width, skeletonCard.width);
  });

  // 审查阻塞点 3：骨架期间可见序必须为空——「全选」不能落到看不见的条目上。
  testWidgets('骨架期间多选「全选」不选中任何条目，映射到位后按真实可见序全选', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await seedSeriesAndLoose();
    db.hold();

    await tester.pumpWidget(buildApp(VideoLibrarySection.allVideos));
    for (int i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(skeleton, findsOneWidget);

    await tester.tap(find.byIcon(FushiIcons.checklist));
    // 批量栏滑入（映射仍卡着，pumpAndSettle 会一直等不到头，逐帧推进）。
    for (int i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(skeleton, findsOneWidget);
    WidgetController.hitTestWarningShouldBeFatal = true;
    addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
    await tester.tap(find.text(t.batch_select_all));
    await tester.pump(const Duration(milliseconds: 50));
    expect(
      find.text(t.batch_selected_count(n: 0)),
      findsOneWidget,
      reason: '骨架上没有可勾选的卡，全选必须是空操作',
    );

    db.release();
    await tester.pumpAndSettle();
    expect(skeleton, findsNothing);
    await tester.tap(find.text(t.batch_select_all));
    await tester.pumpAndSettle();
    // 「全部视频」默认「非系列」档：墙上只有那张散片。
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget);
  });
}

/// 卡住 [getAllMediaCollections]——它只被库页的整套映射加载读取，卡住它 = 映射
/// 迟迟不到，而本地列表照常返回（正是真机上大库的时序）。
class _GatedMapsDatabase extends FushiDatabase {
  _GatedMapsDatabase() : super.forTesting(NativeDatabase.memory());

  Completer<void>? _gate;

  /// 每轮映射加载固定耗时（模拟大库的慢全表查询）；null = 不延迟。
  Duration? mapsDelay;

  /// 映射加载被发起的轮数。
  int mapsCalls = 0;

  void hold() => _gate = Completer<void>();

  void release() {
    final Completer<void>? gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<List<MediaCollectionRow>> getAllMediaCollections() async {
    mapsCalls++;
    await _gate?.future;
    if (mapsDelay case final Duration delay) {
      await Future<void>.delayed(delay);
    }
    return super.getAllMediaCollections();
  }
}
