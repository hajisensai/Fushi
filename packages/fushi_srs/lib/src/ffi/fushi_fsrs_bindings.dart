// 手写 FFI 绑定：native/fushi_fsrs/src/lib.rs 导出的 C ABI（`ffsrs_*`）。
//
// - ffsrs_call / ffsrs_compute_parameters 返回的 `char*` 一律由 ffsrs_free_string 释放；
// - ffsrs_zstd_decompress 返回的缓冲区由 ffsrs_free_bytes（带长度）释放。
// 高层封装见 ffi_fsrs_engine.dart，别在业务代码里直接调这些。
//
// lookup 名必须写成单引号字符串字面量（ffsrs_ 前缀）：native/fushi_fsrs/verify_abi.sh 用正则从本文件
// 抓期望符号集去核对产物导出表。
//
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi' as ffi;

typedef _CallC = ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>);
typedef _ComputeC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Int64>,
    );
typedef _FreeStringC = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _FreeStringDart = void Function(ffi.Pointer<ffi.Char>);
typedef _ZstdC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Size>,
    );
typedef _ZstdDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Size>,
    );
typedef _FreeBytesC = ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _FreeBytesDart = void Function(ffi.Pointer<ffi.Uint8>, int);
typedef _AbiVersionC = ffi.Int32 Function();
typedef _AbiVersionDart = int Function();

/// `ffsrs_*` 符号表。构造时就把全部符号解析完：缺符号 = 库不对，立刻抛
/// [ArgumentError]，由 `FushiFsrs.tryLoad` 转成「不可用」。
class FushiFsrsBindings {
  FushiFsrsBindings(ffi.DynamicLibrary lib)
    : ffsrs_call = lib.lookupFunction<_CallC, _CallC>('ffsrs_call'),
      ffsrs_compute_parameters = lib.lookupFunction<_ComputeC, _ComputeC>(
        'ffsrs_compute_parameters',
      ),
      ffsrs_free_string = lib.lookupFunction<_FreeStringC, _FreeStringDart>(
        'ffsrs_free_string',
      ),
      ffsrs_zstd_decompress = lib.lookupFunction<_ZstdC, _ZstdDart>(
        'ffsrs_zstd_decompress',
      ),
      ffsrs_free_bytes = lib.lookupFunction<_FreeBytesC, _FreeBytesDart>(
        'ffsrs_free_bytes',
      ),
      ffsrs_abi_version = lib.lookupFunction<_AbiVersionC, _AbiVersionDart>(
        'ffsrs_abi_version',
      );

  /// 请求 JSON → 响应 JSON（`{"ok":…}` / `{"error":"…"}`）。
  final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> request)
  ffsrs_call;

  /// 参数优化，阻塞到结束；[cancel] 是 int32 取消标志，[progress] 是 int64[2]
  /// `[已处理, 总数]`，两者都可为 nullptr。
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<ffi.Char> request,
    ffi.Pointer<ffi.Int32> cancel,
    ffi.Pointer<ffi.Int64> progress,
  )
  ffsrs_compute_parameters;

  final void Function(ffi.Pointer<ffi.Char> ptr) ffsrs_free_string;

  /// 成功返回新缓冲区并写 `outLen`；失败返回 nullptr。
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Uint8> data,
    int len,
    ffi.Pointer<ffi.Size> outLen,
  )
  ffsrs_zstd_decompress;

  final void Function(ffi.Pointer<ffi.Uint8> ptr, int len) ffsrs_free_bytes;

  final int Function() ffsrs_abi_version;
}
