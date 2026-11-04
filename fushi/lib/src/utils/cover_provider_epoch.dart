import 'package:material_ui/material_ui.dart';

/// 按 [ImageProvider] 计的「换图代际号」：同一个 provider 每被驱逐一次（同路径
/// 覆盖写封面后的 `evictLocalCoverCache`）代际号 +1。
///
/// 为什么需要：按 provider 记忆的派生结果（`CoverProbeMemo` 的宽高比 / 垫底主色、
/// `PrebakedBlurImage` 的烘焙纹理）都是**异步**算出来的。驱逐恰好发生在计算途中时，
/// 旧图的结果会在驱逐之后才回来，按同一个 provider 写回缓存——之后所有同 provider
/// 的卡都拿旧图的结果。异步任务在**拿到源图那一刻**记下 [of]，写缓存前比对：
/// 不一致说明期间换过图，结果作废、不进缓存。
///
/// 两个缓存共用这一份代际号（同一次换图让两边的飞行中任务一起作废）。只有被驱逐
/// 过的 provider 才会进表，每条一个 int；不设上限是刻意的——条目被淘汰会让代际号
/// 回到 0，恰好与驱逐前记下的 0 相等，作废就失效了。
abstract final class CoverProviderEpoch {
  static final Map<ImageProvider, int> _epochs = <ImageProvider, int>{};

  /// [provider] 当前的代际号；从没被驱逐过为 0。
  static int of(ImageProvider provider) => _epochs[provider] ?? 0;

  /// 让 [provider] 进入下一代：此前记下旧代际号的异步结果都不再写回缓存。
  static void bump(ImageProvider provider) {
    _epochs[provider] = of(provider) + 1;
  }

  @visibleForTesting
  static void clear() => _epochs.clear();
}
