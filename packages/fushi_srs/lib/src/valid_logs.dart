/// 有效日志选取与 S/D 输入收集（铁律 A / B）的 Dart 视图。两条规则都只在 Rust 里写一份
/// （native/fushi_fsrs/src/history.rs 选取、src/projection.rs 记忆状态输入），这里只做打包 / 解包。
/// 不做状态机重放。
library;

import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'algorithm.dart';
import 'day.dart';
import 'ffi/fushi_fsrs_library.dart';
import 'fsrs_engine.dart';
import 'history_kernel.dart';
import 'review_log.dart';

/// 一张卡的日志视图。[serverTimeOf] 给出事件的 S(e)。
///
/// 排序与有效日志选取（撤销、等价导入、排程归属）只在 Rust 里写一份
/// （native/fushi_fsrs/src/history.rs，见 history_kernel.dart）；这里只是选取结果的视图。
/// 一次构造一次 FFI 调用，成批构造用 [SrsCardHistory.many]（一批一次）。
class SrsCardHistory {
  /// 一份历史（一次 FFI 调用；空历史不进原生侧）。
  factory SrsCardHistory(
    Iterable<SrsReviewLog> logs, {
    int? Function(String eventId)? serverTimeOf,
  }) => many(<SrsHistoryInput>[(logs.toList(), serverTimeOf)]).single;

  SrsCardHistory._(List<SrsReviewLog> logs, SrsHistorySelection sel)
    : all = <SrsReviewLog>[for (final int i in sel.order) logs[i]],
      lastEffective = sel.lastEffective < 0 ? null : logs[sel.lastEffective],
      _schedulerFrom = sel.schedulerFrom < 0 ? null : logs[sel.schedulerFrom] {
    for (int k = 0; k < all.length; k++) {
      _position[all[k].id] = k;
      if (sel.status[k] & srsHistoryClamped != 0) _clamped.add(all[k].id);
    }
    effective = <SrsReviewLog>[
      for (int k = 0; k < all.length; k++)
        if (sel.status[k] & srsHistoryEffective != 0) all[k],
    ];
    revoked = <String>{
      for (int k = 0; k < all.length; k++)
        if (sel.status[k] & srsHistoryRevoker != 0) all[k].revokesId!,
    };
    equivalentImports = <String>{
      for (int k = 0; k < all.length; k++)
        if (sel.status[k] & srsHistoryEquivalentImport != 0) all[k].id,
    };
  }

  /// 一批历史，与输入同序；整批一次 FFI 调用。
  static List<SrsCardHistory> many(List<SrsHistoryInput> inputs) {
    final List<SrsHistorySelection> sel = srsSelectHistories(inputs);
    return <SrsCardHistory>[
      for (int i = 0; i < inputs.length; i++)
        SrsCardHistory._(inputs[i].$1, sel[i]),
    ];
  }

  /// 全部日志（含 undo、被撤销的、不认识的；同 ID 只留最后一条），按 sortKey 升序。
  final List<SrsReviewLog> all;

  /// 有效日志（kind 已知且不是 undo、没被撤销、不是被判等价的导入日志），按 sortKey 升序。
  late final List<SrsReviewLog> effective;

  /// 被 undo 撤销的日志 ID（undo 的目标；目标不在本历史里也算）。
  late final Set<String> revoked;

  /// 被判与原生日志等价、因此不算有效的导入日志 ID。
  late final Set<String> equivalentImports;

  /// 最后一条有结果的有效日志；没有 = 新卡。
  final SrsReviewLog? lastEffective;

  /// 决定排程归属的那条 handOff（最后一条有结果的有效 handOff）。
  final SrsReviewLog? _schedulerFrom;

  final Map<String, int> _position = <String, int>{};
  final Set<String> _clamped = <String>{};

  /// [a] 在排序里是否在 [b] 之后（两条都得是本历史 [all] 里的日志）。排序键只在 Rust 里算。
  bool isAfter(SrsReviewLog a, SrsReviewLog b) =>
      _position[a.id]! > _position[b.id]!;

  /// [log] 的排序键被钳位（HLC 物理时间超过它所在批次的 S + 10 分钟）。
  bool isClamped(SrsReviewLog log) => _clamped.contains(log.id);

  /// 卡片当前排程状态 = 最后一条有效日志的结果；scheduler 另由 [scheduler] 决定。
  SrsScheduleResult get state {
    final SrsScheduleResult base =
        lastEffective?.result ?? SrsScheduleResult.initial;
    final String owner = scheduler;
    return base.scheduler == owner ? base : base.copyWith(scheduler: owner);
  }

