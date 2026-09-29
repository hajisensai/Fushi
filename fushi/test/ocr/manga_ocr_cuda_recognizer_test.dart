import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/ocr/manga_ocr_cuda_recognizer.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';
import 'package:image/image.dart' as img;

Map<String, Object?> _status(String event) => <String, Object?>{
  'event': event,
  'protocol': 1,
  'device': 'cuda',
  'batch_size': 8,
  'degrade_reasons': <String>[],
};

class _WorkerProcess implements Process {
  _WorkerProcess() {
    stdin = IOSink(_input.sink);
    _input.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String line) {
          final Map<String, dynamic> request =
              jsonDecode(line) as Map<String, dynamic>;
          requests.add(request);
          if (!requestReceived.isCompleted) requestReceived.complete();
          onRequest?.call(request);
        });
  }

  final StreamController<List<int>> _input = StreamController<List<int>>();
  final StreamController<List<int>> _output = StreamController<List<int>>();
  final StreamController<List<int>> _errors = StreamController<List<int>>();
  final Completer<int> _exit = Completer<int>();
  final Completer<void> requestReceived = Completer<void>();
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
  void Function(Map<String, dynamic>)? onRequest;
  bool holdExit = false;
  int kills = 0;
  ProcessSignal? lastSignal;

  void send(Map<String, Object?> message) =>
      _output.add(utf8.encode('${jsonEncode(message)}\n'));

  void respond(Map<String, dynamic> request, List<String> texts) =>
      send(<String, Object?>{
        ..._status('result'),
        'id': request['id'],
        'texts': texts,
      });

  void finishExit([int code = 0]) {
    if (_exit.isCompleted) return;
    _exit.complete(code);
    unawaited(_output.close());
    unawaited(_errors.close());
  }

  @override
  late final IOSink stdin;
  @override
  Stream<List<int>> get stdout => _output.stream;
  @override
  Stream<List<int>> get stderr => _errors.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 31337;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills += 1;
    lastSignal = signal;
    if (!holdExit) finishExit();
    return true;
  }
}

class _Registry extends HelperProcessRegistry {
  _Registry(this.process, {this.ready = true});
  final _WorkerProcess process;
  final bool ready;
  String? executable;
  List<String>? arguments;
  Map<String, String>? environment;

  @override
  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    this.executable = executable;
    this.arguments = arguments;
    this.environment = environment;
    expect(runInShell, isFalse);
    expect(mode, ProcessStartMode.normal);
    if (ready) process.send(_status('ready'));
    return process;
  }
}

const OcrRect _box = OcrRect(left: 0, top: 0, right: 2, bottom: 2);

Future<MangaOcrCudaRecognizer> _start(
  _Registry registry, {
  Duration requestTimeout = const Duration(seconds: 2),
  Duration startupTimeout = const Duration(seconds: 2),
  void Function(String, String?)? onDeviceChanged,
  void Function(MangaOcrCudaRecognizer)? onStarted,
}) => MangaOcrCudaRecognizer.start(
  pythonExecutable: 'managed python.exe',
  modelDirectory: 'local model',
  workerPath: 'worker.py',
  processRegistry: registry,
  requestTimeout: requestTimeout,
  startupTimeout: startupTimeout,
  onDeviceChanged: onDeviceChanged,
  onStarted: onStarted,
);

