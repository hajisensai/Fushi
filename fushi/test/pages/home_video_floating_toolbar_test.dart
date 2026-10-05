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
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/video_library_shell.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/batch_action_bar.dart';
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart';
import 'package:fushi/src/utils/components/library_section_tabs.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/source_library/source_library_row.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;
import 'package:fushi_engine/media/video/video_book_repository.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

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
      'hibiki_video_floating_pp',
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
    storeDir = Directory.systemTemp.createTempSync('hibiki_video_floating');
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
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final FushiSectionTabBar<VideoLibrarySection> strip = tester.widget(
      find.byType(FushiSectionTabBar<VideoLibrarySection>),
    );
    strip.onChanged!(VideoLibrarySection.allVideos);
    await tester.pumpAndSettle();

    expect(
      inPill(find.byKey(const ValueKey<String>('video-library-refresh'))),
      findsOneWidget,
      reason: '视频库页头的刷新等动作由浮动工具栏的悬浮动作组画出',
    );
    expect(find.byType(BatchActionBar), findsNothing);

    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();

    expect(
      inPill(find.byKey(const ValueKey<String>('video-selection-exit'))),
      findsOneWidget,
      reason: '多选态是浮动工具栏的上下文切换',
    );
    expect(
      inPill(find.byKey(const ValueKey<String>('video-library-refresh'))),
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
      inPill(find.byKey(const ValueKey<String>('video-library-refresh'))),
      findsOneWidget,
    );
  });
}
