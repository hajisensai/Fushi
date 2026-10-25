import 'dart:ffi';
import 'dart:typed_data';

import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

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

typedef _FoldStudyUtf16C =
    Int32 Function(
      Pointer<Uint16>,
      Size,
      Pointer<Uint16>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      Size,
      Pointer<Size>,
      Pointer<Uint32>,
    );
typedef _FoldStudyUtf16Dart =
    int Function(
      Pointer<Uint16>,
      int,
      Pointer<Uint16>,
      Pointer<Uint32>,
      Pointer<Uint32>,
      int,
      Pointer<Size>,
      Pointer<Uint32>,
    );

/// 有声书 / 阅读器匹配坐标系的日文正文归一化（`native/fushi_compute/src/parse/fold.rs`
/// 的 `ffc_parse_fold_audio_utf16`）：白名单外码点丢弃，全角字母数字→半角、大写→小写、
/// 半角片假名→全角、片假名→平假名。上层语义入口是 fushi_audio 的 `AudioTextNormalizer`。
///
/// 这是该口径**唯一**的 Dart 侧运行时实现：没有 Dart 回退。原生库或符号缺失时
/// [instance] 抛 [FushiComputeUnavailableError]。
///
/// 每个 isolate 各持一份实例与一组复用的原生暂存区（[NativeScratch]：随 isolate 存活，
/// isolate 退出时由 finalizer 释放——字幕重匹配、TTS 等短命 worker 不留下外部分配）。
final class AudioTextFoldNative implements Finalizable {
  AudioTextFoldNative._(this._foldUtf16, this._foldStudyUtf16);

  final _FoldUtf16Dart _foldUtf16;
  final _FoldStudyUtf16Dart _foldStudyUtf16;

  /// 固定槽：outLen（size_t）+ total（u32）。
  final NativeScratch _slots = NativeScratch.fixed(16);
  final NativeScratch _inputScratch = NativeScratch(minCapacity: 2048);
  final NativeScratch _outputScratch = NativeScratch(minCapacity: 2048);
  final NativeScratch _startsScratch = NativeScratch(minCapacity: 4096);
  final NativeScratch _endsScratch = NativeScratch(minCapacity: 4096);

  // 本次调用的缓冲（[_ensureCapacity] 之后有效；下一次 [_ensureCapacity] 可能换块）。
  Pointer<Uint16> _input = nullptr;
  Pointer<Uint16> _output = nullptr;
  Pointer<Uint32> _starts = nullptr;
  Pointer<Uint32> _ends = nullptr;
  int _capacity = 0;

  Pointer<Size> get _outLen => _slots.pointer.cast<Size>();
  Pointer<Uint32> get _total => (_slots.pointer + 8).cast<Uint32>();

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
        compute.library.lookupFunction<_FoldStudyUtf16C, _FoldStudyUtf16Dart>(
          'ffc_parse_fold_audio_study_utf16',
          isLeaf: true,
        ),
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  /// 四块缓冲都至少 [length] 个元素（原生侧保证输出不比输入长，容量传 [length] 即可）。
  void _ensureCapacity(int length) {
    _input = _inputScratch.reserve(length * 2).cast<Uint16>();
    _output = _outputScratch.reserve(length * 2).cast<Uint16>();
    _starts = _startsScratch.reserve(length * 4).cast<Uint32>();
    _ends = _endsScratch.reserve(length * 4).cast<Uint32>();
    _capacity = length;
  }

  void _copyIn(String text) {
    final int length = text.length;
    _ensureCapacity(length);
    final Uint16List units = _input.asTypedListOutOfLine(length);
    for (int i = 0; i < length; i++) {
      units[i] = text.codeUnitAt(i);
    }
  }

  int _run(String text, {required bool withStarts}) {
    final int length = text.length;
    _copyIn(text);
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
    return String.fromCharCodes(_output.asTypedListOutOfLine(n));
  }

  /// [text] 的归一化文本，以及每个输出 UTF-16 码元对应**输入码点起始码元下标**
  /// （补充平面码点的两个输出码元同一个下标；被保留码点的输出宽度等于输入宽度）。
  /// 返回的 [Uint32List] 是拷贝，不随下次调用改变。
  ({String text, Uint32List starts}) foldWithStarts(String text) {
    if (text.isEmpty) return (text: '', starts: Uint32List(0));
    final int n = _run(text, withStarts: true);
    if (n == 0) return (text: '', starts: Uint32List(0));
    return (
      text: String.fromCharCodes(_output.asTypedListOutOfLine(n)),
      starts: Uint32List.fromList(_starts.asTypedListOutOfLine(n)),
    );
  }

