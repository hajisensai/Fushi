import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'fushi_rwkv_library.dart';
import 'rwkv_rows.dart';

/// 哪个网络（`frwkv_model_kind`）。
enum RwkvModelKind {
  /// 2,762,884 参数的上游模型（质量优先）。
  large(1),

  /// 331,511 参数的 SM56 小模型（省内存）。
  small(2);

  const RwkvModelKind(this.code);
  final int code;
}

/// 状态精度（`frwkv_runtime_new` 的 precision）。[recommended]：大模型 int8、小模型 int4。
enum RwkvPrecision {
  f32(0),
  int8(8),
  int4(4),
  recommended(-1);

  const RwkvPrecision(this.code);
  final int code;
}

/// 原生调用返回负数（输入不合法 / 数据损坏 / 内部 panic / runtime 已不可信）。
class RwkvNativeException implements Exception {
  const RwkvNativeException(this.code, this.message);

  /// -1 参数、-2 输入行、-3 数据、-4 panic、-5 poisoned、-6 模型不支持（见 README.md）。
  final int code;
  final String message;

  bool get isInput => code == -2;
  bool get isPoisoned => code == -5;
  bool get isUnsupported => code == -6;

  @override
  String toString() => 'RwkvNativeException($code): $message';
}

/// `frwkv_runtime_stats` 的输出。
class RwkvStats {
  const RwkvStats({
    required this.reviews,
    required this.cards,
    required this.notes,
    required this.decks,
    required this.presets,
    required this.cardStateBytes,
    required this.noteStateBytes,
    required this.sharedStateBytes,
    required this.featureStateBytes,
  });

  final int reviews;
  final int cards;
  final int notes;
  final int decks;
  final int presets;
  final int cardStateBytes;
  final int noteStateBytes;
  final int sharedStateBytes;
  final int featureStateBytes;

  int get totalBytes =>
      cardStateBytes + noteStateBytes + sharedStateBytes + featureStateBytes;
}

/// 分数表查询（`frwkv_runtime_scores_lookup`）：[scores] 与请求同序，没命中的是 NaN、
/// [found] 对应位是 0。
class RwkvScoreLookup {
  const RwkvScoreLookup(this.scores, this.found);

  final Float32List scores;
  final Uint8List found;

  int get hits => found.fold<int>(0, (int n, int f) => n + f);
}

/// 作答时排程的结果：Again / Hard / Good / Easy 各自的天数与那天的 R。
class RwkvIntervals {
  const RwkvIntervals(this.days, this.retrievability);

  final List<int> days;
  final List<double> retrievability;
}

final class _Stats extends Struct {
  @Int64()
  external int reviews;
  @Uint64()
  external int cards;
  @Uint64()
  external int notes;
  @Uint64()
  external int decks;
  @Uint64()
  external int presets;
  @Uint64()
  external int cardStateBytes;
  @Uint64()
  external int noteStateBytes;
  @Uint64()
  external int sharedStateBytes;
  @Uint64()
  external int featureStateBytes;
}

typedef _ModelLoadC = Pointer<Void> Function(Pointer<Uint8>, Size);
typedef _ModelLoadDart = Pointer<Void> Function(Pointer<Uint8>, int);
typedef _PtrToI32C = Int32 Function(Pointer<Void>);
typedef _PtrToI32Dart = int Function(Pointer<Void>);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _RuntimeNewC = Pointer<Void> Function(Pointer<Void>, Int32, Uint32);
typedef _RuntimeNewDart = Pointer<Void> Function(Pointer<Void>, int, int);
typedef _RowsC =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Float>);
typedef _RowsDart =
    int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Float>);
typedef _IntervalsC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Float,
      Uint32,
      Pointer<Uint32>,
      Pointer<Float>,
    );
typedef _IntervalsDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      double,
      int,
      Pointer<Uint32>,
      Pointer<Float>,
    );
typedef _SnapshotC =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _SnapshotDart =
    int Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _RestoreC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _RestoreDart = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _StatsC = Int32 Function(Pointer<Void>, Pointer<_Stats>);
