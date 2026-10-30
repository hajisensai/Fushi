/// P6 直读命令的结果视图（docs/specs/2026-10-23-srs-rust-store.md §7）：优化器训练集、RWKV 回放行、
/// 统计页的有效日志列。取数、选取与投影规则都在 Rust（native/fushi_fsrs/src/projection.rs、
/// src/store/projections.rs），这里只按布局解包；命令本身在 [SrsDbStore] 上（后台 isolate 执行）。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';
import 'package:fushi_rwkv/fushi_rwkv.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 「没有」在 i64 列里的哨兵（history.rs `NONE_I64`）。
const int _none = -0x8000000000000000;

/// projection.rs `Alg` 的编码。
int srsProjectionAlgorithmCode(SrsAlgorithm a) => switch (a) {
  SrsAlgorithm.fsrs6 => 0,
  SrsAlgorithm.fsrs7 => 1,
  SrsAlgorithm.rwkv => 2,
};

/// history.rs `RType` 的编码 → reviewType（持久化名）。
String srsReviewTypeOfCode(int code) => switch (code) {
  0 => SrsReviewType.learn,
  1 => SrsReviewType.review,
  2 => SrsReviewType.relearn,
  3 => SrsReviewType.filtered,
  4 => SrsReviewType.manual,
  5 => SrsReviewType.rescheduled,
  _ => '',
};

int _reviewTypeCode(String t) => switch (t) {
  SrsReviewType.learn => 0,
  SrsReviewType.review => 1,
  SrsReviewType.relearn => 2,
  SrsReviewType.filtered => 3,
  SrsReviewType.manual => 4,
  SrsReviewType.rescheduled => 5,
  _ => 6,
};

/// `[u32 偏移 × (n + 1)][UTF-8]` 串表。
List<String> _strings(Uint8List bytes, int at, int n) {
  final ByteData d = ByteData.sublistView(bytes);
  final int body = at + (n + 1) * 4;
  return <String>[
    for (int k = 0; k < n; k++)
      utf8.decode(
        Uint8List.sublistView(
          bytes,
          body + d.getUint32(at + 4 * k, Endian.little),
          body + d.getUint32(at + 4 * (k + 1), Endian.little),
        ),
      ),
  ];
}

// ---------------------------------------------------------------- 优化器

/// 优化器训练集（`ffsrs_store_optimizer_items` 的输出，原样跨 isolate：只有一块字节）。
///
/// 序列 = 一张进训练集的卡的完整评审；条目 = 它到第 len 次评分为止的前缀，按最后一次评分时刻升序。
/// [items] / [cardIds] 在第一次读时才展开成 FSRS 引擎要的对象（在拟合用的后台 isolate 里）。
class SrsTrainingSet {
  SrsTrainingSet(this.bytes)
    : _d = ByteData.sublistView(bytes),
      seqCount = ByteData.sublistView(bytes).getInt64(0, Endian.little),
      reviewTotal = ByteData.sublistView(bytes).getInt64(8, Endian.little),
      itemCount = ByteData.sublistView(bytes).getInt64(16, Endian.little);

  /// 空训练集（没有卡）。
  factory SrsTrainingSet.empty() => SrsTrainingSet(Uint8List(32));

  final Uint8List bytes;
  final ByteData _d;
  final int seqCount;
  final int reviewTotal;

  /// 进训练集的评分条数（门槛与基线用）。
  final int itemCount;

  int _w(int k) => _d.getInt64(8 * k, Endian.little);
  int get _seqStart => 3;
  int get _seqCard => _seqStart + seqCount + 1;
  int get _ratings => _seqCard + seqCount;
  int get _deltas => _ratings + reviewTotal;
  int get _items => _deltas + reviewTotal;

  /// 换成 FSRS 引擎的打包训练集（每张卡一份完整历史 + 按时刻排好的（卡，前缀长度）条目，前缀在
  /// `ffsrs_fit` 里展开）。第一次读时转换（在拟合用的后台 isolate 里），O(总评分数)。
  late final SrsFsrsTrainingSet fsrs = () {
    final Uint8List ratings = Uint8List(reviewTotal);
    final Float32List deltas = Float32List(reviewTotal);
    for (int r = 0; r < reviewTotal; r++) {
      ratings[r] = _w(_ratings + r);
      deltas[r] = _d.getFloat64(8 * (_deltas + r), Endian.little);
    }
    final Uint32List offsets = Uint32List(seqCount + 1);
    final Int64List ids = Int64List(seqCount);
    for (int c = 0; c <= seqCount; c++) {
      offsets[c] = _w(_seqStart + c);
      if (c < seqCount) ids[c] = _w(_seqCard + c);
    }
    final Uint32List itemCards = Uint32List(itemCount);
    final Uint32List itemLengths = Uint32List(itemCount);
    for (int i = 0; i < itemCount; i++) {
      itemCards[i] = _w(_items + 2 * i);
      itemLengths[i] = _w(_items + 2 * i + 1);
    }
    return SrsFsrsTrainingSet(
      ratings: ratings,
      deltaDays: deltas,
      cardOffsets: offsets,
      cardIds: ids,
      itemCards: itemCards,
      itemLengths: itemLengths,
    );
  }();
}

