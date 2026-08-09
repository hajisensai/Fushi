import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 生成**真实体量**的 PNG，用于让性能测试面对与真实书插图同量级的读盘 + 解码成本。
///
/// 合成 EPUB 此前的「图片章」用的是内联 SVG——解码几乎免费，于是跨章计时里
/// `docLoad` 完全测不到图片这一段，跟真实书（整页插图 1600×2400、几百 KB~MB 级）
/// 差了一个数量级。这里按坐标生成渐变叠低频噪声的 RGB 像素：像素数决定解码成本、
/// 噪声决定压缩后体积，两者都能落到真实插图的量级。
class TestImageGenerator {
  const TestImageGenerator();

  /// 生成 [width]×[height] 的 RGB PNG 字节。[seed] 改变噪声花纹，让同一本书里的
  /// 多张插图字节不同（避免 WebView 按同一 URL/内容走缓存而测不到真实成本）。
  Uint8List pngBytes({
    int width = 1600,
    int height = 2400,
    int seed = 1,
  }) {
    // 每行 1 字节 filter(0=None) + width*3 字节 RGB。
    final Uint8List raw = Uint8List(height * (1 + width * 3));
    int p = 0;
    int rnd = seed * 2654435761 & 0x7fffffff;
    for (int y = 0; y < height; y++) {
      raw[p++] = 0; // filter: None
      for (int x = 0; x < width; x++) {
        // 低频渐变（可压缩）+ 每像素噪声（不可压缩），让压缩后体积落在真实插图量级。
        rnd = (rnd * 1103515245 + 12345) & 0x7fffffff;
        final int noise = (rnd >> 16) & 0x1f;
        raw[p++] = ((x * 255) ~/ width + noise) & 0xff;
        raw[p++] = ((y * 255) ~/ height + noise) & 0xff;
        raw[p++] = (((x + y) * 255) ~/ (width + height) + noise) & 0xff;
      }
    }

    final BytesBuilder out = BytesBuilder();
    out.add(<int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    out.add(_chunk('IHDR', _ihdr(width, height)));
    out.add(_chunk('IDAT', Uint8List.fromList(zlib.encode(raw))));
    out.add(_chunk('IEND', Uint8List(0)));
    return out.toBytes();
  }

  Uint8List _ihdr(int width, int height) {
    final ByteData d = ByteData(13);
    d.setUint32(0, width);
    d.setUint32(4, height);
    d.setUint8(8, 8); // bit depth
    d.setUint8(9, 2); // color type: truecolour RGB
    d.setUint8(10, 0); // compression
    d.setUint8(11, 0); // filter
    d.setUint8(12, 0); // interlace
    return d.buffer.asUint8List();
  }

  Uint8List _chunk(String type, Uint8List data) {
    final Uint8List typeBytes = Uint8List.fromList(ascii.encode(type));
    final BytesBuilder b = BytesBuilder();
    final ByteData len = ByteData(4)..setUint32(0, data.length);
    b.add(len.buffer.asUint8List());
    b.add(typeBytes);
    b.add(data);
    final ByteData crc = ByteData(4)
      ..setUint32(0, _crc32(<int>[...typeBytes, ...data]));
    b.add(crc.buffer.asUint8List());
    return b.toBytes();
  }

  static final List<int> _crcTable = _buildCrcTable();

  static List<int> _buildCrcTable() {
    final List<int> table = List<int>.filled(256, 0);
    for (int n = 0; n < 256; n++) {
      int c = n;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      table[n] = c;
    }
    return table;
  }

  static int _crc32(List<int> bytes) {
    int c = 0xFFFFFFFF;
    for (final int b in bytes) {
      c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
    }
    return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
  }
}
