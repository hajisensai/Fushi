import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';

typedef _MatcherNewC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Uint64>,
      Size,
      Pointer<Pointer<Void>>,
    );
typedef _MatcherNewDart =
    int Function(
      Pointer<Uint16>,
      int,
      Pointer<Uint64>,
      int,
      Pointer<Pointer<Void>>,
    );
typedef _MatcherFreeC = Void Function(Pointer<Void>);
typedef _NamesInC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint16>,
      Size,
      Pointer<Uint64>,
      Size,
      Pointer<Uint64>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _NamesInDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint16>,
      int,
      Pointer<Uint64>,
      int,
      Pointer<Uint64>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _LowerC = Int32 Function(Pointer<Uint16>, Size);
typedef _LowerDart = int Function(Pointer<Uint16>, int);

final class _AnkiBindings {
  _AnkiBindings._(DynamicLibrary lib)
    : matcherNew = lib.lookupFunction<_MatcherNewC, _MatcherNewDart>(
        'ffc_parse_anki_matcher_new',
      ),
      matcherFreePointer = lib.lookup<NativeFunction<_MatcherFreeC>>(
        'ffc_parse_anki_matcher_free',
      ),
      namesIn = lib.lookupFunction<_NamesInC, _NamesInDart>(
        'ffc_parse_anki_names_in',
      ),
      lower = lib.lookupFunction<_LowerC, _LowerDart>(
        'ffc_parse_anki_lower_utf16',
        isLeaf: true,
      );

  final _MatcherNewDart matcherNew;
  final Pointer<NativeFunction<_MatcherFreeC>> matcherFreePointer;
  late final NativeFinalizer matcherFree = NativeFinalizer(matcherFreePointer);
  late final void Function(Pointer<Void>) matcherFreeNow = matcherFreePointer
      .asFunction<void Function(Pointer<Void>)>();
  final _NamesInDart namesIn;
  final _LowerDart lower;

  static final Expando<_AnkiBindings> _cache = Expando<_AnkiBindings>();

  static _AnkiBindings of(FushiCompute compute) {
    final _AnkiBindings? cached = _cache[compute];
    if (cached != null) return cached;
    try {
      return _cache[compute] = _AnkiBindings._(compute.library);
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }
}

/// 一批字符串摊平进一块原生 UTF-16 缓冲区 + `count + 1` 个 u64 偏移。
final class _Utf16Batch {
  _Utf16Batch._(this.units, this.unitCount, this.offsets);

  factory _Utf16Batch(List<String> strings) {
    int total = 0;
    for (final String s in strings) {
      total += s.length;
    }
    final int capacity = total == 0 ? 1 : total;
    final Pointer<Uint16> units = malloc<Uint16>(capacity);
    final Pointer<Uint64> offsets = malloc<Uint64>(strings.length + 1);
    // 直接经 Pointer 下标写，不经 `asTypedList` 视图逐元素写：Dart 3.13.5 的 JIT 下，对每次新建的
    // 外部 Uint16List 视图逐元素 `[]=`（含 `setRange(…, s.codeUnits)`）在优化后会访问违例崩溃
    // （2026-10-18 本机复现：同一循环写进 Pointer 或从堆上 Uint16List memcpy 都不崩；AOT 不崩）。
    int at = 0;
    for (int i = 0; i < strings.length; i++) {
      offsets[i] = at;
      final String s = strings[i];
      final int length = s.length;
      for (int j = 0; j < length; j++) {
        units[at + j] = s.codeUnitAt(j);
      }
      at += length;
    }
    offsets[strings.length] = at;
    return _Utf16Batch._(units, total, offsets);
  }

  final Pointer<Uint16> units;
  final int unitCount;
  final Pointer<Uint64> offsets;

  void free() {
    malloc.free(units);
    malloc.free(offsets);
  }
}

/// Anki 媒体去重的引用扫描核心（`native/fushi_compute/src/parse/anki_media.rs`）：在笔记字段
/// 正文里找出出现了哪些媒体文件名。口径与 Anki `findNotes "<文件名>"` 对齐——按 Dart
/// `toLowerCase` 折叠后的朴素子串，不判文件名边界；命中顺序与原 Dart `MediaNameMatcher`
/// 相同（见 Rust 模块注释）。
///
/// 这是唯一实现，没有 Dart 回退；库不可用抛 [FushiComputeUnavailableError]。原生匹配器随
/// 本对象被回收时释放（[NativeFinalizer]），也可以提前 [close]。
final class FfcMediaNameMatcher implements Finalizable {
  FfcMediaNameMatcher._(this._compute, this._bindings, this._handle);

