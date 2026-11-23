import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _NewC = Int32 Function(Pointer<Pointer<Void>>);
typedef _NewDart = int Function(Pointer<Pointer<Void>>);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeDart = void Function(Pointer<Void>);
typedef _ResetC = Int32 Function(Pointer<Void>);
typedef _ResetDart = int Function(Pointer<Void>);
typedef _ConfigureC = Int32 Function(Pointer<Void>, Uint32);
typedef _ConfigureDart = int Function(Pointer<Void>, int);
typedef _FeedPngC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Size,
      Pointer<Float>,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
      Pointer<Uint32>,
    );
typedef _FeedPngDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Float>,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
      Pointer<Uint32>,
    );
typedef _FeedTextC =
    Int32 Function(
      Pointer<Void>,
      Pointer<Uint8>,
      Size,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
      Pointer<Uint32>,
    );
typedef _FeedTextDart =
    int Function(
      Pointer<Void>,
      Pointer<Uint8>,
      int,
      Pointer<Pointer<Uint8>>,
      Pointer<Size>,
      Pointer<Uint32>,
    );

/// [FfcOcrLineTracker.feedPng] 的判定（与 ocrline.rs `action` 同序）。
enum FfcOcrLineFrameAction {
  /// 没变化 / 这一帧已经 OCR 过。
  idle,

  /// 画面在变（打字机 / 转场），等它稳定。
  settling,

  /// 稳定的新画面：[FfcOcrLineFrame.rgba] 是裁好的台词框，OCR 后调 [FfcOcrLineTracker.feedText]。
  ocr,

  /// 框里没字了（上一句已清）。
  cleared,
}

/// 一帧的判定结果。只有 [action] 为 [FfcOcrLineFrameAction.ocr] 时 [rgba] 非空
/// （`width * height * 4`，RGBA8888 行紧排）。这是**预处理后**的图：小字会被整数倍放大、
/// 开了二值化时是白底黑字，所以 [width] / [height] 可能大于裁出的台词框。
final class FfcOcrLineFrame {
  const FfcOcrLineFrame(
    this.action, {
    this.rgba,
    this.width = 0,
    this.height = 0,
  });

  final FfcOcrLineFrameAction action;
  final Uint8List? rgba;
  final int width;
  final int height;
}

/// [FfcOcrLineTracker.feedText] 的判定（与 ocrline.rs `kind` 同序）。
enum FfcOcrLineTextKind {
  /// 识别结果为空（同时清掉上一句）。
  empty,

  /// 与上一句是同一句。
  duplicate,

  /// 新的一句。
  newLine,

  /// 上一句的续写；[FfcOcrLineText.text] 是「上一句 + 新尾巴」（严格前缀扩展）。
  extend,
}

/// 一次文本判定的结果。[text] 只在 newLine / extend 时非空。
typedef FfcOcrLineText = ({FfcOcrLineTextKind kind, String text});

final class _OcrLineBindings {
  _OcrLineBindings(FushiCompute lib)
    : create = lib.library.lookupFunction<_NewC, _NewDart>('ffc_ocrline_new'),
      free = lib.library.lookupFunction<_FreeC, _FreeDart>('ffc_ocrline_free'),
      reset = lib.library.lookupFunction<_ResetC, _ResetDart>(
        'ffc_ocrline_reset',
      ),
      forgetFrame = lib.library.lookupFunction<_ResetC, _ResetDart>(
        'ffc_ocrline_forget_frame',
      ),
      configure = lib.library.lookupFunction<_ConfigureC, _ConfigureDart>(
        'ffc_ocrline_configure',
      ),
      feedPng = lib.library.lookupFunction<_FeedPngC, _FeedPngDart>(
        'ffc_ocrline_feed_png',
      ),
      feedText = lib.library.lookupFunction<_FeedTextC, _FeedTextDart>(
        'ffc_ocrline_feed_text',
      ),
      finalizer = NativeFinalizer(
        lib.library.lookup<NativeFunction<_FreeC>>('ffc_ocrline_free').cast(),
      ),
      lib = lib;

  final _NewDart create;
  final _FreeDart free;
  final _ResetDart reset;
  final _ResetDart forgetFrame;
  final _ConfigureDart configure;
  final _FeedPngDart feedPng;
  final _FeedTextDart feedText;
  final NativeFinalizer finalizer;
  final FushiCompute lib;

  static _OcrLineBindings? _instance;

  static _OcrLineBindings get instance {
    final _OcrLineBindings? b = _instance;
    if (b != null) return b;
    final FushiCompute lib = FushiCompute.require();
    try {
      return _instance = _OcrLineBindings(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('ocr line stream', e.message ?? e);
    }
  }
}

/// 游戏 OCR 台词流的判定核心（native/fushi_compute `ocrline.rs`）：上一帧签名、稳定计数、
/// 已送 OCR 的帧、空白态、上一句文本全在 Rust 里，Dart 不存镜像状态。
///
/// 用法（泵）：截窗得到整窗 PNG → [feedPng]（几～几十毫秒，后台 isolate 里用
/// [feedPngAt]）→ action 为 ocr 时把 [FfcOcrLineFrame.rgba] 交给 OCR → [feedText] →
/// newLine / extend 送进台词流。同一个 tracker 的调用必须串行（泵天然满足；原生侧另有锁兜底）。
///
/// 对象不可达或所在 isolate 退出时由 [NativeFinalizer] 释放；[close] 立即释放（幂等）。
final class FfcOcrLineTracker implements Finalizable {
  FfcOcrLineTracker._(this._b, this._handle) {
    _b.finalizer.attach(this, _handle, detach: this);
  }

