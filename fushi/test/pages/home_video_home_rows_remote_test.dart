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
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 视频首页（[VideoLibrarySection.home]）三条横滚行的互联覆盖面。
///
/// 「继续观看」一直认远端，「下一集」「最近添加」此前结构上只装本地行——同一个
/// 合集在同一屏上一半互联一半不互联，host 上新入库的一批在子设备首页完全看不见。
/// 这两条断言就是那两个缺口的行为门。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('fushi_home_rows_remote_pp');
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
    storeDir = Directory.systemTemp.createTempSync('fushi_home_rows_store');
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

  Widget buildApp(RemoteVideoClient client) => ProviderScope(
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
                remoteVideoClientLoader: () async => client,
              ),
            ),
          ),
        ),
      );

  Future<void> sizeUp(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('「下一集」跨本地/远端合并选集：本机看到第 1 集，下一集指向 host 上的第 2 集',
      (WidgetTester tester) async {
    await sizeUp(tester);

    final int cid =
        await db.createMediaCollection('MyShow', collectionType: 'collection');
    // 本地第 1 集：有播放痕迹（未看完）→ latestPlayed = 0。
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/local-ep1'),
      title: Value('Local Ep1'),
      videoPath: Value('/abs/ep1.mp4'),
      lastPositionMs: Value(60000),
    ));
    await db.addToCollection(cid, MediaKind.video, 'video/local-ep1');

    await tester.pumpWidget(buildApp(_ListFakeRemoteVideoClient(
      <RemoteVideoInfo>[
        const RemoteVideoInfo(
          id: 'video/remote-ep2',
          title: 'Remote Ep2',
          collection: RemoteCollectionMembership(
            collectionName: 'MyShow',
            collectionType: 'collection',
            sortIndex: 1,
          ),
        ),
      ],
    )));
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey<String>('home_video_next_collection_$cid')),
      findsOneWidget,
      reason: '本地只有第 1 集、第 2 集在 host 上时，「下一集」行必须出现',
    );
    expect(
      find.text(t.video_home_next_episode_number(n: 2)),
      findsOneWidget,
      reason: '合并后的序列里下一集是第 2 集（远端那一集）',
    );
  });

  testWidgets('「最近添加」含 host 新入库的远端条目（host 下发 importedAt）',
      (WidgetTester tester) async {
    await sizeUp(tester);

    // 本机也有一条最近入库的散卡，确保整行本身会渲染。
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/local-new'),
      title: const Value('Local New'),
      videoPath: const Value('/abs/local-new.mp4'),
      importedAt: Value(nowMs - 1000),
    ));

    await tester.pumpWidget(buildApp(_ListFakeRemoteVideoClient(
      <RemoteVideoInfo>[
        RemoteVideoInfo(
          id: 'video/remote-new',
          title: 'Remote New',
          importedAt: nowMs,
        ),
      ],
    )));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>(
          'home_video_recent_remote_video_remote-new')),
      findsOneWidget,
      reason: 'host 带了入库时刻 → 远端条目必须进「最近添加」',
    );
  });

  testWidgets('旧 host 不带 importedAt → 远端不进「最近添加」（与改动前同行为）',
      (WidgetTester tester) async {
    await sizeUp(tester);

    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.upsertVideoBook(VideoBooksCompanion(
      bookUid: const Value('video/local-new'),
      title: const Value('Local New'),
      videoPath: const Value('/abs/local-new.mp4'),
      importedAt: Value(nowMs - 1000),
    ));

    await tester.pumpWidget(buildApp(_ListFakeRemoteVideoClient(
      <RemoteVideoInfo>[
        const RemoteVideoInfo(id: 'video/remote-old', title: 'Remote Old'),
      ],
    )));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>(
          'home_video_recent_remote_video_remote-old')),
      findsNothing,
      reason: '没有入库时刻就判不出「最近」，不能凭空造一个',
    );
  });
}

class _ListFakeRemoteVideoClient implements RemoteVideoClient {
  _ListFakeRemoteVideoClient(this._videos);
  final List<RemoteVideoInfo> _videos;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => _videos;

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(String id,
          {int episodeIndex = 0}) async =>
      const RemoteVideoStreamUrls(streamUrl: 'http://x/stream');

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
  }) async {}

  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async =>
      (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}
}
