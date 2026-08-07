import 'package:flutter/material.dart';

import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/media/collections/collection_asset_reclaim.dart';
import 'package:fushi/src/media/collections/collection_one_key_sort.dart';
import 'package:fushi/src/pages/implementations/collection_name_dialog.dart'
    show showCollectionNameDialog;
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart';
import 'package:fushi/src/pages/implementations/tag_picker_page.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 统一三库页合集入口的右键 / 长按菜单（书架横排行、视频合集封面卡、游戏库
/// 横排行共用）：打开详情 / 重命名 / 标签 / [extraListActions] 媒体特有项 /
/// 按名称·按导入时间一键整理 / 删除合集。
///
/// 此前合集管理动作只存在于合集详情页 AppBar，三页的合集入口本身没有任何
/// 上下文菜单（与单卡的长按对话框割裂，用户实报）。本对话框复用单卡同款
/// [MediaItemDialogFrame] 骨架，动作语义与详情页 AppBar 完全同源：
/// 重命名走 [HibikiDatabase.renameMediaCollection]，标签走 [TagPickerPage]
/// （合集路），删除走 [deleteMediaCollectionWithAssets]（纯解链 + 回收合集自有
/// 封面，不删成员本体，可选
/// 「连同成员本体一起删」勾选，与详情页 `_delete` 同一纪律）。
///
/// [context] 必须是**页面**级 context（对话框内部动作先关自身再用它续跑）。
/// [onChanged] 在任何写库动作（重命名/标签/删除）后调用，页面自刷。
/// [onDeleteMembersMedia] 非 null 且合集有成员时，删除确认框提供
/// [deleteMembersCheckboxLabel] 勾选行（调用方按媒体域传
/// `delete_collection_also_books` / `delete_collection_also_videos` 等文案）。
/// [extraListActions] 由调用方注入媒体特有行（视频页：在线匹配封面 / 为合集
/// 获取字幕），本对话框统一负责「先关自身再执行」，回调里不要再 pop。
/// 排序两项内建（[applyCollectionOneKeySort]，与详情页 AppBar 排序菜单同源），
/// 各页零接线成本。
Future<void> showCollectionContextDialog({
  required BuildContext context,
  required HibikiDatabase db,
  required MediaCollectionRow collection,
  required VoidCallback onOpenDetail,
  required VoidCallback onChanged,
  Future<void> Function(List<MediaCollectionItemRow> members)?
      onDeleteMembersMedia,
  String? deleteMembersCheckboxLabel,
  DeletionDisclosure? deleteMembersDisclosure,
  List<DialogListAction> extraListActions = const <DialogListAction>[],
  Widget? cover,
}) async {
  await showAppDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) {
      void closeThen(void Function() action) {
        Navigator.pop(dialogContext);
        action();
      }

      return MediaItemDialogFrame(
        cover: cover,
        title: collection.name,
        // 顶部主按钮 = 打开详情（与行头/卡片单击同路径，键盘/手柄用户可达）。
        launchLabel: t.collection_view_all,
        onLaunch: () => closeThen(onOpenDetail),
        listActions: <DialogListAction>[
          DialogListAction(
            label: t.rename_collection,
            icon: Icons.drive_file_rename_outline,
            onPressed: () => closeThen(
              () => _renameCollection(
                context: context,
                db: db,
                collection: collection,
                onChanged: onChanged,
              ),
            ),
          ),
          DialogListAction(
            label: t.tag_label,
            icon: Icons.sell_outlined,
            onPressed: () => closeThen(
              () => _editCollectionTags(
                context: context,
                collection: collection,
                onChanged: onChanged,
              ),
            ),
          ),
          // 媒体特有项（视频：在线匹配封面 / 为合集获取字幕）。统一包 closeThen，
          // 调用方回调无需自行 pop。
          for (final DialogListAction action in extraListActions)
            DialogListAction(
              label: action.label,
              icon: action.icon,
              onPressed: () => closeThen(action.onPressed),
            ),
          // 一键整理（与合集详情页 AppBar 排序菜单同一实现与落盘路径）。
          DialogListAction(
            label: t.collection_sort_by_title,
            icon: Icons.sort_by_alpha,
            onPressed: () => closeThen(
              () => _sortCollection(
                db: db,
                collection: collection,
                byTitle: true,
                onChanged: onChanged,
              ),
            ),
          ),
          DialogListAction(
            label: t.collection_sort_by_imported,
            icon: Icons.history,
            onPressed: () => closeThen(
              () => _sortCollection(
                db: db,
                collection: collection,
                byTitle: false,
                onChanged: onChanged,
              ),
            ),
          ),
        ],
        dangerActions: <DialogDangerAction>[
          DialogDangerAction(
            label: t.delete_collection,
            onPressed: () => closeThen(
              () => _deleteCollection(
                context: context,
                db: db,
                collection: collection,
                onChanged: onChanged,
                onDeleteMembersMedia: onDeleteMembersMedia,
                deleteMembersCheckboxLabel: deleteMembersCheckboxLabel,
                deleteMembersDisclosure: deleteMembersDisclosure,
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// 重命名合集：命名弹窗 → [HibikiDatabase.renameMediaCollection]。与
/// `CollectionDetailShared.renameDetailCollection` 同语义（那边还要同步页题，
/// 库页语境由 [onChanged] 整页重载覆盖）。
Future<void> _renameCollection({
  required BuildContext context,
  required HibikiDatabase db,
  required MediaCollectionRow collection,
  required VoidCallback onChanged,
}) async {
  final String? newName = await showCollectionNameDialog(
    context: context,
    title: t.rename_collection,
    initialName: collection.name,
  );
  if (newName == null || newName == collection.name) return;
  await db.renameMediaCollection(collection.id, newName);
  onChanged();
}

/// 编辑合集标签：复用共享标签池的 [TagPickerPage]（合集路）。返回后 [onChanged]
/// 让页面失效 `collectionTagMapProvider` 刷新行头/卡面 chip。
Future<void> _editCollectionTags({
  required BuildContext context,
  required MediaCollectionRow collection,
  required VoidCallback onChanged,
}) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute<void>(
      builder: (_) => TagPickerPage(collectionId: collection.id),
    ),
  );
  onChanged();
}

/// 一键整理：按名称 / 按导入时间重排全表并落盘 sortIndex（共享
/// [applyCollectionOneKeySort]），完成后 [onChanged] 让库页合集行立即同序。
Future<void> _sortCollection({
  required HibikiDatabase db,
  required MediaCollectionRow collection,
  required bool byTitle,
  required VoidCallback onChanged,
}) async {
  await applyCollectionOneKeySort(
    db: db,
    collectionId: collection.id,
    byTitle: byTitle,
  );
  onChanged();
}

/// 删除合集：确认（可选「连同成员本体一起删」勾选）→ 先删成员本体（调用方注入，
/// 按媒体域删 DB 行 + 磁盘副本）→ [deleteMediaCollectionWithAssets] 解散容器
/// （清引用行 + 写合集级墓碑 + 回收合集自有封面）。与两个合集详情页的 `_delete`
/// 同一顺序、同一入口（BUG-1319：回收必须挂在删除动作上，不能各入口各写一遍）。
Future<void> _deleteCollection({
  required BuildContext context,
  required HibikiDatabase db,
  required MediaCollectionRow collection,
  required VoidCallback onChanged,
  required Future<void> Function(List<MediaCollectionItemRow> members)?
      onDeleteMembersMedia,
  required String? deleteMembersCheckboxLabel,
  required DeletionDisclosure? deleteMembersDisclosure,
}) async {
  final List<MediaCollectionItemRow> members =
      await db.getCollectionItems(collection.id);
  if (!context.mounted) return;
  final bool canDeleteMembers =
      onDeleteMembersMedia != null && members.isNotEmpty;
  final HibikiDestructiveConfirmResult? result =
      await showAppDialog<HibikiDestructiveConfirmResult>(
    context: context,
    builder: (_) => HibikiDestructiveConfirmDialog(
      title: t.delete_collection,
      message: t.delete_collection_confirm,
      confirmLabel: t.delete_collection,
      checkboxLabel: canDeleteMembers ? deleteMembersCheckboxLabel : null,
      checkedDisclosure: canDeleteMembers ? deleteMembersDisclosure : null,
    ),
  );
  if (result == null || !context.mounted) return;
  if (result.checked && onDeleteMembersMedia != null) {
    await onDeleteMembersMedia(List<MediaCollectionItemRow>.of(members));
  }
  await deleteMediaCollectionWithAssets(db, collection.id);
  onChanged();
}
