import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show DebugPrintCallback;
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
import 'package:fushi/src/sync/cloud_remote_video_client.dart';
import 'package:fushi/src/sync/cloud_video_stream_relay.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi_engine/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_asset_range_reader.dart';
import 'package:fushi/src/sync/sync_backend.dart'
    show SyncAuthError, SyncBackendType;
import 'package:fushi/src/sync/sync_orchestrator.dart'
    show kSyncVideosNamespace, kSyncVideosManifestName;
import 'package:fushi/src/sync/video_manifest.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';
import '../sync/fake_asset_store.dart';

/// 多端库联合视图 §2.2/§2.6：云后端「上传视频文件」推上去的 `__videos__` 资产，经
/// [CloudRemoteVideoClient] 适配成主网格云视频占位卡（云角标 ☁）+ 点击下载整文件入库。
/// 断言：① 云视频清单条目混排进主网格散卡区带云角标；② 下载写穿 VideoBooks（真 DB 行）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  late CloudVideoStreamRelay relay;
  setUpAll(() async {
    relay = await CloudVideoStreamRelay.start();
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_cloud_video_pp');
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async => pathProviderDir.path,
    );
  });
  tearDownAll(() async {
    await relay.close();
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
  late VideoBookRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_cloud_video_store');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    repo = VideoBookRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp(CloudRemoteVideoClient cloud) => ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: HomeVideoPage(
                repo: repo,
                // #792 分区化：home 分区只渲染 dashboard 概览，云占位卡所在的
                // 混排墙（_buildLocalVideoSlivers）搬进了 series 分区，钉住它。
                section: VideoLibrarySection.allVideos,
                // 互联 client 缺省 → _resolveRemoteVideoClient 返 null，走云后端分支。
                cloudRemoteVideoClientLoader: () async => cloud,
                remoteVideoDownloadDestination: (RemoteVideoInfo v) async =>
                    File('${pathProviderDir.path}/${v.id.hashCode}.mp4'),
              ),
            ),
          ),
        ),
      );

  /// 触发下载（点 [trigger]）并等到整条下载链在本 runAsync zone 内彻底排干为止。云视频
  /// 下载走 [_downloadRemote] → [InterconnectDownloadManager.startVideoDownload]，后者在标
  /// completed 前 await 了整链（拉整文件 + onComplete 建行 + 云封面/抽帧兜底），故任务终态
  /// = 全部真实异步已排干。等待用 [Stopwatch] 墙钟兜底（高分辨率、不受 Windows ~15.6ms
  /// 定时器粒度影响、早退保持快路径）——旧实现固定 200 次 20ms 迭代在满负载多 isolate 争用
  /// 下会被批量到期定时器瞬间连发饿死（下载续体尚未调度就退出）而误红。
  Future<void> tapAndAwaitDownload(WidgetTester tester, Finder trigger) async {
    final InterconnectDownloadManager manager =
        ProviderScope.containerOf(tester.element(find.byType(HomeVideoPage)))
            .read(interconnectDownloadManagerProvider);
    await tester.runAsync(() async {
      await tester.tap(trigger);
      final Stopwatch sw = Stopwatch()..start();
      while (sw.elapsed < const Duration(seconds: 30)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final InterconnectDownloadTask? task = manager.tasks['cloud/vid1'];
        if (task != null && task.status != InterconnectDownloadStatus.running) {
          return;
        }
      }
    });
    await tester.pump();
  }

  testWidgets('云视频清单条目混排进主网格散卡区并带云角标', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/local-1'),
      title: Value('Local One'),
      videoPath: Value('/abs/local-1.mp4'),
    ));

    await tester.pumpWidget(buildApp(_FakeCloudRemoteVideoClient(
      entries: <RemoteVideoManifestEntry>[
        const RemoteVideoManifestEntry(
          uid: 'cloud/vid1',
          title: 'Cloud Vid',
          videoAsset: 'cloud_vid1.mp4',
          sizeBytes: 3,
        ),
      ],
    )));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('home_video_video/local-1')),
      findsOneWidget,
    );
    final Finder cloudCard =
        find.byKey(const ValueKey<String>('remote_video_card_cloud_vid1'));
    expect(cloudCard, findsOneWidget, reason: '云视频占位卡必须混排进主网格');
    expect(
      find.byKey(const ValueKey<String>('remote_video_cloud_badge_cloud_vid1')),
      findsOneWidget,
      reason: '云视频占位卡必须带云角标 ☁',
    );
    // BUG-1989 起「全部视频」散卡区是 16:9 等宽 SliverGrid（系列墙才留 Wrap）。
    // 只断言「有网格祖先」不够——云占位自成独立分区时也自带一个 SliverGrid；
    // 判据必须落在「与本地散卡同一个 SliverGrid 实例」上，才真的钉住混排。
    final Finder localCard =
        find.byKey(const ValueKey<String>('home_video_video/local-1'));
    final Finder cloudGrid =
        find.ancestor(of: cloudCard, matching: find.byType(SliverGrid));
    final Finder localGrid =
        find.ancestor(of: localCard, matching: find.byType(SliverGrid));
    expect(
      cloudGrid,
      findsOneWidget,
      reason: '云视频占位卡是主散卡网格的一个 cell（混排，非独立分区）',
    );
    expect(
      tester.element(cloudGrid),
      same(tester.element(localGrid)),
      reason: '云视频占位卡必须与本地散卡同属一个网格，不得自成独立分区',
    );
  });

  testWidgets('点击下载云视频写穿 VideoBooks（真 DB 行 bookUid=uid）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final _FakeCloudRemoteVideoClient cloud = _FakeCloudRemoteVideoClient(
      entries: <RemoteVideoManifestEntry>[
        const RemoteVideoManifestEntry(
          uid: 'cloud/vid1',
          title: 'Cloud Vid',
          videoAsset: 'cloud_vid1.mp4',
          sizeBytes: 3,
        ),
      ],
    );
    await tester.pumpWidget(buildApp(cloud));
    await tester.pumpAndSettle();

    // 下载前列表无该行（云视频不在 VideoBooks）。
    expect(await repo.getByBookUid('cloud/vid1'), isNull);

    // UI 巡检 PR-4：封面内嵌下载按钮已撤，下载入口 = 长按卡片弹面板 → 「下载」
    // （云视频短按卡片本体也下载，见下一个用例）。
    await tester.longPress(
      find.byKey(const ValueKey<String>('remote_video_card_cloud_vid1')),
    );
    await tester.pumpAndSettle();
    await tapAndAwaitDownload(
      tester,
      find.text(t.remote_video_download),
    );

    // 撤掉 saveVideoBook 建行后此断言转红（行不存在）。
    final VideoBookRow? row = await repo.getByBookUid('cloud/vid1');
    expect(row, isNotNull, reason: '云视频下载后必须建 VideoBooks 行');
    expect(row!.title, 'Cloud Vid');
    expect(
      row.videoPath,
      '${pathProviderDir.path}/${'cloud/vid1'.hashCode}.mp4',
    );
    // 下载委托 client.getRemoteVideo 拉整文件（勿双重导入：只建单行）。
    expect(cloud.downloadedUids, contains('cloud/vid1'));
  });

  // #4：云视频占位卡**短按**（点卡片本体，非右上角下载按钮）也要触发下载——云后端视频
  // 无 live host 不能流播，短按 = 下载语义（对齐书侧）。旧实现 _openRemote 见 client==null
  // 直接 return，短按静默无反应。
  testWidgets('短按云视频占位卡触发下载（云无法流播，短按=下载）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final _FakeCloudRemoteVideoClient cloud = _FakeCloudRemoteVideoClient(
      entries: <RemoteVideoManifestEntry>[
        const RemoteVideoManifestEntry(
          uid: 'cloud/vid1',
          title: 'Cloud Vid',
          videoAsset: 'cloud_vid1.mp4',
          sizeBytes: 3,
        ),
      ],
    );
    await tester.pumpWidget(buildApp(cloud));
    await tester.pumpAndSettle();

    expect(await repo.getByBookUid('cloud/vid1'), isNull);

    // 点卡片本体（onTap → _openRemote），不是右上角 remote_video_download 按钮。
    await tapAndAwaitDownload(
      tester,
      find.byKey(const ValueKey<String>('remote_video_card_cloud_vid1')),
    );

    expect(cloud.downloadedUids, contains('cloud/vid1'),
        reason: '#4：短按云占位卡分派下载（不再静默 return）');
    expect(await repo.getByBookUid('cloud/vid1'), isNotNull,
        reason: '短按下载后建 VideoBooks 行');
  });

  testWidgets('云盘能按 Range 读时面板给「播放（流播）」，点它流播而不下载', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const RemoteVideoManifestEntry entry = RemoteVideoManifestEntry(
      uid: 'cloud/vid1',
      title: 'Cloud Vid',
      videoAsset: 'cloud_vid1.mp4',
      sizeBytes: 3,
    );
    final _RangeAssetStore store = _RangeAssetStore();
    await tester.runAsync(() async {
      final String ns = await store.ensureNamespace(kSyncVideosNamespace);
      await store.putJsonAsset(
          ns,
          kSyncVideosManifestName,
          const RemoteVideoManifest(videos: <RemoteVideoManifestEntry>[entry])
              .toJson());
      final File blob = File('${pathProviderDir.path}/cloud_blob')
        ..writeAsBytesSync(<int>[0, 0, 0]);
      await store.putAsset(ns, entry.videoAsset, blob);
    });
    store.lookedUp.clear();
    final _FakeCloudRemoteVideoClient cloud = _FakeCloudRemoteVideoClient(
      entries: <RemoteVideoManifestEntry>[entry],
      streaming: CloudRemoteVideoClient(
        backend: store,
        backendType: SyncBackendType.oneDrive,
        relay: () async => relay,
      ).streamingClient(),
    );
    await tester.pumpWidget(buildApp(cloud));
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey<String>('remote_video_card_cloud_vid1')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.remote_video_stream_play), findsOneWidget);
    expect(find.text(t.remote_video_download), findsOneWidget,
        reason: '流播是新增动作，「下载」保留');

    // 播放页交给播放内核的地址会在 controller.load 开头打一行 `[video-load] … uri=…`，
    // 用它钉住「真正 load 的是本机回环中继地址」，而不只是「client 被问过」。
    final List<String> logs = <String>[];
    final DebugPrintCallback originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    try {
      await tester.tap(find.text(t.remote_video_stream_play));
      for (int i = 0;
          i < 40 && !logs.any((String l) => l.contains('[video-load]'));
          i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    } finally {
      debugPrint = originalDebugPrint;
    }
    expect(store.lookedUp, contains(entry.videoAsset),
        reason: '播放页经流播 client 取流（解析云端视频资产）');
    expect(cloud.downloadedUids, isEmpty, reason: '流播不触发整文件下载');
    final String loadLine = logs
        .firstWhere((String l) => l.contains('[video-load]'), orElse: () => '');
    expect(
      loadLine,
      contains('uri=http://127.0.0.1:${relay.port}/cloud/'),
      reason: '播放内核拿到的是本机回环中继地址（直链 / 凭据不出 Dart 层）',
    );
    expect(loadLine, endsWith('/${entry.videoAsset}'));
  });

  testWidgets('云盘登录失效时流播失败页提示重新登录，而不是通用失败', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const RemoteVideoManifestEntry entry = RemoteVideoManifestEntry(
      uid: 'cloud/vid1',
      title: 'Cloud Vid',
      videoAsset: 'cloud_vid1.mp4',
      sizeBytes: 3,
    );
    final _RangeAssetStore store = _RangeAssetStore();
    await tester.runAsync(() async {
      final String ns = await store.ensureNamespace(kSyncVideosNamespace);
      await store.putJsonAsset(
          ns,
          kSyncVideosManifestName,
          const RemoteVideoManifest(videos: <RemoteVideoManifestEntry>[entry])
              .toJson());
      final File blob = File('${pathProviderDir.path}/cloud_blob_auth')
        ..writeAsBytesSync(<int>[0, 0, 0]);
      await store.putAsset(ns, entry.videoAsset, blob);
    });
    // refresh token 已失效：区间读前的刷新失败。
    store.failWith = SyncAuthError('Token refresh failed: 400');
    final _FakeCloudRemoteVideoClient cloud = _FakeCloudRemoteVideoClient(
      entries: <RemoteVideoManifestEntry>[entry],
      streaming: CloudRemoteVideoClient(
        backend: store,
        backendType: SyncBackendType.dropbox,
        relay: () async => relay,
      ).streamingClient(),
    );
    await tester.pumpWidget(buildApp(cloud));
    await tester.pumpAndSettle();

    await tester.longPress(
      find.byKey(const ValueKey<String>('remote_video_card_cloud_vid1')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.remote_video_stream_play));
    for (int i = 0;
        i < 40 && find.text(t.sync_err_auth_expired).evaluate().isEmpty;
        i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text(t.sync_err_auth_expired), findsOneWidget,
        reason: '登录失效要说「请重新登录」');
    expect(find.text(t.video_load_failed_generic), findsNothing);
    expect(cloud.downloadedUids, isEmpty);
  });

  testWidgets('只能整文件下载的云盘（WebDAV 等）面板不出现「播放（流播）」', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildApp(_FakeCloudRemoteVideoClient(
      entries: <RemoteVideoManifestEntry>[
        const RemoteVideoManifestEntry(
          uid: 'cloud/vid1',
          title: 'Cloud Vid',
          videoAsset: 'cloud_vid1.mp4',
          sizeBytes: 3,
        ),
      ],
    )));
    await tester.pumpAndSettle();
    await tester.longPress(
      find.byKey(const ValueKey<String>('remote_video_card_cloud_vid1')),
    );
    await tester.pumpAndSettle();
    expect(find.text(t.remote_video_download), findsOneWidget);
    expect(find.text(t.remote_video_stream_play), findsNothing);
  });

  testWidgets('流播过的云视频下载入库后续上流播断点（同一 uid，一条进度）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 流播时播放页按云端条目 uid 落的断点（键与临期直链 / 本地端口无关）。
    await prefs.setPref(
        videoRemotePositionEpisodePrefKey('cloud/vid1', 0), 42000);
    await prefs.setPref(
        videoRemotePositionEpisodeAtPrefKey('cloud/vid1', 0), 1700000000000);

    await tester.pumpWidget(buildApp(_FakeCloudRemoteVideoClient(
      entries: <RemoteVideoManifestEntry>[
        const RemoteVideoManifestEntry(
          uid: 'cloud/vid1',
          title: 'Cloud Vid',
          videoAsset: 'cloud_vid1.mp4',
          sizeBytes: 3,
        ),
      ],
    )));
    await tester.pumpAndSettle();
    await tapAndAwaitDownload(
      tester,
      find.byKey(const ValueKey<String>('remote_video_card_cloud_vid1')),
    );

    final VideoBookRow? row = await repo.getByBookUid('cloud/vid1');
    expect(row, isNotNull);
    expect(row!.lastPositionMs, 42000, reason: '下载入库的本地行接上流播断点，不从头看');
  });
}

