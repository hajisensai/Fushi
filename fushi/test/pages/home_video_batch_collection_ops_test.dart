import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_operation_gate.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/series_scrape_seed.dart';
import '../helpers/test_platform_services.dart';
import '../helpers/video_header_more.dart';

/// 块2/3/4 视频库批量合集操作 widget 测试（真写穿内存 DB）：
///  - 多选态合集整选（封面卡整卡勾选 → 合集入选中集；成员卡收进详情页不在库页）；
///  - 组合三档（新建 / 并入 / 合并默认名）；
///  - 删除区分（解散不删媒体行 / 混选计数文案）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  // path_provider 根**全文件共用一个**，刻意不按用例隔离、也不重置 CoverMetaStore：
  // 库页进场的自动刮削 sweep 会跑存量成员封面清理（runMemberCoverCleanup →
  // CoverMetaStore.all()），而 CoverMetaStore 按目录共享进程级状态（读缓存 /
  // 在途加载 / 链式写锁）。上一条用例结束时那次读盘还在飞、它的 fakeAsync Zone
  // 不再推进；store 的共享 future 曾建在发起者 Zone 里，下一条用例进同一目录就
  // 整条挂住，连带批量删除排在 VideoCoverMutationGate 后面永不开工。store 现在
  // 只在根 Zone 里推进共享状态（见 CoverMetaStore._runDetached），这里共用一个
  // 根即是该修复的回归证据。
  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('fushi_batch_ops_pp');
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

  late FushiDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    // 封面写入 / 视频删除共用的进程级锁：上一条用例结束时在飞的 action 永远不会
    // 释放它，不清的话本文件的批量删除会排进永不移交的队列（进度对话框一直挂着）。
    // 契约见 VideoCoverMutationGate.debugResetForTesting。
    VideoCoverMutationGate.debugResetForTesting();
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_batch_ops');
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

  Future<void> seedVideo(String uid, String title) async {
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value(uid),
        title: Value(title),
        videoPath: Value('/abs/$uid.mp4'),
        importedAt: Value(DateTime(2026, 1, 1).millisecondsSinceEpoch),
      ),
    );
    // 「系列」墙只收有 AniDB 主身份的条目；本文件测的是批量选择/合并/解散，散卡
    // 不种身份的话根本不渲染，勾都勾不到。入了已刮削合集的成员照常按合集归属折叠
    // （_effectiveCollectionIdForBook 优先取合集），不会因此变成两张卡。
    await seedAniDbLooseIdentity(db, uid, title: title);
  }

  // #792 分区化：合集封面卡+散卡混排墙（_buildLocalVideoSlivers）搬进 series
  // 分区，标签栏/选择入口只在非 home 分区渲染，默认钉 series。
  Widget buildApp({VideoLibrarySection section = VideoLibrarySection.series}) =>
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

  Future<void> pumpPage(
    WidgetTester tester, {
    VideoLibrarySection section = VideoLibrarySection.series,
  }) async {
    // TODO-2486：顶部新增 hero 轮播（最高 420），800 高视口下墙卡中心会落到
    // 视口之外、tap 判 miss；抬高视口让墙完整可见。
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(section: section));
    await tester.pumpAndSettle();
  }

  Future<void> enterSelectionMode(WidgetTester tester) async {
    await tapVideoHeaderMoreEntry(tester, 'library_select_toggle');
    await tester.pumpAndSettle();
  }

  /// 批量删除 / 解散点头之后：bfa7138bf1（BUG-4709 / 35YfcYO-zR）起删除期间挂着
  /// 不可点掉的进度对话框（不定态指示器持续出帧），解散 / 删除链路里的真实 IO
  /// （合集资产 / 文件回收）在 fakeAsync 下不回话，直接 pumpAndSettle 只会对着
  /// 转圈超时。交替 pump 与 runAsync 让真实 IO 跑完，直到进度对话框自己关掉；
  /// 30s 上界内没关 = 删除真的卡死，照样失败。
  Future<void> finishBatchDelete(WidgetTester tester) async {
    final Finder progress = find.text(t.video_library_delete_progress_title);
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 30));
    await tester.pump();
    while (progress.evaluate().isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump(const Duration(milliseconds: 20));
    }
    await tester.pumpAndSettle();
    expect(progress, findsNothing, reason: '删除结束后进度对话框必须关掉');
  }

  testWidgets('块2：合集封面卡勾选 → 整合集入选中集；成员卡不在库页', (WidgetTester tester) async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    final int cid = await createSeriesCollection(db, '合集甲');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');

    await pumpPage(tester);
    await enterSelectionMode(tester);

    // 进多选态：合集封面卡带 1 个勾选框（透明对勾）；成员卡不在库页（收进详情页）。
    expect(
      find.descendant(
        of: find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
      reason: '合集封面卡多选态画整选勾选框',
    );
    expect(
      find.byKey(const ValueKey<String>('home_video_video/ep1')),
      findsNothing,
      reason: '合集成员卡不在库页（封面卡形态），无从单独勾选',
    );

    // 点合集卡 → 整合集入选中集，底栏计数 = 1。（TODO-2486：hero 轮播也显示
    // 合集名，裸文本 finder 歧义，按墙卡 key 点。）
    await tester.tap(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(t.batch_selected_count(n: 1)),
      findsOneWidget,
      reason: '整卡勾选把合集计入选中集',
    );
  });

  testWidgets('块3 档1：仅散卡 → 命名弹窗新建合集', (WidgetTester tester) async {
    await seedVideo('video/looseA', 'Alpha');
    await seedVideo('video/looseB', 'Beta');

    await pumpPage(tester);
    await enterSelectionMode(tester);

    await tester.tap(
      find.byKey(const ValueKey<String>('home_video_video/looseA')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('home_video_video/looseB')),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('home_video_batch_combine')),
    );
    await tester.pumpAndSettle();
    // 档1 弹命名框，确认。
    expect(find.text(t.dialog_ok), findsOneWidget, reason: '仅散卡应弹命名框');
    await tester.tap(find.text(t.dialog_ok));
    await tester.pumpAndSettle();

    final List<MediaCollectionRow> collections = await db
        .getAllMediaCollections();
    expect(collections.length, 1, reason: '新建一个合集');
    final List<MediaCollectionItemRow> members = await db.getCollectionItems(
      collections.single.id,
    );
    expect(
      members.map((MediaCollectionItemRow m) => m.entryKey).toSet(),
      <String>{'video/looseA', 'video/looseB'},
    );
  });

  testWidgets('块3 档2：1 合集 + 散卡 → 并入该合集（不弹命名）', (WidgetTester tester) async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    await seedVideo('video/looseL', '散卡L');
    final int cid = await createSeriesCollection(db, '合集乙');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');

    await pumpPage(tester);
    await enterSelectionMode(tester);

    // TODO-2486：hero 也显示合集名，按墙卡 key 选合集。
    await tester.tap(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('home_video_video/looseL')),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('home_video_batch_combine')),
    );
    await tester.pumpAndSettle();
    // 档2 不弹命名框。
    expect(find.text(t.dialog_ok), findsNothing, reason: '并入不应弹命名框');

    final List<MediaCollectionItemRow> members = await db.getCollectionItems(
      cid,
    );
    expect(
      members.map((MediaCollectionItemRow m) => m.entryKey).toSet(),
      <String>{'video/ep1', 'video/ep2', 'video/looseL'},
      reason: '散卡并入现有合集',
    );
    expect((await db.getAllMediaCollections()).length, 1, reason: '不新建合集');
  });

  testWidgets('块3 档3：≥2 合集 → 合并成一个（默认名=成员最多合集名）', (WidgetTester tester) async {
    await seedVideo('video/a1', 'A1');
    await seedVideo('video/a2', 'A2');
    await seedVideo('video/b1', 'B1');
    await seedVideo('video/b2', 'B2');
    await seedVideo('video/b3', 'B3');
    final int small = await createSeriesCollection(db, '小集');
    await db.addToCollection(small, MediaKind.video, 'video/a1');
    await db.addToCollection(small, MediaKind.video, 'video/a2');
    final int big = await createSeriesCollection(db, '大集');
    await db.addToCollection(big, MediaKind.video, 'video/b1');
    await db.addToCollection(big, MediaKind.video, 'video/b2');
    await db.addToCollection(big, MediaKind.video, 'video/b3');

    await pumpPage(tester);
    await enterSelectionMode(tester);

    // TODO-2486：hero 也显示合集名，按墙卡 key 选合集。
    await tester.tap(
      find.byKey(ValueKey<String>('home_video_collection_card_$small')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(ValueKey<String>('home_video_collection_card_$big')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('home_video_batch_combine')),
    );
    await tester.pumpAndSettle();
    // 合并弹命名框，默认名 = 成员最多合集名（大集，3 > 2）。
    // 库页自 P5-A 起有常驻搜索框（key=video_search_field），全页 EditableText
    // 不止一个。命名弹窗是压在页面之上的 route，其输入框在树序最后。
    final EditableText field = tester.widget<EditableText>(
      find.byType(EditableText).last,
    );
    expect(field.controller.text, '大集', reason: '默认名=成员最多合集名');
    await tester.tap(find.text(t.dialog_ok));
    await tester.pumpAndSettle();

    final List<MediaCollectionRow> collections = await db
        .getAllMediaCollections();
    expect(collections.length, 1, reason: '合并成一个合集（其余解散）');
    final List<MediaCollectionItemRow> members = await db.getCollectionItems(
      big,
    );
    expect(
      members.map((MediaCollectionItemRow m) => m.entryKey).toSet(),
      <String>{'video/a1', 'video/a2', 'video/b1', 'video/b2', 'video/b3'},
      reason: '目标合集吸收其余合集全部成员',
    );
    expect(await db.getMediaCollectionById(small), isNull, reason: '其余合集被解散');
  });

  testWidgets('块4：选中合集 → 解散（deleteMediaCollection 不删媒体本体）', (
    WidgetTester tester,
  ) async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    final int cid = await createSeriesCollection(db, '待解散');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');

    await pumpPage(tester);
    await enterSelectionMode(tester);
    await tester.tap(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('home_video_batch_delete')),
    );
    await tester.pumpAndSettle();
    // 纯合集 → 解散确认文案。
    expect(find.text(t.batch_dissolve_confirm(m: 1)), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, t.dialog_delete));
    await finishBatchDelete(tester);

    expect(await db.getMediaCollectionById(cid), isNull, reason: '合集被解散');
    // 媒体本体保留（解散只解除分组）。
    final VideoBookRepository repo = VideoBookRepository(db);
    expect(await repo.getByBookUid('video/ep1'), isNotNull, reason: '解散不删媒体行');
    expect(await repo.getByBookUid('video/ep2'), isNotNull);
  });

  testWidgets('块4：混选删除确认文案写明「删 N 个媒体、解散 M 个合集」', (WidgetTester tester) async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    await seedVideo('video/looseL', '散卡L');
    final int cid = await createSeriesCollection(db, '某合集');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');

    await pumpPage(tester);
    await enterSelectionMode(tester);
    await tester.tap(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('home_video_video/looseL')),
    );
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey<String>('home_video_batch_delete')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(t.batch_delete_mixed_confirm(n: 1, m: 1)),
      findsOneWidget,
      reason: '混选确认文案含媒体数 + 合集数',
    );
  });

  testWidgets('TODO-2486 多选纪律：横滚行卡不开播不勾选、三手势全部让位批量操作', (
    WidgetTester tester,
  ) async {
    await seedVideo('video/ep1', '第1集');
    // 入库时刻 = 现在 → 「最近添加」横滚行出现（14 天窗口）。
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('video/fresh'),
        title: const Value('新片'),
        videoPath: const Value('/abs/fresh.mp4'),
        importedAt: Value(DateTime.now().millisecondsSinceEpoch),
      ),
    );
    final int cid = await createSeriesCollection(db, '合集甲');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');

    // #792 分区化：hero 轮播 + 最近添加行只在 home 分区（dashboard 概览），而
    // 选择入口（标签栏 checklist）只在非 home 分区。运行时 shell 是**单实例**
    // HomeVideoPage 切 section 参数（video_library_shell.dart），选择态跨分区
    // 保留——此处镜像该真实路径：home 验前置 → 切 allVideos 进多选 → 切回
    // home 断言 hero/行卡的多选态纪律。
    await pumpPage(tester, section: VideoLibrarySection.home);
    final Finder recentCard = find.byKey(
      const ValueKey<String>('home_video_recent_video/fresh'),
    );
    expect(recentCard, findsOneWidget, reason: '前置：最近添加行须出现');

    await tester.pumpWidget(buildApp(section: VideoLibrarySection.series));
    await tester.pumpAndSettle();
    await enterSelectionMode(tester);
    await tester.pumpWidget(buildApp(section: VideoLibrarySection.home));
    await tester.pumpAndSettle();
    // 行卡是墙内容的快捷镜像、不参与勾选：多选态点击不得开播（弹进播放器会把
    // 批量操作打断）也不得改变选中计数。
    await tester.tap(recentCard, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      find.byType(HomeVideoPage),
      findsOneWidget,
      reason: '多选态点行卡不得推走库页（不开播）',
    );
    expect(
      find.text(t.batch_selected_count(n: 0)),
      findsOneWidget,
      reason: '行卡不参与勾选，计数保持 0',
    );
    // #792 dashboard 化后 home 无 hero 轮播（_buildHeroCarousel 已弃用），多选
    // 纪律由共享行卡 builder 承担：多选态行卡三个手势全部置 null（点击/长按/
    // 右键都让位给批量操作）。
    final FushiCard recentFushiCard = tester.widget<FushiCard>(recentCard);
    expect(recentFushiCard.onTap, isNull, reason: '多选态行卡点击必须置 null');
    expect(recentFushiCard.onLongPress, isNull, reason: '多选态行卡长按必须让位扫选');
    expect(recentFushiCard.onSecondaryTap, isNull, reason: '多选态行卡右键必须让位扫选');
  });
}
