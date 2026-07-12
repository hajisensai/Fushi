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

/// 合集行折叠端到端接线（视频库页；书架共用同一 CollectionShelfRow +
/// `collapsed_collection_ids` 偏好，组件行为见 collection_shelf_row_collapse_test）：
///  - 点行头 chevron 折叠 → 成员卡消失、行头仍在；
///  - 折叠集写穿偏好（跨启动记住）；
///  - 带已折叠偏好开页 → 直接折叠渲染。
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
      importedAt: Value(DateTime(2026, 1, 1)),
    ));
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/ep2'),
      title: const Value('第2集'),
      videoPath: const Value('/abs/ep2.mp4'),
      importedAt: Value(DateTime(2026, 1, 2)),
    ));
    collectionId = await db.createMediaCollection(
      '某番剧',
      collectionType: 'playlist',
    );
    await db.addToCollection(collectionId, 'video', 'video/ep1');
    await db.addToCollection(collectionId, 'video', 'video/ep2');
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

  testWidgets('点行头 chevron 折叠：成员卡消失、行头仍在、偏好写穿', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('某番剧'), findsOneWidget, reason: '合集行头在');
    expect(find.text('第1集'), findsWidgets, reason: '展开态成员卡在');

    await tester.tap(find.byTooltip(t.collection_collapse));
    await tester.pumpAndSettle();

    expect(find.text('某番剧'), findsOneWidget, reason: '折叠后行头仍在');
    expect(find.text('第1集'), findsNothing, reason: '折叠后成员卡消失');
    expect(find.text('第2集'), findsNothing);
    expect(
      prefs.collapsedCollectionIds,
      contains(collectionId),
      reason: '折叠集必须写穿偏好（跨启动记住）',
    );

    // 再点展开：成员回来、偏好清除。
    await tester.tap(find.byTooltip(t.collection_expand));
    await tester.pumpAndSettle();
    expect(find.text('第1集'), findsWidgets);
    expect(prefs.collapsedCollectionIds, isNot(contains(collectionId)));
  });

  testWidgets('带已折叠偏好开页：直接折叠渲染', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await prefs.setCollapsedCollectionIds(<int>{collectionId});
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();

    expect(find.text('某番剧'), findsOneWidget);
    expect(find.text('第1集'), findsNothing, reason: '开页读偏好：上次折叠的合集保持折叠');
  });
}
