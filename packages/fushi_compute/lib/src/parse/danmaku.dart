// 弹幕 sidecar 解析的原生绑定（ffc_parse_danmaku_*）。
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';

/// 一次弹幕解析的结局（与 `native/fushi_compute/src/parse/danmaku.rs` 的 `OUTCOME_*` 一致）。
enum DanmakuParseOutcome {
  /// 解析成功（可能 0 条）。
  ok,

  /// XML 语法 / 结构校验失败，或 JSON 语法错误（见 [DanmakuParseResult.formatException]）。
  syntaxError,

  /// JSON 根不是对象，或 `comments` 不是数组。
  shapeError,

  /// 某个参与取整的数是 NaN / ±Infinity（旧 Dart 实现在这里抛
  /// `UnsupportedError('Infinity or NaN toInt')`，整份作废）。
  nonFiniteNumber,
}

/// 弹幕显示方式编号，等于 fushi `VideoDanmakuMode` 的 index。
abstract final class DanmakuModeIndex {
  static const int scroll = 0;
  static const int top = 1;
  static const int bottom = 2;
}

/// 用一条解析结果构造调用方自己的弹幕对象（免一层中间对象）。
typedef DanmakuItemBuilder<T> =
    T Function(int startMs, String text, int mode, int colorArgb);

final class DanmakuParseResult<T> {
  const DanmakuParseResult(this.outcome, this.items, [this.formatException]);

  final DanmakuParseOutcome outcome;

  /// 已按 `startMs` 排序（Dart `List.sort` 同一算法，同毫秒的先后与旧实现一致）。
  /// 非 [DanmakuParseOutcome.ok] 时为空。
  final List<T> items;

  /// JSON 语法错误时与 `jsonDecode` 抛出的完全相同的 [FormatException]
  /// （文案、源串、偏移）；其余情况为 null。
  final FormatException? formatException;
}

