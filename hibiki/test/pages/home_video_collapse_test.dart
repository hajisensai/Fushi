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

/// 视频页折叠语义退役守卫（用户拍板 2026-07-22 合集改封面卡）：
/// 封面卡无成员行可折叠——视频页不再渲染折叠 chevron、不再读写
/// `collapsed_collection_ids` 偏好（书架横排行照旧用它，组件行为见
/// collection_shelf_row_collapse_test）：
///  - 视频页合集渲染成封面卡：无折叠开关、成员卡不在库页；
///  - 带「已折叠」偏好开页 → 封面卡照常完整渲染（偏好对视频页无效且不被改写）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('hibiki_collapse_pp');
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
  late int collectionId;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_collapse');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);

    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/ep1'),
      title: const Value('第1集'),
      videoPath: const Value('/abs/ep1.mp4'),
      importedAt: Value(DateTime(2026, 1, 1).millisecondsSinceEpoch),
    ));
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/ep2'),
      title: const Value('第2集'),
      videoPath: const Value('/abs/ep2.mp4'),
      importedAt: Value(DateTime(2026, 1, 2).millisecondsSinceEpoch),
    ));
    collectionId = await db.createMediaCollection(
      '某番剧',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, MediaKind.video, 'video/ep1');
    await db.addToCollection(collectionId, MediaKind.video, 'video/ep2');
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

  testWidgets('合集渲染成封面卡：无折叠开关、成员卡不在库页', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey<String>('home_video_collection_card_$collectionId')),
      findsOneWidget,
      reason: '合集必须渲染成封面卡',
    );
    // TODO-2486：hero 轮播另有一份合集名，按卡内 descendant 断言。
    expect(
      find.descendant(
        of: find
            .byKey(ValueKey<String>('home_video_collection_card_$collectionId')),
        matching: find.text('某番剧'),
      ),
      findsOneWidget,
      reason: '卡 footer 显示合集名',
    );
    expect(find.text('第1集'), findsNothing, reason: '成员卡收进详情页，不在库页');
    expect(find.text('第2集'), findsNothing);
    expect(find.byTooltip(t.collection_collapse), findsNothing,
        reason: '封面卡无成员行可折叠——不得再渲染折叠开关');
    expect(find.byTooltip(t.collection_expand), findsNothing);
  });

  testWidgets('带「已折叠」偏好开页：封面卡照常完整渲染、偏好不被视频页改写', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await prefs.setCollapsedCollectionIds(<int>{collectionId});
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey<String>('home_video_collection_card_$collectionId')),
      findsOneWidget,
      reason: '旧折叠偏好对封面卡无效：卡照常渲染',
    );
    expect(
      find.descendant(
        of: find
            .byKey(ValueKey<String>('home_video_collection_card_$collectionId')),
        matching: find.text('某番剧'),
      ),
      findsOneWidget,
    );
    // 偏好保持原样（书架还在用；视频页不再读写它）。
    expect(prefs.collapsedCollectionIds, contains(collectionId),
        reason: '视频页不得改写 collapsed_collection_ids（书架仍在用）');
  });
}
