import 'dart:async';
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
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_video_list_store.dart';
import 'package:fushi/src/sync/server_url_credentials.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 视频库页冷启动：媒体服务器的上一份远端清单从磁盘先画出来，网络回来再换。
///
/// 驱动真页面（[HomeVideoPage] + 真 [RemoteVideoListStore]，落盘目录是临时目录）。
/// 来源是计数版 Jellyfin client：变更戳查询 / 整库枚举都由测试手里的 Completer
/// 控制，断言「网络还没回来时卡片已经在屏幕上」，以及「服务器说变了 → 新清单换上 /
/// 服务器说没变 → 不整库枚举」。
///
/// 磁盘读写与后台 isolate 是真异步，widget 测试的假时钟推不动它们，所以等待处用
/// `tester.runAsync` 让出真实时间后再 pump。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync(
      'fushi_persisted_remote_list_pp',
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
  late Directory listDir;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    await prefs.setJellyfinShowInLibrary(true);
    storeDir = Directory.systemTemp.createTempSync('fushi_persisted_list_db');
    listDir = Directory.systemTemp.createTempSync('fushi_persisted_list');
    RemoteVideoListStore.debugReset();
    RemoteVideoListStore.debugSetDirResolver(() async => listDir);
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
  });

  tearDown(() async {
    RemoteVideoListStore.debugSetDirResolver(null);
    RemoteVideoListStore.debugReset();
    await db.close();
    for (final Directory d in <Directory>[storeDir, listDir]) {
      try {
        if (d.existsSync()) d.deleteSync(recursive: true);
      } on FileSystemException {
        // 临时目录，删不掉留给系统清理。
      }
    }
  });

  /// 上一次运行留下的清单（真走 [RemoteVideoListStore.save]，带变更戳 `s0`）。
  Future<void> persistPreviousRun(_ServerClient client) async {
    await RemoteVideoListStore.save(
      source: client,
      videos: const <RemoteVideoInfo>[
        RemoteVideoInfo(id: 'video/persisted', title: '上次的远端条目'),
      ],
      stamp: 's0',
    );
    await RemoteVideoListStore.debugFlushWrites();
  }

  Widget buildApp(_ServerClient client) => ProviderScope(
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
            remoteVideoClientLoader: () async => null,
            cloudRemoteVideoClientLoader: () async => null,
            jellyfinVideoClientLoader: () async => client,
          ),
        ),
      ),
    ),
  );

  /// 让磁盘读写 / isolate（真异步）跑完，再推几帧把结果画出来。不用
  /// pumpAndSettle：网络 Completer 故意挂着时页面可能有常驻的加载动画。
  Future<void> settleRealIo(WidgetTester tester) async {
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('冷启动：网络还没回来，上一份清单已经画在屏幕上', (WidgetTester tester) async {
    final _ServerClient client = _ServerClient();
    await tester.runAsync(() => persistPreviousRun(client));

    await tester.pumpWidget(buildApp(client));
    await settleRealIo(tester);

    expect(find.text('上次的远端条目'), findsWidgets, reason: '磁盘上的清单不等网络先显示');
    expect(client.checks, <String>['s0'], reason: '后台已在问服务器「变了没」');
    expect(client.listCalls, 0, reason: '变更戳还没答复，整库枚举一次都没发');

    // 服务器答「变了」→ 整库枚举 → 新清单换上。
    client.check.complete(false);
    await settleRealIo(tester);
    expect(client.listCalls, 1);
    client.list.complete(const <RemoteVideoInfo>[
      RemoteVideoInfo(id: 'video/fresh', title: '新的远端条目'),
    ]);
    await settleRealIo(tester);

    expect(find.text('新的远端条目'), findsWidgets);
    expect(find.text('上次的远端条目'), findsNothing);
    await tester.runAsync(RemoteVideoListStore.debugFlushWrites);
  });

  testWidgets('冷启动：服务器答「没变」→ 不整库枚举，卡片原样保留', (WidgetTester tester) async {
    final _ServerClient client = _ServerClient();
    await tester.runAsync(() => persistPreviousRun(client));

    await tester.pumpWidget(buildApp(client));
    await settleRealIo(tester);
    expect(find.text('上次的远端条目'), findsWidgets);

    client.check.complete(true);
    await settleRealIo(tester);

    expect(client.listCalls, 0, reason: '没变就不枚举');
    expect(find.text('上次的远端条目'), findsWidgets);
  });

  testWidgets('没有落盘清单（首次运行）→ 照旧等整库清单', (WidgetTester tester) async {
    final _ServerClient client = _ServerClient();

    await tester.pumpWidget(buildApp(client));
    await settleRealIo(tester);
    expect(client.checks, isEmpty, reason: '没有旧清单就没有戳可问');
    expect(client.listCalls, 1);

    client.list.complete(const <RemoteVideoInfo>[
      RemoteVideoInfo(id: 'video/fresh', title: '新的远端条目'),
    ]);
    await settleRealIo(tester);
    expect(find.text('新的远端条目'), findsWidgets);
    await tester.runAsync(RemoteVideoListStore.debugFlushWrites);
  });
}

/// 计数版 Jellyfin client：只实现库页取清单与落盘会碰到的成员，其余经
/// [noSuchMethod] 兜底（与 home_video_jellyfin_show_in_library_gate_test 同款）。
class _ServerClient implements JellyfinVideoClient {
  final Completer<bool> check = Completer<bool>();
  final Completer<List<RemoteVideoInfo>> list =
      Completer<List<RemoteVideoInfo>>();
  final List<String> checks = <String>[];
  int listCalls = 0;

  @override
  String get remoteLibrarySourceId => 'jellyfin:http://nas:8096|u1';

  @override
  String get coverCacheNamespace => 'jellyfin-test';

  @override
  String get remoteVideoListScope => 'libraries=';

  @override
  ServerUrlCredentials get remoteVideoUrlCredentials =>
      const ServerUrlCredentials(baseUrl: 'http://nas:8096', token: 'tok');

  @override
  Future<String?> takeRemoteLibraryStamp() async => 's1';

  @override
  Future<bool> remoteLibraryUnchangedSince(String stamp) {
    checks.add(stamp);
    return check.future;
  }

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() {
    listCalls++;
    return list.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