  /// 卡片归谁排程：最后一条有效 handOff 事件（移交 / 收回）的方向；没有 = fushi。
  /// 导入锚点、评分都不改归属，同一个导入操作永远同一种结果。
  String get scheduler =>
      _schedulerFrom?.result!.scheduler ?? SrsScheduler.fushi;

  /// 协议只允许撤销「该卡当前最后一条有效日志」。
  bool canUndo(String logId) => lastEffective?.id == logId;

  /// 进统计 / 优化器训练集的评分日志（被撤销、被判等价的都已排除）。
  List<SrsReviewLog> get effectiveRatings => <SrsReviewLog>[
    for (final SrsReviewLog l in effective)
      if (l.isRatingReview && l.rating != null) l,
  ];
}

/// 交给 FSRS 的记忆状态输入。
class SrsMemoryInput {
  const SrsMemoryInput({
    required this.reviews,
    this.starting,
    this.sm2Start,
    required this.complete,
  });

  final List<SrsFsrsReview> reviews;

  /// 锚点自带、可直接用的起点（同算法的 FSRS 记忆状态）。
  final SrsMemory? starting;

  /// 需要用 SM-2 换算的起点（ease 小数，如 2.5；间隔天数）。
  final ({double ease, double intervalDays})? sm2Start;

  /// 历史完整（从新卡算起，与锚点无关）。
  final bool complete;
}

/// 收集 S/D 的输入（铁律 A ①～③）。锚点只决定队列与到期，不截断 S/D 的历史。
///
/// 规则只在 Rust 里写一份（native/fushi_fsrs/src/projection.rs `memory_input`；优化器训练集在 srs.db 上
/// 直读时用同一个函数）：
/// ① 取最近一次重置之后的全部有效评分日志（含导入的；被判等价的导入日志已排除）。
/// ② 第一条是学习类评分 → 历史完整，从新卡算起。
/// ③ 不完整 → 以最近一条（在这段历史开头之前的）导入锚点为起点：锚点有同算法的 FSRS 记忆状态就直接用，
///    否则由锚点 ease + 间隔做 SM-2 换算，再接上锚点之后的评分。
/// ③′ 「恢复到备份时间点」照抄状态的 manual 日志与锚点同一种处理。
///
/// elapsed：FSRS-7 / RWKV 用小数天（含当天复习的优势，第六轮审查第 12 条）；FSRS-6 与 Anki 一致按 [day]
/// 翻日后的日序号差取整天。一次调用一次 FFI（这里只有一张卡的有效日志）。
SrsMemoryInput srsCollectMemoryInput(
  SrsCardHistory history, {
  required SrsAlgorithm algorithm,
  required SrsDayContext day,
  FushiFsrs? library,
}) {
  final FushiFsrs lib =
      library ??
      FushiFsrs.instance ??
      (throw SrsHistoryKernelUnavailableError());
  final List<SrsReviewLog> eff = history.effective;
  final int n = eff.length;
  final Pointer<Int64> ints = malloc<Int64>(
    n == 0 ? 1 : n * _memoryColumnWords,
  );
  final Pointer<Size> outLen = calloc<Size>();
  final Pointer<Pointer<Char>> error = calloc<Pointer<Char>>();
  try {
    final Int64List c = ints.asTypedListOutOfLine(
      n == 0 ? 1 : n * _memoryColumnWords,
    );
    final ByteData bits = ByteData(8);
    int f64(double v) {
      bits.setFloat64(0, v, Endian.little);
      return bits.getInt64(0, Endian.little);
    }

    for (int i = 0; i < n; i++) {
      final SrsReviewLog l = eff[i];
      final SrsScheduleResult? r = l.result;
      final SrsMemory? m = r?.memory;
      final int b = i * _memoryColumnWords;
      c[b] = _kindCode(l.kind);
      c[b + 1] = _reviewTypeCode(l.reviewType);
      c[b + 2] = l.rating ?? _noneI64;
      c[b + 3] = l.occurredAt;
      c[b + 4] =
          (r != null ? 1 : 0) |
          (m != null ? 2 : 0) |
          (l.extra[srsRestoreLogExtraKey] != null ? 4 : 0);
      c[b + 5] = r?.queue.index ?? 0;
      c[b + 6] = r?.scheduledDays ?? 0;
      c[b + 7] = r?.reps ?? 0;
      c[b + 8] = r?.lastReviewedAt ?? _noneI64;
      c[b + 9] = r?.ease ?? _noneI64;
      c[b + 10] = m == null ? 0 : f64(m.stability);
      c[b + 11] = m == null ? 0 : f64(m.difficulty);
      c[b + 12] = m == null ? 0 : f64(m.stabilityFast);
      c[b + 13] = _memAlgCode(l.extra['memAlg']);
    }
    final Pointer<Uint8> out = lib.bindings.ffsrs_memory_input(
      ints,
      n,
      _algorithmCode(algorithm),
      day.utcOffsetMin,
      day.rolloverHour,
      outLen,
      error,
    );
    if (out == nullptr) throw FormatException(_takeError(lib, error));
    final int len = outLen.value;
    try {
      return _decodeMemoryInput(out.asTypedListOutOfLine(len));
    } finally {
      lib.bindings.ffsrs_free_bytes(out, len);
    }
  } finally {
    malloc.free(ints);
    calloc
      ..free(outLen)
      ..free(error);
  }
}

