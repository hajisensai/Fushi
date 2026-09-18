/// 插图宽高比探针：只读文件头部拿像素宽高，供插图册决定横版图占几列。
///
/// 网格卡片是竖版比例（`_kCardAspectRatio`），横版双页图塞进去只能裁掉两侧
/// （BUG-2589）。要让它横跨两列，布局前就得知道每张图是横是竖——而布局是解析式
/// 的（滚动定位靠列数 / 行高推算），不能等缩略图解码完再改行数，否则打开时
/// 定位到当前章的偏移会在图片陆续解码时漂走。所以开页时用 [compute] 在 isolate
/// 里批量读头部：PNG / GIF / BMP / WebP 的尺寸都在前几十字节，JPEG 要走到 SOFn
/// 段（EXIF / ICC 大的文件会靠后），先读 [kIllustrationProbeHeadBytes]，走不到
/// 再整文件读一次。不认识的格式（SVG 等）返回 null，按竖版处理。
library;

import 'dart:io';
import 'dart:typed_data';

/// 第一次只读这么多字节（64 KiB）：覆盖绝大多数 JPEG 的 SOF 位置，也让几百张图
/// 的批量探测停留在毫秒级。
const int kIllustrationProbeHeadBytes = 64 * 1024;

/// `compute()` 入口：逐个文件读头部解析宽高，返回「路径 → 宽/高」。解析不出 /
/// 读不到的文件不进结果。
Map<String, double> probeIllustrationAspectRatios(List<String> paths) {
  final Map<String, double> result = <String, double>{};
  for (final String path in paths) {
    final double? ratio = _probeFile(path);
    if (ratio != null) result[path] = ratio;
  }
  return result;
}

double? _probeFile(String path) {
  final File file = File(path);
  final int length;
  try {
    length = file.lengthSync();
  } on FileSystemException {
    return null;
  }
  if (length <= 0) return null;
  Uint8List head;
  try {
    final RandomAccessFile raf = file.openSync();
    try {
      head = raf.readSync(kIllustrationProbeHeadBytes);
    } finally {
      raf.closeSync();
    }
  } on FileSystemException {
    return null;
  }
  final double? fromHead = imageAspectRatioFromHeader(head);
  if (fromHead != null || length <= head.length) return fromHead;
  // 头部里没走到尺寸信息（大 EXIF / ICC 的 JPEG）：整文件再来一次。
  try {
    return imageAspectRatioFromHeader(file.readAsBytesSync());
  } on FileSystemException {
    return null;
  }
}

/// 从图片文件头解析「宽 / 高」；认不出格式、字节不够、尺寸非法时 null。
/// 纯函数，[bytes] 可以是被截断的文件头。
double? imageAspectRatioFromHeader(Uint8List bytes) {
  final ({int width, int height})? size = imageSizeFromHeader(bytes);
  if (size == null || size.width <= 0 || size.height <= 0) return null;
  return size.width / size.height;
}

/// 从图片文件头解析像素尺寸。支持 PNG / JPEG / GIF / BMP / WebP（VP8 / VP8L /
/// VP8X）；其它格式或字节不够返回 null。
({int width, int height})? imageSizeFromHeader(Uint8List bytes) {
  final ByteData data = ByteData.sublistView(bytes);
  if (_startsWith(bytes, const <int>[0x89, 0x50, 0x4E, 0x47])) {
    // PNG：IHDR 固定在第 16 字节起，宽高各 4 字节大端。
    if (bytes.length < 24) return null;
    return (width: data.getUint32(16), height: data.getUint32(20));
  }
  if (_startsWith(bytes, const <int>[0x47, 0x49, 0x46, 0x38])) {
    // GIF：逻辑屏幕宽高在第 6 字节起，各 2 字节小端。
    if (bytes.length < 10) return null;
    return (
      width: data.getUint16(6, Endian.little),
      height: data.getUint16(8, Endian.little),
    );
  }
  if (_startsWith(bytes, const <int>[0x42, 0x4D])) {
    // BMP：BITMAPINFOHEADER 的宽高在第 18 字节起，各 4 字节小端（高可为负 =
    // 自顶向下，取绝对值）。
    if (bytes.length < 26) return null;
    return (
      width: data.getInt32(18, Endian.little),
      height: data.getInt32(22, Endian.little).abs(),
    );
  }
  if (_startsWith(bytes, const <int>[0x52, 0x49, 0x46, 0x46]) &&
      bytes.length >= 16 &&
      _startsWith(bytes.sublist(8, 12), const <int>[0x57, 0x45, 0x42, 0x50])) {
    return _webpSize(bytes, data);
  }
  if (_startsWith(bytes, const <int>[0xFF, 0xD8])) {
    return _jpegSize(bytes, data);
  }
  return null;
}

