import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';

/// 分析引擎事件种类（与 native/fushi_compute/src/music_analysis.rs 的 `EVENT_*` 一致）。
enum FfcManaEventKind {
  /// 出队、开始分析。
  started(1),

  /// 进度：[FfcManaEvent.stage] / [FfcManaEvent.permille]。
  progress(2),

  /// 一步做完、结果文件已更新：[FfcManaEvent.flags]。
  updated(3),

  /// 全部做完：[FfcManaEvent.flags]。
  done(4),

  /// 失败（原因见 [FushiComputeMusicAnalysis.takeLastError]）。
  failed(5),

  /// 取消。
  cancelled(6),

  /// 模型那一步失败、结果留 DSP 的（之后照常 [done]）。
  modelFailed(7),

  /// 加速执行器不行、这个模型改用 CPU（结果不受影响）：[FfcManaEvent.value] = 失败的执行器代码
  /// （同 `FfcUpscaleBackend.code`）。每进程每模型每执行器一次；原因见 [FushiComputeMusicAnalysis.takeLastError]。
  backendFallback(8);

  const FfcManaEventKind(this.code);

  final int code;

  static FfcManaEventKind? fromCode(int code) {
    for (final FfcManaEventKind k in values) {
      if (k.code == code) return k;
    }
    return null;
  }
}

/// 分析步骤（进度事件里带）。
enum FfcManaStage {
  /// DSP：包络 / 退路节拍 / HPSS 鼓点（总跑，几秒）。
  dsp(1),

  /// Beat This! 拍点（模型在时）。
  beats(2),

  /// htdemucs 分轨：鼓点 / 人声（模型在时，CPU 上约为歌长的 1/4）。
  stems(3);

  const FfcManaStage(this.code);

  final int code;

  static FfcManaStage? fromCode(int code) {
    for (final FfcManaStage s in values) {
      if (s.code == code) return s;
    }
    return null;
  }
}

/// 结果文件 flags（与 native `format::FLAG_*` 一致）。
abstract final class FfcManaFlags {
  /// 拍点来自 Beat This!。
  static const int beatsModel = 1 << 0;

  /// 鼓点来自 htdemucs 鼓轨。
  static const int drumsModel = 1 << 1;

  /// 人声来自 htdemucs 人声轨。
  static const int vocalModel = 1 << 2;

  /// 判为没鼓的歌。
  static const int drumless = 1 << 3;

  /// htdemucs 还在分：鼓点 / 人声只覆盖到结果头里的 `stems_until_ms`（之后仍是 DSP 的），文件会继续刷新。
  static const int stemsPartial = 1 << 4;
}

/// 提交标志（与 native `SUBMIT_*` 一致）。
abstract final class FfcManaSubmitFlags {
  /// 插到队头（正在播的那首）。
  static const int urgent = 1;

  /// 做完删掉输入的 PCM 临时文件。
  static const int deleteInput = 2;

  /// 只跑 DSP。
  static const int dspOnly = 4;
}

/// 原生返回码（本域）。
abstract final class FfcManaStatus {
  /// ORT 接不上：模型被禁用，只剩 DSP。
  static const int runtimeUnavailable = -20;

  /// 引擎没启动。
  static const int notStarted = -21;

  /// 取消：令牌不认识（已做完 / 从没提交）。
  static const int unknownToken = 1;
}

/// 引擎事件。
class FfcManaEvent {
  const FfcManaEvent(this.kind, this.token, this.value);

  final FfcManaEventKind kind;
  final int token;
  final int value;

  /// [FfcManaEventKind.progress] 的步骤。
  FfcManaStage? get stage => FfcManaStage.fromCode(value >> 16);

  /// [FfcManaEventKind.progress] 的千分比。
  int get permille => value & 0xFFFF;

  /// [FfcManaEventKind.updated] / [FfcManaEventKind.done] 的结果 flags。
  int get flags => value;

  @override
  String toString() => 'FfcManaEvent($kind, $token, $value)';
}

typedef _Callback = Void Function(Int32, Uint64, Uint32);
typedef _VersionC = Uint32 Function();
typedef _VersionDart = int Function();
typedef _StartC = Int32 Function(Pointer<NativeFunction<_Callback>>);
typedef _StartDart = int Function(Pointer<NativeFunction<_Callback>>);
typedef _ConfigureC =
    Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Uint32, Uint32);
typedef _ConfigureDart =
    int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, int, int);