typedef _StatsDart = int Function(Pointer<Void>, Pointer<_Stats>);
typedef _AppendC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Int64>,
      Size,
    );
typedef _AppendDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Int64>,
      int,
    );
typedef _UnappendC = Int32 Function(Pointer<Void>, Uint64);
typedef _UnappendDart = int Function(Pointer<Void>, int);
typedef _RewindFromC = Int32 Function(Pointer<Void>, Int64, Pointer<Uint64>);
typedef _RewindFromDart = int Function(Pointer<Void>, int, Pointer<Uint64>);
typedef _LookupC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Int64>,
      Pointer<Uint64>,
      Size,
      Pointer<Float>,
      Pointer<Uint8>,
    );
typedef _LookupDart =
    int Function(
      Pointer<Void>,
      Pointer<Int64>,
      Pointer<Uint64>,
      int,
      Pointer<Float>,
      Pointer<Uint8>,
    );
typedef _UpdateC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Int64>,
      Size,
      Pointer<Float>,
    );
typedef _UpdateDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Pointer<Uint64>,
      Pointer<Int64>,
      int,
      Pointer<Float>,
    );
typedef _RequeryC = Int32 Function(Pointer<Void>, Int64, Int64);
typedef _RequeryDart = int Function(Pointer<Void>, int, int);
typedef _RemoveC = Int32 Function(Pointer<Void>, Pointer<Int64>, Size);
typedef _RemoveDart = int Function(Pointer<Void>, Pointer<Int64>, int);
typedef _LastErrorC = Pointer<Utf8> Function();
typedef _FreeStringC = Void Function(Pointer<Utf8>);
typedef _FreeStringDart = void Function(Pointer<Utf8>);
typedef _FreeBytesC = Void Function(Pointer<Uint8>, Size);
typedef _FreeBytesDart = void Function(Pointer<Uint8>, int);

/// `frwkv_*` 符号表（加载库时一次 lookup）。
class _Bindings {
  _Bindings(DynamicLibrary lib)
    : modelLoad = lib.lookupFunction<_ModelLoadC, _ModelLoadDart>(
        'frwkv_model_load',
      ),
      modelKind = lib.lookupFunction<_PtrToI32C, _PtrToI32Dart>(
        'frwkv_model_kind',
      ),
      modelFree = lib.lookup<NativeFunction<_FreeC>>('frwkv_model_free'),
      runtimeNew = lib.lookupFunction<_RuntimeNewC, _RuntimeNewDart>(
        'frwkv_runtime_new',
      ),
      runtimeFree = lib.lookup<NativeFunction<_FreeC>>('frwkv_runtime_free'),
      replay = lib.lookupFunction<_RowsC, _RowsDart>('frwkv_runtime_replay'),
      query = lib.lookupFunction<_RowsC, _RowsDart>('frwkv_runtime_query'),
      nextIntervals = lib.lookupFunction<_IntervalsC, _IntervalsDart>(
        'frwkv_runtime_next_intervals',
      ),
      snapshot = lib.lookupFunction<_SnapshotC, _SnapshotDart>(
        'frwkv_runtime_snapshot',
      ),
      restore = lib.lookupFunction<_RestoreC, _RestoreDart>(
        'frwkv_runtime_restore',
      ),
      reset = lib.lookupFunction<_PtrToI32C, _PtrToI32Dart>(
        'frwkv_runtime_reset',
      ),
      stats = lib.lookupFunction<_StatsC, _StatsDart>('frwkv_runtime_stats'),
      append = lib.lookupFunction<_AppendC, _AppendDart>(
        'frwkv_runtime_append',
      ),
      unappend = lib.lookupFunction<_UnappendC, _UnappendDart>(
        'frwkv_runtime_unappend',
      ),
      rewindFrom = lib.lookupFunction<_RewindFromC, _RewindFromDart>(
        'frwkv_runtime_rewind_from',
      ),
      scoresClear = lib.lookupFunction<_PtrToI32C, _PtrToI32Dart>(
        'frwkv_runtime_scores_clear',
      ),
      scoresLookup = lib.lookupFunction<_LookupC, _LookupDart>(
        'frwkv_runtime_scores_lookup',
      ),
      scoresUpdate = lib.lookupFunction<_UpdateC, _UpdateDart>(
        'frwkv_runtime_scores_update',
      ),
      scoresRequery = lib.lookupFunction<_RequeryC, _RequeryDart>(
        'frwkv_runtime_scores_requery',
      ),
      scoresRemove = lib.lookupFunction<_RemoveC, _RemoveDart>(
        'frwkv_runtime_scores_remove',
      ),
      lastError = lib.lookupFunction<_LastErrorC, _LastErrorC>(
        'frwkv_last_error',
      ),
      freeString = lib.lookupFunction<_FreeStringC, _FreeStringDart>(
        'frwkv_free_string',
      ),
      freeBytes = lib.lookupFunction<_FreeBytesC, _FreeBytesDart>(
        'frwkv_free_bytes',
      );

