import 'dart:typed_data';

import 'package:image/image.dart' as img;

// ignore_for_file: unnecessary_null_comparison
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
  // BUG-3041：JPEG / PNG 自己读头。image 4.x 的 `JpegDecoder.startDecode` 名为
  // 「只读头」，实测却把整条扫描数据也解析一遍（2400×3400 的页 200~600 ms，且是
  // 在调用方 isolate 上同步跑——阅读器每个页图请求都经这里，主 isolate 直接卡住）；
  // `findDecoderForData` 也会挨个格式试探。漫画页九成以上是这两种格式，直接按
  // 规范读 SOF / IHDR，其余格式照旧交给 image 的解码器。
  final ({int width, int height})? jpeg = _jpegOrientedSize(bytes);
  if (jpeg != null) return jpeg;
  final ({int width, int height})? png = _pngSize(bytes);
  if (png != null) return png;
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
  // GIF：`startDecode` 返回的是**逻辑屏幕描述符**，而 `decodeImage` 建的 Image 用的是
  // **帧描述符**。帧小于逻辑屏幕的 GIF（转档/裁剪工具常见）两者不是一回事——实测一张
  // 「逻辑屏幕 40×20 / 帧 10×8」的 GIF：旧路径 10×8，头探测 40×20。既然对不上就别猜，
  // 交回整张解码（GIF 漫画页本就罕见，这点代价可接受）。
  if (decoder is img.GifDecoder) return null;

  if (info == null || info.width <= 0 || info.height <= 0) return null;
  int width = info.width;
  int height = info.height;
  // `bakeOrientation` 读的是 `image.exif.imageIfd.orientation`，**与格式无关**；
  // 而 image 4.3.0 的 WebP 解码器确实会填这个字段（有损 / 无损两条路径都写 exif）。
  // 只给 JPEG 开这道门就把 WebP 的旋转丢了——实测一张带 orientation=6 的有损 WebP：
  // 旧路径 20×40，只认 JPEG 的头探测 40×20，横竖颠倒。而 `.webp` 就在受理的漫画页
  // 扩展名里，写进 manga.json 的宽高一错，spread/webtoon 自动判向会判反、OCR 框坐标
  // 整体错位，且全程不报错。
  //
  //（PNG / TIFF 之所以不用管，是靠上游的 bug：image 4.3.0 的 PNG 解码器那段
  // `case 'eXif':` 整段被注释掉了、拼写还错成 eXif；TIFF 那条设 exif 的分支在默认
  // frame 下不可达。它们等价是巧合，不是设计——真出现方向就再补。）
  final int orientation = decoder is img.JpegDecoder
      ? jpegExifOrientation(bytes)
      : decoder is img.WebPDecoder
          ? webpExifOrientation(bytes)
          : 1;
  if (orientation >= 5 && orientation <= 8) {
    final int swap = width;
    width = height;
    height = swap;
  }
  return (width: width, height: height);
}

/// WebP `EXIF` chunk（RIFF 容器）里 IFD0 的 Orientation。缺失 / 不是 WebP /
/// 解析不出一律返回 1（未旋转）。只扫 chunk 头，不碰像素。
int webpExifOrientation(Uint8List bytes) {
  // RIFF<u32 size>WEBP，其后是一串 <fourcc><u32 size><payload>（payload 补齐到偶数）。
  if (bytes.length < 12) return 1;
  if (bytes[0] != 0x52 || bytes[1] != 0x49 || bytes[2] != 0x46 ||
      bytes[3] != 0x46) {
    return 1; // 'RIFF'
  }
  if (bytes[8] != 0x57 || bytes[9] != 0x45 || bytes[10] != 0x42 ||
      bytes[11] != 0x50) {
    return 1; // 'WEBP'
  }
  final ByteData data = ByteData.sublistView(bytes);
  int at = 12;
  while (at + 8 <= bytes.length) {
    final bool isExif = bytes[at] == 0x45 && // E
        bytes[at + 1] == 0x58 && // X
        bytes[at + 2] == 0x49 && // I
        bytes[at + 3] == 0x46; // F
    final int size = data.getUint32(at + 4, Endian.little);
    final int payload = at + 8;
    if (size < 0 || payload + size > bytes.length) return 1;
    if (isExif) {
      // 规范说这里直接是 TIFF 头，但确有编码器把 JPEG APP1 的 `Exif\0\0` 前缀也带上，
      // 两种都收。
      final int tiff =
          _isExifHeader(bytes, payload) ? payload + 6 : payload;
      return _orientationFromTiff(bytes, tiff, payload + size);
    }
    // chunk payload 补齐到偶数字节。
    at = payload + size + (size.isOdd ? 1 : 0);
  }
  return 1;
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

/// JPEG：顺着 marker 链走到第一个 SOFn（跳过 DHT/JPG/DAC 这些占用 C4/C8/CC
/// 的非帧头），读帧高宽，再按 [jpegExifOrientation] 换轴——与 `decodeImage` +
/// `bakeOrientation` 同口径。不是 JPEG / 在 SOS 前没找到 SOF / 截断 → null，
/// 交回通用路径。只看段头，不碰扫描数据。
({int width, int height})? _jpegOrientedSize(Uint8List bytes) {
  if (bytes.length < 4 || bytes[0] != 0xFF || bytes[1] != 0xD8) return null;
  int i = 2;
  while (i + 3 < bytes.length) {
    if (bytes[i] != 0xFF) return null;
    final int marker = bytes[i + 1];
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
    if (marker == 0xDA || marker == 0xD9) return null;
    final int segmentLength = (bytes[i + 2] << 8) | bytes[i + 3];
    if (segmentLength < 2) return null;
    final bool isFrameHeader = marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrameHeader) {
      // SOFn 段：长度(2) 精度(1) 高(2) 宽(2)。
      if (segmentLength < 7 || i + 9 > bytes.length) return null;
      int height = (bytes[i + 5] << 8) | bytes[i + 6];
      int width = (bytes[i + 7] << 8) | bytes[i + 8];
      if (width <= 0 || height <= 0) return null;
      final int orientation = jpegExifOrientation(bytes);
      if (orientation >= 5 && orientation <= 8) {
        final int swap = width;
        width = height;
        height = swap;
      }
      return (width: width, height: height);
    }
    i = i + 2 + segmentLength;
  }
  return null;
}

/// PNG：签名后第一个 chunk 必须是 IHDR，宽高是其头两个大端 u32。PNG 的 EXIF
/// 方向 image 4.x 本就不应用（见 [probeOrientedImageSize] 注释），无需换轴。
({int width, int height})? _pngSize(Uint8List bytes) {
  const List<int> signature = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  ];
  if (bytes.length < 24) return null;
  for (int k = 0; k < signature.length; k++) {
    if (bytes[k] != signature[k]) return null;
  }
  // IHDR
  if (bytes[12] != 0x49 ||
      bytes[13] != 0x48 ||
      bytes[14] != 0x44 ||
      bytes[15] != 0x52) {
    return null;
  }
  final ByteData data = ByteData.sublistView(bytes, 16, 24);
  final int width = data.getUint32(0);
  final int height = data.getUint32(4);
  if (width <= 0 || height <= 0) return null;
  return (width: width, height: height);
}