/// 云视频目录 client 的 fake（[CloudRemoteVideoClient] 是具体类，用 implements 覆盖
/// 三个公共方法 + backend getter；私有下载细节不参与接口）。
class _FakeCloudRemoteVideoClient implements CloudRemoteVideoClient {
  _FakeCloudRemoteVideoClient({required this.entries, this.streaming});

  final List<RemoteVideoManifestEntry> entries;
  final List<String> downloadedUids = <String>[];

  /// 流播视图（null = 该云盘只能整文件下载）。
  final CloudStreamVideoClient? streaming;

  @override
  CloudStreamVideoClient? streamingClient() => streaming;

  @override
  SyncAssetStore get backend => throw UnimplementedError();

  @override
  SyncBackendType get backendType => SyncBackendType.webDav;

  @override
  String get remoteLibrarySourceId =>
      cloudRemoteLibrarySourceId(backendType.name);

  @override
  Future<List<RemoteVideoManifestEntry>> listRemoteVideoManifest() async =>
      entries;

  /// TODO-2119：[RemoteVideoSource] 视图——清单→DTO 的适配已收进真 client，
  /// fake 这里照搬同样的映射（页面不再自己适配，所以这份映射必须由 client 侧提供）。
  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async => <RemoteVideoInfo>[
        for (final RemoteVideoManifestEntry e in entries)
          RemoteVideoInfo(
            id: e.uid,
            title: e.title,
            sizeBytes: e.sizeBytes,
            tagsAddedAt: e.tagsAddedAt,
            tagTombstones: e.tagTombstones,
          ),
      ];

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) =>
      getRemoteVideo(id, dest, onProgress: onProgress);

  @override
  Future<void> getRemoteVideo(
    String uid,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    await destination.create(recursive: true);
    await destination.writeAsBytes(<int>[0, 0, 0]);
    downloadedUids.add(uid);
    onProgress?.call(1.0);
  }

  @override
  Future<bool> getRemoteVideoCover(
    String uid,
    File destination, {
    void Function(double progress)? onProgress,
  }) async {
    // 写一张占位封面并返回 true → 登记时用云封面，不落到 ffmpeg 抽帧（测试确定性）。
    await destination.create(recursive: true);
    await destination.writeAsBytes(<int>[1, 2, 3]);
    return true;
  }
}

