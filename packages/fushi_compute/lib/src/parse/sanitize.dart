import 'dart:ffi';
import 'dart:typed_data';

import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _ChapterC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Uint32,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _ChapterDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _CssC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Uint32,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );
typedef _CssDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
    );

/// 阅读器章节 HTML / 书内 CSS 下发前清洗链的原生实现
/// （`native/fushi_compute/src/parse/sanitize.rs` 的 `ffc_parse_sanitize_chapter` /
/// `ffc_parse_sanitize_css`）。
///
/// 这是该清洗链**唯一**的运行时实现：没有 Dart 回退。原生库或符号缺失时 [instance]
/// 抛 [FushiComputeUnavailableError]。
///
/// 输入是磁盘上的原始字节（宽松 UTF-8 解码在原生侧做，规则同 Dart
/// `utf8.decode(allowMalformed: true)`），输出是最终下发给 WebView 的 UTF-8 字节；整条链只跨
/// 一次 FFI 边界。每个 isolate 各持一份实例。
final class ReaderSanitizeNative implements Finalizable {
  ReaderSanitizeNative._(this._chapter, this._css, this._freeBytes);

  /// 自闭合非 void 元素展开成成对标签（BUG-079 / BUG-737）。
  static const int stepXhtml = 1;

  /// 去掉正文 `<img>` 的 `loading` 属性（连原书自带的 lazy 一起），插图一律 eager。
  static const int stepStripImageLoading = 2;

  /// 合并前导插图插到 `<body…>` 之后（插图串为空时是空操作）。
  static const int stepBodyImages = 4;

  /// 阅读器 head 注入（`<head…>` 后 / `</head>` 前）。
  static const int stepReaderHead = 8;

  /// 输入是 Dart `String` 编出来的 UTF-8（已解码文本）而不是磁盘字节：开头的 U+FEFF 是
  /// 正文的一部分、不当 BOM 去掉（磁盘字节按 `utf8.decode` 的规则去掉开头一个 BOM）。
  static const int inputIsText = 0x100;

  /// 原生侧返回 `badInput`：`</head>` 出现在 `<head…>` 结束之前。旧 Dart 实现在这里的
  /// `substring` 抛 [RangeError]，保持同一失败形态。
  static const int _statusHeadOrder = FfcStatus.badInput;

  final _ChapterDart _chapter;
  final _CssDart _css;
  final void Function(Pointer<Uint8>, int) _freeBytes;

  /// 固定输出槽：outPtr（指针）+ outLen（size_t）。
  final NativeScratch _slots = NativeScratch.fixed(16);
  Pointer<Pointer<Uint8>> get _outPtr => _slots.pointer.cast<Pointer<Uint8>>();
  Pointer<Size> get _outLen => (_slots.pointer + 8).cast<Size>();

  static ReaderSanitizeNative? _instance;

  /// 本 isolate 的实例（首次访问时加载并 lookup 符号）。
  static ReaderSanitizeNative get instance => _instance ??= _load();

  static ReaderSanitizeNative _load() {
    final FushiCompute compute = FushiCompute.require();
    // lookup 名写成字符串字面量：verify_abi.sh 从绑定源码抓期望符号集。
    try {
      return ReaderSanitizeNative._(
        compute.library.lookupFunction<_ChapterC, _ChapterDart>(
          'ffc_parse_sanitize_chapter',
          isLeaf: true,
        ),
        compute.library.lookupFunction<_CssC, _CssDart>(
          'ffc_parse_sanitize_css',
          isLeaf: true,
        ),
        compute.freeBytes,
      );
    } on ArgumentError catch (e) {
      throw compute.missingSymbols('parse', e.message ?? e);
    }
  }

  /// 复用的原生输入暂存区（FFI 不能借用 Dart 堆上的 `Uint8List`：`.address` 只对
  /// `@Native` 叶子函数可用，本库走 `DynamicLibrary`）。按需倍增，随 isolate 存活、退出时由
  /// [NativeScratch] 的 finalizer 释放。
  final NativeScratch _scratch = NativeScratch();

  Pointer<Uint8> _reserve(int length) => _scratch.reserve(length);

  /// 章节 HTML 链：按 [steps]（`step*` 位或，可另或上 [inputIsText]）依次处理 [input]。
  /// [images] / [headStart] / [headEnd] 是已编码的 UTF-8 串。`</head>` 早于 `<head…>` 结束时
  /// 抛 [RangeError]。四段输入一次拷进同一块暂存区再过界。
  Uint8List chapterHtml(
    Uint8List input, {
    required int steps,
    Uint8List? images,
    Uint8List? headStart,
    Uint8List? headEnd,
  }) {
    final int imagesLen = images?.length ?? 0;
    final int headStartLen = headStart?.length ?? 0;
    final int headEndLen = headEnd?.length ?? 0;
    final int imagesAt = input.length;
    final int headStartAt = imagesAt + imagesLen;
    final int headEndAt = headStartAt + headStartLen;
    final int total = headEndAt + headEndLen;
    final Pointer<Uint8> base = _reserve(total);
    final Uint8List view = base.asTypedListOutOfLine(total);
    view.setRange(0, imagesAt, input);
    if (images != null) view.setRange(imagesAt, headStartAt, images);
    if (headStart != null) view.setRange(headStartAt, headEndAt, headStart);
    if (headEnd != null) view.setRange(headEndAt, total, headEnd);
    final int status = _chapter(
      base,
      input.length,
      steps,
      base + imagesAt,
      imagesLen,
      base + headStartAt,
      headStartLen,
      base + headEndAt,
      headEndLen,
      _outPtr,
      _outLen,
    );
    if (status == _statusHeadOrder) {
      throw RangeError('</head> precedes the end of the <head> open tag');
    }
    return _takeOutput(status, 'ffc_parse_sanitize_chapter');
  }

  /// 书内 CSS 链：宽松解码后改写 `-epub-*` 前缀属性。[flags] 只认 [inputIsText]。
  Uint8List css(Uint8List input, {int flags = 0}) {
    final Pointer<Uint8> base = _reserve(input.length);
    base.asTypedListOutOfLine(input.length).setAll(0, input);
    final int status = _css(base, input.length, flags, _outPtr, _outLen);
    return _takeOutput(status, 'ffc_parse_sanitize_css');
  }

  Uint8List _takeOutput(int status, String symbol) {
    if (status != FfcStatus.ok) {
      throw StateError('$symbol failed with status $status');
    }
    final Pointer<Uint8> ptr = _outPtr.value;
    final int len = _outLen.value;
    try {
      return Uint8List.fromList(ptr.asTypedListOutOfLine(len));
    } finally {
      _freeBytes(ptr, len);
    }
  }
}