({int width, int height})? _webpSize(Uint8List bytes, ByteData data) {
  if (bytes.length < 30) return null;
  final String chunk = String.fromCharCodes(bytes.sublist(12, 16));
  switch (chunk) {
    case 'VP8 ':
      // 有损：帧头第 6 字节起是起始码 9D 01 2A，随后宽高各 14 位小端。
      if (bytes[23] != 0x9D || bytes[24] != 0x01 || bytes[25] != 0x2A) {
        return null;
      }
      return (
        width: data.getUint16(26, Endian.little) & 0x3FFF,
        height: data.getUint16(28, Endian.little) & 0x3FFF,
      );
    case 'VP8L':
      // 无损：签名字节 2F 后 28 位打包成 (宽-1, 高-1) 各 14 位。
      if (bytes[20] != 0x2F) return null;
      final int b0 = bytes[21], b1 = bytes[22], b2 = bytes[23], b3 = bytes[24];
      return (
        width: 1 + (((b1 & 0x3F) << 8) | b0),
        height: 1 + (((b3 & 0x0F) << 10) | (b2 << 2) | ((b1 & 0xC0) >> 6)),
      );
    case 'VP8X':
      // 扩展：画布宽高各 24 位小端，存的是「宽-1」「高-1」。
      return (
        width: 1 + (bytes[24] | (bytes[25] << 8) | (bytes[26] << 16)),
        height: 1 + (bytes[27] | (bytes[28] << 8) | (bytes[29] << 16)),
      );
  }
  return null;
}

/// JPEG：从 SOI 后逐段走 marker，直到 SOFn（C0~CF，去掉 C4 / C8 / CC 三个非帧
/// 段）；帧头第 3 字节起是高、宽各 2 字节大端。字节在走到之前用完返回 null，
/// 调用方据此决定要不要整文件重读。
({int width, int height})? _jpegSize(Uint8List bytes, ByteData data) {
  int offset = 2;
  while (offset + 4 <= bytes.length) {
    if (bytes[offset] != 0xFF) return null;
    final int marker = bytes[offset + 1];
    if (marker == 0xFF) {
      // 填充字节。
      offset += 1;
      continue;
    }
    if (marker == 0xD8 ||
        (marker >= 0xD0 && marker <= 0xD7) ||
        marker == 0x01) {
      // 无长度段。
      offset += 2;
      continue;
    }
    if (marker == 0xD9 || marker == 0xDA) {
      // EOI / SOS 之前都没见到 SOF：不是能解析的帧结构。
      return null;
    }
    final int segmentLength = data.getUint16(offset + 2);
    if (segmentLength < 2) return null;
    final bool isSof =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isSof) {
      if (offset + 9 > bytes.length) return null;
      return (
        width: data.getUint16(offset + 7),
        height: data.getUint16(offset + 5),
      );
    }
    offset += 2 + segmentLength;
  }
  return null;
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (int i = 0; i < prefix.length; i++) {
    if (bytes[i] != prefix[i]) return false;
  }
  return true;
}
