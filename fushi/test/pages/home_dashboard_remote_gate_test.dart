import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/media.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';
import 'package:fushi/src/platform/platform_providers.dart';
import 'package:fushi/src/platform/platform_services.dart';
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/fake_anki_repository.dart';
import '../helpers/test_platform_services.dart';

/// 首页 dashboard「显示远端条目」门控（BUG-1182 视频页同款，dashboard 此前漏修）：
///
/// 症状：dashboard 的远端取数（书清单/视频清单/活动流三个互联请求）只判互联开关，
/// 完全不认 `showRemoteEntries`——关掉「显示远端条目」的用户仍全额付网络代价，
/// 远端「继续」卡与远端活动照混排进时间轴。
///
/// 守卫：门控必须在**取数之前**（不是渲染期丢弃）。互联配置齐全（开关开 + 已配对
/// 地址/令牌，`restoreAuth` 不发网络、只建暂定句柄）时：
/// 1. 开关关闭 → [RemoteLibraryCache.read] 一次都不被调用（零远端请求）；
/// 2. 开关开启 → 三个域（books / videos / activity）各被取数（阳性对照，证明本
///    harness 真能走到取数处，排除「0 次是因为配置/鉴权没过」的假绿）；
/// 3. 页面存活期间翻开开关 → prefsRepo 监听触发补拉（不用重进页面）。
class _CountingRemoteLibraryCache extends RemoteLibraryCache {
  /// 记录每次 [read] 的域 key（books / videos / activity:N）。
  final List<String> readKeys = <String>[];

  @override
  Future<T> read<T>({
    required String sourceId,
    required String key,
    required Future<T> Function() fetch,
    Duration? ttl,
    bool forceRefresh = false,
  }) async {
    readKeys.add(key);
    // 不调 [fetch]（那会打真网络），按域返回空清单——本测试只关心「取数发生
    // 与否」，不关心取到什么。
    if (key == RemoteLibraryCacheKeys.books) {
      return <RemoteBookInfo>[] as T;
    }
    if (key == RemoteLibraryCacheKeys.videos) {
      return <RemoteVideoInfo>[] as T;
    }
    return <RemoteActivityEvent>[] as T;
  }
}

void main() {
  final TestWidgetsFlutterBinding binding =
      TestWidgetsFlutterBinding.ensureInitialized();

  late Directory pathProviderDir;
  setUpAll(() {
    pathProviderDir = Directory.systemTemp.createTempSync('hibiki_dash_gate');
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
      pathProviderDir.deleteSync(recursive: true);
    }
  });

  late FushiDatabase db;
  late PlatformServices platformServices;
  late FakeAnkiRepository ankiRepository;
  late AppModel appModel;
  late Directory storeDir;
  late PreferencesRepository prefs;
  late _CountingRemoteLibraryCache remoteCache;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    LocaleSettings.setLocale(AppLocale.zhCn);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    storeDir = Directory.systemTemp.createTempSync('hibiki_dash_gate_store');
    platformServices = testPlatformServices();
    ankiRepository = FakeAnkiRepository();
    appModel = AppModel(platformServices)
      ..wireDatabaseForTesting(db)
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: storeDir);
    remoteCache = _CountingRemoteLibraryCache();

    // 互联配置齐全：开关开 + 已配对地址/令牌。`restoreAuth` 只读库、建暂定句柄，
    // 不发任何网络（探测推迟到首次真实请求，而真实请求被计数 cache 拦下）。
    final SyncRepository syncRepo = SyncRepository(db);
    await syncRepo.setInterconnectEnabled(true);
    await syncRepo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(url: 'http://127.0.0.1:9', enabled: true),
    ]);
    await syncRepo.setFushiClientToken('dash-gate-token');
  });

  tearDown(() async {
    await db.close();
    if (storeDir.existsSync()) {
      storeDir.deleteSync(recursive: true);
    }
  });

  /// 书侧 drift `.watch()` provider 打桩（同 home_dashboard_page_test.dart 的
  /// 隔离清单，BUG-1495：不打桩测试卸载期必留 pending timer）。
  List<Override> bookStreamOverrides() => <Override>[
        fushiBooksProvider
            .overrideWith((ref, language) async => const <MediaItem>[]),
        bookLastReadAtProvider
            .overrideWith((ref) async => const <String, int>{}),
        epubBookUidByKeyProvider
            .overrideWith((ref) async => const <String, String>{}),
      ];

  Widget buildApp() => ProviderScope(
        overrides: <Override>[
          platformServicesProvider.overrideWithValue(platformServices),
          ankiRepositoryProvider.overrideWithValue(ankiRepository),
          appProvider.overrideWith((ref) => appModel),
          remoteLibraryCacheProvider.overrideWithValue(remoteCache),
          ...bookStreamOverrides(),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: HomeDashboardPage(videoRepo: VideoBookRepository(db)),
            ),
          ),
        ),
      );

  // 有界 pump（真实 DB + FutureProvider 在 fakeAsync 下 pumpAndSettle 会挂）。
  Future<void> pumpDashboard(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
  }

  testWidgets('开关关闭：dashboard 不发任何远端请求（门控在取数之前）', (WidgetTester tester) async {
    await prefs.setShowRemoteEntries(false);

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    // 再多推 1s，把 400ms 防抖重载等潜在的延迟取数路径也压出来。
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(remoteCache.readKeys, isEmpty,
        reason: '关掉「显示远端条目」后 dashboard 必须零远端取数——门控前移到取数'
            '之前（BUG-1182），不是取回来再丢弃');
  });

  testWidgets('开关开启（阳性对照）：三个域各取数，证明 harness 真能到达取数处',
      (WidgetTester tester) async {
    // 默认即 true，显式写出以固定前提。
    await prefs.setShowRemoteEntries(true);

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(
      remoteCache.readKeys.toSet(),
      containsAll(<String>[
        RemoteLibraryCacheKeys.books,
        RemoteLibraryCacheKeys.videos,
        RemoteLibraryCacheKeys.activity(200),
      ]),
      reason: '开关开着时三个远端域都必须取数；此对照保证上一条用例的 0 次不是'
          '「互联配置/鉴权没过」造成的假绿',
    );
  });

  testWidgets('页面存活期间翻开开关：prefsRepo 监听触发补拉，无需重进页面',
      (WidgetTester tester) async {
    await prefs.setShowRemoteEntries(false);

    await tester.pumpWidget(buildApp());
    await pumpDashboard(tester);
    expect(remoteCache.readKeys, isEmpty);

    await prefs.setShowRemoteEntries(true);
    await pumpDashboard(tester);

    expect(tester.takeException(), isNull);
    expect(
      remoteCache.readKeys.toSet(),
      containsAll(<String>[
        RemoteLibraryCacheKeys.books,
        RemoteLibraryCacheKeys.videos,
        RemoteLibraryCacheKeys.activity(200),
      ]),
      reason: '开关翻开必须立即补拉远端（对齐 BUG-1182 的 prefsRepo 监听模式），'
          '不能要求用户重进首页',
    );
  });
}
