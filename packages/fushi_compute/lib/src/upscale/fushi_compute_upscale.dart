import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_events/native_event_port.dart';

/// 超分档（与 native/fushi_compute/src/upscale/pipeline.rs 的 `Tier` 一致）。
enum FfcUpscaleTier {
  /// 框外 ArtCNN C4F32、框内 Catmull-Rom；没有文字框的页跳过。
  light(1),

  /// 框外 waifu2x swin_unet art noise1、框内 swin_unet art scale2x；没有文字框整页 scale2x。
  high(2);

  const FfcUpscaleTier(this.code);

  final int code;
}

/// 推理后端（与 native `Backend` 一致）。
enum FfcUpscaleBackend {
  cpu(0),
  directMl(1),
  coreMl(2),
  xnnpack(3);

  const FfcUpscaleBackend(this.code);

  final int code;
}

/// 引擎事件种类（与 native `EVENT_*` 一致）。
enum FfcUpscaleEventKind {
  /// 完成，结果在缓存里（[FushiComputeUpscale.cachedPath]）。
  done(1),

  /// 这页不做（轻量档没有文字框 / 太大），继续用画质缩放。
  skipped(2),

  /// 失败（坏图 / 推理出错）。
  failed(3),

  /// 任务被丢弃（翻走了 / 同键替换 / 清队列）。
  cancelled(4),

  /// 某一代配置的模型加载失败（token = 那一代的代际，见 [FushiComputeUpscale.configure]）。只在它等于
  /// 自己启用时拿到的代际才按「不可用」处理：换档后旧代迟到的失败不属于新档。
  modelsFailed(5);

  const FfcUpscaleEventKind(this.code);

  final int code;

  static FfcUpscaleEventKind? fromCode(int code) {
    for (final FfcUpscaleEventKind k in values) {
      if (k.code == code) return k;
    }
    return null;
  }
}

/// 引擎事件：[token] 是提交时给的值。
class FfcUpscaleEvent {
  const FfcUpscaleEvent(this.kind, this.token);

  final FfcUpscaleEventKind kind;
  final int token;

  @override
  String toString() => 'FfcUpscaleEvent($kind, $token)';
}

/// [FushiComputeUpscale.submit] 的结果。
enum FfcUpscaleSubmit {
  /// 入队，之后必有一个带同一 token 的事件。
  queued,

  /// 缓存里已经有了（不入队、不发事件）。
  alreadyCached,

  /// 同键任务正在算（不重复入队；完成事件带先前那次提交的令牌）。
  inProgress,

  /// 本配置下已判过不做 / 失败过（不入队、不发事件）。
  settled,

  /// 引擎没启动 / 没配置档位。
  notReady,
}

/// 原生返回码（upscale 域专用）。
abstract final class FfcUpscaleStatus {
  static const int runtimeUnavailable = -20;
  static const int notReady = -21;
  static const int notCached = -22;
  static const int unsupported = -23;
  static const int alreadyCached = 1;
  static const int inProgress = 2;
  static const int settled = 3;
}

/// 引擎对一个缓存键的认知（[FushiComputeUpscale.query]）。
enum FfcUpscaleKeyState {
  /// 没启动 / 没配置。
  notReady,

  /// 一无所知：该读原图提交。
  unknown,

  /// 结果在缓存里。
  cached,

  /// 在队列里或正在算。
  pending,

  /// 本配置下判过不做。
  skipped,

  /// 本配置下失败过（不自动重试）。
  failed,
}

typedef _StartC =
    Int32 Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Uint64,
      Pointer<NativeFunction<PostCObjectNative>>,
      Int64,
    );
typedef _StartDart =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      int,
      Pointer<NativeFunction<PostCObjectNative>>,
      int,
    );
typedef _AvailC = Int32 Function(Uint32);
typedef _AvailDart = int Function(int);
typedef _TierSupportedC = Int32 Function(Uint32, Uint32);
typedef _TierSupportedDart = int Function(int, int);
typedef _ConfigureC =
    Int32 Function(
      Uint32,
      Uint32,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Uint64>,
    );
typedef _ConfigureDart =
    int Function(int, int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint64>);
typedef _SubmitC =
    Int32 Function(
      Uint64,
      Pointer<Utf8>,
      Int32,
      Pointer<Uint8>,
      Size,
      Pointer<Float>,
      Size,
    );
typedef _SubmitDart =
    int Function(
      int,
      Pointer<Utf8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Float>,
      int,
    );
