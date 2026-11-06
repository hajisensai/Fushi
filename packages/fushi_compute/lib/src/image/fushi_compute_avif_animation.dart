import 'dart:ffi';
import 'dart:typed_data';

import 'package:fushi_ffi_view/fushi_ffi_view.dart';

import '../fushi_compute_library.dart';
import '../native_scratch.dart';

typedef _OpenC =
    Int32 Function(
      Pointer<Uint8>,
      Size,
      Uint32,
      Pointer<Pointer<Void>>,
      Pointer<Uint32>,
    );
typedef _OpenDart =
    int Function(
      Pointer<Uint8>,
      int,
      int,
      Pointer<Pointer<Void>>,
      Pointer<Uint32>,
    );
typedef _NextC =
    Int32 Function(Pointer<Void>, Pointer<Uint8>, Size, Pointer<Uint32>);
typedef _NextDart =
    int Function(Pointer<Void>, Pointer<Uint8>, int, Pointer<Uint32>);
typedef _CloseC = Void Function(Pointer<Void>);
typedef _CloseDart = void Function(Pointer<Void>);

/// [FfcAvifAnimation.nextFrame] 的结果。[pixels] 是原生输出槽上的**视图**（RGBA8888、
/// 行紧排、`width * height * 4` 字节），只在下一次 [FfcAvifAnimation.nextFrame] /
/// [FfcAvifAnimation.close] 之前有效；要留着或跨 isolate 传就先拷走
/// （如 `TransferableTypedData.fromList([pixels])`）。
typedef FfcAvifFrame = ({int index, int durationMs, Uint8List pixels});

/// `ffc_image_avif_anim_*` 的域绑定（符号 lookup 一次，每 isolate 一份）。
final class _AvifAnimationBindings {
  _AvifAnimationBindings(FushiCompute lib)
    : open = lib.library.lookupFunction<_OpenC, _OpenDart>(
        'ffc_image_avif_anim_open',
      ),
      next = lib.library.lookupFunction<_NextC, _NextDart>(
        'ffc_image_avif_anim_next',
      ),
      close = lib.library.lookupFunction<_CloseC, _CloseDart>(
        'ffc_image_avif_anim_close',
      ),
      finalizer = NativeFinalizer(
        lib.library
            .lookup<NativeFunction<_CloseC>>('ffc_image_avif_anim_close')
            .cast(),
      );

  final _OpenDart open;
  final _NextDart next;
  final _CloseDart close;
  final NativeFinalizer finalizer;

  static _AvifAnimationBindings? _instance;

  static _AvifAnimationBindings get instance {
    final _AvifAnimationBindings? b = _instance;
    if (b != null) return b;
    final FushiCompute lib = FushiCompute.require();
    try {
      return _instance = _AvifAnimationBindings(lib);
    } on ArgumentError catch (e) {
      throw lib.missingSymbols('image (avif animation)', e.message ?? e);
    }
  }
}

/// 原生侧（native/fushi_compute `image/avif/sequence.rs`）持有的 AVIF 逐帧解码器：文件字节、
/// 样本表与 rav1d 上下文都在 Rust 里，按需一次解一帧（不把整段动图解进内存）。
///
/// 动图（`avis` 图像序列）按视频轨逐样本解，末帧之后自动回到第 0 帧；静态 AVIF 退化成
/// 1 帧（[frameCount] == 1、[FfcAvifFrame.durationMs] == 0）。输出一律 RGBA8888，宽度按
/// open 时的 `maxWidth` 只缩不放、等比。
///
/// 解一帧是几～几十毫秒的同步 FFI：只在后台 isolate 里用。对象不可达或所在 isolate 退出时
/// 由 [NativeFinalizer] 释放；[close] 立即释放（幂等）。不可并发使用（同一 isolate 天然满足）。
final class FfcAvifAnimation implements Finalizable {
  FfcAvifAnimation._(
    this._b,
    this._handle, {
    required this.width,
    required this.height,
    required this.frameCount,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.repeats,
  }) : _out = NativeScratch.fixed(width * height * 4) {
    _b.finalizer.attach(this, _handle, detach: this);
  }

  /// 打开 [bytes]（AVIF 文件全部字节；原生侧自己拷一份）。[maxWidth] > 0 时输出宽度不超过它
  /// （物理像素，只缩不放、等比）。不是 AVIF / 容器或首帧解不开返回 null。
  /// 原生库缺失或缺符号抛 [FushiComputeUnavailableError]。
  static FfcAvifAnimation? open(Uint8List bytes, {int maxWidth = 0}) {
    if (maxWidth < 0) {
      throw ArgumentError.value(maxWidth, 'maxWidth', 'must be >= 0');
    }
    final _AvifAnimationBindings b = _AvifAnimationBindings.instance;
    final Pointer<Uint8> src = NativeScratch.input.reserve(bytes.length);
    src.asTypedListOutOfLine(bytes.length).setAll(0, bytes);
    final NativeScratch slots = NativeScratch.fixed(8 + 6 * 4);
    final Pointer<Pointer<Void>> handleOut = slots.pointer.cast();
    final Pointer<Uint32> info = Pointer<Uint32>.fromAddress(
      slots.pointer.address + 8,
    );
    final int status = b.open(src, bytes.length, maxWidth, handleOut, info);
    if (status == FfcStatus.badInput) return null;
    if (status != FfcStatus.ok) {
      throw StateError(
        'fushi_compute ffc_image_avif_anim_open failed: $status',
      );
    }
    final FfcAvifAnimation anim = FfcAvifAnimation._(
      b,
      handleOut.value,
      width: info[0],
      height: info[1],
      frameCount: info[2],
      sourceWidth: info[3],
      sourceHeight: info[4],
      repeats: info[5] != 0,
    );
    slots.release();
    return anim;
  }

  final _AvifAnimationBindings _b;
  final Pointer<Void> _handle;

  /// 输出帧槽（`width * height * 4`）+ 元数据槽。
  final NativeScratch _out;
  final NativeScratch _meta = NativeScratch.fixed(8);
  bool _closed = false;

  /// 输出尺寸（已按 maxWidth 缩放）。
  final int width;
  final int height;

  /// 帧数（静态图为 1）。
  final int frameCount;

  /// 源（解码）尺寸。
  final int sourceWidth;
  final int sourceHeight;

  /// 文件要求无限循环（`elst` repeat；ffmpeg `-loop 0`）。静态图为 false。
  final bool repeats;

  /// 是不是动图（多于 1 帧）。
  bool get isAnimated => frameCount > 1;

  /// 解下一帧（末帧之后回到第 0 帧）。坏样本返回 null（调用方停在已显示的帧上）。
  FfcAvifFrame? nextFrame() {
    if (_closed) throw StateError('FfcAvifAnimation is closed');
    final int len = width * height * 4;
    final Pointer<Uint8> out = _out.pointer;
    final Pointer<Uint32> meta = _meta.pointer.cast();
    final int status = _b.next(_handle, out, len, meta);
    if (status == FfcStatus.badInput) return null;
    if (status != FfcStatus.ok) {
      throw StateError(
        'fushi_compute ffc_image_avif_anim_next failed: $status',
      );
    }
    return (
      index: meta[0],
      durationMs: meta[1],
      pixels: out.asTypedListOutOfLine(len),
    );
  }

  /// 立即释放原生解码器与输出槽（幂等）。之后 [nextFrame] 抛 [StateError]。
  void close() {
    if (_closed) return;
    _closed = true;
    _b.finalizer.detach(this);
    _b.close(_handle);
    _out.release();
    _meta.release();
  }
}
