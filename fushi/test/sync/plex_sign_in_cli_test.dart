import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/video/media_server/media_server_config.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/settings/settings_cli_tasks.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/sync/plex_settings_widget.dart';
import 'package:fushi/src/sync/plex_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

http.Response _json(Object body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status);

/// 假 plex.tv + 一台 PMS（局域网地址不通、公网地址通）；[authorizeAfter] 次查询后
/// PIN 才带上账号 token（null = 永不授权）。
class _FakePlex {
  _FakePlex({this.authorizeAfter = 2});

  final int? authorizeAfter;
  int pinChecks = 0;

  MockClient client() => MockClient((http.Request req) async {
    final Uri u = req.url;
    if (u.host == 'plex.tv' && u.path == '/api/v2/pins') {
      return _json(<String, Object?>{'id': 1, 'code': 'pin-code'}, 201);
    }
    if (u.host == 'plex.tv' && u.path == '/api/v2/pins/1') {
      pinChecks++;
      final bool ok = authorizeAfter != null && pinChecks >= authorizeAfter!;
      return _json(<String, Object?>{
        'id': 1,
        'code': 'pin-code',
        'authToken': ok ? 'acct-token' : null,
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
    return http.Response('', 404);
  });
}

/// plex.tv 账号 PIN 授权的控制通道入口：请求里先拿到授权链接与 PIN，后台轮询，
/// 授权后与设置页同一处（savePlexAccountServers）落库；可取消、过期失败。
void main() {
  late FushiDatabase db;
  late SettingsContext settings;
  late SettingsCliTaskRegistry registry;

  Future<void> capture(WidgetTester tester) async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    final Directory tmp = Directory.systemTemp.createTempSync(
      'fushi_plex_cli_',
    );
    addTearDown(() => tmp.deleteSync(recursive: true));
    final AppModel app =
        await tester.runAsync(() async {
              final PreferencesRepository prefs = PreferencesRepository(db);
              await prefs.loadFromDb();
              return AppModel(testPlatformServices())
                ..wireLocalAudioForTesting(
                  prefsRepo: prefs,
                  databaseDirectory: tmp,
                )
                ..wireDatabaseForTesting(db);
            })
            as AppModel;
    registry = SettingsCliTaskRegistry();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Consumer(
            builder: (BuildContext context, WidgetRef ref, Widget? _) {
              settings = SettingsContext(
                context: context,
                appModel: app,
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

  tearDown(() async => db.close());

  testWidgets('授权链接与 PIN 在返回的快照里；授权后落库可达线路', (WidgetTester tester) async {
    await capture(tester);
    final _FakePlex plex = _FakePlex();
    final SettingsCliTask task =
        await tester.runAsync(
              () => startPlexAccountSignInForCli(
                settings,
                pollInterval: const Duration(milliseconds: 5),
                probeTimeout: const Duration(seconds: 2),
                httpClientFactory: plex.client,
                registry: registry,
              ),
            )
            as SettingsCliTask;
    final Map<String, Object?> snapshot = task.toJson();
    final Map<Object?, Object?> detail = snapshot['detail']! as Map;
    expect(detail['pin'], 'pin-code');
    expect(detail['authUrl'], contains('code=pin-code'));
    expect(snapshot['cancellable'], isTrue);
    await expectLater(
      startPlexAccountSignInForCli(settings, registry: registry),
      throwsStateError,
      reason: '同时只能有一轮授权',
    );

    await tester.runAsync(() => task.whenDone);
    expect(task.status, SettingsCliTaskStatus.done, reason: task.error);
    expect(task.result!['added'], 1);
    final List<MediaServerConfig> servers =
        await tester.runAsync(() => SyncRepository(db).getMediaServers())
            as List<MediaServerConfig>;
    final PlexServerConfig saved = servers.whereType<PlexServerConfig>().single;
    expect(saved.machineIdentifier, 'mid-1');
    expect(saved.token, 'server-token');
    expect(saved.accountName, 'carol');
    expect(saved.effectiveServerUrl, 'https://wan.plex.direct:32400');
    expect(jsonEncode(task.toJson()), isNot(contains('token')));
  });

  testWidgets('task cancel 停止轮询；PIN 过期以 failed 结束', (
    WidgetTester tester,
  ) async {
    await capture(tester);
    final _FakePlex never = _FakePlex(authorizeAfter: null);
    final SettingsCliTask waiting =
        await tester.runAsync(
              () => startPlexAccountSignInForCli(
                settings,
                pollInterval: const Duration(milliseconds: 5),
                httpClientFactory: never.client,
                registry: registry,
              ),
            )
            as SettingsCliTask;
    expect(registry.cancel(waiting), SettingsCliCancelOutcome.requested);
    await tester.runAsync(() => waiting.whenDone);
    expect(waiting.status, SettingsCliTaskStatus.cancelled);

    final SettingsCliTask expiring =
        await tester.runAsync(
              () => startPlexAccountSignInForCli(
                settings,
                pollInterval: const Duration(milliseconds: 5),
                timeout: const Duration(milliseconds: 30),
                httpClientFactory: _FakePlex(authorizeAfter: null).client,
                registry: registry,
              ),
            )
            as SettingsCliTask;
    await tester.runAsync(() => expiring.whenDone);
    expect(expiring.status, SettingsCliTaskStatus.failed);
    final List<MediaServerConfig> servers =
        await tester.runAsync(() => SyncRepository(db).getMediaServers())
            as List<MediaServerConfig>;
    expect(servers, isEmpty);
  });
}
