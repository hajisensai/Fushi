import 'dart:io';

import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/cloud_remote_video_client.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_video_list_store.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// B4：Jellyfin/Emby 条目混排进首页 / 系列 / 全部视频改为显式 opt-in
/// （`jellyfin_show_in_library`，默认 false）。
///
/// 驱动真页面：注入一个计数 Jellyfin client，断言闸门关时库页**连 client 都不去
/// 拿**（loader 零调用、清单零请求）；再以闸门开为对照，证明同一路径确实会取数
/// ——否则上面的 0 只是「根本没走到」。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_jellyfin_show_gate_pp',
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

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('fushi_jellyfin_show_gate');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    // 本文件只测闸门：媒体服务器清单不落盘（落盘与冷启动见
    // home_video_persisted_remote_list_test.dart）。
    RemoteVideoListStore.debugReset();
    RemoteVideoListStore.debugSetDirResolver(() async => null);
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    RemoteVideoListStore.debugSetDirResolver(null);
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  Widget buildApp({
    required _CountingJellyfinClient client,
    required void Function() onLoaderCalled,
    CloudRemoteVideoClient? cloud,
  }) => ProviderScope(
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
            section: VideoLibrarySection.allVideos,
            // 互联不出 client；云盘缺省也不出，闸门的效果不会被别的远端源遮住。
            remoteVideoClientLoader: () async => null,
            cloudRemoteVideoClientLoader: () async => cloud,
            jellyfinVideoClientLoader: () async {
              onLoaderCalled();
              return client;
            },
          ),
        ),
      ),
    ),
  );

  testWidgets('默认（混排关）：库页不取 Jellyfin client、不发清单请求', (
    WidgetTester tester,
  ) async {
    expect(prefs.jellyfinShowInLibrary, isFalse, reason: 'B4：默认必须是 opt-in');
    final _CountingJellyfinClient client = _CountingJellyfinClient();
    int loaderCalls = 0;

    await tester.pumpWidget(
      buildApp(client: client, onLoaderCalled: () => loaderCalls++),
    );
    await tester.pumpAndSettle();

    expect(loaderCalls, 0, reason: '闸门关时连 client 都不该去拿');
    expect(client.listCalls, 0, reason: '闸门关时一次拍平清单请求都不发');
  });

  testWidgets('对照：混排开 → 同一路径确实会问 Jellyfin 要清单', (WidgetTester tester) async {
    await prefs.setJellyfinShowInLibrary(true);
    final _CountingJellyfinClient client = _CountingJellyfinClient();
    int loaderCalls = 0;

    await tester.pumpWidget(
      buildApp(client: client, onLoaderCalled: () => loaderCalls++),
    );
    await tester.pumpAndSettle();

    expect(loaderCalls, greaterThanOrEqualTo(1));
    expect(
      client.listCalls,
      greaterThanOrEqualTo(1),
      reason: '闸门开时这条路径要真的取数，否则上面的 0 只是「根本没走到」',
    );
  });

  testWidgets('反馈 k5Ey2AglAf：混排开时云盘视频不消失，与 Jellyfin 条目并存', (
    WidgetTester tester,
  ) async {
    final _CountingJellyfinClient client = _CountingJellyfinClient();
    final _FakeCloudClient cloud = _FakeCloudClient();

    await tester.pumpWidget(
      buildApp(client: client, onLoaderCalled: () {}, cloud: cloud),
    );
    await tester.pumpAndSettle();
    expect(find.text('云盘条目'), findsWidgets, reason: '混排关：只有云盘');
    expect(find.text('远端条目'), findsNothing);

    // 打开「显示在视频库」：Jellyfin 条目**混入**，云盘条目留着（此前是三选一，
    // Jellyfin 一出现云盘清单就不再读）。
    await prefs.setJellyfinShowInLibrary(true);
    await tester.pumpAndSettle();
    expect(find.text('远端条目'), findsWidgets);
    expect(find.text('云盘条目'), findsWidgets, reason: '云盘视频不能被 Jellyfin 顶掉');
    expect(client.listCalls, greaterThanOrEqualTo(1));
    expect(cloud.listCalls, greaterThanOrEqualTo(2), reason: '开关翻转后云盘照样重取');

    // 再关掉：Jellyfin 条目走，云盘条目还在。
    await prefs.setJellyfinShowInLibrary(false);
    await tester.pumpAndSettle();
    expect(find.text('远端条目'), findsNothing);
    expect(find.text('云盘条目'), findsWidgets);
  });

  testWidgets('混排开→关：远端卡片立即消失，再开回来重新出现', (WidgetTester tester) async {
    await prefs.setJellyfinShowInLibrary(true);
    final _CountingJellyfinClient client = _CountingJellyfinClient();

    await tester.pumpWidget(buildApp(client: client, onLoaderCalled: () {}));
    await tester.pumpAndSettle();
    expect(find.text('远端条目'), findsWidgets);

    // 关掉开关：页面必须重取并丢掉旧清单，不能留下没有 client 的幽灵卡片
    // （封面空白、点击无反应）。
    await prefs.setJellyfinShowInLibrary(false);
    await tester.pumpAndSettle();
    expect(find.text('远端条目'), findsNothing);

    await prefs.setJellyfinShowInLibrary(true);
    await tester.pumpAndSettle();
    expect(find.text('远端条目'), findsWidgets);
  });
}

/// 云盘目录 client 的最小假实现：只出一份清单（库页取数只碰这几个成员）。
class _FakeCloudClient implements CloudRemoteVideoClient {
  int listCalls = 0;

  @override
  String get remoteLibrarySourceId => 'cloud:webdav';

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    listCalls++;
    return const <RemoteVideoInfo>[
      RemoteVideoInfo(id: 'cloud-uid-1', title: '云盘条目'),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// 计数版 Jellyfin client：只实现库页取清单会碰到的成员，其余经 [noSuchMethod]
/// 兜底（与 home_video_collection_detail_gate_test 同款）。
class _CountingJellyfinClient implements JellyfinVideoClient {
  int listCalls = 0;

  @override
  String get remoteLibrarySourceId => 'jellyfin:http://nas:8096|u1';

  @override
  String get coverCacheNamespace => 'jellyfin-test';

  /// 不出变更戳：每次重验都整库拉（本文件数的就是整库请求）。
  @override
  Future<String?> takeRemoteLibraryStamp() async => null;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    listCalls++;
    return const <RemoteVideoInfo>[
      RemoteVideoInfo(id: 'video/remote-1', title: '远端条目'),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
