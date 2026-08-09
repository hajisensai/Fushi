import 'dart:typed_data';

/// 判断一帧 RGBA 像素是否「非空白」（不是纯色 / 白屏）。
///
/// 离屏抓图最大的失败模式是抓回纯白 / 纯色帧（见 docs/agent/computer-use-testing.md）。
/// 对 RGBA 缓冲做稀疏采样，把每像素量化到每通道 5 bit（忽略抗锯齿噪声），统计不同
/// 颜色数；达到 [threshold] 即判非空白。纯逻辑、无 I/O，可单测。
bool rgbaLooksNonBlank(Uint8List rgba, {int threshold = 12}) {
  if (rgba.length < 4) {
    return false;
  }
  final int pixelCount = rgba.length ~/ 4;
  // 大图最多采样约 4096 个点，控制耗时；小图全采。
  final int stride = pixelCount <= 4096 ? 1 : pixelCount ~/ 4096;
  final Set<int> colors = <int>{};
  for (int p = 0; p < pixelCount; p += stride) {
    final int i = p * 4;
    final int r = rgba[i] >> 3;
    final int g = rgba[i + 1] >> 3;
    final int b = rgba[i + 2] >> 3;
    colors.add((r << 10) | (g << 5) | b);
    if (colors.length >= threshold) {
      return true;
    }
  }
  return false;
}
