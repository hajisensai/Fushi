import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_home_layout.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 2026-10-14 用户拍板：筛选维度的**分区默认值**不算「生效中的筛选」——
/// 「全部视频」的系列归属默认是「非系列」（[kDefaultVideoSeriesFilter]），
/// 默认档不出 chip、筛选按钮不亮圆点；chip 的 ✕、面板「清除全部」、筛空态的
/// 「清除筛选」三处一律复位到分区默认值，而不是「全部」。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_default_chips_pp',
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
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_default_chips');
    platformServices = testPlatformServices();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    await db.close();
    try {
      storeDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  Widget buildApp() => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(FakeAnkiRepository()),
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: HomeVideoPage(
            repo: VideoBookRepository(db),
            section: VideoLibrarySection.allVideos,
          ),
        ),
      ),
    ),
  );

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
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

  Future<void> seedSeriesAndLoose() async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    await seedVideo('video/loose', '散片');
    final int cid = await db.createMediaCollection(
      '我的番',
      collectionType: 'playlist',
    );
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');
  }

  const ValueKey<String> seriesChip = ValueKey<String>(
    'video_active_filter_series',
  );
  const ValueKey<String> filterButton = ValueKey<String>(
    'video-library-filter-button',
  );
  FushiIconButton filterButtonWidget(WidgetTester tester) =>
      tester.widget<FushiIconButton>(find.byKey(filterButton));
  Finder cardOf(String uid) => find.byKey(ValueKey<String>('home_video_$uid'));

  testWidgets('默认档「非系列」不出 chip、筛选按钮不算生效', (WidgetTester tester) async {
    await seedSeriesAndLoose();
    await pumpPage(tester);

    expect(cardOf('video/loose'), findsOneWidget, reason: '前提：默认档已生效');
    expect(cardOf('video/ep1'), findsNothing);
    expect(find.byKey(seriesChip), findsNothing);
    expect(find.byKey(filterButton), findsOneWidget);
    expect(filterButtonWidget(tester).badge, isFalse, reason: '默认值下筛选按钮不亮圆点');
  });

  testWidgets('非默认档出 chip；点 ✕ 复位到分区默认值「非系列」并写回偏好', (WidgetTester tester) async {
    await prefs.setVideoAllSeriesFilterName(VideoSeriesFilter.all.name);
    await seedSeriesAndLoose();
    await pumpPage(tester);

    expect(cardOf('video/ep1'), findsOneWidget, reason: '前提：读回的是「全部」');
    expect(find.byKey(seriesChip), findsOneWidget);
    expect(filterButtonWidget(tester).badge, isTrue);

    await tester.tap(
      find.descendant(
        of: find.byKey(seriesChip),
        matching: find.byIcon(FushiIcons.close),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(seriesChip), findsNothing);
    expect(prefs.videoAllSeriesFilterName, kDefaultVideoSeriesFilter.name);
    expect(cardOf('video/ep1'), findsNothing, reason: '回到「非系列」，不是「全部」');
    expect(cardOf('video/loose'), findsOneWidget);
  });

  testWidgets('筛空态「清除筛选」同样复位到分区默认值', (WidgetTester tester) async {
    // 「系列内」档 + 库里只有散片 → 筛空。
    await prefs.setVideoAllSeriesFilterName(VideoSeriesFilter.inSeries.name);
    await seedVideo('video/loose', '散片');
    await pumpPage(tester);

    expect(
      find.byKey(const ValueKey<String>('home_video_filtered_empty')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('home_video_filters_clear')),
    );
    await tester.pumpAndSettle();

    expect(prefs.videoAllSeriesFilterName, kDefaultVideoSeriesFilter.name);
    expect(cardOf('video/loose'), findsOneWidget);
    expect(find.byKey(seriesChip), findsNothing);
  });

  testWidgets('全在默认值时筛空：不出无效的「清除筛选」按钮', (WidgetTester tester) async {
    // 库里只有系列的集：默认「非系列」档筛空，提示东西在系列页。
    await seedVideo('video/ep1', '第1集');
    final int cid = await db.createMediaCollection(
      '我的番',
      collectionType: 'playlist',
    );
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await pumpPage(tester);

    expect(
      find.byKey(const ValueKey<String>('home_video_filtered_empty')),
      findsOneWidget,
    );
    expect(
      find.text(t.video_filter_series_standalone_empty_hint),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('home_video_filters_clear')),
      findsNothing,
      reason: '没有可清的条件时按钮按下去什么都不变',
    );
  });
}
