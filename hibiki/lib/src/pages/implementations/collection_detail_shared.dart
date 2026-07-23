import 'package:flutter/material.dart';

import 'package:hibiki/src/pages/implementations/collection_name_dialog.dart'
    show showCollectionNameDialog;
import 'package:hibiki/src/pages/implementations/tag_picker_page.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 两个合集详情页（视频剧集列表 [MediaCollectionDetailPage] 与书架网格
/// [MediaCollectionGridDetailPage]）逐行手抄的四组共享行为收口（巡检 PR-3）：
/// 重命名、编辑标签 + 标签 chip 行、AppBar 排序菜单、删除确认。
///
/// 排序回调（两页数据模型不同：VideoBookRow 内存排 vs 成员行现查元数据排）与
/// 删除后的实际落库仍留在各页；这里只收「同形 UI + 同语义对话框」。
mixin CollectionDetailShared<T extends StatefulWidget> on State<T> {
  /// 宿主页提供：数据库 / 合集行 / 当前显示名 / 改动回调。
  HibikiDatabase get detailDatabase;
  MediaCollectionRow get detailCollection;
  String get detailName;
  set detailName(String value);
  VoidCallback get detailOnChanged;

  /// 标签 chip 行强制重取计数（编辑标签返回后自增）。
  int detailTagsRefresh = 0;

  /// 重命名合集：命名弹窗 → renameMediaCollection → setState 更新页题。
  Future<void> renameDetailCollection() async {
    final String? newName = await showCollectionNameDialog(
      context: context,
      title: t.rename_collection,
      initialName: detailName,
    );
    if (newName == null || newName == detailName) return;
    await detailDatabase.renameMediaCollection(detailCollection.id, newName);
    if (!mounted) return;
    setState(() => detailName = newName);
    detailOnChanged();
  }

  /// 编辑本合集的标签：复用共享标签池的 [TagPickerPage]（合集路，传
  /// collectionId）；返回后自增刷新计数，触发 [buildDetailTagChips] 的
  /// FutureBuilder 重取，chip 行立即反映新增/移除。
  Future<void> editDetailCollectionTags() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => TagPickerPage(collectionId: detailCollection.id),
      ),
    );
    if (!mounted) return;
    setState(() => detailTagsRefresh++);
  }

  /// 详情页头部标签 chip 行：随 [detailTagsRefresh] 强制重取本合集标签；空则不占位。
  Widget buildDetailTagChips() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return FutureBuilder<List<BookTagRow>>(
      key: ValueKey<int>(detailTagsRefresh),
      future: detailDatabase.getTagsForCollection(detailCollection.id),
      builder: (BuildContext context, AsyncSnapshot<List<BookTagRow>> snap) {
        final List<BookTagRow> tags = snap.data ?? const <BookTagRow>[];
        if (tags.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: EdgeInsets.symmetric(
            horizontal: tokens.spacing.rowVertical,
            vertical: tokens.spacing.gap,
          ),
          child: Wrap(
            spacing: tokens.spacing.gap * 0.75,
            runSpacing: tokens.spacing.gap * 0.75,
            children: <Widget>[
              for (final BookTagRow tag in tags)
                HibikiTagChip(
                  label: tag.name,
                  color: Color(tag.colorValue),
                  tone: HibikiTagChipTone.surface,
                ),
            ],
          ),
        );
      },
    );
  }

  /// AppBar「排序」菜单（按名称 / 按导入时间一键重排）；实际重排落库由宿主页回调。
  Widget buildDetailSortMenu({
    required VoidCallback onSortByTitle,
    required VoidCallback onSortByImported,
  }) {
    return MenuAnchor(
      menuChildren: <Widget>[
        MenuItemButton(
          leadingIcon: const Icon(Icons.sort_by_alpha, size: 20),
          onPressed: onSortByTitle,
          child: Text(t.collection_sort_by_title),
        ),
        MenuItemButton(
          leadingIcon: const Icon(Icons.history, size: 20),
          onPressed: onSortByImported,
          child: Text(t.collection_sort_by_imported),
        ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) =>
          IconButton(
        tooltip: t.sort_by,
        icon: const Icon(Icons.sort),
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  /// 「删除合集」确认：统一走 PR-0 的 [HibikiDestructiveConfirmDialog]。
  /// [checkboxLabel] 非空 = 提供「连同成员本体一起删」勾选行；null = 纯解链删除。
  /// 返回 null = 取消。
  Future<HibikiDestructiveConfirmResult?> confirmDetailCollectionDelete({
    String? checkboxLabel,
  }) {
    return showAppDialog<HibikiDestructiveConfirmResult>(
      context: context,
      builder: (_) => HibikiDestructiveConfirmDialog(
        title: t.delete_collection,
        message: t.delete_collection_confirm,
        confirmLabel: t.delete_collection,
        checkboxLabel: checkboxLabel,
      ),
    );
  }

  /// 「移出合集」确认（逐成员）：同走 [HibikiDestructiveConfirmDialog]。true = 确认。
  Future<bool> confirmDetailRemoveMember() async {
    final HibikiDestructiveConfirmResult? result =
        await showAppDialog<HibikiDestructiveConfirmResult>(
      context: context,
      builder: (_) => HibikiDestructiveConfirmDialog(
        title: t.collection_remove_member,
        message: t.collection_remove_member_confirm,
        confirmLabel: t.collection_remove_member,
        leadingIcon: Icons.remove_circle_outline,
      ),
    );
    return result != null;
  }
}
