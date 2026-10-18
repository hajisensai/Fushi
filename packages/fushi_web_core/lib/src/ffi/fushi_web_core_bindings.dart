// 手写 FFI 绑定：native/fushi_web_core/src/lib.rs 导出的 C ABI（`fwc_*`）。
//
// 返回 `char*` 的函数（除 fwc_version 外）一律由调用方 fwc_string_free 释放；
// fwc_engine_serialize 的缓冲用 fwc_bytes_free(ptr, len) 释放。
// 高层封装见 ../adblock_engine.dart，别在业务代码里直接调这些。
// native/fushi_web_core/verify_abi.sh 与 iOS 伞形库的符号核对直接从本文件的 lookup 字面量
// 取期望集（单引号包住的 fwc_ 名字面量），新增符号照现有写法 lookup 即可自动纳入核对；
// 注释里别写单引号包住的 fwc_ 名，会被当成期望符号。
//
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi' as ffi;

/// 不透明的引擎句柄（Rust 侧 `Box<adblock::Engine>`）。
final class FwcAdblockEngine extends ffi.Opaque {}

typedef _VersionC = ffi.Pointer<ffi.Char> Function();
typedef _StringFreeC = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _StringFreeDart = void Function(ffi.Pointer<ffi.Char>);
typedef _BytesFreeC = ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _BytesFreeDart = void Function(ffi.Pointer<ffi.Uint8>, int);
typedef _LastErrorC = ffi.Pointer<ffi.Char> Function();
typedef _CreateC =
    ffi.Pointer<FwcAdblockEngine> Function(
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
      ffi.Size,
    );
typedef _CreateDart =
    ffi.Pointer<FwcAdblockEngine> Function(
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
      int,
    );
typedef _DeserializeC =
    ffi.Pointer<FwcAdblockEngine> Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _DeserializeDart =
    ffi.Pointer<FwcAdblockEngine> Function(ffi.Pointer<ffi.Uint8>, int);
typedef _SerializeC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockEngine>,
      ffi.Pointer<ffi.Size>,
    );
typedef EngineFreeC = ffi.Void Function(ffi.Pointer<FwcAdblockEngine>);
typedef _EngineFreeDart = void Function(ffi.Pointer<FwcAdblockEngine>);
typedef _UseResourcesC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<FwcAdblockEngine>,
      ffi.Pointer<ffi.Char>,
    );
typedef _CheckC =
    ffi.Int32 Function(
      ffi.Pointer<FwcAdblockEngine>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _CheckDart =
    int Function(
      ffi.Pointer<FwcAdblockEngine>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _CheckJsonC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<FwcAdblockEngine>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _CosmeticC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<FwcAdblockEngine>,
      ffi.Pointer<ffi.Char>,
    );
typedef _GenericC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<FwcAdblockEngine>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _ContentBlockingC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
      ffi.Size,
    );
typedef _ContentBlockingDart =
    ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Pointer<ffi.Char>>, int);

/// `fwc_*` 符号表。构造时就把全部符号解析完：缺符号 = 库不对，立刻抛
/// [ArgumentError]，由 `FushiWebCoreLibrary.tryLoad` 转成「不可用」。
class FushiWebCoreBindings {
  FushiWebCoreBindings(ffi.DynamicLibrary lib)
    : fwc_version = lib.lookupFunction<_VersionC, _VersionC>('fwc_version'),
      fwc_string_free = lib.lookupFunction<_StringFreeC, _StringFreeDart>(
        'fwc_string_free',
      ),
      fwc_bytes_free = lib.lookupFunction<_BytesFreeC, _BytesFreeDart>(
        'fwc_bytes_free',
      ),
      fwc_last_error = lib.lookupFunction<_LastErrorC, _LastErrorC>(
        'fwc_last_error',
      ),
      fwc_engine_create = lib.lookupFunction<_CreateC, _CreateDart>(
        'fwc_engine_create',
      ),
      fwc_engine_deserialize = lib
          .lookupFunction<_DeserializeC, _DeserializeDart>(
            'fwc_engine_deserialize',
          ),
      fwc_engine_serialize = lib.lookupFunction<_SerializeC, _SerializeC>(
        'fwc_engine_serialize',
      ),
      fwc_engine_free = lib.lookupFunction<EngineFreeC, _EngineFreeDart>(
        'fwc_engine_free',
      ),
      fwc_engine_free_ptr = lib.lookup<ffi.NativeFunction<EngineFreeC>>(
        'fwc_engine_free',
      ),
      fwc_engine_use_resources = lib
          .lookupFunction<_UseResourcesC, _UseResourcesC>(
            'fwc_engine_use_resources',
          ),
      fwc_engine_check = lib.lookupFunction<_CheckC, _CheckDart>(
        'fwc_engine_check',
      ),
      fwc_engine_check_json = lib.lookupFunction<_CheckJsonC, _CheckJsonC>(
        'fwc_engine_check_json',
      ),
      fwc_engine_cosmetic = lib.lookupFunction<_CosmeticC, _CosmeticC>(
        'fwc_engine_cosmetic',
      ),
      fwc_engine_generic_selectors = lib.lookupFunction<_GenericC, _GenericC>(
        'fwc_engine_generic_selectors',
      ),
      fwc_content_blocking_rules = lib
          .lookupFunction<_ContentBlockingC, _ContentBlockingDart>(
            'fwc_content_blocking_rules',
          );

  final ffi.Pointer<ffi.Char> Function() fwc_version;
  final void Function(ffi.Pointer<ffi.Char>) fwc_string_free;
  final void Function(ffi.Pointer<ffi.Uint8>, int) fwc_bytes_free;
  final ffi.Pointer<ffi.Char> Function() fwc_last_error;
  final ffi.Pointer<FwcAdblockEngine> Function(
    ffi.Pointer<ffi.Pointer<ffi.Char>>,
    int,
  )
  fwc_engine_create;
  final ffi.Pointer<FwcAdblockEngine> Function(ffi.Pointer<ffi.Uint8>, int)
  fwc_engine_deserialize;
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<FwcAdblockEngine>,
    ffi.Pointer<ffi.Size>,
  )
  fwc_engine_serialize;
  final void Function(ffi.Pointer<FwcAdblockEngine>) fwc_engine_free;

  /// 给 `NativeFinalizer` 用的原生函数指针（引擎对象被 GC 时兜底释放）。
  final ffi.Pointer<ffi.NativeFunction<EngineFreeC>> fwc_engine_free_ptr;
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<FwcAdblockEngine>,
    ffi.Pointer<ffi.Char>,
  )
  fwc_engine_use_resources;
  final int Function(
    ffi.Pointer<FwcAdblockEngine>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
  )
  fwc_engine_check;
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<FwcAdblockEngine>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
  )
  fwc_engine_check_json;
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<FwcAdblockEngine>,
    ffi.Pointer<ffi.Char>,
  )
  fwc_engine_cosmetic;
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<FwcAdblockEngine>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
  )
  fwc_engine_generic_selectors;
  final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Pointer<ffi.Char>>, int)
  fwc_content_blocking_rules;
}
