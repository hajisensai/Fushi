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
import '../helpers/series_scrape_seed.dart';
import '../helpers/test_platform_services.dart';

/// 多端库联合视图 §2.3 任务10：远端视频占位卡的合集归属。
///
/// ⚠️ 契约在 2026-08-24（PR #954 的「系列只收 AniDB 已刮削作品」）**变了**：
/// 远端占位没有本机 canonical identity，不得仅凭同名合集混进「系列」墙
/// （`home_video_page._buildLocalVideoSlivers` 的 `groupedRemoteVideos` 在
/// series 分区恒空）。于是「远端占位折进本地合集卡、计进集数角标、卡带云角标」
/// 这条能力**已不存在**：远端占位现在只出现在「全部视频」与首页远端联合视图，
/// 而那两处不做合集折叠。本文件因此改为守新契约——系列墙渲染本地合集卡但不含
/// 远端、全部视频渲染远端散卡但不折合集——原来的折叠断言不是被放宽，是它守的
/// 那个行为被有意移除了。
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

  Widget buildApp(
    RemoteVideoClient client, {
    VideoLibrarySection section = VideoLibrarySection.allVideos,
  }) =>
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
                // #792 分区化：home 分区只渲染 dashboard 概览，混排墙在 series；
                // 远端占位则只在「全部视频」出现（见文件头的契约变更说明），故
                // 两个分区都要测，由调用方指定。
                section: section,
                remoteVideoClientLoader: () async => client,
                remoteVideoDownloadDestination: (RemoteVideoInfo v) async =>
                    File('${pathProviderDir.path}/${v.id.hashCode}.mp4'),
              ),
            ),
          ),
        ),
      );

  testWidgets('系列墙：远端占位照常折进本地合集（BUG-1839 准入不再看 canonical 身份）',
      (WidgetTester tester) async {
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
    // BUG-1839 起入墙资格不再看刮削身份；这里仍种一条 AniDB 作品身份，是为了让
    // 本用例与改动前逐字节可比（种不种都该渲染，见 home_video_series_admission_test）。
    await seedAniDbSeriesIdentity(db, cid, title: 'MyShow');

    // 远端有归属同一合集的第二集。
    await tester.pumpWidget(buildApp(
      _ListFakeRemoteVideoClient(
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
      ),
      section: VideoLibrarySection.series,
    ));
    await tester.pumpAndSettle();

    final Finder collectionCard =
        find.byKey(ValueKey<String>('home_video_collection_card_$cid'));
    expect(collectionCard, findsOneWidget, reason: '本地合集封面卡必须渲染');
    // 远端那一集折进合集卡，不另出独立散卡。
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_video_remote-ep2')),
      findsNothing,
      reason: '归属解析得到本地合集 → 折进合集卡，不降级成散卡',
    );
    // 集数角标含远端成员：1 本地 + 1 远端 = 2。PR #954 曾按「远端无 canonical 身份」
    // 把远端整体挡在系列外（角标退回 1），BUG-1839 撤掉准入门后这条依据一并失效——
    // 否则同一部剧在系列页看着比「全部视频」少集。
    expect(
      find.descendant(
        of: collectionCard,
        matching: find.text(t.video_playlist_episodes(count: 2)),
      ),
      findsOneWidget,
      reason: '系列墙的集数角标必须含 host 上那一集',
    );
    // 含远端成员 → 云角标回来。
    expect(
      find.byKey(ValueKey<String>('home_video_collection_cloud_$cid')),
      findsOneWidget,
      reason: '合集含远端成员就该画云角标，与全部视频同口径',
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

  testWidgets('BUG-1699：合集落库后视频页自动重组（无需下拉刷新/重启）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // BUG-1699 守的是「_collectionsById 不能停在首帧快照」，与「谁被折叠」无关。
    // 原用例拿远端占位当被折叠方，而远端占位已不进系列墙（见文件头契约变更），
    // 于是改用**本地视频**：它同样只有在合集表变化被监听到之后才会折进合集卡。
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/late-ep1'),
      title: Value('Late Ep1'),
      videoPath: Value('/abs/late1.mp4'),
    ));
    await seedAniDbLooseIdentity(db, 'video/late-ep1', title: 'Late Ep1');

    await tester.pumpWidget(buildApp(
      _ListFakeRemoteVideoClient(const <RemoteVideoInfo>[]),
      section: VideoLibrarySection.series,
    ));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('home_video_video/late-ep1')),
      findsOneWidget,
      reason: '前置：合集未落库时该视频是散卡',
    );

    // 模拟后台合集同步落库（互联 live / 云清单 / 备份导入任一写入者）。
    final int cid = await db.createMediaCollection('LateShow',
        collectionType: 'collection');
    await db.addToCollection(cid, MediaKind.video, 'video/late-ep1');
    await seedAniDbSeriesIdentity(db, cid, title: 'LateShow');
    // 合集表 watch 有 300ms 合并窗口。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(
      find.byKey(ValueKey<String>('home_video_collection_card_$cid')),
      findsOneWidget,
      reason: '合集落库后无需任何手动刷新即渲染合集封面卡（BUG-1699 主诉：'
          '此前 _collectionsById 停在首帧快照，恒散卡直到重启）',
    );
    expect(
      find.byKey(const ValueKey<String>('home_video_video/late-ep1')),
      findsNothing,
      reason: '成员自动折进新落库的合集，不再渲染独立散卡',
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
