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
//     forged.jpg（夹断藏质量）：解码器直接解不开 → 不符；
//     inherent_0.15 / 0.25 / 0.35 / 0.5（老实伪造；后两档只在标定时跑过、未入库）：
//       NCC 0.90 / 0.93 / 0.76 / 0.54，细节 0.17 / 0.22 / 0.22 / 0.11；
//   不相关的封面：NCC 0.39–0.57，细节 0.11–0.17。
// 只看 NCC 时伪造样本最高 0.93，离同图最低 0.99 不远；细节项把两边拉开到 0.86 对 0.22。
//
// 解码与两项相似度都在原生内核（native/fushi_compute `ffc_image_cover_signature` /
// `ffc_image_cover_compare`，与旧 Dart 实现在同一份解码像素上逐位一致）。解码器是 Rust 的
// `image` crate：PNG 等无损格式与旧的 `package:image` 逐字节相同；JPEG 有 ±1 级的差，灰度图
// 展开成 RGB 后按真亮度算（旧 `package:image` 的单通道像素 g/b 读作 0，灰度封面只取到 0.299×亮度，
// 与同一张图的彩色版本比不上）。

import 'dart:isolate';
import 'dart:typed_data';

import 'package:fushi_compute/fushi_compute.dart';

/// 比对网格边长。
const int kCoverCompareGrid = 32;

/// 整体相似度（32×32 灰度 NCC）阈值。
const double kCoverConfirmMinNcc = 0.95;

/// 细节相似度（去掉 9×8 粗格均值后的 NCC）阈值。
const double kCoverConfirmMinDetailNcc = 0.70;

// 方差低于 1e-6 视为「平坦」（纯色封面、或全部内容都在粗格均值里）：NCC 无意义，改按均值比
// （阈值在 image.rs `cover_ncc`）。

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

/// 图片字节的比对特征（解码时按 EXIF 方向摆正，按面积平均缩成 32×32 灰度；空格子取同行左侧
/// 最近非空格，与 dHash 一致）；解不开（含畸形 / 恶意构造的数据）返回 null。
CoverSignature? coverSignature(Uint8List bytes) {
  final Float64List? grid = FushiComputeImage.instance.coverSignature(bytes);
  return grid == null ? null : CoverSignature(grid);
}

/// 两个特征的相似度（见文件头）。
CoverSimilarity compareCoverSignatures(CoverSignature a, CoverSignature b) {
  final ({double ncc, double detailNcc}) r = FushiComputeImage.instance
      .compareCoverSignatures(a.grid, b.grid);
  return CoverSimilarity(ncc: r.ncc, detailNcc: r.detailNcc);
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

/// [compareCoverBytes] 的后台 isolate 版本（解码两张图是 CPU 重活）。
Future<CoverSimilarity?> compareCoverBytesInBackground(
  Uint8List local,
  Uint8List remote,
) => Isolate.run<CoverSimilarity?>(() => compareCoverBytes(local, remote));
