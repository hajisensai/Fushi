/// 把整本转录任务下放到 `Isolate.spawn` 的后台 isolate。
///
/// 转录链路里的 fbank（纯 Dart FFT）、能量 VAD、PCM 解析、Loop 图输出的 token
/// 还原全是主 isolate 上的同步 CPU 工作；ORT 调用本身经 MethodChannel 异步，但
/// 每批几十秒音频的特征计算就够把 UI 卡成幻灯片（2026-09-06 英语整本实测）。
/// 做法与漫画 OCR 整卷任务（`manga_ocr_service_impl.dart`）相同：
/// `BackgroundIsolateBinaryMessenger.ensureInitialized(RootIsolateToken)` 让
/// flutter_onnxruntime 的 MethodChannel 可从后台 isolate 发出，会话在 isolate
/// 内建、在 isolate 内关，主 isolate 只收事件。
///
/// 消息协议（同代码库 `Isolate.spawn`，直接发送实例；`AsrTranscribeEvent` 三个
/// 子类的字段都是纯数据，可原样跨 isolate）：
///
/// ```text
/// isolate → main : _ControlPort(sendPort)     建会话前第一时间发，主侧据此发暂停
///                  _Loaded(resolution, greedy…) 引擎装载完成（spawn() 在此返回）
///                  AsrTranscribeEvent           进度 / 已暂停 / 完成（原样转发）
///                  _Stats(AsrDecodeStats)       任务结束后的分阶段耗时
///                  _Error(message, stack)       装载或运行期异常
///                  _Exited()                    会话已关、isolate 即将退出
/// main → isolate : 'pause'                     请求在下一个检查点暂停
/// ```
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show BackgroundIsolateBinaryMessenger, RootIsolateToken;

import 'package:fushi/src/asr/asr_encoder_buckets.dart';
import 'package:fushi/src/asr/asr_engine.dart';
import 'package:fushi/src/asr/asr_model_manifest.dart';
import 'package:fushi/src/asr/asr_model_store.dart';
import 'package:fushi/src/asr/asr_pcm_source.dart';
import 'package:fushi/src/asr/asr_transcribe_job.dart';
import 'package:fushi/src/asr/asr_transcription_service.dart';
import 'package:fushi/src/asr/asr_transducer_decoder.dart';
import 'package:fushi/src/asr/asr_vad.dart';
import 'package:fushi/src/onnx/onnx_inference.dart';

/// 跨 isolate 的任务说明：全是路径 / 枚举 / 数值，不带闭包与会话。
@immutable
class AsrIsolateJobSpec {
  const AsrIsolateJobSpec({
    required this.storeDirPath,
    required this.language,
    required this.variant,
    required this.preference,
    required this.audioPaths,
    required this.jobDirPath,
    required this.chunkSeconds,
    required this.segmenterKind,
    this.batchSize,
    this.usePipeline = true,
    this.staticBucketsOverride,
    this.materialMs,
  });

  final String storeDirPath;
  final AsrLanguage language;
  final AsrEncoderVariant variant;
  final AsrAccelerationPreference preference;
  final List<String> audioPaths;
  final String jobDirPath;
  final int chunkSeconds;
  final AsrSegmenterKind segmenterKind;

  final bool usePipeline;

  /// 见 [AsrTranscriptionService.staticBucketsOverride]。
  final List<AsrEncoderBucket>? staticBucketsOverride;

  /// 素材总时长（毫秒；null = 未知），决定装载时的桶预热策略。
  final int? materialMs;

  /// null = 按编码器实际落到的 EP 取 [AsrTranscriptionService.defaultBatchSizeFor]。
  final int? batchSize;
}

class _IsolateArgs {
  const _IsolateArgs({
    required this.events,
    required this.rootIsolateToken,
    required this.spec,
  });

  final SendPort events;
  final RootIsolateToken? rootIsolateToken;
  final AsrIsolateJobSpec spec;
}

class _ControlPortMessage {
  const _ControlPortMessage(this.port);
  final SendPort port;
}

class _LoadedMessage {
  const _LoadedMessage({
    required this.resolution,
    required this.greedyGraphAvailable,
    required this.greedyUnavailableReason,
  });

  final OnnxProviderResolution resolution;
  final bool greedyGraphAvailable;
  final String? greedyUnavailableReason;
}

class _StatsMessage {
  const _StatsMessage(this.stats);
  final AsrDecodeStats stats;
}

class _ErrorMessage {
  const _ErrorMessage(this.message, this.stackTrace);
  final String message;
  final String stackTrace;
}

class _ExitedMessage {
  const _ExitedMessage();
}

