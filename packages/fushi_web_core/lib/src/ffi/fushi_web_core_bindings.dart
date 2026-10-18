// 手写 FFI 绑定：native/fushi_web_core/src 导出的 C ABI（`fwc_*`）。
//
// 约定（与 Rust 侧 ffi_util.rs / adblock/ffi.rs / comic_ad/ffi.rs 一致）：
// - 字符串入参是 `(ptr, len)` 的 UTF-8（不要求 NUL 结尾）；
// - 返回字节缓冲的函数把长度写进 out_len 参数，用 fwc_bytes_free(ptr, len) 释放；
// - 失败原因用 fwc_last_error 取，用 fwc_string_free 释放；
// - fwc_adblock_check 是微秒级、不分配、不回调的热路径，绑定成 leaf 调用（入参写在
//   AdblockCore 常驻的原生暂存区里，每次请求零 malloc）；其余命令走普通调用。
// 高层封装见 ../adblock/adblock_core.dart 与 ../comic_ad/comic_ad_detector.dart。
// native/fushi_web_core/verify_abi.sh 与 iOS 伞形库的符号核对直接从本文件的 lookup 字面量
// 取期望集（单引号包住的 fwc_ 名字面量），新增符号照现有写法 lookup 即可自动纳入核对；
// 注释里别写单引号包住的 fwc_ 名，会被当成期望符号。
//
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi' as ffi;

/// 不透明的广告拦截核心句柄（Rust 侧 `Box<AdblockCore>`）。
final class FwcAdblockCore extends ffi.Opaque {}

/// 章末广告页判定规则（Rust `#[repr(C)] ComicAdRules`）。
final class FwcComicAdRules extends ffi.Struct {
  @ffi.Uint32()
  external int tailWindow;

  @ffi.Uint32()
  external int protectedLeadingPages;

  @ffi.Double()
  external double colorfulThreshold;

  @ffi.Uint32()
  external int analysisMaxSide;
}

typedef _VersionC = ffi.Pointer<ffi.Char> Function();
typedef _StringFreeC = ffi.Void Function(ffi.Pointer<ffi.Char>);
typedef _StringFreeDart = void Function(ffi.Pointer<ffi.Char>);
typedef _BytesFreeC = ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _BytesFreeDart = void Function(ffi.Pointer<ffi.Uint8>, int);
typedef _LastErrorC = ffi.Pointer<ffi.Char> Function();

typedef _OpenC =
    ffi.Pointer<FwcAdblockCore> Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Uint8,
    );
typedef _OpenDart =
    ffi.Pointer<FwcAdblockCore> Function(ffi.Pointer<ffi.Uint8>, int, int);
typedef AdblockCloseC = ffi.Void Function(ffi.Pointer<FwcAdblockCore>);
typedef _CloseDart = void Function(ffi.Pointer<FwcAdblockCore>);
typedef _CatalogC = ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Size>);
typedef _CoreOutC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Size>,
    );
typedef _CoreFlagOutC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Uint8,
      ffi.Pointer<ffi.Size>,
    );
typedef _CoreFlagOutDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockCore>,
      int,
      ffi.Pointer<ffi.Size>,
    );
typedef _SetListC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Uint8,
      ffi.Pointer<ffi.Size>,
    );
typedef _SetListDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      int,
      int,
      ffi.Pointer<ffi.Size>,
    );
typedef _CoreStrOutC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Size>,
    );
typedef _CoreStrOutDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Size>,
    );
typedef _IngestC =
    ffi.Int32 Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Int32,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
    );
typedef _IngestDart =
    int Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      int,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
    );
typedef _CheckC =
    ffi.Int32 Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Uint8,
    );
typedef _CheckDart =
    int Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      int,
    );
typedef _CosmeticC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Size>,
    );
typedef _CosmeticDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Size>,
    );
typedef _GenericC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Size>,
    );
typedef _GenericDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<FwcAdblockCore>,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Size>,
    );
typedef _DefaultRulesC = FwcComicAdRules Function();
typedef _CandidateStartC =
    ffi.Uint32 Function(ffi.Uint32, ffi.Pointer<FwcComicAdRules>);
typedef _CandidateStartDart = int Function(int, ffi.Pointer<FwcComicAdRules>);
typedef _DetectBatchC =
    ffi.Int32 Function(
      ffi.Pointer<FwcComicAdRules>,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
      ffi.Pointer<ffi.Size>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
    );
typedef _DetectBatchDart =
    int Function(
      ffi.Pointer<FwcComicAdRules>,
      ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
      ffi.Pointer<ffi.Size>,
      int,
      ffi.Pointer<ffi.Uint8>,
    );

