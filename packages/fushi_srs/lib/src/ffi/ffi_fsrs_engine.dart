import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../algorithm.dart';
import '../fsrs_engine.dart';
import 'fushi_fsrs_bindings.dart';
import 'fushi_fsrs_library.dart';

/// [FsrsEngine] 的唯一生产实现：native/fushi_fsrs（fsrs-rs）的 FFI 绑定。
///
/// 请求 / 响应走 JSON（见 lib.rs 的 `dispatch`），参数优化 / 评估的训练集走打包的 TypedData
/// （[SrsFsrsTrainingSet]，见 lib.rs 的 `ffsrs_fit`）；原生侧报的错误（参数不合法、数据不足、
/// 被取消、panic）一律转成 [SrsFsrsException]。所有调用都是同步阻塞的，参数优化 /
/// 外样本评估请放后台 isolate：别的 isolate 用 [FfiFsrsEngine.tryCreate] 自己再建一个
/// 引擎（同一个库，各 isolate 各自 open），取消 / 进度通道用
/// [NativeSrsOptimizerControl.fromAddress] 共享。
class FfiFsrsEngine implements FsrsBatchEngine {
  FfiFsrsEngine(this.library);

  /// 按 [FushiFsrs] 的定位规则加载原生库并建引擎；库不可用返回 null（不抛）。
  static FfiFsrsEngine? tryCreate({String? libraryPath}) {
    final FushiFsrs? lib = libraryPath == null
        ? FushiFsrs.instance
        : FushiFsrs.tryLoad(libraryPath: libraryPath);
    return lib == null ? null : FfiFsrsEngine(lib);
  }

  final FushiFsrs library;

  FushiFsrsBindings get _b => library.bindings;

  String? _fsrsRev;

  @override
  String get fsrsRev {
    final String? cached = _fsrsRev;
    if (cached != null) return cached;
    final Object? result = _call(<String, Object?>{'op': 'version'});
    final Object? rev = result is Map ? result['fsrsRev'] : null;
    if (rev is! String) {
      throw SrsFsrsException('bad version response: $result');
    }
    return _fsrsRev = rev;
  }

  @override
  List<double> defaultParams(SrsAlgorithm algorithm) {
    final Object? result = _call(<String, Object?>{
      'op': 'defaults',
      'algorithm': algorithm.memoryAlgorithm.wire,
    });
    final Object? params = result is Map ? result['params'] : null;
    return _doubleList(params, 'defaults');
  }

  @override
  String? validateParams(SrsAlgorithm algorithm, List<double> params) {
    try {
      _call(<String, Object?>{
        'op': 'validate',
        'algorithm': algorithm.memoryAlgorithm.wire,
        'params': params,
      });
      return null;
    } on SrsFsrsException catch (e) {
      return e.message;
    }
  }

  @override
  SrsNextStates nextStates({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double desiredRetention,
    required SrsMemory? memory,
    required double elapsedDays,
  }) {
    final Object? result = _call(<String, Object?>{
      'op': 'next_states',
      'algorithm': algorithm.memoryAlgorithm.wire,
      'params': params,
      'desiredRetention': desiredRetention,
      'elapsedDays': elapsedDays,
      'memory': memory?.toJson(),
    });
    if (result is! Map) {
      throw SrsFsrsException('bad next_states response: $result');
    }
    return SrsNextStates(
      again: _itemState(result['again']),
      hard: _itemState(result['hard']),
      good: _itemState(result['good']),
      easy: _itemState(result['easy']),
    );
  }

  @override
  SrsMemory? memoryState({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<SrsFsrsReview> reviews,
    SrsMemory? starting,
  }) {
    final Object? result = _call(<String, Object?>{
      'op': 'memory_state',
      'algorithm': algorithm.memoryAlgorithm.wire,
      'params': params,
      'reviews': <Map<String, Object?>>[
        for (final SrsFsrsReview r in reviews) r.toJson(),
      ],
      'starting': starting?.toJson(),
    });
    if (result == null) return null;
    return _memory(result, 'memory_state');
  }

  @override
  SrsMemory memoryStateFromSm2({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required double easeFactor,
    required double intervalDays,
    required double sm2Retention,
  }) {
    final Object? result = _call(<String, Object?>{
      'op': 'memory_state_from_sm2',
      'algorithm': algorithm.memoryAlgorithm.wire,
      'params': params,
      'easeFactor': easeFactor,
      'interval': intervalDays,
      'sm2Retention': sm2Retention,
    });
    return _memory(result, 'memory_state_from_sm2');
  }

