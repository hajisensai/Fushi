/// NSFW 作品制卡图片的模糊副本（拍板台 w04vrhUAaX：「制卡封面同步模糊」）。
///
/// 做法：原生内核把图按 average 缩到长边 [kNsfwBlurSampleEdge] 像素（每个样本是一大块
/// 原像素的均值，细节在这一步不可逆地丢掉），再线性放大回长边 [kNsfwBlurOutputEdge]，
/// 得到柔和的色块图——与库页封面的高斯模糊观感一致，但卡里存下的字节本身就认不出
/// 画面（不是靠渲染时滤镜）。全程走 `image_kernels` 的原生缩放，没有逐像素 Dart 循环。
///
/// 宿主经 [blurImageForNsfwAsync] 送进后台 isolate。
library;

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi_engine/media/image_kernels.dart';
import 'package:image/image.dart' as img;

/// 缩小采样后的长边像素：足够小到认不出画面，又留得住主色块。
const int kNsfwBlurSampleEdge = 12;

/// 放大回去的长边像素：卡里看到的是一张正常尺寸的柔和色块图，不是马赛克小图。
const int kNsfwBlurOutputEdge = 320;

/// 把编码图 [bytes] 变成模糊副本（JPEG）。解不开（认不出的格式 / 坏字节）返回 null——
/// 调用方此时**不得**退回原图（宁可卡上没有图，也不把没模糊的 NSFW 图送进卡）。
Uint8List? blurImageForNsfw(Uint8List bytes, {int quality = 85}) {
  if (bytes.isEmpty) return null;
  final img.Image? source = decodeImageNative(bytes);
  if (source == null || source.width <= 0 || source.height <= 0) return null;
  ({int width, int height}) fit(int longEdge) {
    final double scale = longEdge / math.max(source.width, source.height);
    return (
      width: math.max(1, (source.width * scale).round()),
      height: math.max(1, (source.height * scale).round()),
    );
  }

  final ({int width, int height}) small = fit(kNsfwBlurSampleEdge);
  final img.Image sampled = resizeImageExact(
    source,
    width: small.width,
    height: small.height,
    interpolation: img.Interpolation.average,
  );
  final ({int width, int height}) out = fit(kNsfwBlurOutputEdge);
  final img.Image blurred = resizeImageExact(
    sampled,
    width: out.width,
    height: out.height,
    interpolation: img.Interpolation.linear,
  );
  return img.encodeJpg(
    blurred.numChannels == 4 ? blurred.convert(numChannels: 3) : blurred,
    quality: quality.clamp(1, 100),
  );
}

/// [blurImageForNsfw] 的后台 isolate 变体（顶层函数，只捕获参数）。
Future<Uint8List?> blurImageForNsfwAsync(Uint8List bytes, {int quality = 85}) =>
    Isolate.run<Uint8List?>(() => blurImageForNsfw(bytes, quality: quality));
