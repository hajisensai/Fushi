/// 凝彩的确定性散列（folia `visualizerSeedHash.ts` / `temperaRandom.ts`）：同一首歌、同一个种子，
/// 拖进度、重建都得到同一帧。与 JS 版逐位一致（32 位无符号运算）。
library;

const int _mask32 = 0xFFFFFFFF;

/// FNV-1a 32 位字符串散列（按 UTF-16 码元，和 JS `charCodeAt` 一致）。
int temperaHashSeed(String value) {
  int hash = 2166136261;
  for (final int unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 16777619) & _mask32;
  }
  return hash;
}

/// 32 位截断乘法（JS `Math.imul` 的无符号结果）。
int _imul(int a, int b) => ((a & _mask32) * (b & _mask32)) & _mask32;

/// 把数字种子与盐混合，让版式、装饰、逐字抖动互不相关。
int temperaMixSeed(int seed, int salt) =>
    _imul((seed & _mask32) ^ (salt & _mask32), 2654435761);

/// 按元素下标取确定性的 0..1 抖动。
double temperaHash01(int seed, int index, int salt) =>
    temperaMixSeed(seed + _imul(index + 1, 97), salt) / 4294967296.0;

/// 确定性地挑一个与上一次不同的选项（选项够多时）。
T temperaChooseWithoutRepeat<T>(List<T> choices, String seed, T? previous) {
  final int start = temperaHashSeed(seed) % choices.length;
  for (int offset = 0; offset < choices.length; offset++) {
    final T candidate = choices[(start + offset) % choices.length];
    if (candidate != previous) return candidate;
  }
  return choices[start];
}
