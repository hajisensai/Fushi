import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/floating_ball/camera_ocr_photo.dart';
import 'package:image/image.dart' as img;

/// 相机那样的 JPEG：像素 [width]×[height]，方向只写在 EXIF 里。左上角涂红，
/// 用来确认旋转方向。
Uint8List _photo(int width, int height, {int? orientation}) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(255, 255, 255));
  img.fillRect(
    image,
    x1: 0,
    y1: 0,
    x2: width ~/ 4,
    y2: height ~/ 4,
    color: img.ColorRgb8(255, 0, 0),
  );
  if (orientation != null) image.exif.imageIfd.orientation = orientation;
  return img.encodeJpg(image, quality: 95);
}

void main() {
  test('EXIF 方向烘焙进像素：竖拿手机拍的横像素照片转成竖图，且不再带方向', () {
    // orientation 6 = 顺时针转 90° 才是正向。
    final Uint8List? out = normalizeCameraOcrPhoto(
      _photo(400, 200, orientation: 6),
    );
    expect(out, isNotNull);
    final img.Image decoded = img.decodeJpg(out!)!;
    expect(decoded.width, 200);
    expect(decoded.height, 400);
    final int? orientation = decoded.exif.imageIfd.hasOrientation
        ? decoded.exif.imageIfd.orientation
        : null;
    expect(orientation == null || orientation == 1, isTrue);
    // 顺时针转 90°：原左上角的红块到了右上角。
    final img.Pixel topRight = decoded.getPixel(190, 10);
    expect(topRight.r, greaterThan(200));
    expect(topRight.g, lessThan(80));
    final img.Pixel topLeft = decoded.getPixel(10, 10);
    expect(topLeft.g, greaterThan(200));
  });

  test('已经是正向且不超尺寸：原样返回，不重新编码', () {
    final Uint8List upright = _photo(300, 400);
    expect(identical(normalizeCameraOcrPhoto(upright), upright), isTrue);
    final Uint8List tagged = _photo(300, 400, orientation: 1);
    expect(identical(normalizeCameraOcrPhoto(tagged), tagged), isTrue);
  });

  test('长边超过上限时等比压到上限', () {
    final Uint8List? out = normalizeCameraOcrPhoto(
      _photo(kCameraOcrMaxSide * 2, kCameraOcrMaxSide),
    );
    final img.Image decoded = img.decodeJpg(out!)!;
    expect(decoded.width, kCameraOcrMaxSide);
    expect(decoded.height, kCameraOcrMaxSide ~/ 2);
  });

  test('解不出来的字节返回 null', () {
    expect(normalizeCameraOcrPhoto(Uint8List.fromList(<int>[1, 2, 3])), isNull);
  });
}
