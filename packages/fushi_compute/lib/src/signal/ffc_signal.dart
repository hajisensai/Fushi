import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _XcorrC =
    Int32 Function(
      Pointer<Double>,
      Size,
      Pointer<Double>,
      Size,
      Int64,
      Int64,
      Pointer<Int32>,
      Pointer<Int64>,
      Pointer<Double>,
    );
typedef _XcorrDart =
    int Function(
      Pointer<Double>,
      int,
      Pointer<Double>,
      int,
      int,
      int,
      Pointer<Int32>,
      Pointer<Int64>,
      Pointer<Double>,
    );
typedef _PcmRmsC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Int64,
      Int64,
      Int64,
      Int32,
      Int64,
      Double,
      Pointer<Double>,
      Size,
      Pointer<Size>,
    );
typedef _PcmRmsDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      int,
      int,
      int,
      int,
      double,
      Pointer<Double>,
      int,
      Pointer<Size>,
    );
typedef _ParseLogC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Double,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ParseLogDart =
    int Function(
      Pointer<Uint8>,
      int,
      double,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _DbToAmpC = Int32 Function(Pointer<Double>, Pointer<Double>, Size);
typedef _DbToAmpDart = int Function(Pointer<Double>, Pointer<Double>, int);
typedef _DownsampleC =
    Int32 Function(
      Pointer<Double>,
      Size,
      Int64,
      Double,
      Pointer<Double>,
      Size,
      Pointer<Size>,
    );
typedef _DownsampleDart =
    int Function(
      Pointer<Double>,
      int,
      int,
      double,
      Pointer<Double>,
      int,
      Pointer<Size>,
    );

/// native/fushi_compute/src/signal.rs 的 `ffc_signal_*` 绑定（每个库实例 lookup 一次）。
///
/// lookup 名写成字符串字面量：`native/fushi_compute/verify_abi.sh` 从这里抓期望符号集。
final class _SignalBindings {
  _SignalBindings._(DynamicLibrary lib)
    : xcorr = lib.lookupFunction<_XcorrC, _XcorrDart>(
        'ffc_signal_xcorr_best_shift',
      ),
      pcmRms = lib.lookupFunction<_PcmRmsC, _PcmRmsDart>(
        'ffc_signal_pcm_rms_db',
      ),
      parseLog = lib.lookupFunction<_ParseLogC, _ParseLogDart>(
        'ffc_signal_parse_rms_log',
      ),
      dbToAmp = lib.lookupFunction<_DbToAmpC, _DbToAmpDart>(
        'ffc_signal_db_to_amplitude',
      ),
      downsample = lib.lookupFunction<_DownsampleC, _DownsampleDart>(
        'ffc_signal_downsample_peaks',
      );

  final _XcorrDart xcorr;
  final _PcmRmsDart pcmRms;
  final _ParseLogDart parseLog;
  final _DbToAmpDart dbToAmp;
  final _DownsampleDart downsample;

  static final Expando<_SignalBindings> _cache = Expando<_SignalBindings>();

  /// 缺信号域符号（库比绑定旧）抛 [FushiComputeUnavailableError]。
  static _SignalBindings of(FushiCompute? library) {
    final FushiCompute compute = library ?? FushiCompute.require();
    final _SignalBindings? cached = _cache[compute];
    if (cached != null) return cached;
    try {
      return _cache[compute] = _SignalBindings._(compute.library);
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('signal', e.message ?? e);
    }
  }
}

void _check(int status, String what) {
  if (status == FfcStatus.ok) return;
  if (status == FfcStatus.invalidArgument) {
    throw ArgumentError('fushi_compute $what: invalid argument');
  }
  throw StateError('fushi_compute $what failed: status $status');
}

/// 把 [values] 拷进 [arena] 分配的原生 f64 数组（空列表也给一个非空指针）。
Pointer<Double> _doublesIn(Arena arena, List<double> values) {
  final Pointer<Double> ptr = arena<Double>(values.isEmpty ? 1 : values.length);
  if (values.isNotEmpty)
    ptr.asTypedListOutOfLine(values.length).setAll(0, values);
  return ptr;
}

/// 字幕自动对轴的互相关峰值：在 ±[maxShiftMs] 内滑动 [cue] 活动序列，找与 [audio]
/// 重叠最大的平移（格数，正 = 字幕延后；平手取 |shift| 小者）与归一化置信度（0..1）。
///
/// 输入不足（[binMs] <= 0、任一序列为空或没有 > 0 的格、[maxShiftMs] < 0）返回 null。
/// 库不可用抛 [FushiComputeUnavailableError]。
({int shiftBins, double confidence})? ffcXcorrBestShift(
  List<double> audio,
  List<double> cue, {
  required int binMs,
  required int maxShiftMs,
  FushiCompute? library,
}) {
  final _SignalBindings b = _SignalBindings.of(library);
  return using((Arena arena) {
    final Pointer<Int32> hasData = arena<Int32>();
    final Pointer<Int64> shift = arena<Int64>();
    final Pointer<Double> confidence = arena<Double>();
    _check(
      b.xcorr(
        _doublesIn(arena, audio),
        audio.length,
        _doublesIn(arena, cue),
        cue.length,
        binMs,
        maxShiftMs,
        hasData,
        shift,
        confidence,
      ),
      'ffc_signal_xcorr_best_shift',
    );
    if (hasData.value == 0) return null;
    return (shiftBins: shift.value, confidence: confidence.value);
  });
}

/// 裸 PCM（小端；16 / 32 位整型或 32 位 float）按 [windowMs] 切窗，逐窗 RMS 转 dBFS
/// （夹到 [[silenceDb], 0]）。格式不支持 / 参数非正 / 不足一帧时返回空列表。
/// 库不可用抛 [FushiComputeUnavailableError]。
Float64List ffcPcmRmsDb(
  Uint8List pcm, {
  required int sampleRate,
  required int channels,
  required int bitsPerSample,
  required bool isFloat,
  required int windowMs,
  required double silenceDb,
  FushiCompute? library,
}) {
  final _SignalBindings b = _SignalBindings.of(library);
  return using((Arena arena) {
    final Pointer<Uint8> input = arena<Uint8>(pcm.isEmpty ? 1 : pcm.length);
    if (pcm.isNotEmpty) input.asTypedListOutOfLine(pcm.length).setAll(0, pcm);
    final Pointer<Size> need = arena<Size>();
    int call(Pointer<Double> out, int cap) => b.pcmRms(
      input,
      pcm.length,
      sampleRate,
      channels,
      bitsPerSample,
      isFloat ? 1 : 0,
      windowMs,
      silenceDb,
      out,
      cap,
      need,
    );
    final int first = call(nullptr, 0);
    if (first == FfcStatus.ok && need.value == 0) return Float64List(0);
    if (first != FfcStatus.bufferTooSmall) {
      _check(first, 'ffc_signal_pcm_rms_db');
    }
    final int count = need.value;
    final Pointer<Double> out = arena<Double>(count);
    _check(call(out, count), 'ffc_signal_pcm_rms_db');
    return Float64List.fromList(out.asTypedListOutOfLine(count));
  }, malloc); // 输入整段拷进来就覆盖，不需要 calloc 先清零（10 s 立体声 float32 = 3.8 MB）。
}

/// 解析 ffmpeg `ametadata=print` 的逐帧 RMS 输出（UTF-8 字节）：按出现顺序取
/// `lavfi.astats.Overall.RMS_level` 的值，`-inf` / `inf` / 非有限值记成 [silenceDb]。
///
/// [utf8Bytes] 不是合法 UTF-8 抛 [FormatException]（与 `File.readAsStringSync` 同）。
/// 库不可用抛 [FushiComputeUnavailableError]。
Float64List ffcParseRmsLog(
  Uint8List utf8Bytes, {
  double silenceDb = -120.0,
  FushiCompute? library,
}) {
  final FushiCompute compute = library ?? FushiCompute.require();
  final _SignalBindings b = _SignalBindings.of(compute);
  return using((Arena arena) {
    final Pointer<Uint8> input = arena<Uint8>(
      utf8Bytes.isEmpty ? 1 : utf8Bytes.length,
    );
    if (utf8Bytes.isNotEmpty) {
      input.asTypedListOutOfLine(utf8Bytes.length).setAll(0, utf8Bytes);
    }
    final Pointer<Pointer<Uint8>> outPtr = arena<Pointer<Uint8>>();
    final Pointer<Size> outLen = arena<Size>();
    final int status = b.parseLog(
      input,
      utf8Bytes.length,
      silenceDb,
      outPtr,
      outLen,
    );
    if (status == FfcStatus.badInput) {
      throw const FormatException('ffmpeg RMS log is not valid UTF-8');
    }
    _check(status, 'ffc_signal_parse_rms_log');
    final int bytes = outLen.value;
    if (bytes == 0) return Float64List(0);
    try {
      return Float64List.fromList(
        outPtr.value.cast<Double>().asTypedListOutOfLine(bytes ~/ 8),
      );
    } finally {
      compute.freeBytes(outPtr.value, bytes);
    }
  });
}

/// 一条 dB 能量包络的线性振幅副本（原生内存，随对象被 GC 释放），用于反复降采样成
/// 不同宽度的波形桶：`10^(dB/20)` 只在构造时算一遍。
///
/// 振幅数组由 [NativeScratch] owner 持有、finalizer 挂在 owner 上；本类实现 [Finalizable]，
/// 实例方法执行期间 `this`（进而 owner）一直保活。不能只把裸地址交给原生侧而让 owner 在
/// 最后一次 Dart 引用之后被判不可达（一次性 `fromDb(...).downsample(...)` 就是这条路径，
/// HBK-AUDIT-002）。
final class FfcEnergyEnvelope implements Finalizable {
  FfcEnergyEnvelope._(this._b, this._amp, this.length);

  /// 由 dB 序列（越大越响）建包络。库不可用抛 [FushiComputeUnavailableError]。
  factory FfcEnergyEnvelope.fromDb(List<double> db, {FushiCompute? library}) {
    final _SignalBindings b = _SignalBindings.of(library);
    final int n = db.length;
    final NativeScratch amp = NativeScratch.fixed((n == 0 ? 1 : n) * 8);
    final Pointer<Double> ptr = amp.pointer.cast<Double>();
    ptr.asTypedListOutOfLine(n).setAll(0, db);
    _check(b.dbToAmp(ptr, ptr, n), 'ffc_signal_db_to_amplitude');
    return FfcEnergyEnvelope._(b, amp, n);
  }

  final _SignalBindings _b;

  /// 线性振幅（[length] 个 f64）的 owner。
  final NativeScratch _amp;

  /// 帧数。
  final int length;

  /// 降到 [targetBuckets] 个 0..1 波形桶：每桶取区间线性振幅峰值，再以最小桶峰值为
  /// 地基、第 [percentile]（夹到 0..1）分位为上限线性归一化；全同值时全 0。
  /// [targetBuckets] >= 帧数时每帧一桶；空包络或 [targetBuckets] <= 0 返回空列表。
  Float64List downsample(int targetBuckets, {double percentile = 0.99}) {
    final int n = length;
    if (n == 0 || targetBuckets <= 0) return Float64List(0);
    final int count = targetBuckets >= n ? n : targetBuckets;
    final Pointer<Double> amp = _amp.pointer.cast<Double>();
    return using((Arena arena) {
      final Pointer<Double> out = arena<Double>(count);
      final Pointer<Size> outLen = arena<Size>();
      _check(
        _b.downsample(amp, n, targetBuckets, percentile, out, count, outLen),
        'ffc_signal_downsample_peaks',
      );
      return Float64List.fromList(out.asTypedListOutOfLine(outLen.value));
    });
  }
}
