// GENERATED / hand-mirrored — do not edit by hand except to re-run ffigen.
//
// 本文件是 `ffigen.yaml` 对 native/hibiki_torrent/.../hibiki_torrent.h 的产物。
// 本机装有 LLVM/libclang 时可 `dart run ffigen --config ffigen.yaml` 覆盖重生；
// 内容与 ffigen 对该 3 函数 C ABI 的输出等价（单一 DynamicLibrary 构造 +
// lookup 惰性字段），与仓库既有 hoshidicts FFI 手写范式一致。
//
// ignore_for_file: always_specify_types, camel_case_types, non_constant_identifier_names

import 'dart:ffi' as ffi;

/// Dart FFI bindings for the hibiki_torrent C ABI bridge over libtorrent.
class HibikiTorrentBindings {
  /// Holds the symbol lookup function.
  final ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
      _lookup;

  /// The symbols are looked up in [dynamicLibrary].
  HibikiTorrentBindings(ffi.DynamicLibrary dynamicLibrary)
      : _lookup = dynamicLibrary.lookup;

  /// The symbols are looked up with [lookup].
  HibikiTorrentBindings.fromLookup(
    ffi.Pointer<T> Function<T extends ffi.NativeType>(String symbolName)
        lookup,
  ) : _lookup = lookup;

  /// 返回 libtorrent 运行时版本串（如 "2.0.11.0"）。指向 libtorrent 内部
  /// 静态存储，调用方不得 free。
  ffi.Pointer<ffi.Char> ht_libtorrent_version() {
    return _ht_libtorrent_version();
  }

  late final _ht_libtorrent_versionPtr =
      _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Char> Function()>>(
          'ht_libtorrent_version');
  late final _ht_libtorrent_version = _ht_libtorrent_versionPtr
      .asFunction<ffi.Pointer<ffi.Char> Function()>();

  /// 创建一个不监听端口的 libtorrent session，返回不透明句柄；失败返回 NULL。
  ffi.Pointer<ffi.Void> ht_session_create() {
    return _ht_session_create();
  }

  late final _ht_session_createPtr =
      _lookup<ffi.NativeFunction<ffi.Pointer<ffi.Void> Function()>>(
          'ht_session_create');
  late final _ht_session_create =
      _ht_session_createPtr.asFunction<ffi.Pointer<ffi.Void> Function()>();

  /// 销毁 ht_session_create 返回的句柄；传 NULL 为 no-op。
  void ht_session_destroy(ffi.Pointer<ffi.Void> session) {
    return _ht_session_destroy(session);
  }

  late final _ht_session_destroyPtr =
      _lookup<ffi.NativeFunction<ffi.Void Function(ffi.Pointer<ffi.Void>)>>(
          'ht_session_destroy');
  late final _ht_session_destroy = _ht_session_destroyPtr
      .asFunction<void Function(ffi.Pointer<ffi.Void>)>();
}
