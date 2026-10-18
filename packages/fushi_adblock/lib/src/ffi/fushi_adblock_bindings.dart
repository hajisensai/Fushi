// 手写 FFI 绑定：native/fushi_adblock/src/lib.rs 导出的 C ABI（`fadb_*`）。
//
// 返回 `char*` 的函数（除 fadb_version 外）一律由调用方 fadb_string_free 释放；
// fadb_engine_serialize 的缓冲用 fadb_bytes_free(ptr, len) 释放。
// 高层封装见 ../fushi_adblock_engine.dart，别在业务代码里直接调这些。
// native/fushi_adblock/verify_abi.sh 与 iOS 伞形库的符号核对直接从本文件的 lookup 字面量
// 取期望集（单引号包住的 fadb_ 名字面量），新增符号照现有写法 lookup 即可自动纳入核对；
// 注释里别写单引号包住的 fadb_ 名，会被当成期望符号。
//
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi' as ffi;

/// 不透明的引擎句柄（Rust 侧 `Box<adblock::Engine>`）。
final class FadbEngine extends ffi.Opaque {}

typedef _VersionC = ffi.Pointer<ffi.Char> Function();
typedef _StringFreeC = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _StringFreeDart = void Function(ffi.Pointer<ffi.Char>);
typedef _BytesFreeC = ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _BytesFreeDart = void Function(ffi.Pointer<ffi.Uint8>, int);
typedef _LastErrorC = ffi.Pointer<ffi.Char> Function();
typedef _CreateC =
    ffi.Pointer<FadbEngine> Function(
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
      ffi.Size,
    );
typedef _CreateDart =
    ffi.Pointer<FadbEngine> Function(ffi.Pointer<ffi.Pointer<ffi.Char>>, int);
typedef _DeserializeC =
    ffi.Pointer<FadbEngine> Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _DeserializeDart =
    ffi.Pointer<FadbEngine> Function(ffi.Pointer<ffi.Uint8>, int);
typedef _SerializeC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FadbEngine>,
      ffi.Pointer<ffi.Size>,
    );
typedef EngineFreeC = ffi.Void Function(ffi.Pointer<FadbEngine>);
typedef _EngineFreeDart = void Function(ffi.Pointer<FadbEngine>);
typedef _UseResourcesC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<FadbEngine>,
      ffi.Pointer<ffi.Char>,
    );
typedef _CheckC =
    ffi.Int32 Function(
      ffi.Pointer<FadbEngine>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _CheckDart =
    int Function(
      ffi.Pointer<FadbEngine>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _CheckJsonC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<FadbEngine>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Char>,
    );
typedef _CosmeticC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<FadbEngine>,
      ffi.Pointer<ffi.Char>,
    );
typedef _GenericC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<FadbEngine>,
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

/// `fadb_*` 符号表。构造时就把全部符号解析完：缺符号 = 库不对，立刻抛
/// [ArgumentError]，由 `FushiAdblockLibrary.tryLoad` 转成「不可用」。
class FushiAdblockBindings {
  FushiAdblockBindings(ffi.DynamicLibrary lib)
    : fadb_version = lib.lookupFunction<_VersionC, _VersionC>('fadb_version'),
      fadb_string_free = lib.lookupFunction<_StringFreeC, _StringFreeDart>(
        'fadb_string_free',
      ),
      fadb_bytes_free = lib.lookupFunction<_BytesFreeC, _BytesFreeDart>(
        'fadb_bytes_free',
      ),
      fadb_last_error = lib.lookupFunction<_LastErrorC, _LastErrorC>(
        'fadb_last_error',
      ),
      fadb_engine_create = lib.lookupFunction<_CreateC, _CreateDart>(
        'fadb_engine_create',
      ),
      fadb_engine_deserialize = lib
          .lookupFunction<_DeserializeC, _DeserializeDart>(
            'fadb_engine_deserialize',
          ),
      fadb_engine_serialize = lib.lookupFunction<_SerializeC, _SerializeC>(
        'fadb_engine_serialize',
      ),
      fadb_engine_free = lib.lookupFunction<EngineFreeC, _EngineFreeDart>(
        'fadb_engine_free',
      ),
      fadb_engine_free_ptr = lib.lookup<ffi.NativeFunction<EngineFreeC>>(
        'fadb_engine_free',
      ),
      fadb_engine_use_resources = lib
          .lookupFunction<_UseResourcesC, _UseResourcesC>(
            'fadb_engine_use_resources',
          ),
      fadb_engine_check = lib.lookupFunction<_CheckC, _CheckDart>(
        'fadb_engine_check',
      ),
      fadb_engine_check_json = lib.lookupFunction<_CheckJsonC, _CheckJsonC>(
        'fadb_engine_check_json',
      ),
      fadb_engine_cosmetic = lib.lookupFunction<_CosmeticC, _CosmeticC>(
        'fadb_engine_cosmetic',
      ),
      fadb_engine_generic_selectors = lib.lookupFunction<_GenericC, _GenericC>(
        'fadb_engine_generic_selectors',
      ),
      fadb_content_blocking_rules = lib
          .lookupFunction<_ContentBlockingC, _ContentBlockingDart>(
            'fadb_content_blocking_rules',
          );

  final ffi.Pointer<ffi.Char> Function() fadb_version;
  final void Function(ffi.Pointer<ffi.Char>) fadb_string_free;
  final void Function(ffi.Pointer<ffi.Uint8>, int) fadb_bytes_free;
  final ffi.Pointer<ffi.Char> Function() fadb_last_error;
  final ffi.Pointer<FadbEngine> Function(
    ffi.Pointer<ffi.Pointer<ffi.Char>>,
    int,
  )
  fadb_engine_create;
  final ffi.Pointer<FadbEngine> Function(ffi.Pointer<ffi.Uint8>, int)
  fadb_engine_deserialize;
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<FadbEngine>,
    ffi.Pointer<ffi.Size>,
  )
  fadb_engine_serialize;
  final void Function(ffi.Pointer<FadbEngine>) fadb_engine_free;

  /// 给 `NativeFinalizer` 用的原生函数指针（引擎对象被 GC 时兜底释放）。
  final ffi.Pointer<ffi.NativeFunction<EngineFreeC>> fadb_engine_free_ptr;
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<FadbEngine>,
    ffi.Pointer<ffi.Char>,
  )
  fadb_engine_use_resources;
  final int Function(
    ffi.Pointer<FadbEngine>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
  )
  fadb_engine_check;
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<FadbEngine>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
  )
  fadb_engine_check_json;
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<FadbEngine>,
    ffi.Pointer<ffi.Char>,
  )
  fadb_engine_cosmetic;
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<FadbEngine>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
    ffi.Pointer<ffi.Char>,
  )
  fadb_engine_generic_selectors;
  final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Pointer<ffi.Char>>, int)
  fadb_content_blocking_rules;
}