  /// 新建 tracker。原生库缺失或缺符号抛 [FushiComputeUnavailableError]。
  factory FfcOcrLineTracker() {
    final _OcrLineBindings b = _OcrLineBindings.instance;
    final Pointer<Pointer<Void>> out = malloc<Pointer<Void>>();
    try {
      _check('ffc_ocrline_new', b.create(out));
      return FfcOcrLineTracker._(b, out.value);
    } finally {
      malloc.free(out);
    }
  }

  final _OcrLineBindings _b;
  final Pointer<Void> _handle;
  bool _closed = false;

  /// 原生句柄地址：交给后台 isolate 的 [feedPngAt]（本对象必须活到那次调用结束）。
  int get address {
    _ensureOpen();
    return _handle.address;
  }

  /// 在本 isolate 里喂一帧（同 [feedPngAt]）。
  FfcOcrLineFrame feedPng(
    Uint8List png, {
    required double left,
    required double top,
    required double width,
    required double height,
  }) => feedPngAt(
    address,
    png,
    left: left,
    top: top,
    width: width,
    height: height,
  );

  /// 喂一帧整窗 PNG，区域是客户区归一化坐标（0～1）。静态、按地址调用：在后台 isolate 里跑
  /// （那边自己 lookup 符号）。PNG 坏或区域与图没有交集抛 [FormatException] / [ArgumentError]。
  static FfcOcrLineFrame feedPngAt(
    int address,
    Uint8List png, {
    required double left,
    required double top,
    required double width,
    required double height,
  }) {
    final _OcrLineBindings b = _OcrLineBindings.instance;
    final Pointer<Uint8> src = NativeScratch.input.reserve(png.length);
    src.asTypedListOutOfLine(png.length).setAll(0, png);
    final Pointer<Float> region = malloc<Float>(4);
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    final Pointer<Uint32> meta = malloc<Uint32>(3);
    try {
      region[0] = left;
      region[1] = top;
      region[2] = width;
      region[3] = height;
      final int status = b.feedPng(
        Pointer<Void>.fromAddress(address),
        src,
        png.length,
        region,
        outPtr,
        outLen,
        meta,
      );
      if (status == FfcStatus.badInput) {
        throw const FormatException('ffc_ocrline_feed_png: not a PNG');
      }
      if (status == FfcStatus.invalidArgument) {
        throw ArgumentError('OCR region does not intersect the frame');
      }
      _check('ffc_ocrline_feed_png', status);
      final FfcOcrLineFrameAction action =
          FfcOcrLineFrameAction.values[meta[0]];
      if (action != FfcOcrLineFrameAction.ocr) return FfcOcrLineFrame(action);
      final Pointer<Uint8> data = outPtr.value;
      final int n = outLen.value;
      final Uint8List rgba;
      try {
        rgba = Uint8List.fromList(data.asTypedListOutOfLine(n));
      } finally {
        b.lib.freeBytes(data, n);
      }
      return FfcOcrLineFrame(
        action,
        rgba: rgba,
        width: meta[1],
        height: meta[2],
      );
    } finally {
      malloc.free(region);
      malloc.free(outPtr);
      malloc.free(outLen);
      malloc.free(meta);
    }
  }

  /// 喂一次 OCR 结果（多行用 `\n` 分隔）。微秒级，可在 UI isolate 里调。
  FfcOcrLineText feedText(String text) {
    _ensureOpen();
    final List<int> bytes = utf8.encode(text);
    final Pointer<Uint8> src = NativeScratch.input.reserve(bytes.length);
    src.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
    final Pointer<Pointer<Uint8>> outPtr = malloc<Pointer<Uint8>>();
    final Pointer<Size> outLen = malloc<Size>();
    final Pointer<Uint32> kind = malloc<Uint32>();
    try {
      _check(
        'ffc_ocrline_feed_text',
        _b.feedText(_handle, src, bytes.length, outPtr, outLen, kind),
      );
      final FfcOcrLineTextKind k = FfcOcrLineTextKind.values[kind.value];
      final Pointer<Uint8> data = outPtr.value;
      final int n = outLen.value;
      if (data == nullptr || n == 0) return (kind: k, text: '');
      try {
        return (kind: k, text: utf8.decode(data.asTypedListOutOfLine(n)));
      } finally {
        _b.lib.freeBytes(data, n);
      }
    } finally {
      malloc.free(outPtr);
      malloc.free(outLen);
      malloc.free(kind);
    }
  }

  /// 忘掉全部帧状态与上一句（换识别区域时）。
  void reset() {
    _ensureOpen();
    _check('ffc_ocrline_reset', _b.reset(_handle));
  }

  /// 上一次交出的 OCR 帧没能识别（识别器单次报错）：同一画面稳定时会再交出一次，
  /// 上一句保留。
  void forgetFrame() {
    _ensureOpen();
    _check('ffc_ocrline_forget_frame', _b.forgetFrame(_handle));
  }

  /// 送 OCR 前的预处理选项（ocrline.rs `flags`）。小字放大总是开着；[binarize] = 按 Otsu
  /// 阈值二值化成白底黑字（低对比 / 描边字）。选项变了时同一画面会按新选项再交出一次。
  void configure({required bool binarize}) {
    _ensureOpen();
    _check(
      'ffc_ocrline_configure',
      _b.configure(_handle, binarize ? _kFlagBinarize : 0),
    );
  }

  static const int _kFlagBinarize = 1;

  /// 立即释放原生 tracker（幂等）。
  void close() {
    if (_closed) return;
    _closed = true;
    _b.finalizer.detach(this);
    _b.free(_handle);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('FfcOcrLineTracker is closed');
  }

  static void _check(String symbol, int status) {
    if (status != FfcStatus.ok) {
      throw StateError('fushi_compute $symbol failed: $status');
    }
  }
}
