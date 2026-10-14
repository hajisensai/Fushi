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
