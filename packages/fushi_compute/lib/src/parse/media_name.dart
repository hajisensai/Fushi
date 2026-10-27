import 'dart:ffi';
import 'dart:typed_data';

import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _BatchC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Uint32>,
      Size,
      Pointer<Uint16>,
      Size,
      Pointer<Uint32>,
      Size,
      Int32,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _BatchDart =
    int Function(
      Pointer<Uint16>,
      int,
      Pointer<Uint32>,
      int,
      Pointer<Uint16>,
      int,
      Pointer<Uint32>,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _TrailingSeasonC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Uint32>,
      Size,
      Pointer<Int32>,
    );
typedef _TrailingSeasonDart =
    int Function(Pointer<Uint16>, int, Pointer<Uint32>, int, Pointer<Int32>);

/// 一个名字的原生解析结果（字段语义同 fushi_engine 的 `ParsedMediaName`）。
final class FfcParsedName {
  const FfcParsedName({
    required this.inputIndex,
    required this.title,
    required this.secondaryTitle,
    required this.titleWithTrailingYear,
    required this.releaseGroup,
    required this.resolution,
    required this.episode,
    required this.season,
    required this.year,
    required this.isMovieHint,
  });

  /// 这条结果来自第几个输入（候选批量里一个路径可产出 0～2 条）。
  final int inputIndex;
  final String title;
  final String? secondaryTitle;
  final String? titleWithTrailingYear;
  final String? releaseGroup;
  final String? resolution;
  final int? episode;
  final int? season;
  final int? year;
  final bool isMovieHint;
}

/// [MediaNameNative.trailingSeasons] 的一项：季号 + 去掉季号后标题在输入里的区间。
typedef FfcTrailingSeason = ({int season, int titleStart, int titleEnd});

/// 原生库暂存区：一组字符串按 UTF-16 码元连续写进一块原生内存 + 各自长度。
/// 每个 isolate 各持一份（[NativeScratch]：随 isolate 存活，退出时由 finalizer 释放）。
final class Utf16BatchBuffer implements Finalizable {
  final NativeScratch _units = NativeScratch(minCapacity: 512);
  final NativeScratch _lens = NativeScratch(minCapacity: 1024);

  /// 最近一次 [fill] 写入的码元 / 长度数组（下一次 [fill] 前有效）。
  Pointer<Uint16> units = nullptr;
  Pointer<Uint32> lens = nullptr;

  /// 已写入的码元总数 / 字符串个数。
  int unitCount = 0;
  int count = 0;

  /// 写入 [values]（覆盖上一次）。
  void fill(List<String> values) {
    int total = 0;
    for (final String value in values) {
      total += value.length;
    }
    units = _units.reserve(total * 2).cast<Uint16>();
    lens = _lens.reserve(values.length * 4).cast<Uint32>();
    final Uint16List unitView = units.asTypedListOutOfLine(total);
    final Uint32List lenView = lens.asTypedListOutOfLine(values.length);
    int offset = 0;
    for (int i = 0; i < values.length; i++) {
      final String value = values[i];
      final int length = value.length;
      for (int j = 0; j < length; j++) {
        unitView[offset + j] = value.codeUnitAt(j);
      }
      lenView[i] = length;
      offset += length;
    }
    unitCount = total;
    count = values.length;
  }
}

/// 视频文件名 / 目录名解析的原生实现（`native/fushi_compute/src/parse/media_name.rs` 的
/// `ffc_parse_filename_*`）。这是规则引擎**唯一**的运行时实现：没有 Dart 回退，库或符号
/// 缺失时 [instance] 抛 [FushiComputeUnavailableError]。
///
/// 接口一律批量：一次 FFI 调用解析一组字符串，结果是定长记录 + UTF-16 池一次交回。
final class MediaNameNative implements Finalizable {
  MediaNameNative._(
    this._compute,
    this._parse,
    this._candidates,
    this._trailing,
  );

  final FushiCompute _compute;
  final _BatchDart _parse;
  final _BatchDart _candidates;
  final _TrailingSeasonDart _trailing;
  final Utf16BatchBuffer _input = Utf16BatchBuffer();
  final Utf16BatchBuffer _extensions = Utf16BatchBuffer();

  /// 固定输出槽：outPtr（指针）+ outLen（size_t）。
  final NativeScratch _slots = NativeScratch.fixed(16);
  Pointer<Pointer<Uint8>> get _outPtr => _slots.pointer.cast<Pointer<Uint8>>();
  Pointer<Size> get _outLen => (_slots.pointer + 8).cast<Size>();
  final NativeScratch _seasonOut = NativeScratch(minCapacity: 1024);
  Object? _extensionsKey;

  static MediaNameNative? _instance;

  /// 本 isolate 的实例（首次访问时加载并 lookup 符号）。
  static MediaNameNative get instance => _instance ??= _load();

