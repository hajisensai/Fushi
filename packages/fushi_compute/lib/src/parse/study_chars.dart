import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../fushi_compute_library.dart';

typedef _ClassOfC = Uint8 Function(Uint32);
typedef _ClassOfDart = int Function(int);
typedef _CountUtf16C =
    Int32 Function(Pointer<Uint16>, Size, Pointer<Uint64>, Pointer<Uint8>);
typedef _CountUtf16Dart =
    int Function(Pointer<Uint16>, int, Pointer<Uint64>, Pointer<Uint8>);

/// 学习统计「字数」口径的原生实现（`native/fushi_compute/src/parse.rs` 的
/// `ffc_parse_study_char_class` / `ffc_parse_study_chars_utf16`）。
///
/// 这是该口径**唯一**的运行时实现：没有 Dart 回退。原生库或符号缺失时 [instance]
/// 抛 [FushiComputeUnavailableError]（说明缺什么、怎么指定库），不返回 null、不静默算出别的数。
///
/// 每个 isolate 各持一份实例与一块复用的原生暂存区（随 isolate 生命周期，不释放）。
final class StudyCharsNative {
  StudyCharsNative._(this._classOf, this._countUtf16)
    : _count = calloc<Uint64>(),
      _inWord = calloc<Uint8>();

  final _ClassOfDart _classOf;
  final _CountUtf16Dart _countUtf16;
  final Pointer<Uint64> _count;
  final Pointer<Uint8> _inWord;
  Pointer<Uint16> _buffer = nullptr;
  int _capacity = 0;

  static StudyCharsNative? _instance;

  /// 本 isolate 的实例（首次访问时加载并 lookup 符号）。
  static StudyCharsNative get instance => _instance ??= _load();

  static StudyCharsNative _load() {
    final FushiCompute? lib = FushiCompute.instance;
    if (lib == null) {
      throw FushiComputeUnavailableError(
        'fushi_compute native library is not available '
        '(${FushiCompute.defaultLibraryName()}); set $kFushiComputeLibEnv '
        'to its path or ship it next to the executable',
      );
    }
    const String classSymbol = 'ffc_parse_study_char_class';
    const String countSymbol = 'ffc_parse_study_chars_utf16';
    for (final String symbol in <String>[classSymbol, countSymbol]) {
      if (!lib.providesSymbol(symbol)) {
        throw FushiComputeUnavailableError(
          'fushi_compute at ${lib.libraryPath} does not export $symbol '
          '(library is older than this build)',
        );
      }
    }
    return StudyCharsNative._(
      lib.library.lookupFunction<_ClassOfC, _ClassOfDart>(
        classSymbol,
        isLeaf: true,
      ),
      lib.library.lookupFunction<_CountUtf16C, _CountUtf16Dart>(
        countSymbol,
        isLeaf: true,
      ),
    );
  }

  /// 码点 [codePoint] 的分类：0 断词不计 / 1 透明 / 2 每码点计 1 / 3 连续串计 1。
  int classOf(int codePoint) {
    if (codePoint < 0 || codePoint > 0x10FFFF) return 0;
    return _classOf(codePoint);
  }

  /// 从 ([count], [inWord]) 状态接着数 [text]，返回新状态。语义见
  /// `StudyCharCounter`（packages/fushi_engine/lib/stats/study_char_count.dart）。
  ({int count, bool inWord}) add(String text, int count, bool inWord) {
    final int length = text.length;
    if (length == 0) return (count: count, inWord: inWord);
    if (length > _capacity) {
      if (_buffer != nullptr) calloc.free(_buffer);
      int capacity = _capacity == 0 ? 1024 : _capacity;
      while (capacity < length) {
        capacity *= 2;
      }
      _buffer = calloc<Uint16>(capacity);
      _capacity = capacity;
    }
    final Uint16List units = _buffer.asTypedList(length);
    for (int i = 0; i < length; i++) {
      units[i] = text.codeUnitAt(i);
    }
    _count.value = count;
    _inWord.value = inWord ? 1 : 0;
    final int status = _countUtf16(_buffer, length, _count, _inWord);
    if (status != FfcStatus.ok) {
      throw StateError(
        'ffc_parse_study_chars_utf16 failed with status $status',
      );
    }
    return (count: _count.value, inWord: _inWord.value != 0);
  }
}
