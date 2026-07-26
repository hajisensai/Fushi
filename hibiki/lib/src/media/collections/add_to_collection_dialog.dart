import 'package:flutter/material.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'package:hibiki/src/pages/implementations/collection_name_dialog.dart';
import 'package:hibiki/utils.dart';

/// 单卡「加入合集」的共享弹窗（书架 / 视频库 / 游戏库共用）。
///
/// 列出全部现有合集（名称 + 成员数，已含本条目的合集置灰打勾），首项「新建
/// 合集」走 [showCollectionNameDialog] 命名后创建。落库统一走
/// [HibikiDatabase.createMediaCollection] / [HibikiDatabase.addToCollection]
/// （后者自带成员墓碑清理——重加回被移出的成员不会被同步复活逻辑吞掉），与
/// 多选批量「组合成合集」三档共用同一条 DAO 路径。
///
/// 返回是否真的加入了合集（调用方据此刷新分组/网格）。
Future<bool> showAddToCollectionDialog({
  required BuildContext context,
  required HibikiDatabase database,
  required MediaKind mediaType,
  required String entryKey,
  String defaultNewName = '',
}) async {
  final List<MediaCollectionRow> collections =
      await database.getAllMediaCollections();
  final List<MediaCollectionItemRow> allItems =
      await database.getAllCollectionItems();
  final Map<int, int> memberCounts = <int, int>{};
  final Set<int> alreadyIn = <int>{};
  for (final MediaCollectionItemRow item in allItems) {
    memberCounts[item.collectionId] =
        (memberCounts[item.collectionId] ?? 0) + 1;
    if (item.mediaType == mediaType.dbValue && item.entryKey == entryKey) {
      alreadyIn.add(item.collectionId);
    }
  }
  collections.sort(
    (MediaCollectionRow a, MediaCollectionRow b) => a.name.compareTo(b.name),
  );
  if (!context.mounted) return false;

  const int kCreateNewSentinel = -1;
  final int? picked = await showAppDialog<int>(
    context: context,
    builder: (BuildContext dialogContext) => _AddToCollectionDialog(
      collections: collections,
      memberCounts: memberCounts,
      alreadyIn: alreadyIn,
      createNewSentinel: kCreateNewSentinel,
    ),
  );
  if (picked == null || !context.mounted) return false;

  final int collectionId;
  if (picked == kCreateNewSentinel) {
    final String? name = await showCollectionNameDialog(
      context: context,
      title: t.create_series,
      initialName: defaultNewName,
    );
    if (name == null || !context.mounted) return false;
    collectionId = await database.createMediaCollection(name);
  } else {
    collectionId = picked;
  }
  await database.addToCollection(collectionId, mediaType, entryKey);
  HibikiToast.show(msg: t.batch_add_to_collection_success(n: 1));
  return true;
}

class _AddToCollectionDialog extends StatelessWidget {
  const _AddToCollectionDialog({
    required this.collections,
    required this.memberCounts,
    required this.alreadyIn,
    required this.createNewSentinel,
  });

  final List<MediaCollectionRow> collections;
  final Map<int, int> memberCounts;
  final Set<int> alreadyIn;
  final int createNewSentinel;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      scrollable: false,
      child: HibikiModalSheetFrame(
        title: t.add_to_collection,
        leadingIcon: Icons.collections_bookmark_outlined,
        scrollable: true,
        bodyPadding: EdgeInsets.symmetric(
          horizontal: tokens.spacing.gap,
          vertical: tokens.spacing.gap / 2,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            HibikiListItem(
              key: const ValueKey<String>('add_to_collection_create_new'),
              leading: const Icon(Icons.add),
              title: Text(t.create_series),
              onTap: () => Navigator.pop(context, createNewSentinel),
            ),
            for (final MediaCollectionRow collection in collections)
              HibikiListItem(
                key: ValueKey<String>('add_to_collection_${collection.id}'),
                leading: const Icon(Icons.collections_bookmark_outlined),
                title: Text(collection.name),
                subtitle: Text(
                  t.series_item_count(n: memberCounts[collection.id] ?? 0),
                ),
                trailing: alreadyIn.contains(collection.id)
                    ? const Icon(Icons.check)
                    : null,
                // 已含本条目的合集不可重复加入（置灰不可点）。
                onTap: alreadyIn.contains(collection.id)
                    ? null
                    : () => Navigator.pop(context, collection.id),
              ),
          ],
        ),
      ),
    );
  }
}
