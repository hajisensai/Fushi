// JellyfinConfigWidget 的「线路」面板（真 DB + MockClient，无真实服务器）。
//
// 本文件锁住：
//  [1] 展开一行 → 线路面板：登录地址带「登录地址」副标题、不可删；添加线路走
//      「探连通 + 拿现有令牌读 Views」两步、**不重新登录**，成功后列表 +1、不切换；
//  [2] 点单选切换 → 配置 active 落库、该台远端清单槽失效、身份不变（仍一条记录）；
//      删除正在用的备用线路 → 回落登录地址；
//  [3] 新地址不认现有令牌（别台服务器 / 令牌过期）→ 弹错误对话框、不落库。
//
// 页面 widget 测试不挂 ProviderScope 时 build 路径读 Riverpod 会整页抛：本 widget
// 经 SettingsContext.ref 读 remoteLibraryCacheProvider，harness 必须挂 ProviderScope。

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/sync/jellyfin_settings_widget.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

const String _lan = 'http://nas:8096';
const String _wan = 'https://emby.example.com';

const JellyfinServerConfig _nas = JellyfinServerConfig(
  serverUrl: _lan,
  username: 'alice',
  userId: 'u-alice',
  accessToken: 'tok-nas',
  serverName: 'NAS',
  deviceId: 'dev-1',
);

String _idOf(JellyfinServerConfig c) =>
    JellyfinVideoClient.sourceIdFor(serverUrl: c.serverUrl, userId: c.userId);

FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<AppModel> _appModel(FushiDatabase db) async {
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'fushi_jellyfin_routes_',
  );
  addTearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  return AppModel(testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

/// 假服务器：`nas` 与 `emby.example.com` 两个 host 是**同一台**（都认 tok-nas），
/// `other.example.com` 是别台（不认这个令牌 → 401）。
class _FakeServer {
  final List<http.Request> seen = <http.Request>[];

  static const Set<String> sameServerHosts = <String>{
    'nas',
    'emby.example.com',
  };

  MockClient client() => MockClient((http.Request req) async {
    seen.add(req);
    if (req.url.path == '/System/Info/Public') {
      return http.Response(
        jsonEncode(<String, Object?>{'ServerName': 'NAS'}),
        200,
      );
    }
    if (req.url.path.endsWith('/Views')) {
      final String auth = req.headers['Authorization'] ?? '';
      final bool tokenOk =
          sameServerHosts.contains(req.url.host) &&
          auth.contains('Token="tok-nas"');
      if (!tokenOk) return http.Response('', 401);
      return http.Response(
        jsonEncode(<String, Object?>{
          'Items': <Object?>[
            <String, Object?>{
              'Id': 'lib-anime',
              'Name': 'Anime',
              'CollectionType': 'tvshows',
            },
          ],
        }),
        200,
      );
    }
    return http.Response('', 404);
  });
}

Widget _harness({
  required FushiDatabase db,
  required AppModel appModel,
  required RemoteLibraryCache cache,
  required http.Client Function() clientFactory,
}) {
  final ThemeNotifier themeNotifier = ThemeNotifier(db, () => const TextTheme())
    ..loadFromPrefsSnapshot(<String, String>{
      'design_system': PrefCodec.encode('material'),
      'app_theme_key': PrefCodec.encode('system-theme'),
      'brightness_mode': PrefCodec.encode('system'),
      'custom_theme_seed': PrefCodec.encode(0xFF1F4959),
    });
  appModel.themeNotifier = themeNotifier;
  addTearDown(themeNotifier.dispose);

  return ProviderScope(
    overrides: <Override>[
      appProvider.overrideWith((Ref ref) => appModel),
      remoteLibraryCacheProvider.overrideWithValue(cache),
    ],
    child: MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        platform: TargetPlatform.android,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
        extensions: <ThemeExtension<dynamic>>[
          FushiDesignSystemTheme(themeNotifier.designSystemTheme),
        ],
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              final SettingsContext sctx = SettingsContext(
                context: context,
                appModel: ref.read(appProvider),
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return JellyfinConfigWidget(
                settingsContext: sctx,
                httpClientFactory: clientFactory,
              );
            },
          ),
        ),
      ),
    ),
  );
}

