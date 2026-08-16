import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// TODO-646 近无损压缩：制卡截图降采样。
///
/// 视频制卡封面在没有 cue GIF 时回退到当前帧截图（media_kit `image/jpeg`，按
/// libmpv 原始解码帧分辨率输出，可能是 1080p / 4K）。Lapis 卡面主图 CSS
/// `max-height:400px`、点图放大灯箱最大 ~1000px，故长边 1000px 已足够清晰，
/// 再大只是浪费媒体库体积。本模块把截图字节解码 → 长边等比缩到 1000px → 重编码
/// 高质量 JPEG（quality 90）。
///
/// 设计要点：
/// - **只缩不放**：长边已 <= [maxLongEdge] 时原样返回入参字节（不解码重编码，
///   避免对小图反复有损转码）。
/// - **解码失败保守回退**：字节非图片 / 解码返回 null 时原样返回入参，绝不让
///   降采样把一张有效截图变成空字节而破坏制卡。
/// - 纯 Dart（`package:image`，无 dart:ui），可在隔离/单测中直接调用，与
///   `epub_edge_matcher.dart` 同范式。

/// 降采样后重编码用的目标格式。
///
/// 这里**不直接用** `MiningStillFormat`（`lib/src/mining/` 的制卡值对象）：本模块是
/// utils 层，同时服务阅读器选区插图等与制卡无关的调用点，反向依赖 mining 会把制卡
/// 的偏好语义拖进一个纯图像工具里。调用点做一次映射即可。
enum CardScreenshotEncoding {
  /// 有损，吃 `quality` 参数（默认，= 改动前的唯一行为）。
  jpeg,

  /// 无损，忽略 `quality`。
  png,
}

/// 计算等比缩放后的目标尺寸（纯函数，可单测）。
///
/// 返回 `null` 表示无需缩放（长边已 <= [maxLongEdge]，或输入尺寸非法）。
/// 否则返回缩放后的 `(width, height)`，长边恰为 [maxLongEdge]，另一边等比四舍五入
/// 且至少为 1（避免极端宽高比缩成 0）。
({int width, int height})? computeDownsampledSize({
  required int width,
  required int height,
  int maxLongEdge = 1000,
}) {
  if (width <= 0 || height <= 0 || maxLongEdge <= 0) return null;
  final int longEdge = width >= height ? width : height;
  if (longEdge <= maxLongEdge) return null; // 只缩不放。
  final double scale = maxLongEdge / longEdge;
  final int newWidth = (width * scale).round();
  final int newHeight = (height * scale).round();
  return (
    width: newWidth < 1 ? 1 : newWidth,
    height: newHeight < 1 ? 1 : newHeight,
  );
}

/// 把制卡截图 [bytes] 降采样到长边 [maxLongEdge]px，重编码为 [encoding]（JPEG 时吃
/// [quality]）。解码失败时原样返回 [bytes]（绝不返回空/破坏媒体）。
///
/// TODO-757 压缩开关：默认压缩档（长边 1000px / 质量 90，= TODO-646 现状）。关闭压缩
/// 时调用点传高保真档（长边 2000px / 质量 95）。默认值保持现状，纯函数不读全局偏好。
///
/// 「不需要缩放就原样返回」这条捷径**只在入参已经是目标格式时**成立：用户选 PNG 而截图
/// 源是 media_kit 的 `image/jpeg` 时，原样返回会让调用方把 JPEG 字节写进 `.png`（Anki 按
/// 扩展名判 MIME → 封面不显示）。故这里按 [encoding] 与实际字节格式比对，格式不符就
/// 重编码——即使尺寸没变。返回字节的真实格式由 [cardScreenshotEncodingOf] 复核。
Uint8List downsampleCardScreenshot(
  Uint8List bytes, {
  int maxLongEdge = 1000,
  int quality = 90,
  CardScreenshotEncoding encoding = CardScreenshotEncoding.jpeg,
}) {
  if (bytes.isEmpty) return bytes;
  try {
    // `img.decodeImage` 对损坏字节可能返回 null，也可能在嗅探解码器时抛
    // （如 GIF 头探测越界 RangeError）。两种都视作「不是可处理的截图」，
    // 保守原样返回，绝不让降采样把一张有效封面变成空/异常而破坏制卡。
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final ({int width, int height})? target = computeDownsampledSize(
      width: decoded.width,
      height: decoded.height,
      maxLongEdge: maxLongEdge,
    );
    // 已 <= 长边上限**且**字节本就是目标格式 → 一点不动（不解码重编码，避免对小图反复
    // 有损转码，jpeg 路径逐字节等价于改动前）。
    if (target == null && cardScreenshotEncodingOf(bytes) == encoding) {
      return bytes;
    }
    final img.Image out = target == null
        ? decoded
        : img.copyResize(
            decoded,
            width: target.width,
            height: target.height,
          );
    return switch (encoding) {
      CardScreenshotEncoding.jpeg => img.encodeJpg(out, quality: quality),
      CardScreenshotEncoding.png => img.encodePng(out),
    };
  } catch (_) {
    return bytes;
  }
}

