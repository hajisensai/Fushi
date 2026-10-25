import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

// 视频刮削标题归一化 / 相似度（`ffc_parse_title_*`，native/fushi_compute/src/parse/title_score.rs）
// 与 AniDB 标题目录 / anime XML 解析（`ffc_parse_anidb_*`，src/parse/anidb.rs）的绑定。
//
// 这是这些算法**唯一**的运行时实现：没有 Dart 回退。原生库或符号缺失时首次使用抛
// [FushiComputeUnavailableError]。每个 isolate 各持一份符号表与一块复用的原生暂存区。

typedef _NormalizeC =
    Int32 Function(Pointer<Uint16>, Size, Pointer<Uint16>, Size, Pointer<Size>);
typedef _NormalizeDart =
    int Function(Pointer<Uint16>, int, Pointer<Uint16>, int, Pointer<Size>);
typedef _UnitsToBytesC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _UnitsToBytesDart =
    int Function(Pointer<Uint16>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _PairC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Uint16>,
      Size,
      Pointer<Double>,
    );
typedef _PairDart =
    int Function(Pointer<Uint16>, int, Pointer<Uint16>, int, Pointer<Double>);
typedef _BatchC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Uint16>,
      Pointer<Uint32>,
      Size,
      Pointer<Double>,
    );
typedef _BatchDart =
    int Function(
      Pointer<Uint16>,
      int,
      Pointer<Uint16>,
      Pointer<Uint32>,
      int,
      Pointer<Double>,
    );