  /// 阅读器有声书坐标（`ReaderAudioPositionIndex`）：[text] 的归一化文本，以及每个输出
  /// UTF-16 码元所在输入码点的学习单位起点 `offsets` / 终点 `ends`（`fushi_engine` 的
  /// `countStudyChars` 口径，从右往左判收尾）与学习单位总数 `total`，一次 FFI 算完。
  /// 多个 DOM 文本节点用 U+0000 连接后传入，等价于逐节点各算一次再接起来。返回的列表是拷贝。
  ({String text, Uint32List offsets, Uint32List ends, int total}) foldStudy(
    String text,
  ) {
    if (text.isEmpty) {
      return (text: '', offsets: Uint32List(0), ends: Uint32List(0), total: 0);
    }
    final int length = text.length;
    _copyIn(text);
    final int status = _foldStudyUtf16(
      _input,
      length,
      _output,
      _starts,
      _ends,
      _capacity,
      _outLen,
      _total,
    );
    if (status != FfcStatus.ok) {
      throw StateError(
        'ffc_parse_fold_audio_study_utf16 failed with status $status',
      );
    }
    final int n = _outLen.value;
    return (
      text: n == 0 ? '' : String.fromCharCodes(_output.asTypedListOutOfLine(n)),
      offsets: Uint32List.fromList(_starts.asTypedListOutOfLine(n)),
      ends: Uint32List.fromList(_ends.asTypedListOutOfLine(n)),
      total: _total.value,
    );
  }

  /// 多段文本各自归一化后首尾相接（等于逐段 [fold] 再拼接），以及每段在拼接结果里的起点。
  /// 整批一次 FFI：各段之间在输入暂存区里插 U+0000（不在白名单里、必被丢弃，也挡住相邻段
  /// 首尾的孤立代理拼成代理对），段起点在原生侧写好的 starts 上二分查得，不逐码元走 Dart。
  ({String text, Uint32List pieceStarts}) foldConcat(List<String> pieces) {
    final int count = pieces.length;
    final Uint32List pieceStarts = Uint32List(count);
    if (count == 0) return (text: '', pieceStarts: pieceStarts);
    int length = count - 1;
    for (final String piece in pieces) {
      length += piece.length;
    }
    if (length == 0) return (text: '', pieceStarts: pieceStarts);
    _ensureCapacity(length);
    final Uint16List units = _input.asTypedListOutOfLine(length);
    // 第 k 段在输入里的起点；先暂存进 pieceStarts，过界后原地换成输出起点。
    int cursor = 0;
    for (int k = 0; k < count; k++) {
      if (k > 0) units[cursor++] = 0;
      pieceStarts[k] = cursor;
      final String piece = pieces[k];
      for (int i = 0; i < piece.length; i++) {
        units[cursor + i] = piece.codeUnitAt(i);
      }
      cursor += piece.length;
    }
    final int status = _foldUtf16(
      _input,
      length,
      _output,
      _starts,
      _capacity,
      _outLen,
    );
    if (status != FfcStatus.ok) {
      throw StateError('ffc_parse_fold_audio_utf16 failed with status $status');
    }
    final int n = _outLen.value;
    final Uint32List starts = _starts.asTypedListOutOfLine(n);
    // 输出 starts 单调不减：第 k 段的输出起点 = 第一个 starts ≥ 段输入起点的下标。
    int lo = 0;
    for (int k = 0; k < count; k++) {
      final int target = pieceStarts[k];
      int hi = n;
      while (lo < hi) {
        final int mid = (lo + hi) >> 1;
        if (starts[mid] < target) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      pieceStarts[k] = lo;
    }
    return (
      text: n == 0 ? '' : String.fromCharCodes(_output.asTypedListOutOfLine(n)),
      pieceStarts: pieceStarts,
    );
  }

  /// 多段文本各自归一化（第 k 项逐码元等于 `fold(pieces[k])`），整批一次 FFI：与
  /// [foldConcat] 同一次原生调用（段间 U+0000 隔开，循环在 Rust），再按段起点切回各段。
  /// 有声书重切的 ASR token、TTS 计划的句与间隙都按这个粒度归一化，逐项调 [fold] 会每项
  /// 跨一次 FFI。
  List<String> foldBatch(List<String> pieces) {
    final int count = pieces.length;
    if (count == 0) return <String>[];
    final ({String text, Uint32List pieceStarts}) r = foldConcat(pieces);
    final String text = r.text;
    final Uint32List starts = r.pieceStarts;
    return <String>[
      for (int k = 0; k < count; k++)
        text.substring(starts[k], k + 1 < count ? starts[k + 1] : text.length),
    ];
  }
}
