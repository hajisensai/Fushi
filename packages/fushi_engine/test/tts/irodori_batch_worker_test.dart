import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/tts/local/irodori_batch_worker.dart';
import 'package:fushi_engine/tts/local/irodori_batch_worker_script.dart';
import 'package:fushi_engine/tts/local/irodori_local_engine.dart';
import 'package:fushi_engine/tts/local/irodori_local_package.dart';
import 'package:fushi_engine/tts/tts_types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'tts_test_helpers.dart';

/// 按 worker 的方式起读线程（`Reader(detach_stdin())`），再起一个继承 stdin 的子进程。
const String _stdinHarness = r'''
import importlib.util, os, subprocess, sys, time
spec = importlib.util.spec_from_file_location("w", sys.argv[1])
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)
reader = w.Reader(w.detach_stdin())
reader.start()
time.sleep(0.3)
out = subprocess.run([sys.executable, "-c", "print('child')"],
                     stdout=subprocess.PIPE, timeout=10).stdout
print("child=" + out.decode().strip(), flush=True)
print("req=" + str(reader.requests.get(timeout=10)), flush=True)
os._exit(0)
''';

/// PATH 上能跑的 Python 3；找不到返回 null。
Future<String?> _findPython() async {
  for (final String exe in <String>['python3', 'python']) {
    try {
      final ProcessResult r = await Process.run(exe, <String>['--version']);
      if (r.exitCode == 0 && '${r.stdout}${r.stderr}'.contains('Python 3')) {
        return exe;
      }
    } on ProcessException {
      continue;
    }
  }
  return null;
}

/// 假 worker 进程：收到的每行请求交给 [onRequest]，它经 [emit] 回事件。
class _FakeWorker implements Process {
  _FakeWorker(this.onRequest) {
    _stdinController.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          requests.add(jsonDecode(line) as Map<String, Object?>);
          onRequest(this, requests.last);
        });
  }

  final void Function(_FakeWorker w, Map<String, Object?> request) onRequest;
  final List<Map<String, Object?>> requests = <Map<String, Object?>>[];
  final StreamController<List<int>> _out = StreamController<List<int>>();
  final StreamController<List<int>> _err = StreamController<List<int>>();
  final StreamController<List<int>> _stdinController =
      StreamController<List<int>>();
  late final IOSink _stdin = IOSink(_stdinController.sink);
  final Completer<int> _exit = Completer<int>();

  void emit(String event, Map<String, Object?> fields) => _out.add(
    utf8.encode(
      '$kIrodoriBatchEventPrefix${jsonEncode(<String, Object?>{'event': event, ...fields})}\n',
    ),
  );

  void log(String line) => _out.add(utf8.encode('$line\n'));

  void exit(int code) {
    if (_exit.isCompleted) return;
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
  int get pid => 4242;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    exit(-9);
    return true;
  }
}

/// 正常的假 worker：一启动就 ready；合成请求逐句回报，`fail` 开头的句子失败；
/// 支持取消与退出。
void _standard(_FakeWorker w, Map<String, Object?> req) {
  switch (req['op']) {
    case 'synthesize':
      final List<Object?> items = req['items']! as List<Object?>;
      final String job = req['job']! as String;
      int ok = 0, failed = 0;
      for (int i = 0; i < items.length; i++) {
        final Map<String, Object?> item = items[i]! as Map<String, Object?>;
        final bool good = !(item['text']! as String).startsWith('fail');
        good ? ok++ : failed++;
        w.emit('line', <String, Object?>{
          'job': job,
          'id': item['id'],
          'index': i,
          'total': items.length,
          'ok': good,
          if (good) 'out': item['out'],
          if (good) 'duration_ms': 1200,
          if (!good) 'error': 'RuntimeError: boom',
        });
      }
      w.emit('job_done', <String, Object?>{
        'job': job,
        'ok': ok,
        'failed': failed,
        'cancelled': false,
      });
    case 'shutdown':
      w.exit(0);
  }
}