  @override
  double retrievability({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsMemory memory,
    required double elapsedDays,
  }) {
    final Object? result = _call(<String, Object?>{
      'op': 'retrievability',
      'algorithm': algorithm.memoryAlgorithm.wire,
      'params': params,
      'memory': memory.toJson(),
      'elapsedDays': elapsedDays,
    });
    if (result is! num) {
      throw SrsFsrsException('bad retrievability response: $result');
    }
    return result.toDouble();
  }

  @override
  List<double> retrievabilityBatch({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required List<SrsMemory> memories,
    required List<double> elapsedDays,
  }) {
    final int n = memories.length;
    if (elapsedDays.length != n) {
      throw ArgumentError('memories and elapsedDays differ in length');
    }
    final Pointer<Char> model = _encode(<String, Object?>{
      'algorithm': algorithm.memoryAlgorithm.wire,
      'params': params,
    }).toNativeUtf8().cast<Char>();
    // 五段 f32 连续放在一块：s | d | sf | elapsed | out。
    final int slots = n == 0 ? 1 : n;
    final Pointer<Float> buf = calloc<Float>(slots * 5);
    try {
      final Float32List view = buf.asTypedListOutOfLine(slots * 5);
      for (int i = 0; i < n; i++) {
        final SrsMemory m = memories[i];
        view[i] = m.stability;
        view[slots + i] = m.difficulty;
        view[2 * slots + i] = m.stabilityFast;
        view[3 * slots + i] = elapsedDays[i];
      }
      _decodeResponse(
        _b.ffsrs_retrievability_batch(
          model,
          buf,
          buf + slots,
          buf + 2 * slots,
          buf + 3 * slots,
          n,
          buf + 4 * slots,
        ),
      );
      return List<double>.of(view.sublist(4 * slots, 4 * slots + n));
    } finally {
      calloc.free(buf);
      calloc.free(model);
    }
  }

  /// 参数优化（阻塞）。
  ///
  /// [control] 是 [NativeSrsOptimizerControl] 时，原生侧运行中持续读它的取消标志、写进度，
  /// 别的 isolate 调 `cancel()` 即可中止（抛 `SrsFsrsException('cancelled')`）。
  /// 其它实现无法穿过 FFI 边界，只在开始前检查一次是否已取消。
  @override
  List<double> computeParameters({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
    SrsOptimizerControl? control,
  }) {
    if (control != null && control.cancelled) {
      throw const SrsFsrsException('cancelled');
    }
    final Object? result = _fit(
      <String, Object?>{
        'op': 'compute_parameters',
        'algorithm': algorithm.memoryAlgorithm.wire,
      },
      items,
      control is NativeSrsOptimizerControl ? control : null,
    );
    final Object? params = result is Map ? result['params'] : null;
    return _doubleList(params, 'compute_parameters');
  }

  @override
  SrsEvaluation evaluateTimeSeries({
    required SrsAlgorithm algorithm,
    required SrsFsrsTrainingSet items,
  }) {
    final Object? result = _fit(<String, Object?>{
      'op': 'evaluate_tss',
      'algorithm': algorithm.memoryAlgorithm.wire,
    }, items);
    return _evaluation(result, 'evaluate_tss');
  }

  @override
  SrsEvaluation evaluate({
    required SrsAlgorithm algorithm,
    required List<double> params,
    required SrsFsrsTrainingSet items,
  }) {
    final Object? result = _fit(<String, Object?>{
      'op': 'evaluate',
      'algorithm': algorithm.memoryAlgorithm.wire,
      'params': params,
    }, items);
    return _evaluation(result, 'evaluate');
  }

  /// 一次 `ffsrs_fit`：请求头走 JSON（几十字节），训练集的六段 TypedData 各拷一次进原生内存。
  /// 前缀在原生侧展开，这里只有 O(总评分数) 的数据。
  Object? _fit(
    Map<String, Object?> request,
    SrsFsrsTrainingSet set, [
    NativeSrsOptimizerControl? control,
  ]) {
    final Pointer<Char> req = _encode(request).toNativeUtf8().cast<Char>();
    final Int64List? ids = set.cardIds;
    // 长度为 0 时也分配 1 个元素，原生侧拿到的永远是合法指针。
    final Pointer<Uint8> ratings = calloc<Uint8>(_slots(set.ratings.length));
    final Pointer<Float> deltas = calloc<Float>(_slots(set.deltaDays.length));
    final Pointer<Uint32> offsets = calloc<Uint32>(set.cardOffsets.length);
    final Pointer<Int64> cardIds = ids == null
        ? nullptr
        : calloc<Int64>(_slots(ids.length));
    final Pointer<Uint32> itemCards = calloc<Uint32>(_slots(set.length));
    final Pointer<Uint32> itemLengths = calloc<Uint32>(_slots(set.length));
    try {
      ratings.asTypedListOutOfLine(set.ratings.length).setAll(0, set.ratings);
      deltas
          .asTypedListOutOfLine(set.deltaDays.length)
          .setAll(0, set.deltaDays);
      offsets
          .asTypedListOutOfLine(set.cardOffsets.length)
          .setAll(0, set.cardOffsets);
      if (ids != null) cardIds.asTypedListOutOfLine(ids.length).setAll(0, ids);
      itemCards.asTypedListOutOfLine(set.length).setAll(0, set.itemCards);
      itemLengths.asTypedListOutOfLine(set.length).setAll(0, set.itemLengths);
      return _decodeResponse(
        _b.ffsrs_fit(
          req,
          ratings,
          deltas,
          set.ratings.length,
          offsets,
          cardIds,
          set.cardCount,
          itemCards,
          itemLengths,
          set.length,
          control?.cancelPointer ?? nullptr,
          control?.progressPointer ?? nullptr,
        ),
      );
    } finally {
      calloc.free(req);
      calloc.free(ratings);
      calloc.free(deltas);
      calloc.free(offsets);
      if (cardIds != nullptr) calloc.free(cardIds);
      calloc.free(itemCards);
      calloc.free(itemLengths);
    }
  }

