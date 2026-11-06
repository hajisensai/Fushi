// 手写 FFI 绑定：native/fushi_fsrs/src/lib.rs 导出的 C ABI（`ffsrs_*`）。
//
// - ffsrs_call / ffsrs_fit 返回的 `char*` 一律由 ffsrs_free_string 释放；
// - ffsrs_zstd_decompress 返回的缓冲区由 ffsrs_free_bytes（带长度）释放。
// 高层封装见 ffi_fsrs_engine.dart，别在业务代码里直接调这些。
//
// lookup 名必须写成单引号字符串字面量（ffsrs_ 前缀）：native/fushi_fsrs/verify_abi.sh 用正则从本文件
// 抓期望符号集去核对产物导出表。
//
// ignore_for_file: non_constant_identifier_names

import 'dart:ffi' as ffi;

typedef _CallC = ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>);
typedef _FitC =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Float>,
      ffi.Size,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Int64>,
      ffi.Size,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Uint32>,
      ffi.Size,
      ffi.Pointer<ffi.Int32>,
      ffi.Pointer<ffi.Int64>,
    );
typedef _FitDart =
    ffi.Pointer<ffi.Char> Function(
      ffi.Pointer<ffi.Char>,
      ffi.Pointer<ffi.Uint8>,
      ffi.Pointer<ffi.Float>,
      int,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Int64>,
      int,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Uint32>,
      int,
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
typedef _ZstdFileC =
    ffi.Int32 Function(
      ffi.Pointer<ffi.Char> inPath,
      ffi.Pointer<ffi.Char> outPath,
    );
typedef _ZstdFileDart =
    int Function(ffi.Pointer<ffi.Char> inPath, ffi.Pointer<ffi.Char> outPath);
typedef _FreeBytesC = ffi.Void Function(ffi.Pointer<ffi.Uint8>, ffi.Size);
typedef _FreeBytesDart = void Function(ffi.Pointer<ffi.Uint8>, int);
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
typedef _HistoryStatesC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Int64>,
      ffi.Size,
      ffi.Pointer<ffi.Uint32>,
      ffi.Size,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _HistoryStatesDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Int64>,
      int,
      ffi.Pointer<ffi.Uint32>,
      int,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _HistorySelectC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Int64>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Uint32>,
      ffi.Size,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _HistorySelectDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Int64>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Uint32>,
      int,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _ImportEquivalentC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint32>,
      ffi.Size,
      ffi.Pointer<ffi.Uint32>,
      ffi.Size,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _ImportEquivalentDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint32>,
      int,
      ffi.Pointer<ffi.Uint32>,
      int,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _MemoryInputC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Int64>,
      ffi.Size,
      ffi.Int32,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _MemoryInputDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Int64>,
      int,
      int,
      int,
      int,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _RwkvNowRowsC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Int64>,
      ffi.Size,
      ffi.Int32,
      ffi.Int32,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _RwkvNowRowsDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Int64>,
      int,
      int,
      int,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _MaterializeC =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint8>,
      ffi.Size,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Int64>,
      ffi.Size,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _MaterializeDart =
    ffi.Pointer<ffi.Uint8> Function(
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint8>,
      int,
      ffi.Pointer<ffi.Uint32>,
      ffi.Pointer<ffi.Int64>,
      int,
      ffi.Pointer<ffi.Size>,
      ffi.Pointer<ffi.Pointer<ffi.Char>>,
    );
typedef _AbiVersionC = ffi.Int32 Function();
typedef _AbiVersionDart = int Function();
typedef _BootTimeC = ffi.Int64 Function();
typedef _BootTimeDart = int Function();

/// `ffsrs_*` 符号表。构造时就把全部符号解析完：缺符号 = 库不对，立刻抛
/// [ArgumentError]，由 `FushiFsrs.tryLoad` 转成「不可用」。
class FushiFsrsBindings {
  FushiFsrsBindings(ffi.DynamicLibrary lib)
    : ffsrs_call = lib.lookupFunction<_CallC, _CallC>('ffsrs_call'),
      ffsrs_fit = lib.lookupFunction<_FitC, _FitDart>('ffsrs_fit'),
      ffsrs_retrievability_batch = lib.lookupFunction<_BatchC, _BatchDart>(
        'ffsrs_retrievability_batch',
      ),
      ffsrs_free_string = lib.lookupFunction<_FreeStringC, _FreeStringDart>(
        'ffsrs_free_string',
      ),
      ffsrs_zstd_decompress = lib.lookupFunction<_ZstdC, _ZstdDart>(
        'ffsrs_zstd_decompress',
      ),
      ffsrs_zstd_decompress_file = lib
          .lookupFunction<_ZstdFileC, _ZstdFileDart>(
            'ffsrs_zstd_decompress_file',
          ),
      ffsrs_free_bytes = lib.lookupFunction<_FreeBytesC, _FreeBytesDart>(
        'ffsrs_free_bytes',
      ),
      ffsrs_abi_version = lib.lookupFunction<_AbiVersionC, _AbiVersionDart>(
        'ffsrs_abi_version',
      ),
      ffsrs_boot_time_ms = lib.lookupFunction<_BootTimeC, _BootTimeDart>(
        'ffsrs_boot_time_ms',
        isLeaf: true,
      ),
      ffsrs_search_dupe_norm_batch = lib
          .lookupFunction<_DupeNormC, _DupeNormDart>(
            'ffsrs_search_dupe_norm_batch',
          ),
      ffsrs_history_states = lib
          .lookupFunction<_HistoryStatesC, _HistoryStatesDart>(
            'ffsrs_history_states',
          ),
      ffsrs_history_select = lib
          .lookupFunction<_HistorySelectC, _HistorySelectDart>(
            'ffsrs_history_select',
          ),
      ffsrs_import_equivalent = lib
          .lookupFunction<_ImportEquivalentC, _ImportEquivalentDart>(
            'ffsrs_import_equivalent',
          ),
      ffsrs_materialize = lib.lookupFunction<_MaterializeC, _MaterializeDart>(
        'ffsrs_materialize',
      ),
      ffsrs_memory_input = lib.lookupFunction<_MemoryInputC, _MemoryInputDart>(
        'ffsrs_memory_input',
      ),
      ffsrs_rwkv_now_rows = lib.lookupFunction<_RwkvNowRowsC, _RwkvNowRowsDart>(
        'ffsrs_rwkv_now_rows',
      );

  /// 请求 JSON → 响应 JSON（`{"ok":…}` / `{"error":"…"}`）。
  final ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char> request)
  ffsrs_call;

  /// 参数优化 / 评估，阻塞到结束。[request] 是 `{"op","algorithm","params"?}` JSON，训练集是打包形态
  /// （每张卡一份完整历史 + 按时刻排序的 `(卡序号, 前缀长度)`，见 lib.rs 的 `TrainingSet`）；
  /// [cardIds] 可为 nullptr。[cancel] 是 int32 取消标志，[progress] 是 int64[2] `[已处理, 总数]`，
  /// 两者都可为 nullptr，只对参数优化生效。
  final ffi.Pointer<ffi.Char> Function(
    ffi.Pointer<ffi.Char> request,
    ffi.Pointer<ffi.Uint8> ratings,
    ffi.Pointer<ffi.Float> deltaDays,
    int reviewCount,
    ffi.Pointer<ffi.Uint32> cardOffsets,
    ffi.Pointer<ffi.Int64> cardIds,
    int cardCount,
    ffi.Pointer<ffi.Uint32> itemCards,
    ffi.Pointer<ffi.Uint32> itemLengths,
    int itemCount,
    ffi.Pointer<ffi.Int32> cancel,
    ffi.Pointer<ffi.Int64> progress,
  )
  ffsrs_fit;

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

  /// zstd 文件到文件流式解码：返回 0 成功 / 1 参数非法 / 2 读写失败 / 3 数据非法 / 4 panic
  /// （native/fushi_fsrs/src/lib.rs 的 `ZSTD_FILE_*`）。
  final int Function(
    ffi.Pointer<ffi.Char> inPath,
    ffi.Pointer<ffi.Char> outPath,
  )
  ffsrs_zstd_decompress_file;

  final void Function(ffi.Pointer<ffi.Uint8> ptr, int len) ffsrs_free_bytes;

  final int Function() ffsrs_abi_version;

  /// 自本次开机以来的毫秒，**含睡眠**、不受改系统时间影响（native/fushi_fsrs/src/boot_clock.rs）；
  /// 取不到返回 -1。可信时间（`SrsTrustedClock`）按它推算。
  final int Function() ffsrs_boot_time_ms;

  /// AnkiConnect 查重规范形，批量；返回 `[u32 LE 偏移 × (n+1)][UTF-8]`，由 [ffsrs_free_bytes] 释放。
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Uint8> text,
    int textLen,
    ffi.Pointer<ffi.Uint32> offsets,
    int n,
    ffi.Pointer<ffi.Size> outLen,
  )
  ffsrs_search_dupe_norm_batch;

  /// 卡片历史（落库 JSON）→ 当前状态，批量；布局见 native/fushi_fsrs/src/history.rs
  /// `states_from_json`。成功返回缓冲区（[ffsrs_free_bytes] 释放），失败返回空指针并写错误串
  /// （[ffsrs_free_string] 释放）。
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Uint8> text,
    int textLen,
    ffi.Pointer<ffi.Uint32> offsets,
    ffi.Pointer<ffi.Int64> serverTimes,
    int nLogs,
    ffi.Pointer<ffi.Uint32> groups,
    int nGroups,
    ffi.Pointer<ffi.Size> outLen,
    ffi.Pointer<ffi.Pointer<ffi.Char>> error,
  )
  ffsrs_history_states;

  /// 卡片历史（列模式）→ 排序与选取标记，批量；布局见 history.rs `select_columns`。
  /// 释放规则同 [ffsrs_history_states]。
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Int64> ints,
    int nLogs,
    ffi.Pointer<ffi.Uint8> text,
    int textLen,
    ffi.Pointer<ffi.Uint32> offsets,
    ffi.Pointer<ffi.Uint32> groups,
    int nGroups,
    ffi.Pointer<ffi.Size> outLen,
    ffi.Pointer<ffi.Pointer<ffi.Char>> error,
  )
  ffsrs_history_select;

  /// Anki 导入器入库前判重（每组：导入日志 + 原生日志，落库 JSON）→ 每组一个字节，批量；
  /// 布局见 history.rs `import_equivalent_any`。释放规则同 [ffsrs_history_states]。
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Uint8> text,
    int textLen,
    ffi.Pointer<ffi.Uint32> offsets,
    int nLogs,
    ffi.Pointer<ffi.Uint32> groups,
    int nGroups,
    ffi.Pointer<ffi.Size> outLen,
    ffi.Pointer<ffi.Pointer<ffi.Char>> error,
  )
  ffsrs_import_equivalent;

  /// 修改记录（落库 JSON）→ 寄存器与物化视图，批量；布局见 registers.rs `materialize`
  /// （组描述 JSON + 项原文 + 服务器时刻，结果是 JSON）。释放规则同 [ffsrs_history_states]。
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Uint8> header,
    int headerLen,
    ffi.Pointer<ffi.Uint8> text,
    int textLen,
    ffi.Pointer<ffi.Uint32> offsets,
    ffi.Pointer<ffi.Int64> serverTimes,
    int nItems,
    ffi.Pointer<ffi.Size> outLen,
    ffi.Pointer<ffi.Pointer<ffi.Char>> error,
  )
  ffsrs_materialize;

  /// 记忆状态输入（铁律 A，`projection.rs` `memory_input_columns`）：一份历史的有效日志（列模式，
  /// 已排序）→ 评审序列与起点。释放规则同 [ffsrs_history_states]。
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Int64> ints,
    int nLogs,
    int algorithm,
    int utcOffsetMin,
    int rolloverHour,
    ffi.Pointer<ffi.Size> outLen,
    ffi.Pointer<ffi.Pointer<ffi.Char>> error,
  )
  ffsrs_memory_input;

  /// RWKV「此刻」行（ease 0，`projection.rs` `rwkv_now_rows`）：每行 9 个 i64 → 80 字节的
  /// `FrwkvReview`。释放规则同 [ffsrs_history_states]。
  final ffi.Pointer<ffi.Uint8> Function(
    ffi.Pointer<ffi.Int64> ints,
    int nRows,
    int utcOffsetMin,
    int rolloverHour,
    ffi.Pointer<ffi.Size> outLen,
    ffi.Pointer<ffi.Pointer<ffi.Char>> error,
  )
  ffsrs_rwkv_now_rows;
}