IrodoriBatchItem _item(
  String id,
  String text, {
  String? adapter,
  String refs = 'a',
}) => IrodoriBatchItem(
  id: id,
  text: text,
  refs: <String>['/refs/$refs.wav'],
  adapterDir: adapter,
  outputPath: '/out/$id.wav',
);

void main() {
  late Directory dir;
  late File python;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('irodori_batch_');
    python = File(p.join(dir.path, 'python.exe'))..writeAsStringSync('');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  IrodoriBatchWorker worker(
    _FakeWorker Function() make, {
    void Function(Map<String, String>?)? onEnv,
    bool ready = true,
    Duration readyTimeout = const Duration(seconds: 5),
  }) => IrodoriBatchWorker(
    launch: () async => IrodoriBatchLaunch(
      executable: python.path,
      arguments: const <String>['w.py'],
      workingDirectory: dir.path,
      environment: const <String, String>{'IRODORI_SDPA_CUDNN': '0'},
    ),
    readyTimeout: readyTimeout,
    stopTimeout: const Duration(milliseconds: 200),
    spawn:
        (
          String exe,
          List<String> args, {
          String? workingDirectory,
          Map<String, String>? environment,
        }) async {
          onEnv?.call(environment);
          final _FakeWorker w = make();
          if (ready) {
            scheduleMicrotask(() {
              w.log('Loading checkpoint ...');
              w.emit('loading', <String, Object?>{'stage': 'model'});
              w.emit('ready', <String, Object?>{
                'protocol': kIrodoriBatchProtocol,
                'device': 'cuda',
              });
            });
          }
          return w;
        },
  );

  group('协议', () {
    test('事件行解析；日志行与坏行返回 null', () {
      expect(parseIrodoriWorkerLine('Loading model'), isNull);
      expect(parseIrodoriWorkerLine('$kIrodoriBatchEventPrefix{bad'), isNull);
      expect(
        parseIrodoriWorkerLine('$kIrodoriBatchEventPrefix{"event":"nope"}'),
        isNull,
      );
      expect(
        parseIrodoriWorkerLine(
          '$kIrodoriBatchEventPrefix{"event":"ready","protocol":1,"device":"cuda"}',
        ),
        isA<IrodoriWorkerReady>()
            .having((IrodoriWorkerReady e) => e.device, 'device', 'cuda')
            .having((IrodoriWorkerReady e) => e.protocol, 'protocol', 1),
      );
      final IrodoriWorkerLine ok =
          parseIrodoriWorkerLine(
                '$kIrodoriBatchEventPrefix{"event":"line","job":"j","id":"p001_b0_0",'
                '"index":2,"total":5,"ok":true,"out":"/o.wav","duration_ms":980}',
              )!
              as IrodoriWorkerLine;
      expect(ok.result.ok, isTrue);
      expect(ok.result.outputPath, '/o.wav');
      expect(ok.result.durationMs, 980);
      expect(ok.index, 2);
      expect(ok.total, 5);
      final IrodoriWorkerLine bad =
          parseIrodoriWorkerLine(
                '$kIrodoriBatchEventPrefix{"event":"line","job":"j","id":"x","ok":false,'
                '"error":"MemoryError: "}',
              )!
              as IrodoriWorkerLine;
      expect(bad.result.ok, isFalse);
      expect(bad.result.error, 'MemoryError: ');
      expect(bad.result.outputPath, isNull);
      expect(
        parseIrodoriWorkerLine(
          '$kIrodoriBatchEventPrefix{"event":"line","job":"j","id":"x"}',
        ),
        isNull,
        reason: '缺 ok 字段',
      );
      expect(
        parseIrodoriWorkerLine(
          '$kIrodoriBatchEventPrefix{"event":"job_done","job":"j","ok":3,"failed":1,"cancelled":true}',
        ),
        isA<IrodoriWorkerJobDone>()
            .having((IrodoriWorkerJobDone e) => e.failed, 'failed', 1)
            .having((IrodoriWorkerJobDone e) => e.cancelled, 'cancelled', true),
      );
      expect(
        parseIrodoriWorkerLine(
          '$kIrodoriBatchEventPrefix{"event":"fatal","error":"MemoryError"}',
        ),
        isA<IrodoriWorkerFatal>(),
      );
    });

    test('合成顺序：LoRA 组在前、同组连续、组内保持原序', () {
      final List<IrodoriBatchItem> order = irodoriBatchOrder(<IrodoriBatchItem>[
        _item('1', 'a', refs: 'narr'),
        _item('2', 'b', adapter: '/lora', refs: 'miyagi'),
        _item('3', 'c', refs: 'side'),
        _item('4', 'd', adapter: '/lora', refs: 'sendai'),
        _item('5', 'e', adapter: '/lora', refs: 'miyagi'),
        _item('6', 'f', refs: 'narr'),
      ]);
      expect(order.map((IrodoriBatchItem i) => i.id), <String>[
        '2',
        '5',
        '4',
        '1',
        '6',
        '3',
      ]);
    });

    test('请求行带全部字段（字段名与脚本一致）', () {
      final Map<String, Object?> req =
          jsonDecode(
                encodeIrodoriSynthesizeRequest(
                  IrodoriBatchJob(
                    id: 'j1',
                    items: <IrodoriBatchItem>[
                      const IrodoriBatchItem(
                        id: 'l',
                        text: 'うん',
                        refs: <String>['/r.wav'],
                        outputPath: '/o.wav',
                        seconds: 0.85,
                        seed: 3,
                      ),
                    ],
                  ),
                ),
              )
              as Map<String, Object?>;
      expect(req['op'], 'synthesize');
      expect(req['job'], 'j1');
      final Map<String, Object?> item =
          (req['items']! as List<Object?>).single! as Map<String, Object?>;
      expect(item, <String, Object?>{
        'id': 'l',
        'text': 'うん',
        'refs': <String>['/r.wav'],
        'adapter': null,
        'seconds': 0.85,
        'seed': 3,
        'steps': 40,
        'cfg_text': 3.0,
        'cfg_speaker': 5.0,
        'out': '/o.wav',
      });
      for (final String key in item.keys) {
        if (key == 'id' || key == 'text' || key == 'out') continue;
        expect(
          kIrodoriBatchWorkerScript,
          contains('"$key"'),
          reason: '脚本要读 $key',
        );
      }
      expect(encodeIrodoriCancelRequest('j1'), '{"op":"cancel","job":"j1"}');
    });

    test('脚本与 Dart 侧的协议常量一致、带上低内存加载与 SDPA 开关', () {
      expect(
        kIrodoriBatchWorkerScript,
        contains('PROTOCOL = $kIrodoriBatchProtocol'),
      );
      expect(
        kIrodoriBatchWorkerScript,
        contains('PREFIX = "$kIrodoriBatchEventPrefix"'),
      );
      expect(kIrodoriBatchWorkerScript, contains('IRODORI_SDPA_CUDNN'));
      expect(kIrodoriBatchWorkerScript, contains('load_safetensors_file = '));
      expect(kIrodoriBatchWorkerScript, contains('lora_adapter='));
      expect(kIrodoriBatchWorkerScript, contains('seconds='));
      expect(kIrodoriBatchWorkerScript, isNot(contains("'''")));
    });

    // 回归：读请求的线程直接挂在真 stdin 上时，Windows 的同步管道读会让同一句柄上的
    // 其它调用（加载自带 CRT 的原生 DLL、subprocess 复制 STD_INPUT_HANDLE）一起卡死，
    // 真实 Irodori 上表现为永远停在 loading{stage: import}。这里不需要 torch：
    // 读线程挂起后再起一个继承 stdin 的子进程，修复前子进程卡住、超时。
    test('读请求线程挂起时，主线程仍能起子进程，请求照常读到', () async {
      final String? python = await _findPython();
      if (python == null) {
        markTestSkipped('本机没有可用的 python');
        return;
      }
      final Directory tmp = await Directory.systemTemp.createTemp(
        'irodori_stdin_',
      );
      addTearDown(() => tmp.delete(recursive: true));
      final String script = p.join(tmp.path, 'w.py');
      await File(script).writeAsString(kIrodoriBatchWorkerScript);
      final String harness = p.join(tmp.path, 'h.py');
      await File(harness).writeAsString(_stdinHarness);
      final Process proc = await Process.start(python, <String>[
        '-I',
        harness,
        script,
      ]);
      final Future<String> out = proc.stdout.transform(utf8.decoder).join();
      final Future<String> err = proc.stderr.transform(utf8.decoder).join();
      await Future<void>.delayed(const Duration(seconds: 1));
      proc.stdin.writeln('{"op":"synthesize","job":"j"}');
      await proc.stdin.flush();
      final int code = await proc.exitCode.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          proc.kill();
          return -1;
        },
      );
      final String stdoutText = await out;
      expect(code, 0, reason: '$stdoutText\n${await err}');
      expect(stdoutText, contains('child=child'));
      expect(stdoutText, contains("req={'op': 'synthesize', 'job': 'j'}"));
    });
  });

  group('IrodoriBatchWorker', () {
    test('拉起 → 就绪；整批逐句回报，失败句只影响自己', () async {
      Map<String, String>? env;
      final IrodoriBatchWorker w = worker(
        () => _FakeWorker(_standard),
        onEnv: (Map<String, String>? e) => env = e,
      );
      final List<String> seen = <String>[];
      final IrodoriBatchResult r = await w.run(
        IrodoriBatchJob(
          id: 'j1',
          items: <IrodoriBatchItem>[
            _item('a', 'こんにちは'),
            _item('b', 'fail please'),
            _item('c', 'またね'),
          ],
        ),
        onLine: (IrodoriBatchLineResult l) => seen.add('${l.id}:${l.ok}'),
      );
      expect(w.phase, IrodoriBatchPhase.ready);
      expect(w.device, 'cuda');
      expect(w.logTail, contains('Loading checkpoint ...'));
      expect(env!['IRODORI_SDPA_CUDNN'], '0');
      expect(env!['PYTHONUNBUFFERED'], '1');
      expect(seen, <String>['a:true', 'b:false', 'c:true']);
      expect(r.failure, isNull);
      expect(r.cancelled, isFalse);
      expect(r.lines['a']!.outputPath, '/out/a.wav');
      expect(r.lines['a']!.durationMs, 1200);
      expect(r.failedLines.map((IrodoriBatchLineResult l) => l.id), <String>[
        'b',
      ]);
      expect(w.isBusy, isFalse);
      await w.stop();
      expect(w.phase, IrodoriBatchPhase.stopped);
    });

    test('多个任务排队、模型只加载一次', () async {
      int spawns = 0;
      final IrodoriBatchWorker w = worker(() {
        spawns++;
        return _FakeWorker(_standard);
      });
      final List<Future<IrodoriBatchResult>> runs =
          <Future<IrodoriBatchResult>>[
            for (int i = 0; i < 3; i++)
              w.run(
                IrodoriBatchJob(
                  id: 'j$i',
                  items: <IrodoriBatchItem>[_item('l$i', 't')],
                ),
              ),
          ];
      final List<IrodoriBatchResult> results = await Future.wait(runs);
      expect(spawns, 1);
      for (int i = 0; i < 3; i++) {
        expect(results[i].lines['l$i']!.ok, isTrue);
      }
      await w.stop();
    });

    test('进程中途退出：没回报的句子全记失败，下次重新拉起', () async {
      int spawns = 0;
      final IrodoriBatchWorker w = worker(() {
        spawns++;
        return _FakeWorker((_FakeWorker fw, Map<String, Object?> req) {
          if (req['op'] != 'synthesize') return;
          if (spawns == 1) {
            fw.emit('line', <String, Object?>{
              'job': req['job'],
              'id': 'a',
              'index': 0,
              'total': 2,
              'ok': true,
              'out': '/out/a.wav',
            });
            fw.exit(3221225477); // access violation
          } else {
            _standard(fw, req);
          }
        });
      });
      final List<IrodoriBatchLineResult> seen = <IrodoriBatchLineResult>[];
      final IrodoriBatchResult r = await w.run(
        IrodoriBatchJob(
          id: 'j',
          items: <IrodoriBatchItem>[_item('a', 'x'), _item('b', 'y')],
        ),
        onLine: seen.add,
      );
      expect(r.failure, IrodoriBatchFailure.exited);
      expect(r.lines['a']!.ok, isTrue);
      expect(r.lines['b']!.ok, isFalse);
      expect(r.lines['b']!.error, 'worker_exited');
      expect(seen.map((IrodoriBatchLineResult l) => l.id), <String>['a', 'b']);
      expect(w.phase, IrodoriBatchPhase.failed);
      expect(w.failure, IrodoriBatchFailure.exited);

      final IrodoriBatchResult again = await w.run(
        IrodoriBatchJob(id: 'j2', items: <IrodoriBatchItem>[_item('b', 'y')]),
      );
      expect(spawns, 2);
      expect(again.lines['b']!.ok, isTrue);
      await w.stop();
    });

    test('取消：发 cancel 请求，结果标记 cancelled', () async {
      late _FakeWorker fake;
      final IrodoriBatchWorker w = worker(
        () => fake = _FakeWorker((_FakeWorker fw, Map<String, Object?> req) {
          switch (req['op']) {
            case 'synthesize':
              fw.emit('line', <String, Object?>{
                'job': req['job'],
                'id': 'a',
                'index': 0,
                'total': 3,
                'ok': true,
                'out': '/out/a.wav',
              });
            case 'cancel':
              fw.emit('job_done', <String, Object?>{
                'job': req['job'],
                'ok': 1,
                'failed': 0,
                'cancelled': true,
              });
            case 'shutdown':
              fw.exit(0);
          }
        }),
      );
      final TtsCancelToken token = TtsCancelToken();
      final Future<IrodoriBatchResult> pending = w.run(
        IrodoriBatchJob(
          id: 'jc',
          items: <IrodoriBatchItem>[
            _item('a', 'x'),
            _item('b', 'y'),
            _item('c', 'z'),
          ],
        ),
        onLine: (_) => token.cancel(),
        cancel: token,
      );
      final IrodoriBatchResult r = await pending;
      expect(r.cancelled, isTrue);
      expect(r.lines.keys, <String>['a']);
      expect(
        fake.requests.map((Map<String, Object?> q) => q['op']),
        containsAllInOrder(<String>['synthesize', 'cancel']),
      );
      await w.stop();
    });

    test('加载失败（fatal）/ 协议不符 / 没装 → 失败原因如实', () async {
      final IrodoriBatchWorker fatal = worker(() {
        final _FakeWorker fw = _FakeWorker(_standard);
        scheduleMicrotask(() {
          fw.emit('fatal', <String, Object?>{'error': 'MemoryError: '});
          fw.exit(1);
        });
        return fw;
      }, ready: false);
      final IrodoriBatchResult r = await fatal.run(
        IrodoriBatchJob(id: 'j', items: <IrodoriBatchItem>[_item('a', 'x')]),
      );
      expect(r.failure, IrodoriBatchFailure.loadFailed);
      expect(r.lines, isEmpty);
      expect(fatal.logTail.join('\n'), contains('MemoryError'));

      final IrodoriBatchWorker mismatch = worker(() {
        final _FakeWorker fw = _FakeWorker(_standard);
        scheduleMicrotask(
          () => fw.emit('ready', <String, Object?>{
            'protocol': kIrodoriBatchProtocol + 1,
            'device': 'cpu',
          }),
        );
        return fw;
      }, ready: false);
      expect(await mismatch.start(), isFalse);
      expect(mismatch.failure, IrodoriBatchFailure.protocolMismatch);

      final IrodoriBatchWorker missing = IrodoriBatchWorker(
        launch: () async => null,
      );
      expect(await missing.start(), isFalse);
      expect(missing.failure, IrodoriBatchFailure.notInstalled);
    });

    test('加载超时 → timeout，进程被杀', () async {
      late _FakeWorker fake;
      final IrodoriBatchWorker w = worker(
        () => fake = _FakeWorker(_standard),
        ready: false,
        readyTimeout: const Duration(milliseconds: 50),
      );
      expect(await w.start(), isFalse);
      expect(w.failure, IrodoriBatchFailure.timeout);
      expect(await fake.exitCode, -9);
    });

    test('空任务 / 已取消不拉起进程', () async {
      int spawns = 0;
      final IrodoriBatchWorker w = worker(() {
        spawns++;
        return _FakeWorker(_standard);
      });
      expect(
        (await w.run(
          const IrodoriBatchJob(id: 'e', items: <IrodoriBatchItem>[]),
        )).lines,
        isEmpty,
      );
      final TtsCancelToken token = TtsCancelToken()..cancel();
      expect(
        (await w.run(
          IrodoriBatchJob(id: 'c', items: <IrodoriBatchItem>[_item('a', 'x')]),
          cancel: token,
        )).cancelled,
        isTrue,
      );
      expect(spawns, 0);
    });
  });

  group('引擎装配', () {
    test('启动参数：.venv 解释器 + 脚本 + v4-Large 与编解码器的本地路径', () async {
      final IrodoriInstallLayout layout = IrodoriInstallLayout(
        p.join(dir.path, 'fushi-irodori-tts'),
      );
      final String script = await writeIrodoriBatchWorkerScript(layout);
      expect(File(script).readAsStringSync(), kIrodoriBatchWorkerScript);
      expect(p.basename(script), kIrodoriBatchWorkerScriptName);
      final IrodoriModelRepo large =
          kIrodoriManifest.models[IrodoriModelChoice.large]!;
      final IrodoriBatchLaunch launch = irodoriBatchLaunch(
        layout: layout,
        script: script,
        large: large,
        codec: kIrodoriManifest.codec,
        source: IrodoriDownloadSource.huggingFace,
      );
      expect(launch.executable, layout.venvPython);
      expect(launch.arguments.take(4), <String>['-X', 'utf8', '-u', script]);
      final int ckpt = launch.arguments.indexOf('--checkpoint');
      expect(
        launch.arguments[ckpt + 1],
        p.join(layout.modelsDir, 'Irodori-TTS-v4-Large', 'model.safetensors'),
      );
      expect(launch.arguments, contains('--codec'));
      expect(launch.environment['IRODORI_SDPA_CUDNN'], '0');
      expect(launch.environment['PYTHONPATH'], '');
      expect(launch.environment['HF_HOME'], layout.hfHome);
    });

    test('v4-Large 清单：13 GB 底模、与 Small 不同的 tokenizer，钉了 revision', () {
      final IrodoriModelRepo large =
          kIrodoriManifest.models[IrodoriModelChoice.large]!;
      expect(large.repo, 'Aratako/Irodori-TTS-v4-Large');
      expect(large.revision, hasLength(40));
      expect(large.totalBytes, greaterThan(13000000000));
      for (final IrodoriPinnedFile f in large.files) {
        expect(f.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
      }
      expect(
        large.files.map((IrodoriPinnedFile f) => f.path),
        containsAll(<String>[
          'model.safetensors',
          'tokenizer/tokenizer.json',
          'tokenizer/tokenizer_config.json',
        ]),
      );
    });

    test('没下 v4-Large 时 batchModelReady 为假、worker 报 notInstalled', () async {
      final IrodoriLocalEngine engine = IrodoriLocalEngine(
        prefs: MemoryPrefStore(),
        httpClientFactory: () => HttpClient(),
        supported: true,
      );
      expect(engine.batchModelReady, isFalse);
      expect(await engine.batchWorker.start(), isFalse);
      expect(engine.batchWorker.failure, IrodoriBatchFailure.notInstalled);
      engine.dispose();
    });
  });
}