const String _kPauseMessage = 'pause';

/// 后台 isolate 里跑的转录（生产路径）。
class AsrIsolateTranscription implements AsrRunningTranscription {
  AsrIsolateTranscription._(
    this._events,
    this._control,
    this._loaded,
    this._exited,
  );

  /// 起 isolate、装载引擎；引擎装好（或装载失败）才返回，与进程内路径的
  /// `start()` 契约一致。
  static Future<AsrIsolateTranscription> spawn(AsrIsolateJobSpec spec) async {
    final ReceivePort events = ReceivePort();
    final Completer<SendPort> control = Completer<SendPort>();
    final Completer<_LoadedMessage> loaded = Completer<_LoadedMessage>();
    final Completer<void> exited = Completer<void>();
    late final AsrIsolateTranscription running;
    events.listen((Object? message) {
      if (message is _ControlPortMessage) {
        if (!control.isCompleted) control.complete(message.port);
        return;
      }
      if (message is _LoadedMessage) {
        if (!loaded.isCompleted) loaded.complete(message);
        return;
      }
      if (message is _ErrorMessage) {
        final StateError error = StateError(message.message);
        final StackTrace stack = StackTrace.fromString(message.stackTrace);
        if (!loaded.isCompleted) {
          loaded.completeError(error, stack);
        } else {
          running._onRunError(error, stack);
        }
        return;
      }
      if (message is _ExitedMessage) {
        if (!exited.isCompleted) exited.complete();
        running._onExited();
        events.close();
        return;
      }
      if (message is List<Object?> && message.length == 2) {
        // Isolate.spawn onError 通道：[error, stackTrace] 字符串对。
        final StateError error = StateError(
          'ASR isolate crashed: ${message[0]}',
        );
        final StackTrace stack = StackTrace.fromString('${message[1]}');
        if (!loaded.isCompleted) loaded.completeError(error, stack);
        running._onRunError(error, stack);
        if (!exited.isCompleted) exited.complete();
        running._onExited();
        events.close();
        return;
      }
      if (message is _StatsMessage) {
        running._stats = message.stats;
        return;
      }
      if (message is AsrTranscribeEvent) {
        running._onEvent(message);
      }
    });
    running = AsrIsolateTranscription._(
      events,
      control.future,
      loaded.future,
      exited.future,
    );
    try {
      await Isolate.spawn<_IsolateArgs>(
        _isolateMain,
        _IsolateArgs(
          events: events.sendPort,
          rootIsolateToken: RootIsolateToken.instance,
          spec: spec,
        ),
        onError: events.sendPort,
        debugName: 'asr_transcribe_job',
      );
      final _LoadedMessage m = await loaded.future;
      running._resolution = m.resolution;
      running._greedyGraphAvailable = m.greedyGraphAvailable;
      running._greedyUnavailableReason = m.greedyUnavailableReason;
      return running;
    } catch (_) {
      events.close();
      rethrow;
    }
  }

  final ReceivePort _events;
  final Future<SendPort> _control;
  // ignore: unused_field — 只为让 spawn() 的等待与实例绑定，便于将来重连。
  final Future<_LoadedMessage> _loaded;
  final Future<void> _exited;

  late OnnxProviderResolution _resolution;
  bool _greedyGraphAvailable = false;
  String? _greedyUnavailableReason;
  AsrDecodeStats? _stats;
  StreamController<AsrTranscribeEvent>? _stream;
  bool _isolateExited = false;
  bool _pauseRequested = false;

  @override
  OnnxProviderResolution get encoderResolution => _resolution;

  @override
  bool get greedyGraphAvailable => _greedyGraphAvailable;

  @override
  String? get greedyUnavailableReason => _greedyUnavailableReason;

  @override
  AsrDecodeStats? get decodeStats => _stats;

  @override
  Stream<AsrTranscribeEvent> run() {
    if (_stream != null) {
      throw StateError('AsrIsolateTranscription.run() 只能调用一次');
    }
    final StreamController<AsrTranscribeEvent> c =
        StreamController<AsrTranscribeEvent>();
    _stream = c;
    if (_isolateExited) c.close();
    return c.stream;
  }

  void _onEvent(AsrTranscribeEvent e) {
    final StreamController<AsrTranscribeEvent>? c = _stream;
    if (c == null || c.isClosed) return;
    c.add(e);
    // 任务流以 finished / paused 收尾（与 AsrTranscribeJob.run 契约一致）。
    if (e is AsrTranscribeFinishedEvent || e is AsrTranscribePausedEvent) {
      c.close();
    }
  }

