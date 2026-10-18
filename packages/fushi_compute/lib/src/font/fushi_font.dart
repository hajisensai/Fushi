import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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

/// `ffc_font_*`：字体容器解码（native/fushi_compute/src/font.rs）。
///
/// 原生库是硬依赖（各平台随包）：库或符号缺失时 [instance] / [FushiFont.of] 抛
/// [FushiComputeUnavailableError]，不退回任何 Dart 实现——WOFF2 解码只有 Rust 这一份。
class FushiFont {
  FushiFont._(this._lib, this._woff2ToSfnt);

  /// 解码符号名。
  static const String woff2ToSfntSymbol = 'ffc_font_woff2_to_sfnt';

  final FushiCompute _lib;
  final _Woff2ToSfntDart _woff2ToSfnt;

  static FushiFont? _default;

  /// 默认库（[FushiCompute.instance]）上的绑定；每个 isolate 各自加载一次。
  static FushiFont get instance {
    final FushiFont? cached = _default;
    if (cached != null) return cached;
    final FushiCompute? lib = FushiCompute.instance;
    if (lib == null) {
      throw FushiComputeUnavailableError(
        'fushi_compute native library not found (needed for WOFF2 decoding); '
        'set $kFushiComputeLibEnv or ship ${FushiCompute.defaultLibraryName()} '
        'with the app',
      );
    }
    return _default = FushiFont.of(lib);
  }

  /// 绑定到指定的已加载库（测试 / harness）。库里没有 [woff2ToSfntSymbol] 时抛 [FushiComputeUnavailableError]。
  factory FushiFont.of(FushiCompute lib) {
    if (!lib.providesSymbol(woff2ToSfntSymbol)) {
      throw FushiComputeUnavailableError(
        'fushi_compute library ${lib.libraryPath ?? '(process)'} does not '
        'export $woff2ToSfntSymbol; rebuild native/fushi_compute',
      );
    }
    return FushiFont._(
      lib,
      lib.library.lookupFunction<_Woff2ToSfntC, _Woff2ToSfntDart>(
        woff2ToSfntSymbol,
      ),
    );
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
      input.asTypedList(len).setAll(0, woff2);
      final int status = _woff2ToSfnt(input, len, outPtr, outLen);
      if (status == FfcStatus.badInput) return null;
      if (status != FfcStatus.ok) {
        throw StateError('$woff2ToSfntSymbol failed with status $status');
      }
      final int n = outLen.value;
      final Pointer<Uint8> out = outPtr.value;
      try {
        return Uint8List.fromList(out.asTypedList(n));
      } finally {
        _lib.freeBytes(out, n);
      }
    } finally {
      malloc.free(input);
      malloc.free(outPtr);
      malloc.free(outLen);
    }
  }
}