/// projection.rs `MEMORY_COLUMN_WORDS`。
const int _memoryColumnWords = 14;

/// 「没有」在 i64 列里的哨兵（history.rs `NONE_I64`）。
const int _noneI64 = -0x8000000000000000;

/// projection.rs `Alg` 的编码。
int _algorithmCode(SrsAlgorithm a) => switch (a) {
  SrsAlgorithm.fsrs6 => 0,
  SrsAlgorithm.fsrs7 => 1,
  SrsAlgorithm.rwkv => 2,
};

/// history.rs `Kind` 的编码（与卡片历史的列模式同一张表）。
int _kindCode(String kind) => switch (kind) {
  SrsLogKind.review => 0,
  SrsLogKind.manual => 1,
  SrsLogKind.reschedule => 2,
  SrsLogKind.importAnchor => 3,
  SrsLogKind.handOff => 4,
  SrsLogKind.undo => 5,
  _ => 6,
};

/// history.rs `RType` 的编码。
int _reviewTypeCode(String reviewType) => switch (reviewType) {
  SrsReviewType.learn => 0,
  SrsReviewType.review => 1,
  SrsReviewType.relearn => 2,
  SrsReviewType.filtered => 3,
  SrsReviewType.manual => 4,
  SrsReviewType.rescheduled => 5,
  _ => 6,
};

/// projection.rs `MemAlg` 的编码：缺失 -1、算法名 0..2、别的字符串 3、不是字符串 4（用到时 Rust 判坏数据）。
int _memAlgCode(Object? v) => switch (v) {
  null => -1,
  'fsrs6' => 0,
  'fsrs7' => 1,
  'rwkv' => 2,
  String() => 3,
  _ => 4,
};

SrsMemoryInput _decodeMemoryInput(Uint8List bytes) {
  final ByteData d = ByteData.sublistView(bytes);
  final int flags = d.getInt64(0, Endian.little);
  final int n = d.getInt64(8, Endian.little);
  double f(int k) => d.getFloat64(16 + 8 * k, Endian.little);
  const int ratings = 56;
  final int deltas = ratings + 8 * n;
  return SrsMemoryInput(
    reviews: <SrsFsrsReview>[
      for (int i = 0; i < n; i++)
        SrsFsrsReview(
          rating: d.getInt64(ratings + 8 * i, Endian.little),
          deltaDays: d.getFloat64(deltas + 8 * i, Endian.little),
        ),
    ],
    starting: flags & 2 != 0
        ? SrsMemory(stability: f(0), difficulty: f(1), stabilityFast: f(2))
        : null,
    sm2Start: flags & 4 != 0 ? (ease: f(3), intervalDays: f(4)) : null,
    complete: flags & 1 != 0,
  );
}

String _takeError(FushiFsrs lib, Pointer<Pointer<Char>> error) {
  final Pointer<Char> p = error.value;
  if (p == nullptr) return 'memory input kernel failed';
  try {
    return p.cast<Utf8>().toDartString();
  } finally {
    lib.bindings.ffsrs_free_string(p);
  }
}

/// 用 [engine] 把输入算成当前记忆状态（新卡返回 null）。
SrsMemory? srsComputeMemory(
  SrsMemoryInput input, {
  required FsrsEngine engine,
  required SrsAlgorithm algorithm,
  required List<double> params,
  double sm2Retention = 0.9,
}) {
  algorithm = algorithm.memoryAlgorithm;
  SrsMemory? starting = input.starting;
  final ({double ease, double intervalDays})? sm2 = input.sm2Start;
  if (starting == null && sm2 != null) {
    starting = engine.memoryStateFromSm2(
      algorithm: algorithm,
      params: params,
      easeFactor: sm2.ease,
      intervalDays: sm2.intervalDays,
      sm2Retention: sm2Retention,
    );
  }
  if (input.reviews.isEmpty) return starting;
  final List<SrsFsrsReview> reviews = starting == null
      ? <SrsFsrsReview>[
          SrsFsrsReview(rating: input.reviews.first.rating, deltaDays: 0),
          ...input.reviews.skip(1),
        ]
      : input.reviews;
  return engine.memoryState(
    algorithm: algorithm,
    params: params,
    reviews: reviews,
    starting: starting,
  );
}
