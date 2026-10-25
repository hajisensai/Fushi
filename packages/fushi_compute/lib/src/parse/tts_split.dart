import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';

typedef _SplitC =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Int64>,
      Size,
      Pointer<Uint16>,
      Size,
      Pointer<Int64>,
      Size,
      Int64,
      Pointer<Int32>,
      Size,
      Pointer<Uint16>,
      Size,
      Pointer<Size>,
      Pointer<Size>,
    );
typedef _SplitDart =
    int Function(
      Pointer<Uint16>,
      int,
      Pointer<Int64>,
      int,
      Pointer<Uint16>,
      int,
      Pointer<Int64>,
      int,
      int,
      Pointer<Int32>,
      int,
      Pointer<Uint16>,
      int,
      Pointer<Size>,
      Pointer<Size>,
    );

/// 一处 ruby 底本区间（[text] 的 UTF-16 码元）与读音。
typedef TtsSplitRuby = ({int start, int end, String reading});

/// 一句：章内原文 UTF-16 区间、显示原文与送去合成的文本（ruby 底本换成读音）。
final class TtsSplitSegment {
  const TtsSplitSegment({
    required this.start,
    required this.end,
    required this.text,
    required this.spokenText,
  });

  final int start;
  final int end;
  final String text;
  final String spokenText;
}

/// 长度 0 也分配 1 个元素：asTypedList 不收 nullptr。
int _atLeastOne(int count) => count < 1 ? 1 : count;

/// TTS 整章切句的原生实现（`native/fushi_compute/src/parse/tts_split.rs` 的
/// `ffc_parse_tts_split_utf16`）。规则见那里的模块注释。
///
/// 这是切句**唯一**的运行时实现：没有 Dart 回退。原生库或符号缺失时 [instance]
/// 抛 [FushiComputeUnavailableError]。
///
/// 原生缓冲区每次调用现分配（一整块）、返回前释放：整书计划跑在一次性的后台 isolate 里，
/// 挂在 isolate 静态字段上的暂存区随 isolate 退出就泄漏了（原生内存不归 GC 管）。
final class TtsSplitNative {
  TtsSplitNative._(this._split);

  final _SplitDart _split;

  static TtsSplitNative? _instance;

  /// 本 isolate 的实例（首次访问时加载并 lookup 符号）。
  static TtsSplitNative get instance => _instance ??= _load();

