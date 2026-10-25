/// 卡片历史内核（native/fushi_fsrs/src/history.rs）的 Dart 封装：有效日志选取与当前排程状态只在
/// Rust 里写一份，这里只做打包 / 解包。设计见 docs/specs/2026-10-23-srs-rust-core.md「第一阶段」。
///
/// 两个批量入口，一次 FFI 调用处理一整批历史（逐卡跨 FFI 比 Dart 自己算还慢）：
/// - [srsHistoryStatesFromJson]：落库形态（canonical JSON 原文的 UTF-8 字节 + 服务器时刻）→ 当前状态。
///   缓存刷新走这条，日志不在 Dart 侧解码。
/// - [srsSelectHistories]：内存里的 [SrsReviewLog] → 排序与选取标记（[SrsCardHistory] 的构造）。
///
/// 原生库是硬依赖：加载失败抛 [SrsHistoryKernelUnavailableError]，没有 Dart 回退。
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import 'ffi/fushi_fsrs_library.dart';
import 'fsrs_engine.dart';
import 'review_log.dart';

/// 原生卡片历史内核（fushi_fsrs）不可用：库没随包 / 编出来的库缺 `ffsrs_history_*` 符号。
final class SrsHistoryKernelUnavailableError extends StateError {
  SrsHistoryKernelUnavailableError()
    : super(
        'card history kernel (fushi_fsrs ffsrs_history_*) is not available; '
        'build native/fushi_fsrs (tool/native_libs.ps1) or set FUSHI_FSRS_LIB',
      );
}

/// 「没有」在 i64 列里的哨兵（history.rs `NONE_I64`）。
const int _none = -0x8000000000000000;

/// history.rs `STATE_WORDS`。
const int _stateWords = 14;

/// history.rs `COLUMN_WORDS`。
const int _columnWords = 7;

/// history.rs 的 `STATUS_*` 位。
const int srsHistoryEffective = 1;
const int srsHistoryRevoked = 2;
const int srsHistoryEquivalentImport = 4;
const int srsHistoryRevoker = 8;

/// 排序键的物理部分被钳位（HLC 物理时间超过 S(e) + 10 分钟；history.rs `STATUS_CLAMPED`）。
const int srsHistoryClamped = 16;

FushiFsrs _library(FushiFsrs? library) =>
    library ?? FushiFsrs.instance ?? (throw SrsHistoryKernelUnavailableError());

/// 一份卡片历史的当前状态（[srsHistoryStatesFromJson] 的结果）。
class SrsHistoryState {
  const SrsHistoryState({required this.result, required this.lastLogId});

  /// 当前排程状态 = Dart `SrsCardHistory.state`（排程归属已覆盖）。
  final SrsScheduleResult result;

  /// 最后一条有结果的有效日志 ID（`SrsCardHistory.lastEffective?.id`）。
  final String? lastLogId;
}

/// 一份待算的落库形态历史：每条日志的 canonical JSON 原文（UTF-8）与服务器时刻 S(e)。
typedef SrsStoredHistory = List<(Uint8List json, int? serverTime)>;

/// 一批历史（落库形态）的当前状态，与输入同序。坏数据（与 `SrsReviewLog.fromJson` 判坏的同一类）
/// 抛 [FormatException]。
List<SrsHistoryState> srsHistoryStatesFromJson(
  List<SrsStoredHistory> histories, {
  FushiFsrs? library,
}) {
  if (histories.isEmpty) return const <SrsHistoryState>[];
  final FushiFsrs lib = _library(library);
  int nLogs = 0;
  int total = 0;
  for (final SrsStoredHistory h in histories) {
    nLogs += h.length;
    for (final (Uint8List j, int? _) in h) {
      total += j.length;
    }
  }
  final Pointer<Uint8> text = malloc<Uint8>(total == 0 ? 1 : total);
  final Pointer<Uint32> offs = malloc<Uint32>(nLogs + 1);
  final Pointer<Int64> servers = malloc<Int64>(nLogs == 0 ? 1 : nLogs);
  final Pointer<Uint32> groups = malloc<Uint32>(histories.length + 1);
  final Pointer<Size> outLen = calloc<Size>();
  final Pointer<Pointer<Char>> error = calloc<Pointer<Char>>();
  try {
    final Uint8List t = text.asTypedListOutOfLine(total == 0 ? 1 : total);
    final Uint32List o = offs.asTypedListOutOfLine(nLogs + 1);
    final Int64List s = servers.asTypedListOutOfLine(nLogs == 0 ? 1 : nLogs);
    final Uint32List g = groups.asTypedListOutOfLine(histories.length + 1);
    int at = 0;
    int i = 0;
    o[0] = 0;
    g[0] = 0;
    for (int k = 0; k < histories.length; k++) {
      for (final (Uint8List j, int? st) in histories[k]) {
        t.setRange(at, at + j.length, j);
        at += j.length;
        s[i] = st ?? _none;
        o[++i] = at;
      }
      g[k + 1] = i;
    }
    final Pointer<Uint8> out = lib.bindings.ffsrs_history_states(
      text,
      total,
      offs,
      servers,
      nLogs,
      groups,
      histories.length,
      outLen,
      error,
    );
    if (out == nullptr) throw FormatException(_takeError(lib, error));
    final int len = outLen.value;
    try {
      return _decodeStates(out.asTypedListOutOfLine(len), histories.length);
    } finally {
      lib.bindings.ffsrs_free_bytes(out, len);
    }
  } finally {
    malloc
      ..free(text)
      ..free(offs)
      ..free(servers)
      ..free(groups);
    calloc
      ..free(outLen)
      ..free(error);
  }
}

