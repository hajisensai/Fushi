// 排行榜封面的感知哈希（dHash，64 位）。
//
// 服务端按它把不同用户提交的「同一张封面」归为同一候选（services/leaderboard/src/cover_votes.js：
// 汉明距离 ≤ COVER_HASH_MAX_DISTANCE = [kCoverHashMaxDistance] 视为同一张图），同一候选只存一份
// 缩略图，票数按人头计。算法：
//   1. 灰度（ITU-R BT.601 亮度）；
//   2. 按面积平均缩成 9×8（每个源像素按坐标落进一个格子，格内求平均——与源尺寸无关）；
//   3. 每行相邻两格比较，左格比右格亮记 1，共 8×8 = 64 位，行优先、高位在前；
//   4. 输出 16 位小写 hex。
// 面积平均对 JPEG 压缩噪点、缩放插值差异不敏感：同一张图不同质量 / 尺寸的缩略图只差几位。

import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:fushi_engine/leaderboard/local_shelf.dart';

/// 与服务端 `COVER_HASH_MAX_DISTANCE` 一致：汉明距离不超过它视为同一张图。
const int kCoverHashMaxDistance = 10;

const int _cols = 9;
const int _rows = 8;

/// 图片字节（JPEG / PNG / WebP 等 `image` 包能解的格式）的 dHash；解不开返回 null。
String? coverDHash(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    // 损坏 / 过短的字节在嗅探解码器时会抛 RangeError 等，统一按「解不开」处理。
    decoded = null;
  }
  if (decoded == null || decoded.width < 1 || decoded.height < 1) return null;
  return coverDHashOfImage(decoded);
}

/// 已解码图片的 dHash（见文件头）。
String coverDHashOfImage(img.Image image) {
  final int w = image.width;
  final int h = image.height;
  final List<double> sum = List<double>.filled(_cols * _rows, 0);
  final List<int> count = List<int>.filled(_cols * _rows, 0);
  for (final img.Pixel p in image) {
    final int cx = p.x * _cols ~/ w;
    final int cy = p.y * _rows ~/ h;
    final int cell = cy * _cols + cx;
    sum[cell] +=
        0.299 * p.rNormalized + 0.587 * p.gNormalized + 0.114 * p.bNormalized;
    count[cell]++;
  }
  // 源图比 9×8 还小时有空格子：取同一行左侧最近的非空格子（第一格空就取 0）。
  final List<double> mean = List<double>.filled(_cols * _rows, 0);
  for (int y = 0; y < _rows; y++) {
    double last = 0;
    for (int x = 0; x < _cols; x++) {
      final int i = y * _cols + x;
      if (count[i] > 0) last = sum[i] / count[i];
      mean[i] = last;
    }
  }
  final StringBuffer out = StringBuffer();
  int nibble = 0;
  int bits = 0;
  for (int y = 0; y < _rows; y++) {
    for (int x = 0; x < _cols - 1; x++) {
      final bool brighter = mean[y * _cols + x] > mean[y * _cols + x + 1];
      nibble = (nibble << 1) | (brighter ? 1 : 0);
      if (++bits == 4) {
        out.write(nibble.toRadixString(16));
        nibble = 0;
        bits = 0;
      }
    }
  }
  return out.toString();
}

/// 两个 16 位 hex dHash 的汉明距离。长度不对抛 [FormatException]。
int coverHashDistance(String a, String b) {
  if (a.length != 16 || b.length != 16) {
    throw FormatException('cover hash must be 16 hex chars', '$a / $b');
  }
  int d = 0;
  for (int i = 0; i < 16; i++) {
    int x = int.parse(a[i], radix: 16) ^ int.parse(b[i], radix: 16);
    while (x != 0) {
      d += x & 1;
      x >>= 1;
    }
  }
  return d;
}

/// 本地封面文件的「指纹」：路径 + 大小 + 修改时刻。指纹不变就认为封面没换，不用重新生成
/// 缩略图和哈希（每次同步只 stat，不解码）。没有本地封面或文件不在返回 null。
Future<String?> localCoverFingerprint(LocalShelfEntry entry) async {
  final String? path = entry.localCoverPath;
  if (path == null) return null;
  final FileStat st = await FileStat.stat(path);
  if (st.type == FileSystemEntityType.notFound) return null;
  return '$path|${st.size}|${st.modified.millisecondsSinceEpoch}';
}
