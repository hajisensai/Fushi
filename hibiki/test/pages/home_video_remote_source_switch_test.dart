import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/cloud_remote_video_client.dart';
import 'package:fushi/src/sync/hibiki_library_host_service.dart';
import 'package:fushi/src/sync/remote_library_source.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/sync/sync_asset_store.dart';
import 'package:fushi/src/sync/sync_backend.dart' show SyncBackendType;
import 'package:fushi/src/sync/video_manifest.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// BUG-1202 行为守卫：换远端来源之后，视频库里出现的必须是**当前来源**的条目。
///
/// 真实缺陷路径（develop `fdd71adcb`）——`_loadRemoteVideos` 的取数主干是
/// `_resolveRemoteVideoClient() ?? _resolveCloudRemoteVideoClient()`（TODO-2119 把
/// 双分支塌缩成一条），而共享 TTL 缓存只按「域」分槽（`videos` 一个槽），互联与云盘
/// 两种源都往里写。于是：
///
///   ① 互联启用 → 视频页拉对端清单 → 写进 videos 槽（60s 新鲜）
///   ② 用户关掉互联开关 → `_resolveRemoteVideoClient` 在
///      `isInterconnectEnabled()` 为 false 时**先 return null，压根不调 restoreAuth**，
///      所以 `InterconnectSyncBackend.sessionIdentityRevision` 不会自增
///   ③ 切走再切回视频 tab（[BaseModuleTabPageState.onTabActivated]）→ 走云盘分支 →
///      `read(key: videos)` 命中①那份缓存，`fetch` 根本不执行
///   ④ 用户在「云视频」视图里看到互联对端的片子，且不报错
///
/// 唯一的失效信号挂在互联内部，翻开关 / 换云盘后端都不经过它——所以这条不能靠
/// 「记得在切换入口失效」来治，得让两种源在数据结构上就不共用槽（`sourceId`）。
///
/// **这条断言锁的是内容归属，不是「缓存清空了」**：把修复退回去（`read` 不按
/// sourceId 分槽）时，槽仍然是 fresh 的、页面照样渲染出卡片——错在渲染出的是**上一个
/// 来源**的卡片。只断言「远端区为空」或「缓存被清了」都抓不住这个缺陷。
void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir =
        Directory.systemTemp.createTempSync('hibiki_remote_switch_pp');
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
    storeDir =
        Directory.systemTemp.createTempSync('hibiki_remote_switch_store');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    repo = VideoBookRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) storeDir.deleteSync(recursive: true);
  });

  /// 「切走再切回视频 tab」——推的是生产里那个真信号 [homeShellTabNotifier]，由
  /// `BaseModuleTabPageState` 监听后回调 `onTabActivated()`（BUG-994 的保活刷新范式），
  /// 不是测试直接去戳页面的私有/受保护方法。
  ///
  /// 走的是**非** forceRefresh 的读，正是会命中 TTL 缓存的那条路；下拉刷新
  /// （forceRefresh: true）无条件穿透缓存、会掩盖缺陷，所以这里不能用它。
  Future<void> reactivateTab(WidgetTester tester) async {
    homeShellTabNotifier.value = HomeTab.books;
    homeShellTabNotifier.value = HomeTab.video;
    await tester.pumpAndSettle();
  }

  setUp(() => homeShellTabNotifier.value = HomeTab.video);

  testWidgets('BUG-1202: 关掉互联后视频库显示云盘的片子，不是上一个来源的', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 互联开关：由测试直接翻，模拟用户去设置页关掉「互联」。翻它**不会**触碰
    // InterconnectSyncBackend，所以没有任何缓存失效发生——这正是缺陷成立的前提。
    bool interconnectEnabled = true;

    final _FakeInterconnectVideoClient interconnect =
        _FakeInterconnectVideoClient(<RemoteVideoInfo>[
      const RemoteVideoInfo(id: 'peer-only-vid', title: '对端才有的片子'),
    ]);
    final _FakeCloudVideoSource cloud = _FakeCloudVideoSource(<RemoteVideoInfo>[
      const RemoteVideoInfo(id: 'cloud-only-vid', title: '云盘才有的片子'),
    ]);

    await tester.pumpWidget(ProviderScope(
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
              // 互联启用时给互联 client；关掉后返 null → 页面回退云盘分支，
              // 与生产的 `_resolveRemoteVideoClient` 语义一致。
              remoteVideoClientLoader: () async =>
                  interconnectEnabled ? interconnect : null,
              cloudRemoteVideoClientLoader: () async => cloud,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // ① 互联来源：对端的片子在场。
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_peer-only-vid')),
      findsOneWidget,
      reason: '前提：互联启用时先渲染出对端条目，缓存里因此装着互联的清单',
    );
    expect(interconnect.listCalls, 1);

    // ② 用户关掉互联开关。时钟没动，互联那份缓存仍在 60s TTL 内。
    interconnectEnabled = false;

    // ③ 切走再切回视频 tab。
    await reactivateTab(tester);

    // ④ 断言内容归属：看到的必须是云盘的片子，且对端那张卡必须消失。
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_cloud-only-vid')),
      findsOneWidget,
      reason: 'BUG-1202：云盘视图必须渲染云盘自己的条目',
    );
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_peer-only-vid')),
      findsNothing,
      reason: 'BUG-1202：关掉互联后不得再看到互联对端的条目（缓存串味）',
    );
    expect(find.text('云盘才有的片子'), findsOneWidget);
    expect(find.text('对端才有的片子'), findsNothing);
    expect(
      cloud.listCalls,
      1,
      reason: '云盘是另一个槽，必须真去问云盘要清单，而不是复用互联那份缓存',
    );
  });

  testWidgets('BUG-1202: 反向——云盘视图开启互联后显示对端的片子', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    bool interconnectEnabled = false;

    final _FakeInterconnectVideoClient interconnect =
        _FakeInterconnectVideoClient(<RemoteVideoInfo>[
      const RemoteVideoInfo(id: 'peer-only-vid', title: '对端才有的片子'),
    ]);
    final _FakeCloudVideoSource cloud = _FakeCloudVideoSource(<RemoteVideoInfo>[
      const RemoteVideoInfo(id: 'cloud-only-vid', title: '云盘才有的片子'),
    ]);

    await tester.pumpWidget(ProviderScope(
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
              remoteVideoClientLoader: () async =>
                  interconnectEnabled ? interconnect : null,
              cloudRemoteVideoClientLoader: () async => cloud,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('remote_video_card_cloud-only-vid')),
      findsOneWidget,
      reason: '前提：先用云盘来源把清单缓存热起来',
    );

    // 用户打开互联开关。重新 restoreAuth 时 _sessionSignature 与上次相同（地址/令牌
    // 都没改）→ revision 不自增 → 同样没有失效兜底。
    interconnectEnabled = true;
    await reactivateTab(tester);

    expect(
      find.byKey(const ValueKey<String>('remote_video_card_peer-only-vid')),
      findsOneWidget,
      reason: 'BUG-1202：互联视图必须渲染对端自己的条目',
    );
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_cloud-only-vid')),
      findsNothing,
      reason: 'BUG-1202：开启互联后不得再看到云盘的条目（缓存串味）',
    );
  });

  testWidgets('BUG-1202: 同来源反复切 tab 仍复用缓存（没把 BUG-1180 弄丢）', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final _FakeInterconnectVideoClient interconnect =
        _FakeInterconnectVideoClient(<RemoteVideoInfo>[
      const RemoteVideoInfo(id: 'peer-only-vid', title: '对端才有的片子'),
    ]);

    await tester.pumpWidget(ProviderScope(
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
              remoteVideoClientLoader: () async => interconnect,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(interconnect.listCalls, 1);

    await reactivateTab(tester);
    await reactivateTab(tester);

    expect(
      interconnect.listCalls,
      1,
      reason: 'BUG-1180：同来源 TTL 内切回 tab 不得重打网络——分槽修复不能把它弄丢',
    );
    expect(
      find.byKey(const ValueKey<String>('remote_video_card_peer-only-vid')),
      findsOneWidget,
    );
  });
}

