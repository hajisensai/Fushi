// PlexConfigWidget（真 DB + MockClient，无真实 plex.tv / PMS）。锁住：
//  [1] PIN 登录：建 PIN → 打开授权页 → 轮询拿 token → 列 resources → 逐条探测连接
//      （局域网不通落到公网）→ 按服务器写配置（全部连接存成线路、当前 = 可达那条）；
//  [2] 手动连接：/identity 取身份、/library/sections 验 token，写一条单线路配置；
//  [3] 退出登录只删这一台 Plex，Jellyfin 配置不受影响。

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/plex_settings_widget.dart';
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi/src/sync/remote_library_cache.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/test_platform_services.dart';

FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

Future<AppModel> _appModel(FushiDatabase db) async {
  final PreferencesRepository prefsRepo = PreferencesRepository(db);
  await prefsRepo.loadFromDb();
  final Directory tempDir = Directory.systemTemp.createTempSync(
    'fushi_plex_settings_',
  );
  addTearDown(() async {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });
  return AppModel(testPlatformServices())
    ..wireLocalAudioForTesting(prefsRepo: prefsRepo, databaseDirectory: tempDir)
    ..wireDatabaseForTesting(db);
}

http.Response _json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// 假 plex.tv + 两台地址的 PMS（局域网地址不通、公网地址通）。
class _FakePlex {
  final List<http.Request> seen = <http.Request>[];
  int pinChecks = 0;

  MockClient client() => MockClient((http.Request req) async {
    seen.add(req);
    final Uri u = req.url;
    if (u.host == 'plex.tv' &&
        u.path == '/api/v2/pins' &&
        req.method == 'POST') {
      return _json(<String, Object?>{'id': 1, 'code': 'pin-code'}, 201);
    }
    if (u.host == 'plex.tv' && u.path == '/api/v2/pins/1') {
      pinChecks++;
      return _json(<String, Object?>{
        'id': 1,
        'code': 'pin-code',
        'authToken': pinChecks >= 2 ? 'acct-token' : null,
      });
    }
    if (u.host == 'plex.tv' && u.path == '/api/v2/user') {
      return _json(<String, Object?>{'id': 42, 'username': 'carol'});
    }
    if (u.host == 'clients.plex.tv') {
      return _json(<Object?>[
        <String, Object?>{
          'name': 'Home PMS',
          'provides': 'server',
          'clientIdentifier': 'mid-1',
          'accessToken': 'server-token',
          'connections': <Object?>[
            <String, Object?>{
              'uri': 'https://wan.plex.direct:32400',
              'local': false,
            },
            <String, Object?>{'uri': 'http://10.0.0.9:32400', 'local': true},
          ],
        },
      ]);
    }
    if (u.path == '/identity') {
      if (u.host == '10.0.0.9') {
        throw http.ClientException('Connection refused', u);
      }
      return _json(<String, Object?>{
        'MediaContainer': <String, Object?>{'machineIdentifier': 'mid-1'},
      });
    }
    if (u.path == '/library/sections') {
      if (req.headers['X-Plex-Token'] != 'manual-token') {
        return http.Response('', 401);
      }
      return _json(<String, Object?>{
        'MediaContainer': <String, Object?>{'Directory': <Object?>[]},
      });
    }
    if (u.path == '/') {
      return _json(<String, Object?>{
        'MediaContainer': <String, Object?>{'friendlyName': 'Manual PMS'},
      });
    }
    return http.Response('', 404);
  });
}

Widget _harness({
  required FushiDatabase db,
  required AppModel appModel,
  required RemoteLibraryCache cache,
  required http.Client Function() clientFactory,
  required List<Uri> opened,
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
              return PlexConfigWidget(
                settingsContext: sctx,
                httpClientFactory: clientFactory,
                openUrl: (Uri url) async {
                  opened.add(url);
                  return true;
                },
                pinPollInterval: const Duration(milliseconds: 10),
              );
            },
          ),
        ),
      ),
    ),
  );
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

Future<void> _enterInto(WidgetTester tester, int fieldIndex, String text) =>
    tester.enterText(
      find.descendant(
        of: find.byType(FushiTextField).at(fieldIndex),
        matching: find.byType(EditableText),
      ),
      text,
    );

