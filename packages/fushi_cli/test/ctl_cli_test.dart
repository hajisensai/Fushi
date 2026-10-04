import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'ctl_server_test.dart' show FakeHandler;

void main() {
  late Directory root;
  late String stateDir;
  late StringBuffer out;
  late StringBuffer err;
  final List<CtlServer> servers = <CtlServer>[];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fushi_ctl_cli_');
    stateDir = p.join(root.path, 'ctl');
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() async {
    for (final CtlServer server in servers) {
      await server.stop();
    }
    servers.clear();
    await root.delete(recursive: true);
  });

  Future<int> run(
    List<String> args, {
    CtlProcessStarter? starter,
    Map<String, String> extraEnv = const <String, String>{},
  }) => runFushiCli(
    args,
    environment: <String, String>{kCtlDirEnv: stateDir, ...extraEnv},
    operatingSystem: 'linux',
    cliExecutable: p.join(root.path, 'bin', 'fushi_cli'),
    out: out,
    err: err,
    starter:
        starter ??
        (String exe, List<String> args) async => fail('不应拉起 app：$exe'),
    pollInterval: const Duration(milliseconds: 20),
  );

  Future<FakeHandler> startApp({bool initialised = true}) async {
    final FakeHandler handler = FakeHandler()..initialised = initialised;
    final CtlServer server = CtlServer(handler: handler, stateDir: stateDir);
    servers.add(server);
    await server.start();
    return handler;
  }

  Future<String> fakeAppBinary() async {
    final File app = File(p.join(root.path, 'bin', 'fushi'));
    await app.create(recursive: true);
    return app.path;
  }

  test('status：没在运行 → 69，且不拉起 app', () async {
    expect(await run(<String>['status', '--json']), kCliExitUnavailable);
    expect(jsonDecode(out.toString().trim()), <String, Object?>{
      'running': false,
    });
  });

  test('status：在运行 → JSON 带 pid 与就绪状态', () async {
    await startApp();
    expect(await run(<String>['--json', 'status']), kCliExitOk);
    final Map<String, Object?> json =
        jsonDecode(out.toString().trim()) as Map<String, Object?>;
    expect(json['running'], isTrue);
    expect(json['pid'], 4242);
    expect(json['initialised'], isTrue);
  });

  test('残留的发现文件（端口没人听）按未运行处理', () async {
    await writeCtlEndpoint(
      stateDir,
      CtlEndpoint(port: await _closedPort(), token: 't', pid: 1, startedAt: 0),
    );
    expect(await run(<String>['status']), kCliExitUnavailable);
  });

  test('open：相对路径在 CLI 侧转成绝对路径', () async {
    final FakeHandler handler = await startApp();
    expect(await run(<String>['open', 'clips/a.mkv']), kCliExitOk);
    expect(handler.opened.single, p.normalize(p.absolute('clips/a.mkv')));
  });

  test('open：URL 原样转交', () async {
    final FakeHandler handler = await startApp();
    await run(<String>['open', 'fushi://lookup?word=x']);
    expect(handler.opened.single, 'fushi://lookup?word=x');
  });

  test('open：app 拒绝 → 退出码 1 并说明原因', () async {
    await startApp();
    expect(await run(<String>['open', '/x/a.txt']), kCliExitFailed);
    expect(err.toString(), contains('unsupported'));
  });

  test('lookup：多个参数拼成一个词', () async {
    final FakeHandler handler = await startApp();
    expect(await run(<String>['lookup', 'hello', 'world']), kCliExitOk);
    expect(handler.lookups, <String>['hello world']);
  });

  test('app 没在运行 → 自动拉起并等初始化完成再执行', () async {
    final String app = await fakeAppBinary();
    final List<String> launched = <String>[];
    FakeHandler? handler;
    final int code = await run(
      <String>['lookup', '猫'],
      starter: (String exe, List<String> args) async {
        launched.add(exe);
        // 模拟真实 app：先开控制通道（初始化中），过一会儿才就绪。
        unawaited(() async {
          await Future<void>.delayed(const Duration(milliseconds: 60));
          handler = await startApp(initialised: false);
          await Future<void>.delayed(const Duration(milliseconds: 100));
          handler!.initialised = true;
        }());
      },
    );
    expect(code, kCliExitOk, reason: err.toString());
    expect(launched, <String>[app]);
    expect(handler!.lookups, <String>['猫']);
  });

  test('--no-launch：没在运行就失败，不拉起', () async {
    await fakeAppBinary();
    expect(
      await run(<String>['--no-launch', 'lookup', '猫']),
      kCliExitUnavailable,
    );
  });

  test('找不到 app → 69', () async {
    expect(await run(<String>['lookup', '猫']), kCliExitUnavailable);
    expect(err.toString(), contains(kFushiAppEnv));
  });

  test('拉起后一直等不到控制通道 → 超时 75', () async {
    await fakeAppBinary();
    final int code = await run(<String>[
      '--timeout',
      '1',
      'start',
    ], starter: (String exe, List<String> args) async {});
    expect(code, kCliExitTempFail);
    expect(err.toString(), contains('超时'));
  });

  test('quit：没在运行也算成功', () async {
    expect(await run(<String>['quit']), kCliExitOk);
  });

  test('quit：转交给 app', () async {
    final FakeHandler handler = await startApp();
    expect(await run(<String>['quit']), kCliExitOk);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(handler.quits, 1);
  });

  test('没有命令 → 用法错误', () async {
    expect(await run(const <String>[]), kCliExitUsage);
  });
}

/// 拿一个此刻没人监听的端口。
Future<int> _closedPort() async {
  final ServerSocket socket = await ServerSocket.bind(
    InternetAddress.loopbackIPv4,
    0,
  );
  final int port = socket.port;
  await socket.close();
  return port;
}