String _takeError(FushiFsrs lib, Pointer<Pointer<Char>> error) {
  final Pointer<Char> p = error.value;
  if (p == nullptr) return 'card history kernel failed';
  try {
    return p.cast<Utf8>().toDartString();
  } finally {
    lib.bindings.ffsrs_free_string(p);
  }
}

/// 解出 [n] 份历史的状态（`ffsrs_history_states` / `ffsrs_store_history_states` 的同一布局）。
List<SrsHistoryState> srsDecodeHistoryStates(Uint8List bytes, int n) =>
    _decodeStates(bytes, n);

List<SrsHistoryState> _decodeStates(Uint8List bytes, int n) {
  final ByteData d = ByteData.sublistView(bytes);
  final int strTable = n * _stateWords * 8;
  final int strBody = strTable + (2 * n + 1) * 4;
  String str(int k) => utf8.decode(
    Uint8List.sublistView(
      bytes,
      strBody + d.getUint32(strTable + k * 4, Endian.little),
      strBody + d.getUint32(strTable + (k + 1) * 4, Endian.little),
    ),
  );
  return <SrsHistoryState>[
    for (int g = 0; g < n; g++) _decodeState(d, g * _stateWords * 8, str, g),
  ];
}

SrsHistoryState _decodeState(
  ByteData d,
  int base,
  String Function(int k) str,
  int g,
) {
  int w(int k) => d.getInt64(base + k * 8, Endian.little);
  double f(int k) => d.getFloat64(base + k * 8, Endian.little);
  final int flags = w(0);
  return SrsHistoryState(
    result: SrsScheduleResult(
      queue: SrsQueue.values[w(1)],
      dueDay: flags & 2 != 0 ? w(2) : null,
      dueAt: flags & 4 != 0 ? w(3) : null,
      scheduledDays: w(4),
      learningStep: w(5),
      reps: w(6),
      lapses: w(7),
      lastReviewedAt: flags & 16 != 0 ? w(8) : null,
      ease: flags & 32 != 0 ? w(9) : null,
      memory: flags & 8 != 0
          ? SrsMemory(stability: f(10), difficulty: f(11), stabilityFast: f(12))
          : null,
      scheduler: str(2 * g + 1),
    ),
    lastLogId: flags & 1 != 0 ? str(2 * g) : null,
  );
}

