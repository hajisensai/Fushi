// 封面投票的本机强比对（「确认票」，services/leaderboard/src/cover_votes.js 文件头）。
//
// 为什么要在投票者设备上比：服务端按 64 位 dHash 把相近的封面归为同一候选，但 dHash 可以被「老实伪造」——
// 知道公开的正版封面就能造出服务端哈希距离很近、显示却是另一张图的 JPEG。持正版封面的用户按哈希
// 投票时会被收割到伪造图上。投票者手里有正版原图，所以命中候选后先下载候选缩略图，在本机与本地封面比：
//
//   1. 两张图各自解码（EXIF 方向已摆正），按面积平均缩成 32×32 灰度（BT.601，与 dHash 同一公式）；
//   2. 整体相似度 = 两个 32×32 网格的归一化互相关（NCC）；
//   3. 细节相似度 = 各自减去 9×8 粗格均值（正是 dHash 看到的那一层）后的残差的 NCC。
//      伪造者为了对上 dHash 只能把 9×8 粗格亮度凑成正版的样子，粗格之内的内容是他想放的另一张图——
//      细节相似度正好量这一层，同图的不同压缩 / 尺寸在这一层仍高度相关。
//   两项都过阈值才算同一张图。
//
// 防护边界：比对结论由客户端自报（服务端无从验证），所以它防的是**诚实客户端被收割**去给伪造图投票，
// 不防一人多号——那一层靠服务端的替换门槛（注册早于候选的账户数 + 公示期 + 管理员可见的不符计数）。
//
// 阈值标定（test/leaderboard/cover_compare_test.dart 的样本，正版 A = 212×300 封面）：
//   同图变体（重编码 q20–q95、缩到 150 / 106 / 64 宽、缩小再放大、亮度 / 对比度 / 灰度、裁 2%）：
//     NCC ≥ 0.9909、细节 ≥ 0.8623（最差都是缩到 64 宽这一档，真实缩略图长边 ≥ 150 时细节 ≥ 0.95）；
//   审查给的伪造样本：
//     forged.jpg（夹断藏质量）：Dart 解码器直接解不开 → 不符；
//     inherent_0.15 / 0.25 / 0.35 / 0.5（老实伪造；后两档只在标定时跑过、未入库）：
//       NCC 0.90 / 0.93 / 0.76 / 0.54，细节 0.17 / 0.22 / 0.22 / 0.11；
//   不相关的封面：NCC 0.39–0.57，细节 0.11–0.17。
// 只看 NCC 时伪造样本最高 0.93，离同图最低 0.99 不远；细节项把两边拉开到 0.86 对 0.22。

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 比对网格边长。
const int kCoverCompareGrid = 32;

/// 整体相似度（32×32 灰度 NCC）阈值。
const double kCoverConfirmMinNcc = 0.95;

/// 细节相似度（去掉 9×8 粗格均值后的 NCC）阈值。
const double kCoverConfirmMinDetailNcc = 0.70;

/// 方差低于它视为「平坦」（纯色封面、或全部内容都在粗格均值里）：NCC 无意义，改按均值比。
const double _flatVariance = 1e-6;

/// 一张封面的比对特征：32×32 灰度网格（行优先，值域 0–1）。
class CoverSignature {
  const CoverSignature(this.grid);

  final Float64List grid;
}

/// 两张封面的比对结果。
class CoverSimilarity {
  const CoverSimilarity({required this.ncc, required this.detailNcc});

  /// 32×32 灰度网格的 NCC（-1…1）。
  final double ncc;

  /// 去掉 9×8 粗格均值后的残差的 NCC（-1…1）。
  final double detailNcc;

  /// 两项都过阈值。
  bool get sameImage =>
      ncc >= kCoverConfirmMinNcc && detailNcc >= kCoverConfirmMinDetailNcc;

  @override
  String toString() =>
      'CoverSimilarity(ncc: ${ncc.toStringAsFixed(4)}, '
      'detail: ${detailNcc.toStringAsFixed(4)})';
}

/// 图片字节的比对特征；解不开（含解码器对畸形数据抛异常）返回 null。
CoverSignature? coverSignature(Uint8List bytes) {
  img.Image? decoded;
  try {
    decoded = img.decodeImage(bytes);
  } on Object {
    // 畸形 / 恶意构造的 JPEG 会让解码器抛 RangeError 等：一律按解不开处理。
    decoded = null;
  }
  if (decoded == null || decoded.width < 1 || decoded.height < 1) return null;
  return coverSignatureOfImage(decoded);
}

