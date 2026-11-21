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
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/shell_layout.dart';
import '../helpers/test_platform_services.dart';

/// 拍板 design-nmv-video16-scrape-refresh（选 b）：
/// ① 库页被盖住时不跟着刮削写入刷新，露出来补一次；
/// ② 刮削写入后只重读变了的作品，不再整表重读重算（大库批次里每 2 s 一轮、
///    3000 行每轮占 UI isolate 中位 19.8 ms）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_video_scrape_refresh_pp',
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

  late _CountingDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;
  late HomeTab tabBefore;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    tabBefore = homeShellTabNotifier.value;
    homeShellTabNotifier.value = HomeTab.video;
    db = _CountingDatabase();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync(
      'fushi_video_scrape_refresh',
    );
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    homeShellTabNotifier.value = tabBefore;
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp(ValueNotifier<bool> shown) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        theme: gridShellTheme(),
        home: Scaffold(
          // 播放页 / 详情页盖住库页时，库页所在子树的 TickerMode 关掉
          // （isShownToUser 的判据）。
          body: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (BuildContext context, bool enabled, Widget? child) =>
                TickerMode(enabled: enabled, child: child!),
            child: HomeVideoPage(
              repo: VideoBookRepository(db),
              section: VideoLibrarySection.allVideos,
            ),
          ),
        ),
      ),
    ),
  );

  Future<void> seedLooseVideo() => db.upsertVideoBook(
    VideoBooksCompanion.insert(
      bookUid: 'video/loose',
      title: '散片',
      videoPath: '/abs/video/loose.mp4',
    ),
  );

  /// 一次刮削写入：书架行改标题（刮削写 episode 标题），再写一行刮削运行记录——
  /// 后者触发展示层信号，本身与库页无关。
  Future<void> scrapeWrite(String title) async {
    await db.updateVideoBookTitle('video/loose', title);
    await db.insertVideoSourceScrapeRun(
      VideoSourceScrapeRunsCompanion.insert(
        scope: 'library',
        status: 'completed',
        startedAt: 1,
        updatedAt: 1,
      ),
    );
  }

  Future<void> settle(WidgetTester tester) async {
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 400));
    }
    await tester.pumpAndSettle();
  }

  Finder titleOnCard(String title) => find.descendant(
    of: find.byKey(const ValueKey<String>('home_video_video/loose')),
    matching: find.text(title),
  );

  testWidgets('刮削写入后只重读变了的那几行，不整表重读映射', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await seedLooseVideo();
    final ValueNotifier<bool> shown = ValueNotifier<bool>(true);
    addTearDown(shown.dispose);

    await tester.pumpWidget(buildApp(shown));
    await settle(tester);
    expect(titleOnCard('散片'), findsOneWidget);
    final int fullRounds = db.fullMapsRounds;
    final int patches = db.patchReads;

    await scrapeWrite('第1集 旅立ち');
    await settle(tester);

    expect(db.patchReads, greaterThan(patches), reason: '刮削写入走增量刷新');
    expect(db.fullMapsRounds, fullRounds, reason: '刮削写入不再整表重读十几张映射表');
    expect(titleOnCard('第1集 旅立ち'), findsOneWidget, reason: '书架行的新标题要上墙');
  });

  testWidgets('库页被盖住时刮削写入不刷新，露出来补一次', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await seedLooseVideo();
    final ValueNotifier<bool> shown = ValueNotifier<bool>(true);
    addTearDown(shown.dispose);

    await tester.pumpWidget(buildApp(shown));
    await settle(tester);
    final int fullRounds = db.fullMapsRounds;
    final int patches = db.patchReads;

    shown.value = false;
    await tester.pump();
    for (int i = 0; i < 3; i++) {
      await scrapeWrite('第${i + 1}集');
      await tester.pump(const Duration(seconds: 3));
    }
    await settle(tester);
    expect(db.patchReads, patches, reason: '被盖住期间一轮都不刷');
    expect(db.fullMapsRounds, fullRounds);

    shown.value = true;
    await settle(tester);
    expect(db.patchReads, patches + 1, reason: '露出来只补一次');
    expect(db.fullMapsRounds, fullRounds);
    expect(titleOnCard('第3集'), findsOneWidget);
  });
}

class _CountingDatabase extends FushiDatabase {
  _CountingDatabase() : super.forTesting(NativeDatabase.memory());

  /// 整表映射轮次数（[getAllMediaCollections] 只被库页的整套映射加载读取）。
  int fullMapsRounds = 0;

  /// 增量重读次数。
  int patchReads = 0;

  @override
  Future<List<MediaCollectionRow>> getAllMediaCollections() {
    fullMapsRounds++;
    return super.getAllMediaCollections();
  }

  @override
  Future<VideoScrapePresentationRows> getVideoScrapePresentationRows(
    VideoScrapePresentationDelta delta,
  ) {
    patchReads++;
    return super.getVideoScrapePresentationRows(delta);
  }
}