/// 互联对端 live 库的 fake。只实现清单能力，其余 live 端点本用例不触碰。
class _FakeInterconnectVideoClient implements RemoteVideoClient {
  _FakeInterconnectVideoClient(this.videos);

  final List<RemoteVideoInfo> videos;
  int listCalls = 0;

  @override
  String get remoteLibrarySourceId => kInterconnectRemoteLibrarySourceId;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    listCalls++;
    return videos;
  }

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();

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

/// 云盘目录源的 fake。页面的 `cloudRemoteVideoClientLoader` 收的是具体类
/// [CloudRemoteVideoClient]，故用 `implements` 覆盖其公共面；本用例只走清单一条路，
/// 下载/封面路径由 `home_video_cloud_download_test.dart` 覆盖。
class _FakeCloudVideoSource implements CloudRemoteVideoClient {
  _FakeCloudVideoSource(this.videos);

  final List<RemoteVideoInfo> videos;
  int listCalls = 0;

  @override
  SyncAssetStore get backend => throw UnimplementedError();

  /// 与 [remoteLibrarySourceId] 保持同源：这个 fake 冒充的是 Google Drive 后端。
  @override
  SyncBackendType get backendType => SyncBackendType.googleDrive;

  @override
  String get remoteLibrarySourceId =>
      cloudRemoteLibrarySourceId(backendType.name);

  @override
  Future<List<RemoteVideoManifestEntry>> listRemoteVideoManifest() async =>
      throw UnimplementedError();

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async {
    listCalls++;
    return videos;
  }

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();

  @override
  Future<void> getRemoteVideo(
    String uid,
    File destination, {
    void Function(double progress)? onProgress,
  }) async =>
      throw UnimplementedError();

  @override
  Future<bool> getRemoteVideoCover(
    String uid,
    File destination, {
    void Function(double progress)? onProgress,
  }) async =>
      false;
}
