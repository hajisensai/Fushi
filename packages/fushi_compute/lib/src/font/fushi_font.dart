import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';

typedef _Woff2ToSfntC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _Woff2ToSfntDart =
    int Function(Pointer<Uint8>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _TableChecksumC =
    Int32 Function(Pointer<Uint8>, Size, Int32, Pointer<Uint32>);
typedef _TableChecksumDart =
    int Function(Pointer<Uint8>, int, int, Pointer<Uint32>);

/// `ffc_font_*`：字体容器解码（native/fushi_compute/src/font.rs）。
///
/// 原生库是硬依赖：库不可用或缺字体域符号时 [instance] / [FushiFont.of] 抛
/// [FushiComputeUnavailableError]，不退回任何 Dart 实现——WOFF2 解码只有 Rust 这一份。
final class FushiFont {
  FushiFont._(this._compute, this._woff2ToSfnt, this._tableChecksum);

  final FushiCompute _compute;
  final _Woff2ToSfntDart _woff2ToSfnt;
  final _TableChecksumDart _tableChecksum;

  static final Expando<FushiFont> _cache = Expando<FushiFont>();

  /// 默认库（[FushiCompute.require]）上的绑定；每个 isolate 各自加载一次。
  static FushiFont get instance => FushiFont.of(FushiCompute.require());

  /// 绑定到指定的已加载库。缺字体域符号（库比绑定旧）抛 [FushiComputeUnavailableError]。
  ///
  /// lookup 名写成字符串字面量：`native/fushi_compute/verify_abi.sh` 从这里抓期望符号集。
  factory FushiFont.of(FushiCompute compute) {
    final FushiFont? cached = _cache[compute];
    if (cached != null) return cached;
    try {
      return _cache[compute] = FushiFont._(
        compute,
        compute.library.lookupFunction<_Woff2ToSfntC, _Woff2ToSfntDart>(
          'ffc_font_woff2_to_sfnt',
        ),
        compute.library.lookupFunction<_TableChecksumC, _TableChecksumDart>(
          'ffc_font_table_checksum',
          isLeaf: true,
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('font', e.message ?? e);
    }
  }

  /// WOFF2 → 裸 sfnt（Flutter `FontLoader` / 阅读器下发用）。
  ///
  /// [woff2] 不是可解码的 WOFF2（签名不对、截断、Brotli 流坏、字体集合）时返回 null，
  /// 调用方跳过这个字体而不是注册坏字体。原生侧 panic 等意外状态抛 [StateError]。
  Uint8List? woff2ToSfnt(Uint8List woff2) {
    final int len = woff2.length;
    final Pointer<Uint8> input = malloc<Uint8>(len == 0 ? 1 : len);
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    try {
      input.asTypedListOutOfLine(len).setAll(0, woff2);
      final int status = _woff2ToSfnt(input, len, outPtr, outLen);
      if (status == FfcStatus.badInput) return null;
      if (status != FfcStatus.ok) {
        throw StateError('ffc_font_woff2_to_sfnt failed with status $status');
      }
      final int n = outLen.value;
      final Pointer<Uint8> out = outPtr.value;
      try {
        return Uint8List.fromList(out.asTypedListOutOfLine(n));
      } finally {
        _compute.freeBytes(out, n);
      }
    } finally {
      malloc.free(input);
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }

  /// OpenType 表校验和：[data] 的 `[offset, offset + length)` 按大端 uint32 回绕求和，
  /// 尾部不足 4 字节补 0；[headTable] 时偏移 8 的字（`checkSumAdjustment`）按 0 算。
  /// 整字体校验和（算 `checkSumAdjustment` 用）就是对整份 sfnt 求和。
  ///
  /// [length] 缺省到 [data] 末尾。越界抛 [RangeError]。
  int tableChecksum(
    Uint8List data, {
    int offset = 0,
    int? length,
    bool headTable = false,
  }) {
    final int len = length ?? data.length - offset;
    RangeError.checkValidRange(offset, offset + len, data.length);
    final Pointer<Uint8> buf = malloc<Uint8>(len == 0 ? 1 : len);
    final Pointer<Uint32> out = malloc<Uint32>();
    try {
      buf.asTypedListOutOfLine(len).setRange(0, len, data, offset);
      final int status = _tableChecksum(buf, len, headTable ? 1 : 0, out);
      if (status != FfcStatus.ok) {
        throw StateError('ffc_font_table_checksum failed with status $status');
      }
      return out.value;
    } finally {
      malloc.free(buf);
      malloc.free(out);
    }
  }
}
