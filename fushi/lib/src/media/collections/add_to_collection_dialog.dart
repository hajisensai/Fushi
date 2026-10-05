import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/pages/implementations/collection_name_dialog.dart';
import 'package:fushi/utils.dart';

/// 单卡「加入合集」的共享弹窗（书架 / 视频库 / 游戏库共用）。
///
/// 列出与条目同一库页域的现有合集（名称 + 成员数，已含本条目的合集置灰打勾），首项「新建
/// 合集」走 [showCollectionNameDialog] 命名后创建。落库统一走
/// [FushiDatabase.createMediaCollection] / [FushiDatabase.addToCollection]
/// （后者自带成员墓碑清理——重加回被移出的成员不会被同步复活逻辑吞掉），与
/// 多选批量「组合成合集」三档共用同一条 DAO 路径。
///
/// 返回是否真的加入了合集（调用方据此刷新分组/网格）。
Future<bool> showAddToCollectionDialog({
  required BuildContext context,
  required FushiDatabase database,
  required MediaKind mediaType,
  required String entryKey,
  String defaultNewName = '',
}) async {
  // BUG-2974：只列与本条目同一库页域的合集（书不见视频合集、漫画不见书合集），
  // 域判据收口在数据层 [FushiDatabase.getMediaCollectionsForEntryDomain]。
  final List<MediaCollectionRow> collections =
      await database.getMediaCollectionsForEntryDomain(mediaType, entryKey);
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
    // BUG-2974：createMediaCollection 按 (名称, 类型) 自然键复用已有行。同名合集若
    // 属于别的库页（如视频合集），复用就等于把书塞进视频合集——两域又混在一起。
    // 本域里已有的同名合集照常复用；别的域占着这个名字就拒绝，让用户换名。
    final MediaCollectionRow? sameName =
        await database.getMediaCollectionByNaturalKey(name, 'collection');
    if (sameName != null &&
        !collections.any((MediaCollectionRow c) => c.id == sameName.id)) {
      FushiToast.show(
        msg: t.collection_name_taken_other_library(name: name),
        severity: ToastSeverity.warning,
      );
      return false;
    }
    if (!context.mounted) return false;
    collectionId = await database.createMediaCollection(name);
  } else {
    collectionId = picked;
  }
  await database.addToCollection(collectionId, mediaType, entryKey);
  FushiToast.show(
    msg: t.batch_add_to_collection_success(n: 1),
    severity: ToastSeverity.success,
  );
  return true;
}

/// 合集详情页「移到其他合集」：给一批成员挑目标合集（同库域，BUG-2974 同口径：
/// 按 [domainKind] / [domainEntryKey] 这个代表成员的媒体库取候选），可新建。
/// [currentCollectionId] 显示为已在（不可选）。返回目标合集 id；取消 null。
Future<int?> pickTargetCollectionForMembers({
  required BuildContext context,
  required FushiDatabase database,
  required MediaKind domainKind,
  required String domainEntryKey,
  required int currentCollectionId,
  String defaultNewName = '',
}) async {
  final List<MediaCollectionRow> collections =
      await database.getMediaCollectionsForEntryDomain(
    domainKind,
    domainEntryKey,
  );
  final List<MediaCollectionItemRow> allItems =
      await database.getAllCollectionItems();
  final Map<int, int> memberCounts = <int, int>{};
  for (final MediaCollectionItemRow item in allItems) {
    memberCounts[item.collectionId] =
        (memberCounts[item.collectionId] ?? 0) + 1;
  }
  collections.sort(
    (MediaCollectionRow a, MediaCollectionRow b) => a.name.compareTo(b.name),
  );
  if (!context.mounted) return null;
  const int kCreateNewSentinel = -1;
  final int? picked = await showAppDialog<int>(
    context: context,
    builder: (BuildContext dialogContext) => _AddToCollectionDialog(
      collections: collections,
      memberCounts: memberCounts,
      alreadyIn: <int>{currentCollectionId},
      createNewSentinel: kCreateNewSentinel,
    ),
  );
  if (picked == null || !context.mounted) return null;
  if (picked != kCreateNewSentinel) return picked;
  final String? name = await showCollectionNameDialog(
    context: context,
    title: t.create_series,
    initialName: defaultNewName,
  );
  if (name == null || !context.mounted) return null;
  final MediaCollectionRow? sameName =
      await database.getMediaCollectionByNaturalKey(name, 'collection');
  if (sameName != null &&
      !collections.any((MediaCollectionRow c) => c.id == sameName.id)) {
    FushiToast.show(
      msg: t.collection_name_taken_other_library(name: name),
      severity: ToastSeverity.warning,
    );
    return null;
  }
  return database.createMediaCollection(name);
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
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      scrollable: false,
      child: FushiModalSheetFrame(
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
            FushiListItem(
              key: const ValueKey<String>('add_to_collection_create_new'),
              // M3E 行首形状底：新建 = primary 饱和色块，与已有合集区分。
              leading: const FushiListLeadingIcon(
                Icons.add,
                tone: FushiCardTone.primary,
              ),
              title: Text(t.create_series),
              onTap: () => Navigator.pop(context, createNewSentinel),
            ),
            for (final MediaCollectionRow collection in collections)
              FushiListItem(
                key: ValueKey<String>('add_to_collection_${collection.id}'),
                leading: const FushiListLeadingIcon(
                  Icons.collections_bookmark_outlined,
                  shape: FushiLeadingShape.square,
                ),
                title: Text(collection.name),
                subtitle: Text(
                  t.series_item_count(n: memberCounts[collection.id] ?? 0),
                ),
                trailing: alreadyIn.contains(collection.id)
                    ? const FushiIcon(Icons.check)
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