// ---------------------------------------------------------------- RWKV

/// 一张卡最后一条**保留**评分的摘要：「此刻」这一行的 card_type 与间隔只取决于它。
class SrsRwkvLastRating {
  const SrsRwkvLastRating({
    required this.at,
    required this.rating,
    required this.reviewType,
  });

  final int at;
  final int rating;
  final String reviewType;
}

/// 一张卡的回放视图（`ffsrs_store_rwkv_rows` 逐卡模式）。
class SrsRwkvCardRows {
  const SrsRwkvCardRows({
    required this.keptIds,
    required this.effectiveRatings,
    required this.last,
    required this.rows,
  });

  /// 保留评分的日志 ID（时间顺序）。
  final List<String> keptIds;

  /// 有效评分条数（含学习序列重启丢掉的那些）。
  final int effectiveRatings;
  final SrsRwkvLastRating? last;

  /// 与 [keptIds] 一一对应的回放行。
  final RwkvRows rows;

  /// 第 [i] 行（单独一行的 [RwkvRows]）。
  RwkvRows row(int i) => RwkvRows.fromBytes(
    Uint8List.sublistView(
      rows.bytes,
      i * kFrwkvReviewSize,
      (i + 1) * kFrwkvReviewSize,
    ),
  );

  /// 增量追加（`srsRwkvAppendRows` 的判据）：[logIds]（按时间先后）必须正好是保留评分的末尾几条，
  /// 且不是学习序列重启（上游丢弃了这张卡更早的评分，增量追加撤不回它们）。返回每条一行；不成立时 null。
  List<RwkvRows>? appendRows(List<String> logIds) {
    final int first = keptIds.length - logIds.length;
    if (logIds.isEmpty || first < 0) return null;
    for (int j = 0; j < logIds.length; j++) {
      if (keptIds[first + j] != logIds[j]) return null;
    }
    if (first == 0 && effectiveRatings > logIds.length) return null;
    return <RwkvRows>[for (int i = first; i < keptIds.length; i++) row(i)];
  }
}

List<SrsRwkvCardRows> srsDecodeRwkvCards(Uint8List bytes) {
  final ByteData d = ByteData.sublistView(bytes);
  int w(int k) => d.getInt64(8 * k, Endian.little);
  final int n = w(0);
  int total = 0;
  for (int g = 0; g < n; g++) {
    total += w(1 + 6 * g);
  }
  final int rowsAt = 8 * (1 + 6 * n);
  final List<String> ids = _strings(
    bytes,
    rowsAt + total * kFrwkvReviewSize,
    total,
  );
  final List<SrsRwkvCardRows> out = <SrsRwkvCardRows>[];
  int k = 0;
  for (int g = 0; g < n; g++) {
    final int b = 1 + 6 * g;
    final int kept = w(b);
    out.add(
      SrsRwkvCardRows(
        keptIds: ids.sublist(k, k + kept),
        effectiveRatings: w(b + 1),
        last: w(b + 2) == _none
            ? null
            : SrsRwkvLastRating(
                at: w(b + 2),
                rating: w(b + 3),
                reviewType: srsReviewTypeOfCode(w(b + 4)),
              ),
        rows: RwkvRows.fromBytes(
          Uint8List.fromList(
            Uint8List.sublistView(
              bytes,
              rowsAt + k * kFrwkvReviewSize,
              rowsAt + (k + kept) * kFrwkvReviewSize,
            ),
          ),
        ),
      ),
    );
    k += kept;
  }
  return out;
}

/// 全量回放（`ffsrs_store_rwkv_rows` 回放模式）。
class SrsRwkvReplay {
  const SrsRwkvReplay({
    required this.count,
    required this.maxRowId,
    required this.lastAt,
    required this.rows,
    required this.strays,
  });

  /// 日志指纹（与 [rows] 出自同一个快照）。
  final int count;
  final int maxRowId;

  /// 最后一条回放行的评分时刻；没有评分时 null。
  final int? lastAt;

  /// 按评分时刻排好序的行。
  final RwkvRows rows;

  /// 调用方列卡之后才出现日志、不在任何血统里的卡。
  final List<String> strays;
}