  void _onRunError(Object error, StackTrace stack) {
    final StreamController<AsrTranscribeEvent>? c = _stream;
    if (c == null || c.isClosed) return;
    c.addError(error, stack);
    c.close();
  }

  void _onExited() {
    _isolateExited = true;
    final StreamController<AsrTranscribeEvent>? c = _stream;
    if (c != null && !c.isClosed) c.close();
  }

  @override
  void requestPause() {
    if (_pauseRequested) return;
    _pauseRequested = true;
    unawaited(_control.then((SendPort port) => port.send(_kPauseMessage)));
  }

  /// 会话归 isolate 所有：这里只能请求暂停并等它在下一个检查点关会话退出；
  /// 不 `Isolate.kill`——那会让 ORT 的 native 会话没人释放。
  @override
  Future<void> dispose() async {
    if (!_isolateExited) {
      requestPause();
      await _exited;
    }
    _events.close();
  }
}

/// isolate 入口：装载引擎 → 跑任务 → 回发事件 → 关会话。
Future<void> _isolateMain(_IsolateArgs args) async {
  final ReceivePort control = ReceivePort();
  AsrTranscribeJob? job;
  bool pauseBeforeStart = false;
  control.listen((Object? message) {
    if (message != _kPauseMessage) return;
    final AsrTranscribeJob? j = job;
    if (j != null) {
      j.requestPause();
    } else {
      pauseBeforeStart = true;
    }
  });
  args.events.send(_ControlPortMessage(control.sendPort));

  final RootIsolateToken? token = args.rootIsolateToken;
  if (token != null) {
    // 让 flutter_onnxruntime 的 MethodChannel 调用可从本后台 isolate 发出。
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }

  final AsrIsolateJobSpec spec = args.spec;
  AsrEngineSessions? sessions;
  try {
    final AsrModelStore store = AsrModelStore(
      Directory(spec.storeDirPath),
      asrModelPackFor(spec.language),
    );
    sessions = await AsrEngineLoader().load(
      store: store,
      variant: spec.variant,
      preference: spec.preference,
      staticBucketsOverride: spec.staticBucketsOverride,
      materialMs: spec.materialMs,
    );
    args.events.send(
      _LoadedMessage(
        resolution: sessions.encoderResolution,
        greedyGraphAvailable: sessions.greedy != null,
        greedyUnavailableReason: sessions.greedyUnavailableReason,
      ),
    );
    final AsrTransducerDecoder decoder = AsrTransducerDecoder(
      encoder: sessions.encoder,
      decoder: sessions.decoder,
      joiner: sessions.joiner,
      tokens: sessions.tokens,
      greedy: sessions.greedy,
      staticEncoders: sessions.staticEncoders,
    );
    // 静态桶模式段切短到 10 s（见 kAsrStaticMaxSegmentMs），否则保持 VAD 默认。
    final int maxSegmentMs = sessions.staticEncoders != null
        ? kAsrStaticMaxSegmentMs
        : kAsrDefaultMaxSegmentMs;
    final AsrTranscribeJob j = AsrTranscribeJob(
      jobDir: Directory(spec.jobDirPath),
      audioPaths: spec.audioPaths,
      modelId: store.pack.id,
      pcm: FfmpegAsrPcmSource(),
      segmenter: switch (spec.segmenterKind) {
        AsrSegmenterKind.energy => AsrVadSegmenter(
          scorer: EnergyVadScorer(),
          maxSegmentMs: maxSegmentMs,
        ),
        AsrSegmenterKind.silero => AsrVadSegmenter(
          session: sessions.vad,
          maxSegmentMs: maxSegmentMs,
        ),
      },
      decoder: decoder,
      batchSize:
          spec.batchSize ??
          AsrTranscriptionService.defaultBatchSizeFor(
            sessions.encoderResolution.effective,
          ),
      chunkSeconds: spec.chunkSeconds,
      statsProvider: () => decoder.stats,
      usePipeline: spec.usePipeline,
    );
    job = j;
    if (pauseBeforeStart) j.requestPause();
    await for (final AsrTranscribeEvent e in j.run()) {
      // 统计先于收尾事件发出：主侧在 finished / paused 一到就读 decodeStats。
      if (e is AsrTranscribeFinishedEvent || e is AsrTranscribePausedEvent) {
        args.events.send(_StatsMessage(decoder.stats));
      }
      args.events.send(e);
    }
  } catch (error, stack) {
    args.events.send(_ErrorMessage('$error', '$stack'));
  } finally {
    try {
      await sessions?.close();
    } catch (_) {
      // 关会话失败没有可做的补救；退出本 isolate 即可。
    }
    args.events.send(const _ExitedMessage());
    control.close();
  }
}