  static int _slots(int n) => n == 0 ? 1 : n;

  /// zstd 解码（.apkg 新格式的 collection.anki21b / 媒体清单 / 媒体文件）。
  ///
  /// 原生库不可用或数据不是合法 zstd 帧时返回 null（不抛）。[library] 缺省用
  /// [FushiFsrs.instance]。
  static Uint8List? zstdDecompress(Uint8List data, {FushiFsrs? library}) {
    final FushiFsrs? lib = library ?? FushiFsrs.instance;
    if (lib == null) return null;
    final FushiFsrsBindings b = lib.bindings;
    final Pointer<Uint8> input = calloc<Uint8>(data.isEmpty ? 1 : data.length);
    final Pointer<Size> outLen = calloc<Size>();
    try {
      input.asTypedListOutOfLine(data.length).setAll(0, data);
      final Pointer<Uint8> out = b.ffsrs_zstd_decompress(
        input,
        data.length,
        outLen,
      );
      if (out == nullptr) return null;
      final int len = outLen.value;
      try {
        return Uint8List.fromList(out.asTypedListOutOfLine(len));
      } finally {
        b.ffsrs_free_bytes(out, len);
      }
    } finally {
      calloc.free(input);
      calloc.free(outLen);
    }
  }

  /// zstd 文件到文件流式解码（.apkg 新格式的 collection.anki21b）：一次 FFI 调用解完整个
  /// 文件，内存峰值与文件大小无关。阻塞到结束——大文件要在后台 isolate 里调。
  ///
  /// 原生库不可用返回 null；成功返回 [SrsZstdFileResult.ok]，其余见 [SrsZstdFileResult]。
  /// 失败时 [outPath] 可能残留半截内容，由调用方删除。
  static SrsZstdFileResult? zstdDecompressFile(
    String inPath,
    String outPath, {
    FushiFsrs? library,
  }) {
    final FushiFsrs? lib = library ?? FushiFsrs.instance;
    if (lib == null) return null;
    final Pointer<Utf8> i = inPath.toNativeUtf8();
    final Pointer<Utf8> o = outPath.toNativeUtf8();
    try {
      final int code = lib.bindings.ffsrs_zstd_decompress_file(
        i.cast<Char>(),
        o.cast<Char>(),
      );
      return code >= 0 && code < SrsZstdFileResult.values.length
          ? SrsZstdFileResult.values[code]
          : SrsZstdFileResult.panic;
    } finally {
      calloc.free(i);
      calloc.free(o);
    }
  }

  // ---- JSON 往返 ----

  Object? _call(Map<String, Object?> request) {
    final Pointer<Char> req = _encode(request).toNativeUtf8().cast<Char>();
    try {
      return _decodeResponse(_b.ffsrs_call(req));
    } finally {
      calloc.free(req);
    }
  }

  static String _encode(Map<String, Object?> request) {
    try {
      return jsonEncode(request);
    } on JsonUnsupportedObjectError catch (e) {
      // NaN / Infinity 不能进 JSON：按参数不合法报。
      throw SrsFsrsException('request not encodable: ${e.cause ?? e}');
    }
  }

  /// 读出并释放原生返回的响应串，解包 `{"ok":…}` / `{"error":…}`。
  Object? _decodeResponse(Pointer<Char> resp) {
    if (resp == nullptr) {
      throw const SrsFsrsException('null response from fushi_fsrs');
    }
    final String text;
    try {
      text = resp.cast<Utf8>().toDartString();
    } finally {
      _b.ffsrs_free_string(resp);
    }
    final Object? body;
    try {
      body = jsonDecode(text);
    } on FormatException catch (e) {
      throw SrsFsrsException('response is not json: ${e.message}');
    }
    if (body is! Map) throw SrsFsrsException('bad response: $text');
    if (body.containsKey('error')) {
      throw SrsFsrsException('${body['error']}');
    }
    if (!body.containsKey('ok')) throw SrsFsrsException('bad response: $text');
    return body['ok'];
  }