  /// 用 [names] 建匹配器；扫描结果里的下标指回 [names]。
  factory FfcMediaNameMatcher(List<String> names) {
    final FushiCompute compute = FushiCompute.require();
    final _AnkiBindings bindings = _AnkiBindings.of(compute);
    final _Utf16Batch batch = _Utf16Batch(names);
    final Pointer<Pointer<Void>> out = calloc<Pointer<Void>>();
    try {
      final int status = bindings.matcherNew(
        batch.units,
        batch.unitCount,
        batch.offsets,
        names.length,
        out,
      );
      if (status != FfcStatus.ok) {
        throw StateError(
          'ffc_parse_anki_matcher_new failed with status $status',
        );
      }
      final FfcMediaNameMatcher matcher = FfcMediaNameMatcher._(
        compute,
        bindings,
        out.value,
      );
      bindings.matcherFree.attach(matcher, out.value.cast(), detach: matcher);
      return matcher;
    } finally {
      batch.free();
      calloc.free(out);
    }
  }

  final FushiCompute _compute;
  final _AnkiBindings _bindings;
  Pointer<Void> _handle;

  /// 一次扫一批组：`groups[g]` 是一组正文（例如一条笔记的全部字段），返回每组命中的名字
  /// 下标（组内并集，首次出现序；同一下标不重复）。
  List<Uint32List> scanGroups(List<List<String>> groups) {
    if (_handle == nullptr) throw StateError('matcher already closed');
    final List<String> texts = <String>[
      for (final List<String> group in groups) ...group,
    ];
    final _Utf16Batch batch = _Utf16Batch(texts);
    final Pointer<Uint64> groupOffsets = malloc<Uint64>(groups.length + 1);
    final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = calloc<Size>();
    try {
      int at = 0;
      for (int g = 0; g < groups.length; g++) {
        groupOffsets[g] = at;
        at += groups[g].length;
      }
      groupOffsets[groups.length] = at;
      final int status = _bindings.namesIn(
        _handle,
        batch.units,
        batch.unitCount,
        batch.offsets,
        texts.length,
        groupOffsets,
        groups.length,
        outPtr,
        outLen,
      );
      if (status != FfcStatus.ok) {
        throw StateError('ffc_parse_anki_names_in failed with status $status');
      }
      final Pointer<Uint8> out = outPtr.value;
      final int length = outLen.value;
      try {
        final ByteData data = out
            .asTypedListOutOfLine(length)
            .buffer
            .asByteData(0, length);
        final int hitBase = (groups.length + 1) * 4;
        int read(int index) => data.getUint32(index * 4, Endian.little);
        return List<Uint32List>.generate(groups.length, (int g) {
          final int start = read(g);
          final int end = read(g + 1);
          final Uint32List hits = Uint32List(end - start);
          for (int i = 0; i < hits.length; i++) {
            hits[i] = data.getUint32(hitBase + (start + i) * 4, Endian.little);
          }
          return hits;
        }, growable: false);
      } finally {
        _compute.freeBytes(out, length);
      }
    } finally {
      batch.free();
      malloc.free(groupOffsets);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  /// 提前释放原生匹配器；幂等。之后不可再 [scanGroups]。
  void close() {
    if (_handle == nullptr) return;
    _bindings.matcherFree.detach(this);
    final Pointer<Void> handle = _handle;
    _handle = nullptr;
    _bindings.matcherFreeNow(handle);
  }

  /// [text] 按扫描口径（Dart `toLowerCase` 的逐码点折叠表）折叠后的结果。只用于口径自检。
  static String foldForMatching(String text) {
    if (text.isEmpty) return text;
    final FushiCompute compute = FushiCompute.require();
    final _AnkiBindings bindings = _AnkiBindings.of(compute);
    final Pointer<Uint16> buffer = malloc<Uint16>(text.length);
    try {
      for (int i = 0; i < text.length; i++) {
        buffer[i] = text.codeUnitAt(i);
      }
      final int status = bindings.lower(buffer, text.length);
      if (status != FfcStatus.ok) {
        throw StateError(
          'ffc_parse_anki_lower_utf16 failed with status $status',
        );
      }
      return String.fromCharCodes(buffer.asTypedListOutOfLine(text.length));
    } finally {
      malloc.free(buffer);
    }
  }
}
