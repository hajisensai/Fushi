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
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/library_layout/library_layout.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_bar_cluster.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;
import 'package:fushi_engine/media/video/video_book_repository.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';
import '../helpers/shell_layout.dart';
import '../helpers/unmount_and_close_db.dart';

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

/// 视频库多选态的 Apple 顶栏（用户 2026-11-24 截图：右上角「已选 0 项」玻璃胶囊
/// 字贴顶、与旁边玻璃钮不齐，且与底部工具栏中央的计数重复）：
/// - Apple 下顶栏只留退出多选的 ✕，计数只在底部批量栏出现一次；
/// - 顶栏各玻璃钮竖直居中对齐；
/// - 玻璃钮槽（FushiAppleBarCluster）里不居中的子节点也被竖直居中（根因）。
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
  bool dbClosed = false;

  setUp(() async {
    dbClosed = false;
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
    if (!dbClosed) await db.close();
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
        theme: gridShellTheme(
          base: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            glassDesign: true,
          ).copyWith(platform: TargetPlatform.windows),
        ),
        home: FushiGlassScope(
          child: Scaffold(
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
    ),
  );

  testWidgets('Apple 多选态：顶栏只有 ✕（计数只在底部批量栏一次），玻璃钮竖直对齐', (
    WidgetTester tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    tester
        .widget<LibraryLayout<VideoLibrarySection>>(
          find.byType(LibraryLayout<VideoLibrarySection>),
        )
        .spec
        .onSelect(VideoLibrarySection.allVideos);
    await tester.pumpAndSettle();

    final Finder toggle = find.byKey(
      const ValueKey<String>('library_select_toggle'),
    );
    if (toggle.evaluate().isEmpty) {
      await tester.tap(
        find.byKey(const ValueKey<String>('video-library-more')),
      );
      await tester.pumpAndSettle();
    }
    await tester.tap(toggle.first);
    await tester.pumpAndSettle();

    expect(find.byType(BatchActionBar), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('video-selection-count')),
      findsNothing,
      reason: 'Apple 顶栏不再放计数',
    );
    final Finder count = find.text(t.batch_selected_count(n: 0));
    expect(count, findsOneWidget, reason: '「已选 0 项」只出现一次');
    expect(
      find.descendant(of: find.byType(BatchActionBar), matching: count),
      findsOneWidget,
      reason: '计数在底部浮动工具栏里',
    );

    final Finder exit = find.byKey(
      const ValueKey<String>('video-selection-exit'),
    );
    expect(exit, findsOneWidget);
    final Finder import = find.byKey(
      const ValueKey<String>('video-library-view-import'),
    );
    expect(import, findsOneWidget);
    expect(
      (tester.getCenter(exit).dy - tester.getCenter(import).dy).abs(),
      lessThan(0.5),
      reason: '顶栏玻璃钮竖直居中对齐',
    );
    // 视频库页挂载即起后台封面回填：用例体内卸页推进到关库完成（见 helper）。
    await unmountAndCloseDb(tester, db);
    dbClosed = true;
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('玻璃钮槽：不自带居中的子节点也竖直居中（根因：此前 minHeight 撑高后字贴顶）', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFushiThemeData(
          scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
          textTheme: Typography.material2021().black,
          glassDesign: true,
        ).copyWith(platform: TargetPlatform.windows),
        home: FushiGlassScope(
          child: Scaffold(
            body: Center(
              child: FushiAppleBarCluster(
                compact: false,
                items: <Widget>[
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12),
                    child: Text('Label', key: ValueKey<String>('slot-text')),
                  ),
                  FushiIconButton(
                    key: const ValueKey<String>('slot-icon'),
                    tooltip: 'Close',
                    icon: Icons.close,
                    onTap: () {},
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      (tester.getCenter(find.byKey(const ValueKey<String>('slot-text'))).dy -
              tester
                  .getCenter(find.byKey(const ValueKey<String>('slot-icon')))
                  .dy)
          .abs(),
      lessThan(0.5),
    );
  });
}
