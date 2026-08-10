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

/// 多端库联合视图 §2.3 任务10：远端视频占位卡的合集归属。host 下发的
/// [RemoteVideoInfo.collection]（自然键 name+type）解析到本地合集 → 远端占位折进该
/// 合集（封面卡形态：计入集数角标 + 卡带云角标，成员收进详情页）；解析不到本地
/// 合集 → 散卡降级（不硬造合集卡）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_coll_video_pp');
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
    storeDir = Directory.systemTemp.createTempSync('hibiki_remote_coll_store');
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
                // #792 分区化：home 分区只渲染 dashboard 概览，合集封面卡与远端
                // 占位卡所在的混排墙（_buildLocalVideoSlivers）搬进了 series 分区。
                section: VideoLibrarySection.series,
                remoteVideoClientLoader: () async => client,
                remoteVideoDownloadDestination: (RemoteVideoInfo v) async =>
                    File('${pathProviderDir.path}/${v.id.hashCode}.mp4'),
              ),
            ),
          ),
        ),
      );

  testWidgets('远端归属命中本地合集 → 折进合集封面卡（计数含远端 + 云角标）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 本地合集 + 本地成员一集。
    final int cid =
        await db.createMediaCollection('MyShow', collectionType: 'collection');
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/local-ep1'),
      title: Value('Local Ep1'),
      videoPath: Value('/abs/ep1.mp4'),
    ));
    await db.addToCollection(cid, MediaKind.video, 'video/local-ep1');

    // 远端有归属同一合集的第二集。
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

    final Finder collectionCard =
        find.byKey(ValueKey<String>('home_video_collection_card_$cid'));
    expect(collectionCard, findsOneWidget, reason: '本地合集封面卡必须渲染');
    // 远端成员折进合集卡：不再单独渲染散卡（成员收进详情页）。
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_video_remote-ep2')),
      findsNothing,
      reason: '远端占位归属命中本地合集 → 折进合集卡，不再渲染独立散卡',
    );
    // 集数角标含远端占位成员（BUG-790 口径：1 本地 + 1 远端 = 2）。
    expect(
      find.descendant(
        of: collectionCard,
        matching: find.text(t.video_playlist_episodes(count: 2)),
      ),
      findsOneWidget,
      reason: '集数角标必须计入远端占位成员（本地+远端同源）',
    );
    // 含远端占位成员 → 合集卡右上云角标。
    expect(
      find.byKey(ValueKey<String>('home_video_collection_cloud_$cid')),
      findsOneWidget,
      reason: '含远端占位成员的合集卡必须带云角标',
    );
  });

  testWidgets('远端归属解析不到本地合集 → 散卡降级（进散卡网格，不折行）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 本地无 'Ghost' 合集，只有一本散视频占位判定基线。
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/local-1'),
      title: Value('Local One'),
      videoPath: Value('/abs/local-1.mp4'),
    ));

    await tester.pumpWidget(buildApp(_ListFakeRemoteVideoClient(
      <RemoteVideoInfo>[
        const RemoteVideoInfo(
          id: 'video/remote-orphan',
          title: 'Remote Orphan',
          collection: RemoteCollectionMembership(
            collectionName: 'Ghost',
            collectionType: 'collection',
            sortIndex: 0,
          ),
        ),
      ],
    )));
    await tester.pumpAndSettle();

    final Finder remoteCard = find
        .byKey(const ValueKey<String>('remote_video_card_video_remote-orphan'));
    expect(remoteCard, findsOneWidget);
    // 归属解析不到 → 散卡降级：进主散卡网格，且不在任何合集横排行内。
    expect(
      find.ancestor(of: remoteCard, matching: find.byType(Wrap)),
      findsOneWidget,
      reason: '归属解析不到本地合集 → 占位卡落散卡网格（散卡降级）',
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
