// JellyfinConfigWidget 多服务器 UI（真 DB + MockClient，无真实服务器）。
//
// 视频页「媒体服务器」栏目一台一张卡片，设置页随之从「一台登录 / 登出」变成
// 「已登录列表 + 常驻添加表单」。本文件锁住：
//  [1] 两台已登录服务器渲染两行，「自动列出条目」开关只有一处、在列表上方；
//  [2] 展开一行、点「退出登录」只删这一台（另一台仍在、DB 只剩一条、该台缓存槽失效）；
//  [3] 添加表单登录成功 → 列表 +1（同 (serverUrl, userId) 重登只换令牌、不多一行，
//      且保留已点名的媒体库）。
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
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

const JellyfinServerConfig _nas = JellyfinServerConfig(
  serverUrl: 'http://nas:8096',
  username: 'alice',
  // 与假服务器的派生规则（u-<username>）一致：重登同账号才判成同一身份。
  userId: 'u-alice',
  accessToken: 'tok-nas',
  serverName: 'NAS',
  libraryIds: <String>['lib-anime'],
);

const JellyfinServerConfig _emby = JellyfinServerConfig(
  serverUrl: 'https://emby.example.com',
  username: 'bob',
  userId: 'u-emby',
  accessToken: 'tok-emby',
  serverName: 'Public Emby',
);

String _idOf(JellyfinServerConfig c) =>
    JellyfinVideoClient.sourceIdFor(serverUrl: c.serverUrl, userId: c.userId);

FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<AppModel> _appModel(FushiDatabase db) async {
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'fushi_jellyfin_settings_',
  );
  addTearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  return AppModel(testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

/// 假服务器的跨 client 状态：widget 每次登录 / 读 Views 都经 [clientFactory] 新建
/// 一个短命 client，请求记录与令牌序号必须放在工厂外面才能跨请求累计。
class _FakeServer {
  final List<http.Request> seen = <http.Request>[];
  int tokenSeq = 0;

  /// 任何 host 的 AuthenticateByName 都成功（userId 派生自用户名，令牌每次递增，
  /// 方便断言「重登换了令牌」）；Views 固定返回两个视频库 + 一个音乐库。
  MockClient client() => MockClient((http.Request req) async {
    seen.add(req);
    // BUG-2584：登录前先探连通性（GET /System/Info/Public，无需认证）。
    if (req.url.path == '/System/Info/Public') {
      return http.Response(
        jsonEncode(<String, Object?>{'ServerName': 'Fake ${req.url.host}'}),
        200,
      );
    }
    if (req.url.path == '/Users/AuthenticateByName') {
      final Map<String, Object?> body = (jsonDecode(req.body) as Map)
          .cast<String, Object?>();
      final String username = body['Username'] as String;
      tokenSeq++;
      return http.Response(
        jsonEncode(<String, Object?>{
          'AccessToken': 'tok-$username-$tokenSeq',
          'ServerName': 'Fake ${req.url.host}',
          'User': <String, Object?>{'Id': 'u-$username'},
        }),
        200,
      );
    }
    if (req.url.path.endsWith('/Views')) {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'Items': <Object?>[
              <String, Object?>{
                'Id': 'lib-anime',
                'Name': 'Anime',
                'CollectionType': 'tvshows',
              },
              <String, Object?>{
                'Id': 'lib-movies',
                'Name': 'Movies',
                'CollectionType': 'movies',
              },
              <String, Object?>{
                'Id': 'lib-music',
                'Name': 'Music',
                'CollectionType': 'music',
              },
            ],
          }),
        ),
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

/// 一台服务器的摘要行（标题含服务器名 · 地址）。
Finder _serverRow(JellyfinServerConfig c) => find.byWidgetPredicate(
  (Widget w) =>
      w is FushiListItem &&
      w.title is Text &&
      ((w.title as Text).data ?? '').contains(c.serverUrl),
);

Finder _autoListSwitch() => find.byWidgetPredicate(
  (Widget w) =>
      w is AdaptiveSettingsSwitchRow && w.title == t.jellyfin_auto_list_title,
);

Future<void> _enterInto(WidgetTester tester, int fieldIndex, String text) =>
    tester.enterText(
      find.descendant(
        of: find.byType(FushiTextField).at(fieldIndex),
        matching: find.byType(EditableText),
      ),
      text,
    );

void main() {
  // 每条都把视口放宽到 800x1600：列表 + 表单竖排超过默认 600 逻辑像素高度，
  // SingleChildScrollView 兜底后仍要让「退出登录」按钮在可点击范围内。

  testWidgets('[1] 两台已登录服务器渲染两行；自动列出开关只有一处、在列表上方', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _appModel(db);
    await SyncRepository(
      db,
    ).setJellyfinServers(<JellyfinServerConfig>[_nas, _emby]);
    final _FakeServer server = _FakeServer();

    await tester.pumpWidget(
      _harness(
        db: db,
        appModel: appModel,
        cache: RemoteLibraryCache(),
        clientFactory: server.client,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    expect(_serverRow(_nas), findsOneWidget);
    expect(_serverRow(_emby), findsOneWidget);
    expect(find.text(t.jellyfin_servers_empty_hint), findsNothing);
    expect(_autoListSwitch(), findsOneWidget, reason: '全局偏好只渲染一处');
    expect(
      tester.getTopLeft(_autoListSwitch()).dy,
      lessThan(tester.getTopLeft(_serverRow(_nas)).dy),
      reason: '开关在列表上方',
    );
    // 添加表单常驻在列表下方。
    expect(find.text(t.jellyfin_servers_add_title), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, t.jellyfin_sign_in),
      findsOneWidget,
    );
    expect(
      server.seen,
      isEmpty,
      reason: '行未展开不发 Views 请求（分区 collapsedByDefault 同理）',
    );
  });

  testWidgets('[2] 展开一行点退出登录：只删这一台，另一台仍在、该台缓存槽失效', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _appModel(db);
    final SyncRepository repo = SyncRepository(db);
    await repo.setJellyfinServers(<JellyfinServerConfig>[_nas, _emby]);
    final _FakeServer server = _FakeServer();
    final RemoteLibraryCache cache = RemoteLibraryCache();
    // 两台各塞一个缓存槽：登出 NAS 后只有 NAS 的槽该失效。
    await cache.read<String>(
      sourceId: _idOf(_nas),
      key: 'videos',
      fetch: () async => 'nas-list',
      ttl: const Duration(hours: 1),
    );
    await cache.read<String>(
      sourceId: _idOf(_emby),
      key: 'videos',
      fetch: () async => 'emby-list',
      ttl: const Duration(hours: 1),
    );

    await tester.pumpWidget(
      _harness(
        db: db,
        appModel: appModel,
        cache: cache,
        clientFactory: server.client,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    // 未展开：没有退出登录按钮。
    expect(find.widgetWithText(TextButton, t.jellyfin_sign_out), findsNothing);

    await tester.tap(_serverRow(_nas));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.widgetWithText(TextButton, t.jellyfin_sign_out),
      findsOneWidget,
      reason: '只展开了一行 → 只有一个退出按钮',
    );
    expect(find.text('Anime'), findsOneWidget, reason: '展开后媒体库面板取 Views');
    expect(find.text('Music'), findsNothing, reason: '音乐库不在视频域');
    expect(server.seen.map((http.Request r) => r.url.path), <String>[
      '/Users/u-alice/Views',
    ]);

    await tester.tap(find.widgetWithText(TextButton, t.jellyfin_sign_out));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    expect(_serverRow(_nas), findsNothing);
    expect(_serverRow(_emby), findsOneWidget, reason: '另一台不受影响');
    final List<JellyfinServerConfig> left = await repo.getJellyfinServers();
    expect(left.map(_idOf), <String>[_idOf(_emby)], reason: 'DB 只删这一台');
    expect(
      cache.peek<String>(sourceId: _idOf(_nas), key: 'videos'),
      isNull,
      reason: '登出必须失效这台的远端清单槽',
    );
    expect(
      cache.peek<String>(sourceId: _idOf(_emby), key: 'videos'),
      'emby-list',
      reason: '别台的槽不能被连坐',
    );
  });

  testWidgets('[3] 添加表单登录成功 → 列表 +1；同账号重登只换令牌、不多一行、保留库点名', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _appModel(db);
    final SyncRepository repo = SyncRepository(db);
    await repo.setJellyfinServers(<JellyfinServerConfig>[_nas]);
    final _FakeServer server = _FakeServer();

    await tester.pumpWidget(
      _harness(
        db: db,
        appModel: appModel,
        cache: RemoteLibraryCache(),
        clientFactory: server.client,
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(_serverRow(_nas), findsOneWidget);

    // 登录第二台。
    await _enterInto(tester, 0, 'emby.example.com');
    await _enterInto(tester, 1, 'bob');
    await _enterInto(tester, 2, 'pw');
    await tester.tap(find.widgetWithText(FilledButton, t.jellyfin_sign_in));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    // 先探连通性再登录（BUG-2584）：两个请求、同一台服务器。
    expect(
      server.seen.map((http.Request r) => r.url.path).toList(),
      <String>['/System/Info/Public', '/Users/AuthenticateByName'],
    );
    expect(server.seen.last.url.host, 'emby.example.com');
    List<JellyfinServerConfig> servers = await repo.getJellyfinServers();
    expect(servers, hasLength(2), reason: '登录成功 → 列表 +1');
    expect(
      servers[1].serverUrl,
      'http://emby.example.com',
      reason: '缺 scheme 由 normalizeServerUrl 补 http（局域网常态）',
    );
    expect(servers[1].userId, 'u-bob');
    expect(servers[1].accessToken, 'tok-bob-1');
    expect(_serverRow(_nas), findsOneWidget);
    expect(_serverRow(servers[1]), findsOneWidget, reason: 'UI 列表也 +1');
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: find.byType(FushiTextField).at(2),
              matching: find.byType(EditableText),
            ),
          )
          .controller
          .text,
      isEmpty,
      reason: '登录成功后密码框清空',
    );

    // 同 (serverUrl, userId) 重登：换令牌，不多一行，NAS 已点名的库保留。
    await _enterInto(tester, 0, 'http://nas:8096');
    await _enterInto(tester, 1, 'alice');
    await _enterInto(tester, 2, 'pw2');
    await tester.tap(find.widgetWithText(FilledButton, t.jellyfin_sign_in));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));

    servers = await repo.getJellyfinServers();
    expect(servers, hasLength(2), reason: '同身份重登不能多出第三行');
    expect(servers[0].userId, 'u-alice');
    expect(servers[0].accessToken, 'tok-alice-2', reason: '令牌换成新的');
    expect(servers[0].libraryIds, <String>[
      'lib-anime',
    ], reason: 'BUG-1891 的库点名不能因为重登被清回「全部」');
    expect(find.byType(FushiListItem), findsNWidgets(2), reason: 'UI 仍两行');
  });
}
