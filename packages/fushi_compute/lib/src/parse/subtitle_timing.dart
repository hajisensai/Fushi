import 'dart:ffi';
import 'dart:typed_data';

import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _SummarizeC = Int32 Function(Pointer<Uint16>, Size, Pointer<Int64>);
typedef _SummarizeDart = int Function(Pointer<Uint16>, int, Pointer<Int64>);

/// 字幕时间跨度扫描（srt / vtt 的 `起 --> 止`，没有再扫 ass/ssa 的 `Dialogue:`）的原生
/// 实现（`native/fushi_compute/src/parse/subtitle_timing.rs` 的
/// `ffc_parse_subtiming_summarize`）。唯一实现、没有 Dart 回退。
///
/// 暂存区与输出槽由 [NativeScratch] 持有，isolate 退出时释放。
final class SubtitleTimingNative implements Finalizable {
  SubtitleTimingNative._(this._summarize);

  final _SummarizeDart _summarize;

  /// 输出槽：3 × i64。
  final NativeScratch _out = NativeScratch.fixed(24);
  final NativeScratch _buffer = NativeScratch(minCapacity: 8192);

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
    final Pointer<Uint16> buffer = _buffer.reserve(length * 2).cast<Uint16>();
    if (length > 0) {
      final Uint16List units = buffer.asTypedListOutOfLine(length);
      for (int i = 0; i < length; i++) {
        units[i] = content.codeUnitAt(i);
      }
    }
    final Pointer<Int64> out = _out.pointer.cast<Int64>();
    final int status = _summarize(buffer, length, out);
    if (status != FfcStatus.ok) {
      throw StateError(
        'ffc_parse_subtiming_summarize failed with status $status',
      );
    }
    return (cueCount: out[0], firstStartMs: out[1], lastEndMs: out[2]);
  }
}
