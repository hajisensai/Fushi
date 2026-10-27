import 'dart:ffi';
import 'dart:typed_data';

import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _ClassOfC = Uint8 Function(Uint32);
typedef _ClassOfDart = int Function(int);
typedef _CountUtf16C =
    Int32 Function(Pointer<Uint16>, Size, Pointer<Uint64>, Pointer<Uint8>);
typedef _CountUtf16Dart =
    int Function(Pointer<Uint16>, int, Pointer<Uint64>, Pointer<Uint8>);
typedef _PrefixesC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Uint32>,
      Size,
      Pointer<Uint64>,
    );
typedef _PrefixesDart =
    int Function(Pointer<Uint16>, int, Pointer<Uint32>, int, Pointer<Uint64>);

/// 学习统计「字数」口径的原生实现（`native/fushi_compute/src/parse.rs` 的
/// `ffc_parse_study_char_class` / `ffc_parse_study_chars_utf16`）。
///
/// 这是该口径**唯一**的运行时实现：没有 Dart 回退。原生库或符号缺失时 [instance]
/// 抛 [FushiComputeUnavailableError]（说明缺什么、怎么指定库），不返回 null、不静默算出别的数。
///
/// 每个 isolate 各持一份实例与一块复用的原生暂存区（[NativeScratch]：随 isolate 存活，
/// 退出时由 finalizer 释放）。
final class StudyCharsNative implements Finalizable {
  StudyCharsNative._(this._classOf, this._countUtf16, this._prefixes);

  final _ClassOfDart _classOf;
  final _CountUtf16Dart _countUtf16;
  final _PrefixesDart _prefixes;

  /// 固定槽：count（u64）+ inWord（u8）。
  final NativeScratch _slots = NativeScratch.fixed(16);
  final NativeScratch _buffer = NativeScratch(minCapacity: 2048);

  static StudyCharsNative? _instance;

  /// 本 isolate 的实例（首次访问时加载并 lookup 符号）。
  static StudyCharsNative get instance => _instance ??= _load();

  static StudyCharsNative _load() {
    final FushiCompute compute = FushiCompute.require();
    // lookup 名写成字符串字面量：verify_abi.sh 从绑定源码抓期望符号集。
    try {
      return StudyCharsNative._(
        compute.library.lookupFunction<_ClassOfC, _ClassOfDart>(
          'ffc_parse_study_char_class',
          isLeaf: true,
        ),
        compute.library.lookupFunction<_CountUtf16C, _CountUtf16Dart>(
          'ffc_parse_study_chars_utf16',
          isLeaf: true,
        ),
        compute.library.lookupFunction<_PrefixesC, _PrefixesDart>(
          'ffc_parse_study_char_prefixes',
          isLeaf: true,
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  /// 码点 [codePoint] 的分类：0 断词不计 / 1 透明 / 2 每码点计 1 / 3 连续串计 1。
  int classOf(int codePoint) {
    if (codePoint < 0 || codePoint > 0x10FFFF) return 0;
    return _classOf(codePoint);
  }

  /// 从 ([count], [inWord]) 状态接着数 [text]，返回新状态。语义见
  /// `StudyCharCounter`（packages/fushi_engine/lib/stats/study_char_count.dart）。
  ({int count, bool inWord}) add(String text, int count, bool inWord) {
    final int length = text.length;
    if (length == 0) return (count: count, inWord: inWord);
    final Pointer<Uint16> buffer = _buffer.reserve(length * 2).cast<Uint16>();
    final Uint16List units = buffer.asTypedListOutOfLine(length);
    for (int i = 0; i < length; i++) {
      units[i] = text.codeUnitAt(i);
    }
    final Pointer<Uint64> countSlot = _slots.pointer.cast<Uint64>();
    final Pointer<Uint8> inWordSlot = _slots.pointer + 8;
    countSlot.value = count;
    inWordSlot.value = inWord ? 1 : 0;
    final int status = _countUtf16(buffer, length, countSlot, inWordSlot);
    if (status != FfcStatus.ok) {
      throw StateError(
        'ffc_parse_study_chars_utf16 failed with status $status',
      );
    }
    return (count: countSlot.value, inWord: inWordSlot.value != 0);
  }

  /// [text] 里多个位置（UTF-16 偏移，升序、不超过长度）的学习单位前缀数，一次 FFI 算完：
  /// 第 i 个结果 = `countStudyChars(text.substring(0, offsets[i]))`。
  List<int> prefixTotals(String text, List<int> offsets) {
    if (offsets.isEmpty) return const <int>[];
    final int length = text.length;
    final int n = offsets.length;
    // 一块暂存：文本 u16 | 偏移 u32（4 字节对齐）| 结果 u64（8 字节对齐）。
    final int textBytes = (length * 2 + 7) & ~7;
    final int offsetBytes = (n * 4 + 7) & ~7;
    final Pointer<Uint8> base = _buffer.reserve(
      textBytes + offsetBytes + n * 8,
    );
    final Pointer<Uint16> unitsPtr = base.cast<Uint16>();
    final Uint16List units = unitsPtr.asTypedListOutOfLine(length);
    for (int i = 0; i < length; i++) {
      units[i] = text.codeUnitAt(i);
    }
    final Pointer<Uint32> offsetsPtr = (base + textBytes).cast<Uint32>();
    offsetsPtr.asTypedListOutOfLine(n).setAll(0, offsets);
    final Pointer<Uint64> outPtr = (base + textBytes + offsetBytes)
        .cast<Uint64>();
    final int status = _prefixes(unitsPtr, length, offsetsPtr, n, outPtr);
    if (status != FfcStatus.ok) {
      throw StateError(
        'ffc_parse_study_char_prefixes failed with status $status',
      );
    }
    return List<int>.of(outPtr.asTypedListOutOfLine(n));
  }
}