typedef _SubmitC = Int32 Function(Uint64, Pointer<Utf8>, Pointer<Utf8>, Uint32);
typedef _SubmitDart = int Function(int, Pointer<Utf8>, Pointer<Utf8>, int);
typedef _CancelC = Int32 Function(Uint64);
typedef _CancelDart = int Function(int);
typedef _AnalyzeC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32);
typedef _AnalyzeDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _LastErrorC = Int32 Function(Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _LastErrorDart = int Function(Pointer<Pointer<Uint8>>, Pointer<Size>);

/// 整首离线音频分析引擎的 Dart 绑定（native `ffc_mana_*`）。
///
/// 引擎在 Rust 里是进程级单例（工作线程 + 队列 + 可选 ONNX 模型）；这里只发粗粒度命令，事件经一个
/// `NativeCallable.listener` 回到本 isolate 的 [events]。结果是文件（`.fma`），由调用方整份读进来解析，
/// 逐帧取值不跨 FFI。只应在一个 isolate（UI isolate）里用。
class FushiComputeMusicAnalysis {
  FushiComputeMusicAnalysis._(FushiCompute lib)
    : _lib = lib,
      _formatVersion = lib.library.lookupFunction<_VersionC, _VersionDart>(
        'ffc_mana_format_version',
      ),
      _pipelineVersion = lib.library.lookupFunction<_VersionC, _VersionDart>(
        'ffc_mana_pipeline_version',
      ),
      _start = lib.library.lookupFunction<_StartC, _StartDart>(
        'ffc_mana_start',
      ),
      _configure = lib.library.lookupFunction<_ConfigureC, _ConfigureDart>(
        'ffc_mana_configure',
      ),
      _submit = lib.library.lookupFunction<_SubmitC, _SubmitDart>(
        'ffc_mana_submit',
      ),
      _cancel = lib.library.lookupFunction<_CancelC, _CancelDart>(
        'ffc_mana_cancel',
      ),
      _analyze = lib.library.lookupFunction<_AnalyzeC, _AnalyzeDart>(
        'ffc_mana_analyze_file',
      ),
      _lastError = lib.library.lookupFunction<_LastErrorC, _LastErrorDart>(
        'ffc_mana_last_error',
      );

  final FushiCompute _lib;
  final _VersionDart _formatVersion;
  final _VersionDart _pipelineVersion;
  final _StartDart _start;
  final _ConfigureDart _configure;
  final _SubmitDart _submit;
  final _CancelDart _cancel;
  final _AnalyzeDart _analyze;
  final _LastErrorDart _lastError;

  static FushiComputeMusicAnalysis? _instance;

  /// 默认库上的绑定。库不可用或缺符号抛 [FushiComputeUnavailableError]。
  static FushiComputeMusicAnalysis get instance =>
      _instance ??= _bind(FushiCompute.require());

  static FushiComputeMusicAnalysis _bind(FushiCompute lib) {
    try {
      return FushiComputeMusicAnalysis._(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('music_analysis', e.message ?? e);
    }
  }

  final StreamController<FfcManaEvent> _events =
      StreamController<FfcManaEvent>.broadcast();

  // 进程级引擎的回调：建一次、永不关闭（Rust 工作线程随时可能调它）。
  NativeCallable<_Callback>? _callback;

  /// 引擎事件（广播）。
  Stream<FfcManaEvent> get events => _events.stream;

  void _onEvent(int kind, int token, int value) {
    final FfcManaEventKind? k = FfcManaEventKind.fromCode(kind);
    if (k != null) _events.add(FfcManaEvent(k, token, value));
  }

  /// 结果文件布局版本（Dart 解析器据此拒读不认识的文件）。
  int get formatVersion => _formatVersion();

  /// 分析算法版本（缓存失效判据）。
  int get pipelineVersion => _pipelineVersion();

  /// 启动引擎（幂等）。返回原生状态码。
  int start() {
    final NativeCallable<_Callback> callback = _callback ??=
        NativeCallable<_Callback>.listener(_onEvent);
    return _start(callback.nativeFunction);
  }

  /// 配置可选模型（null = 不用）。有模型时接上 [ortPath] 那份 onnxruntime（null = 从本进程符号找，Apple）；
  /// 接不上返回 [FfcManaStatus.runtimeUnavailable]，引擎只跑 DSP。
  ///
  /// [backend] 与超分同一套代码（`FfcUpscaleBackend.code`：0 CPU / 1 DirectML / 2 CoreML / 3 XNNPACK）：
  /// 这份 ORT 里没有就静默用 CPU；建会话或跑模型失败就退回 CPU 并发一次 [FfcManaEventKind.backendFallback]。
  int configure({
    required String? ortPath,
    required String? beatThisModel,
    required String? htdemucsModel,
    required int threads,
    int backend = 0,
  }) => using(
    (Arena arena) => _configure(
      ortPath == null ? nullptr : ortPath.toNativeUtf8(allocator: arena),
      beatThisModel == null
          ? nullptr
          : beatThisModel.toNativeUtf8(allocator: arena),
      htdemucsModel == null
          ? nullptr
          : htdemucsModel.toNativeUtf8(allocator: arena),
      threads < 1 ? 1 : threads,
      backend,
    ),
  );

  /// 提交一首（[pcmPath] 是 44.1 kHz 立体声 s16le raw；结果写 [outPath]）。之后必有一个带 [token] 的
  /// done / failed / cancelled 事件。返回原生状态码。
  int submit({
    required int token,
    required String pcmPath,
    required String outPath,
    int flags = 0,
  }) => using(
    (Arena arena) => _submit(
      token,
      pcmPath.toNativeUtf8(allocator: arena),
      outPath.toNativeUtf8(allocator: arena),
      flags,
    ),
  );

  /// 取消（排队的立即发 cancelled；在跑的到下一个检查点停）。不认识的令牌返回
  /// [FfcManaStatus.unknownToken]。
  int cancel(int token) => _cancel(token);

  /// 同步分析（不进队列、不发事件，用当前模型配置）：后台 isolate / 无头 / 测试用。返回原生状态码。
  int analyzeFileSync({
    required String pcmPath,
    required String outPath,
    int flags = 0,
  }) => using(
    (Arena arena) => _analyze(
      pcmPath.toNativeUtf8(allocator: arena),
      outPath.toNativeUtf8(allocator: arena),
      flags,
    ),
  );

  /// 引擎最近一条错误。
  String? takeLastError() {
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    try {
      if (_lastError(outPtr, outLen) != FfcStatus.ok) return null;
      final Pointer<Uint8> data = outPtr.value;
      final int n = outLen.value;
      try {
        return n == 0
            ? null
            : utf8.decode(data.asTypedListOutOfLine(n), allowMalformed: true);
      } finally {
        _lib.freeBytes(data, n);
      }
    } finally {
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }
}
