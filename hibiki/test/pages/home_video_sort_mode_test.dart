import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';
import 'package:hibiki/src/platform/platform_providers.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 排序交互重设计层次 A（spec 2026-07-12）：视频库「排序方式」菜单端到端接线。
///
/// 锁死三件事：①默认「最近观看」= watch-stats 最新者在前、无记录退导入时间
/// （用户拍板的默认值变化）；②菜单切「名称」走 natural 序（第9话 < 第10话）、
/// 切「导入时间」新导入在前；③选择写穿偏好 `video_sort_mode`（跨启动记住）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_sort_mode_pp');
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
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_sort_mode');
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

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(body: HomeVideoPage(repo: VideoBookRepository(db))),
          ),
        ),
      );

  /// 三张散卡从左到右的标题序（同一行内按 x 坐标）。
  List<String> cardOrder(WidgetTester tester, List<String> titles) {
    final List<({String title, double x})> found = <({String title, double x})>[
      for (final String title in titles)
        (title: title, x: tester.getTopLeft(find.text(title).last).dx),
    ];
    found.sort((a, b) => a.x.compareTo(b.x));
    return <String>[for (final r in found) r.title];
  }

  Future<void> seedThreeVideos() async {
    // Beta：导入居中（1/2），有观看痕迹（watch-stats lastModified = now，最新）。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/beta'),
      title: const Value('Beta'),
      videoPath: const Value('/abs/beta.mp4'),
      lastPositionMs: const Value(60000),
      importedAt: Value(DateTime(2026, 1, 2).millisecondsSinceEpoch),
    ));
    // Alpha 第10话：导入最新（1/3），无观看记录。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/a10'),
      title: const Value('Alpha 第10话'),
      videoPath: const Value('/abs/a10.mp4'),
      importedAt: Value(DateTime(2026, 1, 3).millisecondsSinceEpoch),
    ));
    // Alpha 第9话：导入最旧（1/1），无观看记录。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/a9'),
      title: const Value('Alpha 第9话'),
      videoPath: const Value('/abs/a9.mp4'),
      importedAt: Value(DateTime(2026, 1, 1).millisecondsSinceEpoch),
    ));
    await db.addVideoWatchStatistic(
      title: 'Beta',
      dateKey: '2026-07-12',
      subtitleChars: 1,
      watchTimeMs: 1000,
      bookUid: 'video/beta',
    );
  }

  const List<String> allTitles = <String>['Beta', 'Alpha 第10话', 'Alpha 第9话'];

  testWidgets('默认最近观看：看过的在前，没看过的按导入时间倒序；切名称/导入时间真重排 + 写穿偏好',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await seedThreeVideos();
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 默认 recent：Beta（watch-stats=now 最新）→ Alpha 第10话（导入 1/3）→
    // Alpha 第9话（导入 1/1）。
    expect(
      cardOrder(tester, allTitles),
      <String>['Beta', 'Alpha 第10话', 'Alpha 第9话'],
      reason: '默认「最近观看」：有观看痕迹者最前，其余退导入时间倒序',
    );

    // 切「名称」：natural 序 → 第9话 < 第10话 < Beta。
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.sort_title).last);
    await tester.pumpAndSettle();
    expect(
      cardOrder(tester, allTitles),
      <String>['Alpha 第9话', 'Alpha 第10话', 'Beta'],
      reason: '名称模式必须 natural 排序（第9话 < 第10话，不是字典序）',
    );
    expect(prefs.videoSortModeName, 'title', reason: '选择必须写穿偏好');

    // 切「导入时间」：新导入在前。
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.sort_imported).last);
    await tester.pumpAndSettle();
    expect(
      cardOrder(tester, allTitles),
      <String>['Alpha 第10话', 'Beta', 'Alpha 第9话'],
      reason: '导入时间模式：新导入在前',
    );
    expect(prefs.videoSortModeName, 'imported');
  });

  testWidgets('偏好持久化：带 video_sort_mode=title 开页直接按名称序渲染',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await seedThreeVideos();
    await prefs.setVideoSortModeName('title');
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(
      cardOrder(tester, allTitles),
      <String>['Alpha 第9话', 'Alpha 第10话', 'Beta'],
      reason: '开页读偏好：上次选的名称序直接生效',
    );
  });
}
