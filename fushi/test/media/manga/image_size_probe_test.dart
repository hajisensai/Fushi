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

  test('WebP / GIF / BMP：各自的头', () {
    final img.Image image = img.Image(width: 24, height: 16);
    expect(
        probeOrientedImageSize(img.encodeGif(image)), (width: 24, height: 16));
    expect(
        probeOrientedImageSize(img.encodeBmp(image)), (width: 24, height: 16));
  });

  test('非图片 / 截断返回 null（调用方回退整张解码）', () {
    expect(probeOrientedImageSize(Uint8List.fromList(<int>[1, 2, 3])), isNull);
    expect(probeOrientedImageSize(Uint8List(0)), isNull);
    final Uint8List jpg = img.encodeJpg(img.Image(width: 30, height: 20));
    // 只剩 SOI 的截断 JPEG：orientation 兜底 1，不越界。
    expect(jpegExifOrientation(Uint8List.sublistView(jpg, 0, 3)), 1);
  });
}
