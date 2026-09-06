/// 把 [AsrPcmSource] 架在两个 isolate 之间：解码在**根 isolate** 做，转录 isolate
/// 只按块拉 PCM。
///
/// 为什么必须这样（BUG-2197）：Android / iOS 的 PCM 解码走 `ffmpeg_kit_flutter`，它的
/// Dart 侧初始化会 `EventChannel.receiveBroadcastStream()`——平台消息处理器只能注册
/// 在根 isolate，后台 isolate 一碰就是 `Unsupported operation: Background isolates
/// do not support setMessageHandler()`。桌面走 ffmpeg 命令行没这一步，所以 Windows
/// 上从来没暴露。与其按平台分叉「哪些平台可以在 isolate 里解码」，不如统一：
/// 平台通道的活一律留在根 isolate，转录 isolate 只做纯 Dart + ORT。
///
/// 协议（一次 [RemoteAsrPcmSource.decode] = 一个 `id`）：
///
/// ```text
/// isolate → host : Open(id, path, startSample, chunkSeconds, replyTo)
///                  Next(id)            要下一块（任务侧预取一块，所以宿主总在解下一块）
///                  Cancel(id)          流关闭 / 出错时清理
///                  Probe(id, path, replyTo)
/// host → isolate  : Chunk(id, startSample, TransferableTypedData)  零拷贝搬样本
///                  Done(id) / Error(id, message, isDecodeException)
///                  ProbeReply(id, ms)
/// ```
///
/// 纯 `dart:isolate`，不依赖 Flutter，可在 `flutter test` 里跨真 isolate 测。
library;

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi/src/asr/asr_types.dart';

class _PcmOpen {
  const _PcmOpen(
    this.id,
    this.path,
    this.startSample,
    this.chunkSeconds,
    this.replyTo,
  );
  final int id;
  final String path;
  final int startSample;
  final int chunkSeconds;
  final SendPort replyTo;
}

class _PcmNext {
  const _PcmNext(this.id);
  final int id;
}

class _PcmCancel {
  const _PcmCancel(this.id);
  final int id;
}

class _PcmProbe {
  const _PcmProbe(this.id, this.path, this.replyTo);
  final int id;
  final String path;
  final SendPort replyTo;
}

class _PcmChunk {
  const _PcmChunk(this.id, this.startSample, this.samples);
  final int id;
  final int startSample;
  final TransferableTypedData samples;
}

class _PcmDone {
  const _PcmDone(this.id);
  final int id;
}

class _PcmError {
  const _PcmError(this.id, this.message, this.path, this.isDecodeException);
  final int id;
  final String message;
  final String path;
  final bool isDecodeException;
}

class _PcmProbeReply {
  const _PcmProbeReply(this.id, this.ms);
  final int id;
  final int? ms;
}

/// 根 isolate 侧：持有真正的 [AsrPcmSource]，应答转录 isolate 的请求。
class AsrPcmBridgeHost {
  AsrPcmBridgeHost(this._source) {
    _requests.listen(_handle);
  }

  final AsrPcmSource _source;
  final ReceivePort _requests = ReceivePort();
  final Map<int, StreamIterator<AsrPcmChunk>> _open =
      <int, StreamIterator<AsrPcmChunk>>{};
  final Map<int, SendPort> _replyTo = <int, SendPort>{};

  /// 交给转录 isolate 的请求端口。
  SendPort get port => _requests.sendPort;

  void _handle(Object? message) {
    switch (message) {
      case _PcmOpen(:final int id):
        _replyTo[id] = message.replyTo;
        _open[id] = StreamIterator<AsrPcmChunk>(
          _source.decode(
            message.path,
            startSample: message.startSample,
            chunkSeconds: message.chunkSeconds,
          ),
        );
      case _PcmNext(:final int id):
        _next(id);
      case _PcmCancel(:final int id):
        _close(id);
      case _PcmProbe(:final int id):
        _source.probeDurationMs(message.path).then<void>(
              (int? ms) => message.replyTo.send(_PcmProbeReply(id, ms)),
              onError: (Object _) =>
                  message.replyTo.send(_PcmProbeReply(id, null)),
            );
    }
  }

