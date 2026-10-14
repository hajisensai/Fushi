import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/local/gpt_sovits_local_server.dart';
import 'package:test/test.dart';

class _FakeProcess implements Process {
  final StreamController<List<int>> out = StreamController<List<int>>();
  final StreamController<List<int>> err = StreamController<List<int>>();
  final Completer<int> exit = Completer<int>();
  int kills = 0;

  @override
  Stream<List<int>> get stdout => out.stream;
  @override
  Stream<List<int>> get stderr => err.stream;
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  int get pid => 4242;
  @override
  Future<int> get exitCode => exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (!exit.isCompleted) exit.complete(-15);
    return true;
  }
}

void main() {
  late Directory dir;
  late GptSovitsLaunchSpec spec;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('gsv_server_');
    final File python = File('${dir.path}/python.exe')..writeAsStringSync('');
    spec = GptSovitsLaunchSpec(
      executable: python.path,
      arguments: const <String>['api_v2.py'],
      workingDirectory: dir.path,
      port: 19880,
    );
  });

  tearDown(() => dir.deleteSync(recursive: true));

  test('起进程后探活成功即 running，环境强制 UTF-8 不缓冲', () async {
    final _FakeProcess process = _FakeProcess();
    Map<String, String>? env;
    int probes = 0;
    final GptSovitsLocalServer server = GptSovitsLocalServer(
      spawn:
          (
            String exe,
            List<String> args, {
            workingDirectory,
            environment,
          }) async {
            env = environment;
            return process;
          },
      // 第一次探活（启动前看端口是否已被占）为否，第三次起就绪。
      probe: (int port) async => ++probes >= 3,
      probeInterval: Duration.zero,
    );
    process.out.add(utf8.encode('loading 底模\n'));
    expect(await server.start(spec), isTrue);
    expect(server.phase, GptSovitsServerPhase.running);
    expect(server.endpoint, 'http://127.0.0.1:19880');
    expect(env!['PYTHONIOENCODING'], 'utf-8');
    expect(env!['PYTHONUNBUFFERED'], '1');
    expect(server.logTail, contains('loading 底模'));

    await server.stop();
    expect(process.kills, 1);
    expect(server.phase, GptSovitsServerPhase.stopped);
    expect(server.endpoint, isNull);
  });

  test('并发 start 只起一个进程', () async {
    int spawns = 0;
    final GptSovitsLocalServer server = GptSovitsLocalServer(
      spawn:
          (
            String exe,
            List<String> args, {
            workingDirectory,
            environment,
          }) async {
            spawns++;
            return _FakeProcess();
          },
      probe: _probeAfter(2),
      probeInterval: Duration.zero,
    );
    final List<bool> results = await Future.wait(<Future<bool>>[
      server.start(spec),
      server.start(spec),
    ]);
    expect(results, <bool>[true, true]);
    expect(spawns, 1);
    expect(await server.start(spec), isTrue);
    expect(spawns, 1);
  });

  test('端口上已有服务：借用，不再起第二个进程', () async {
    int spawns = 0;
    final GptSovitsLocalServer server = GptSovitsLocalServer(
      spawn:
          (
            String exe,
            List<String> args, {
            workingDirectory,
            environment,
          }) async {
            spawns++;
            return _FakeProcess();
          },
      probe: (int port) async => true,
    );
    expect(await server.start(spec), isTrue);
    expect(spawns, 0);
    expect(server.isExternal, isTrue);
    expect(server.endpoint, 'http://127.0.0.1:19880');
  });

  test('进程在就绪前退出 → failed/exited，日志尾保留输出', () async {
    final _FakeProcess process = _FakeProcess();
    final GptSovitsLocalServer server = GptSovitsLocalServer(
      spawn:
          (
            String exe,
            List<String> args, {
            workingDirectory,
            environment,
          }) async => process,
      probe: (int port) async => false,
      probeInterval: const Duration(milliseconds: 5),
    );
    final Future<bool> started = server.start(spec);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    process.err.add(utf8.encode('CUDA error: no kernel image\n'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    process.exit.complete(1);
    expect(await started, isFalse);
    expect(server.phase, GptSovitsServerPhase.failed);
    expect(server.failure, GptSovitsServerFailure.exited);
    expect(server.logTail, contains('CUDA error: no kernel image'));
  });

  test('超时 → 杀进程并报 timeout', () async {
    final _FakeProcess process = _FakeProcess();
    final GptSovitsLocalServer server = GptSovitsLocalServer(
      spawn:
          (
            String exe,
            List<String> args, {
            workingDirectory,
            environment,
          }) async => process,
      probe: (int port) async => false,
      readyTimeout: const Duration(milliseconds: 30),
      probeInterval: const Duration(milliseconds: 5),
    );
    expect(await server.start(spec), isFalse);
    expect(server.failure, GptSovitsServerFailure.timeout);
    expect(process.kills, 1);
  });

  test('启动前探活期间 stop：不再 spawn，也不会被置 running', () async {
    int spawns = 0;
    final Completer<bool> firstProbe = Completer<bool>();
    final GptSovitsLocalServer server = GptSovitsLocalServer(
      spawn:
          (
            String exe,
            List<String> args, {
            workingDirectory,
            environment,
          }) async {
            spawns++;
            return _FakeProcess();
          },
      probe: (int port) => firstProbe.future,
      probeInterval: Duration.zero,
    );
    final Future<bool> started = server.start(spec);
    await Future<void>.delayed(Duration.zero);
    expect(server.phase, GptSovitsServerPhase.starting);
    await server.stop();
    firstProbe.complete(false);
    expect(await started, isFalse);
    expect(spawns, 0);
    expect(server.phase, GptSovitsServerPhase.stopped);
    expect(server.endpoint, isNull);
  });

  test('spawn 期间 stop：刚起的进程立即被杀，不留孤儿', () async {
    final _FakeProcess process = _FakeProcess();
    final Completer<Process> spawnGate = Completer<Process>();
    final GptSovitsLocalServer server = GptSovitsLocalServer(
      spawn: (String exe, List<String> args, {workingDirectory, environment}) =>
          spawnGate.future,
      probe: (int port) async => false,
      probeInterval: Duration.zero,
    );
    final Future<bool> started = server.start(spec);
    await Future<void>.delayed(Duration.zero);
    await server.stop();
    spawnGate.complete(process);
    expect(await started, isFalse);
    expect(process.kills, 1);
    expect(server.phase, GptSovitsServerPhase.stopped);
    // 被取消的进程不登记 pid（下次启动不会把它当成可认领的自家服务）。
    expect(File('${dir.path}/$kGptSovitsPidFileName').existsSync(), isFalse);
  });

  test('上次崩溃留下的自家服务（pid 文件 + 映像匹配）：认领，可以停止', () async {
    File('${dir.path}/$kGptSovitsPidFileName').writeAsStringSync(
      jsonEncode(<String, Object?>{'pid': 777, 'port': 19880}),
    );
    final List<int> killed = <int>[];
    final GptSovitsLocalServer server = GptSovitsLocalServer(
      spawn:
          (
            String exe,
            List<String> args, {
            workingDirectory,
            environment,
          }) async => throw StateError('must not spawn'),
      probe: (int port) async => true,
      pidOwnerCheck: (int pid, String exe) async =>
          pid == 777 && exe == spec.executable,
      pidKill: (int pid) {
        killed.add(pid);
        return true;
      },
    );
    expect(await server.start(spec), isTrue);
    expect(server.isExternal, isFalse);
    expect(server.endpoint, 'http://127.0.0.1:19880');
    await server.stop();
    expect(killed, <int>[777]);
    expect(File('${dir.path}/$kGptSovitsPidFileName').existsSync(), isFalse);
  });

  test('pid 文件在但进程不是本整合包的：仍当外部服务借用，不杀', () async {
    File('${dir.path}/$kGptSovitsPidFileName').writeAsStringSync(
      jsonEncode(<String, Object?>{'pid': 777, 'port': 19880}),
    );
    final List<int> killed = <int>[];
    final GptSovitsLocalServer server = GptSovitsLocalServer(
      probe: (int port) async => true,
      pidOwnerCheck: (int pid, String exe) async => false,
      pidKill: (int pid) {
        killed.add(pid);
        return true;
      },
    );
    expect(await server.start(spec), isTrue);
    expect(server.isExternal, isTrue);
    await server.stop();
    expect(killed, isEmpty);
  });

  test('自起进程写 pid 文件、退出后删掉', () async {
    final _FakeProcess process = _FakeProcess();
    final GptSovitsLocalServer server = GptSovitsLocalServer(
      spawn:
          (
            String exe,
            List<String> args, {
            workingDirectory,
            environment,
          }) async => process,
      probe: _probeAfter(1),
      probeInterval: Duration.zero,
    );
    expect(await server.start(spec), isTrue);
    final File pidFile = File('${dir.path}/$kGptSovitsPidFileName');
    expect(jsonDecode(pidFile.readAsStringSync()), <String, Object?>{
      'pid': 4242,
      'port': 19880,
    });
    await server.stop();
    await Future<void>.delayed(Duration.zero);
    expect(pidFile.existsSync(), isFalse);
  });

  test('探活只认 api_v2 的路由表', () {
    expect(
      gptSovitsOpenApiLooksLikeApiV2(
        jsonEncode(<String, Object?>{
          'paths': <String, Object?>{
            '/tts': <String, Object?>{},
            '/control': <String, Object?>{},
            '/set_gpt_weights': <String, Object?>{},
          },
        }),
      ),
      isTrue,
    );
    expect(
      gptSovitsOpenApiLooksLikeApiV2(
        jsonEncode(<String, Object?>{
          'paths': <String, Object?>{'/items': <String, Object?>{}},
        }),
      ),
      isFalse,
    );
    expect(gptSovitsOpenApiLooksLikeApiV2('<html>'), isFalse);
  });

  test('没装（可执行文件不存在）→ notInstalled，不起进程', () async {
    int spawns = 0;
    final GptSovitsLocalServer server = GptSovitsLocalServer(
      spawn:
          (
            String exe,
            List<String> args, {
            workingDirectory,
            environment,
          }) async {
            spawns++;
            return _FakeProcess();
          },
      probe: (int port) async => true,
    );
    final bool ok = await server.start(
      GptSovitsLaunchSpec(
        executable: '${dir.path}/missing.exe',
        arguments: const <String>[],
        workingDirectory: dir.path,
        port: 1,
      ),
    );
    expect(ok, isFalse);
    expect(server.failure, GptSovitsServerFailure.notInstalled);
    expect(spawns, 0);
  });
}

/// 第一次（启动前的占用检查）为否，之后第 [n] 次起为真。
GptSovitsProbe _probeAfter(int n) {
  int calls = 0;
  return (int port) async => ++calls > n;
}
