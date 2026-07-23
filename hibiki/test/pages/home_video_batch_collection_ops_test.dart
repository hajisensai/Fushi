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

/// 块2/3/4 视频库批量合集操作 widget 测试（真写穿内存 DB）：
///  - 多选态合集整选（封面卡整卡勾选 → 合集入选中集；成员卡收进详情页不在库页）；
///  - 组合三档（新建 / 并入 / 合并默认名）；
///  - 删除区分（解散不删媒体行 / 混选计数文案）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_batch_ops_pp');
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
    storeDir = Directory.systemTemp.createTempSync('hibiki_batch_ops');
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

  Future<void> seedVideo(String uid, String title) async {
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: Value(uid),
      title: Value(title),
      videoPath: Value('/abs/$uid.mp4'),
      importedAt: Value(DateTime(2026, 1, 1)),
    ));
  }

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

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  Future<void> enterSelectionMode(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();
  }

  testWidgets('块2：合集封面卡勾选 → 整合集入选中集；成员卡不在库页', (WidgetTester tester) async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    final int cid = await db.createMediaCollection('合集甲');
    await db.addToCollection(cid, 'video', 'video/ep1');
    await db.addToCollection(cid, 'video', 'video/ep2');

    await pumpPage(tester);
    await enterSelectionMode(tester);

    // 进多选态：合集封面卡带 1 个勾选框（透明对勾）；成员卡不在库页（收进详情页）。
    expect(
      find.descendant(
        of: find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
      reason: '合集封面卡多选态画整选勾选框',
    );
    expect(
      find.byKey(const ValueKey<String>('home_video_video/ep1')),
      findsNothing,
      reason: '合集成员卡不在库页（封面卡形态），无从单独勾选',
    );

    // 点合集卡 → 整合集入选中集，底栏计数 = 1。
    await tester.tap(find.text('合集甲'));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_selected_count(n: 1)), findsOneWidget,
        reason: '整卡勾选把合集计入选中集');
  });

  testWidgets('块3 档1：仅散卡 → 命名弹窗新建合集', (WidgetTester tester) async {
    await seedVideo('video/looseA', 'Alpha');
    await seedVideo('video/looseB', 'Beta');

    await pumpPage(tester);
    await enterSelectionMode(tester);

    await tester
        .tap(find.byKey(const ValueKey<String>('home_video_video/looseA')));
    await tester.pump();
    await tester
        .tap(find.byKey(const ValueKey<String>('home_video_video/looseB')));
    await tester.pump();

    await tester
        .tap(find.byKey(const ValueKey<String>('home_video_batch_combine')));
    await tester.pumpAndSettle();
    // 档1 弹命名框，确认。
    expect(find.text(t.dialog_ok), findsOneWidget, reason: '仅散卡应弹命名框');
    await tester.tap(find.text(t.dialog_ok));
    await tester.pumpAndSettle();

    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    expect(collections.length, 1, reason: '新建一个合集');
    final List<MediaCollectionItemRow> members =
        await db.getCollectionItems(collections.single.id);
    expect(members.map((MediaCollectionItemRow m) => m.entryKey).toSet(),
        <String>{'video/looseA', 'video/looseB'});
  });

  testWidgets('块3 档2：1 合集 + 散卡 → 并入该合集（不弹命名）', (WidgetTester tester) async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    await seedVideo('video/looseL', '散卡L');
    final int cid = await db.createMediaCollection('合集乙');
    await db.addToCollection(cid, 'video', 'video/ep1');
    await db.addToCollection(cid, 'video', 'video/ep2');

    await pumpPage(tester);
    await enterSelectionMode(tester);

    await tester.tap(find.text('合集乙')); // 选合集
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey<String>('home_video_video/looseL')));
    await tester.pump();

    await tester
        .tap(find.byKey(const ValueKey<String>('home_video_batch_combine')));
    await tester.pumpAndSettle();
    // 档2 不弹命名框。
    expect(find.text(t.dialog_ok), findsNothing, reason: '并入不应弹命名框');

    final List<MediaCollectionItemRow> members =
        await db.getCollectionItems(cid);
    expect(members.map((MediaCollectionItemRow m) => m.entryKey).toSet(),
        <String>{'video/ep1', 'video/ep2', 'video/looseL'},
        reason: '散卡并入现有合集');
    expect((await db.getAllMediaCollections()).length, 1, reason: '不新建合集');
  });

  testWidgets('块3 档3：≥2 合集 → 合并成一个（默认名=成员最多合集名）', (WidgetTester tester) async {
    await seedVideo('video/a1', 'A1');
    await seedVideo('video/a2', 'A2');
    await seedVideo('video/b1', 'B1');
    await seedVideo('video/b2', 'B2');
    await seedVideo('video/b3', 'B3');
    final int small = await db.createMediaCollection('小集');
    await db.addToCollection(small, 'video', 'video/a1');
    await db.addToCollection(small, 'video', 'video/a2');
    final int big = await db.createMediaCollection('大集');
    await db.addToCollection(big, 'video', 'video/b1');
    await db.addToCollection(big, 'video', 'video/b2');
    await db.addToCollection(big, 'video', 'video/b3');

    await pumpPage(tester);
    await enterSelectionMode(tester);

    await tester.tap(find.text('小集'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('大集'));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('home_video_batch_combine')));
    await tester.pumpAndSettle();
    // 合并弹命名框，默认名 = 成员最多合集名（大集，3 > 2）。
    final EditableText field = tester.widget<EditableText>(
      find.byType(EditableText),
    );
    expect(field.controller.text, '大集', reason: '默认名=成员最多合集名');
    await tester.tap(find.text(t.dialog_ok));
    await tester.pumpAndSettle();

    final List<MediaCollectionRow> collections =
        await db.getAllMediaCollections();
    expect(collections.length, 1, reason: '合并成一个合集（其余解散）');
    final List<MediaCollectionItemRow> members =
        await db.getCollectionItems(big);
    expect(members.map((MediaCollectionItemRow m) => m.entryKey).toSet(),
        <String>{'video/a1', 'video/a2', 'video/b1', 'video/b2', 'video/b3'},
        reason: '目标合集吸收其余合集全部成员');
    expect(await db.getMediaCollectionById(small), isNull, reason: '其余合集被解散');
  });

  testWidgets('块4：选中合集 → 解散（deleteMediaCollection 不删媒体本体）',
      (WidgetTester tester) async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    final int cid = await db.createMediaCollection('待解散');
    await db.addToCollection(cid, 'video', 'video/ep1');
    await db.addToCollection(cid, 'video', 'video/ep2');

    await pumpPage(tester);
    await enterSelectionMode(tester);
    await tester.tap(find.text('待解散'));
    await tester.pumpAndSettle();

    await tester
        .tap(find.byKey(const ValueKey<String>('home_video_batch_delete')));
    await tester.pumpAndSettle();
    // 纯合集 → 解散确认文案。
    expect(find.text(t.batch_dissolve_confirm(m: 1)), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, t.dialog_delete));
    await tester.pumpAndSettle();

    expect(await db.getMediaCollectionById(cid), isNull, reason: '合集被解散');
    // 媒体本体保留（解散只解除分组）。
    final VideoBookRepository repo = VideoBookRepository(db);
    expect(await repo.getByBookUid('video/ep1'), isNotNull, reason: '解散不删媒体行');
    expect(await repo.getByBookUid('video/ep2'), isNotNull);
  });

  testWidgets('块4：混选删除确认文案写明「删 N 个媒体、解散 M 个合集」', (WidgetTester tester) async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    await seedVideo('video/looseL', '散卡L');
    final int cid = await db.createMediaCollection('某合集');
    await db.addToCollection(cid, 'video', 'video/ep1');
    await db.addToCollection(cid, 'video', 'video/ep2');

    await pumpPage(tester);
    await enterSelectionMode(tester);
    await tester.tap(find.text('某合集'));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const ValueKey<String>('home_video_video/looseL')));
    await tester.pump();

    await tester
        .tap(find.byKey(const ValueKey<String>('home_video_batch_delete')));
    await tester.pumpAndSettle();
    expect(find.text(t.batch_delete_mixed_confirm(n: 1, m: 1)), findsOneWidget,
        reason: '混选确认文案含媒体数 + 合集数');
  });
}
