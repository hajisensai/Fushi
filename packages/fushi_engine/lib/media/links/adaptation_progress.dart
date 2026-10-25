/// 动画进度 ↔ 原作进度（作品图谱 L5，spec `docs/specs/2026-10-24-cross-media-links.md`
/// §6）：「改编作看到第 N 集 ≈ 原作第 M 卷 / 章」。
///
/// 现有 provider 都不直接给集 ↔ 卷映射，所以本期只做**手动对应点**（用户在连接上
/// 记「第 13 集 ≈ 第 4 卷」），由对应点估算当前进度。从字幕与书的文本相似度推断依赖
/// L4 `fushi_corpus`（倒排索引，尚未落地）——[AdaptationProgressInferrer] 只是接口，
/// [kAdaptationProgressInferrer] 恒为 null，UI 据此不显示「自动推断」入口。
library;

/// 原作进度单位（落库值冻结；未知值读作 [volume]）。
enum AdaptationSourceUnit {
  volume('volume'),
  chapter('chapter');

  const AdaptationSourceUnit(this.dbValue);

  final String dbValue;

  static AdaptationSourceUnit parse(String? raw) {
    for (final AdaptationSourceUnit u in values) {
      if (u.dbValue == raw) return u;
    }
    return volume;
  }
}

/// 一个对应点：改编作第 [episode] 集 ≈ 原作第 [number] 个 [unit]。
class AdaptationProgressAnchor {
  const AdaptationProgressAnchor({
    required this.episode,
    required this.unit,
    required this.number,
  });

  final int episode;
  final AdaptationSourceUnit unit;
  final int number;

  @override
  bool operator ==(Object other) =>
      other is AdaptationProgressAnchor &&
      other.episode == episode &&
      other.unit == unit &&
      other.number == number;

  @override
  int get hashCode => Object.hash(episode, unit, number);

  @override
  String toString() => 'ep$episode≈${unit.dbValue}$number';
}

/// 由对应点估算看到第 [watchedEpisode] 集时原作到了哪：取集号 ≤ [watchedEpisode]
/// 的最后一个对应点（对应点是「这一集开始改编到这里」的语义，不在两点之间插值——
/// 卷与集不是线性关系，插出来的小数卷号只会给人错误的精确感）。没有不晚于它的
/// 对应点（或还没开始看）返回 null。
AdaptationProgressAnchor? estimateSourceProgress(
  Iterable<AdaptationProgressAnchor> anchors,
  int? watchedEpisode,
) {
  if (watchedEpisode == null || watchedEpisode < 1) return null;
  AdaptationProgressAnchor? best;
  for (final AdaptationProgressAnchor a in anchors) {
    if (a.episode > watchedEpisode) continue;
    if (best == null || a.episode > best.episode) best = a;
  }
  return best;
}

/// 反向：读到原作第 [number] 个 [unit] 时对应动画的哪一集——取原作位置 ≤ 它的
/// 最后一个对应点的集号（只比同单位的对应点）。没有返回 null。
int? estimateAdaptationEpisode(
  Iterable<AdaptationProgressAnchor> anchors,
  AdaptationSourceUnit unit,
  int number,
) {
  AdaptationProgressAnchor? best;
  for (final AdaptationProgressAnchor a in anchors) {
    if (a.unit != unit || a.number > number) continue;
    if (best == null ||
        a.number > best.number ||
        (a.number == best.number && a.episode > best.episode)) {
      best = a;
    }
  }
  return best?.episode;
}

/// 文本相似度推断的接口（依赖 L4 `fushi_corpus`，**未实现**）：给出改编作字幕与原作
/// 正文，返回推断的对应点。推断结果只能作建议，不写进手动对应点表。
abstract interface class AdaptationProgressInferrer {
  Future<List<AdaptationProgressAnchor>> infer({
    required String sourceKind,
    required String sourceKey,
    required String adaptationKind,
    required String adaptationKey,
  });
}

/// 当前可用的推断器：L4 `fushi_corpus` 落地前恒为 null。
const AdaptationProgressInferrer? kAdaptationProgressInferrer = null;