  static MediaNameNative _load() {
    final FushiCompute compute = FushiCompute.require();
    // lookup 名写成字符串字面量：verify_abi.sh 从绑定源码抓期望符号集。
    try {
      return MediaNameNative._(
        compute,
        compute.library.lookupFunction<_BatchC, _BatchDart>(
          'ffc_parse_filename_parse_batch',
        ),
        compute.library.lookupFunction<_BatchC, _BatchDart>(
          'ffc_parse_filename_candidates_batch',
        ),
        compute.library.lookupFunction<_TrailingSeasonC, _TrailingSeasonDart>(
          'ffc_parse_filename_trailing_season_batch',
          isLeaf: true,
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  /// 逐个解析 [names]（结果与输入一一对应）。[extensions] 是要剥掉的扩展名（小写含点），
  /// [currentYear] 是「今年」（尾部裸年份晚于明年不认）。
  List<FfcParsedName> parseNames(
    List<String> names, {
    required Iterable<String> extensions,
    required int currentYear,
  }) => _run(
    _parse,
    'ffc_parse_filename_parse_batch',
    names,
    extensions,
    currentYear,
  );

  /// 逐个路径给出有序候选（目录名候选在前、文件名候选在后），`inputIndex` 是路径下标。
  List<FfcParsedName> candidatesForPaths(
    List<String> paths, {
    required Iterable<String> extensions,
    required int currentYear,
  }) => _run(
    _candidates,
    'ffc_parse_filename_candidates_batch',
    paths,
    extensions,
    currentYear,
  );

  /// 「标题尾部裸数字季号」：逐个输入给出季号与去掉季号后标题的区间，不是季号为 null。
  List<FfcTrailingSeason?> trailingSeasons(List<String> texts) {
    if (texts.isEmpty) return const <FfcTrailingSeason?>[];
    _input.fill(texts);
    final int needed = texts.length * 3;
    final Pointer<Int32> seasonOut = _seasonOut.reserve(needed * 4).cast();
    final int status = _trailing(
      _input.units,
      _input.unitCount,
      _input.lens,
      _input.count,
      seasonOut,
    );
    if (status != FfcStatus.ok) {
      throw StateError(
        'ffc_parse_filename_trailing_season_batch failed with status $status',
      );
    }
    final Int32List out = seasonOut.asTypedListOutOfLine(needed);
    return <FfcTrailingSeason?>[
      for (int i = 0; i < texts.length; i++)
        out[i * 3] < 0
            ? null
            : (
                season: out[i * 3],
                titleStart: out[i * 3 + 1],
                titleEnd: out[i * 3 + 2],
              ),
    ];
  }

  List<FfcParsedName> _run(
    _BatchDart call,
    String symbol,
    List<String> inputs,
    Iterable<String> extensions,
    int currentYear,
  ) {
    if (inputs.isEmpty) return const <FfcParsedName>[];
    if (!identical(_extensionsKey, extensions)) {
      _extensions.fill(extensions.toList(growable: false));
      _extensionsKey = extensions;
    }
    _input.fill(inputs);
    final int status = call(
      _input.units,
      _input.unitCount,
      _input.lens,
      _input.count,
      _extensions.units,
      _extensions.unitCount,
      _extensions.lens,
      _extensions.count,
      currentYear,
      _outPtr,
      _outLen,
    );
    if (status != FfcStatus.ok) {
      throw StateError('$symbol failed with status $status');
    }
    final Pointer<Uint8> ptr = _outPtr.value;
    final int len = _outLen.value;
    try {
      return _decode(ptr.asTypedListOutOfLine(len));
    } finally {
      _compute.freeBytes(ptr, len);
    }
  }

  /// 布局见 media_name.rs 的 `encode_records`：`[i32 n][n × 16 i32][u16 池]`。
  static List<FfcParsedName> _decode(Uint8List bytes) {
    const int recordInts = 16;
    final ByteData data = ByteData.sublistView(bytes);
    final int n = data.getInt32(0, Endian.host);
    final int poolStart = 4 + n * recordInts * 4;
    // 拷进 Dart 堆（对齐无关），再按区间建字符串。
    final Uint16List pool = Uint16List((bytes.length - poolStart) >> 1);
    pool.buffer.asUint8List().setRange(0, pool.length * 2, bytes, poolStart);
    String? str(int base, int field) {
      final int length = data.getInt32(base + (field + 1) * 4, Endian.host);
      if (length < 0) return null;
      final int offset = data.getInt32(base + field * 4, Endian.host);
      return String.fromCharCodes(pool, offset, offset + length);
    }

    int? num(int base, int field) {
      final int value = data.getInt32(base + field * 4, Endian.host);
      return value < 0 ? null : value;
    }

    return List<FfcParsedName>.generate(n, (int i) {
      final int base = 4 + i * recordInts * 4;
      return FfcParsedName(
        inputIndex: data.getInt32(base, Endian.host),
        title: str(base, 1)!,
        secondaryTitle: str(base, 3),
        titleWithTrailingYear: str(base, 5),
        releaseGroup: str(base, 7),
        resolution: str(base, 9),
        episode: num(base, 11),
        season: num(base, 12),
        year: num(base, 13),
        isMovieHint: data.getInt32(base + 14 * 4, Endian.host) & 1 == 1,
      );
    }, growable: false);
  }
}
