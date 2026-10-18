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
typedef _BatchC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Float>,
      ffi.Pointer<ffi.Float>,
      ffi.Pointer<ffi.Float>,
      ffi.Pointer<ffi.Float>,
      ffi.Size,
      ffi.Pointer<ffi.Float>,
    );
typedef _BatchDart =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Float>,
      ffi.Pointer<ffi.Float>,
      ffi.Pointer<ffi.Float>,
      ffi.Pointer<ffi.Float>,
      int,
      ffi.Pointer<ffi.Float>,
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
typedef _CorpusNewC =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint32>,
      ffi.Size,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _CorpusNewDart =
    ffi.Pointer<ffi.Void> Function(
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint32>,
      int,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _CorpusFreeC = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _CorpusFreeDart = void Function(ffi.Pointer<ffi.Void>);
typedef _SetIntsC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Int32,
      ffi.Pointer<ffi.Int64>,
      ffi.Size,
    );
typedef _SetIntsDart =
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Int64>, int);
typedef _SetFloatsC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Void>,
      ffi.Int32,
      ffi.Pointer<ffi.Double>,
      ffi.Size,
    );
typedef _SetFloatsDart =
    int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Double>, int);
typedef _MatchC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
    );
typedef _MatchDart =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<ffi.Void>,
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Uint8>,
      int,
    );
typedef _DupeNormC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint32>,
      ffi.Size,
      ffi.Pointer<ffi.Size>,
    );
typedef _DupeNormDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint32>,
      int,
      ffi.Pointer<ffi.Size>,
    );
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
      ffsrs_retrievability_batch = lib.lookupFunction<_BatchC, _BatchDart>(
        'ffsrs_retrievability_batch',
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
      ),
      ffsrs_search_corpus_new = lib.lookupFunction<_CorpusNewC, _CorpusNewDart>(
        'ffsrs_search_corpus_new',
      ),
      ffsrs_search_corpus_free_ptr = lib
          .lookup<ffi.NativeFunction<_CorpusFreeC>>('ffsrs_search_corpus_free'),
      ffsrs_search_corpus_set_ints = lib
          .lookupFunction<_SetIntsC, _SetIntsDart>(
            'ffsrs_search_corpus_set_ints',
          ),
      ffsrs_search_corpus_set_floats = lib
          .lookupFunction<_SetFloatsC, _SetFloatsDart>(
            'ffsrs_search_corpus_set_floats',
          ),
      ffsrs_search_corpus_match = lib.lookupFunction<_MatchC, _MatchDart>(
        'ffsrs_search_corpus_match',
      ),
      ffsrs_search_dupe_norm_batch = lib
          .lookupFunction<_DupeNormC, _DupeNormDart>(
            'ffsrs_search_dupe_norm_batch',
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

  /// 同一组参数下批量算可提取度：[model] 是 `{"algorithm","params"}` JSON，
  /// [s] / [d] / [elapsed] / [out] 长度均为 [n]，[sf] 可为 nullptr（取 [s]）。
  /// 返回 `{"ok":n}` / `{"error":"…"}`，由 [ffsrs_free_string] 释放。
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<ffi.Char> model,
    ffi.Pointer<ffi.Float> s,
    ffi.Pointer<ffi.Float> d,
    ffi.Pointer<ffi.Float> sf,
    ffi.Pointer<ffi.Float> elapsed,
    int n,
    ffi.Pointer<ffi.Float> out,
  )
  ffsrs_retrievability_batch;

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

  /// Anki 搜索语料（native/fushi_fsrs/src/search.rs `Corpus::new` 的布局）：失败返回 nullptr，
  /// 并在 [errorOut]（可为 nullptr）写一条由 [ffsrs_free_string] 释放的错误串。
  final ffi.Pointer<ffi.Void> Function(
    ffi.Pointer<ffi.Uint8> text,
    int textLen,
    ffi.Pointer<ffi.Uint32> layout,
    int layoutLen,
    ffi.Pointer<ffi.Pointer<ffi.Char>> errorOut,
  )
  ffsrs_search_corpus_new;

  /// `ffsrs_search_corpus_free` 的函数指针（[searchCorpusFinalizer] 用）。
  final ffi.Pointer<ffi.NativeFunction<_CorpusFreeC>>
  ffsrs_search_corpus_free_ptr;

  late final void Function(ffi.Pointer<ffi.Void> corpus)
  ffsrs_search_corpus_free = ffsrs_search_corpus_free_ptr
      .asFunction<_CorpusFreeDart>();

  /// 语料对象被回收时释放原生句柄。
  late final ffi.NativeFinalizer searchCorpusFinalizer = ffi.NativeFinalizer(
    ffsrs_search_corpus_free_ptr.cast(),
  );

  /// 设整数列 / 小数列（长度 = 卡数）；成功 0，失败 -1。
  final int Function(
    ffi.Pointer<ffi.Void> corpus,
    int column,
    ffi.Pointer<ffi.Int64> data,
    int n,
  )
  ffsrs_search_corpus_set_ints;

  final int Function(
    ffi.Pointer<ffi.Void> corpus,
    int column,
    ffi.Pointer<ffi.Double> data,
    int n,
  )
  ffsrs_search_corpus_set_floats;

  /// 整批求值：[out] 长 [n]（= 卡数），返回 `{"ok":命中数}` / `{"error","kind","at"}`，
  /// 由 [ffsrs_free_string] 释放。
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<ffi.Void> corpus,
    ffi.Pointer<ffi.Char> query,
    ffi.Pointer<ffi.Uint8> out,
    int n,
  )
  ffsrs_search_corpus_match;

  /// AnkiConnect 查重规范形，批量；返回 `[u32 LE 偏移 × (n+1)][UTF-8]`，由 [ffsrs_free_bytes] 释放。
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Uint8> text,
    int textLen,
    ffi.Pointer<ffi.Uint32> offsets,
    int n,
    ffi.Pointer<ffi.Size> outLen,
  )
  ffsrs_search_dupe_norm_batch;
}