  Future<void> _next(int id) async {
    final StreamIterator<AsrPcmChunk>? it = _open[id];
    final SendPort? reply = _replyTo[id];
    if (it == null || reply == null) return;
    try {
      if (!await it.moveNext()) {
        reply.send(_PcmDone(id));
        await _close(id);
        return;
      }
      final Float32List samples = it.current.samples;
      reply.send(
        _PcmChunk(
          id,
          it.current.startSample,
          TransferableTypedData.fromList(<TypedData>[
            samples.buffer.asUint8List(
              samples.offsetInBytes,
              samples.lengthInBytes,
            ),
          ]),
        ),
      );
    } catch (error) {
      reply.send(
        _PcmError(
          id,
          error is AsrPcmDecodeException ? error.message : '$error',
          error is AsrPcmDecodeException ? error.audioPath : '',
          error is AsrPcmDecodeException,
        ),
      );
      await _close(id);
    }
  }

  Future<void> _close(int id) async {
    final StreamIterator<AsrPcmChunk>? it = _open.remove(id);
    _replyTo.remove(id);
    if (it != null) await it.cancel();
  }

  /// 转录 isolate 退出后关端口、取消还开着的流。
  Future<void> close() async {
    _requests.close();
    for (final int id in _open.keys.toList()) {
      await _close(id);
    }
  }
}

/// 转录 isolate 侧的 [AsrPcmSource]：所有请求经 [hostPort] 发给
/// [AsrPcmBridgeHost]，样本以 [TransferableTypedData] 零拷贝接收。
class RemoteAsrPcmSource implements AsrPcmSource {
  RemoteAsrPcmSource(this._host) {
    _replies.listen(_onReply);
  }

  final SendPort _host;
  final ReceivePort _replies = ReceivePort();
  final Map<int, Completer<Object?>> _waiting = <int, Completer<Object?>>{};
  int _nextId = 0;

  void _onReply(Object? message) {
    final int id = switch (message) {
      _PcmChunk(:final int id) => id,
      _PcmDone(:final int id) => id,
      _PcmError(:final int id) => id,
      _PcmProbeReply(:final int id) => id,
      _ => -1,
    };
    final Completer<Object?>? c = _waiting.remove(id);
    if (c != null && !c.isCompleted) c.complete(message);
  }

  Future<Object?> _await(int id) {
    final Completer<Object?> c = Completer<Object?>();
    _waiting[id] = c;
    return c.future;
  }

  @override
  Future<int?> probeDurationMs(String audioPath) async {
    final int id = _nextId++;
    final Future<Object?> reply = _await(id);
    _host.send(_PcmProbe(id, audioPath, _replies.sendPort));
    return ((await reply) as _PcmProbeReply).ms;
  }

  @override
  Stream<AsrPcmChunk> decode(
    String audioPath, {
    int startSample = 0,
    int chunkSeconds = 600,
  }) async* {
    final int id = _nextId++;
    _host.send(
      _PcmOpen(id, audioPath, startSample, chunkSeconds, _replies.sendPort),
    );
    try {
      while (true) {
        final Future<Object?> reply = _await(id);
        _host.send(_PcmNext(id));
        final Object? r = await reply;
        switch (r) {
          case _PcmDone():
            return;
          case _PcmError(:final String message, :final String path):
            if (r.isDecodeException) throw AsrPcmDecodeException(path, message);
            throw StateError('PCM bridge: $message');
          case _PcmChunk(
              :final int startSample,
              :final TransferableTypedData samples
            ):
            yield AsrPcmChunk(
              startSample: startSample,
              samples: samples.materialize().asFloat32List(),
            );
          default:
            throw StateError('PCM bridge: unexpected reply $r');
        }
      }
    } finally {
      _waiting.remove(id);
      _host.send(_PcmCancel(id));
    }
  }

  void close() => _replies.close();
}
