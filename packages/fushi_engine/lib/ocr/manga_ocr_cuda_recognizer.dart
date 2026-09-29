import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:fushi_engine/utils/misc/helper_process_registry.dart';

/// One offline, persistent manga-ocr process. Requests are serialized, with
/// batched crops in reading order and explicit device/degradation reporting.
class MangaOcrCudaRecognizer implements BatchOcrRecognizer {
  MangaOcrCudaRecognizer._(
    this._process, {
    required this.batchSize,
    required this.requestTimeout,
    required this.shutdownTimeout,
    required this.onDeviceChanged,
  }) {
    _stdout = _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          _receive,
          onError: _fail,
          onDone: () {
            if (!_closed)
              _fail(StateError('manga-ocr worker closed stdout$_details'));
          },
        );
    _stderr = _process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (String value) {
            _diagnostics += value;
            if (_diagnostics.length > 8192) {
              _diagnostics = _diagnostics.substring(_diagnostics.length - 8192);
            }
          },
          onError: (Object error) {
            if (!_closed) _fail(error);
          },
        );
    unawaited(
      _process.exitCode.then<void>((int code) {
        if (!_closed) {
          _fail(StateError('manga-ocr worker exited ($code)$_details'));
        }
      }, onError: _fail),
    );
    unawaited(
      _process.stdin.done.then<void>((_) {
        if (!_closed) _fail(StateError('manga-ocr worker closed stdin'));
      }, onError: _fail),
    );
  }

  /// The installer materializes the bundled worker and verifies the local
  /// checkpoint before calling this method. The worker never downloads files.
  static Future<MangaOcrCudaRecognizer> start({
    required String pythonExecutable,
    required String modelDirectory,
    required String workerPath,
    int batchSize = 8,
    void Function(String device, String? degradeReason)? onDeviceChanged,
    void Function(MangaOcrCudaRecognizer recognizer)? onStarted,
    Duration startupTimeout = const Duration(minutes: 2),
    Duration requestTimeout = const Duration(minutes: 2),
    Duration shutdownTimeout = const Duration(seconds: 5),
    HelperProcessRegistry? processRegistry,
  }) async {
    RangeError.checkValueInInterval(batchSize, 1, 8, 'batchSize');
    final Process process =
        await (processRegistry ?? HelperProcessRegistry.instance).start(
          pythonExecutable,
          <String>[
            '-u',
            workerPath,
            '--model-dir',
            modelDirectory,
            '--batch-size',
            '$batchSize',
            '--parent-pid',
            '$pid',
          ],
          environment: const <String, String>{
            'HF_HUB_OFFLINE': '1',
            'TRANSFORMERS_OFFLINE': '1',
            'HF_HUB_DISABLE_TELEMETRY': '1',
            'TOKENIZERS_PARALLELISM': 'false',
            'PYTHONIOENCODING': 'utf-8',
            'PYTHONUNBUFFERED': '1',
            'PYTHONNOUSERSITE': '1',
            'PYTHONPATH': '',
          },
        );
    final MangaOcrCudaRecognizer recognizer = MangaOcrCudaRecognizer._(
      process,
      batchSize: batchSize,
      requestTimeout: requestTimeout,
      shutdownTimeout: shutdownTimeout,
      onDeviceChanged: onDeviceChanged,
    );
    final Future<void> ready = recognizer._ready.future.timeout(
      startupTimeout,
      onTimeout: () => throw TimeoutException(
        'manga-ocr worker startup timed out${recognizer._details}',
        startupTimeout,
      ),
    );
    // onStarted may cancel or throw before the await below attaches; observe
    // readiness immediately while still propagating its error to start().
    unawaited(ready.catchError((Object _) {}));
    try {
      onStarted?.call(recognizer);
      await ready;
      return recognizer;
    } catch (_) {
      await recognizer.close();
      rethrow;
    }
  }

  final Process _process;
  final int batchSize;
  final Duration requestTimeout;
  final Duration shutdownTimeout;
  final void Function(String device, String? degradeReason)? onDeviceChanged;
  final Completer<void> _ready = Completer<void>();
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<String> _stderr;
  Completer<List<String>>? _pending;
  int _requestId = 0;
  int _expectedTexts = 0;
  bool _closed = false;
  bool _receivedReady = false;
  Future<void>? _closing;
  Future<void> _queue = Future<void>.value();
  String _diagnostics = '';
  String _device = '';
  String? _degradeReason;
  int _effectiveBatchSize = 1;

  String get device => _device;
  String? get degradeReason => _degradeReason;
  int get effectiveBatchSize => _effectiveBatchSize;
  String get _details => _diagnostics.isEmpty ? '' : ': $_diagnostics';

  void _updateStatus(Map<String, dynamic> message) {
    final Object? device = message['device'];
    final Object? count = message['batch_size'];
    final Object? reasons = message['degrade_reasons'];
    if (message['protocol'] != 1 ||
        (device != 'cuda' && device != 'cpu') ||
        count is! int ||
        count < 1 ||
        count > batchSize ||
        reasons is! List ||
        reasons.any((dynamic reason) => reason is! String)) {
      throw const FormatException('invalid manga-ocr worker status');
    }
    final String? reason = reasons.isEmpty ? null : reasons.join('; ');
    final bool changed = device != _device || reason != _degradeReason;
    _device = device as String;
    _effectiveBatchSize = count;
    _degradeReason = reason;
    if (changed) onDeviceChanged?.call(_device, reason);
  }

  void _receive(String line) {
    if (_closed) return;
    try {
      final Object? decoded = jsonDecode(line);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('invalid manga-ocr worker message');
      }
      if (decoded['event'] == 'error') {
        throw StateError('manga-ocr worker: ${decoded['message']}');
      }
      if (decoded['event'] == 'ready') {
        if (_receivedReady) throw StateError('duplicate worker ready event');
        _updateStatus(decoded);
        _receivedReady = true;
        _ready.complete();
        return;
      }
      if (!_receivedReady) throw StateError('worker message before ready');
      if (decoded['event'] == 'status') {
        _updateStatus(decoded);
        return;
      }
      if (decoded['event'] != 'result' ||
          decoded['id'] != _requestId ||
          _pending == null) {
        throw const FormatException('unexpected manga-ocr worker response');
      }
      _updateStatus(decoded);
      final Object? texts = decoded['texts'];
      if (texts is! List ||
          texts.length != _expectedTexts ||
          texts.any((dynamic text) => text is! String)) {
        throw const FormatException(
          'manga-ocr response count/order contract failed',
        );
      }
      final Completer<List<String>> pending = _pending!;
      _pending = null;
      pending.complete(texts.cast<String>());
    } catch (error, stack) {
      _fail(error, stack);
    }
  }

  void _fail(Object error, [StackTrace? stack]) {
    if (_closed) return;
    if (!_ready.isCompleted) _ready.completeError(error, stack);
    final Completer<List<String>>? pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted)
      pending.completeError(error, stack);
    // Preserve the original protocol/process failure; close still kills and
    // waits for the process, and a caller may await close() itself as well.
    unawaited(close().catchError((Object _) {}));
  }

  void _checkOpen() {
    if (_closed) throw StateError('manga-ocr worker is closed');
  }

  @override
  Future<String> recognize(img.Image page, OcrRect box) async =>
      (await recognizeBatch(page, <OcrRect>[box])).single;

  @override
  Future<List<String>> recognizeBatch(img.Image page, List<OcrRect> boxes) {
    final List<OcrRect> snapshot = List<OcrRect>.of(boxes);
    final Future<List<String>> result = _queue.then((_) async {
      _checkOpen();
      final List<String> texts = <String>[];
      for (int start = 0; start < snapshot.length; start += batchSize) {
        _checkOpen();
        final List<String> images = <String>[
          for (final OcrRect box in snapshot.skip(start).take(batchSize))
            // Local IPC favors fast lossless encoding over smaller files.
            base64Encode(img.encodePng(_crop(page, box), level: 1)),
        ];
        texts.addAll(await _request(images));
      }
      return texts;
    });
    _queue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  static img.Image _crop(img.Image page, OcrRect box) {
    if (!box.left.isFinite ||
        !box.top.isFinite ||
        !box.right.isFinite ||
        !box.bottom.isFinite) {
      throw ArgumentError.value(box, 'box', 'coordinates must be finite');
    }
    final OcrRect clipped = box.clamp(
      page.width.toDouble(),
      page.height.toDouble(),
    );
    final int x = clipped.left.floor().clamp(0, page.width - 1);
    final int y = clipped.top.floor().clamp(0, page.height - 1);
    return img.copyCrop(
      page,
      x: x,
      y: y,
      width: math.max(1, clipped.right.ceil() - x),
      height: math.max(1, clipped.bottom.ceil() - y),
    );
  }

  Future<List<String>> _request(List<String> images) async {
    _checkOpen();
    final Completer<List<String>> pending = Completer<List<String>>();
    _pending = pending;
    _expectedTexts = images.length;
    _requestId += 1;
    try {
      _process.stdin.writeln(
        jsonEncode(<String, Object>{
          'id': _requestId,
          'op': 'recognize',
          'images': images,
        }),
      );
    } catch (error, stack) {
      _fail(error, stack);
    }
    try {
      return await pending.future.timeout(requestTimeout);
    } catch (error, stack) {
      _fail(error, stack);
      rethrow;
    }
  }

  /// Cancellation must not wait for generation or for the serialized queue.
  /// SIGKILL is immediate on Windows and Unix; EOF also stops the worker if the
  /// owning isolate is killed without executing this cleanup.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    if (!_ready.isCompleted) {
      _ready.completeError(
        StateError('manga-ocr worker was closed during startup'),
      );
    }
    final Completer<List<String>>? pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('manga-ocr worker was closed'));
    }
    _process.kill(ProcessSignal.sigkill);
    unawaited(_process.stdin.close().catchError((Object _) {}));
    try {
      await _process.exitCode.timeout(shutdownTimeout);
    } finally {
      await _stdout.cancel();
      await _stderr.cancel();
    }
  }
}
