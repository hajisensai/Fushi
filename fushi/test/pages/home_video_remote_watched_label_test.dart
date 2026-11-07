import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_library_overview.dart'
    show formatVideoPosition;
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-4236：视频页远端卡的「看到 X」只显示 host 清单快照（缓存 + 页面常驻），
/// 互联 sweep 落地 host 的新断点 / 本机看完回来后不变（Linux Phase 4 r4-13：
/// host 已到 0:50，卡片「看到 0:40」）。卡片断点必须是清单快照与本机库断点的
/// 较新者（与开播判定同一份），并在本机断点变化时就地刷新——不等清单过期。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  const String uid = 'video/remote-long';
  const int t0 = 1000;
  const int t2 = 3000;

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_watched_label_pp',
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
  late HomeTab previousTab;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_watched_label_store');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    // 本页「在前台」= 路由在栈顶且视频 tab 是当前 tab。
    previousTab = homeShellTabNotifier.value;
    homeShellTabNotifier.value = HomeTab.video;
  });

  tearDown(() async {
    homeShellTabNotifier.value = previousTab;
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
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

  /// 本机库里的远端断点：与互联 sweep（`InterconnectPlaybackPositionSync._writeLocal`）
  /// 同样直接写库，不经偏好仓库。
  Future<void> writeLocal(int positionMs, int at) async {
    await db.setPrefTyped<int>(videoRemotePositionPrefKey(uid), positionMs);
    await db.setPrefTyped<int>(videoRemotePositionAtPrefKey(uid), at);
  }

  Finder watchedTo(int positionMs) =>
      find.text(t.video_watched_up_to(time: formatVideoPosition(positionMs)));

  /// host 清单快照：40 s @ t0（页面拿到后一直被缓存，测试里也不再变）。
  _ListFakeRemoteVideoClient hostList() =>
      _ListFakeRemoteVideoClient(<RemoteVideoInfo>[
        const RemoteVideoInfo(
          id: uid,
          title: 'host_long',
          durationMs: 60 * 60000,
          positionMs: 40000,
          positionUpdatedAtMs: t0,
        ),
      ]);

  testWidgets('本机库断点比清单新：卡片显示本机断点（不是清单快照）', (WidgetTester tester) async {
    await sizeUp(tester);
    await writeLocal(50000, t2);
    final _ListFakeRemoteVideoClient client = hostList();

    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();

    expect(watchedTo(50000), findsWidgets);
    expect(watchedTo(40000), findsNothing, reason: '清单快照比本机库旧');
  });

  testWidgets('本机库断点比清单旧：卡片照旧显示清单断点', (WidgetTester tester) async {
    await sizeUp(tester);
    await writeLocal(20000, t0 - 1);

    await tester.pumpWidget(buildApp(hostList()));
    await tester.pumpAndSettle();

    expect(watchedTo(40000), findsWidgets);
    expect(watchedTo(20000), findsNothing);
  });

  testWidgets('页面常驻时 sweep 落地 host 新断点：卡片就地刷新，不重新问 host 要清单', (
    WidgetTester tester,
  ) async {
    await sizeUp(tester);
    // 本机断点比清单旧：卡片先显示清单的 40 s。
    await writeLocal(20000, t0 - 1);
    final _ListFakeRemoteVideoClient client = hostList();

    await tester.pumpWidget(buildApp(client));
    await tester.pumpAndSettle();
    expect(watchedTo(40000), findsWidgets);
    final int listCallsBefore = client.listCalls;

    // 互联 sweep 把 host 的 50 s @ t2 落进本机库。
    await writeLocal(50000, t2);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(watchedTo(50000), findsWidgets);
    expect(watchedTo(40000), findsNothing);
    expect(
      client.listCalls,
      listCallsBefore,
      reason: '清单仍走缓存（TTL 内），刷新只重读本机断点',
    );
  });
}

class _ListFakeRemoteVideoClient implements RemoteVideoClient {
  _ListFakeRemoteVideoClient(this._videos);
  final List<RemoteVideoInfo> _videos;
  int listCalls = 0;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    listCalls++;
    return _videos;
  }

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
