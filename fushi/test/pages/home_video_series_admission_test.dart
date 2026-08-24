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

/// BUG-1839：「系列」页的准入资格。
///
/// 曾经的判据是「必须有 AniDB primary identity」。用户真实库里 anidb 身份是 0 条
/// （AniDB HTTP 身份要求注册 client，没配就结构上写不出来），875 条 primary 全是
/// tmdb —— 于是整个系列页恒空，还被空态文案说成「没有书籍匹配所选标签」。
///
/// 用户拍板：**没刮削也应该进，合集就应该在系列里面**。系列与「全部视频」的区别
/// 是折叠方式（合集折成一张封面卡 vs 逐条平铺），不是刮削资格。下面四条把这个
/// 契约钉死，避免再按 provider 给页面加准入门。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('fushi_series_admission_pp');
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
    storeDir = Directory.systemTemp.createTempSync('fushi_series_admission');
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
                section: VideoLibrarySection.series,
              ),
            ),
          ),
        ),
      );

  Future<void> pumpSeries(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp());
    await tester.pumpAndSettle();
  }

  Future<void> seedVideo(String uid, String title) =>
      db.upsertVideoBook(VideoBooksCompanion(
        bookUid: Value<String>(uid),
        title: Value<String>(title),
        videoPath: Value<String>('/abs/$uid.mp4'),
        importedAt: Value<int>(DateTime(2026, 1, 4).millisecondsSinceEpoch),
      ));

  /// 用户库的真实形态：primary 身份是 tmdb，不是 anidb。
  Future<void> seedTmdbCollectionIdentity(int collectionId, String title) async {
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        mediaType: 'tv',
        title: title,
        collectionId: Value<int?>(collectionId),
        updatedAt: 0,
      ),
    );
    await db.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:$workId:tmdb',
          provider: 'tmdb',
          externalId: 'tmdb-$collectionId',
          isPrimary: const Value<bool>(true),
          updatedAt: 0,
        ),
      ],
    );
  }

  testWidgets('零刮削的普通合集出现在系列页（用户拍板：合集就该在系列里）',
      (WidgetTester tester) async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    final int cid =
        await db.createMediaCollection('我的合集', collectionType: 'playlist');
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');

    await pumpSeries(tester);

    expect(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
      findsOneWidget,
      reason: '一条刮削记录都没有的用户合集也必须折成合集卡进系列墙',
    );
    expect(find.text(t.tag_no_books_for_filter), findsNothing,
        reason: '库里有东西就不该落到「没有匹配」空态',
    );
  });

  testWidgets('零刮削的独立视频作为散卡出现在系列页', (WidgetTester tester) async {
    await seedVideo('video/loose', '没刮削的片子');

    await pumpSeries(tester);

    expect(
      find.byKey(const ValueKey<String>('home_video_video/loose')),
      findsOneWidget,
      reason: '散卡的入墙资格不看刮削身份',
    );
  });

  testWidgets('TMDB primary 身份（用户库真实形态）不再被挡在系列外',
      (WidgetTester tester) async {
    await seedVideo('video/tmdb-ep1', '第1集');
    final int cid =
        await db.createMediaCollection('TMDB 番', collectionType: 'playlist');
    await db.addToCollection(cid, MediaKind.video, 'video/tmdb-ep1');
    await seedTmdbCollectionIdentity(cid, 'TMDB 番');

    await pumpSeries(tester);

    expect(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
      findsOneWidget,
      reason: 'primary 是 tmdb 而非 anidb 时同样进系列——这正是整页变空的那条判据',
    );
  });

  testWidgets('父作品的花絮/短篇仍被排除（这条既有行为不受本次放宽影响）',
      (WidgetTester tester) async {
    await seedVideo('video/main', '正片');
    await seedVideo('video/extra', '花絮');
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        mediaType: 'tv',
        title: '正片',
        bookUid: const Value<String?>('video/main'),
        updatedAt: 0,
      ),
    );
    await db.upsertVideoMetadataExtra(
      VideoMetadataExtrasCompanion.insert(
        workId: workId,
        extraKey: 'work:$workId:extra:1',
        kind: 'featurette',
        sourceKind: 'local',
        title: '花絮',
        bookUid: const Value<String?>('video/extra'),
        updatedAt: 0,
      ),
    );

    await pumpSeries(tester);

    expect(
      find.byKey(const ValueKey<String>('home_video_video/main')),
      findsOneWidget,
      reason: '正片照常在',
    );
    expect(
      find.byKey(const ValueKey<String>('home_video_video/extra')),
      findsNothing,
      reason: '花絮不得再被拆成独立系列卡（放宽准入不等于放行花絮）',
    );
  });
}
