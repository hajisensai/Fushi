import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../fushi_compute_library.dart';

typedef _SummarizeC = Int32 Function(Pointer<Uint16>, Size, Pointer<Int64>);
typedef _SummarizeDart = int Function(Pointer<Uint16>, int, Pointer<Int64>);

/// 字幕时间跨度扫描（srt / vtt 的 `起 --> 止`，没有再扫 ass/ssa 的 `Dialogue:`）的原生
/// 实现（`native/fushi_compute/src/parse/subtitle_timing.rs` 的
/// `ffc_parse_subtiming_summarize`）。唯一实现、没有 Dart 回退。
final class SubtitleTimingNative {
  SubtitleTimingNative._(this._summarize) : _out = calloc<Int64>(3);

  final _SummarizeDart _summarize;
  final Pointer<Int64> _out;
  Pointer<Uint16> _buffer = nullptr;
  int _capacity = 0;

  static SubtitleTimingNative? _instance;

  /// 本 isolate 的实例（首次访问时加载并 lookup 符号）。
  static SubtitleTimingNative get instance => _instance ??= _load();

  static SubtitleTimingNative _load() {
    final FushiCompute compute = FushiCompute.require();
    try {
      return SubtitleTimingNative._(
        compute.library.lookupFunction<_SummarizeC, _SummarizeDart>(
          'ffc_parse_subtiming_summarize',
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  /// 扫 [content]：`cueCount` 为 0 时另两项为 0。
  ({int cueCount, int firstStartMs, int lastEndMs}) summarize(String content) {
    final int length = content.length;
    if (length > _capacity) {
      if (_buffer != nullptr) calloc.free(_buffer);
      int capacity = _capacity == 0 ? 4096 : _capacity;
      while (capacity < length) {
        capacity *= 2;
      }
      _buffer = calloc<Uint16>(capacity);
      _capacity = capacity;
    }
    if (length > 0) {
      final Uint16List units = _buffer.asTypedList(length);
      for (int i = 0; i < length; i++) {
        units[i] = content.codeUnitAt(i);
      }
    }
    final int status = _summarize(_buffer, length, _out);
    if (status != FfcStatus.ok) {
      throw StateError(
        'ffc_parse_subtiming_summarize failed with status $status',
      );
    }
    return (cueCount: _out[0], firstStartMs: _out[1], lastEndMs: _out[2]);
  }
}
