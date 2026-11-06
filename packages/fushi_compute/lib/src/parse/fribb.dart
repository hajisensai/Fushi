import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';

typedef _EntriesC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
      Pointer<Int32>,
      Pointer<Size>,
    );
typedef _EntriesDart =
    int Function(
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
      Pointer<Int32>,
      Pointer<Size>,
    );

/// Fribb `anime-list-full.json` 一个 AniDB 条目的原生解析结果（字段语义同 fushi_engine 的
/// `AnimeIdentityEntry`；`malIds` 按插入序去重）。
final class FfcFribbEntry {
  const FfcFribbEntry({
    required this.anidbId,
    required this.malIds,
    required this.anilistId,
    required this.tvdbId,
    required this.tmdbId,
    required this.tmdbSeason,
    required this.tmdbEpisodeOffset,
    required this.tvdbSeason,
    required this.tvdbEpisodeOffset,
    required this.type,
    required this.tmdbIsMovieNamespace,
  });

  final int anidbId;
  final List<int> malIds;
  final int? anilistId;
  final int? tvdbId;
  final int? tmdbId;
  final int? tmdbSeason;
  final int? tmdbEpisodeOffset;
  final int? tvdbSeason;
  final int? tvdbEpisodeOffset;
  final String? type;
  final bool tmdbIsMovieNamespace;
}

/// Fribb 全表不是合法 JSON（[offset] 是出错的 UTF-8 字节位置）。
final class FfcFribbInvalidJson implements Exception {
  const FfcFribbInvalidJson(this.offset);

  final int offset;

  @override
  String toString() => 'FormatException: invalid JSON (at byte $offset)';
}

/// Fribb 全表是合法 JSON 但顶层不是数组。
final class FfcFribbNotAList implements Exception {
  const FfcFribbNotAList();

  @override
  String toString() => 'FormatException: top-level JSON value is not a list';
}

/// Fribb 映射全表解析 + 按 AniDB 条目归并的原生实现（`native/fushi_compute/src/parse/
/// fribb.rs` 的 `ffc_parse_fribb_entries`）。唯一实现、没有 Dart 回退。
final class FribbNative {
  FribbNative._(this._compute, this._entries);

  final FushiCompute _compute;
  final _EntriesDart _entries;

  static FribbNative? _instance;

  /// 本 isolate 的实例（首次访问时加载并 lookup 符号）。
  static FribbNative get instance => _instance ??= _load();

  static FribbNative _load() {
    final FushiCompute compute = FushiCompute.require();
    try {
      return FribbNative._(
        compute,
        compute.library.lookupFunction<_EntriesC, _EntriesDart>(
          'ffc_parse_fribb_entries',
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  /// 解析 UTF-8 编码的全表，条目按 anidb_id 首次出现的顺序返回。
  /// 不是合法 JSON 抛 [FfcFribbInvalidJson]，顶层不是数组抛 [FfcFribbNotAList]。
  List<FfcFribbEntry> parseEntries(Uint8List utf8Json) {
    final Pointer<Uint8> input = calloc<Uint8>(
      utf8Json.isEmpty ? 1 : utf8Json.length,
    );
    final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = calloc<Size>();
    final Pointer<Int32> errorKind = calloc<Int32>();
    final Pointer<Size> errorOffset = calloc<Size>();
    try {
      input.asTypedListOutOfLine(utf8Json.length).setAll(0, utf8Json);
      final int status = _entries(
        input,
        utf8Json.length,
        outPtr,
        outLen,
        errorKind,
        errorOffset,
      );
      if (status == FfcStatus.badInput) {
        if (errorKind.value == 2) throw const FfcFribbNotAList();
        throw FfcFribbInvalidJson(errorOffset.value);
      }
      if (status != FfcStatus.ok) {
        throw StateError('ffc_parse_fribb_entries failed with status $status');
      }
      final Pointer<Uint8> ptr = outPtr.value;
      final int len = outLen.value;
      try {
        return _decode(ptr.asTypedListOutOfLine(len));
      } finally {
        _compute.freeBytes(ptr, len);
      }
    } finally {
      calloc.free(input);
      calloc.free(outPtr);
      calloc.free(outLen);
      calloc.free(errorKind);
      calloc.free(errorOffset);
    }
  }

  /// 布局见 fribb.rs 的 `encode`：`[i64 n, i64 mal池长, i64 字符池长][n × 13 i64][mal 池][u16 池]`。
  static List<FfcFribbEntry> _decode(Uint8List bytes) {
    const int recordInts = 13;
    final ByteData data = ByteData.sublistView(bytes);
    int at(int index) => data.getInt64(index * 8, Endian.host);
    final int n = at(0);
    final int malCount = at(1);
    final int malStart = 3 + n * recordInts;
    final int poolStart = (malStart + malCount) * 8;
    final Uint16List pool = Uint16List((bytes.length - poolStart) >> 1);
    pool.buffer.asUint8List().setRange(0, pool.length * 2, bytes, poolStart);
    int? opt(int index) {
      final int value = at(index);
      return value < 0 ? null : value;
    }

    return List<FfcFribbEntry>.generate(n, (int i) {
      final int base = 3 + i * recordInts;
      final int typeLength = at(base + 10);
      final int typeOffset = at(base + 9);
      final int malOffset = at(base + 11);
      final int mals = at(base + 12);
      return FfcFribbEntry(
        anidbId: at(base),
        malIds: List<int>.generate(
          mals,
          (int j) => at(malStart + malOffset + j),
          growable: false,
        ),
        anilistId: opt(base + 1),
        tvdbId: opt(base + 2),
        tmdbId: opt(base + 3),
        tmdbSeason: opt(base + 4),
        tmdbEpisodeOffset: opt(base + 5),
        tvdbSeason: opt(base + 6),
        tvdbEpisodeOffset: opt(base + 7),
        tmdbIsMovieNamespace: at(base + 8) & 1 == 1,
        type: typeLength < 0
            ? null
            : String.fromCharCodes(pool, typeOffset, typeOffset + typeLength),
      );
    }, growable: false);
  }
}
