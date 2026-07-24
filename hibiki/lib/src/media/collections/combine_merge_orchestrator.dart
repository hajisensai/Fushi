import 'package:flutter/material.dart';

import 'package:hibiki/src/media/collections/batch_combine.dart';
import 'package:hibiki/src/pages/implementations/collection_name_dialog.dart';
import 'package:hibiki/src/utils/misc/shelf_ordering.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 批量「合并合集」档3 的共享 DB/UI 编排（书架页 + 视频首页两处逐字等价的合并流程）。
///
/// 决策纯函数（[classifyCombine] / [chooseMergeTarget]）留在 `batch_combine.dart`
/// 保持 widget/DB-free 便于单测；本函数负责有副作用的编排：成员快照 → 选目标 →
/// 命名弹窗 → TOCTOU 复查 → 迁移循环（幂等 addToCollection + 解散源合集）→ 散卡
/// 加入 → rename → 刷新 + toast。页面差异（db 来源 / 刷新机制 / 合集名解析 /
/// 挂载判定 / 文案）全部由调用方注入，两处调用点因此收薄到只剩注入参数。
///
/// 返回 `true` 表示合并已落地（rename 完成、刷新与 toast 已触发）；`false` 表示中途
/// 中止（命名弹窗取消，或任一挂载检查失败 —— 与原实现的 `return` 提前退出等价）。
Future<bool> combineMergeCollections({
  required BuildContext context,
  required HibikiDatabase db,
  required List<int> collectionIds,
  required List<ShelfEntryRef> refs,
  required String Function(int collectionId) collectionNameById,
  required bool Function() isMounted,
  required Future<void> Function() onRefresh,
  required String mergeDialogTitle,
  required String mergedToast,
}) async {
  final Map<int, List<MediaCollectionItemRow>> itemsById =
      <int, List<MediaCollectionItemRow>>{};
  for (final int id in collectionIds) {
    itemsById[id] = await db.getCollectionItems(id);
  }
  final MergeTargetChoice choice = chooseMergeTarget(
    <({int id, String name, int memberCount})>[
      for (final int id in collectionIds)
        (
          id: id,
          name: collectionNameById(id),
          memberCount: itemsById[id]!.length,
        ),
    ],
  );
  if (!isMounted() || !context.mounted) return false;
  final String? name = await showCollectionNameDialog(
    context: context,
    title: mergeDialogTitle,
    initialName: choice.defaultName,
  );
  if (name == null || !isMounted()) return false;
  final int targetId = choice.targetId;
  // 复查 #6（TOCTOU）：成员快照上面是在命名确认框「之前」取的，框开着期间若有新成员
  // 同步进源合集，用旧快照迁移会漏掉这些新成员，随后 deleteMediaCollection 把它们连
  // 同源合集一起删掉 → 分组丢失。确认后、迁移前对每个源合集「重取」最新成员再迁移，
  // addToCollection 幂等去重，重复成员无副作用。
  for (final int id in collectionIds) {
    if (id == targetId) continue;
    final List<MediaCollectionItemRow> members =
        await db.getCollectionItems(id);
    for (final MediaCollectionItemRow m in members) {
      await db.addToCollection(targetId, m.mediaType, m.entryKey);
    }
    await db.deleteMediaCollection(id);
  }
  for (final ShelfEntryRef ref in refs) {
    await db.addToCollection(targetId, ref.mediaType, ref.entryKey);
  }
  await db.renameMediaCollection(targetId, name);
  if (!isMounted()) return false;
  await onRefresh();
  HibikiToast.show(msg: mergedToast);
  return true;
}
