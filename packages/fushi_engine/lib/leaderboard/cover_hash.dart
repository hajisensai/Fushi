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

import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/leaderboard/local_shelf.dart';
import 'package:fushi_engine/media/image_kernels.dart';

/// 与服务端 `COVER_HASH_MAX_DISTANCE` 一致：汉明距离不超过它视为同一张图。
const int kCoverHashMaxDistance = 10;

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

/// 已解码图片（首帧）的 dHash（见文件头）。灰度 / 求均值 / 比较在原生内核
/// （ffc_image_dhash）里，与旧的逐像素 Dart 循环逐位相同；调色板与非 uint8 图先展开成
/// uint8（16 位图因此按 8 位精度求亮度，与服务端容差 [kCoverHashMaxDistance] 相比可忽略）。
String coverDHashOfImage(img.Image image) {
  final ({Uint8List pixels, int stride, int channels, int width, int height})
  p = uint8Pixels(image);
  final Uint8List bits = FushiComputeImage.instance.dHash(
    p.pixels,
    stride: p.stride,
    channels: p.channels,
    width: p.width,
    height: p.height,
  );
  final StringBuffer out = StringBuffer();
  for (final int byte in bits) {
    out.write(byte.toRadixString(16).padLeft(2, '0'));
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