/// Anki 导入器入库前判重：每组（导入日志, 这张逻辑卡的原生日志）里，导入日志与某条原生日志是不是
/// 同一次复习（两条都是评分类复习、评分相同、Anki revlog 时刻与原生发生时刻相差 ≤ 1 秒）。判据与卡片
/// 历史选取里的等价导入是 history.rs 同一个函数。整批一次 FFI 调用，与输入同序。
List<bool> srsImportEquivalentAny(
  List<(SrsReviewLog imported, List<SrsReviewLog> natives)> groups, {
  FushiFsrs? library,
}) {
  if (groups.isEmpty) return const <bool>[];
  final FushiFsrs lib = _library(library);
  final List<Uint8List> logs = <Uint8List>[
    for (final (SrsReviewLog i, List<SrsReviewLog> ns)
        in groups) ...<Uint8List>[
      utf8.encode(i.canonical()),
      for (final SrsReviewLog n in ns) utf8.encode(n.canonical()),
    ],
  ];
  int total = 0;
  for (final Uint8List j in logs) {
    total += j.length;
  }
  final Pointer<Uint8> text = malloc<Uint8>(total == 0 ? 1 : total);
  final Pointer<Uint32> offs = malloc<Uint32>(logs.length + 1);
  final Pointer<Uint32> bounds = malloc<Uint32>(groups.length + 1);
  final Pointer<Size> outLen = calloc<Size>();
  final Pointer<Pointer<Char>> error = calloc<Pointer<Char>>();
  try {
    final Uint8List t = text.asTypedListOutOfLine(total == 0 ? 1 : total);
    final Uint32List o = offs.asTypedListOutOfLine(logs.length + 1);
    final Uint32List g = bounds.asTypedListOutOfLine(groups.length + 1);
    int at = 0;
    o[0] = 0;
    for (int i = 0; i < logs.length; i++) {
      t.setRange(at, at + logs[i].length, logs[i]);
      at += logs[i].length;
      o[i + 1] = at;
    }
    g[0] = 0;
    for (int k = 0; k < groups.length; k++) {
      g[k + 1] = g[k] + 1 + groups[k].$2.length;
    }
    final Pointer<Uint8> out = lib.bindings.ffsrs_import_equivalent(
      text,
      total,
      offs,
      logs.length,
      bounds,
      groups.length,
      outLen,
      error,
    );
    if (out == nullptr) throw FormatException(_takeError(lib, error));
    final int len = outLen.value;
    try {
      return <bool>[for (final int b in out.asTypedListOutOfLine(len)) b == 1];
    } finally {
      lib.bindings.ffsrs_free_bytes(out, len);
    }
  } finally {
    malloc
      ..free(text)
      ..free(offs)
      ..free(bounds);
    calloc
      ..free(outLen)
      ..free(error);
  }
}

/// 一份历史的选取结果（[srsSelectHistories]）：下标指向该份历史的输入列表。
class SrsHistorySelection {
  const SrsHistorySelection({
    required this.order,
    required this.status,
    required this.lastEffective,
    required this.schedulerFrom,
  });

  /// 去重（同 ID 留最后一条）后按排序键升序的输入下标。
  final List<int> order;

  /// 与 [order] 一一对应的 `srsHistory*` 位。
  final List<int> status;

  /// 最后一条有结果的有效日志的下标；没有 = -1。
  final int lastEffective;

  /// 决定排程归属的 handOff 日志的下标；没有 = -1。
  final int schedulerFrom;
}

/// 一份待选取的内存历史：日志与它们的服务器时刻。
typedef SrsHistoryInput = (
  List<SrsReviewLog> logs,
  int? Function(String eventId)? serverTimeOf,
);

/// 一批内存历史的选取，与输入同序；空历史不进原生侧。
List<SrsHistorySelection> srsSelectHistories(
  List<SrsHistoryInput> histories, {
  FushiFsrs? library,
}) {
  int nLogs = 0;
  for (final SrsHistoryInput h in histories) {
    nLogs += h.$1.length;
  }
  if (nLogs == 0) {
    return <SrsHistorySelection>[
      for (int i = 0; i < histories.length; i++) _emptySelection,
    ];
  }
  final FushiFsrs lib = _library(library);
  final _Utf8Packer strings = _Utf8Packer(nLogs * 3);
  final Pointer<Int64> ints = malloc<Int64>(nLogs * _columnWords);
  final Pointer<Uint32> groups = malloc<Uint32>(histories.length + 1);
  final Pointer<Size> outLen = calloc<Size>();
  final Pointer<Pointer<Char>> error = calloc<Pointer<Char>>();
  Pointer<Uint8> text = nullptr;
  Pointer<Uint32> offs = nullptr;
  try {
    final Int64List c = ints.asTypedListOutOfLine(nLogs * _columnWords);
    final Uint32List g = groups.asTypedListOutOfLine(histories.length + 1);
    int i = 0;
    g[0] = 0;
    for (int k = 0; k < histories.length; k++) {
      final (List<SrsReviewLog> logs, int? Function(String)? st) = histories[k];
      for (final SrsReviewLog l in logs) {
        final int b = i * _columnWords;
        c[b] = l.hlc.physical;
        c[b + 1] = l.hlc.counter;
        c[b + 2] = st?.call(l.id) ?? _none;
        c[b + 3] = l.occurredAt;
        c[b + 4] = l.ankiRevlogId ?? _none;
        c[b + 5] = l.rating ?? _none;
        c[b + 6] = _bits(l);
        strings
          ..add(l.id)
          ..add(l.hlc.writerId)
          ..add(l.revokesId ?? '');
        i++;
      }
      g[k + 1] = i;
    }
    (text, offs) = strings.toNative();
    final Pointer<Uint8> out = lib.bindings.ffsrs_history_select(
      ints,
      nLogs,
      text,
      strings.length,
      offs,
      groups,
      histories.length,
      outLen,
      error,
    );
    if (out == nullptr) throw FormatException(_takeError(lib, error));
    final int len = outLen.value;
    try {
      return _decodeSelections(out.asTypedListOutOfLine(len), histories);
    } finally {
      lib.bindings.ffsrs_free_bytes(out, len);
    }
  } finally {
    malloc
      ..free(ints)
      ..free(groups);
    if (text != nullptr) malloc.free(text);
    if (offs != nullptr) malloc.free(offs);
    calloc
      ..free(outLen)
      ..free(error);
  }
}

