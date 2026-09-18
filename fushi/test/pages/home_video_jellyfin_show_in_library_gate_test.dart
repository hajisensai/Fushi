import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
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
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:fushi/src/sync/jellyfin_video_client.dart';
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
      'hibiki_jellyfin_show_gate_pp',
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
    storeDir = Directory.systemTemp.createTempSync('hibiki_jellyfin_show_gate');
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

  Widget buildApp({
    required _CountingJellyfinClient client,
    required void Function() onLoaderCalled,
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
            // 互联与云盘都不出 client：`??` 链只剩 Jellyfin 这一环，闸门的
            // 效果不会被别的远端源遮住。
            remoteVideoClientLoader: () async => null,
            cloudRemoteVideoClientLoader: () async => null,
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

  testWidgets('对照：混排开 → 同一路径确实会问 Jellyfin 要清单', (
    WidgetTester tester,
  ) async {
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
}

/// 计数版 Jellyfin client：只实现库页取清单会碰到的成员，其余经 [noSuchMethod]
/// 兜底（与 home_video_collection_detail_gate_test 同款）。
class _CountingJellyfinClient implements JellyfinVideoClient {
  int listCalls = 0;

  @override
  String get remoteLibrarySourceId => 'jellyfin:http://nas:8096|u1';

  @override
  String get coverCacheNamespace => 'jellyfin-test';

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