SrsRwkvReplay srsDecodeRwkvReplay(Uint8List bytes) {
  final ByteData d = ByteData.sublistView(bytes);
  int w(int k) => d.getInt64(8 * k, Endian.little);
  final int n = w(3);
  const int rowsAt = 40;
  return SrsRwkvReplay(
    count: w(0),
    maxRowId: w(1),
    lastAt: w(2) == _none ? null : w(2),
    rows: RwkvRows.fromBytes(
      Uint8List.sublistView(bytes, rowsAt, rowsAt + n * kFrwkvReviewSize),
    ),
    strays: _strings(bytes, rowsAt + n * kFrwkvReviewSize, w(4)),
  );
}

/// 一条对齐用的新日志（rowid 在指纹之后）。
/// [kind] 是日志 kind（review / undo；其它 kind 为空串——对齐只认这两种），[revokes] 是 undo 的撤销目标。
typedef SrsRwkvTailLog = ({
  String id,
  String cardId,
  String kind,
  int at,
  String? revokes,
});

/// RWKV 对齐的日志指纹与尾巴（`ffsrs_store_rwkv_log_tail`，同一个快照）。
class SrsRwkvLogTail {
  const SrsRwkvLogTail({
    required this.count,
    required this.maxRowId,
    required this.newRows,
    required this.logs,
  });

  final int count;
  final int maxRowId;

  /// rowid 在给定位置之后的行数。
  final int newRows;

  /// 这些新行（按发生时刻、rowid）；没要时为空。
  final List<SrsRwkvTailLog> logs;
}

SrsRwkvLogTail srsDecodeRwkvLogTail(Uint8List bytes) {
  final ByteData d = ByteData.sublistView(bytes);
  int w(int k) => d.getInt64(8 * k, Endian.little);
  final int n = w(3);
  final List<String> s = _strings(bytes, 8 * (4 + 2 * n), 3 * n);
  return SrsRwkvLogTail(
    count: w(0),
    maxRowId: w(1),
    newRows: w(2),
    logs: <SrsRwkvTailLog>[
      for (int i = 0; i < n; i++)
        (
          id: s[3 * i],
          cardId: s[3 * i + 1],
          kind: switch (w(4 + n + i)) {
            1 => SrsLogKind.review,
            2 => SrsLogKind.undo,
            _ => '',
          },
          at: w(4 + i),
          revokes: s[3 * i + 2].isEmpty ? null : s[3 * i + 2],
        ),
    ],
  );
}

/// 「这张卡此刻」的回放行输入（ease 0）：RWKV-Instant 排队查此刻的 R，也是作答时「此刻作答」的行。
typedef SrsRwkvNowCard = ({
  int cardId,
  int noteId,
  int deckId,
  int presetId,
  SrsRwkvLastRating? last,
  SrsQueue queue,
});

/// 一批「此刻」行（card_type / 间隔规则在 projection.rs `push_rwkv_now_row`，整批一次 FFI）。
///
/// [atMs] 非空时是每行各自的「此刻」（与 [cards] 同序，统计页预测到期时各卡查不同的未来时刻），
/// 这时 [nowMs] 不用。
RwkvRows srsRwkvNowRows(
  List<SrsRwkvNowCard> cards, {
  required int nowMs,
  required SrsDayContext day,
  List<int>? atMs,
  FushiFsrs? library,
}) {
  final FushiFsrs lib =
      library ??
      FushiFsrs.instance ??
      (throw SrsHistoryKernelUnavailableError());
  const int words = 9;
  final int n = cards.length;
  if (atMs != null && atMs.length != n) {
    throw ArgumentError.value(atMs.length, 'atMs', 'must match cards ($n)');
  }
  final Pointer<Int64> ints = malloc<Int64>(n == 0 ? 1 : n * words);
  final Pointer<Size> outLen = calloc<Size>();
  final Pointer<Pointer<Char>> error = calloc<Pointer<Char>>();
  try {
    final Int64List c = ints.asTypedListOutOfLine(n == 0 ? 1 : n * words);
    for (int i = 0; i < n; i++) {
      final SrsRwkvNowCard x = cards[i];
      final SrsRwkvLastRating? last = x.last;
      c.setAll(i * words, <int>[
        x.cardId,
        x.noteId,
        x.deckId,
        x.presetId,
        last?.at ?? _none,
        last?.rating ?? 0,
        last == null ? 0 : _reviewTypeCode(last.reviewType),
        x.queue.index,
        atMs?[i] ?? nowMs,
      ]);
    }
    final Pointer<Uint8> out = lib.bindings.ffsrs_rwkv_now_rows(
      ints,
      n,
      day.utcOffsetMin,
      day.rolloverHour,
      outLen,
      error,
    );
    if (out == nullptr) {
      final Pointer<Char> e = error.value;
      final String message = e == nullptr
          ? 'rwkv now rows failed'
          : e.cast<Utf8>().toDartString();
      if (e != nullptr) lib.bindings.ffsrs_free_string(e);
      throw FormatException(message);
    }
    final int len = outLen.value;
    try {
      return RwkvRows.fromBytes(
        Uint8List.fromList(out.asTypedListOutOfLine(len)),
      );
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