/// 能按 Range 读的假云盘（形同 OneDrive / Dropbox 后端），并记下被解析过的资产名。
class _RangeAssetStore extends FakeAssetStore implements SyncAssetRangeReader {
  final Map<String, List<int>> _bytes = <String, List<int>>{};
  final List<String> lookedUp = <String>[];

  /// 非 null 时区间读一律抛它（模拟 refresh token 失效）。
  Exception? failWith;

  @override
  Future<AssetEntry?> findAsset(String namespaceId, String name) {
    lookedUp.add(name);
    return super.findAsset(namespaceId, name);
  }

  @override
  Future<void> putAsset(String namespaceId, String name, File file,
      {void Function(double progress)? onProgress}) async {
    await super.putAsset(namespaceId, name, file, onProgress: onProgress);
    _bytes['$namespaceId/$name'] = await file.readAsBytes();
  }

  @override
  Future<SyncAssetRange> openAssetRange(String assetId,
      {required int start, int? end}) async {
    final Exception? failure = failWith;
    if (failure != null) throw failure;
    final List<int> bytes = _bytes[assetId]!;
    final int last =
        end == null || end >= bytes.length ? bytes.length - 1 : end;
    return SyncAssetRange(
      start: start,
      end: last,
      totalBytes: bytes.length,
      bytes: Stream<List<int>>.value(bytes.sublist(start, last + 1)),
    );
  }
}
