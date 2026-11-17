// 本机 Irodori 服务端与批处理 worker 的双向互斥（显存只够一个模型实例）：用假进程
// 跑 IrodoriLocalEngine 的真实编排，任何时刻两个模型进程不能同时活着。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/local/irodori_batch_worker.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker_script.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_local_package.dart';
import 'package:fushi_engine/tts/local/irodori_local_server.dart';
import 'package:fushi_engine/tts/local/local_service_process.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// 两种模型进程的存活计数 + 事件序列；任何重叠记进 [violations]。
class _Gpu {
  int server = 0;
  int worker = 0;
  final List<String> events = <String>[];
  final List<String> violations = <String>[];

  void up(String who) {
    if (server + worker > 0) {
      violations.add('$who spawned while server=$server worker=$worker');
    }
    who == 'server' ? server++ : worker++;
    events.add('$who+');
  }

  void down(String who) {
    who == 'server' ? server-- : worker--;
    events.add('$who-');
  }
}

/// 假模型进程。服务端：kill 即退出；worker：stdin 收 JSON Lines 请求，经 [emit] 回事件。
class _FakeProcess implements Process {
  _FakeProcess(this.gpu, this.who) {
    gpu.up(who);
    _stdinController.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          final Map<String, Object?> req =
              jsonDecode(line) as Map<String, Object?>;
          requests.add(req);
          onRequest?.call(req);
        });
  }

  final _Gpu gpu;
  final String who;
  void Function(Map<String, Object?> req)? onRequest;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final StreamController<List<int>> _out = StreamController<List<int>>();
  final StreamController<List<int>> _err = StreamController<List<int>>();
  final StreamController<List<int>> _stdinController =
      StreamController<List<int>>();
  late final IOSink _stdin = IOSink(_stdinController.sink);
  final Completer<int> _exit = Completer<int>();

  bool get alive => !_exit.isCompleted;

  void emit(String event, Map<String, Object?> fields) => _out.add(
    utf8.encode(
      '$kIrodoriBatchEventPrefix'
      '${jsonEncode(<String, Object?>{'event': event, ...fields})}\n',
    ),
  );

  void exit(int code) {
    if (_exit.isCompleted) return;
    gpu.down(who);
    _exit.complete(code);
    unawaited(_out.close());
    unawaited(_err.close());
  }

  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  IOSink get stdin => _stdin;
  @override
  int get pid => who == 'server' ? 5151 : 4242;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    exit(-9);
    return true;
  }
}

IrodoriModelRepo _repo(String name, String file) => IrodoriModelRepo(
  repo: 'test/$name',
  revision: 'r',
  files: <IrodoriPinnedFile>[
    IrodoriPinnedFile(path: file, size: 1, sha256: '0' * 64),
  ],
);

/// 与正式清单同一环境指纹，模型换成 1 字节的假文件。
final IrodoriManifest _manifest = IrodoriManifest(
  uvVersion: kIrodoriManifest.uvVersion,
  uvAssets: kIrodoriManifest.uvAssets,
  pythonVersion: kIrodoriManifest.pythonVersion,
  server: kIrodoriManifest.server,
  dependencies: kIrodoriManifest.dependencies,
  models: <IrodoriModelChoice, IrodoriModelRepo>{
    IrodoriModelChoice.small: _repo('Small', 'model.safetensors'),
    IrodoriModelChoice.large: _repo('Large', 'model.safetensors'),
  },
  codec: _repo('Codec', 'weights.pth'),
);

const IrodoriBatchJob _job = IrodoriBatchJob(
  id: 'j',
  items: <IrodoriBatchItem>[
    IrodoriBatchItem(
      id: 'a',
      text: 'こんにちは',
      refs: <String>['/r/a.wav'],
      outputPath: '/out/a.wav',
    ),
  ],
);

