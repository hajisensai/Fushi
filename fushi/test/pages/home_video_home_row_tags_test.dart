import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-1808：视频首页（[VideoLibrarySection.home]）横滚行卡必须画用户标签。
///
/// series-first 拆分把墙格从首页移去「系列 / 全部视频」后，首页只剩 hero + 三条
/// 横滚行；标签层当时只写在墙卡 `_buildCard` 上，于是「打了标签，首页一个都看不
/// 见」。这几条断言就是那个缺口的行为门：继续观看行的散卡、合集卡与最近添加行卡
/// 各自认自己那条标签，没打标签的卡不得凭空长出 chip。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('fushi_home_row_tags_pp');
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
    storeDir = Directory.systemTemp.createTempSync('fushi_home_row_tags_store');
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
            home: Scaffold(
              body: HomeVideoPage(
                repo: VideoBookRepository(db),
                section: VideoLibrarySection.home,
              ),
            ),
          ),
        ),
      );

  Future<void> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  /// 有播放痕迹（未看完）→ 进「继续观看」行。
  Future<void> seedInProgress(String uid, String title) =>
      db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(title),
        videoPath: Value<String>('/abs/$title.mp4'),
        lastPositionMs: const Value<int>(60000),
      ));

  Finder tagTextIn(String cardKey, String tagName) => find.descendant(
        of: find.byKey(ValueKey<String>(cardKey)),
        matching: find.text(tagName),
      );

  testWidgets('继续观看行的散卡显示该视频的标签', (WidgetTester tester) async {
    await seedInProgress('video/tagged', 'Tagged Show');
    await seedInProgress('video/plain', 'Plain Show');
    final int tagId = await db.createTag('WatchLater', 0xFF2196F3);
    await db.addTagToVideoBook('video/tagged', tagId);

    await pumpHome(tester);

    expect(
      tagTextIn('home_video_continue_video/tagged', 'WatchLater'),
      findsOneWidget,
      reason: '首页横滚卡必须和墙卡一样画出已打的标签（BUG-1808）',
    );
    expect(
      tagTextIn('home_video_continue_video/plain', 'WatchLater'),
      findsNothing,
      reason: '标签只属于打过它的那条视频，不得整行铺开',
    );
  });

  testWidgets('最近添加行的卡显示该视频的标签', (WidgetTester tester) async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value<String>('video/fresh'),
      title: const Value<String>('Fresh Show'),
      videoPath: const Value<String>('/abs/fresh.mp4'),
      importedAt: Value<int>(nowMs),
    ));
    final int tagId = await db.createTag('Backlog', 0xFF4CAF50);
    await db.addTagToVideoBook('video/fresh', tagId);

    await pumpHome(tester);

    expect(
      tagTextIn('home_video_recent_video/fresh', 'Backlog'),
      findsOneWidget,
      reason: '「最近添加」行卡与「继续观看」同一标签口径',
    );
  });

  testWidgets('继续观看行的合集卡显示合集自己的标签', (WidgetTester tester) async {
    final int cid =
        await db.createMediaCollection('MyShow', collectionType: 'playlist');
    await seedInProgress('video/ep1', 'Ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    final int tagId = await db.createTag('Airing', 0xFFFF9800);
    await db.addTagToCollection(cid, tagId);

    await pumpHome(tester);

    expect(
      tagTextIn('home_video_continue_collection_$cid', 'Airing'),
      findsOneWidget,
      reason: '合集的标签走 collectionTagMapProvider，与合集墙卡同一口径',
    );
  });
}