/// 服务器摘要行（标题含服务器名 · 当前线路）。
Finder _serverRow(String activeUrl) => find.byWidgetPredicate(
  (Widget w) =>
      w is FushiListItem &&
      w.title is Text &&
      ((w.title as Text).data ?? '') == 'NAS · $activeUrl',
);

Finder _routeRow(String url) =>
    find.byKey(ValueKey<String>('jellyfin-route-${_idOf(_nas)}-$url'));

Finder _routeField() => find.descendant(
  of: find.byWidgetPredicate(
    (Widget w) => w is FushiTextField && w.labelText == t.jellyfin_route_url,
  ),
  matching: find.byType(EditableText),
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

Future<({FushiDatabase db, SyncRepository repo, _FakeServer server})> _setUp(
  WidgetTester tester, {
  required JellyfinServerConfig config,
  required RemoteLibraryCache cache,
}) async {
  tester.view.physicalSize = const Size(800, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final FushiDatabase db = _testDb();
  addTearDown(db.close);
  final AppModel appModel = await _appModel(db);
  final SyncRepository repo = SyncRepository(db);
  await repo.setJellyfinServers(<JellyfinServerConfig>[config]);
  final _FakeServer server = _FakeServer();
  await tester.pumpWidget(
    _harness(
      db: db,
      appModel: appModel,
      cache: cache,
      clientFactory: server.client,
    ),
  );
  await _settle(tester);
  return (db: db, repo: repo, server: server);
}

void main() {
  testWidgets('[1] 展开 → 线路面板；添加线路不重新登录，成功后 +1、不切换', (
    WidgetTester tester,
  ) async {
    final ({FushiDatabase db, SyncRepository repo, _FakeServer server}) rig =
        await _setUp(tester, config: _nas, cache: RemoteLibraryCache());

    expect(_routeRow(_lan), findsNothing, reason: '未展开不出线路面板');
    await tester.tap(_serverRow(_lan));
    await _settle(tester);

    expect(_routeRow(_lan), findsOneWidget);
    expect(find.text(t.jellyfin_route_primary_label), findsOneWidget);
    expect(
      find.descendant(
        of: _routeRow(_lan),
        matching: find.byIcon(Icons.delete_outline),
      ),
      findsNothing,
      reason: '登录地址是身份锚，不可删',
    );
    rig.server.seen.clear();

    await tester.enterText(_routeField(), 'emby.example.com');
    await tester.tap(find.widgetWithText(FilledButton, t.jellyfin_route_add));
    await _settle(tester);

    expect(
      rig.server.seen.map((http.Request r) => r.url.path).toList(),
      <String>['/System/Info/Public', '/Users/u-alice/Views'],
      reason: '探连通 + 拿现有令牌验证同一台；没有 AuthenticateByName',
    );
    expect(rig.server.seen.last.url.host, 'emby.example.com');
    expect(
      rig.server.seen.last.headers['Authorization'],
      contains('DeviceId="dev-1"'),
      reason: '验证请求带这台配置自己的 DeviceId',
    );
    final List<JellyfinServerConfig> servers = await rig.repo
        .getJellyfinServers();
    expect(servers, hasLength(1));
    expect(servers.single.routeUrls, <String>[
      _lan,
      'http://emby.example.com',
    ], reason: '缺 scheme 由 normalizeServerUrl 补 http');
    expect(servers.single.effectiveServerUrl, _lan, reason: '添加不切换');
    expect(servers.single.accessToken, 'tok-nas', reason: '令牌不动');
    expect(_routeRow('http://emby.example.com'), findsOneWidget);
    expect(
      tester.widget<EditableText>(_routeField()).controller.text,
      isEmpty,
      reason: '添加成功后输入框清空',
    );
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('[2] 单选切换：active 落库、缓存槽失效、身份不变；删正在用的线路回落', (
    WidgetTester tester,
  ) async {
    final RemoteLibraryCache cache = RemoteLibraryCache();
    final JellyfinServerConfig config = _nas.copyWithRoutes(
      alternateUrls: <String>[_wan],
    );
    final ({FushiDatabase db, SyncRepository repo, _FakeServer server}) rig =
        await _setUp(tester, config: config, cache: cache);
    await cache.read<String>(
      sourceId: _idOf(_nas),
      key: 'videos',
      fetch: () async => 'lan-list',
      ttl: const Duration(hours: 1),
    );

    await tester.tap(_serverRow(_lan));
    await _settle(tester);
    expect(_routeRow(_lan), findsOneWidget);
    expect(_routeRow(_wan), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: _routeRow(_wan),
        matching: find.byType(Radio<String>),
      ),
    );
    await _settle(tester);

    List<JellyfinServerConfig> servers = await rig.repo.getJellyfinServers();
    expect(servers, hasLength(1), reason: '切线路不多一张卡');
    expect(_idOf(servers.single), _idOf(_nas), reason: '身份锚不变');
    expect(servers.single.effectiveServerUrl, _wan);
    expect(
      cache.peek<String>(sourceId: _idOf(_nas), key: 'videos'),
      isNull,
      reason: '槽里的封面 / 流 URL 烤着旧线路 host，必须失效',
    );
    expect(_serverRow(_wan), findsOneWidget, reason: '摘要行显示当前线路');
    expect(find.text(t.jellyfin_route_active_label), findsOneWidget);
    expect(
      rig.server.seen.where((http.Request r) => r.url.path.endsWith('/Views')),
      isNotEmpty,
    );
    expect(
      rig.server.seen.last.url.host,
      'emby.example.com',
      reason: '重取媒体库清单走新线路',
    );

    // 删掉正在用的备用线路 → 回落登录地址。
    await tester.tap(
      find.descendant(
        of: _routeRow(_wan),
        matching: find.byIcon(Icons.delete_outline),
      ),
    );
    await _settle(tester);
    servers = await rig.repo.getJellyfinServers();
    expect(servers.single.routeUrls, <String>[_lan]);
    expect(servers.single.effectiveServerUrl, _lan);
    expect(_routeRow(_wan), findsNothing);
    expect(_serverRow(_lan), findsOneWidget);
  });

  testWidgets('[3] 新地址不认现有令牌 → 错误对话框、不落库', (WidgetTester tester) async {
    final ({FushiDatabase db, SyncRepository repo, _FakeServer server}) rig =
        await _setUp(tester, config: _nas, cache: RemoteLibraryCache());
    await tester.tap(_serverRow(_lan));
    await _settle(tester);

    await tester.enterText(_routeField(), 'https://other.example.com');
    await tester.tap(find.widgetWithText(FilledButton, t.jellyfin_route_add));
    await _settle(tester);

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(t.jellyfin_route_add_failed), findsOneWidget);
    expect(
      find.textContaining('https://other.example.com'),
      findsWidgets,
      reason: '错误文案点名是哪条地址',
    );
    final List<JellyfinServerConfig> servers = await rig.repo
        .getJellyfinServers();
    expect(servers.single.routeUrls, <String>[_lan], reason: '不落库');

    await tester.tap(find.widgetWithText(TextButton, t.dialog_close));
    await _settle(tester);
    // 对话框退场动画 + `_busy` 复位再各画一帧。
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(AlertDialog), findsNothing);

    // 重复地址：本地判掉，不发请求。
    rig.server.seen.clear();
    await tester.enterText(_routeField(), _lan);
    await tester.tap(find.widgetWithText(FilledButton, t.jellyfin_route_add));
    await _settle(tester);
    expect(rig.server.seen, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
  });
}