/// 让事件循环把排着的微任务 / 计时器跑完，直到 [done] 成立。
Future<void> _until(bool Function() done) async {
  for (int i = 0; i < 500 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  expect(done(), isTrue, reason: '等待的状态没出现');
}

void main() {
  late Directory dir;
  late _Gpu gpu;
  late IrodoriLocalEngine engine;
  late List<_FakeProcess> servers;
  late List<_FakeProcess> workers;

  /// 服务端进程 spawn 后端口是否立刻答话（false = 一直停在 starting）。
  late bool serverListensOnSpawn;

  /// worker 是否一启动就 ready（false = 停在加载中，测试手动 [_ready]）。
  late bool workerReadyOnSpawn;

  /// worker 收到合成请求后是否立刻跑完（false = 一直忙，测试手动 [_finish]）。
  late bool workerFinishesJobs;

  /// worker 收到 shutdown 后是否立刻退出（false = 卸载模型中，测试手动 exit）。
  late bool workerExitsOnShutdown;

  void ready(_FakeProcess w) => w.emit('ready', <String, Object?>{
    'protocol': kIrodoriBatchProtocol,
    'device': 'cuda',
  });

  void finish(_FakeProcess w, Map<String, Object?> req) {
    final List<Object?> items = req['items']! as List<Object?>;
    for (int i = 0; i < items.length; i++) {
      final Map<String, Object?> item = items[i]! as Map<String, Object?>;
      w.emit('line', <String, Object?>{
        'job': req['job'],
        'id': item['id'],
        'index': i,
        'total': items.length,
        'ok': true,
        'out': item['out'],
      });
    }
    w.emit('job_done', <String, Object?>{
      'job': req['job'],
      'ok': items.length,
      'failed': 0,
      'cancelled': false,
    });
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('irodori_exclusion_');
    gpu = _Gpu();
    servers = <_FakeProcess>[];
    workers = <_FakeProcess>[];
    serverListensOnSpawn = true;
    workerReadyOnSpawn = true;
    workerFinishesJobs = true;
    workerExitsOnShutdown = true;

    // 装好的假环境：状态文件 + .venv 解释器 + 三份模型。
    final IrodoriInstallLayout layout = IrodoriInstallLayout(
      p.join(dir.path, kIrodoriInstallSubdir),
    );
    File(layout.venvPython)
      ..createSync(recursive: true)
      ..writeAsStringSync('');
    layout.writeState(
      IrodoriInstallState(
        environmentRevision: _manifest.environmentRevision,
        backend: IrodoriTorchBackend.cpu,
      ),
    );
    for (final IrodoriModelRepo repo in <IrodoriModelRepo>[
      ..._manifest.models.values,
      _manifest.codec,
    ]) {
      File(layout.modelFile(repo, repo.files.single))
        ..createSync(recursive: true)
        ..writeAsBytesSync(<int>[0]);
    }
    final MemoryPrefStore prefs = MemoryPrefStore();
    await prefs.setPref(
      kIrodoriLocalPrefKey,
      jsonEncode(IrodoriLocalSettings(dir: layout.root, owned: true).toJson()),
    );

    bool listening = false;
    engine = IrodoriLocalEngine(
      prefs: prefs,
      httpClientFactory: () => HttpClient(),
      manifest: _manifest,
      supported: true,
      server: IrodoriLocalServer(
        probe: (int _) async => listening,
        pidOwnerCheck: (int pid, String exe) async => false,
        pidKill: (int pid) => false,
        readyTimeout: const Duration(seconds: 5),
        probeInterval: const Duration(milliseconds: 2),
        portReleaseTimeout: const Duration(seconds: 1),
        spawn:
            (
              String exe,
              List<String> args, {
              String? workingDirectory,
              Map<String, String>? environment,
            }) async {
              final _FakeProcess s = _FakeProcess(gpu, 'server');
              servers.add(s);
              listening = serverListensOnSpawn;
              unawaited(s.exitCode.then((_) => listening = false));
              return s;
            },
      ),
      batchWorkerFactory: (Future<IrodoriBatchLaunch?> Function() launch) =>
          IrodoriBatchWorker(
            launch: launch,
            readyTimeout: const Duration(seconds: 5),
            stopTimeout: const Duration(seconds: 2),
            spawn:
                (
                  String exe,
                  List<String> args, {
                  String? workingDirectory,
                  Map<String, String>? environment,
                }) async {
                  final _FakeProcess w = _FakeProcess(gpu, 'worker');
                  w.onRequest = (Map<String, Object?> req) {
                    switch (req['op']) {
                      case 'synthesize':
                        if (workerFinishesJobs) finish(w, req);
                      case 'shutdown':
                        if (workerExitsOnShutdown) w.exit(0);
                    }
                  };
                  workers.add(w);
                  if (workerReadyOnSpawn) scheduleMicrotask(() => ready(w));
                  return w;
                },
          ),
    );
    expect(engine.isInstalled, isTrue);
    expect(engine.batchModelReady, isTrue);
  });

  tearDown(() async {
    for (final _FakeProcess w in workers) {
      w.exit(0);
    }
    await engine.shutdown();
    engine.dispose();
    expect(gpu.violations, isEmpty);
    dir.deleteSync(recursive: true);
  });

  group('服务端让 worker', () {
    test('worker 加载中：不起服务端，也不把自动拉起锁死', () async {
      workerReadyOnSpawn = false;
      final Future<bool> loading = engine.batchWorker.start();
      await _until(() => workers.isNotEmpty);
      expect(engine.batchWorker.phase, IrodoriBatchPhase.starting);

      expect(await engine.start(), isFalse);
      await engine.ensureRunningFor(engine.endpoint);
      expect(servers, isEmpty);
      expect(engine.server.phase, LocalServicePhase.stopped);
      expect(engine.autoStartBlocked, isFalse, reason: '让路不是服务端失败');

      ready(workers.single);
      expect(await loading, isTrue);
      expect(gpu.events, <String>['worker+']);
    });

    test('worker 在跑任务：不起服务端，任务照常跑完', () async {
      workerFinishesJobs = false;
      final Future<IrodoriBatchResult> run = engine.batchWorker.run(_job);
      await _until(
        () =>
            workers.isNotEmpty &&
            workers.single.requests.any(
              (Map<String, Object?> r) => r['op'] == 'synthesize',
            ),
      );
      expect(engine.batchWorker.isBusy, isTrue);
      expect(await engine.start(), isFalse);
      expect(servers, isEmpty);

      finish(
        workers.single,
        workers.single.requests.firstWhere(
          (Map<String, Object?> r) => r['op'] == 'synthesize',
        ),
      );
      final IrodoriBatchResult r = await run;
      expect(r.failure, isNull);
      expect(r.lines['a']!.ok, isTrue);
    });

    test('任务刚排进队（还没发到进程）：worker 算忙，服务端不抢', () async {
      expect(await engine.batchWorker.start(), isTrue);
      // run() 与 start() 之间没有 await：任务还在 worker 的队列里。
      final Future<IrodoriBatchResult> run = engine.batchWorker.run(_job);
      expect(engine.batchWorker.isBusy, isTrue);
      expect(await engine.start(), isFalse);
      final IrodoriBatchResult r = await run;
      expect(r.failure, isNull, reason: '不能被当成空闲停掉、整批记 worker_exited');
      expect(r.lines['a']!.ok, isTrue);
      expect(engine.batchWorker.isBusy, isFalse);
      expect(servers, isEmpty);
    });

    test('worker 空闲：先停 worker（等进程退出）再起服务端', () async {
      expect(await engine.batchWorker.start(), isTrue);
      expect(await engine.start(), isTrue);
      expect(engine.server.isRunning, isTrue);
      expect(engine.batchWorker.phase, IrodoriBatchPhase.stopped);
      expect(
        workers.single.requests.map((Map<String, Object?> r) => r['op']),
        contains('shutdown'),
      );
      expect(gpu.events, <String>['worker+', 'worker-', 'server+']);
    });

    test('停空闲 worker 的途中来了批量任务：服务端放弃启动，worker 等旧进程退出后再起', () async {
      expect(await engine.batchWorker.start(), isTrue);
      workerExitsOnShutdown = false; // 旧进程卸载模型要一会儿
      // 服务端连 starting 都不该进：只靠 worker 侧回头取消一次启动，取决于两边
      // continuation 的先后，换个次序就会两个进程一起起来。
      final List<LocalServicePhase> serverPhases = <LocalServicePhase>[];
      engine.server.addListener(() => serverPhases.add(engine.server.phase));
      final Future<bool> serverStart = engine.start();
      await _until(
        () => workers.single.requests.any(
          (Map<String, Object?> r) => r['op'] == 'shutdown',
        ),
      );
      expect(engine.batchWorker.phase, IrodoriBatchPhase.stopped);

      workerExitsOnShutdown = true;
      final Future<IrodoriBatchResult> run = engine.batchWorker.run(_job);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(workers, hasLength(1), reason: '旧 worker 还没退出，新进程不能起');

      workers.first.exit(0);
      expect(await serverStart, isFalse);
      final IrodoriBatchResult r = await run;
      expect(r.failure, isNull);
      expect(r.lines['a']!.ok, isTrue);
      expect(servers, isEmpty);
      expect(gpu.events, <String>['worker+', 'worker-', 'worker+']);
      expect(serverPhases, isNot(contains(LocalServicePhase.starting)));
    });
  });

  group('worker 让服务端', () {
    test('服务端在跑：拉 worker 前先停掉它（等端口释放）', () async {
      expect(await engine.start(), isTrue);
      final IrodoriBatchResult r = await engine.batchWorker.run(_job);
      expect(r.failure, isNull);
      expect(r.lines['a']!.ok, isTrue);
      expect(engine.server.phase, LocalServicePhase.stopped);
      expect(servers.single.alive, isFalse);
      expect(gpu.events, <String>['server+', 'server-', 'worker+']);

      // worker 用完空闲后，朗读再拉服务端：worker 让出。
      expect(await engine.start(), isTrue);
      expect(gpu.events.skip(3), <String>['worker-', 'server+']);
    });

    test('服务端正在启动（还没就绪）：这次启动被取消、进程被杀，worker 再起', () async {
      serverListensOnSpawn = false;
      final Future<bool> serverStart = engine.start();
      await _until(() => servers.isNotEmpty);
      expect(engine.server.phase, LocalServicePhase.starting);

      final IrodoriBatchResult r = await engine.batchWorker.run(_job);
      expect(r.failure, isNull);
      expect(await serverStart, isFalse);
      expect(engine.server.phase, LocalServicePhase.stopped);
      expect(servers.single.alive, isFalse);
      expect(gpu.events, <String>['server+', 'server-', 'worker+']);
    });
  });
}
