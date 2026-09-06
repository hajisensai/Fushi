import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 只读文件头取页图的（已按 EXIF 方向摆正的）宽高，**不解码像素**。
///
/// 漫画导入对每一页只需要宽高写进 `manga.json`，以前却 `img.decodeImage` +
/// `bakeOrientation` 整张解出来（纯 Dart 解一张 2000×3000 的 JPEG 要几十毫秒、
/// 二十几 MB 堆），200 页就是好几秒的 UI 卡顿。这里走各格式的 `startDecode`
/// （JPEG 只读到 SOF、PNG 只读 IHDR、WebP 只读 VP8 头），JPEG 另外读 APP1 里的
/// EXIF Orientation：5~8 是转了 90° 的方向，宽高对调——与 `bakeOrientation`
/// 后的尺寸一致（守卫 `image_size_probe_test.dart` 用真编码的图逐一对照）。
///
/// 不认识的格式 / 损坏文件返回 null，调用方回退整张解码（行为与从前一致）。
({int width, int height})? probeOrientedImageSize(Uint8List bytes) {
  final img.Decoder? decoder;
  final img.DecodeInfo? info;
  try {
    // 太短的输入会让某些格式的 isValidFile 越界读，与损坏文件同样按「认不出」处理。
    decoder = img.findDecoderForData(bytes);
    if (decoder == null) return null;
    info = decoder.startDecode(bytes);
  } catch (_) {
    return null;
  }
  if (info == null || info.width <= 0 || info.height <= 0) return null;
  int width = info.width;
  int height = info.height;
  if (decoder is img.JpegDecoder) {
    final int orientation = jpegExifOrientation(bytes);
    if (orientation >= 5 && orientation <= 8) {
      final int swap = width;
      width = height;
      height = swap;
    }
  }
  return (width: width, height: height);
}

/// JPEG APP1 Exif 段 IFD0 里的 Orientation（tag 0x0112，1~8）。缺失 / 不是
/// JPEG / 解析不出一律返回 1（未旋转）。只顺着 marker 链走到 SOS 之前，不碰像素。
int jpegExifOrientation(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return 1;
  int i = 2;
  while (i + 3 < bytes.length) {
    if (bytes[i] != 0xFF) return 1;
    final int marker = bytes[i + 1];
    // 无长度的独立 marker（SOI / TEM / RSTn）与填充 0xFF。
    if (marker == 0xFF) {
      i += 1;
      continue;
    }
    if (marker == 0xD8 ||
        marker == 0x01 ||
        (marker >= 0xD0 && marker <= 0xD7)) {
      i += 2;
      continue;
    }
    // SOS / EOI：像素段开始，EXIF 不可能在后面。
    if (marker == 0xDA || marker == 0xD9) return 1;
    final int segmentLength = (bytes[i + 2] << 8) | bytes[i + 3];
    if (segmentLength < 2) return 1;
    final int segmentStart = i + 4;
    final int segmentEnd = i + 2 + segmentLength;
    if (segmentEnd > bytes.length) return 1;
    if (marker == 0xE1 &&
        segmentLength >= 8 &&
        _isExifHeader(bytes, segmentStart)) {
      return _orientationFromTiff(bytes, segmentStart + 6, segmentEnd);
    }
    i = segmentEnd;
  }
  return 1;
}

bool _isExifHeader(Uint8List bytes, int at) =>
    at + 6 <= bytes.length &&
    bytes[at] == 0x45 && // E
    bytes[at + 1] == 0x78 && // x
    bytes[at + 2] == 0x69 && // i
    bytes[at + 3] == 0x66 && // f
    bytes[at + 4] == 0x00 &&
    bytes[at + 5] == 0x00;

int _orientationFromTiff(Uint8List bytes, int tiff, int end) {
  if (tiff + 8 > end) return 1;
  final Endian endian;
  if (bytes[tiff] == 0x49 && bytes[tiff + 1] == 0x49) {
    endian = Endian.little;
  } else if (bytes[tiff] == 0x4D && bytes[tiff + 1] == 0x4D) {
    endian = Endian.big;
  } else {
    return 1;
  }
  final ByteData data = ByteData.sublistView(bytes, tiff, end);
  if (data.getUint16(2, endian) != 0x002A) return 1;
  final int ifd = data.getUint32(4, endian);
  if (ifd + 2 > data.lengthInBytes) return 1;
  final int entries = data.getUint16(ifd, endian);
  for (int n = 0; n < entries; n++) {
    final int entry = ifd + 2 + n * 12;
    if (entry + 12 > data.lengthInBytes) return 1;
    if (data.getUint16(entry, endian) != 0x0112) continue;
    // type SHORT(3) count 1：值就地存在 offset 字段前两个字节。
    if (data.getUint16(entry + 2, endian) != 3) return 1;
    final int value = data.getUint16(entry + 8, endian);
    return (value >= 1 && value <= 8) ? value : 1;
  }
  return 1;
}