void _bigView(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('[1] PIN 登录：探测连接后写配置，当前线路 = 可达的公网地址', (
    WidgetTester tester,
  ) async {
    _bigView(tester);
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _appModel(db);
    final _FakePlex fake = _FakePlex();
    final List<Uri> opened = <Uri>[];
    await tester.pumpWidget(
      _harness(
        db: db,
        appModel: appModel,
        cache: RemoteLibraryCache(),
        clientFactory: fake.client,
        opened: opened,
      ),
    );
    await _settle(tester);
    expect(find.text(t.jellyfin_servers_empty_hint), findsOneWidget);

    await tester.tap(find.text(t.plex_account_sign_in));
    await _settle(tester);

    expect(opened, hasLength(1));
    expect(opened.single.toString(), startsWith('https://app.plex.tv/auth#?'));
    expect(fake.pinChecks, greaterThanOrEqualTo(2));
    final List<MediaServerConfig> saved =
        await tester.runAsync(() => SyncRepository(db).getMediaServers()) ??
        const <MediaServerConfig>[];
    final PlexServerConfig plex = saved.single as PlexServerConfig;
    expect(plex.machineIdentifier, 'mid-1');
    expect(plex.token, 'server-token', reason: '用服务器级 token，不是账号 token');
    expect(plex.connections, <String>[
      'http://10.0.0.9:32400',
      'https://wan.plex.direct:32400',
    ], reason: '局域网排在前');
    expect(plex.effectiveServerUrl, 'https://wan.plex.direct:32400');
    expect(plex.accountId, '42');
    expect(plex.accountName, 'carol');
    expect(plex.clientIdentifier, isNotEmpty);
    // 所有请求都带同一个客户端身份。
    expect(
      fake.seen
          .map((http.Request r) => r.headers['X-Plex-Client-Identifier'])
          .toSet(),
      <String?>{plex.clientIdentifier},
    );
    expect(find.textContaining('Home PMS'), findsOneWidget);
  });

  testWidgets('[2] 手动连接：identity + sections 验证后写单线路配置', (
    WidgetTester tester,
  ) async {
    _bigView(tester);
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _appModel(db);
    final _FakePlex fake = _FakePlex();
    await tester.pumpWidget(
      _harness(
        db: db,
        appModel: appModel,
        cache: RemoteLibraryCache(),
        clientFactory: fake.client,
        opened: <Uri>[],
      ),
    );
    await _settle(tester);
    await _enterInto(tester, 0, 'pms.lan:32400/');
    await _enterInto(tester, 1, 'manual-token');
    await tester.tap(find.text(t.plex_manual_connect));
    await _settle(tester);

    final List<MediaServerConfig> saved =
        await tester.runAsync(() => SyncRepository(db).getMediaServers()) ??
        const <MediaServerConfig>[];
    final PlexServerConfig plex = saved.single as PlexServerConfig;
    expect(plex.connections, <String>['http://pms.lan:32400']);
    expect(plex.token, 'manual-token');
    expect(plex.serverName, 'Manual PMS');
    expect(
      fake.seen.map((http.Request r) => r.url.path),
      containsAll(<String>['/identity', '/library/sections']),
    );
  });

  testWidgets('[3] 退出登录只删这一台 Plex，Jellyfin 不受影响', (WidgetTester tester) async {
    _bigView(tester);
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final AppModel appModel = await _appModel(db);
    const JellyfinServerConfig nas = JellyfinServerConfig(
      serverUrl: 'http://nas:8096',
      username: 'alice',
      userId: 'u-nas',
      accessToken: 'tok',
    );
    const PlexServerConfig plex = PlexServerConfig(
      machineIdentifier: 'mid-1',
      token: 'tok',
      clientIdentifier: 'c',
      connections: <String>['http://pms:32400'],
      serverName: 'Home PMS',
    );
    await SyncRepository(db).setMediaServers(<MediaServerConfig>[nas, plex]);
    final RemoteLibraryCache cache = RemoteLibraryCache();
    await tester.pumpWidget(
      _harness(
        db: db,
        appModel: appModel,
        cache: cache,
        clientFactory: _FakePlex().client,
        opened: <Uri>[],
      ),
    );
    await _settle(tester);
    expect(find.textContaining('Home PMS'), findsOneWidget);
    await tester.tap(find.byTooltip(t.jellyfin_sign_out));
    await _settle(tester);

    final List<MediaServerConfig> left =
        await tester.runAsync(() => SyncRepository(db).getMediaServers()) ??
        const <MediaServerConfig>[];
    expect(left.single, isA<JellyfinServerConfig>());
    expect(find.text(t.jellyfin_servers_empty_hint), findsOneWidget);
  });
}