  final _ModelLoadDart modelLoad;
  final _PtrToI32Dart modelKind;
  final Pointer<NativeFunction<_FreeC>> modelFree;
  final _RuntimeNewDart runtimeNew;
  final Pointer<NativeFunction<_FreeC>> runtimeFree;
  final _RowsDart replay;
  final _RowsDart query;
  final _IntervalsDart nextIntervals;
  final _SnapshotDart snapshot;
  final _RestoreDart restore;
  final _PtrToI32Dart reset;
  final _StatsDart stats;
  final _AppendDart append;
  final _UnappendDart unappend;
  final _RewindFromDart rewindFrom;
  final _PtrToI32Dart scoresClear;
  final _LookupDart scoresLookup;
  final _UpdateDart scoresUpdate;
  final _RequeryDart scoresRequery;
  final _RemoveDart scoresRemove;
  final Pointer<Utf8> Function() lastError;
  final _FreeStringDart freeString;
  final _FreeBytesDart freeBytes;

  /// 返回码 < 0 时**紧接着**（同一段同步代码、不经 await）取线程局部的错误文本。
  RwkvNativeException error(int code) {
    final Pointer<Utf8> text = lastError();
    String message = 'fushi_rwkv error $code';
    if (text != nullptr) {
      message = text.toDartString();
      freeString(text);
    }
    return RwkvNativeException(code, message);
  }

  void check(int code) {
    if (code < 0) throw error(code);
  }
}

final Expando<_Bindings> _bindings = Expando<_Bindings>();

_Bindings _of(FushiRwkv library) =>
    _bindings[library] ??= _Bindings(library.library);

/// 原生网络（`frwkv_model_load`）。可被多个 runtime 共享；runtime 各持一份引用，
/// 所以模型可以先于 runtime 释放。
class RwkvNativeModel implements Finalizable {
  RwkvNativeModel._(this._b, this._handle, this.kind);

  /// 从权重文件字节加载（大 / 小模型按内容识别）。
  factory RwkvNativeModel.load(Uint8List weights, {FushiRwkv? library}) {
    final _Bindings b = _of(library ?? FushiRwkv.instance);
    final Pointer<Uint8> buffer = malloc<Uint8>(weights.length);
    try {
      buffer.asTypedListOutOfLine(weights.length).setAll(0, weights);
      final Pointer<Void> handle = b.modelLoad(buffer, weights.length);
      if (handle == nullptr) throw b.error(-3);
      final int kindCode = b.modelKind(handle);
      final RwkvNativeModel model = RwkvNativeModel._(
        b,
        handle,
        RwkvModelKind.values.firstWhere(
          (RwkvModelKind k) => k.code == kindCode,
        ),
      );
      NativeFinalizer(b.modelFree.cast()).attach(model, handle, detach: model);
      return model;
    } finally {
      malloc.free(buffer);
    }
  }

  final _Bindings _b;
  final Pointer<Void> _handle;
  final RwkvModelKind kind;
}

/// 一个 collection 的 RWKV 状态（`frwkv_runtime_*`）。**不是线程安全的**：只在创建它的
/// isolate 里用（app 里由 [RwkvWorker] 持有）。所有批量数据整块传，一次交互个位数调用。
class RwkvNativeRuntime implements Finalizable {
  RwkvNativeRuntime._(this._b, this._handle, this.kind, this.precision);

