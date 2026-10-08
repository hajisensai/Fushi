/// `tracking sync|status` 契约：下线闸关着时在任何请求前判 69（生产现状）；闸打开时
/// 环境变量令牌经 `connect` 校验落盘、空 outbox 一轮同步成功、令牌被拒 69、退出码映射。
/// Bangumi 客户端用假实现，不连网。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/tracking/bangumi_api_client.dart';
import 'package:fushi_engine/media/tracking/media_tracking_service.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/tracking_commands.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _FakeBangumi implements BangumiTrackingApi {
  _FakeBangumi(this.token, this.calls);

  final String token;
  final List<String> calls;

  @override
  Future<BangumiUser> getMe() async {
    calls.add('getMe:$token');
    if (token != 'good') throw const BangumiApiException(statusCode: 401, message: 'bad token');
    return const BangumiUser(username: 'neko', nickname: '猫');
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late Directory tmp;
  late File configFile;
  late ServerPaths paths;
  late StringBuffer out;
  late StringBuffer err;
  late List<String> calls;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_tracking_cli_');
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    final String dataDir = p.join(tmp.path, 'data');
    await ServerConfig.defaults(dataDir: dataDir).save(configFile);
    paths = ServerPaths(dataDir);
    out = StringBuffer();
    err = StringBuffer();
    calls = <String>[];
  });

  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  Future<int> tracking(List<String> args, {bool enabled = true, Map<String, String> env = const <String, String>{}}) {
    final TrackingModule module = TrackingModule(
      out: out,
      err: err,
      env: env,
      enabled: enabled,
      apiFactory: (String token) => _FakeBangumi(token, calls),
    );
    final ArgParser parser = ArgParser();
    module.register(parser);
    return module.run(
      'tracking',
      parser.parse(<String>['tracking', ...args]).command!,
      CliContext(configFile: configFile, verbose: false),
    );
  }

  test('生产现状：下线闸关着 = 69，且不打开数据目录、不发请求', () async {
    expect(kMediaTrackingEnabled, isFalse, reason: '闸打开后这条测试与模块文档都要改');
    expect(const TrackingModule().enabled, kMediaTrackingEnabled);
    expect(await tracking(<String>['sync'], enabled: false, env: <String, String>{kBangumiTokenEnv: 'good'}), 69);
    expect(err.toString(), contains('kMediaTrackingEnabled'));
    expect(calls, isEmpty);
    expect(Directory(paths.dataDir).existsSync(), isFalse);
  });

  test('环境变量令牌：connect 校验后落盘，空 outbox 同步成功', () async {
    expect(
      await tracking(<String>['sync', '--json'], env: <String, String>{kBangumiTokenEnv: 'good'}),
      0,
      reason: err.toString(),
    );
    expect(calls, <String>['getMe:good']);
    expect(jsonDecode(out.toString()), <String, Object?>{
      'succeeded': 0,
      'failed': 0,
      'pending': 0,
      'unauthorized': false,
    });
    final FushiDatabase db = FushiDatabase(paths.support.path);
    expect(PrefCodec.decodeUntyped((await db.getPref(kBangumiAccessTokenPref))!), 'good');
    expect(PrefCodec.decodeUntyped((await db.getPref(kBangumiAccountNamePref))!), '猫');
    await db.close();

    out.clear();
    expect(await tracking(<String>['status', '--json']), 0);
    final Map<String, Object?> status = jsonDecode(out.toString()) as Map<String, Object?>;
    expect(status['configured'], true);
    expect(status['account'], '猫');
    expect(status['pending'], 0);
  });

  test('令牌被拒 = 69，不落盘', () async {
    expect(await tracking(<String>['sync'], env: <String, String>{kBangumiTokenEnv: 'bad'}), 69);
    final FushiDatabase db = FushiDatabase(paths.support.path);
    expect(await db.getPref(kBangumiAccessTokenPref), isNull);
    await db.close();
  });

  test('没有令牌 = 69', () async {
    expect(await tracking(<String>['sync']), 69);
    expect(err.toString(), contains(kBangumiTokenEnv));
  });

  test('退出码映射', () {
    expect(trackingSyncExitCode(const MediaTrackingSyncResult(succeeded: 2, failed: 0, pending: 0)), 0);
    expect(trackingSyncExitCode(const MediaTrackingSyncResult(succeeded: 1, failed: 1, pending: 1)), 1);
    expect(
      trackingSyncExitCode(const MediaTrackingSyncResult(succeeded: 0, failed: 1, pending: 1, unauthorized: true)),
      69,
    );
  });

  test('用法错误 = 64', () async {
    expect(await tracking(<String>[]), 64);
    expect(await tracking(<String>[], enabled: false), 64);
  });
}
