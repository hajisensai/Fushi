import 'dart:ffi';
import 'dart:typed_data';

import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _ParseC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ParseDart =
    int Function(Pointer<Uint16>, int, Pointer<Pointer<Uint8>>, Pointer<Size>);
typedef _StripBatchC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Uint32>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _StripBatchDart =
    int Function(
      Pointer<Uint16>,
      int,
      Pointer<Uint32>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ParseAssC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Uint8,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ParseAssDart =
    int Function(
      Pointer<Uint16>,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ParseMarkupC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Uint32,
      Double,
      Double,
      Int64,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ParseMarkupDart =
    int Function(
      Pointer<Uint16>,
      int,
      int,
      double,
      double,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

/// 字幕解析的原生实现（`native/fushi_compute/src/parse/subtitle.rs` 的
/// `ffc_parse_subtitle_*`）：SRT / WebVTT / ASS 全文、单条 cue 的行内 markup、HTML / VTT
/// 行内标签剥离。
///
/// 这是这些解析的**唯一**运行时实现：没有 Dart 回退。原生库或符号缺失时 [instance] 抛
/// [FushiComputeUnavailableError]。本类只负责把 Dart String 的 UTF-16 码元送进原生内存、
/// 拿回结果字节块（[SubtitleNativeResult]）；把结果解码成 `AudioCue` / `SubtitleMarkup`
/// 的是 packages/fushi_audio（本包不依赖它）。
///
/// 每个 isolate 各持一份实例与一块复用的输入暂存区（[NativeScratch]，isolate 退出时释放）。
final class SubtitleParseNative implements Finalizable {
  SubtitleParseNative._(
    this._compute,
    this._srt,
    this._vtt,
    this._ass,
    this._markup,
    this._strip,
    this._stripBatch,
  );

  final FushiCompute _compute;
  final _ParseDart _srt;
  final _ParseDart _vtt;
  final _ParseAssDart _ass;
  final _ParseMarkupDart _markup;
  final _ParseDart _strip;
  final _StripBatchDart _stripBatch;

  /// 固定输出槽：outPtr（指针）+ outLen（size_t）。
  final NativeScratch _slots = NativeScratch.fixed(16);
  Pointer<Pointer<Uint8>> get _outPtr => _slots.pointer.cast<Pointer<Uint8>>();
  Pointer<Size> get _outLen => (_slots.pointer + 8).cast<Size>();

  final NativeScratch _buffer = NativeScratch(minCapacity: 2048);

  /// [stripHtmlTagsBatch] 的各条结束下标（u32）。
  final NativeScratch _ends = NativeScratch(minCapacity: 1024);

  /// 暂存区超过这么多码元时用完即释放（大文件只在后台 isolate 里解析一次）。
  static const int _retainCapacity = 1 << 16;

  static SubtitleParseNative? _instance;

  /// 本 isolate 的实例（首次访问时加载并 lookup 符号）。
  static SubtitleParseNative get instance => _instance ??= _load();

  static SubtitleParseNative _load() {
    final FushiCompute compute = FushiCompute.require();
    // lookup 名写成字符串字面量：verify_abi.sh 从绑定源码抓期望符号集。
    try {
      return SubtitleParseNative._(
        compute,
        compute.library.lookupFunction<_ParseC, _ParseDart>(
          'ffc_parse_subtitle_srt',
        ),
        compute.library.lookupFunction<_ParseC, _ParseDart>(
          'ffc_parse_subtitle_vtt',
        ),
        compute.library.lookupFunction<_ParseAssC, _ParseAssDart>(
          'ffc_parse_subtitle_ass',
        ),
        compute.library.lookupFunction<_ParseMarkupC, _ParseMarkupDart>(
          'ffc_parse_subtitle_markup',
        ),
        compute.library.lookupFunction<_ParseC, _ParseDart>(
          'ffc_parse_subtitle_strip_html_tags',
          isLeaf: true,
        ),
        compute.library.lookupFunction<_StripBatchC, _StripBatchDart>(
          'ffc_parse_subtitle_strip_html_tags_batch',
          isLeaf: true,
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  /// SRT 全文。结果数据区：cue 列表（见 subtitle.rs `write_cues`，无 ASS 字段）。
  SubtitleNativeResult parseSrt(String content) => _call(
    content,
    (Pointer<Uint16> p, int n) => _srt(p, n, _outPtr, _outLen),
  );

  /// WebVTT 全文。数据区同 [parseSrt]。
  SubtitleNativeResult parseVtt(String content) => _call(
    content,
    (Pointer<Uint16> p, int n) => _vtt(p, n, _outPtr, _outLen),
  );

  /// ASS / SSA 全文。数据区：u32 丢弃条数、样式表、cue 列表（带 ASS 字段）。
  SubtitleNativeResult parseAss(
    String content, {
    bool includeDrawings = false,
  }) => _call(
    content,
    (Pointer<Uint16> p, int n) =>
        _ass(p, n, includeDrawings ? 1 : 0, _outPtr, _outLen),
  );

  /// 单条 cue 原文的 markup。数据区：一条 markup 记录。
  SubtitleNativeResult parseMarkup(
    String raw, {
    double? playResX,
    double? playResY,
    int layer = 0,
  }) {
    final int flags = (playResX != null ? 1 : 0) | (playResY != null ? 2 : 0);
    return _call(
      raw,
      (Pointer<Uint16> p, int n) => _markup(
        p,
        n,
        flags,
        playResX ?? 0,
        playResY ?? 0,
        layer,
        _outPtr,
        _outLen,
      ),
    );
  }

  /// 剥离行内 `<...>` 标签（注音 `<rt>` / `<rp>` / `<rtc>` 连内容一起删）并 `trim()`。
  String stripHtmlTags(String text) {
    final SubtitleNativeResult result = _call(
      text,
      (Pointer<Uint16> p, int n) => _strip(p, n, _outPtr, _outLen),
    );
    try {
      return result.reader().string();
    } finally {
      result.free();
    }
  }

  /// 批量 [stripHtmlTags]：第 i 项逐字等于 `stripHtmlTags(texts[i])`。整批首尾相接拷进一块
  /// 原生内存、附各条结束下标，一次 FFI（`ffc_parse_subtitle_strip_html_tags_batch`，循环在
  /// Rust；标签不会跨条匹配）。增强 LRC 整份的行一次交过去，不逐行跨边界。
  List<String> stripHtmlTagsBatch(List<String> texts) {
    final int count = texts.length;
    if (count == 0) return <String>[];
    int length = 0;
    for (final String text in texts) {
      length += text.length;
    }
    final Pointer<Uint16> buffer = _buffer.reserve(length * 2).cast<Uint16>();
    final Pointer<Uint32> ends = _ends.reserve(count * 4).cast<Uint32>();
    final Uint16List units = buffer.asTypedListOutOfLine(length);
    final Uint32List endView = ends.asTypedListOutOfLine(count);
    int at = 0;
    for (int k = 0; k < count; k++) {
      final String text = texts[k];
      for (int i = 0; i < text.length; i++) {
        units[at + i] = text.codeUnitAt(i);
      }
      at += text.length;
      endView[k] = at;
    }
    final int status = _stripBatch(
      buffer,
      length,
      ends,
      count,
      _outPtr,
      _outLen,
    );
    if (_buffer.capacity > _retainCapacity * 2) _buffer.release();
    if (_ends.capacity > _retainCapacity * 2) _ends.release();
    if (status != FfcStatus.ok) {
      throw StateError('ffc_parse_subtitle_* failed with status $status');
    }
    final SubtitleNativeResult result = SubtitleNativeResult._(
      _compute,
      _outPtr.value,
      _outLen.value,
    );
    try {
      final SubtitleNativeReader reader = result.reader();
      return <String>[for (int k = 0; k < count; k++) reader.string()];
    } finally {
      result.free();
    }
  }

  SubtitleNativeResult _call(
    String text,
    int Function(Pointer<Uint16> units, int length) invoke,
  ) {
    final int length = text.length;
    final Pointer<Uint16> buffer = _buffer.reserve(length * 2).cast<Uint16>();
    if (length > 0) {
      final Uint16List units = buffer.asTypedListOutOfLine(length);
      for (int i = 0; i < length; i++) {
        units[i] = text.codeUnitAt(i);
      }
    }
    final int status = invoke(buffer, length);
    if (_buffer.capacity > _retainCapacity * 2) _buffer.release();
    if (status != FfcStatus.ok) {
      throw StateError('ffc_parse_subtitle_* failed with status $status');
    }
    return SubtitleNativeResult._(_compute, _outPtr.value, _outLen.value);
  }
}

/// 一次原生解析交出的结果字节块（布局见 subtitle.rs 文件头）。用完必须 [free]。
final class SubtitleNativeResult {
  SubtitleNativeResult._(this._compute, this._ptr, this._length) {
    final Uint8List all = _ptr.asTypedListOutOfLine(_length);
    final ByteData header = all.buffer.asByteData(all.offsetInBytes, 16);
    kind = header.getUint32(0, Endian.little);
    final int dataLength = header.getUint32(4, Endian.little);
    final int poolUnits = header.getUint32(8, Endian.little);
    _data = all.buffer.asByteData(all.offsetInBytes + 16, dataLength);
    final int poolOffset = 16 + ((dataLength + 7) ~/ 8) * 8;
    if ((_ptr.address + poolOffset) % 2 != 0) {
      throw StateError('fushi_compute returned a misaligned string pool');
    }
    _pool = Pointer<Uint16>.fromAddress(
      _ptr.address + poolOffset,
    ).asTypedListOutOfLine(poolUnits);
  }

  final FushiCompute _compute;
  final Pointer<Uint8> _ptr;
  final int _length;
  late final ByteData _data;
  late final Uint16List _pool;
  bool _freed = false;

  /// 0 = 成功；1..3 = 旧 Dart 实现在这里会抛出的异常（见 [throwIfError]）。
  late final int kind;

  /// 数据区的顺序读取器（从头开始）。
  SubtitleNativeReader reader() => SubtitleNativeReader._(_data, _pool);

  /// 结果是异常时释放并按原类型抛出：`FormatException` / `UnsupportedError` /
  /// `RangeError.range`（与旧 Dart 实现抛出的类型与消息一致）。
  void throwIfError() {
    if (kind == 0) return;
    final SubtitleNativeReader r = reader();
    final Object error;
    switch (kind) {
      case 1:
        final String message = r.string();
        final String source = r.string();
        error = FormatException(message, source);
      case 2:
        error = UnsupportedError(r.string());
      case 3:
        final int value = r.i64();
        final int start = r.i64();
        final int end = r.i64();
        error = RangeError.range(value, start, end, r.string());
      default:
        error = StateError('unknown fushi_compute subtitle result kind $kind');
    }
    free();
    throw error;
  }

  /// 释放原生结果（之后 [reader] 读到的视图失效）。可重复调用。
  void free() {
    if (_freed) return;
    _freed = true;
    _compute.freeBytes(_ptr, _length);
  }
}

/// [SubtitleNativeResult] 数据区的小端顺序读取器。字符串从池里复制成 Dart String。
final class SubtitleNativeReader {
  SubtitleNativeReader._(this._data, this._pool);

  final ByteData _data;
  final Uint16List _pool;
  int _offset = 0;

  int u8() => _data.getUint8(_offset++);

  int u32() {
    final int v = _data.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  int i32() {
    final int v = _data.getInt32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  int i64() {
    final int v = _data.getInt64(_offset, Endian.little);
    _offset += 8;
    return v;
  }

  double f64() {
    final double v = _data.getFloat64(_offset, Endian.little);
    _offset += 8;
    return v;
  }

  String string() {
    final int start = u32();
    final int length = u32();
    if (length == 0) return '';
    return String.fromCharCodes(
      Uint16List.sublistView(_pool, start, start + length),
    );
  }
}
