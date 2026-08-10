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
import 'package:fushi/src/sync/cloud_remote_video_client.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/interconnect_download_manager.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart' show SyncBackendType;
import 'package:fushi/src/sync/video_manifest.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 多端库联合视图 §2.2/§2.6：云后端「上传视频文件」推上去的 `__videos__` 资产，经
/// [CloudRemoteVideoClient] 适配成主网格云视频占位卡（云角标 ☁）+ 点击下载整文件入库。
/// 断言：① 云视频清单条目混排进主网格散卡区带云角标；② 下载写穿 VideoBooks（真 DB 行）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_cloud_video_pp');
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
                section: VideoLibrarySection.series,
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
    expect(
      find.ancestor(of: cloudCard, matching: find.byType(Wrap)),
      findsOneWidget,
      reason: '云视频占位卡是主散卡网格的一个 cell（混排，非独立分区）',
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
}

/// 云视频目录 client 的 fake（[CloudRemoteVideoClient] 是具体类，用 implements 覆盖
/// 三个公共方法 + backend getter；私有下载细节不参与接口）。
class _FakeCloudRemoteVideoClient implements CloudRemoteVideoClient {
  _FakeCloudRemoteVideoClient({required this.entries});

  final List<RemoteVideoManifestEntry> entries;
  final List<String> downloadedUids = <String>[];

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