  static TtsSplitNative _load() {
    final FushiCompute compute = FushiCompute.require();
    // lookup 名写成字符串字面量：verify_abi.sh 从绑定源码抓期望符号集。
    try {
      return TtsSplitNative._(
        compute.library.lookupFunction<_SplitC, _SplitDart>(
          'ffc_parse_tts_split_utf16',
          isLeaf: true,
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  /// 切一章 [text]：[rubies] 按出现顺序；[blockEnds] / [sceneBreaks] 是硬句界；
  /// 单句合成文本不超过 [maxLength]（UTF-16 码元，至少 8）。
  List<TtsSplitSegment> split(
    String text, {
    required List<TtsSplitRuby> rubies,
    required List<int> blockEnds,
    required List<int> sceneBreaks,
    required int maxLength,
  }) {
    if (maxLength < 8) throw ArgumentError.value(maxLength, 'maxLength');
    final int length = text.length;
    int readingsLength = 0;
    for (final TtsSplitRuby ruby in rubies) {
      readingsLength += ruby.reading.length;
    }
    final int breakCount = blockEnds.length + sceneBreaks.length;
    // 句数不超过原子数（≤ 码元数），池不超过原文 + 全部读音：这个容量一次就够。
    final int recordCapacity = length;
    final int poolCapacity = length + readingsLength;

    // 全部输入 / 输出区一次分配、按偏移切开（短章逐次调用时，8 次 malloc + 8 次 free
    // 比旧 Dart 整次切句还贵）。8 字节字段排在前、4 字节记录其次、UTF-16 区在后，
    // 各区自然对齐；每区至少 1 个元素（asTypedList 不收 nullptr）。
    final int rubyAt = 0;
    final int breakAt = rubyAt + _atLeastOne(rubies.length * 4) * 8;
    final int countAt = breakAt + _atLeastOne(breakCount) * 8;
    final int poolLengthAt = countAt + 8;
    final int recordAt = poolLengthAt + 8;
    final int textAt = recordAt + _atLeastOne(recordCapacity * 4) * 4;
    final int readingAt = textAt + _atLeastOne(length) * 2;
    final int poolAt = readingAt + _atLeastOne(readingsLength) * 2;
    final int totalBytes = poolAt + _atLeastOne(poolCapacity) * 2;
    final Pointer<Uint8> block = malloc<Uint8>(totalBytes);
    try {
      final Pointer<Int64> rubyPtr = (block + rubyAt).cast<Int64>();
      final Pointer<Int64> breakPtr = (block + breakAt).cast<Int64>();
      final Pointer<Size> countPtr = (block + countAt).cast<Size>();
      final Pointer<Size> poolLengthPtr = (block + poolLengthAt).cast<Size>();
      final Pointer<Int32> recordPtr = (block + recordAt).cast<Int32>();
      final Pointer<Uint16> textPtr = (block + textAt).cast<Uint16>();
      final Pointer<Uint16> readingPtr = (block + readingAt).cast<Uint16>();
      final Pointer<Uint16> poolPtr = (block + poolAt).cast<Uint16>();

      final Uint16List textUnits = textPtr.asTypedListOutOfLine(length);
      for (int i = 0; i < length; i++) {
        textUnits[i] = text.codeUnitAt(i);
      }
      final Int64List rubyFields = rubyPtr.asTypedListOutOfLine(
        rubies.length * 4,
      );
      final Uint16List readingUnits = readingPtr.asTypedListOutOfLine(
        readingsLength,
      );
      int readingCursor = 0;
      for (int k = 0; k < rubies.length; k++) {
        final TtsSplitRuby ruby = rubies[k];
        final String reading = ruby.reading;
        rubyFields[k * 4] = ruby.start;
        rubyFields[k * 4 + 1] = ruby.end;
        rubyFields[k * 4 + 2] = readingCursor;
        rubyFields[k * 4 + 3] = reading.length;
        for (int i = 0; i < reading.length; i++) {
          readingUnits[readingCursor++] = reading.codeUnitAt(i);
        }
      }
      final Int64List breakValues = breakPtr.asTypedListOutOfLine(breakCount);
      breakValues.setAll(0, blockEnds);
      breakValues.setAll(blockEnds.length, sceneBreaks);

      final int status = _split(
        textPtr,
        length,
        rubyPtr,
        rubies.length,
        readingPtr,
        readingsLength,
        breakPtr,
        breakCount,
        maxLength,
        recordPtr,
        recordCapacity,
        poolPtr,
        poolCapacity,
        countPtr,
        poolLengthPtr,
      );
      if (status != FfcStatus.ok) {
        throw StateError(
          'ffc_parse_tts_split_utf16 failed with status $status',
        );
      }
      final int count = countPtr.value;
      final Int32List records = recordPtr.asTypedListOutOfLine(count * 4);
      final Uint16List pool = poolPtr.asTypedListOutOfLine(poolLengthPtr.value);
      return List<TtsSplitSegment>.generate(count, (int k) {
        final int start = records[k * 4];
        final int end = records[k * 4 + 1];
        final String original = text.substring(start, end);
        final int spokenOffset = records[k * 4 + 2];
        final int spokenLength = records[k * 4 + 3];
        return TtsSplitSegment(
          start: start,
          end: end,
          text: original,
          spokenText: spokenLength < 0
              ? original
              : String.fromCharCodes(
                  pool,
                  spokenOffset,
                  spokenOffset + spokenLength,
                ),
        );
      }, growable: false);
    } finally {
      malloc.free(block);
    }
  }
}