typedef _NormalizeBatchC =
    Int32 Function(
      Pointer<Uint16>,
      Pointer<Uint32>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _NormalizeBatchDart =
    int Function(
      Pointer<Uint16>,
      Pointer<Uint32>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _MatrixC =
    Int32 Function(
      Pointer<Uint16>,
      Pointer<Uint32>,
      Size,
      Pointer<Uint16>,
      Pointer<Uint32>,
      Size,
      Pointer<Double>,
    );
typedef _MatrixDart =
    int Function(
      Pointer<Uint16>,
      Pointer<Uint32>,
      int,
      Pointer<Uint16>,
      Pointer<Uint32>,
      int,
      Pointer<Double>,
    );
typedef _NewC = Pointer<Void> Function();
typedef _FeedC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _FeedDart = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _HandleStatusC = Int32 Function(Pointer<Void>);
typedef _HandleStatusDart = int Function(Pointer<Void>);
typedef _FinishC = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _FinishDart = int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _ErrorC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint32>,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ErrorDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint32>,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _FreeHandleC = Void Function(Pointer<Void>);
typedef _FreeHandleDart = void Function(Pointer<Void>);
typedef _HandleBytesC =
    Int32 Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _HandleBytesDart =
    int Function(Pointer<Void>, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _RecordTableC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Size>,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _RecordTableDart =
    int Function(
      Pointer<Void>,
      Pointer<Size>,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _SearchC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint16>,
      Size,
      Uint32,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _SearchDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint16>,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

/// 本 isolate 的符号表与暂存区。
final class _AniDbNative implements Finalizable {
  _AniDbNative._(this.compute) {
    final DynamicLibrary lib = compute.library;
    // lookup 名写成字符串字面量：verify_abi.sh 从绑定源码抓期望符号集。
    try {
      normalize = lib.lookupFunction<_NormalizeC, _NormalizeDart>(
        'ffc_parse_title_normalize',
        isLeaf: true,
      );
      tokens = lib.lookupFunction<_UnitsToBytesC, _UnitsToBytesDart>(
        'ffc_parse_title_tokens',
        isLeaf: true,
      );
      similarity = lib.lookupFunction<_PairC, _PairDart>(
        'ffc_parse_title_similarity',
        isLeaf: true,
      );
      similarityNormalized = lib.lookupFunction<_PairC, _PairDart>(
        'ffc_parse_title_similarity_normalized',
        isLeaf: true,
      );
      similarityBatch = lib.lookupFunction<_BatchC, _BatchDart>(
        'ffc_parse_title_similarity_normalized_batch',
      );
      normalizeBatch = lib
          .lookupFunction<_NormalizeBatchC, _NormalizeBatchDart>(
            'ffc_parse_title_normalize_batch',
          );
      similarityMatrix = lib.lookupFunction<_MatrixC, _MatrixDart>(
        'ffc_parse_title_similarity_normalized_matrix',
      );
      builderNew = lib.lookupFunction<_NewC, _NewC>(
        'ffc_parse_anidb_catalog_builder_new',
      );
      builderFeed = lib.lookupFunction<_FeedC, _FeedDart>(
        'ffc_parse_anidb_catalog_builder_feed',
      );
      builderClose = lib.lookupFunction<_HandleStatusC, _HandleStatusDart>(
        'ffc_parse_anidb_catalog_builder_close',
      );
      builderFinish = lib.lookupFunction<_FinishC, _FinishDart>(
        'ffc_parse_anidb_catalog_builder_finish',
      );
      builderError = lib.lookupFunction<_ErrorC, _ErrorDart>(
        'ffc_parse_anidb_catalog_builder_error',
        isLeaf: true,
      );
      builderFree = lib.lookupFunction<_FreeHandleC, _FreeHandleDart>(
        'ffc_parse_anidb_catalog_builder_free',
      );
      catalogFreePointer = lib.lookup<NativeFunction<_FreeHandleC>>(
        'ffc_parse_anidb_catalog_free',
      );
      catalogFree = catalogFreePointer.asFunction<_FreeHandleDart>();
      catalogIds = lib.lookupFunction<_HandleBytesC, _HandleBytesDart>(
        'ffc_parse_anidb_catalog_anime_ids',
      );
      catalogRecordTable = lib.lookupFunction<_RecordTableC, _RecordTableDart>(
        'ffc_parse_anidb_catalog_record_table',
        isLeaf: true,
      );
      catalogSearch = lib.lookupFunction<_SearchC, _SearchDart>(
        'ffc_parse_anidb_catalog_search',
      );
      animeXml = lib.lookupFunction<_UnitsToBytesC, _UnitsToBytesDart>(
        'ffc_parse_anidb_anime_xml',
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  final FushiCompute compute;
  late final _NormalizeDart normalize;
  late final _UnitsToBytesDart tokens;
  late final _PairDart similarity;
  late final _PairDart similarityNormalized;
  late final _BatchDart similarityBatch;
  late final _NormalizeBatchDart normalizeBatch;
  late final _MatrixDart similarityMatrix;
  late final _NewC builderNew;
  late final _FeedDart builderFeed;
  late final _HandleStatusDart builderClose;
  late final _FinishDart builderFinish;
  late final _ErrorDart builderError;
  late final _FreeHandleDart builderFree;
  late final Pointer<NativeFunction<_FreeHandleC>> catalogFreePointer;
  late final _FreeHandleDart catalogFree;
  late final _HandleBytesDart catalogIds;
  late final _RecordTableDart catalogRecordTable;
  late final _SearchDart catalogSearch;
  late final _UnitsToBytesDart animeXml;

  late final NativeFinalizer catalogFinalizer = NativeFinalizer(
    catalogFreePointer.cast(),
  );

  /// 固定输出槽（一块定长内存按 8 字节切）：size / double / u32 / bytes 指针 / 句柄 +
  /// `ffc_parse_anidb_catalog_record_table` 的 7 个输出字。由 [NativeScratch] 持有，
  /// isolate 退出时释放。
  final NativeScratch _slots = NativeScratch.fixed(8 * 12);
  Pointer<Size> get sizeOut => _slots.pointer.cast<Size>();
  Pointer<Double> get doubleOut => (_slots.pointer + 8).cast<Double>();
  Pointer<Uint32> get u32Out => (_slots.pointer + 16).cast<Uint32>();
  Pointer<Pointer<Uint8>> get bytesOut =>
      (_slots.pointer + 24).cast<Pointer<Uint8>>();
  Pointer<Pointer<Void>> get handleOut =>
      (_slots.pointer + 32).cast<Pointer<Void>>();
  Pointer<Size> get recordTableWords => (_slots.pointer + 40).cast<Size>();

  final NativeScratch _units = NativeScratch(minCapacity: 2048);
  final NativeScratch _out = NativeScratch(minCapacity: 2048);

  static _AniDbNative? _instance;
  static _AniDbNative get instance =>
      _instance ??= _AniDbNative._(FushiCompute.require());

  /// 至少 [length] 个码元的输入暂存区。
  Pointer<Uint16> units(int length) => _units.reserve(length * 2).cast();

  /// 至少 [length] 个码元的输出暂存区。
  Pointer<Uint16> output(int length) => _out.reserve(length * 2).cast();

  /// 把 [text] 写进 [target] 的 [offset] 处。
  static void write(Pointer<Uint16> target, int offset, String text) {
    final int length = text.length;
    if (length == 0) return;
    final Uint16List view = target.asTypedListOutOfLine(offset + length);
    for (int i = 0; i < length; i++) {
      view[offset + i] = text.codeUnitAt(i);
    }
  }

  /// 取走 `bytesOut` / `sizeOut` 指向的 Rust 缓冲（复制进 Dart 堆后立即释放）。
  Uint8List takeBytes() {
    final Pointer<Uint8> ptr = bytesOut.value;
    final int len = sizeOut.value;
    if (ptr == nullptr || len == 0) {
      if (ptr != nullptr) compute.freeBytes(ptr, len);
      return Uint8List(0);
    }
    final Uint8List copy = Uint8List.fromList(ptr.asTypedListOutOfLine(len));
    compute.freeBytes(ptr, len);
    return copy;
  }
}

void _check(int status, String symbol) {
  if (status != FfcStatus.ok) {
    throw StateError('$symbol failed with status $status');
  }
}

/// Rust `encode_string_list` 的格式（`u32 count`、`count` 个 `u32` 长度、拼接的 UTF-16 码元）。
List<String> _decodeStringList(Uint8List bytes, [int offset = 0]) {
  if (bytes.length - offset < 4) return const <String>[];
  final ByteData data = ByteData.sublistView(bytes);
  final int count = data.getUint32(offset, Endian.little);
  int cursor = offset + 4 + 4 * count;
  final List<String> out = List<String>.filled(count, '');
  for (int i = 0; i < count; i++) {
    final int length = data.getUint32(offset + 4 + 4 * i, Endian.little);
    out[i] = String.fromCharCodes(
      Uint16List.sublistView(bytes, cursor, cursor + 2 * length),
    );
    cursor += 2 * length;
  }
  return out;
}

/// 视频刮削标题归一化与相似度（原 Dart `TitleNormalizer` 的算法；Dart 侧只剩外壳）。
abstract final class TitleScoreNative {
  /// 全角→半角 → 繁→简 → 去装饰符号 → 小写 → 空白折叠。
  static String normalize(String title) {
    final int length = title.length;
    if (length == 0) return '';
    final _AniDbNative n = _AniDbNative.instance;
    final Pointer<Uint16> input = n.units(length);
    _AniDbNative.write(input, 0, title);
    int capacity = length * 2 + 16;
    for (;;) {
      final Pointer<Uint16> out = n.output(capacity);
      final int status = n.normalize(input, length, out, capacity, n.sizeOut);
      if (status == FfcStatus.bufferTooSmall) {
        capacity = n.sizeOut.value;
        continue;
      }
      _check(status, 'ffc_parse_title_normalize');
      final int written = n.sizeOut.value;
      return written == 0
          ? ''
          : String.fromCharCodes(out.asTypedListOutOfLine(written));
    }
  }

  /// 批量 [normalize]（一次 FFI 调用），与输入同序。
  static List<String> normalizeAll(List<String> titles) {
    if (titles.isEmpty) return <String>[];
    final _AniDbNative n = _AniDbNative.instance;
    final _PackedStrings packed = _PackedStrings(titles);
    try {
      _check(
        n.normalizeBatch(
          packed.units,
          packed.offsets,
          packed.count,
          n.bytesOut,
          n.sizeOut,
        ),
        'ffc_parse_title_normalize_batch',
      );
      return _decodeStringList(n.takeBytes());
    } finally {
      packed.free();
    }
  }

  /// 相似度矩阵（一次 FFI 调用）：结果第 `q * candidates.length + c` 项是
  /// `similarityNormalized(queries[q], candidates[c])`，逐位一致。两侧都必须已归一化。
  static Float64List similarityNormalizedMatrix(
    List<String> queries,
    List<String> candidates,
  ) {
    final int total = queries.length * candidates.length;
    final Float64List result = Float64List(total);
    if (total == 0) return result;
    final _AniDbNative n = _AniDbNative.instance;
    final _PackedStrings q = _PackedStrings(queries);
    final _PackedStrings c = _PackedStrings(candidates);
    final Pointer<Double> out = calloc<Double>(total);
    try {
      _check(
        n.similarityMatrix(
          q.units,
          q.offsets,
          q.count,
          c.units,
          c.offsets,
          c.count,
          out,
        ),
        'ffc_parse_title_similarity_normalized_matrix',
      );
      result.setAll(0, out.asTypedListOutOfLine(total));
      return result;
    } finally {
      q.free();
      c.free();
      calloc.free(out);
    }
  }

  /// 分词（输入应为 [normalize] 的输出），按出现顺序、可重复。
  static List<String> tokens(String normalized) {
    if (normalized.isEmpty) return <String>[];
    final _AniDbNative n = _AniDbNative.instance;
    final Pointer<Uint16> input = n.units(normalized.length);
    _AniDbNative.write(input, 0, normalized);
    _check(
      n.tokens(input, normalized.length, n.bytesOut, n.sizeOut),
      'ffc_parse_title_tokens',
    );
    return _decodeStringList(n.takeBytes());
  }

  static double _pair(String a, String b, bool normalized) {
    final _AniDbNative n = _AniDbNative.instance;
    final Pointer<Uint16> input = n.units(a.length + b.length);
    _AniDbNative.write(input, 0, a);
    _AniDbNative.write(input, a.length, b);
    final int status = normalized
        ? n.similarityNormalized(
            input,
            a.length,
            input + a.length,
            b.length,
            n.doubleOut,
          )
        : n.similarity(
            input,
            a.length,
            input + a.length,
            b.length,
            n.doubleOut,
          );
    _check(status, 'ffc_parse_title_similarity');
    return n.doubleOut.value;
  }

  /// 相似度 [0,1]（两侧先归一化）。
  static double similarity(String a, String b) => _pair(a, b, false);

  /// 两侧都已归一化的相似度。
  static double similarityNormalized(String na, String nb) =>
      _pair(na, nb, true);

  /// 一个已归一化查询对一批已归一化候选打分（一次 FFI 调用），结果与逐个调
  /// [similarityNormalized] 逐位一致。
  static Float64List similarityNormalizedBatch(
    String query,
    List<String> candidates,
  ) {
    final int count = candidates.length;
    final Float64List result = Float64List(count);
    if (count == 0) return result;
    final _AniDbNative n = _AniDbNative.instance;
    int total = 0;
    for (final String c in candidates) {
      total += c.length;
    }
    final Pointer<Uint16> queryUnits = n.output(query.length + 1);
    _AniDbNative.write(queryUnits, 0, query);
    final Pointer<Uint16> units = n.units(total + 1);
    final Pointer<Uint32> offsets = calloc<Uint32>(count + 1);
    final Pointer<Double> out = calloc<Double>(count);
    try {
      int cursor = 0;
      for (int i = 0; i < count; i++) {
        offsets[i] = cursor;
        _AniDbNative.write(units, cursor, candidates[i]);
        cursor += candidates[i].length;
      }
      offsets[count] = cursor;
      _check(
        n.similarityBatch(queryUnits, query.length, units, offsets, count, out),
        'ffc_parse_title_similarity_normalized_batch',
      );
      result.setAll(0, out.asTypedListOutOfLine(count));
      return result;
    } finally {
      calloc.free(offsets);
      calloc.free(out);
    }
  }
}

/// 一批字符串打包进原生内存：拼接的码元 + `count + 1` 个偏移。用完 [free]（漏调也随对象
/// 回收经 [NativeScratch] 释放）。
final class _PackedStrings implements Finalizable {
  _PackedStrings(List<String> items) : count = items.length {
    int total = 0;
    for (final String s in items) {
      total += s.length;
    }
    _units = NativeScratch.fixed((total == 0 ? 1 : total) * 2);
    _offsets = NativeScratch.fixed((count + 1) * 4);
    units = _units.pointer.cast<Uint16>();
    offsets = _offsets.pointer.cast<Uint32>();
    int cursor = 0;
    for (int i = 0; i < count; i++) {
      offsets[i] = cursor;
      _AniDbNative.write(units, cursor, items[i]);
      cursor += items[i].length;
    }
    offsets[count] = cursor;
  }

  final int count;
  late final NativeScratch _units;
  late final NativeScratch _offsets;
  late final Pointer<Uint16> units;
  late final Pointer<Uint32> offsets;

  void free() {
    _units.release();
    _offsets.release();
  }
}

/// AniDB 标题包解析失败（种类与 Rust `CatalogError::kind` 一致）。
final class AniDbCatalogNativeError implements Exception {
  const AniDbCatalogNativeError(this.kind, this.detail);

  static const int forbiddenDeclaration = 1;
  static const int unexpectedRoot = 2;
  static const int tooManyRecords = 3;
  static const int tooManyTitles = 4;
  static const int invalidXml = 5;
  static const int invalidData = 6;
  static const int noUsableRecords = 7;

  final int kind;

  /// 种类 5 / 6 时的说明（XmlException / FormatException 的 toString 风格）。
  final String detail;

  @override
  String toString() => 'AniDbCatalogNativeError($kind): $detail';
}

/// 流式喂入解压后标题包的构建器。用完必须 [dispose]（成功 [finish] 之后也要）。
final class AniDbCatalogBuilderNative implements Finalizable {
  AniDbCatalogBuilderNative() : _n = _AniDbNative.instance {
    _handle = _n.builderNew();
    if (_handle == nullptr) {
      throw StateError('ffc_parse_anidb_catalog_builder_new returned null');
    }
  }

  final _AniDbNative _n;
  late Pointer<Void> _handle;

  /// 喂入块的暂存区（[NativeScratch]：[dispose] 立即归还，漏调也随对象回收释放）。
  final NativeScratch _chunk = NativeScratch();

  AniDbCatalogNativeError _error() {
    _check(
      _n.builderError(_handle, _n.u32Out, _n.bytesOut, _n.sizeOut),
      'ffc_parse_anidb_catalog_builder_error',
    );
    final int kind = _n.u32Out.value;
    final Uint8List bytes = _n.takeBytes();
    return AniDbCatalogNativeError(
      kind,
      String.fromCharCodes(Uint16List.sublistView(bytes)),
    );
  }

  void _status(int status, String symbol) {
    if (status == FfcStatus.badInput) throw _error();
    _check(status, symbol);
  }

  /// 喂一块解压后的字节。
  void add(List<int> chunk) {
    final int length = chunk.length;
    if (length == 0) return;
    final Pointer<Uint8> buffer = _chunk.reserve(length);
    buffer.asTypedListOutOfLine(length).setAll(0, chunk);
    _status(
      _n.builderFeed(_handle, buffer, length),
      'ffc_parse_anidb_catalog_builder_feed',
    );
  }

  /// 输入结束检查。
  void close() => _status(
    _n.builderClose(_handle),
    'ffc_parse_anidb_catalog_builder_close',
  );

  /// 汇总并建索引，返回目录句柄地址（交给 [AniDbCatalogNative.adopt]；可跨 isolate 传递）。
  int finish() {
    _status(
      _n.builderFinish(_handle, _n.handleOut),
      'ffc_parse_anidb_catalog_builder_finish',
    );
    return _n.handleOut.value.address;
  }

  void dispose() {
    if (_handle != nullptr) {
      _n.builderFree(_handle);
      _handle = nullptr;
    }
    _chunk.release();
  }
}

/// 一条搜索命中：[titleIndex] 是该 anime 记录里标题的下标；[kind] 0 exact / 1 prefix /
/// 2 similar。
typedef AniDbNativeSearchHit = ({
  int animeId,
  int titleIndex,
  int kind,
  double similarity,
});

/// 一条记录的标题：value / type / language / normalized。
typedef AniDbNativeTitle = ({
  String value,
  String type,
  String language,
  String normalized,
});

/// 已建好的标题目录（原生内存）。不可变，只读查询；随本对象被 GC 时经 [NativeFinalizer]
/// 释放，也可提前 [dispose]（之后任何查询都抛 [StateError]）。
final class AniDbCatalogNative implements Finalizable {
  AniDbCatalogNative._(this._n, this._handle) : _owned = true {
    _n.catalogFinalizer.attach(this, _handle, detach: this);
  }

  AniDbCatalogNative._borrowed(this._n, this._handle) : _owned = false;

  /// 接管 [AniDbCatalogBuilderNative.finish] 交出的句柄（通常来自后台 isolate）。
  /// 每个地址只能接管一次。
  factory AniDbCatalogNative.adopt(int address) {
    if (address == 0) throw ArgumentError.value(address, 'address');
    return AniDbCatalogNative._(
      _AniDbNative.instance,
      Pointer<Void>.fromAddress(address),
    );
  }

  /// 临时读 [address] 处的目录而**不接管**它（不挂 finalizer、不释放）；[body] 返回后这个
  /// 借来的对象失效（之后任何查询都抛 [StateError]）。供后台 isolate 在把句柄交出去之前
  /// 读记录表；接管仍由调用方 [AniDbCatalogNative.adopt] 恰好做一次。
  static R borrow<R>(int address, R Function(AniDbCatalogNative catalog) body) {
    if (address == 0) throw ArgumentError.value(address, 'address');
    final AniDbCatalogNative catalog = AniDbCatalogNative._borrowed(
      _AniDbNative.instance,
      Pointer<Void>.fromAddress(address),
    );
    try {
      return body(catalog);
    } finally {
      catalog._table = null;
      catalog._handle = nullptr;
    }
  }

  final _AniDbNative _n;
  final bool _owned;
  Pointer<Void> _handle;

  bool get isDisposed => _handle == nullptr;

  Pointer<Void> _live() {
    if (_handle == nullptr) {
      throw StateError('AniDB title catalog has been released');
    }
    return _handle;
  }

  /// 全部 anime id（升序）。
  List<int> animeIds() {
    _check(
      _n.catalogIds(_live(), _n.bytesOut, _n.sizeOut),
      'ffc_parse_anidb_catalog_anime_ids',
    );
    final Uint8List bytes = _n.takeBytes();
    final ByteData data = ByteData.sublistView(bytes);
    return <int>[
      for (int i = 0; i + 8 <= bytes.length; i += 8)
        data.getInt64(i, Endian.little),
    ];
  }

  _AniDbRecordTable? _table;

  /// 目录的扁平记录表：原生内存上的零拷贝视图，首次取记录时一次 FFI 借出、之后按 id 二分
  /// 纯 Dart 读取（不再逐条跨 FFI、不再在 Rust 侧逐条复制 + 编码）。视图只在本对象内部用、
  /// 每次都先过 [_live]，[dispose] 后不会再被读到。
  _AniDbRecordTable get _recordTable {
    final Pointer<Void> handle = _live();
    final _AniDbRecordTable? cached = _table;
    if (cached != null) return cached;
    final Pointer<Size> w = _n.recordTableWords;
    _check(
      _n.catalogRecordTable(handle, w, _n.bytesOut, _n.sizeOut),
      'ffc_parse_anidb_catalog_record_table',
    );
    final List<String> strings = _decodeStringList(_n.takeBytes());
    final int records = w[1];
    final int titles = w[4];
    final int units = w[6];
    return _table = _AniDbRecordTable(
      ids: records == 0
          ? Int64List(0)
          : Pointer<Int64>.fromAddress(w[0]).asTypedListOutOfLine(records),
      titleStart: Pointer<Uint32>.fromAddress(
        w[2],
      ).asTypedListOutOfLine(records + 1),
      titles: titles == 0
          ? Uint32List(0)
          : Pointer<Uint32>.fromAddress(w[3]).asTypedListOutOfLine(6 * titles),
      units: units == 0
          ? Uint16List(0)
          : Pointer<Uint16>.fromAddress(w[5]).asTypedListOutOfLine(units),
      strings: strings,
    );
  }

  /// [animeId] 的标题，逐个交给 [make]（value / type / language / normalized）构造调用方
  /// 自己的对象；没有该记录时 null。type / language 是去重后的同一批 [String] 实例；
  /// normalized 与 value 相同时直接是 value 那个实例。
  List<T>? recordTitles<T>(
    int animeId,
    T Function(String value, String type, String language, String normalized)
    make,
  ) {
    final _AniDbRecordTable t = _recordTable;
    final Int64List ids = t.ids;
    int low = 0;
    int high = ids.length;
    while (low < high) {
      final int middle = (low + high) >> 1;
      if (ids[middle] < animeId) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low >= ids.length || ids[low] != animeId) return null;
    return recordTitlesAt(low, make);
  }

  /// 记录条数（记录按 anime id 升序编号 `0..recordCount-1`）。
  int get recordCount => _recordTable.ids.length;

  /// 第 [index] 条记录的 anime id。
  int animeIdAt(int index) => _recordTable.ids[index];

  /// 第 [index] 条记录的标题（见 [recordTitles]）。
  List<T> recordTitlesAt<T>(
    int index,
    T Function(String value, String type, String language, String normalized)
    make,
  ) {
    final _AniDbRecordTable t = _recordTable;
    final int first = t.titleStart[index];
    final int count = t.titleStart[index + 1] - first;
    final Uint32List w = t.titles;
    final Uint16List units = t.units;
    final List<String> strings = t.strings;
    return List<T>.generate(count, (int i) {
      final int k = 6 * (first + i);
      final int valueAt = w[k];
      final int valueEnd = valueAt + w[k + 1];
      final String value = String.fromCharCodes(units, valueAt, valueEnd);
      final int normAt = w[k + 2];
      final int normLength = w[k + 3];
      final String normalized = normAt == valueAt && normLength == w[k + 1]
          ? value
          : String.fromCharCodes(units, normAt, normAt + normLength);
      return make(value, strings[w[k + 4]], strings[w[k + 5]], normalized);
    }, growable: false);
  }

  /// [animeId] 的标题（没有该记录时 null）。
  List<AniDbNativeTitle>? find(int animeId) => recordTitles(
    animeId,
    (String value, String type, String language, String normalized) =>
        (value: value, type: type, language: language, normalized: normalized),
  );

  /// 搜索（[normalizedQuery] 必须是 [TitleScoreNative.normalize] 的输出）。
  List<AniDbNativeSearchHit> search(String normalizedQuery, int limit) {
    final Pointer<Void> handle = _live();
    if (limit <= 0 || normalizedQuery.isEmpty) {
      return const <AniDbNativeSearchHit>[];
    }
    final Pointer<Uint16> input = _n.units(normalizedQuery.length);
    _AniDbNative.write(input, 0, normalizedQuery);
    _check(
      _n.catalogSearch(
        handle,
        input,
        normalizedQuery.length,
        limit > 0xFFFFFFFF ? 0xFFFFFFFF : limit,
        _n.bytesOut,
        _n.sizeOut,
      ),
      'ffc_parse_anidb_catalog_search',
    );
    final Uint8List bytes = _n.takeBytes();
    final ByteData data = ByteData.sublistView(bytes);
    final int count = data.getUint32(0, Endian.little);
    return <AniDbNativeSearchHit>[
      for (int i = 0; i < count; i++)
        (
          animeId: data.getInt64(8 + 24 * i, Endian.little),
          titleIndex: data.getUint32(16 + 24 * i, Endian.little),
          kind: data.getUint32(20 + 24 * i, Endian.little),
          similarity: data.getFloat64(24 + 24 * i, Endian.little),
        ),
    ];
  }

  /// 立即释放原生内存。
  void dispose() {
    if (_handle == nullptr) return;
    if (!_owned)
      throw StateError('A borrowed AniDB title catalog is not owned');
    _n.catalogFinalizer.detach(this);
    _table = null;
    _n.catalogFree(_handle);
    _handle = nullptr;
  }
}

/// [AniDbCatalogNative] 借出的记录表视图（布局见 Rust `catalog::RecordTable`）。
final class _AniDbRecordTable {
  const _AniDbRecordTable({
    required this.ids,
    required this.titleStart,
    required this.titles,
    required this.units,
    required this.strings,
  });

  final Int64List ids;
  final Uint32List titleStart;
  final Uint32List titles;
  final Uint16List units;
  final List<String> strings;
}

/// anime XML 解析失败。[kind]：1 禁止的 DOCTYPE/ENTITY 声明 / 2 解析失败（`XmlParserException`）
/// / 3 闭合标签错位 / 4 多余的闭合标签 / 5 缺闭合标签（后三种对应 `XmlTagException`）。
/// [position] 是 UTF-16 码元下标。
final class FfcXmlParseError implements Exception {
  const FfcXmlParseError({
    required this.kind,
    required this.position,
    required this.message,
    required this.expectedName,
    required this.actualName,
  });

  static const int forbiddenDeclaration = 1;
  static const int parser = 2;
  static const int mismatchClosingTag = 3;
  static const int unexpectedClosingTag = 4;
  static const int missingClosingTag = 5;

  final int kind;
  final int position;
  final String message;
  final String expectedName;
  final String actualName;

  @override
  String toString() =>
      'FfcXmlParseError($kind at $position): $message $expectedName $actualName';
}

/// 原生解析出的只读 XML 元素树（`package:xml` DOM 取值语义的子集）。
final class FfcXmlElement {
  FfcXmlElement._(this._doc, this._index);

  final _FfcXmlDocument _doc;
  final int _index;

  /// 限定名（含前缀）。
  String get name => _doc.names[_index];

  /// 本地名（`indexOf(':') > 0` 时取其后）。
  String get localName {
    final String n = name;
    final int index = n.indexOf(':');
    return index > 0 ? n.substring(index + 1) : n;
  }

  FfcXmlElement? get parent {
    final int p = _doc.parents[_index];
    return p < 0 ? null : _doc.elements[p];
  }

  List<FfcXmlElement> get childElements => _doc.children[_index];

  /// 按出现顺序的属性（限定名, 值）。
  List<(String, String)> get attributes => _doc.attributes[_index];

  /// 限定名为 [name] 的第一个属性值（`XmlElement.getAttribute(name)`）。
  String? getAttribute(String name) {
    for (final (String n, String v) in attributes) {
      if (n == name) return v;
    }
    return null;
  }

  /// 本地名为 [local]、命名空间 URI 为 [namespaceUri] 的第一个属性值
  /// （`getAttribute(local, namespace: uri)`：前缀经祖先的 `xmlns:前缀` 解析，
  /// 无前缀的属性取最近的默认命名空间 `xmlns`）。
  String? getAttributeNs(String local, String namespaceUri) {
    for (final (String n, String v) in attributes) {
      final int index = n.indexOf(':');
      final String? prefix = index > 0 ? n.substring(0, index) : null;
      final String attrLocal = index > 0 ? n.substring(index + 1) : n;
      if (attrLocal != local) continue;
      final String? uri = prefix == null
          ? _lookup(null, 'xmlns')
          : _lookup('xmlns', prefix);
      if (uri == namespaceUri) return v;
    }
    return null;
  }

  String? _lookup(String? prefix, String local) {
    for (FfcXmlElement? e = this; e != null; e = e.parent) {
      for (final (String n, String v) in e.attributes) {
        final int index = n.indexOf(':');
        final String? p = index > 0 ? n.substring(0, index) : null;
        final String l = index > 0 ? n.substring(index + 1) : n;
        if (p == prefix && l == local) return v;
      }
    }
    return null;
  }

  /// 限定名为 [name] 的第一个子元素。
  FfcXmlElement? getElement(String name) {
    for (final FfcXmlElement child in childElements) {
      if (child.name == name) return child;
    }
    return null;
  }

  /// 限定名为 [name] 的子元素。
  Iterable<FfcXmlElement> findElements(String name) =>
      childElements.where((FfcXmlElement child) => child.name == name);

  /// 全部后代文本 / CDATA 的拼接（`innerText`）。
  String get innerText => _doc.text.substring(
    _doc.textRanges[2 * _index],
    _doc.textRanges[2 * _index + 1],
  );
}

final class _FfcXmlDocument {
  _FfcXmlDocument(Uint8List bytes) {
    final ByteData data = ByteData.sublistView(bytes);
    final int elementCount = data.getUint32(0, Endian.little);
    final int attrCount = data.getUint32(4, Endian.little);
    final int textUnits = data.getUint32(8, Endian.little);
    final int stringUnits = data.getUint32(12, Endian.little);
    const int elementsAt = 16;
    final int attrsAt = elementsAt + 28 * elementCount;
    final int textAt = attrsAt + 16 * attrCount;
    final int stringsAt = textAt + 2 * textUnits;
    text = String.fromCharCodes(
      Uint16List.sublistView(bytes, textAt, stringsAt),
    );
    final Uint16List strings = Uint16List.sublistView(
      bytes,
      stringsAt,
      stringsAt + 2 * stringUnits,
    );
    String str(int offset, int length) =>
        String.fromCharCodes(strings, offset, offset + length);
    final List<(String, String)> allAttrs = <(String, String)>[
      for (int i = 0; i < attrCount; i++)
        (
          str(
            data.getUint32(attrsAt + 16 * i, Endian.little),
            data.getUint32(attrsAt + 16 * i + 4, Endian.little),
          ),
          str(
            data.getUint32(attrsAt + 16 * i + 8, Endian.little),
            data.getUint32(attrsAt + 16 * i + 12, Endian.little),
          ),
        ),
    ];
    parents = List<int>.filled(elementCount, -1);
    names = List<String>.filled(elementCount, '');
    attributes = List<List<(String, String)>>.filled(
      elementCount,
      const <(String, String)>[],
    );
    textRanges = Int32List(2 * elementCount);
    children = <List<FfcXmlElement>>[
      for (int i = 0; i < elementCount; i++) <FfcXmlElement>[],
    ];
    elements = <FfcXmlElement>[
      for (int i = 0; i < elementCount; i++) FfcXmlElement._(this, i),
    ];
    for (int i = 0; i < elementCount; i++) {
      int w(int k) =>
          data.getUint32(elementsAt + 28 * i + 4 * k, Endian.little);
      final int parent = w(0);
      parents[i] = parent == 0xFFFFFFFF ? -1 : parent;
      names[i] = str(w(1), w(2));
      attributes[i] = allAttrs.sublist(w(3), w(3) + w(4));
      textRanges[2 * i] = w(5);
      textRanges[2 * i + 1] = w(6);
      if (parents[i] >= 0) children[parents[i]].add(elements[i]);
    }
  }

  late final String text;
  late final List<int> parents;
  late final List<String> names;
  late final List<List<(String, String)>> attributes;
  late final Int32List textRanges;
  late final List<List<FfcXmlElement>> children;
  late final List<FfcXmlElement> elements;
}

/// 解析单部 AniDB anime XML（含 `<!DOCTYPE` / `<!ENTITY` 预检），返回根元素；
/// 失败抛 [FfcXmlParseError]。
FfcXmlElement parseAniDbAnimeXml(String xml) {
  final _AniDbNative n = _AniDbNative.instance;
  final Pointer<Uint16> input = n.units(xml.length);
  _AniDbNative.write(input, 0, xml);
  final int status = n.animeXml(input, xml.length, n.bytesOut, n.sizeOut);
  if (status == FfcStatus.badInput) {
    final Uint8List bytes = n.takeBytes();
    final ByteData data = ByteData.sublistView(bytes);
    final List<String> items = _decodeStringList(bytes, 8);
    throw FfcXmlParseError(
      kind: data.getUint32(0, Endian.little),
      position: data.getUint32(4, Endian.little),
      message: items[0],
      expectedName: items[1],
      actualName: items[2],
    );
  }
  _check(status, 'ffc_parse_anidb_anime_xml');
  final _FfcXmlDocument doc = _FfcXmlDocument(n.takeBytes());
  for (int i = 0; i < doc.parents.length; i++) {
    if (doc.parents[i] < 0) return doc.elements[i];
  }
  throw StateError('ffc_parse_anidb_anime_xml returned no root element');
}
