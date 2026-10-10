import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-3235：视频库首屏「一块块加载」（用户实报：点开视频库，里面的视频是一块块
/// 出来的）。
///
/// 根因：本地列表与分组映射各自 setState——列表先到就拿**空映射**画出全员散卡，
/// 映射（十几张表）到了再收拢成合集、换刮削海报。这里钉死：映射未就位时三个
/// 分区都只画骨架，任何一帧都不拿空映射渲染散卡；映射一到整墙一次换成终态。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_video_first_paint_pp',
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

  late _GatedMapsDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = _GatedMapsDatabase();
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_video_first_paint');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    db.release();
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp(VideoLibrarySection section) => ProviderScope(
    overrides: <Override>[
      platformServicesProvider.overrideWithValue(platformServices),
      ankiRepositoryProvider.overrideWithValue(ankiRepository),
      appProvider.overrideWith((ref) => appModel),
    ],
    child: TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: HomeVideoPage(repo: VideoBookRepository(db), section: section),
        ),
      ),
    ),
  );

  Future<void> seedVideo(String uid, String title) => db.upsertVideoBook(
    VideoBooksCompanion(
      bookUid: Value<String>(uid),
      title: Value<String>(title),
      videoPath: Value<String>('/abs/$uid.mp4'),
      importedAt: Value<int>(DateTime(2026, 1, 4).millisecondsSinceEpoch),
    ),
  );

  /// 一部两集的番（合集）+ 一部没归系列的散片。
  Future<int> seedSeriesAndLoose() async {
    await seedVideo('video/ep1', '第1集');
    await seedVideo('video/ep2', '第2集');
    await seedVideo('video/loose', '散片');
    final int cid = await db.createMediaCollection(
      '我的番',
      collectionType: 'playlist',
    );
    await db.addToCollection(cid, MediaKind.video, 'video/ep1');
    await db.addToCollection(cid, MediaKind.video, 'video/ep2');
    return cid;
  }

  Finder cardOf(String uid) => find.byKey(ValueKey<String>('home_video_$uid'));
  final Finder skeleton = find.byKey(
    const ValueKey<String>('home_video_library_maps_pending'),
  );

  for (final VideoLibrarySection section in <VideoLibrarySection>[
    VideoLibrarySection.series,
    VideoLibrarySection.allVideos,
    VideoLibrarySection.home,
  ]) {
    testWidgets('映射未就位时 ${section.name} 只画骨架，不拿空映射铺散卡', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final int cid = await seedSeriesAndLoose();
      db.hold();

      await tester.pumpWidget(buildApp(section));
      // 列表早已到位、映射被卡住：逐帧推进，任何一帧都不许出现散卡。
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(skeleton, findsOneWidget, reason: '第 $i 帧：映射未到应画骨架');
        expect(cardOf('video/ep1'), findsNothing, reason: '第 $i 帧：成员散卡提前出现');
        expect(cardOf('video/ep2'), findsNothing);
        expect(cardOf('video/loose'), findsNothing);
      }

      db.release();
      await tester.pumpAndSettle();

      expect(skeleton, findsNothing);
      switch (section) {
        case VideoLibrarySection.series:
          expect(
            find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
            findsOneWidget,
          );
          expect(cardOf('video/ep1'), findsNothing, reason: '成员折进合集卡');
          expect(cardOf('video/loose'), findsOneWidget);
        case VideoLibrarySection.allVideos:
          // BUG-2835 默认「非系列」：映射到了才知道谁是成员。
          expect(cardOf('video/ep1'), findsNothing);
          expect(cardOf('video/loose'), findsOneWidget);
        default:
          break;
      }
    });
  }
}

/// 卡住 [getAllMediaCollections]——它只被库页的整套映射加载读取，卡住它 = 映射
/// 迟迟不到，而本地列表照常返回（正是真机上大库的时序）。
class _GatedMapsDatabase extends FushiDatabase {
  _GatedMapsDatabase() : super.forTesting(NativeDatabase.memory());

  Completer<void>? _gate;

  void hold() => _gate = Completer<void>();

  void release() {
    final Completer<void>? gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<List<MediaCollectionRow>> getAllMediaCollections() async {
    await _gate?.future;
    return super.getAllMediaCollections();
  }
}
