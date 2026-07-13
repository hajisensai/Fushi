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

/// 去碎片方案 A（spec 2026-07-12-shelf-grid-defrag，已拍板：分区+顶部）：
/// 构造一个**旧交错布局必然切碎网格**的排序局面——「最近」模式下散卡 A >
/// 合集 > 散卡 B——锁死分区后的两条不变量：
///  ① 合集行渲染在所有散卡之上（顶部合集区），即使某散卡比它「更最近」；
///  ② 两张散卡同行渲染（单一网格；旧布局它们被合集行切成两段、各占一残行）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_partition_pp');
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
    storeDir = Directory.systemTemp.createTempSync('hibiki_partition');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);

    // 合集（2 集，成员 recent = importedAt 1/4）。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/ep1'),
      title: const Value('第1集'),
      videoPath: const Value('/abs/ep1.mp4'),
      importedAt: Value(DateTime(2026, 1, 4)),
    ));
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/ep2'),
      title: const Value('第2集'),
      videoPath: const Value('/abs/ep2.mp4'),
      importedAt: Value(DateTime(2026, 1, 2)),
    ));
    final int collectionId = await db.createMediaCollection(
      '某番剧',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, 'video', 'video/ep1');
    await db.addToCollection(collectionId, 'video', 'video/ep2');

    // 散卡 A：watch-stats = now（「最近」序里排最前，旧布局会压在合集行之上）。
    // 不设 lastPositionMs——带进度行的卡标题 y 会比无进度卡低，干扰同行断言。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/looseA'),
      title: const Value('Loose New'),
      videoPath: const Value('/abs/loose_a.mp4'),
      importedAt: Value(DateTime(2026, 1, 5)),
    ));
    await db.addVideoWatchStatistic(
      title: 'Loose New',
      dateKey: '2026-07-12',
      subtitleChars: 1,
      watchTimeMs: 1000,
      bookUid: 'video/looseA',
    );
    // 散卡 B：importedAt 1/3（「最近」序里排在合集 1/4 之后——旧交错布局下
    // A 与 B 被合集行切成两个残段）。
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/looseB'),
      title: const Value('Loose Old'),
      videoPath: const Value('/abs/loose_b.mp4'),
      importedAt: Value(DateTime(2026, 1, 3)),
    ));
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

  testWidgets('合集区在所有散卡之上；两张散卡同行（单一网格无切碎）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    final double headerTop = tester.getTopLeft(find.text('某番剧').last).dy;
    final double looseATop = tester.getTopLeft(find.text('Loose New').last).dy;
    final double looseBTop = tester.getTopLeft(find.text('Loose Old').last).dy;

    expect(headerTop, lessThan(looseATop),
        reason: '合集区必须在散卡之上——即使散卡「更最近」（方案 A 顶部拍板）');
    expect(headerTop, lessThan(looseBTop));
    // 单一网格 = 恰好一个 SliverGrid（旧交错布局把 A/B 切成两个网格段）。
    // 不比标题 y 等值：卡内徽章/进度行会让同一网格行里的标题差十几像素。
    expect(find.byType(SliverGrid), findsOneWidget,
        reason: '散卡必须合成单一网格；旧交错布局是两个残段网格');
  });
}