  /// `threads`：0 = 全部核心，1 = 单线程（墨水屏 / 省电）。
  factory RwkvNativeRuntime.create(
    RwkvNativeModel model, {
    RwkvPrecision precision = RwkvPrecision.recommended,
    int threads = 0,
  }) {
    final _Bindings b = model._b;
    final Pointer<Void> handle = b.runtimeNew(
      model._handle,
      precision.code,
      threads,
    );
    if (handle == nullptr) throw b.error(-1);
    final RwkvPrecision resolved = precision != RwkvPrecision.recommended
        ? precision
        : (model.kind == RwkvModelKind.small
              ? RwkvPrecision.int4
              : RwkvPrecision.int8);
    final RwkvNativeRuntime runtime = RwkvNativeRuntime._(
      b,
      handle,
      model.kind,
      resolved,
    );
    _finalizer(b).attach(runtime, handle, detach: runtime);
    return runtime;
  }

  static final Expando<NativeFinalizer> _finalizers =
      Expando<NativeFinalizer>();
  static NativeFinalizer _finalizer(_Bindings b) =>
      _finalizers[b] ??= NativeFinalizer(b.runtimeFree.cast());

  final _Bindings _b;
  final Pointer<Void> _handle;
  final RwkvModelKind kind;
  final RwkvPrecision precision;
  bool _disposed = false;

  void _alive() {
    if (_disposed) throw StateError('RWKV runtime disposed');
  }

  /// 按时间顺序追加一批已答复习；[predictions] 为 true 时返回每行作答前的 R
  /// （无评分行为 NaN）。任一行不合法 → [RwkvNativeException]（整批未应用）。
  Float32List? replay(RwkvRows rows, {bool predictions = false}) =>
      _rows(_b.replay, rows, predictions);

  /// 批量查询当前 R；不合法的行为 NaN。
  Float32List query(RwkvRows rows) => _rows(_b.query, rows, true)!;

  Float32List? _rows(_RowsDart call, RwkvRows rows, bool output) {
    _alive();
    final int n = rows.length;
    final Pointer<Uint8> input = malloc<Uint8>(n * kFrwkvReviewSize + 1);
    final Pointer<Float> out = output ? malloc<Float>(n + 1) : nullptr;
    try {
      input.asTypedListOutOfLine(n * kFrwkvReviewSize).setAll(0, rows.bytes);
      final int code = call(_handle, input, n, out);
      if (code < 0) throw _b.error(code);
      return output ? Float32List.fromList(out.asTypedListOutOfLine(n)) : null;
    } finally {
      malloc.free(input);
      if (out != nullptr) malloc.free(out);
    }
  }

  /// 追加已答复习并记撤销日志（`frwkv_runtime_append`，标签 [tags] 与评分时刻 [ats]（毫秒，不得早于
  /// 日志里最后一条）与行同序）：状态与 [replay] 同一批行逐位相同，之后可用 [unappend] 原样撤回最近
  /// 一条、用 [rewindFrom] 退到某个时刻之前。只有小模型支持（大模型抛
  /// [RwkvNativeException.isUnsupported]）。
  void append(RwkvRows rows, List<int> tags, List<int> ats) {
    _alive();
    final int n = rows.length;
    if (tags.length != n || ats.length != n) {
      throw ArgumentError('tags/ats/rows length mismatch');
    }
    final Pointer<Uint8> input = malloc<Uint8>(n * kFrwkvReviewSize + 1);
    final Pointer<Uint64> tagBuffer = malloc<Uint64>(n + 1);
    final Pointer<Int64> atBuffer = malloc<Int64>(n + 1);
    try {
      input.asTypedListOutOfLine(n * kFrwkvReviewSize).setAll(0, rows.bytes);
      tagBuffer.asTypedListOutOfLine(n).setAll(0, tags);
      atBuffer.asTypedListOutOfLine(n).setAll(0, ats);
      _b.check(_b.append(_handle, input, tagBuffer, atBuffer, n));
    } finally {
      malloc
        ..free(input)
        ..free(tagBuffer)
        ..free(atBuffer);
    }
  }

