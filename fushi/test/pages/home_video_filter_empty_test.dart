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
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/glass_unwrap.dart';
import '../helpers/test_platform_services.dart';

/// 2026-10 体验优化：视频库筛选空态（视频自己的文案 + 一键清除）与窄屏搜索行
/// （搜索框独占一行、chip 落第二行）。harness 与
/// `home_video_all_videos_series_filter_test.dart` 同形。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_video_filter_empty_pp',
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
    storeDir = Directory.systemTemp.createTempSync('fushi_video_filter_empty');
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

  Widget buildApp(VideoLibrarySection section, {Key? pageKey}) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: HomeVideoPage(
            key: pageKey,
            repo: VideoBookRepository(db),
            section: section,
          ),
        ),
      ),
    ),
  );

  Future<void> pumpSection(
    WidgetTester tester,
    VideoLibrarySection section, {
    Size size = const Size(1280, 1600),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(section));
    await tester.pumpAndSettle();
  }

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

  Finder searchField() =>
      find.byKey(const ValueKey<String>('video_search_field'));

  const ValueKey<String> searchButton = ValueKey<String>(
    'fushi-header-search-button',
  );

  /// 单行页头（2026-10-14）：搜索平时是页头里的 🔍，点开整行换成搜索栏。
  Future<void> expandSearch(WidgetTester tester) async {
    await tester.tap(find.byKey(searchButton));
    await tester.pumpAndSettle();
  }

  testWidgets('2026-10 筛选空态：视频自己的文案 + 一键清除搜索词与全部筛选', (
    WidgetTester tester,
  ) async {
    await seedSeriesAndLoose();
    await prefs.setVideoAllSeriesFilterName('all');
    await pumpSection(tester, VideoLibrarySection.allVideos);

    await expandSearch(tester);
    await tester.enterText(searchField(), 'zzz-no-hit');
    await tester.pumpAndSettle();

    expect(find.text(t.video_library_filter_empty), findsOneWidget);
    expect(
      find.text(t.tag_no_books_for_filter),
      findsNothing,
      reason: '不再借用书架「书」的文案',
    );
    final Finder clear = find.byKey(
      const ValueKey<String>('home_video_filters_clear'),
    );
    expect(clear, findsOneWidget);

    await tester.tap(clear);
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<TextField>(glassUnwrap<TextField>(searchField()))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.text(t.video_library_filter_empty), findsNothing);
    // 2026-10-14：清除 = 每个维度回到**分区默认值**（与 chip ✕、面板「清除
    // 全部」同口径），系列归属回「非系列」：散片回来，合集的集仍收在系列页。
    expect(cardOf('video/loose'), findsOneWidget);
    expect(cardOf('video/ep1'), findsNothing);
    expect(cardOf('video/ep2'), findsNothing);
    expect(
      prefs.videoAllSeriesFilterName,
      'standalone',
      reason: '系列归属是唯一持久化的档位，清除后要写回偏好',
    );
  });

  testWidgets('2026-10 「非系列」默认档筛空：给系列页提示，没有可清的条件就不出清除按钮', (
    WidgetTester tester,
  ) async {
    await seedVideo('video/ep1', '第1集');
    final int cid = await db.createMediaCollection(
      '我的番',
      collectionType: 'playlist',
    );
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await pumpSection(tester, VideoLibrarySection.allVideos);

    expect(
      find.text(t.video_filter_series_standalone_empty_hint),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home_video_filters_clear')),
      findsNothing,
      reason: '清除只回到分区默认值，已经全在默认值时按下去什么都不变',
    );
  });

  testWidgets('2026-10-14 360dp 窄屏：单行页头无溢出，🔍 展开后搜索栏占满整行', (
    WidgetTester tester,
  ) async {
    await seedSeriesAndLoose();
    await pumpSection(
      tester,
      VideoLibrarySection.allVideos,
      size: const Size(360, 780),
    );

    expect(tester.takeException(), isNull);
    expect(find.byKey(searchButton), findsOneWidget);
    expect(searchField(), findsNothing, reason: '搜索平时收成 🔍');

    await expandSearch(tester);
    expect(tester.takeException(), isNull);
    expect(searchField(), findsOneWidget);
    expect(
      tester
          .getRect(
            find.byKey(const ValueKey<String>('fushi-header-search-bar')),
          )
          .width,
      greaterThan(300),
      reason: '展开后整行页头换成搜索栏',
    );
  });

  testWidgets('2026-10-14 宽屏：🔍 与筛选按钮同在页头一行，生效中的筛选 chip 在下一行', (
    WidgetTester tester,
  ) async {
    await prefs.setVideoAllSeriesFilterName('all');
    await seedSeriesAndLoose();
    await pumpSection(tester, VideoLibrarySection.allVideos);

    final Rect search = tester.getRect(find.byKey(searchButton));
    final Rect filter = tester.getRect(
      find.byKey(const ValueKey<String>('video-library-filter-button')),
    );
    expect((search.center.dy - filter.center.dy).abs(), lessThan(12));
    final Rect chip = tester.getRect(
      find.byKey(const ValueKey<String>('video_active_filter_series')),
    );
    expect(chip.top, greaterThanOrEqualTo(filter.bottom - 1));
  });
}
