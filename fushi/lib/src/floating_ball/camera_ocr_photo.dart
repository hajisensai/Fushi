/// 拍照查词的照片规整：把相机照片变成「像素方向即显示方向」的送检图。
///
/// 为什么非做不可：相机 JPEG 的方向多半只写在 EXIF 里（竖着拿手机拍，像素仍是
/// 横的），而 Android 系统 OCR 通道用 `BitmapFactory.decodeByteArray` 解码，不看
/// EXIF——不烘焙的话识别器看到的是躺倒的字，行框坐标也和选取页上（Flutter 按
/// EXIF 转正后）画出来的图对不上。烘焙后送检图与选取页显示的是同一组像素。
///
/// 顺带把长边压到 [kCameraOcrMaxSide]：一千多万像素的原图对行级 OCR 没有好处，
/// 只会拖慢识别与解码。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 送检照片的最长边（像素）。
const int kCameraOcrMaxSide = 2560;

/// 相机照片 → 送检图（JPEG，无 EXIF 方向）。已经是正向且不超尺寸的原样返回；
/// 解不出来返回 null。纯函数，可放进 `compute` 跑。
Uint8List? normalizeCameraOcrPhoto(Uint8List bytes) {
  final img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on RangeError {
    // image 的格式嗅探器碰到截断 / 非图片字节会越界读，而不是返回 null。
    return null;
  } on img.ImageException {
    return null;
  }
  if (decoded == null) return null;
  final int? orientation = decoded.exif.imageIfd.hasOrientation
      ? decoded.exif.imageIfd.orientation
      : null;
  final bool rotated = orientation != null && orientation != 1;
  img.Image image = rotated ? img.bakeOrientation(decoded) : decoded;
  final bool oversized =
      math.max(image.width, image.height) > kCameraOcrMaxSide;
  if (!rotated && !oversized) return bytes;
  if (oversized) {
    image = image.width >= image.height
        ? img.copyResize(image, width: kCameraOcrMaxSide)
        : img.copyResize(image, height: kCameraOcrMaxSide);
  }
  // 像素已经转正：不带 EXIF 写出，免得哪一端再按残留的方向转一次。
  image.exif = img.ExifData();
  return img.encodeJpg(image, quality: 90);
}