  /// 退到时刻 [atMs] 之前（`frwkv_runtime_rewind_from`）：撤掉撤销日志里全部时刻 ≥ [atMs] 的条目，返回
  /// 撤了几条；状态与「只回放过时刻 < [atMs] 的行」逐位相同。退不到（日志之前还有时刻未知的行）返回
  /// null，什么都不改。
  int? rewindFrom(int atMs) {
    _alive();
    final Pointer<Uint64> out = malloc<Uint64>();
    try {
      final int code = _b.rewindFrom(_handle, atMs, out);
      if (code < 0) throw _b.error(code);
      return code == 1 ? out.value : null;
    } finally {
      malloc.free(out);
    }
  }

  /// 撤回最近一条 [append]（仅当标签是 [tag]）：true = 已撤回，状态与没回放过它逐位相同；
  /// false = 不是它（或日志已清空），什么都没改。
  bool unappend(int tag) {
    _alive();
    final int code = _b.unappend(_handle, tag);
    if (code < 0) throw _b.error(code);
    return code == 1;
  }

  /// 清空常驻分数表（全量刷新前）。
  void clearScores() {
    _alive();
    _b.check(_b.scoresClear(_handle));
  }

  /// 在分数表里查这些卡（id 与版本，见 lib.rs `frwkv_runtime_scores_lookup`）。不改状态。
  RwkvScoreLookup lookupScores(Int64List cardIds, Uint64List versions) {
    _alive();
    final int n = cardIds.length;
    if (versions.length != n) throw ArgumentError('ids/versions mismatch');
    final Pointer<Int64> ids = malloc<Int64>(n + 1);
    final Pointer<Uint64> vs = malloc<Uint64>(n + 1);
    final Pointer<Float> scores = malloc<Float>(n + 1);
    final Pointer<Uint8> found = malloc<Uint8>(n + 1);
    try {
      ids.asTypedListOutOfLine(n).setAll(0, cardIds);
      vs.asTypedListOutOfLine(n).setAll(0, versions);
      final int code = _b.scoresLookup(_handle, ids, vs, n, scores, found);
      if (code < 0) throw _b.error(code);
      return RwkvScoreLookup(
        Float32List.fromList(scores.asTypedListOutOfLine(n)),
        Uint8List.fromList(found.asTypedListOutOfLine(n)),
      );
    } finally {
      malloc
        ..free(ids)
        ..free(vs)
        ..free(scores)
        ..free(found);
    }
  }

  /// 算这些查询行的 R（与 [query] 逐位相同）并记进分数表（版本 [versions]；锚点
  /// [anchorsMs] = 每张卡最后一条保留评分的时刻，没有给 -1，[requeryScores] 用）。
  Float32List updateScores(
    RwkvRows rows,
    Uint64List versions,
    Int64List anchorsMs,
  ) {
    _alive();
    final int n = rows.length;
    if (versions.length != n || anchorsMs.length != n) {
      throw ArgumentError('rows/versions/anchors mismatch');
    }
    final Pointer<Uint8> input = malloc<Uint8>(n * kFrwkvReviewSize + 1);
    final Pointer<Uint64> vs = malloc<Uint64>(n + 1);
    final Pointer<Int64> anchors = malloc<Int64>(n + 1);
    final Pointer<Float> out = malloc<Float>(n + 1);
    try {
      input.asTypedListOutOfLine(n * kFrwkvReviewSize).setAll(0, rows.bytes);
      vs.asTypedListOutOfLine(n).setAll(0, versions);
      anchors.asTypedListOutOfLine(n).setAll(0, anchorsMs);
      _b.check(_b.scoresUpdate(_handle, input, vs, anchors, n, out));
      return Float32List.fromList(out.asTypedListOutOfLine(n));
    } finally {
      malloc
        ..free(input)
        ..free(vs)
        ..free(anchors)
        ..free(out);
    }
  }

