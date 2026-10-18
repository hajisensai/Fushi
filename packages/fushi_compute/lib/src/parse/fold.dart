import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../fushi_compute_library.dart';

typedef _FoldUtf16C =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Uint16>,
      Pointer<Uint32>,
      Size,
      Pointer<Size>,
    );
typedef _FoldUtf16Dart =
    int Function(
      Pointer<Uint16>,
      int,
      Pointer<Uint16>,
      Pointer<Uint32>,
      int,
      Pointer<Size>,
    );

/// 有声书 / 阅读器匹配坐标系的日文正文归一化（`native/fushi_compute/src/parse/fold.rs`
/// 的 `ffc_parse_fold_audio_utf16`）：白名单外码点丢弃，全角字母数字→半角、大写→小写、
/// 半角片假名→全角、片假名→平假名。上层语义入口是 fushi_audio 的 `AudioTextNormalizer`。
///
/// 这是该口径**唯一**的 Dart 侧运行时实现：没有 Dart 回退。原生库或符号缺失时
/// [instance] 抛 [FushiComputeUnavailableError]。
///
/// 每个 isolate 各持一份实例与一组复用的原生暂存区（随 isolate 生命周期，不释放）。
final class AudioTextFoldNative {
  AudioTextFoldNative._(this._foldUtf16) : _outLen = calloc<Size>();

  final _FoldUtf16Dart _foldUtf16;
  final Pointer<Size> _outLen;
  Pointer<Uint16> _input = nullptr;
  Pointer<Uint16> _output = nullptr;
  Pointer<Uint32> _starts = nullptr;
  int _capacity = 0;

  static AudioTextFoldNative? _instance;

  /// 本 isolate 的实例（首次访问时加载并 lookup 符号）。
  static AudioTextFoldNative get instance => _instance ??= _load();

  static AudioTextFoldNative _load() {
    final FushiCompute compute = FushiCompute.require();
    // lookup 名写成字符串字面量：verify_abi.sh 从绑定源码抓期望符号集。
    try {
      return AudioTextFoldNative._(
        compute.library.lookupFunction<_FoldUtf16C, _FoldUtf16Dart>(
          'ffc_parse_fold_audio_utf16',
          isLeaf: true,
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  void _ensureCapacity(int length) {
    if (length <= _capacity) return;
    if (_capacity > 0) {
      calloc
        ..free(_input)
        ..free(_output)
        ..free(_starts);
    }
    int capacity = _capacity == 0 ? 1024 : _capacity;
    while (capacity < length) {
      capacity *= 2;
    }
    _input = calloc<Uint16>(capacity);
    _output = calloc<Uint16>(capacity);
    _starts = calloc<Uint32>(capacity);
    _capacity = capacity;
  }

  int _run(String text, {required bool withStarts}) {
    final int length = text.length;
    _ensureCapacity(length);
    final Uint16List units = _input.asTypedList(length);
    for (int i = 0; i < length; i++) {
      units[i] = text.codeUnitAt(i);
    }
    final int status = _foldUtf16(
      _input,
      length,
      _output,
      withStarts ? _starts : nullptr,
      _capacity,
      _outLen,
    );
    if (status != FfcStatus.ok) {
      throw StateError('ffc_parse_fold_audio_utf16 failed with status $status');
    }
    return _outLen.value;
  }

  /// [text] 的归一化文本。
  String fold(String text) {
    if (text.isEmpty) return '';
    final int n = _run(text, withStarts: false);
    if (n == 0) return '';
    return String.fromCharCodes(_output.asTypedList(n));
  }

  /// [text] 的归一化文本，以及每个输出 UTF-16 码元对应**输入码点起始码元下标**
  /// （补充平面码点的两个输出码元同一个下标；被保留码点的输出宽度等于输入宽度）。
  /// 返回的 [Uint32List] 是拷贝，不随下次调用改变。
  ({String text, Uint32List starts}) foldWithStarts(String text) {
    if (text.isEmpty) return (text: '', starts: Uint32List(0));
    final int n = _run(text, withStarts: true);
    if (n == 0) return (text: '', starts: Uint32List(0));
    return (
      text: String.fromCharCodes(_output.asTypedList(n)),
      starts: Uint32List.fromList(_starts.asTypedList(n)),
    );
  }
}