  static List<double> _doubleList(Object? value, String op) {
    if (value is! List) throw SrsFsrsException('bad $op response: $value');
    return <double>[
      for (final Object? v in value)
        if (v is num)
          v.toDouble()
        else
          throw SrsFsrsException('bad $op response: $value'),
    ];
  }

  static SrsMemory _memory(Object? value, String op) {
    final SrsMemory? memory = SrsMemory.fromJson(value);
    if (memory == null) throw SrsFsrsException('bad $op response: $value');
    return memory;
  }

  static SrsItemState _itemState(Object? value) {
    if (value is! Map) throw SrsFsrsException('bad item state: $value');
    final Object? interval = value['interval'];
    if (interval is! num) throw SrsFsrsException('bad item state: $value');
    return SrsItemState(
      memory: _memory(value['memory'], 'next_states'),
      interval: interval.toDouble(),
    );
  }

  static SrsEvaluation _evaluation(Object? value, String op) {
    if (value is Map) {
      final Object? logLoss = value['logLoss'];
      final Object? rmse = value['rmseBins'];
      if (logLoss is num && rmse is num) {
        return SrsEvaluation(
          logLoss: logLoss.toDouble(),
          rmseBins: rmse.toDouble(),
        );
      }
    }
    throw SrsFsrsException('bad $op response: $value');
  }
}

/// 原生内存实现的优化器取消 / 进度通道：一个 int32 取消标志 + int64[2] 进度
/// `[已处理, 总数]`，由 `ffsrs_fit`（参数优化）的看门线程读写。
///
/// 跨 isolate：在 UI isolate 建一个（拥有内存），把 [cancelAddress] / [progressAddress]
/// 两个 int 传给后台 isolate，那边用 [NativeSrsOptimizerControl.fromAddress] 包一层
/// （不拥有内存）交给 [FfiFsrsEngine.computeParameters]。拥有者必须等优化调用返回后
/// 才 [dispose]，否则原生侧会写已释放的内存。
///
/// 取消标志是对齐的 int32，单次读写在所有目标架构上都是原子的；进度的 int64 在
/// armeabi-v7a 上可能读到撕裂值，只用于展示，不参与判定。
class NativeSrsOptimizerControl implements SrsOptimizerControl {
  /// 分配并拥有原生内存（初值全 0）。
  NativeSrsOptimizerControl()
    : _cancel = calloc<Int32>(),
      _progress = calloc<Int64>(2),
      _owned = true;

  /// 包装别的 isolate 分配的同一块内存；不拥有，[dispose] 不释放。
  NativeSrsOptimizerControl.fromAddress({
    required int cancelAddress,
    required int progressAddress,
  }) : _cancel = Pointer<Int32>.fromAddress(cancelAddress),
       _progress = Pointer<Int64>.fromAddress(progressAddress),
       _owned = false;

  final Pointer<Int32> _cancel;
  final Pointer<Int64> _progress;
  final bool _owned;
  bool _disposed = false;

  /// 取消标志的地址（跨 isolate 传递用）。
  int get cancelAddress => _cancel.address;

  /// 进度数组的地址（跨 isolate 传递用）。
  int get progressAddress => _progress.address;

  Pointer<Int32> get cancelPointer {
    _checkAlive();
    return _cancel;
  }

  Pointer<Int64> get progressPointer {
    _checkAlive();
    return _progress;
  }

  @override
  bool get cancelled => !_disposed && _cancel.value != 0;

  @override
  void cancel() {
    if (_disposed) return;
    _cancel.value = 1;
  }

  @override
  (int, int) get progress => _disposed ? (0, 0) : (_progress[0], _progress[1]);

  /// 释放拥有的原生内存；非拥有者只是标记失效。重复调用无害。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_owned) {
      calloc.free(_cancel);
      calloc.free(_progress);
    }
  }

  void _checkAlive() {
    if (_disposed) {
      throw StateError('NativeSrsOptimizerControl already disposed');
    }
  }
}

/// [FfiFsrsEngine.zstdDecompressFile] 的结果（与 native 的 `ZSTD_FILE_*` 同序）。
enum SrsZstdFileResult {
  ok,
  badArgs,

  /// 读源文件 / 写目标文件失败。
  io,

  /// 不是合法的 zstd 帧（含截断）。
  corrupt,
  panic,
}
