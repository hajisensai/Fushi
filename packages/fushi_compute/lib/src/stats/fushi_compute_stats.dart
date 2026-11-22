import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';

typedef _DeriveC =
    Int32 Function(
      Pointer<Int64>,
      Size,
      Pointer<Uint32>,
      Size,
      Pointer<Uint16>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _DeriveDart =
    int Function(
      Pointer<Int64>,
      int,
      Pointer<Uint32>,
      int,
      Pointer<Uint16>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

/// `ffc_stats_derive` 的输入打包器：整数流 + 字符串流（UTF-16 码元首尾相接 + 每个
/// 字符串的结束偏移）。表的顺序与字段见 `native/fushi_compute/src/stats.rs` 文件头；
/// 写什么、按什么顺序写由唯一调用方（`fushi_engine` 的统计事实面）决定。
final class FfcStatInput {
  Int64List _ints = Int64List(256);
  int _intCount = 0;
  Uint32List _ends = Uint32List(256);
  int _strCount = 0;
  Uint16List _text = Uint16List(4096);
  int _textLen = 0;

  /// 追加一个整数。
  void int64(int value) {
    if (_intCount == _ints.length) {
      _ints = Int64List(_ints.length * 2)..setAll(0, _ints);
    }
    _ints[_intCount++] = value;
  }

  /// 追加一个字符串（按 UTF-16 码元原样，不经 UTF-8）。
  void string(String value) {
    final int n = value.length;
    if (_textLen + n > _text.length) {
      int next = _text.length * 2;
      while (next < _textLen + n) {
        next *= 2;
      }
      _text = Uint16List(next)..setAll(0, _text);
    }
    if (n > 0) _text.setRange(_textLen, _textLen + n, value.codeUnits);
    _textLen += n;
    if (_strCount == _ends.length) {
      _ends = Uint32List(_ends.length * 2)..setAll(0, _ends);
    }
    _ends[_strCount++] = _textLen;
  }
}

/// `ffc_stats_derive` 的快照：整数流 + 去重后的字符串表（整数流里的字符串是表下标）。
final class FfcStatSnapshot {
  FfcStatSnapshot._(this.ints, this.strings);

  final Int64List ints;
  final List<String> strings;
}

/// native/fushi_compute 学习统计派生域（`ffc_stats_*`，`src/stats.rs`）的绑定。
///
/// 硬依赖、没有 Dart 回退：库不可用或缺符号时 [instance] 抛 [FushiComputeUnavailableError]。
/// 每个 isolate 各自加载一次（统计事实面在后台 isolate 里调它）。
final class FushiComputeStats {
  FushiComputeStats._(this._compute, this._derive);

  final FushiCompute _compute;
  final _DeriveDart _derive;

  static final Expando<FushiComputeStats> _cache = Expando<FushiComputeStats>();

  /// 默认库（[FushiCompute.require]）上的绑定。
  static FushiComputeStats get instance =>
      FushiComputeStats.of(FushiCompute.require());

  /// 绑定到指定的已加载库。缺本域符号（库比绑定旧）抛 [FushiComputeUnavailableError]。
  ///
  /// lookup 名写成字符串字面量：`native/fushi_compute/verify_abi.sh` 从这里抓期望符号集。
  factory FushiComputeStats.of(FushiCompute compute) {
    final FushiComputeStats? cached = _cache[compute];
    if (cached != null) return cached;
    try {
      return _cache[compute] = FushiComputeStats._(
        compute,
        compute.library.lookupFunction<_DeriveC, _DeriveDart>(
          'ffc_stats_derive',
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('stats', e.message ?? e);
    }
  }

  /// 整份派生：[input] → 快照。输入格式不符（版本、越界、多余数据）抛 [FormatException]，
  /// 原生侧其它失败（panic 等）抛 [StateError]。
  ///
  /// 大库上是几十毫秒的同步调用：调用方必须在后台 isolate 里调（统计事实面就是）。
  FfcStatSnapshot derive(FfcStatInput input) {
    final int nInts = input._intCount;
    final int nEnds = input._strCount;
    final int nText = input._textLen;
    // 长度为 0 时也交非空指针（原生侧只对空指针报错）。
    final Pointer<Int64> ints = malloc<Int64>(nInts == 0 ? 1 : nInts);
    final Pointer<Uint32> ends = malloc<Uint32>(nEnds == 0 ? 1 : nEnds);
    final Pointer<Uint16> text = malloc<Uint16>(nText == 0 ? 1 : nText);
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    try {
      ints.asTypedListOutOfLine(nInts).setRange(0, nInts, input._ints);
      ends.asTypedListOutOfLine(nEnds).setRange(0, nEnds, input._ends);
      text.asTypedListOutOfLine(nText).setRange(0, nText, input._text);
      final int status = _derive(
        ints,
        nInts,
        ends,
        nEnds,
        text,
        nText,
        outPtr,
        outLen,
      );
      if (status == FfcStatus.badInput) {
        throw const FormatException('ffc_stats_derive: malformed input');
      }
      if (status != FfcStatus.ok) {
        throw StateError('ffc_stats_derive failed with status $status');
      }
      final Pointer<Uint8> out = outPtr.value;
      final int n = outLen.value;
      try {
        return _decode(out, n);
      } finally {
        _compute.freeBytes(out, n);
      }
    } finally {
      malloc.free(ints);
      malloc.free(ends);
      malloc.free(text);
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }

  static FfcStatSnapshot _decode(Pointer<Uint8> out, int n) {
    if (n < 24) throw StateError('ffc_stats_derive: short output ($n bytes)');
    final Uint64List header = out.cast<Uint64>().asTypedListOutOfLine(3);
    final int nInts = header[0];
    final int nEnds = header[1];
    final int nText = header[2];
    final int endsOffset = 24 + nInts * 8;
    final int textOffset = endsOffset + nEnds * 4;
    if (textOffset + nText * 2 != n) {
      throw StateError('ffc_stats_derive: inconsistent output length');
    }
    final Int64List ints = Int64List.fromList(
      (out + 24).cast<Int64>().asTypedListOutOfLine(nInts),
    );
    final Uint32List ends = (out + endsOffset)
        .cast<Uint32>()
        .asTypedListOutOfLine(nEnds);
    final Uint16List text = (out + textOffset)
        .cast<Uint16>()
        .asTypedListOutOfLine(nText);
    final List<String> strings = List<String>.generate(nEnds, (int i) {
      final int start = i == 0 ? 0 : ends[i - 1];
      return String.fromCharCodes(text, start, ends[i]);
    }, growable: false);
    return FfcStatSnapshot._(ints, strings);
  }
}