/// [bytes] 实际是哪种编码（按魔数嗅探，不解码整图）。既不是 JPEG 也不是 PNG（含空字节、
/// GIF、损坏数据）时返回 null。
///
/// 用途是**落盘前复核真实格式**：降采样在解码失败时会原样返回入参，此时产出格式与用户
/// 所选无关，扩展名必须跟着真实字节走。
CardScreenshotEncoding? cardScreenshotEncodingOf(Uint8List bytes) {
  // `findFormatForData` 会挨个问解码器 `isValidFile`，其中 GIF 那个对**过短/损坏**的字节
  // 直接抛 RangeError（`InputBuffer.readString` 越界）——不是返回 false。嗅探失败等价于
  // 「不是我们认得的静图」，与 [downsampleCardScreenshot] 的保守回退同一条纪律。
  try {
    return switch (img.findFormatForData(bytes)) {
      img.ImageFormat.jpg => CardScreenshotEncoding.jpeg,
      img.ImageFormat.png => CardScreenshotEncoding.png,
      _ => null,
    };
  } catch (_) {
    return null;
  }
}

/// 只换编码、**不改尺寸**：把 [bytes] 重编码成 [encoding]。
///
/// 与 [downsampleCardScreenshot] 分开是因为用途不同：那个服务「我们自己抓的原始帧」
/// （该压就压），这个服务「外部已经处理好的封面字节」（gal 窗口抓图已降过采样、浏览器
/// 扩展给的截图），此时再压一遍尺寸是越权。
///
/// 三种情况原样返回，一个字节都不动：
/// - 空字节；
/// - 嗅探不出是 JPEG/PNG —— **动图（GIF/WebP/AVIF）走的就是这条**，绝不能把一段动图
///   解成第一帧再编成静图；
/// - 已经就是目标格式。
Uint8List transcodeCardScreenshot(
  Uint8List bytes, {
  required CardScreenshotEncoding encoding,
  int quality = 90,
}) {
  if (bytes.isEmpty) return bytes;
  final CardScreenshotEncoding? actual = cardScreenshotEncodingOf(bytes);
  if (actual == null || actual == encoding) return bytes;
  try {
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    return switch (encoding) {
      CardScreenshotEncoding.jpeg => img.encodeJpg(decoded, quality: quality),
      CardScreenshotEncoding.png => img.encodePng(decoded),
    };
  } catch (_) {
    return bytes;
  }
}

/// [transcodeCardScreenshot] 的后台 isolate 变体（理由同
/// [downsampleCardScreenshotAsync]：解码/编码是纯 Dart CPU 重活，不能压 UI 线程）。
Future<Uint8List> transcodeCardScreenshotAsync(
  Uint8List bytes, {
  required CardScreenshotEncoding encoding,
  int quality = 90,
}) {
  if (bytes.isEmpty) return Future<Uint8List>.value(bytes);
  return Isolate.run<Uint8List>(
    () => transcodeCardScreenshot(bytes, encoding: encoding, quality: quality),
  );
}

/// [downsampleCardScreenshot] 的后台 isolate 变体（BUG-933）。
///
/// 根因：制卡封面（libmpv 原始解码帧，可能 1080p/4K）的 `img.decodeImage` +
/// `copyResize`(lanczos) + `encodeJpg` 是纯 Dart CPU 重活，几十到几百 ms；旧代码在
/// **UI isolate** 同步 `await` 这条链（`immersion_mining_engine` / reader 选区插图），
/// 制卡截图那一下明显卡顿/未响应。这里整体卸到后台 isolate（[Isolate.run]，与
/// `encodeClipTextFrameAsJpgAsync` 同范式）：传 [Uint8List] 进、[Uint8List] 出，
/// `package:image` 对象只在后台 isolate 内生灭，UI 线程不再被解码/编码阻塞。
///
/// 语义与同步版一致：小图/无法解码时原样返回入参字节（跨 isolate 拷贝后内容相等，
/// 不再是 `identical`，但绝不返回空/破坏媒体）。
Future<Uint8List> downsampleCardScreenshotAsync(
  Uint8List bytes, {
  int maxLongEdge = 1000,
  int quality = 90,
  CardScreenshotEncoding encoding = CardScreenshotEncoding.jpeg,
}) {
  if (bytes.isEmpty) return Future<Uint8List>.value(bytes);
  return Isolate.run<Uint8List>(
    () => downsampleCardScreenshot(
      bytes,
      maxLongEdge: maxLongEdge,
      quality: quality,
      encoding: encoding,
    ),
  );
}