void main() {
  test('managed startup is offline and reports the actual device', () async {
    final _WorkerProcess process = _WorkerProcess();
    final _Registry registry = _Registry(process);
    final List<(String, String?)> devices = <(String, String?)>[];
    final MangaOcrCudaRecognizer recognizer = await _start(
      registry,
      onDeviceChanged: (String device, String? reason) =>
          devices.add((device, reason)),
    );
    addTearDown(recognizer.close);
    expect(registry.executable, 'managed python.exe');
    expect(registry.arguments, <String>[
      '-u',
      'worker.py',
      '--model-dir',
      'local model',
      '--batch-size',
      '8',
      '--parent-pid',
      '$pid',
    ]);
    expect(registry.environment!['HF_HUB_OFFLINE'], '1');
    expect(registry.environment!['TRANSFORMERS_OFFLINE'], '1');
    expect(registry.environment!['PYTHONNOUSERSITE'], '1');
    expect(recognizer.device, 'cuda');
    expect(devices, <(String, String?)>[('cuda', null)]);
  });

  test(
    'batches raw crops with full fractional boundaries in strict order',
    () async {
      final _WorkerProcess process = _WorkerProcess();
      process.onRequest = (Map<String, dynamic> request) {
        final List<String> texts = <String>[];
        for (final dynamic encoded in request['images'] as List<dynamic>) {
          final img.Image crop = img.decodePng(
            base64Decode(encoded as String),
          )!;
          texts.add(
            '${crop.getPixel(0, 0).r.toInt()}:${crop.width}x${crop.height}',
          );
        }
        process.respond(request, texts);
      };
      final MangaOcrCudaRecognizer recognizer = await _start(
        _Registry(process),
      );
      addTearDown(recognizer.close);
      final img.Image page = img.Image(width: 25, height: 4);
      for (int x = 0; x < page.width; x++) {
        for (int y = 0; y < page.height; y++) {
          page.setPixelRgb(x, y, x, 150, 200);
        }
      }
      final List<OcrRect> boxes = <OcrRect>[
        for (int x = 0; x < 10; x++)
          OcrRect(left: x + 0.8, top: 0.8, right: x + 2.2, bottom: 2.2),
      ];
      expect(await recognizer.recognizeBatch(page, boxes), <String>[
        for (int x = 0; x < 10; x++) '$x:3x3',
      ]);
      expect(
        process.requests.map(
          (Map<String, dynamic> r) => (r['images'] as List).length,
        ),
        <int>[8, 2],
      );
      expect(process.requests.map((Map<String, dynamic> r) => r['id']), <int>[
        1,
        2,
      ]);
      expect(await recognizer.recognizeBatch(page, const <OcrRect>[]), isEmpty);
      expect(process.requests, hasLength(2));
    },
  );

  test(
    'overlapping calls reuse one process and never overlap requests',
    () async {
      final _WorkerProcess process = _WorkerProcess();
      final MangaOcrCudaRecognizer recognizer = await _start(
        _Registry(process),
      );
      addTearDown(recognizer.close);
      final img.Image page = img.Image(width: 2, height: 2);
      final Future<String> first = recognizer.recognize(page, _box);
      final Future<String> second = recognizer.recognize(page, _box);
      await process.requestReceived.future;
      expect(process.requests, hasLength(1));
      process.respond(process.requests.single, <String>['first']);
      expect(await first, 'first');
      await Future<void>.delayed(Duration.zero);
      expect(process.requests, hasLength(2));
      process.respond(process.requests.last, <String>['second']);
      expect(await second, 'second');
    },
  );

  for (final bool wrongId in <bool>[false, true]) {
    test(
      'rejects ${wrongId ? 'wrong IDs' : 'wrong result counts'} and stops worker',
      () async {
        final _WorkerProcess process = _WorkerProcess();
        process.onRequest = (Map<String, dynamic> request) =>
            process.send(<String, Object?>{
              ..._status('result'),
              'id': wrongId ? 99 : request['id'],
              'texts': wrongId ? <String>['text'] : <String>[],
            });
        final MangaOcrCudaRecognizer recognizer = await _start(
          _Registry(process),
        );
        await expectLater(
          recognizer.recognize(img.Image(width: 2, height: 2), _box),
          throwsFormatException,
        );
        await recognizer.close();
        expect(process.kills, 1);
      },
    );
  }

  test('CPU degradation is visible before inference completes', () async {
    final _WorkerProcess process = _WorkerProcess();
    final List<(String, String?)> devices = <(String, String?)>[];
    final MangaOcrCudaRecognizer recognizer = await _start(
      _Registry(process),
      onDeviceChanged: (String d, String? r) => devices.add((d, r)),
    );
    addTearDown(recognizer.close);
    process.send(<String, Object?>{
      ..._status('status'),
      'device': 'cpu',
      'batch_size': 1,
      'degrade_reasons': <String>['CUDA out of memory; using CPU'],
    });
    await Future<void>.delayed(Duration.zero);
    expect(recognizer.device, 'cpu');
    expect(recognizer.effectiveBatchSize, 1);
    expect(recognizer.degradeReason, 'CUDA out of memory; using CPU');
    expect(devices.last, ('cpu', 'CUDA out of memory; using CPU'));
  });

  test(
    'request timeout kills the worker rather than leaving inference running',
    () async {
      final _WorkerProcess process = _WorkerProcess();
      final MangaOcrCudaRecognizer recognizer = await _start(
        _Registry(process),
        requestTimeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        recognizer.recognize(img.Image(width: 2, height: 2), _box),
        throwsA(isA<TimeoutException>()),
      );
      await recognizer.close();
      expect(process.lastSignal, ProcessSignal.sigkill);
    },
  );

  test('startup timeout kills and awaits the process', () async {
    final _WorkerProcess process = _WorkerProcess();
    await expectLater(
      _start(
        _Registry(process, ready: false),
        startupTimeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(process.kills, 1);
    expect(await process.exitCode, 0);
  });

  test('onStarted allows cancellation before torch/model readiness', () async {
    final _WorkerProcess process = _WorkerProcess();
    await expectLater(
      _start(
        _Registry(process, ready: false),
        onStarted: (MangaOcrCudaRecognizer r) => unawaited(r.close()),
      ),
      throwsStateError,
    );
    expect(process.kills, 1);
  });

  test(
    'close interrupts pending work immediately and awaits actual exit',
    () async {
      final _WorkerProcess process = _WorkerProcess()..holdExit = true;
      final MangaOcrCudaRecognizer recognizer = await _start(
        _Registry(process),
      );
      final Future<void> rejected = expectLater(
        recognizer.recognize(img.Image(width: 2, height: 2), _box),
        throwsStateError,
      );
      await process.requestReceived.future;
      bool exited = false;
      final Future<void> closed = recognizer.close().then((_) => exited = true);
      await rejected;
      expect(process.kills, 1);
      expect(exited, isFalse);
      process.finishExit();
      await closed;
      await recognizer.close();
      expect(process.kills, 1, reason: 'close must be idempotent');
    },
  );

  test('unexpected process exit rejects pending recognition', () async {
    final _WorkerProcess process = _WorkerProcess();
    final MangaOcrCudaRecognizer recognizer = await _start(_Registry(process));
    final Future<void> rejected = expectLater(
      recognizer.recognize(img.Image(width: 2, height: 2), _box),
      throwsStateError,
    );
    await process.requestReceived.future;
    process.finishExit(7);
    await rejected;
    await recognizer.close();
  });
}