typedef _XmlC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _XmlDart =
    int Function(Pointer<Uint16>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _JsonC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Int64,
      Uint8,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _JsonDart =
    int Function(
      Pointer<Uint16>,
      int,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

/// `jsonDecode` 的 `FormatException` 文案，下标即原生错误码。
const List<String> _jsonErrorMessages = <String>[
  '',
  'Unexpected character',
  'Unexpected end of input',
  'Unterminated string',
  'Control character in string',
  'Missing expected digit',
  'Invalid unicode escape',
  'Unrecognized string escape',
  'Unterminated number literal',
];

const int _headerWords = 6;
const int _recordWords = 4;

/// Bilibili XML / 弹弹play JSON 弹幕解析的原生实现（`ffc_parse_danmaku_*`）。
///
/// 这是弹幕解析**唯一**的运行时实现：没有 Dart 回退。原生库或符号缺失时 [instance]
/// 抛 [FushiComputeUnavailableError]。结果与旧 Dart 实现（`package:xml` / `jsonDecode`
/// + 逐条转换 + `List.sort`）逐条、逐字段一致，见
/// `packages/fushi_compute/test/danmaku_parity_test.dart`。
final class DanmakuNative {
  DanmakuNative._(this._compute, this._xml, this._json);

  final FushiCompute _compute;
  final _XmlDart _xml;
  final _JsonDart _json;

  static DanmakuNative? _instance;

  /// 本 isolate 的实例（首次访问时加载并 lookup 符号）。
  static DanmakuNative get instance => _instance ??= _load();

  static DanmakuNative _load() {
    final FushiCompute compute = FushiCompute.require();
    // lookup 名写成字符串字面量：verify_abi.sh 从绑定源码抓期望符号集。
    try {
      return DanmakuNative._(
        compute,
        compute.library.lookupFunction<_XmlC, _XmlDart>(
          'ffc_parse_danmaku_bilibili_xml',
        ),
        compute.library.lookupFunction<_JsonC, _JsonDart>(
          'ffc_parse_danmaku_dandanplay_json',
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  /// 旧 `parseBilibiliDanmakuXml` 的解析：`XmlDocument.parse` → 每个 `<d>` 的
  /// `p` 属性（时间,模式,字号,颜色,…）与 `innerText.trim()`。
  DanmakuParseResult<T> parseBilibiliXml<T>(
    String xml,
    DanmakuItemBuilder<T> build,
  ) {
    return _run(
      xml,
      build,
      (
        Pointer<Uint16> units,
        int length,
        Pointer<Pointer<Uint8>> out,
        Pointer<Size> outLength,
      ) => _xml(units, length, out, outLength),
    );
  }

  /// 旧 `jsonDecode` + 形状校验 + `dandanplayCommentsToDanmaku` 的解析。
  ///
  /// 时间偏移二选一：[shiftMs] 直接加到每条上；[shiftSeconds] 按旧在线路径的
  /// `(shiftSeconds * 1000).round()` 换算——它不是有限数时，形状校验通过后结局为
  /// [DanmakuParseOutcome.nonFiniteNumber]（旧实现在同一时序点抛异常）。
  DanmakuParseResult<T> parseDandanplayJson<T>(
    String json,
    DanmakuItemBuilder<T> build, {
    int shiftMs = 0,
    double? shiftSeconds,
  }) {
    int shift = shiftMs;
    int shiftNonFinite = 0;
    if (shiftSeconds != null) {
      if (shiftMs != 0) {
        throw ArgumentError('pass either shiftMs or shiftSeconds, not both');
      }
      final double scaled = shiftSeconds * 1000;
      if (scaled.isFinite) {
        shift = scaled.round();
      } else {
        shiftNonFinite = 1;
      }
    }
    return _run(
      json,
      build,
      (
        Pointer<Uint16> units,
        int length,
        Pointer<Pointer<Uint8>> out,
        Pointer<Size> outLength,
      ) => _json(units, length, shift, shiftNonFinite, out, outLength),
    );
  }

  DanmakuParseResult<T> _run<T>(
    String source,
    DanmakuItemBuilder<T> build,
    int Function(Pointer<Uint16>, int, Pointer<Pointer<Uint8>>, Pointer<Size>)
    call,
  ) {
    final int length = source.length;
    final Pointer<Uint16> input = length == 0
        ? nullptr
        : malloc<Uint16>(length);
    final Pointer<Pointer<Uint8>> outPtr = calloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = calloc<Size>();
    try {
      if (length > 0) {
        final Uint16List units = input.asTypedListOutOfLine(length);
        for (int i = 0; i < length; i++) {
          units[i] = source.codeUnitAt(i);
        }
      }
      final int status = call(input, length, outPtr, outLen);
      if (status != FfcStatus.ok) {
        throw StateError('ffc_parse_danmaku_* failed with status $status');
      }
      final Pointer<Uint8> out = outPtr.value;
      final int outLength = outLen.value;
      try {
        return _decode(out, outLength, source, build);
      } finally {
        _compute.freeBytes(out, outLength);
      }
    } finally {
      if (input != nullptr) malloc.free(input);
      calloc.free(outPtr);
      calloc.free(outLen);
    }
  }

  static DanmakuParseResult<T> _decode<T>(
    Pointer<Uint8> out,
    int outLength,
    String source,
    DanmakuItemBuilder<T> build,
  ) {
    // 缓冲区来自 Rust 的 malloc（对齐 ≥ 8），按 u32 / u16 视图读。
    if (out.address % 4 != 0 || outLength < _headerWords * 4) {
      throw StateError('ffc_parse_danmaku_* returned a malformed buffer');
    }
    final Uint32List header = out.cast<Uint32>().asTypedListOutOfLine(
      _headerWords,
    );
    final int outcome = header[0];
    final int count = header[3];
    final int poolLength = header[4];
    final int recordEnd = _headerWords + _recordWords * count;
    if (outLength != recordEnd * 4 + poolLength * 2 ||
        outcome >= DanmakuParseOutcome.values.length) {
      throw StateError('ffc_parse_danmaku_* returned a malformed buffer');
    }
    if (outcome != 0) {
      FormatException? formatException;
      final int errorCode = header[1];
      if (outcome == 1 &&
          errorCode > 0 &&
          errorCode < _jsonErrorMessages.length) {
        formatException = FormatException(
          _jsonErrorMessages[errorCode],
          source,
          header[2],
        );
      }
      return DanmakuParseResult<T>(
        DanmakuParseOutcome.values[outcome],
        <T>[],
        formatException,
      );
    }
    final Uint32List words = out.cast<Uint32>().asTypedListOutOfLine(recordEnd);
    final Uint16List pool = out.cast<Uint16>().asTypedListOutOfLine(
      recordEnd * 2 + poolLength,
    );
    final List<T> items = <T>[];
    int textStart = recordEnd * 2;
    for (int i = 0; i < count; i++) {
      final int base = _headerWords + _recordWords * i;
      final int textEnd = textStart + words[base + 3];
      items.add(
        build(
          words[base],
          String.fromCharCodes(pool, textStart, textEnd),
          words[base + 2],
          words[base + 1],
        ),
      );
      textStart = textEnd;
    }
    return DanmakuParseResult<T>(DanmakuParseOutcome.ok, items);
  }
}
