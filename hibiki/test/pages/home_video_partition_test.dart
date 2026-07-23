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

/// 去碎片方案 A（spec 2026-07-12 分区拍板）+ 封面卡形态（用户拍板 2026-07-22）：
/// 构造「最近」模式下散卡 A > 合集 > 散卡 B 的排序局面，锁死两条不变量：
///  ① 合集封面卡在网格里排在所有散卡之前（合集区在前），即使某散卡比它「更最近」；
///  ② 合集卡与散卡合成**单一** [SliverGrid]（旧横排行形态是「行 slivers + 网格」
///     两段式；更旧的交错布局把散卡切成多个残段网格）。
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

  testWidgets('合集封面卡排在所有散卡之前；合集卡+散卡合成单一网格', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    // 网格 cell 序 = 阅读序（先行后列）：合集卡必须在两张散卡之前——即使散卡
    // 「更最近」（方案 A 合集区在前拍板；封面卡形态下体现为网格前排 cell）。
    final Offset collectionPos = tester.getTopLeft(find.text('某番剧').last);
    final Offset looseAPos = tester.getTopLeft(find.text('Loose New').last);
    final Offset looseBPos = tester.getTopLeft(find.text('Loose Old').last);
    bool cellBefore(Offset a, Offset b) =>
        a.dy < b.dy || (a.dy == b.dy && a.dx < b.dx);
    expect(cellBefore(collectionPos, looseAPos), isTrue,
        reason: '合集卡必须排在散卡之前——即使散卡「更最近」');
    expect(cellBefore(collectionPos, looseBPos), isTrue);
    // 单一网格 = 恰好一个 SliverGrid（合集卡与散卡同网格；旧横排行形态是
    // 「行 slivers + 网格」两段式，更旧的交错布局把散卡切成两个网格段）。
    expect(find.byType(SliverGrid), findsOneWidget, reason: '合集卡与散卡必须合成单一网格');
    // 封面卡形态：合集卡在，成员卡不再出现在库页（成员收进详情页）。
    expect(
      find.byKey(const ValueKey<String>('home_video_video/ep1')),
      findsNothing,
      reason: '合集成员卡不再直接渲染在库页（封面卡形态）',
    );
  });
}
