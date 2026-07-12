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
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_video_client.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 多端库联合视图（spec 2026-07-12 §2.1/§2.4/§2.5）视频页占位卡混排 widget 守卫：
///  ① 远端互联视频以占位卡混排进主网格（不再独立分区），带云角标 ☁；
///  ② 本地已有同 bookUid 的视频不重复（只显示本地卡）；
///  ③ 「显示远端条目」开关关闭 → 占位卡全部不渲染；
///  ④ 远端目录拉取失败 → 占位卡不出现，只剩本地卡（离线=只剩本地）。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_mixed_grid_video_pp');
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

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_mixed_grid_video');
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
                remoteVideoClientLoader: () async => client,
                remoteVideoDownloadDestination: (RemoteVideoInfo v) async =>
                    File('${pathProviderDir.path}/${v.id.hashCode}.mp4'),
              ),
            ),
          ),
        ),
      );

  testWidgets('远端互联视频混排进主网格且带云角标', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    // 一本本地视频 + 一条远端占位，验证两者同网格混排。
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/local-1'),
      title: Value('Local One'),
      videoPath: Value('/abs/local-1.mp4'),
    ));

    await tester.pumpWidget(buildApp(_ListFakeRemoteVideoClient(
      <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'remote/only', title: 'Remote Only')
      ],
    )));
    await tester.pumpAndSettle();

    // 本地卡在，远端占位卡在（同一主 SliverGrid 混排），远端占位带云角标。
    expect(
      find.byKey(const ValueKey<String>('home_video_video/local-1')),
      findsOneWidget,
    );
    final Finder remoteCard =
        find.byKey(const ValueKey<String>('remote_video_card_remote_only'));
    expect(remoteCard, findsOneWidget);
    expect(
      find.byKey(
          const ValueKey<String>('remote_video_cloud_badge_remote_only')),
      findsOneWidget,
    );
    expect(
      find.ancestor(of: remoteCard, matching: find.byType(SliverGrid)),
      findsOneWidget,
      reason: '远端占位卡必须是主散卡网格（SliverGrid）的一个 cell（混排，非独立分区）',
    );
  });

  testWidgets('本地已有同 bookUid 的视频不重复渲染远端占位', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/dup'),
      title: Value('Local Dup'),
      videoPath: Value('/abs/dup.mp4'),
    ));

    await tester.pumpWidget(buildApp(_ListFakeRemoteVideoClient(
      <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'video/dup', title: 'Dup On Remote'),
        RemoteVideoInfo(id: 'video/only-remote', title: 'Only Remote'),
      ],
    )));
    await tester.pumpAndSettle();

    // 本地卡在；远端 dup 占位被去重隐藏；只剩纯远端 only-remote 的占位卡。
    expect(
      find.byKey(const ValueKey<String>('home_video_video/dup')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_video_dup')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_video_only-remote')),
      findsOneWidget,
    );
  });

  testWidgets('「显示远端条目」开关关闭 → 占位卡全部不渲染', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await prefs.setShowRemoteEntries(false);
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/local-1'),
      title: Value('Local One'),
      videoPath: Value('/abs/local-1.mp4'),
    ));

    await tester.pumpWidget(buildApp(_ListFakeRemoteVideoClient(
      <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'remote/only', title: 'Remote Only')
      ],
    )));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('home_video_video/local-1')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_remote_only')),
      findsNothing,
      reason: '开关关闭时远端占位卡不得渲染',
    );
  });

  testWidgets('远端目录拉取失败 → 占位卡不出现，只剩本地卡', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await db.upsertVideoBook(const VideoBooksCompanion(
      bookUid: Value('video/local-1'),
      title: Value('Local One'),
      videoPath: Value('/abs/local-1.mp4'),
    ));

    await tester.pumpWidget(buildApp(_ThrowingRemoteVideoClient()));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('home_video_video/local-1')),
      findsOneWidget,
      reason: '拉取失败仍显示本地库（离线=只剩本地）',
    );
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_remote_only')),
      findsNothing,
      reason: '远端目录拉取失败时占位卡不出现',
    );
  });
}

class _ListFakeRemoteVideoClient implements RemoteVideoClient {
  _ListFakeRemoteVideoClient(this._videos);
  final List<RemoteVideoInfo> _videos;

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

/// listRemoteVideos 抛异常 → 页面走 failed 门控（占位卡不出现）。
class _ThrowingRemoteVideoClient implements RemoteVideoClient {
  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async =>
      throw const SocketException('offline');

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
