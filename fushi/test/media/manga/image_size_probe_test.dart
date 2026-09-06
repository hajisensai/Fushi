import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:fushi/src/media/manga/import/image_size_probe.dart';

/// 头部探测的宽高必须与「整张解码 + bakeOrientation」的宽高逐格式一致——
/// 漫画导入写进 manga.json 的尺寸从此只读文件头，口径不能漂。
void main() {
  ({int width, int height}) baked(Uint8List bytes) {
    final img.Image oriented = img.bakeOrientation(img.decodeImage(bytes)!);
    return (width: oriented.width, height: oriented.height);
  }

  test('PNG: IHDR 尺寸', () {
    final Uint8List bytes = img.encodePng(img.Image(width: 30, height: 20));
    expect(probeOrientedImageSize(bytes), (width: 30, height: 20));
    expect(probeOrientedImageSize(bytes), baked(bytes));
  });

  test('JPEG 无 EXIF：SOF 尺寸，orientation 视为 1', () {
    final Uint8List bytes = img.encodeJpg(img.Image(width: 30, height: 20));
    expect(jpegExifOrientation(bytes), 1);
    expect(probeOrientedImageSize(bytes), (width: 30, height: 20));
    expect(probeOrientedImageSize(bytes), baked(bytes));
  });

  for (final int orientation in <int>[1, 2, 3, 4, 5, 6, 7, 8]) {
    test('JPEG EXIF orientation=$orientation 与 bakeOrientation 一致', () {
      final img.Image image = img.Image(width: 30, height: 20);
      image.exif.imageIfd.orientation = orientation;
      final Uint8List bytes = img.encodeJpg(image);
      expect(jpegExifOrientation(bytes), orientation);
      final ({int width, int height})? probed = probeOrientedImageSize(bytes);
      expect(probed, baked(bytes));
      expect(
        probed,
        orientation >= 5 ? (width: 20, height: 30) : (width: 30, height: 20),
      );
    });
  }

  test('BMP：各自的头', () {
    final img.Image image = img.Image(width: 24, height: 16);
    expect(
        probeOrientedImageSize(img.encodeBmp(image)), (width: 24, height: 16));
  });

  test('GIF 返回 null：逻辑屏幕尺寸 != 帧尺寸，不能拿它冒充', () {
    // `GifDecoder.startDecode` 返回的是**逻辑屏幕描述符**，而 `decodeImage` 建的
    // Image 用的是**帧描述符**。帧小于逻辑屏幕的 GIF（转档/裁剪工具常见）两者不是
    // 一回事，头探测会给出画布尺寸而不是实际图像尺寸——下游据此判 spread/webtoon
    // 会判反、OCR 框坐标整体错位，且全程不报错。既然对不上就交回整张解码。
    final Uint8List gif = img.encodeGif(img.Image(width: 24, height: 16));
    expect(probeOrientedImageSize(gif), isNull,
        reason: 'GIF 必须回退整张解码，不能用逻辑屏幕尺寸');
    // 回退路径本身仍给出正确尺寸（调用方就是这么兜的）。
    expect(baked(gif), (width: 24, height: 16));
  });

  group('WebP EXIF orientation（bakeOrientation 与格式无关，WebP 也会被它旋转）', () {
    // image 4.3.0 的 WebP 解码器确实会填 image.exif（有损 VP8 / 无损 VP8L 两条路径
    // 都写），所以 `bakeOrientation` 对带 orientation 的 WebP 会换轴。只给 JPEG 开
    // 这道门就把 WebP 的旋转丢了，而 `.webp` 就在受理的漫画页扩展名里。
    //
    // 这里手搓 RIFF 容器而不是用 img.encodeWebP —— image 包不提供 WebP 编码。
    // 合成的是最小 VP8L：signature 0x2F + 14bit(w-1) + 14bit(h-1) + alpha + version。
    Uint8List u32le(int v) =>
        Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

    Uint8List vp8lPayload(int w, int h) {
      final int bits = (w - 1) | ((h - 1) << 14);
      return Uint8List.fromList(<int>[
        0x2F,
        bits & 0xFF,
        (bits >> 8) & 0xFF,
        (bits >> 16) & 0xFF,
        (bits >> 24) & 0xFF,
        0x00,
      ]);
    }

    void addChunk(BytesBuilder out, String fourcc, Uint8List payload) {
      out.add(fourcc.codeUnits);
      out.add(u32le(payload.length));
      out.add(payload);
      if (payload.length.isOdd) out.addByte(0);
    }

    Uint8List buildWebp(int w, int h, {Uint8List? exif}) {
      final BytesBuilder body = BytesBuilder();
      addChunk(body, 'VP8L', vp8lPayload(w, h));
      if (exif != null) addChunk(body, 'EXIF', exif);
      final Uint8List inner = body.toBytes();
      final BytesBuilder out = BytesBuilder();
      out.add('RIFF'.codeUnits);
      out.add(u32le(4 + inner.length));
      out.add('WEBP'.codeUnits);
      out.add(inner);
      return out.toBytes();
    }

    /// 小端 TIFF，IFD0 里恰好一条 Orientation = SHORT(v)。
    Uint8List tiffOrientation(int v, {bool withExifPrefix = false}) {
      final BytesBuilder b = BytesBuilder();
      if (withExifPrefix) b.add(<int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00]);
      b.add(<int>[0x49, 0x49, 0x2A, 0x00]);
      b.add(u32le(8));
      b.add(<int>[0x01, 0x00]);
      b.add(<int>[0x12, 0x01]);
      b.add(<int>[0x03, 0x00]);
      b.add(u32le(1));
      b.add(<int>[v & 0xFF, (v >> 8) & 0xFF, 0x00, 0x00]);
      b.add(u32le(0));
      return b.toBytes();
    }

    for (final int orientation in <int>[1, 3, 6, 8]) {
      test('orientation=$orientation：>=5 换轴，其余不动', () {
        final Uint8List bytes =
            buildWebp(24, 16, exif: tiffOrientation(orientation));
        expect(webpExifOrientation(bytes), orientation);
        expect(
          probeOrientedImageSize(bytes),
          orientation >= 5 ? (width: 16, height: 24) : (width: 24, height: 16),
          reason: 'orientation 5~8 是转了 90° 的方向，宽高必须对调',
        );
      });
    }

    test('EXIF chunk 带 Exif 前缀（六字节 Exif + 两个 NUL）的编码器也要认', () {
      final Uint8List bytes = buildWebp(24, 16,
          exif: tiffOrientation(6, withExifPrefix: true));
      expect(webpExifOrientation(bytes), 6);
      expect(probeOrientedImageSize(bytes), (width: 16, height: 24));
    });

    test('没有 EXIF chunk / 不是 WebP：一律 1（未旋转）', () {
      // 用一个填充 chunk 把字节喂够（最小 VP8L 头本身不足以让 startDecode 走完）。
      final Uint8List padded =
          buildWebp(24, 16, exif: Uint8List.fromList(<int>[0, 0, 0, 0]));
      expect(webpExifOrientation(padded), 1);
      expect(probeOrientedImageSize(padded), (width: 24, height: 16));
      expect(webpExifOrientation(img.encodeJpg(img.Image(width: 4, height: 4))),
          1);
      expect(webpExifOrientation(Uint8List.fromList(<int>[1, 2, 3])), 1);
      expect(webpExifOrientation(Uint8List(0)), 1);
    });
  });

  test('非图片 / 截断返回 null（调用方回退整张解码）', () {
    expect(probeOrientedImageSize(Uint8List.fromList(<int>[1, 2, 3])), isNull);
    expect(probeOrientedImageSize(Uint8List(0)), isNull);
    final Uint8List jpg = img.encodeJpg(img.Image(width: 30, height: 20));
    // 只剩 SOI 的截断 JPEG：orientation 兜底 1，不越界。
    expect(jpegExifOrientation(Uint8List.sublistView(jpg, 0, 3)), 1);
  });
}
