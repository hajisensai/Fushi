import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/models.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/pages/implementations/home_video_page.dart';
import 'package:hibiki/src/platform/platform_providers.dart';
import 'package:hibiki/src/platform/platform_services.dart';
import 'package:hibiki/src/sync/cloud_remote_video_client.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/sync_asset_store.dart';
import 'package:hibiki/src/sync/video_manifest.dart';
import 'package:hibiki_core/hibiki_core.dart';
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

  late HibikiDatabase db;
  late PreferencesRepository prefs;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;
  late VideoBookRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
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
                // 互联 client 缺省 → _resolveRemoteVideoClient 返 null，走云后端分支。
                cloudRemoteVideoClientLoader: () async => cloud,
                remoteVideoDownloadDestination: (RemoteVideoInfo v) async =>
                    File('${pathProviderDir.path}/${v.id.hashCode}.mp4'),
              ),
            ),
          ),
        ),
      );

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
      find.ancestor(of: cloudCard, matching: find.byType(SliverGrid)),
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

    await tester.runAsync(() async {
      await tester.tap(find.byKey(
        const ValueKey<String>('remote_video_download_cloud_vid1'),
      ));
      for (int i = 0; i < 200; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (await repo.getByBookUid('cloud/vid1') != null && i > 4) return;
      }
    });
    await tester.pump();

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
  Future<List<RemoteVideoManifestEntry>> listRemoteVideos() async => entries;

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
