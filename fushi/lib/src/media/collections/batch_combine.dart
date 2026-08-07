/// 批量「组合成合集」按钮的三档自适应判定（纯函数，widget/DB-free，便于单测）。
///
/// 两库页（书架 / 视频）批量选择态并存两个选择集：合集选中集（collectionId 集）与
/// 散卡选中集。点「组合」时按二者数量自适应分档，避免把「新建 / 并入 / 合并」硬拆成
/// 三个按钮（用户拍板：一个按钮三档）。
library;

/// 组合动作的四种落点。
enum CombineTier {
  /// 仅散卡（合集 0、散卡 ≥1）→ 命名弹窗新建合集。
  createNew,

  /// 恰 1 合集 + 若干散卡 → 散卡并入该合集（不弹命名）。
  addToExisting,

  /// ≥2 合集（可带散卡）→ 合并成一个（默认名=成员最多合集名，确认框可改名）。
  mergeCollections,

  /// 无可组合（空选，或仅 1 合集且无散卡）→ 无操作。
  noop,
}

/// 依据「选中合集数」[collectionCount] 与「选中散卡数」[looseCount] 判定组合档位。
CombineTier classifyCombine({
  required int collectionCount,
  required int looseCount,
}) {
  if (collectionCount >= 2) return CombineTier.mergeCollections;
  if (collectionCount == 1) {
    return looseCount > 0 ? CombineTier.addToExisting : CombineTier.noop;
  }
  return looseCount > 0 ? CombineTier.createNew : CombineTier.noop;
}

/// 合并多合集时的目标合集选择结果：并集目标 id + 默认名（供命名确认框预填）。
class MergeTargetChoice {
  const MergeTargetChoice({required this.targetId, required this.defaultName});

  /// 吸收其余合集成员的目标合集 id（其余合集随后 deleteMediaCollection 解散）。
  final int targetId;

  /// 默认名 = 成员最多合集的名（用户可在确认框改名）。
  final String defaultName;
}

/// 从选中合集里挑「成员最多」的作为合并目标，其名作默认名（纯函数）。
///
/// 平票取输入序里的第一个（调用方按 id 升序传入 → 平票稳定取最小 id）。[collections]
/// 不得为空。
MergeTargetChoice chooseMergeTarget(
  List<({int id, String name, int memberCount})> collections,
) {
  assert(collections.isNotEmpty, 'chooseMergeTarget requires ≥1 collection');
  ({int id, String name, int memberCount}) best = collections.first;
  for (final ({int id, String name, int memberCount}) c
      in collections.skip(1)) {
    if (c.memberCount > best.memberCount) best = c;
  }
  return MergeTargetChoice(targetId: best.id, defaultName: best.name);
}
