/// `sync pull` / `sync peers|forget` 的契约：目标解析（指纹钉扎 / 明文门 / 凭据来源）、
/// 只拉与双向两种模式真写穿本机 DB、HTTP 传输的鉴权与状态码映射、退出码。
///
/// 不连真网络：传输用内存假实现，HTTP 层用本机回环上的假 host。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:drift/drift.dart' show Value;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/aggregate_snapshot.dart';
import 'package:fushi_engine/sync/aggregate_sync_service.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/sync_commands.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const String _fp = 'aa:bb:cc:dd';

class _MemoryRemote implements AggregateRemote {
  _MemoryRemote(this.snapshot);

  Object? snapshot;
  final List<Object> pushed = <Object>[];
  bool closed = false;

  @override
  Future<Object?> fetch() async => snapshot;

  @override
  Future<void> push(Object json) async => pushed.add(json);

  @override
  void close() => closed = true;
}

StudySegmentsCompanion _segment(String uid, int minutes) {
  final DateTime start = DateTime(2026, 10, 3, 9);
  final DateTime end = start.add(Duration(minutes: minutes));
  return StudySegmentsCompanion.insert(
    uid: uid,
    deviceId: 'host-device',
    mediaKind: kActivityMediaBook,
    mediaKey: 'book-$uid',
    title: 'Book $uid',
    startAt: start.millisecondsSinceEpoch,
    endAt: end.millisecondsSinceEpoch,
    dateKey: FushiDatabase.statDateKeyOf(start),
    hour: start.hour,
    durationMs: Value<int>(minutes * 60000),
    chars: const Value<int>(500),
    updatedAt: end.millisecondsSinceEpoch,
  );
}