/// `fwc_*` 符号表。构造时就把全部符号解析完：缺符号 = 库不对 / 版本太老，立刻抛
/// [ArgumentError]（原生库是硬依赖，没有「判不可用」的退路）。
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
      fwc_adblock_open = lib.lookupFunction<_OpenC, _OpenDart>(
        'fwc_adblock_open',
      ),
      fwc_adblock_close = lib.lookupFunction<AdblockCloseC, _CloseDart>(
        'fwc_adblock_close',
      ),
      fwc_adblock_close_ptr = lib.lookup<ffi.NativeFunction<AdblockCloseC>>(
        'fwc_adblock_close',
      ),
      fwc_adblock_catalog = lib.lookupFunction<_CatalogC, _CatalogC>(
        'fwc_adblock_catalog',
      ),
      fwc_adblock_snapshot = lib.lookupFunction<_CoreOutC, _CoreOutC>(
        'fwc_adblock_snapshot',
      ),
      fwc_adblock_set_enabled = lib
          .lookupFunction<_CoreFlagOutC, _CoreFlagOutDart>(
            'fwc_adblock_set_enabled',
          ),
      fwc_adblock_set_list_enabled = lib
          .lookupFunction<_SetListC, _SetListDart>(
            'fwc_adblock_set_list_enabled',
          ),
      fwc_adblock_set_allowlist = lib
          .lookupFunction<_CoreStrOutC, _CoreStrOutDart>(
            'fwc_adblock_set_allowlist',
          ),
      fwc_adblock_begin_sync = lib
          .lookupFunction<_CoreFlagOutC, _CoreFlagOutDart>(
            'fwc_adblock_begin_sync',
          ),
      fwc_adblock_ingest = lib.lookupFunction<_IngestC, _IngestDart>(
        'fwc_adblock_ingest',
      ),
      fwc_adblock_finish_sync = lib.lookupFunction<_CoreOutC, _CoreOutC>(
        'fwc_adblock_finish_sync',
      ),
      fwc_adblock_check = lib.lookupFunction<_CheckC, _CheckDart>(
        'fwc_adblock_check',
        isLeaf: true,
      ),
      fwc_adblock_cosmetic = lib.lookupFunction<_CosmeticC, _CosmeticDart>(
        'fwc_adblock_cosmetic',
      ),
      fwc_adblock_generic = lib.lookupFunction<_GenericC, _GenericDart>(
        'fwc_adblock_generic',
      ),
      fwc_adblock_content_blockers = lib.lookupFunction<_CoreOutC, _CoreOutC>(
        'fwc_adblock_content_blockers',
      ),
      fwc_comic_ad_default_rules = lib
          .lookupFunction<_DefaultRulesC, _DefaultRulesC>(
            'fwc_comic_ad_default_rules',
          ),
      fwc_comic_ad_candidate_start = lib
          .lookupFunction<_CandidateStartC, _CandidateStartDart>(
            'fwc_comic_ad_candidate_start',
          ),
      fwc_comic_ad_detect_batch = lib
          .lookupFunction<_DetectBatchC, _DetectBatchDart>(
            'fwc_comic_ad_detect_batch',
          );

  final ffi.Pointer<ffi.Char> Function() fwc_version;
  final void Function(ffi.Pointer<ffi.Char>) fwc_string_free;
  final void Function(ffi.Pointer<ffi.Uint8>, int) fwc_bytes_free;
  final ffi.Pointer<ffi.Char> Function() fwc_last_error;

  final ffi.Pointer<FwcAdblockCore> Function(ffi.Pointer<ffi.Uint8>, int, int)
  fwc_adblock_open;
  final void Function(ffi.Pointer<FwcAdblockCore>) fwc_adblock_close;

  /// 给 `NativeFinalizer` 用的原生函数指针（核心对象被 GC 时兜底释放）。
  final ffi.Pointer<ffi.NativeFunction<AdblockCloseC>> fwc_adblock_close_ptr;
  final ffi.Pointer<ffi.Uint8> Function(ffi.Pointer<ffi.Size>)
  fwc_adblock_catalog;
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<FwcAdblockCore>,
    ffi.Pointer<ffi.Size>,
  )
  fwc_adblock_snapshot;
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<FwcAdblockCore>,
    int,
    ffi.Pointer<ffi.Size>,
  )
  fwc_adblock_set_enabled;
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<FwcAdblockCore>,
    ffi.Pointer<ffi.Uint8>,
    int,
    int,
    ffi.Pointer<ffi.Size>,
  )
  fwc_adblock_set_list_enabled;
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<FwcAdblockCore>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Size>,
  )
  fwc_adblock_set_allowlist;
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<FwcAdblockCore>,
    int,
    ffi.Pointer<ffi.Size>,
  )
  fwc_adblock_begin_sync;
  final int Function(
    ffi.Pointer<FwcAdblockCore>,
    ffi.Pointer<ffi.Uint8>,
    int,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
  )
  fwc_adblock_ingest;
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<FwcAdblockCore>,
    ffi.Pointer<ffi.Size>,
  )
  fwc_adblock_finish_sync;

  /// leaf 调用（微秒级、不回调 Dart）。
  final int Function(
    ffi.Pointer<FwcAdblockCore>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    int,
  )
  fwc_adblock_check;
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<FwcAdblockCore>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Size>,
  )
  fwc_adblock_cosmetic;
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<FwcAdblockCore>,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Uint8>,
    int,
    ffi.Pointer<ffi.Size>,
  )
  fwc_adblock_generic;
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<FwcAdblockCore>,
    ffi.Pointer<ffi.Size>,
  )
  fwc_adblock_content_blockers;

  final FwcComicAdRules Function() fwc_comic_ad_default_rules;
  final int Function(int, ffi.Pointer<FwcComicAdRules>)
  fwc_comic_ad_candidate_start;
  final int Function(
    ffi.Pointer<FwcComicAdRules>,
    ffi.Pointer<ffi.Pointer<ffi.Uint8>>,
    ffi.Pointer<ffi.Size>,
    int,
    ffi.Pointer<ffi.Uint8>,
  )
  fwc_comic_ad_detect_batch;
}