  /// 全量刷新分数表：每一项按第 [today] 个调度日、此刻 [nowMs] 重算（lib.rs
  /// `frwkv_runtime_scores_requery`）。返回重查的项数。
  int requeryScores(int today, int nowMs) {
    _alive();
    final int code = _b.scoresRequery(_handle, today, nowMs);
    if (code < 0) throw _b.error(code);
    return code;
  }

  /// 从分数表删掉这些卡的项（卡被永久清除，lib.rs `frwkv_runtime_scores_remove`）。
  /// 返回删掉的项数。
  int removeScores(Int64List cardIds) {
    _alive();
    final int n = cardIds.length;
    final Pointer<Int64> ids = malloc<Int64>(n + 1);
    try {
      ids.asTypedListOutOfLine(n).setAll(0, cardIds);
      final int code = _b.scoresRemove(_handle, ids, n);
      if (code < 0) throw _b.error(code);
      return code;
    } finally {
      malloc.free(ids);
    }
  }

  /// 作答时排程：[answer] 第一行是这次作答（ease 被忽略），见 lib.rs `frwkv_runtime_next_intervals`。
  RwkvIntervals nextIntervals(
    RwkvRows answer, {
    required double targetRetention,
    required int maxIntervalDays,
  }) {
    _alive();
    if (answer.isEmpty) throw ArgumentError('answer row missing');
    final Pointer<Uint8> input = malloc<Uint8>(kFrwkvReviewSize);
    final Pointer<Uint32> days = malloc<Uint32>(4);
    final Pointer<Float> r = malloc<Float>(4);
    try {
      input
          .asTypedListOutOfLine(kFrwkvReviewSize)
          .setAll(0, answer.bytes.sublist(0, kFrwkvReviewSize));
      final int code = _b.nextIntervals(
        _handle,
        input,
        targetRetention,
        maxIntervalDays,
        days,
        r,
      );
      if (code < 0) throw _b.error(code);
      return RwkvIntervals(
        List<int>.of(days.asTypedListOutOfLine(4)),
        List<double>.of(r.asTypedListOutOfLine(4)),
      );
    } finally {
      malloc
        ..free(input)
        ..free(days)
        ..free(r);
    }
  }

  /// 无损快照（与模型、精度绑定；恢复到别的会被拒）。
  Uint8List snapshot() {
    _alive();
    final Pointer<Pointer<Uint8>> bytes = malloc<Pointer<Uint8>>();
    final Pointer<Size> len = malloc<Size>();
    try {
      final int code = _b.snapshot(_handle, bytes, len);
      if (code < 0) throw _b.error(code);
      final Uint8List copy = Uint8List.fromList(
        bytes.value.asTypedListOutOfLine(len.value),
      );
      _b.freeBytes(bytes.value, len.value);
      return copy;
    } finally {
      malloc
        ..free(bytes)
        ..free(len);
    }
  }

  /// 用快照替换状态；失败时状态不变。
  void restore(Uint8List snapshot) {
    _alive();
    final Pointer<Uint8> input = malloc<Uint8>(snapshot.length + 1);
    try {
      input.asTypedListOutOfLine(snapshot.length).setAll(0, snapshot);
      _b.check(_b.restore(_handle, input, snapshot.length));
    } finally {
      malloc.free(input);
    }
  }

  void reset() {
    _alive();
    _b.check(_b.reset(_handle));
  }

  RwkvStats stats() {
    _alive();
    final Pointer<_Stats> out = malloc<_Stats>();
    try {
      _b.check(_b.stats(_handle, out));
      final _Stats s = out.ref;
      return RwkvStats(
        reviews: s.reviews,
        cards: s.cards,
        notes: s.notes,
        decks: s.decks,
        presets: s.presets,
        cardStateBytes: s.cardStateBytes,
        noteStateBytes: s.noteStateBytes,
        sharedStateBytes: s.sharedStateBytes,
        featureStateBytes: s.featureStateBytes,
      );
    } finally {
      malloc.free(out);
    }
  }

  /// 立即释放原生状态（不等 GC）。之后再调用任何方法抛 [StateError]。
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer(_b).detach(this);
    _b.runtimeFree.asFunction<void Function(Pointer<Void>)>()(_handle);
  }
}
