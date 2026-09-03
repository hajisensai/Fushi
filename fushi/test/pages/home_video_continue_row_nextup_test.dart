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

/// 视频首页「继续观看」行的 Next-Up 语义（用户实报）：一集从头看到尾再退出，
/// 合集就从「继续观看」消失、只剩「下一集」行有它；中途退出的反而在。同一部番在
/// 首页时有时无，而 hero 大卡的「继续看·第 N 集」早就是「看完 → 下一集」口径。
///
/// 这里断言：最近播放那集已看完 → 继续行仍出该合集卡、指向下一集、文案是
/// 「下一集 · 第 N 集」；整部看完 → 不进继续行。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_home_continue_nextup_pp',
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
    storeDir = Directory.systemTemp.createTempSync(
      'fushi_home_continue_nextup_store',
    );
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

  Widget buildApp({VideoLibrarySection section = VideoLibrarySection.home}) =>
      ProviderScope(
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
                section: section,
              ),
            ),
          ),
        ),
      );

  Future<void> pumpHome(
    WidgetTester tester, {
    VideoLibrarySection section = VideoLibrarySection.home,
  }) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(buildApp(section: section));
    await tester.pumpAndSettle();
  }

  Future<void> seedEpisode(
    String uid,
    String title, {
    int positionMs = 0,
    bool completed = false,
    int? lastPlayedAt,
  }) => db.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(title),
      videoPath: Value<String>('/abs/$title.mp4'),
      lastPositionMs: Value<int>(positionMs),
      completedAt: Value<DateTime?>(completed ? DateTime.now() : null),
      lastPlayedAt: Value<int?>(lastPlayedAt),
    ),
  );

  Finder continueCard(int cid) =>
      find.byKey(ValueKey<String>('home_video_continue_collection_$cid'));

  testWidgets('最近播放那集已看完 → 继续观看行指向下一集', (WidgetTester tester) async {
    final int cid = await db.createMediaCollection(
      'Yuru Yuri',
      collectionType: 'playlist',
    );
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await seedEpisode(
      'video/yy-ep1',
      'YY Ep1',
      positionMs: 1,
      completed: true,
      lastPlayedAt: nowMs,
    );
    await seedEpisode('video/yy-ep2', 'YY Ep2');
    await db.addToCollection(cid, MediaKind.video, 'video/yy-ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/yy-ep2');

    await pumpHome(tester);

    expect(continueCard(cid), findsOneWidget, reason: '看完一集退出后，合集不能从「继续观看」消失');
    expect(
      find.descendant(
        of: continueCard(cid),
        matching: find.text(t.video_home_next_episode_number(n: 2)),
      ),
      findsOneWidget,
      reason: '目标是还没开播的下一集，文案应是「下一集 · 第 2 集」而非「看到第 2 集」',
    );
    expect(
      find.byKey(ValueKey<String>('home_video_next_collection_$cid')),
      findsOneWidget,
      reason: '「下一集」行照旧有它——两行各放一份',
    );
  });

  testWidgets('最近播放那集没看完 → 继续观看行停在它自己', (WidgetTester tester) async {
    final int cid = await db.createMediaCollection(
      'Mid Show',
      collectionType: 'playlist',
    );
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await seedEpisode(
      'video/mid-ep1',
      'Mid Ep1',
      positionMs: 1,
      completed: true,
      lastPlayedAt: nowMs - 1000,
    );
    await seedEpisode(
      'video/mid-ep2',
      'Mid Ep2',
      positionMs: 60000,
      lastPlayedAt: nowMs,
    );
    await seedEpisode('video/mid-ep3', 'Mid Ep3');
    for (final String uid in <String>[
      'video/mid-ep1',
      'video/mid-ep2',
      'video/mid-ep3',
    ]) {
      await db.addToCollection(cid, MediaKind.video, uid);
    }

    await pumpHome(tester);

    expect(continueCard(cid), findsOneWidget);
    expect(
      find.descendant(
        of: continueCard(cid),
        matching: find.textContaining(
          t.video_home_continue_episode_number(n: 2),
        ),
      ),
      findsOneWidget,
      reason: '中途退出仍是「看到第 2 集」，不得跳到第 3 集',
    );
  });

  testWidgets('整部看完 → 不进继续观看行', (WidgetTester tester) async {
    final int cid = await db.createMediaCollection(
      'Done Show',
      collectionType: 'playlist',
    );
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await seedEpisode(
      'video/done-ep1',
      'Done Ep1',
      positionMs: 1,
      completed: true,
      lastPlayedAt: nowMs - 1000,
    );
    await seedEpisode(
      'video/done-ep2',
      'Done Ep2',
      positionMs: 1,
      completed: true,
      lastPlayedAt: nowMs,
    );
    await db.addToCollection(cid, MediaKind.video, 'video/done-ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/done-ep2');

    await pumpHome(tester);

    expect(
      continueCard(cid),
      findsNothing,
      reason: '没有下一集可续，整部看完的合集不该赖在「继续观看」',
    );
    expect(
      find.byKey(ValueKey<String>('home_video_next_collection_$cid')),
      findsNothing,
    );
  });
}
