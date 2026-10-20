import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:fushi_compute/fushi_compute.dart';

/// BUG-959：本地媒体封面统一解码上限（物理像素宽）。
///
/// 封面卡槽最宽约 200 逻辑像素，最高 dpr(3) 下约 600 物理像素，720 仍有富余且清晰；
/// 而封面源常是视频原生分辨率（1080p/4K）或 EPUB 原始封面（常 1600×2400），不降采样
/// 会整帧解码进 Flutter ImageCache（默认 100MB/1000 张）——十几张 1080p 或 3 张 4K
/// 即撑爆上限，滚动时 LRU 反复淘汰→重解码全帧，产生持续卡顿与高内存。
const int kLocalCoverDecodePixelWidth = 720;

/// 有声书迷你条等极小封面（约 36 逻辑像素）的解码上限，进一步省内存。
const int kMiniCoverDecodePixelWidth = 144;

/// 首页活动时间轴缩略图（40×56 / 68×40）的解码上限。
///
/// 取 192 而非默认 720：覆盖 3x DPR 仍有余量，同时把活动列表中几十张封面的
/// 解码内存压到约 1/14，避免滚动时 ImageCache 淘汰与重解码抖动。
const int kActivityCoverDecodePixelWidth = 192;

/// 给本地文件封面 [ImageProvider] 套解码上限。
///
/// [ResizeImage] 只按 [width] 上限降采样（`allowUpscaling: false` 保证不放大、不裁切、
/// 小于上限的源原样解码），把「原生分辨率整帧」收敛到「卡槽够用的物理像素」。
/// 缺失文件由上层 `errorBuilder` / `frameBuilder` 兜底，不需要事先同步 `existsSync`。
///
/// `.avif`（漫画页图当封面、AVIF 封面）Flutter 自带 codec 在多数平台解不开，交给
/// [AvifFileImage] 走原生内核，同样按 [width] 只缩不放。
ImageProvider resizedFileImage(
  File file, {
  int width = kLocalCoverDecodePixelWidth,
}) => isAvifPath(file.path)
    ? AvifFileImage(file, maxWidth: width)
    : ResizeImage(FileImage(file), width: width, allowUpscaling: false);

/// 路径扩展名是不是 `.avif`（大小写不敏感）。导入 / 下载 / 直读缓存都按真实字节定
/// 扩展名，所以扩展名就是格式。
bool isAvifPath(String path) => path.toLowerCase().endsWith('.avif');

/// 本地 AVIF 文件的 [ImageProvider]：后台 isolate 里用原生内核（native/fushi_compute 的
/// image/avif.rs）解成 RGBA，再经 [ui.ImageDescriptor.raw] 交给引擎；[maxWidth] 与
/// `ResizeImage(width:, allowUpscaling: false)` 同义（只缩不放、按宽等比）。
///
/// 不能套 [ResizeImage]：它只会把缩放参数塞进「编码字节 → codec」的 decode 回调，而
/// AVIF 正是那个 codec 解不开的格式。
@immutable
class AvifFileImage extends ImageProvider<AvifFileImage> {
  const AvifFileImage(this.file, {this.maxWidth});

  final File file;

  /// 解码宽度上限（物理像素）；null = 原尺寸。
  final int? maxWidth;

  @override
  Future<AvifFileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AvifFileImage>(this);

  @override
  ImageStreamCompleter loadImage(
    AvifFileImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _loadCodec(key),
    scale: 1,
    debugLabel: key.file.path,
    informationCollector: () => <DiagnosticsNode>[
      ErrorDescription('Path: ${file.path}'),
    ],
  );

  Future<ui.Codec> _loadCodec(AvifFileImage key) async {
    final Uint8List bytes = await key.file.readAsBytes();
    final ({Uint8List rgba, int width, int height})? decoded =
        await Isolate.run(() => decodeAvifToRgba(bytes));
    if (decoded == null) {
      // 与 FileImage 处理空文件同理：坏图不留在缓存里，换好文件后能重新加载。
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      throw StateError('${key.file.path} could not be decoded as AVIF.');
    }
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      decoded.rgba,
    );
    final ui.ImageDescriptor descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: decoded.width,
      height: decoded.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final int? limit = key.maxWidth;
    return descriptor.instantiateCodec(
      targetWidth: limit != null && limit < decoded.width ? limit : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AvifFileImage &&
      other.file.path == file.path &&
      other.maxWidth == maxWidth;

  @override
  int get hashCode => Object.hash(file.path, maxWidth);

  @override
  String toString() =>
      '${objectRuntimeType(this, 'AvifFileImage')}("${file.path}", maxWidth: $maxWidth)';
}

/// AVIF 字节 → RGBA8888（原生解码 + 3 通道补 alpha，两次 FFI）；解不开返回 null。
/// 顶层函数：给 [Isolate.run] 用，闭包只捕获字节。
({Uint8List rgba, int width, int height})? decodeAvifToRgba(Uint8List bytes) {
  final FfcDecodedImage? d = FushiComputeImage.instance.decode(bytes);
  if (d == null) return null;
  final Uint8List rgba = d.channels == 4
      ? d.pixels
      : FushiComputeImage.instance.toRgba8(
          d.pixels,
          d.channels,
          d.width,
          d.height,
        );
  return (rgba: rgba, width: d.width, height: d.height);
}

/// 换封面（同路径覆盖写）后驱逐该路径的**全部**旧解码缓存条目。
///
/// [ImageCache] 按 provider key 存条目：裸 [FileImage] 与 [resizedFileImage]
/// （[ResizeImage] 包装键）是**两个不同的 key**——只驱逐 FileImage 的话，走降采样
/// 渲染的卡片重建时仍命中旧解码，用户看到的还是换之前那张图（游戏封面卡与视频
/// 封面同坑，见 `setVideoCoverFromPickedFile` 注释）。两个键都清才干净。
Future<void> evictLocalCoverCache(String path) async {
  final File file = File(path);
  await FileImage(file).evict();
  await resizedFileImage(file).evict();
}