void main() {
  late Directory tmp;
  late File configFile;
  late ServerPaths paths;
  late StringBuffer out;
  late StringBuffer err;
  late _MemoryRemote remote;
  late Map<String, Object?> hostSnapshot;

  setUpAll(() async {
    // host 端的快照用真实 DB 物化，形状与线上 /api/library/aggregate 一致。
    final Directory hostDir = await Directory.systemTemp.createTemp('fushi_sync_host_');
    final FushiDatabase hostDb = FushiDatabase(hostDir.path);
    await hostDb.upsertStudySegment(_segment('h1', 30));
    await hostDb.upsertStudySegment(_segment('h2', 15));
    hostSnapshot = (await AggregateSyncService(hostDb).materializeLocalSnapshot()).toJson();
    await hostDb.close();
    await hostDir.delete(recursive: true);
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_sync_cli_');
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final String dataDir = p.join(tmp.path, 'data');
    await ServerConfig.defaults(dataDir: dataDir).save(configFile);
    paths = ServerPaths(dataDir);
    await paths.ensureLayout();
    final FushiDatabase db = FushiDatabase(paths.support.path);
    await db.upsertStudySegment(_segment('local1', 5));
    await db.close();
    out = StringBuffer();
    err = StringBuffer();
    remote = _MemoryRemote(jsonDecode(jsonEncode(hostSnapshot)));
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<int> sync(List<String> args, {Map<String, String> env = const <String, String>{}}) {
    final SyncModule module = SyncModule(out: out, err: err, env: env, remoteFactory: (SyncTarget _) => remote);
    final ArgParser parser = ArgParser();
    module.register(parser);
    return module.run(
      'sync',
      parser.parse(<String>['sync', ...args]).command!,
      CliContext(configFile: configFile, verbose: false),
    );
  }

  Future<Set<String>> localSegmentUids() async {
    final FushiDatabase db = FushiDatabase(paths.support.path);
    try {
      return (await db.select(db.studySegments).get()).map((StudySegmentRow r) => r.uid).toSet();
    } finally {
      await db.close();
    }
  }

  group('sync pull', () {
    test('只拉：host 的段折进本机，不写 host；--json 形状', () async {
      final int code = await sync(
        <String>['pull', 'http://127.0.0.1:38765', '--allow-http', '--json'],
        env: <String, String>{kSyncTokenEnv: 'tok'},
      );
      expect(code, 0, reason: err.toString());
      expect(await localSegmentUids(), <String>{'local1', 'h1', 'h2'});
      expect(remote.pushed, isEmpty);
      expect(remote.closed, isTrue);
      final Map<String, Object?> r = jsonDecode(out.toString()) as Map<String, Object?>;
      expect(r['host'], 'http://127.0.0.1:38765');
      expect(r['mode'], 'pull');
      expect(r['pushed'], false);
      expect((r['pulled']! as Map<String, Object?>)['studySegments'], 2);
    });

    test('--push：合并结果推回 host（含本机段）', () async {
      expect(
        await sync(
          <String>['pull', 'http://127.0.0.1:38765', '--allow-http', '--push'],
          env: <String, String>{kSyncTokenEnv: 'tok'},
        ),
        0,
        reason: err.toString(),
      );
      expect(await localSegmentUids(), <String>{'local1', 'h1', 'h2'});
      expect(remote.pushed, hasLength(1));
      final AggregateSnapshot pushed = AggregateSnapshot.fromJson(remote.pushed.single);
      expect(pushed.studySegments.map((StudySegmentRecord s) => s.uid).toSet(), <String>{'local1', 'h1', 'h2'});
    });

    test('--no-stats：统计不折进来', () async {
      expect(
        await sync(
          <String>['pull', 'http://127.0.0.1:38765', '--allow-http', '--no-stats'],
          env: <String, String>{kSyncTokenEnv: 'tok'},
        ),
        0,
        reason: err.toString(),
      );
      expect(await localSegmentUids(), <String>{'local1'});
    });

    test('老 host 无端点：只拉 = 69', () async {
      remote.snapshot = null;
      expect(
        await sync(
          <String>['pull', 'http://127.0.0.1:38765', '--allow-http'],
          env: <String, String>{kSyncTokenEnv: 'tok'},
        ),
        69,
      );
    });

    test('已配对记录提供 token 与指纹', () async {
      await SyncPeerCredentialStore.under(
        paths.support,
      ).upsert(const SyncPeerCredential(url: 'https://10.0.0.2:38765', token: 'saved', fingerprint: _fp));
      expect(await sync(<String>['pull', 'https://10.0.0.2:38765/']), 0, reason: err.toString());
    });

    test('用法错误 = 64', () async {
      expect(await sync(<String>['pull']), 64);
      expect(await sync(<String>['pull', 'ftp://x']), 64);
      expect(await sync(<String>['pull', 'http://x', '--allow-http', '--no-stats', '--no-favorites']), 64);
      expect(await sync(<String>[]), 64);
    });
  });

  group('resolveSyncTarget', () {
    late SyncPeerCredentialStore store;
    setUp(() => store = SyncPeerCredentialStore.under(paths.support));

    Future<(SyncTarget?, int, String)> resolve(String url, {String? fp, bool allowHttp = false, String? token}) =>
        resolveSyncTarget(rawUrl: url, fingerprintArg: fp, allowHttp: allowHttp, envToken: token, store: store);

    test('https 没有指纹 = 64（不做盲 TOFU）', () async {
      expect((await resolve('https://h:1', token: 't')).$2, 64);
    });

    test('http 不显式允许 = 64；http 带指纹 = 64', () async {
      expect((await resolve('http://h:1', token: 't')).$2, 64);
      expect((await resolve('http://h:1', allowHttp: true, fp: _fp, token: 't')).$2, 64);
    });

    test('没有凭据 = 69', () async {
      expect((await resolve('https://h:1', fp: _fp)).$2, 69);
    });

    test('命令行指纹与已配对指纹不符 = 1', () async {
      await store.upsert(const SyncPeerCredential(url: 'https://h:1', token: 's', fingerprint: _fp));
      expect((await resolve('https://h:1', fp: '11:22')).$2, 1);
      // 写法不同（大小写 / 去冒号）但同一张证书：放行。
      final (SyncTarget? t, int code, _) = await resolve('https://h:1', fp: 'AABBCCDD');
      expect(code, 0);
      expect(t!.token, 's');
    });

    test('环境变量 token 优先于已配对记录', () async {
      await store.upsert(const SyncPeerCredential(url: 'https://h:1', token: 's', fingerprint: _fp));
      expect((await resolve('https://h:1', token: 'env')).$1!.token, 'env');
    });
  });

  group('凭据存储', () {
    test('落盘 0600，forget 删除，peers 不输出 token', () async {
      final SyncPeerCredentialStore store = SyncPeerCredentialStore.under(paths.support);
      await store.upsert(const SyncPeerCredential(url: 'https://h:1', token: 'secret', fingerprint: _fp));
      if (!Platform.isWindows) {
        expect((await store.file.stat()).modeString(), 'rw-------');
      }
      expect(await sync(<String>['peers', '--json']), 0);
      expect(out.toString(), isNot(contains('secret')));
      expect(out.toString(), contains('https://h:1'));
      expect(await sync(<String>['forget', 'https://h:1']), 0);
      expect(await store.load(), isEmpty);
      expect(await sync(<String>['forget', 'https://h:1']), 1);
    });
  });

  group('HttpAggregateRemote', () {
    late HttpServer server;
    late int status;
    final List<String?> auths = <String?>[];
    final List<String> methods = <String>[];

    setUp(() async {
      status = 200;
      auths.clear();
      methods.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        auths.add(req.headers.value(HttpHeaders.authorizationHeader));
        methods.add('${req.method} ${req.uri.path}');
        await req.drain<void>();
        req.response.statusCode = status;
        if (status == 200) req.response.write(jsonEncode(<String, Object?>{'version': 1}));
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    HttpAggregateRemote client() =>
        HttpAggregateRemote(baseUrl: Uri.parse('http://127.0.0.1:${server.port}'), token: 'tk');

    test('Basic hibiki:<token>，GET / PUT 同一端点', () async {
      final HttpAggregateRemote c = client();
      expect(await c.fetch(), <String, Object?>{'version': 1});
      await c.push(<String, Object?>{'version': 1});
      c.close();
      expect(auths.toSet(), <String>{'Basic ${base64Encode(utf8.encode('hibiki:tk'))}'});
      expect(methods, <String>['GET /api/library/aggregate', 'PUT /api/library/aggregate']);
    });

    test('404 = 老 host（null）；401 = 69；500 = 1', () async {
      final HttpAggregateRemote c = client();
      status = 404;
      expect(await c.fetch(), isNull);
      status = 401;
      await expectLater(
        c.fetch(),
        throwsA(isA<SyncRemoteException>().having((SyncRemoteException e) => e.exitCode, 'exitCode', 69)),
      );
      status = 500;
      await expectLater(
        c.fetch(),
        throwsA(isA<SyncRemoteException>().having((SyncRemoteException e) => e.exitCode, 'exitCode', 1)),
      );
      c.close();
    });

    test('连不上 = 69', () async {
      final int port = server.port;
      await server.close(force: true);
      final HttpAggregateRemote c = HttpAggregateRemote(baseUrl: Uri.parse('http://127.0.0.1:$port'), token: 'tk');
      await expectLater(
        c.fetch(),
        throwsA(isA<SyncRemoteException>().having((SyncRemoteException e) => e.exitCode, 'exitCode', 69)),
      );
      c.close();
    });
  });

  test('配对失败原因映射', () {
    expect(describePairFailure('declined').$1, 1);
    expect(describePairFailure('tls').$1, 69);
    expect(describePairFailure('unavailable').$1, 69);
  });
}