typedef _QueryC = Int32 Function(Pointer<Utf8>);
typedef _QueryDart = int Function(Pointer<Utf8>);
typedef _FocusC = Int32 Function(Int32, Uint32);
typedef _FocusDart = int Function(int, int);
typedef _ClearC = Int32 Function();
typedef _ClearDart = int Function();
typedef _CachedC =
    Int32 Function(Pointer<Utf8>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _CachedDart =
    int Function(Pointer<Utf8>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _LastErrorC = Int32 Function(Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _LastErrorDart = int Function(Pointer<Pointer<Uint8>>, Pointer<Size>);

/// 漫画页超分引擎的 Dart 绑定（设计文档 `docs/specs/2026-11-20-manga-upscale-design.md` §4）。
///
/// 引擎在 Rust 里是**进程级单例**：持有 ORT 运行时、模型会话、任务队列（含往后预取）、磁盘 LRU
/// 与工作线程；这里只发粗粒度命令，事件经一个 [NativeEventPort] 回到本 isolate 的 [events]，
/// 不存镜像状态。只应在一个 isolate（UI isolate）里用。
class FushiComputeUpscale {
  FushiComputeUpscale._(FushiCompute lib)
    : _lib = lib,
      _start = lib.library.lookupFunction<_StartC, _StartDart>(
        'ffc_upscale_start',
      ),
      _available = lib.library.lookupFunction<_AvailC, _AvailDart>(
        'ffc_upscale_backend_available',
      ),
      _tierSupported = lib.library
          .lookupFunction<_TierSupportedC, _TierSupportedDart>(
            'ffc_upscale_tier_supported',
          ),
      _configure = lib.library.lookupFunction<_ConfigureC, _ConfigureDart>(
        'ffc_upscale_configure',
      ),
      _submit = lib.library.lookupFunction<_SubmitC, _SubmitDart>(
        'ffc_upscale_submit',
      ),
      _query = lib.library.lookupFunction<_QueryC, _QueryDart>(
        'ffc_upscale_query',
      ),
      _focus = lib.library.lookupFunction<_FocusC, _FocusDart>(
        'ffc_upscale_focus',
      ),
      _clear = lib.library.lookupFunction<_ClearC, _ClearDart>(
        'ffc_upscale_clear',
      ),
      _cached = lib.library.lookupFunction<_CachedC, _CachedDart>(
        'ffc_upscale_cached_path',
      ),
      _lastError = lib.library.lookupFunction<_LastErrorC, _LastErrorDart>(
        'ffc_upscale_last_error',
      );

  final FushiCompute _lib;
  final _StartDart _start;
  final _AvailDart _available;
  final _TierSupportedDart _tierSupported;
  final _ConfigureDart _configure;
  final _SubmitDart _submit;
  final _QueryDart _query;
  final _FocusDart _focus;
  final _ClearDart _clear;
  final _CachedDart _cached;
  final _LastErrorDart _lastError;

  static FushiComputeUpscale? _instance;

  /// 默认库上的绑定。库不可用或缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputeUpscale get instance =>
      _instance ??= _bind(FushiCompute.require());

  static FushiComputeUpscale _bind(FushiCompute lib) {
    try {
      return FushiComputeUpscale._(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('upscale', e.message ?? e);
    }
  }

  final StreamController<FfcUpscaleEvent> _events =
      StreamController<FfcUpscaleEvent>.broadcast();

  // 进程级引擎的事件端口：建一次、永不关闭（Rust 工作线程随时可能发事件）。本 isolate 没了时
  // 发过来的事件只是丢掉，不会像 NativeCallable 那样让进程 abort（BUG-5413）。
  NativeEventPort? _port;

  /// 引擎事件（广播）。
  Stream<FfcUpscaleEvent> get events => _events.stream;

  void _onEvent(List<int> message) {
    if (message.length != 2) return;
    final FfcUpscaleEventKind? k = FfcUpscaleEventKind.fromCode(message[0]);
    if (k != null) _events.add(FfcUpscaleEvent(k, message[1]));
  }

  /// 启动（或更新）引擎。[ortPath] 是本进程那份 onnxruntime 动态库；null = 从本进程符号找（Apple）。
  /// 返回原生状态码：[FfcStatus.ok]、[FfcUpscaleStatus.runtimeUnavailable]（ORT 接不上）等。
  int start({
    required String? ortPath,
    required String cacheDir,
    required int cacheBytes,
  }) {
    final NativeEventPort port = _port ??= NativeEventPort(_onEvent);
    return using((Arena arena) {
      return _start(
        ortPath == null ? nullptr : ortPath.toNativeUtf8(allocator: arena),
        cacheDir.toNativeUtf8(allocator: arena),
        cacheBytes,
        port.post,
        port.nativePort,
      );
    });
  }

  /// 已接上的 ORT 能不能用 [backend]。
  bool backendAvailable(FfcUpscaleBackend backend) =>
      _available(backend.code) == 1;

  /// [tier] 在 [backend] 上能不能跑（引擎的实测结论：高质量档只在 DirectML 上）。下载模型前据此降档。
  bool tierSupported(FfcUpscaleTier tier, FfcUpscaleBackend backend) =>
      _tierSupported(tier.code, backend.code) == 1;

  /// 配置档位与模型文件；配置变了，引擎在下一页之前重载模型（并丢掉旧配置排队的任务）。
  ///
  /// 返回原生状态码与生效的配置代际：配置变了（或这代模型加载失败过、重新启用）代际加一，否则不变。
  /// [FfcUpscaleEventKind.modelsFailed] 的 token 就是失败的那一代。
  ({int status, int generation}) configure({
    required FfcUpscaleTier tier,
    required FfcUpscaleBackend backend,
    required String? insideModel,
    required String outsideModel,
  }) {
    return using((Arena arena) {
      final Pointer<Uint64> generation = arena<Uint64>();
      final int status = _configure(
        tier.code,
        backend.code,
        insideModel == null
            ? nullptr
            : insideModel.toNativeUtf8(allocator: arena),
        outsideModel.toNativeUtf8(allocator: arena),
        generation,
      );
      return (status: status, generation: generation.value);
    });
  }

  /// 提交一页。[key] 由调用方保证含页身份、档位、文字框签名与模型版本；[page] 排优先级；
  /// [boxes] 是归一化 `[x0, y0, x1, y1]…`。
  FfcUpscaleSubmit submit({
    required int token,
    required String key,
    required int page,
    required Uint8List data,
    Float32List? boxes,
  }) {
    if (data.isEmpty) throw ArgumentError.value(data.length, 'data');
    final int floats = boxes?.length ?? 0;
    if (floats % 4 != 0) throw ArgumentError.value(floats, 'boxes');
    final Pointer<Uint8> dataPtr = malloc<Uint8>(data.length);
    final Pointer<Float> boxPtr = floats == 0 ? nullptr : malloc<Float>(floats);
    try {
      dataPtr.asTypedListOutOfLine(data.length).setAll(0, data);
      if (floats > 0) boxPtr.asTypedListOutOfLine(floats).setAll(0, boxes!);
      final int status = using(
        (Arena arena) => _submit(
          token,
          key.toNativeUtf8(allocator: arena),
          page,
          dataPtr,
          data.length,
          boxPtr,
          floats ~/ 4,
        ),
      );
      return switch (status) {
        FfcStatus.ok => FfcUpscaleSubmit.queued,
        FfcUpscaleStatus.alreadyCached => FfcUpscaleSubmit.alreadyCached,
        FfcUpscaleStatus.notReady => FfcUpscaleSubmit.notReady,
        FfcUpscaleStatus.inProgress => FfcUpscaleSubmit.inProgress,
        FfcUpscaleStatus.settled => FfcUpscaleSubmit.settled,
        _ => throw StateError('ffc_upscale_submit failed: status $status'),
      };
    } finally {
      malloc.free(dataPtr);
      if (boxPtr != nullptr) malloc.free(boxPtr);
    }
  }

  /// 引擎对 [key] 的认知；据此决定要不要读原图来 [submit]。
  FfcUpscaleKeyState query(String key) {
    final int status = using(
      (Arena arena) => _query(key.toNativeUtf8(allocator: arena)),
    );
    return switch (status) {
      0 => FfcUpscaleKeyState.unknown,
      1 => FfcUpscaleKeyState.cached,
      2 => FfcUpscaleKeyState.pending,
      3 => FfcUpscaleKeyState.skipped,
      4 => FfcUpscaleKeyState.failed,
      FfcUpscaleStatus.notReady => FfcUpscaleKeyState.notReady,
      _ => throw StateError('ffc_upscale_query failed: status $status'),
    };
  }

  /// 换当前页与往后预取页数；窗口外的任务丢弃。
  void focus(int page, int window) => _focus(page, window);

  /// 清空队列。
  void clear() => _clear();

  /// 缓存命中时返回结果 JPEG 的路径（并刷新为最近使用）。
  String? cachedPath(String key) {
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    try {
      final int status = using(
        (Arena arena) =>
            _cached(key.toNativeUtf8(allocator: arena), outPtr, outLen),
      );
      if (status != FfcStatus.ok) return null;
      final Pointer<Uint8> data = outPtr.value;
      final int n = outLen.value;
      try {
        return utf8.decode(data.asTypedListOutOfLine(n));
      } finally {
        _lib.freeBytes(data, n);
      }
    } finally {
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }

  /// 取走引擎最近一条错误（原生线程里出的错只回一个事件码，原因从这里拿）。
  String? takeLastError() {
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    try {
      if (_lastError(outPtr, outLen) != FfcStatus.ok) return null;
      final Pointer<Uint8> data = outPtr.value;
      final int n = outLen.value;
      try {
        return utf8.decode(data.asTypedListOutOfLine(n), allowMalformed: true);
      } finally {
        _lib.freeBytes(data, n);
      }
    } finally {
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }
}