/// 已解码图片的比对特征（面积平均缩成 32×32 灰度；空格子取同行左侧最近非空格，与 dHash 一致）。
CoverSignature coverSignatureOfImage(img.Image image) {
  const int n = kCoverCompareGrid;
  final int w = image.width;
  final int h = image.height;
  final Float64List sum = Float64List(n * n);
  final Int32List count = Int32List(n * n);
  for (final img.Pixel p in image) {
    final int cell = (p.y * n ~/ h) * n + p.x * n ~/ w;
    sum[cell] +=
        0.299 * p.rNormalized + 0.587 * p.gNormalized + 0.114 * p.bNormalized;
    count[cell]++;
  }
  final Float64List grid = Float64List(n * n);
  for (int y = 0; y < n; y++) {
    double last = 0;
    for (int x = 0; x < n; x++) {
      final int i = y * n + x;
      if (count[i] > 0) last = sum[i] / count[i];
      grid[i] = last;
    }
  }
  return CoverSignature(grid);
}

/// 两个特征的相似度（见文件头）。
CoverSimilarity compareCoverSignatures(CoverSignature a, CoverSignature b) {
  return CoverSimilarity(
    ncc: _ncc(a.grid, b.grid),
    detailNcc: _ncc(_detail(a.grid), _detail(b.grid)),
  );
}

/// 本地封面与候选缩略图是不是同一张图。[local] 解不开返回 null（本机问题，调用方不该据此记「不符」）；
/// [remote] 解不开算不符（服务端存的必是可解的 JPEG，解不开就是有人在构造畸形数据）。
CoverSimilarity? compareCoverBytes(Uint8List local, Uint8List remote) {
  final CoverSignature? a = coverSignature(local);
  if (a == null) return null;
  final CoverSignature? b = coverSignature(remote);
  if (b == null) return const CoverSimilarity(ncc: -1, detailNcc: -1);
  return compareCoverSignatures(a, b);
}

/// [compareCoverBytes] 的后台 isolate 版本（解码两张图是纯 Dart CPU 重活）。
Future<CoverSimilarity?> compareCoverBytesInBackground(
  Uint8List local,
  Uint8List remote,
) => Isolate.run<CoverSimilarity?>(() => compareCoverBytes(local, remote));

/// 减去 9×8 粗格（dHash 的格子划分）均值后的残差。
Float64List _detail(Float64List g) {
  const int n = kCoverCompareGrid;
  final Float64List sum = Float64List(72);
  final Int32List count = Int32List(72);
  int cellOf(int x, int y) => (y * 8 ~/ n) * 9 + x * 9 ~/ n;
  for (int y = 0; y < n; y++) {
    for (int x = 0; x < n; x++) {
      final int c = cellOf(x, y);
      sum[c] += g[y * n + x];
      count[c]++;
    }
  }
  final Float64List out = Float64List(n * n);
  for (int y = 0; y < n; y++) {
    for (int x = 0; x < n; x++) {
      final int c = cellOf(x, y);
      out[y * n + x] = g[y * n + x] - sum[c] / count[c];
    }
  }
  return out;
}

/// 归一化互相关。两边都平坦时按均值是否接近给 1 / 0；只有一边平坦给 0。
double _ncc(Float64List a, Float64List b) {
  double ma = 0;
  double mb = 0;
  for (int i = 0; i < a.length; i++) {
    ma += a[i];
    mb += b[i];
  }
  ma /= a.length;
  mb /= b.length;
  double sab = 0;
  double saa = 0;
  double sbb = 0;
  for (int i = 0; i < a.length; i++) {
    final double da = a[i] - ma;
    final double db = b[i] - mb;
    sab += da * db;
    saa += da * da;
    sbb += db * db;
  }
  final bool flatA = saa / a.length < _flatVariance;
  final bool flatB = sbb / b.length < _flatVariance;
  if (flatA && flatB) return (ma - mb).abs() < 0.05 ? 1 : 0;
  if (flatA || flatB) return 0;
  return sab / math.sqrt(saa * sbb);
}
