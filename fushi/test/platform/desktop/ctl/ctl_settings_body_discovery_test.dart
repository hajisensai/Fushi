import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/discovery/alist_site_config.dart';
import 'package:fushi/src/media/discovery/audiobookshelf_server_config.dart';
import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_settings_body_discovery.dart';
import 'package:fushi/src/platform/desktop/ctl/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:material_ui/material_ui.dart';

import '../../../helpers/test_platform_services.dart';

/// 发现来源 / OPDS / AList / Audiobookshelf 的控制通道条目：增删改真写穿偏好、
/// 列表不回显凭据、ABS 改地址即退出登录、连接测试走真实请求路径。
void main() {
  late FushiDatabase db;
  late PreferencesRepository prefs;
  late AppModel appModel;
  late SettingsContext sc;
  late Directory tempDir;

  final List<SettingsItem> items = <SettingsItem>[
    for (final CtlBodyPage page in buildCtlDiscoveryBodyPages()) ...page.items,
  ];

  SettingsCliList listOf(String id) =>
      (items.singleWhere((SettingsItem i) => i.id == id) as SettingsCustomItem)
          .cliList!;

  SettingsCliAction actionOf(String id) =>
      (items.singleWhere((SettingsItem i) => i.id == id) as SettingsActionItem)
          .cli!;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = PreferencesRepository(db);
    await prefs.loadFromDb();
    tempDir = Directory.systemTemp.createTempSync('fushi_discovery_cli_');
    appModel = AppModel(testPlatformServices())
      ..wireLocalAudioForTesting(prefsRepo: prefs, databaseDirectory: tempDir)
      ..wireDatabaseForTesting(db);
  });

  tearDown(() async {
    await db.close();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> pumpContext(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, _) {
              sc = SettingsContext(
                context: context,
                appModel: appModel,
                ref: ref,
                readerSource: ReaderFushiSource.instance,
                refresh: () {},
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
  }

  test('ids are unique and carry the .cli. segment', () {
    final List<String> ids = items.map((SettingsItem i) => i.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    expect(ids.every((String id) => id.contains('.cli.')), isTrue);
    final Iterable<SettingsCliParam> secrets =
        <SettingsCliParam>[
          ...listOf(kCtlOpdsListId).fields,
          ...listOf(kCtlAListListId).fields,
          ...actionOf(kCtlAbsSignInId).params,
        ].where(
          (SettingsCliParam p) => p.name == 'password' || p.name == 'api_key',
        );
    expect(secrets, isNotEmpty);
    expect(secrets.every((SettingsCliParam p) => p.secret), isTrue);
    expect(actionOf(kCtlAbsSignOutId).confirm, isTrue);
  });

  testWidgets('builtin discovery sources: list + toggle write through', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliList cli = listOf(kCtlDiscoverySourcesListId);
    final List<Map<String, Object?>> rows = await cli.list(sc);
    // 内置 BT 站发现源已移除（用户自己添加 BT 站）：这里只剩非 BT 的内置源。
    expect(
      rows.map((Map<String, Object?> r) => r['id']),
      isNot(contains('nyaa')),
    );
    expect(
      rows.map((Map<String, Object?> r) => r['id']),
      contains('alist-erogame'),
    );
    await cli.update!(sc, 'alist-erogame', <String, String>{
      'enabled': 'false',
    });
    expect(appModel.discoveryDisabledSourceIds, contains('alist-erogame'));
    final Map<String, Object?> back =
        await cli.update!(sc, 'alist-erogame', <String, String>{
              'enabled': 'true',
            })
            as Map<String, Object?>;
    expect(back['enabled'], isTrue);
    expect(
      appModel.discoveryDisabledSourceIds,
      isNot(contains('alist-erogame')),
    );
    await expectLater(
      cli.update!(sc, 'nope', <String, String>{'enabled': 'true'}),
      throwsArgumentError,
    );
    await expectLater(
      cli.update!(sc, 'alist-erogame', <String, String>{'enabled': 'maybe'}),
      throwsArgumentError,
    );
  });

  testWidgets('opds: add/set/rm write through, password never listed', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliList cli = listOf(kCtlOpdsListId);
    final Map<String, Object?> created =
        await cli.add!(sc, <String, String>{
              'url': 'https://books.test/opds',
              'name': 'Lib',
              'username': 'u',
              'password': 'SECRET-PW',
            })
            as Map<String, Object?>;
    final String id = created['id']! as String;
    final OpdsServerConfig stored = prefs.discoveryOpdsServers.single;
    expect(stored.password, 'SECRET-PW');
    expect(stored.catalogUrl.toString(), 'https://books.test/opds');
    expect(jsonEncode(await cli.list(sc)), isNot(contains('SECRET-PW')));
    expect((await cli.list(sc)).single['hasPassword'], isTrue);

    await cli.update!(sc, id, <String, String>{'enabled': 'false'});
    expect(prefs.discoveryOpdsServers.single.enabled, isFalse);
    expect(prefs.discoveryOpdsServers.single.password, 'SECRET-PW');

    // 明文 HTTP 要显式放行：配置构造器拒绝，不落盘。
    await expectLater(
      cli.update!(sc, id, <String, String>{'url': 'http://lan.test/opds'}),
      throwsArgumentError,
    );
    await cli.update!(sc, id, <String, String>{
      'url': 'http://lan.test/opds',
      'allow_http': 'true',
    });
    expect(
      prefs.discoveryOpdsServers.single.catalogUrl.toString(),
      'http://lan.test/opds',
    );

    await cli.remove!(sc, id);
    expect(prefs.discoveryOpdsServers, isEmpty);
    await expectLater(cli.remove!(sc, id), throwsArgumentError);
  });

  testWidgets('alist: kinds parse and write through', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final SettingsCliList cli = listOf(kCtlAListListId);
    final Map<String, Object?> created =
        await cli.add!(sc, <String, String>{
              'url': 'https://alist.test',
              'kinds': 'game,manga',
              'password': 'PW',
            })
            as Map<String, Object?>;
    final AListSiteConfig stored = prefs.discoveryAListSites.single;
    expect(stored.kinds, <DiscoveryMediaKind>{
      DiscoveryMediaKind.game,
      DiscoveryMediaKind.manga,
    });
    expect(created['kinds'], 'game,manga');
    expect(jsonEncode(await cli.list(sc)), isNot(contains('"PW"')));
    await expectLater(
      cli.update!(sc, stored.id, <String, String>{'kinds': 'video'}),
      throwsArgumentError,
    );
    await expectLater(
      cli.update!(sc, stored.id, <String, String>{'kinds': ''}),
      throwsArgumentError,
    );
    await cli.update!(sc, stored.id, <String, String>{'kinds': 'novel'});
    expect(prefs.discoveryAListSites.single.kinds, <DiscoveryMediaKind>{
      DiscoveryMediaKind.novel,
    });
  });

  testWidgets('audiobookshelf: url change signs out, sign-out clears tokens', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    await appModel
        .setDiscoveryAudiobookshelfServers(<AudiobookshelfServerConfig>[
          AudiobookshelfServerConfig(
            id: 'server-1',
            name: 'NAS',
            serverUrl: Uri.parse('https://abs.test'),
            username: 'me',
            tokens: const AudiobookshelfTokens(
              accessToken: 'ACCESS-TOKEN',
              refreshToken: 'REFRESH-TOKEN',
            ),
          ),
        ]);
    final SettingsCliList cli = listOf(kCtlAbsListId);
    final List<Map<String, Object?>> rows = await cli.list(sc);
    expect(rows.single['signedIn'], isTrue);
    expect(jsonEncode(rows), isNot(contains('TOKEN')));

    await cli.update!(sc, 'server-1', <String, String>{'name': 'Home'});
    expect(prefs.discoveryAudiobookshelfServers.single.isSignedIn, isTrue);

    await cli.update!(sc, 'server-1', <String, String>{
      'url': 'https://other.test',
    });
    expect(prefs.discoveryAudiobookshelfServers.single.isSignedIn, isFalse);
    expect(prefs.discoveryAudiobookshelfServers.single.name, 'Home');

    // 登录参数校验在任何网络请求之前。
    await expectLater(
      actionOf(kCtlAbsSignInId).run!(sc, <String, String>{'id': 'server-1'}),
      throwsArgumentError,
    );
    await expectLater(
      actionOf(kCtlAbsTestId).run!(sc, <String, String>{'id': 'server-1'}),
      throwsArgumentError,
      reason: '未登录不能测试',
    );

    await appModel
        .setDiscoveryAudiobookshelfServers(<AudiobookshelfServerConfig>[
          prefs.discoveryAudiobookshelfServers.single.withTokens(
            const AudiobookshelfTokens(accessToken: 'A'),
            username: 'me',
          ),
        ]);
    await actionOf(kCtlAbsSignOutId).run!(sc, <String, String>{
      'id': 'server-1',
    });
    expect(prefs.discoveryAudiobookshelfServers.single.isSignedIn, isFalse);
    expect(prefs.discoveryAudiobookshelfServers.single.username, isEmpty);

    final Map<String, Object?> added =
        await cli.add!(sc, <String, String>{'url': 'https://abs2.test/'})
            as Map<String, Object?>;
    expect(added['signedIn'], isFalse);
    expect(prefs.discoveryAudiobookshelfServers, hasLength(2));
    await expectLater(
      cli.add!(sc, <String, String>{'url': 'http://lan.test:13378'}),
      throwsArgumentError,
      reason: '明文 HTTP 要显式 allow_http',
    );
    await cli.remove!(sc, 'server-1');
    expect(prefs.discoveryAudiobookshelfServers, hasLength(1));
  });

  testWidgets('opds test probes the real endpoint and reports failure', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    // flutter_test 给 HttpClient 装了一律回 400 的假实现：换真客户端才真打到本机服务。
    final HttpOverrides? saved = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = saved);
    int hits = 0;
    await tester.runAsync(() async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      server.listen((HttpRequest request) {
        hits++;
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('nope');
        request.response.close();
      });
      try {
        await appModel.setDiscoveryOpdsServers(<OpdsServerConfig>[
          OpdsServerConfig(
            id: 'opds-1',
            name: 'Local',
            catalogUrl: Uri.parse('http://127.0.0.1:${server.port}/opds'),
          ),
        ]);
        final Object? result = await actionOf(kCtlOpdsTestId).run!(
          sc,
          <String, String>{'id': 'opds-1'},
        );
        final Map<String, Object?> json = result! as Map<String, Object?>;
        expect(json['ok'], isFalse);
        expect(json['message'], isA<String>());
        expect(hits, greaterThan(0), reason: '请求必须真打到本机服务');
        await expectLater(
          actionOf(kCtlOpdsTestId).run!(sc, <String, String>{'id': 'nope'}),
          throwsArgumentError,
        );
      } finally {
        await server.close(force: true);
      }
    });
  });

  testWidgets('opds test: Kavita 探测写回的地址与列表输出都不含 API key，换 key 后照常可用', (
    WidgetTester tester,
  ) async {
    await pumpContext(tester);
    final HttpOverrides? saved = HttpOverrides.current;
    HttpOverrides.global = _RealHttpOverrides();
    addTearDown(() => HttpOverrides.global = saved);
    const String oldKey = 'KAVITA-OLD-KEY-0001';
    const String newKey = 'KAVITA-NEW-KEY-0002';
    String acceptedKey = oldKey;
    final List<String> paths = <String>[];
    await tester.runAsync(() async {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      server.listen((HttpRequest request) {
        paths.add(request.uri.path);
        if (request.uri.path == '/api/opds/$acceptedKey') {
          request.response
            ..headers.contentType = ContentType('application', 'atom+xml')
            ..write('<feed xmlns="http://www.w3.org/2005/Atom"></feed>');
        } else {
          request.response.statusCode = HttpStatus.notFound;
        }
        request.response.close();
      });
      try {
        final SettingsCliList cli = listOf(kCtlOpdsListId);
        final Map<String, Object?> created =
            await cli.add!(sc, <String, String>{
                  'url': 'http://127.0.0.1:${server.port}',
                  'api_key': oldKey,
                })
                as Map<String, Object?>;
        final String id = created['id']! as String;

        final Object? first = await actionOf(kCtlOpdsTestId).run!(
          sc,
          <String, String>{'id': id},
        );
        expect((first! as Map<String, Object?>)['ok'], isTrue);
        expect(paths.last, '/api/opds/$oldKey', reason: '请求本身要带真 key');
        expect(jsonEncode(first), isNot(contains(oldKey)));

        // 写回的是占位形态：落盘的配置与控制通道列表都不含 key 明文。
        final OpdsServerConfig stored = prefs.discoveryOpdsServers.single;
        expect(stored.catalogUrl.pathSegments, <String>[
          'api',
          'opds',
          kOpdsApiKeyPlaceholder,
        ]);
        expect(stored.toJson()['url'], isNot(contains(oldKey)));
        expect(jsonEncode(await cli.list(sc)), isNot(contains(oldKey)));

        // 服务端换了 key：只改 api_key，写回的地址自动跟着用新 key。
        acceptedKey = newKey;
        await cli.update!(sc, id, <String, String>{'api_key': newKey});
        paths.clear();
        final Object? second = await actionOf(kCtlOpdsTestId).run!(
          sc,
          <String, String>{'id': id},
        );
        expect((second! as Map<String, Object?>)['ok'], isTrue);
        expect(paths, <String>['/api/opds/$newKey']);
        expect(jsonEncode(await cli.list(sc)), isNot(contains(newKey)));
      } finally {
        await server.close(force: true);
      }
    });
  });
}

class _RealHttpOverrides extends HttpOverrides {}
