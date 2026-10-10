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
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-3235：视频库首屏「一块块加载」（用户实报：点开视频库，里面的视频是一块块出来的）。
///
/// 根因：本地列表、分组映射、远端清单各自 setState——列表先到就拿空映射画出
/// 全员散卡，映射到了再收拢成合集、换海报，远端收养后又整套重载映射两遍。
/// 这里钉死两件事：
/// * 映射未就位时三个分区都只画骨架，不拿空映射渲染散卡；
/// * 远端收养一次写入只换来一轮映射重载（不再被表变更防抖再补一轮）。
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

  late _CountingDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = _CountingDatabase();
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
    db.releaseCollections();
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp(VideoLibrarySection section, {RemoteVideoClient? remote}) =>
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
                remoteVideoClientLoader: remote == null
                    ? null
                    : () async => remote,
              ),
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

  void useDesktopView(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final VideoLibrarySection section in <VideoLibrarySection>[
    VideoLibrarySection.series,
    VideoLibrarySection.allVideos,
    VideoLibrarySection.home,
  ]) {
    testWidgets('映射未就位时 ${section.name} 只画骨架，不拿空映射铺散卡', (
      WidgetTester tester,
    ) async {
      useDesktopView(tester);
      final int cid = await seedSeriesAndLoose();
      db.holdCollections();

      await tester.pumpWidget(buildApp(section));
      // 列表早已到位、映射被卡住：逐帧推进，任何一帧都不许出现成员散卡。
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        expect(skeleton, findsOneWidget, reason: '第 $i 帧：映射未到应画骨架');
        expect(cardOf('video/ep1'), findsNothing, reason: '第 $i 帧：成员散卡提前出现');
        expect(cardOf('video/ep2'), findsNothing);
        expect(cardOf('video/loose'), findsNothing);
      }

      db.releaseCollections();
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

  testWidgets('远端收养一次写入只换来一轮映射重载', (WidgetTester tester) async {
    useDesktopView(tester);
    final List<RemoteVideoInfo> remoteVideos = <RemoteVideoInfo>[
      for (int i = 0; i < 6; i++)
        RemoteVideoInfo(
          id: 'remote-$i',
          title: 'Remote $i',
          collection: RemoteCollectionMembership(
            collectionName: 'Remote show',
            collectionType: 'collection',
            sortIndex: i,
          ),
        ),
    ];

    await tester.pumpWidget(
      buildApp(
        VideoLibrarySection.series,
        remote: _ListFakeRemoteVideoClient(remoteVideos),
      ),
    );
    await tester.pumpAndSettle();
    // 等防抖窗口过完，确认没有迟到的补刀重载。
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(
      (await db.getAllCollectionItems()).length,
      remoteVideos.length,
      reason: '前提：远端清单确实写进了合集表',
    );
    // 首屏一轮 + 收养写入后一轮。此前逐条事务收养 + 表变更防抖会再补一轮。
    expect(db.collectionReads, 2);
  });
}

/// 统计 / 卡住 [getAllMediaCollections]——它只被库页的整套映射重载读取，
/// 读一次 = 重载一轮。
class _CountingDatabase extends FushiDatabase {
  _CountingDatabase() : super.forTesting(NativeDatabase.memory());

  int collectionReads = 0;
  Completer<void>? _gate;

  void holdCollections() => _gate = Completer<void>();

  void releaseCollections() {
    final Completer<void>? gate = _gate;
    if (gate != null && !gate.isCompleted) gate.complete();
  }

  @override
  Future<List<MediaCollectionRow>> getAllMediaCollections() async {
    collectionReads++;
    await _gate?.future;
    return super.getAllMediaCollections();
  }
}

class _ListFakeRemoteVideoClient implements RemoteVideoClient {
  _ListFakeRemoteVideoClient(this._videos);
  final List<RemoteVideoInfo> _videos;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => _videos;

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async => const RemoteVideoStreamUrls(streamUrl: 'http://x/stream');

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    void Function(double progress)? onProgress,
    int episodeIndex = 0,
  }) async {}

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) async {}

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}
}
