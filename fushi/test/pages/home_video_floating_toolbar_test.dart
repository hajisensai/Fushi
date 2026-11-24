import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/video_library_shell.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;
import 'package:fushi_engine/media/video/video_book_repository.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';
import '../helpers/masthead_tabs.dart';
import '../helpers/shell_layout.dart';

class _NoopScrapeRunner implements VideoSourceScrapeRunner {
  @override
  Future<SourceScrapeReport> scrapeSource(
    SourceLibraryRow source, {
    required VideoSourceScrapeCancellationToken cancellationToken,
    required VideoSourceScrapeProgressCallback onProgress,
    VideoSourceScrapeConfirmationCallback? onConfirmation,
    VideoSourceScrapeBatchContext? batchContext,
    List<VideoSourceScrapeWork>? plannedWorks,
    String runScope = 'source',
  }) async {
    return SourceScrapeReport(sourceIds: <int>[source.id]);
  }
}

/// 视频库 M3E 浮动工具栏 × 真实视频库页：页头动作进悬浮动作组；进入多选时
/// 动作组上下文切换成「已选 N · 退出」，底部批量栏弹簧浮起；退出后原样换回。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_video_floating_pp',
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
    try {
      pathProviderDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  late FushiDatabase db;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;
  late VideoSourceScrapeTaskController scrapeController;
  late ChangeNotifier refreshSignal;

  setUp(() async {
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final PreferencesRepository prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_video_floating');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    scrapeController = VideoSourceScrapeTaskController(_NoopScrapeRunner());
    refreshSignal = ChangeNotifier();
    await db.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value('video/alpha'),
        title: const Value('Alpha'),
        videoPath: const Value('/abs/alpha.mp4'),
        importedAt: Value(DateTime(2026, 1, 1).millisecondsSinceEpoch),
      ),
    );
  });

  tearDown(() async {
    scrapeController.dispose();
    refreshSignal.dispose();
    await db.close();
    try {
      storeDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget buildApp() => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        theme: gridShellTheme(),
        home: Scaffold(
          body: VideoLibraryShell(
            repository: VideoBookRepository(db),
            libraryRefreshSignal: refreshSignal,
            scrapeTaskController: scrapeController,
            onScrapeAll: () async {},
            onClearAllScrapeRecords: () async {},
            onScrapeSource: (_) async {},
            onVideoScanCompleted: (_, __) async {},
            onOpenScrapeTasks: () {},
            onLibraryChanged: () {},
          ),
        ),
      ),
    ),
  );

  Finder inPill(Finder matching) => find.descendant(
    of: find.byType(FushiFloatingActionsPill),
    matching: matching,
  );

  testWidgets('多选：悬浮动作组切成「已选 N · 退出」，底部批量栏浮起；退出后换回', (
    WidgetTester tester,
  ) async {
    // 刷新只在桌面平台出现（触屏下拉即入口，反馈 #7m1x-R3yOn）。
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 页头大字顶栏（PR #3397）：全部视频在媒体库组的二级页签里。
    readMastheadTabs<VideoLibrarySection>(
      tester,
      mastheadSecondaryTabs<VideoLibrarySection>(),
    ).onChanged(VideoLibrarySection.allVideos);
    await tester.pumpAndSettle();

    // 设计稿 #video V2：页头常驻搜索 / 筛选与排序 / 后台任务 / 添加，低频动作
    // （刷新、选择、管理标签…）挂在页面「⋯」上；宽窗放得下时由页头统一收纳
    // 平铺成独立图标钮（沿用菜单项 key），一项都没收时不出「⋯」（用户
    // 2026-11-24「有空间还是展开最好」，fushiResolveHeaderActions）。
    expect(
      inPill(find.byKey(const ValueKey<String>('library_select_toggle'))),
      findsOneWidget,
      reason: '视频库页头的低频动作由浮动工具栏的悬浮动作组画出（宽窗平铺）',
    );
    expect(
      inPill(find.byKey(const ValueKey<String>('video-library-more'))),
      findsNothing,
      reason: '1600 宽放得下全部平铺，不再收进「⋯」',
    );
    expect(
      find.byKey(const ValueKey<String>('video-library-refresh')),
      findsNothing,
      reason: '刷新空闲时是「⋯」项（此处平铺），不另画转圈刷新钮',
    );
    expect(
      inPill(find.byKey(const ValueKey<String>('video-library-refresh-menu'))),
      findsOneWidget,
    );
    expect(find.byType(BatchActionBar), findsNothing);

    await tester.tap(
      inPill(find.byKey(const ValueKey<String>('library_select_toggle'))),
    );
    await tester.pumpAndSettle();

    expect(
      inPill(find.byKey(const ValueKey<String>('video-selection-exit'))),
      findsOneWidget,
      reason: '多选态是浮动工具栏的上下文切换',
    );
    expect(
      inPill(find.byKey(const ValueKey<String>('library_select_toggle'))),
      findsNothing,
    );
    expect(inPill(find.text(t.batch_selected_count(n: 0))), findsOneWidget);
    expect(find.byType(BatchActionBar), findsOneWidget);

    await tester.tap(
      inPill(find.byKey(const ValueKey<String>('video-selection-exit'))),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BatchActionBar), findsNothing, reason: '批量栏沉下去后卸掉');
    expect(
      inPill(find.byKey(const ValueKey<String>('library_select_toggle'))),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null; // 须在用例体内复位：不变量先于 tearDown 校验
  });

  testWidgets('触屏平台页头不画刷新按钮（下拉刷新是同一入口，不重复）', (WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 页头大字顶栏（PR #3397）：全部视频在媒体库组的二级页签里。
    readMastheadTabs<VideoLibrarySection>(
      tester,
      mastheadSecondaryTabs<VideoLibrarySection>(),
    ).onChanged(VideoLibrarySection.allVideos);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('video-library-refresh')),
      findsNothing,
    );
    // 宽窗下「⋯」的项平铺成独立图标钮（fushiResolveHeaderActions），刷新项
    // 无论平铺还是收进「⋯」都沿用同一个 key。
    expect(
      find.byKey(const ValueKey<String>('library_select_toggle')),
      findsOneWidget,
      reason: '其余低频动作照常平铺，排除「整行没画」的假绿',
    );
    expect(
      find.byKey(const ValueKey<String>('video-library-refresh-menu')),
      findsNothing,
      reason: '触屏下拉即刷新入口，「⋯」项里也不重复',
    );
    debugDefaultTargetPlatformOverride = null;
  });
}
