// 服务端操作目录里的复习（SRS）操作（admin_ops.dart）：对真的 AdminApi + HeadlessHost
// 跑——只读转发、立即同步要用户表态、制卡落点 / 牌组 / 翻日时刻可撤销（被手改过报
// superseded）、改一份的牌组不动别的、AnkiConnect 设置与选哪几份 profile 不进目录。
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/agent/agent_tool.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/admin/admin_ops.dart';
import 'package:fushi_server/src/agent_host.dart';
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

const List<String> kSrsOps = <String>[
  'server.srs.status',
  'server.srs.profiles',
  'server.srs.sync',
  'server.srs.mining-target.set',
  'server.srs.mining-deck.set',
  'server.srs.rollover-hour.set',
];

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late HeadlessHost host;
  late AdminApi api;
  late OpInvoker invoker;
  late List<String> requests;

  /// 模拟并发：操作发出 `PUT /api/admin/srs` 之前先跑一下（管理员在 WebUI 里同时改）。
  Future<void> Function()? beforeSrsPut;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_srs_ops_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
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
    requests = <String>[];
    beforeSrsPut = null;
    invoker = OpInvoker(
      buildServerAdminOpCatalog(
        () => (shelf.Request r) async {
          requests.add('${r.method} /${r.url.path}');
          final Future<void> Function()? hook = beforeSrsPut;
          if (hook != null &&
              r.method == 'PUT' &&
              r.url.path == 'api/admin/srs') {
            beforeSrsPut = null;
            await hook();
          }
          return api.handle(r);
        },
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

  /// 管理员直接改（WebUI / ctl 那条路，不经操作目录）。
  Future<void> adminPut(Map<String, Object?> body) async {
    final shelf.Response r = await api.handle(
      shelf.Request(
        'PUT',
        Uri.parse('http://localhost/api/admin/srs'),
        body: jsonEncode(body),
      ),
    );
    expect(r.statusCode, 200, reason: await r.readAsString());
  }

  Map<String, Object?> asMap(Object? v) => Map<String, Object?>.from(v! as Map);

  Future<Object?> run(
    String id,
    Map<String, Object?> args, {
    Set<String> gates = const <String>{},
  }) async => (await invoker.invoke(
    id,
    args,
    caller: OpCaller.model,
    grantedGates: gates,
  )).result;

  Future<OpUndoRecord> runUndoable(String id, Map<String, Object?> args) async {
    final OpInvocation inv = await invoker.invoke(
      id,
      args,
      caller: OpCaller.model,
      captureUndo: true,
    );
    return inv.undo!;
  }

  Future<OpUndoStatus> revert(String id, OpUndoRecord record) async =>
      (await invoker.catalog[id]!.undo!.revert(
        jsonDecode(jsonEncode(record.payload)) as Map<String, Object?>,
      )).status;

  test('目录：六条复习操作、风险分级；选 profile / 默认 / AnkiConnect 不进目录、不常驻', () {
    final OpCatalog catalog = invoker.catalog;
    for (final String id in kSrsOps) {
      expect(catalog[id], isNotNull, reason: id);
    }
    expect(catalog['server.srs.status']!.risk, OpRisk.read);
    expect(catalog['server.srs.profiles']!.risk, OpRisk.read);
    expect(catalog['server.srs.sync']!.risk, OpRisk.irreversible);
    for (final String id in <String>[
      'server.srs.mining-target.set',
      'server.srs.mining-deck.set',
      'server.srs.rollover-hour.set',
    ]) {
      expect(catalog[id]!.risk, OpRisk.write, reason: id);
      expect(catalog[id]!.undo, isNotNull, reason: id);
    }
    for (final FushiOp op in catalog.ops) {
      expect(op.id, isNot(contains('srs.profile.')));
      expect(op.id, isNot(contains('srs.default')));
      for (final OpParam param in op.params) {
        expect(
          const <String>[
            'profiles',
            'addProfiles',
            'removeProfiles',
            'defaultProfile',
            'ankiConnect',
            'miningDecks',
          ],
          isNot(contains(param.name)),
          reason: '${op.id}.${param.name}',
        );
      }
    }
    for (final String id in kSrsOps) {
      expect(kServerAgentResidentOps, isNot(contains(id)));
    }
  });

  test('状态：原样转发，但 AnkiConnect 只剩开没开 / 在不在监听 / 最近错误', () async {
    await adminPut(<String, Object?>{
      'addProfiles': <String>[kJa],
      'ankiConnect': <String, Object?>{
        'apiKey': 'secret-key',
        'profileKeys': <String, String>{kJa: 'ja-key'},
      },
    });
    requests.clear();
    final Map<String, Object?> st = asMap(
      await run('server.srs.status', const <String, Object?>{}),
    );
    expect(requests, <String>['GET /api/admin/srs']);
    expect(st['enabled'], isTrue);
    expect(asMap(st['config'])['profiles'], <String>[kJa]);
    expect(asMap(st['ankiConnect']).keys, <String>[
      'enabled',
      'listening',
      'lastError',
    ]);
    final String wire = jsonEncode(st);
    for (final String leak in <String>[
      'secret-key',
      'ja-key',
      'apiKeySet',
      'profileKeysSet',
      'bind',
      'corsOrigins',
      '127.0.0.1',
    ]) {
      expect(wire, isNot(contains(leak)), reason: leak);
    }

    final Map<String, Object?> found = asMap(
      await run('server.srs.profiles', const <String, Object?>{}),
    );
    expect(
      (found['profiles']! as List).map((Object? e) => (e! as Map)['uid']),
      <String>[kJa],
    );
  });

  test('立即同步：没表态 → 422 不碰 admin API；表态后转发（表态参数不过线）；没提供的 uid → 404', () async {
    await adminPut(<String, Object?>{
      'addProfiles': <String>[kJa],
    });
    requests.clear();
    await expectLater(
      run('server.srs.sync', const <String, Object?>{}),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 422),
      ),
    );
    expect(requests, isEmpty);
    final Map<String, Object?> st = asMap(
      await run(
        'server.srs.sync',
        const <String, Object?>{'profile': kJa},
        gates: const <String>{kServerOpConfirmGate},
      ),
    );
    expect(requests, <String>['POST /api/admin/srs/sync']);
    expect(asMap(st['ankiConnect']).keys, isNot(contains('port')));
    await expectLater(
      run(
        'server.srs.sync',
        const <String, Object?>{'profile': kZh},
        gates: const <String>{kServerOpConfirmGate},
      ),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
      ),
    );
  });

  test('制卡落点：改 → 撤销写回；被手改过 → superseded 保留手改', () async {
    final OpUndoRecord rec = await runUndoable(
      'server.srs.mining-target.set',
      const <String, Object?>{'miningTarget': 'review'},
    );
    expect(host.config.srs.miningTarget.wire, 'review');
    expect(rec.before, 'auto');
    expect(
      await revert('server.srs.mining-target.set', rec),
      OpUndoStatus.done,
    );
    expect(host.config.srs.miningTarget.wire, 'auto');

    final OpUndoRecord second = await runUndoable(
      'server.srs.mining-target.set',
      const <String, Object?>{'miningTarget': 'anki'},
    );
    await adminPut(<String, Object?>{'miningTarget': 'review'});
    expect(
      await revert('server.srs.mining-target.set', second),
      OpUndoStatus.superseded,
    );
    expect(host.config.srs.miningTarget.wire, 'review');

    await expectLater(
      run('server.srs.mining-target.set', const <String, Object?>{
        'miningTarget': 'nowhere',
      }),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
      ),
    );
  });

  test('制卡牌组：只改那一份，别的 profile 的牌组原样保留；撤销 / superseded / 空 = 默认', () async {
    await adminPut(<String, Object?>{
      'addProfiles': <String>[kJa, kZh],
      'miningDecks': <String, String>{kZh: 'Chinese::Mining'},
    });

    final OpUndoRecord rec = await runUndoable(
      'server.srs.mining-deck.set',
      const <String, Object?>{'profile': kJa, 'deck': ' Japanese::Mining '},
    );
    expect(host.config.srs.miningDecks, <String, String>{
      kZh: 'Chinese::Mining',
      kJa: 'Japanese::Mining',
    });
    expect(rec.before, '');
    expect(rec.after, 'Japanese::Mining');

    // 撤销之前管理员改了另一份的牌组：这一份没被动过，照样撤，另一份的手改保留。
    await adminPut(<String, Object?>{
      'miningDecks': <String, String>{
        kZh: 'Chinese::New',
        kJa: 'Japanese::Mining',
      },
    });
    expect(await revert('server.srs.mining-deck.set', rec), OpUndoStatus.done);
    expect(host.config.srs.miningDecks, <String, String>{kZh: 'Chinese::New'});

    // 空串 = 回到默认牌组（删掉这一项）；撤销放回原名。
    final OpUndoRecord clear = await runUndoable(
      'server.srs.mining-deck.set',
      const <String, Object?>{'profile': kZh, 'deck': ''},
    );
    expect(host.config.srs.miningDecks, isEmpty);
    expect(
      await revert('server.srs.mining-deck.set', clear),
      OpUndoStatus.done,
    );
    expect(host.config.srs.miningDecks, <String, String>{kZh: 'Chinese::New'});

    // 执行后这一份又被手改：superseded，不覆盖。
    final OpUndoRecord third = await runUndoable(
      'server.srs.mining-deck.set',
      const <String, Object?>{'profile': kZh, 'deck': 'AI::Deck'},
    );
    await adminPut(<String, Object?>{
      'miningDecks': <String, String>{kZh: 'Hand::Edit'},
    });
    expect(
      await revert('server.srs.mining-deck.set', third),
      OpUndoStatus.superseded,
    );
    expect(host.config.srs.miningDecks, <String, String>{kZh: 'Hand::Edit'});

    // 没提供的 profile：404，配置不动。
    requests.clear();
    await expectLater(
      run('server.srs.mining-deck.set', const <String, Object?>{
        'profile': '01928c3e-0000-7000-8000-00000000dead',
        'deck': 'X',
      }),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 404),
      ),
    );
    expect(requests, <String>['GET /api/admin/srs']);
    expect(host.config.srs.miningDecks, <String, String>{kZh: 'Hand::Edit'});
  });

  test('制卡牌组：操作读完配置、写之前别人改了另一份的牌组 → 那份改动不丢（一次 patch，不读改写）', () async {
    await adminPut(<String, Object?>{
      'addProfiles': <String>[kJa, kZh],
      'miningDecks': <String, String>{kZh: 'Chinese::Old'},
    });
    beforeSrsPut = () => adminPut(<String, Object?>{
      'miningDecks': <String, String>{kZh: 'Chinese::Concurrent'},
    });
    requests.clear();
    final OpUndoRecord rec = await runUndoable(
      'server.srs.mining-deck.set',
      const <String, Object?>{'profile': kJa, 'deck': 'Japanese::Mining'},
    );
    expect(beforeSrsPut, isNull, reason: '并发改动确实插在操作的写之前');
    expect(host.config.srs.miningDecks, <String, String>{
      kZh: 'Chinese::Concurrent',
      kJa: 'Japanese::Mining',
    });
    expect(
      requests.where((String r) => r == 'PUT /api/admin/srs'),
      hasLength(1),
    );

    // 撤销同样只动这一份：撤销写之前别人又改了另一份，也不丢。
    beforeSrsPut = () => adminPut(<String, Object?>{
      'miningDecks': <String, String>{
        kZh: 'Chinese::Later',
        kJa: 'Japanese::Mining',
      },
    });
    expect(await revert('server.srs.mining-deck.set', rec), OpUndoStatus.done);
    expect(beforeSrsPut, isNull);
    expect(host.config.srs.miningDecks, <String, String>{
      kZh: 'Chinese::Later',
    });
  });

  test('翻日时刻兜底：改 → 撤销写回；超范围 → 400；被手改过 → superseded', () async {
    final OpUndoRecord rec = await runUndoable(
      'server.srs.rollover-hour.set',
      const <String, Object?>{'rolloverHour': 6},
    );
    expect(host.config.srs.rolloverHour, 6);
    expect(
      await revert('server.srs.rollover-hour.set', rec),
      OpUndoStatus.done,
    );
    expect(host.config.srs.rolloverHour, 4);

    await expectLater(
      run('server.srs.rollover-hour.set', const <String, Object?>{
        'rolloverHour': 30,
      }),
      throwsA(
        isA<CtlFailure>().having((CtlFailure f) => f.status, 'status', 400),
      ),
    );

    final OpUndoRecord second = await runUndoable(
      'server.srs.rollover-hour.set',
      const <String, Object?>{'rolloverHour': 2},
    );
    await adminPut(<String, Object?>{'rolloverHour': 5});
    expect(
      await revert('server.srs.rollover-hour.set', second),
      OpUndoStatus.superseded,
    );
    expect(host.config.srs.rolloverHour, 5);
  });

  test('ServerAgentToolbox：能搜到；写操作记进服务端库、撤销写回；同步没确认拒绝', () async {
    await adminPut(<String, Object?>{
      'addProfiles': <String>[kJa],
    });
    final ServerAgentToolbox toolbox = ServerAgentToolbox(
      invoker: invoker,
      db: db,
    );
    expect(
      toolbox.searchTools('srs').map((AgentToolSpec t) => t.name),
      containsAll(kSrsOps),
    );
    expect(
      toolbox
          .searchTools('review mining deck')
          .map((AgentToolSpec t) => t.name),
      contains('server.srs.mining-deck.set'),
    );
    final AgentToolSpec sync = toolbox.describeTool('server.srs.sync')!;
    expect(sync.confirm || sync.risk == AgentToolRisk.irreversible, isTrue);
    expect(jsonEncode(sync.parameters), isNot(contains(kServerOpConfirmGate)));

    final AgentToolResult set = await toolbox.execute(
      const AgentToolInvocation(
        sessionId: 'rm1',
        name: 'server.srs.mining-deck.set',
        arguments: <String, Object?>{'profile': kJa, 'deck': 'JP'},
      ),
    );
    expect(set.isError, isFalse);
    expect(host.config.srs.miningDecks, <String, String>{kJa: 'JP'});
    expect(
      (await db.listAiAgentActions()).single.opId,
      'server.srs.mining-deck.set',
    );
    expect((await toolbox.undo(set.actionId!)).status, AgentUndoStatus.done);
    expect(host.config.srs.miningDecks, isEmpty);

    final AgentToolResult refused = await toolbox.execute(
      const AgentToolInvocation(
        sessionId: 'rm1',
        name: 'server.srs.sync',
        arguments: <String, Object?>{},
      ),
    );
    expect(refused.errorCode, 'confirmation_required');
  });
}