const SrsHistorySelection _emptySelection = SrsHistorySelection(
  order: <int>[],
  status: <int>[],
  lastEffective: -1,
  schedulerFrom: -1,
);

/// history.rs `COLUMN_WORDS` 的 bits 列：kind 编码、origin、评分类 reviewType、有结果、有 revokes。
int _bits(SrsReviewLog l) {
  final int kind = switch (l.kind) {
    SrsLogKind.review => 0,
    SrsLogKind.manual => 1,
    SrsLogKind.reschedule => 2,
    SrsLogKind.importAnchor => 3,
    SrsLogKind.handOff => 4,
    SrsLogKind.undo => 5,
    _ => 6,
  };
  final int origin = switch (l.origin) {
    SrsLogOrigin.fushi => 0,
    SrsLogOrigin.anki => 1,
    _ => 2,
  };
  return kind |
      origin << 3 |
      (SrsReviewType.rating.contains(l.reviewType) ? 1 << 5 : 0) |
      (l.result != null ? 1 << 6 : 0) |
      (l.revokesId != null ? 1 << 7 : 0);
}

List<SrsHistorySelection> _decodeSelections(
  Uint8List bytes,
  List<SrsHistoryInput> histories,
) {
  final ByteData d = ByteData.sublistView(bytes);
  final int n = histories.length;
  final int total = d.getUint32(n * 4, Endian.little);
  final int orderAt = (n + 1) * 4;
  final int lastAt = orderAt + total * 4;
  final int schedAt = lastAt + n * 4;
  final int statusAt = schedAt + n * 4;
  final List<SrsHistorySelection> out = <SrsHistorySelection>[];
  int base = 0;
  for (int k = 0; k < n; k++) {
    final int a = d.getUint32(k * 4, Endian.little);
    final int b = d.getUint32((k + 1) * 4, Endian.little);
    final int last = d.getInt32(lastAt + k * 4, Endian.little);
    final int sched = d.getInt32(schedAt + k * 4, Endian.little);
    out.add(
      SrsHistorySelection(
        order: <int>[
          for (int j = a; j < b; j++)
            d.getUint32(orderAt + j * 4, Endian.little) - base,
        ],
        // 拷出来：[bytes] 是原生缓冲区，返回后就释放。
        status: Uint8List.fromList(
          Uint8List.sublistView(bytes, statusAt + a, statusAt + b),
        ),
        lastEffective: last < 0 ? -1 : last - base,
        schedulerFrom: sched < 0 ? -1 : sched - base,
      ),
    );
    base += histories[k].$1.length;
  }
  return out;
}

/// 一批短串打包成一块 UTF-8 + 偏移表（ASCII 直写，不逐串分配）。
class _Utf8Packer {
  _Utf8Packer(int count) : _offs = Uint32List(count + 1);

  Uint8List _buf = Uint8List(4096);
  final Uint32List _offs;
  int length = 0;
  int _n = 0;

  void add(String s) {
    _reserve(s.length * 3);
    bool ascii = true;
    for (int i = 0; i < s.length; i++) {
      final int u = s.codeUnitAt(i);
      if (u >= 0x80) {
        ascii = false;
        break;
      }
      _buf[length + i] = u;
    }
    if (ascii) {
      length += s.length;
    } else {
      final Uint8List e = utf8.encode(s);
      _buf.setRange(length, length + e.length, e);
      length += e.length;
    }
    _offs[++_n] = length;
  }

  void _reserve(int extra) {
    if (length + extra <= _buf.length) return;
    int cap = _buf.length * 2;
    while (cap < length + extra) {
      cap *= 2;
    }
    _buf = Uint8List(cap)..setRange(0, length, _buf);
  }

  /// 拷进原生内存；两块都由调用方 `malloc.free`。
  (Pointer<Uint8>, Pointer<Uint32>) toNative() {
    final Pointer<Uint8> text = malloc<Uint8>(length == 0 ? 1 : length);
    final Pointer<Uint32> offs = malloc<Uint32>(_offs.length);
    if (length > 0) text.asTypedListOutOfLine(length).setRange(0, length, _buf);
    offs.asTypedListOutOfLine(_offs.length).setAll(0, _offs);
    return (text, offs);
  }
}
