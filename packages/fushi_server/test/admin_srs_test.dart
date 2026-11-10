// admin API 的复习端点（docs/specs/2026-11-05-server-srs-design.md §4.1 / §4.5）：选哪几份 profile、默认那份、
// 立即同步、AnkiConnect 开关与 key（key 只报设没设，不回显）；改动写回配置文件、即时生效。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

const String kJa = '01928c3e-0000-7000-8000-00000000a0a0';
const String kZh = '01928c3e-0000-7000-8000-00000000b0b0';

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late AdminApi api;
  late File configFile;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_srs_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(port: 0, bind: '127.0.0.1', tls: false, adminToken: 'tok');
    await config.save(configFile);
    final ServerPrefs prefs = ServerPrefs(db);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
    );
    await host.start();
    api = AdminApi(
      AdminContext(
        config: config,
        configFile: configFile,
        paths: paths,
        log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
        db: db,
        identity: identity,
        host: host,
        startedAt: DateTime.now(),
      ),
    );
  });

  tearDown(() async {
    await host.stop();
    await db.close();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  Future<(int, Map<String, dynamic>)> call(
    String method,
    String path, [
    Object? body,
  ]) async {
    final shelf.Response r = await api.handle(
      shelf.Request(
        method,
        Uri.parse('http://localhost/api/admin/$path'),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    return (
      r.statusCode,
      Map<String, dynamic>.from(jsonDecode(await r.readAsString()) as Map),
    );
  }

  test('默认关：没有 profile，AnkiConnect 不监听', () async {
    final (int code, Map<String, dynamic> st) = await call('GET', 'srs');
    expect(code, 200);
    expect(st['enabled'], isFalse);
    expect(st['profiles'], isEmpty);
    expect((st['ankiConnect'] as Map)['enabled'], isFalse);
    expect((st['ankiConnect'] as Map)['listening'], isFalse);
  });

  test('加 / 设默认 / 去掉 profile：即时生效并写回配置文件', () async {
    var (int code, Map<String, dynamic> st) = await call(
      'PUT',
      'srs',
      <String, Object?>{
        'addProfiles': <String>[kJa, kZh],
      },
    );
    expect(code, 200, reason: '$st');
    expect(st['enabled'], isTrue);
    await host.srs!.syncNow();
    expect(host.srs!.storeFor(kZh), isNotNull);

    (code, st) = await call('PUT', 'srs', <String, Object?>{
      'defaultProfile': kZh,
    });
    expect(st['defaultProfile'], kZh);
    expect((await ServerConfig.load(configFile)).srs.defaultProfile, kZh);

    // 同步目录里没有这两份（没有设备同步过来）：照样列出、标成 missing，管理员能取消。
    final (_, Map<String, dynamic> found) = await call('GET', 'srs/profiles');
    expect(
      (found['profiles'] as List).map((Object? e) => (e! as Map)['uid']),
      containsAll(<String>[kJa, kZh]),
    );

    expect(
      (await call('POST', 'srs/sync', <String, Object?>{'profile': kJa})).$1,
      200,
    );
    expect(
      (await call('POST', 'srs/sync', <String, Object?>{
        'profile': '01928c3e-0000-7000-8000-00000000dead',
      })).$1,
      404,
    );

    (code, st) = await call('PUT', 'srs', <String, Object?>{
      'removeProfiles': <String>[kZh],
    });
    expect((st['config'] as Map)['profiles'], <String>[kJa]);
    expect(
      (st['config'] as Map)['defaultProfile'],
      '',
      reason: '默认那份被取消了：清空，回到列表第一份',
    );
    expect(st['defaultProfile'], kJa);
    expect(host.srs!.storeFor(kZh), isNull);
  });

  test('制卡牌组：miningDecks 整份替换；miningDecksPatch 只改给了的那几份，空串删掉那一项', () async {
    var (int code, Map<String, dynamic> st) = await call(
      'PUT',
      'srs',
      <String, Object?>{
        'addProfiles': <String>[kJa, kZh],
        'miningDecks': <String, String>{kJa: 'JA', kZh: 'ZH'},
      },
    );
    expect(code, 200, reason: '$st');

    (code, st) = await call('PUT', 'srs', <String, Object?>{
      'miningDecksPatch': <String, String>{kJa: ' JA::New '},
    });
    expect(code, 200, reason: '$st');
    expect((st['config'] as Map)['miningDecks'], <String, String>{
      kJa: 'JA::New',
      kZh: 'ZH',
    });

    (code, st) = await call('PUT', 'srs', <String, Object?>{
      'miningDecksPatch': <String, String>{kZh: ''},
    });
    expect((st['config'] as Map)['miningDecks'], <String, String>{
      kJa: 'JA::New',
    });
    expect(
      (await ServerConfig.load(configFile)).srs.miningDecks,
      <String, String>{kJa: 'JA::New'},
      reason: '写回配置文件',
    );

    // 两个都给：patch 合到这次的整份上。
    (code, st) = await call('PUT', 'srs', <String, Object?>{
      'miningDecks': <String, String>{kZh: 'ZH2'},
      'miningDecksPatch': <String, String>{kJa: 'JA3'},
    });
    expect((st['config'] as Map)['miningDecks'], <String, String>{
      kZh: 'ZH2',
      kJa: 'JA3',
    });

    // 整份替换照旧（WebUI 那条）。
    (code, st) = await call('PUT', 'srs', <String, Object?>{
      'miningDecks': <String, String>{kZh: 'Only'},
    });
    expect((st['config'] as Map)['miningDecks'], <String, String>{kZh: 'Only'});

    expect(
      (await call('PUT', 'srs', <String, Object?>{
        'miningDecksPatch': <String, String>{'not-a-uid': 'X'},
      })).$1,
      400,
    );
    expect(
      (await call('PUT', 'srs', <String, Object?>{
        'miningDecksPatch': <String>['x'],
      })).$1,
      400,
    );
  });

  test('参数不对：400；默认那份不在列表里：400', () async {
    expect(
      (await call('PUT', 'srs', <String, Object?>{
        'profiles': <String>['not-a-uid'],
      })).$1,
      400,
    );
    expect(
      (await call('PUT', 'srs', <String, Object?>{
        'profiles': <String>[kJa],
        'defaultProfile': kZh,
      })).$1,
      400,
    );
    expect(
      (await call('PUT', 'srs', <String, Object?>{'rolloverHour': 30})).$1,
      400,
    );
    expect(
      (await call('PUT', 'srs', <String, Object?>{'miningTarget': 'x'})).$1,
      400,
    );
  });

  test('AnkiConnect：局域网地址没 key 拒绝（409）；设了 key 只报设没设，不回显', () async {
    final (int refused, Map<String, dynamic> why) = await call(
      'PUT',
      'srs',
      <String, Object?>{
        'ankiConnect': <String, Object?>{'enabled': true, 'bind': '0.0.0.0'},
      },
    );
    expect(refused, 409);
    expect(why['reason'], 'ankiconnect_invalid');
    expect(host.config.ankiConnect.enabled, isFalse, reason: '被拒的改动不落地');

    final ServerSocket probe = await ServerSocket.bind('127.0.0.1', 0);
    final int freePort = probe.port;
    await probe.close();
    final (int ok, Map<String, dynamic> st) = await call(
      'PUT',
      'srs',
      <String, Object?>{
        'addProfiles': <String>[kJa],
        'ankiConnect': <String, Object?>{
          'enabled': true,
          'port': freePort,
          'apiKey': 'secret-key',
          'profileKeys': <String, String>{kJa: 'ja-key'},
        },
      },
    );
    expect(ok, 200, reason: '$st');
    final Map<dynamic, dynamic> ac = st['ankiConnect'] as Map;
    expect(ac['apiKeySet'], isTrue);
    expect((ac['profileKeysSet'] as Map)[kJa], isTrue);
    expect(jsonEncode(st), isNot(contains('secret-key')));
    expect(jsonEncode(st), isNot(contains('ja-key')));
    expect(host.ankiConnect!.listening, isTrue);

    // 空串 = 清掉共用 key；不给 = 不动。
    final (_, Map<String, dynamic> cleared) = await call(
      'PUT',
      'srs',
      <String, Object?>{
        'ankiConnect': <String, Object?>{'apiKey': ''},
      },
    );
    expect((cleared['ankiConnect'] as Map)['apiKeySet'], isFalse);
    expect(host.config.ankiConnect.profileKeys[kJa], 'ja-key');
  });
}
