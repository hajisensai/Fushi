/// 留在推理后端的张量句柄：自回归解码的 KV cache 不必每步在 Dart 与原生之间搬运。
///
/// 为什么需要：app 的 ONNX 经 Flutter 插件（MethodChannel）调用，[OcrSession.run]
/// 每次把全部输入上传、把全部输出读回 Dart。manga-ocr 无 cache 路径每个文字块约有
/// 58 MB 过通道；KV cache 版每步的 past / cross K/V 若照样来回搬，省下的计算又被
/// 通道拷贝吃回去（2026-09-23 Baberu 在 app 内比 Python 慢数倍就是这个原因）。
/// 插件自己的 `OrtValue` 本就是原生侧句柄，本文件把这个能力以可选接口的形式
/// 暴露给引擎：实现了 [OcrHandleSession] 的后端把句柄留在原生侧；没实现的后端
/// （服务端 FFI、测试 fake）经 [asOcrHandleSession] 包成拷贝适配器，结果相同只是
/// 慢——FFI 在进程内拷贝本来就便宜。
library;

import 'package:fushi_engine/ocr/ocr_inference.dart';

/// 一份留在推理后端的张量。只能原样喂回**同一个后端**的会话；用完调 [dispose]。
abstract interface class OcrTensorHandle {
  List<int> get shape;

  /// 释放后端占用（幂等）。
  Future<void> dispose();
}

/// 一次句柄式运行的结果：[fetched] 是读回 Dart 的输出（后端已释放），[kept] 是
/// 留在后端的输出——调用方负责逐个 [OcrTensorHandle.dispose]。
class OcrHandleRunResult {
  const OcrHandleRunResult({required this.fetched, required this.kept});

  final Map<String, OcrTensor> fetched;
  final Map<String, OcrTensorHandle> kept;
}

/// 可选能力：输出可以留在后端、只按名读回需要的那几个。
abstract interface class OcrHandleSession implements OcrSession {
  /// 把一份张量上传成句柄（整轮解码复用的常量，如首步占位 past）。
  Future<OcrTensorHandle> upload(OcrTensor tensor);

  /// [tensors] 本次上传、用完即释放；[handles] 是本后端已有的句柄，不释放。
  /// [fetch] 里的输出读回 Dart，其余输出作为句柄交给调用方。
  Future<OcrHandleRunResult> runWithHandles({
    Map<String, OcrTensor> tensors = const <String, OcrTensor>{},
    Map<String, OcrTensorHandle> handles = const <String, OcrTensorHandle>{},
    required Set<String> fetch,
  });
}

/// 后端支持句柄就原样返回，否则包一层在 Dart 内存里模拟句柄的拷贝适配器。
OcrHandleSession asOcrHandleSession(OcrSession session) =>
    session is OcrHandleSession ? session : _CopyingHandleSession(session);

/// 拷贝适配器的「句柄」：就是一份 Dart 侧张量。
class _CopiedTensorHandle implements OcrTensorHandle {
  _CopiedTensorHandle(this.tensor);

  final OcrTensor tensor;

  @override
  List<int> get shape => tensor.shape;

  @override
  Future<void> dispose() async {}
}

class _CopyingHandleSession implements OcrHandleSession {
  _CopyingHandleSession(this._inner);

  final OcrSession _inner;

  @override
  Future<OcrTensorHandle> upload(OcrTensor tensor) async =>
      _CopiedTensorHandle(tensor);

  @override
  Future<OcrHandleRunResult> runWithHandles({
    Map<String, OcrTensor> tensors = const <String, OcrTensor>{},
    Map<String, OcrTensorHandle> handles = const <String, OcrTensorHandle>{},
    required Set<String> fetch,
  }) async {
    final Map<String, OcrTensor> inputs = <String, OcrTensor>{...tensors};
    for (final MapEntry<String, OcrTensorHandle> entry in handles.entries) {
      final OcrTensorHandle handle = entry.value;
      if (handle is! _CopiedTensorHandle) {
        throw ArgumentError.value(
          handle,
          entry.key,
          'handle belongs to a different inference backend',
        );
      }
      inputs[entry.key] = handle.tensor;
    }
    final Map<String, OcrTensor> outputs = await _inner.run(inputs);
    return OcrHandleRunResult(
      fetched: <String, OcrTensor>{
        for (final MapEntry<String, OcrTensor> entry in outputs.entries)
          if (fetch.contains(entry.key)) entry.key: entry.value,
      },
      kept: <String, OcrTensorHandle>{
        for (final MapEntry<String, OcrTensor> entry in outputs.entries)
          if (!fetch.contains(entry.key))
            entry.key: _CopiedTensorHandle(entry.value),
      },
    );
  }

  @override
  Future<Map<String, OcrTensor>> run(Map<String, OcrTensor> inputs) =>
      _inner.run(inputs);

  @override
  Future<void> close() => _inner.close();
}
