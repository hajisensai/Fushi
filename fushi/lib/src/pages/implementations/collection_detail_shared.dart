import 'package:fushi/src/ai/ai_failure_text.dart';
import 'package:fushi/src/media/collections/collection_ai_order.dart';
import 'package:fushi/src/media/tags/tag_picker_sheet.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi_engine/ai/ai_collection_order_assistant.dart'
    show resolveCollectionOrderAiProvider;
import 'package:fushi_engine/ai/ai_settings.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/pages/implementations/collection_name_dialog.dart'
    show showCollectionNameDialog;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart';

/// 两个合集详情页（视频剧集列表 [MediaCollectionDetailPage] 与书架网格
/// [MediaCollectionGridDetailPage]）逐行手抄的四组共享行为收口（巡检 PR-3）：
/// 重命名、编辑标签 + 标签 chip 行、AppBar 排序菜单、删除确认。
///
/// 排序回调（两页数据模型不同：VideoBookRow 内存排 vs 成员行现查元数据排）与
/// 删除后的实际落库仍留在各页；这里只收「同形 UI + 同语义对话框」。
mixin CollectionDetailShared<T extends StatefulWidget> on State<T> {
  /// 宿主页提供：数据库 / 合集行 / 当前显示名 / 改动回调。
  FushiDatabase get detailDatabase;
  MediaCollectionRow get detailCollection;
  String get detailName;
  set detailName(String value);
  VoidCallback get detailOnChanged;

  /// 标签 chip 行强制重取计数（编辑标签返回后自增）。
  int detailTagsRefresh = 0;

  Future<List<BookTagRow>>? _detailTagsFuture;
  int? _detailTagsToken;
  int? _detailTagsCollectionId;

  /// 标签查询，身份 = (合集 id, [detailTagsRefresh])。
  ///
  /// **不能在 build 里现取**（BUG-2010）：那样每次重建都对库多发一次查询，而
  /// 重建源不受本页控制——app 一拉到前台就走 `AppLifecycleState.resumed` → 重取
  /// 系统调色板 → 通知主题 → 全树重建。
  ///
  /// 注意 chip 行**不会**因此闪：builder 只读 `snap.data`，而 FutureBuilder 换
  /// future 时走的是 `_snapshot.inState(ConnectionState.none)`——data 会保留，
  /// 只有像 `VideoWorkDetailPage` 那样判 `connectionState` 的才会退回加载态。
  /// 记忆化省下的是白查库，不是闪。
  Future<List<BookTagRow>> get _detailTags {
    final int collectionId = detailCollection.id;
    if (_detailTagsFuture == null ||
        _detailTagsToken != detailTagsRefresh ||
        _detailTagsCollectionId != collectionId) {
      _detailTagsToken = detailTagsRefresh;
      _detailTagsCollectionId = collectionId;
      _detailTagsFuture = detailDatabase.getTagsForCollection(collectionId);
    }
    return _detailTagsFuture!;
  }

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
    await showTagPicker(
      context,
      targets: TagTargets(collectionIds: <int>[detailCollection.id]),
    );
    if (!mounted) return;
    setState(() => detailTagsRefresh++);
  }

  /// 详情页头部标签 chip 行：随 [detailTagsRefresh] 强制重取本合集标签；空则不占位。
  Widget buildDetailTagChips() {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return FutureBuilder<List<BookTagRow>>(
      future: _detailTags,
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
                FushiTagChip(
                  label: tag.name,
                  color: Color(tag.colorValue),
                  tone: FushiTagChipTone.surface,
                ),
            ],
          ),
        );
      },
    );
  }

  /// AppBar「排序」菜单（按名称 / 按导入时间一键重排）；实际重排落库由宿主页回调。
  /// [onSortByAi] 非 null 时多一项「AI 排序」（AI 模块关着时宿主传 null）。
  Widget buildDetailSortMenu({
    required VoidCallback onSortByTitle,
    required VoidCallback onSortByImported,
    VoidCallback? onSortByAi,
  }) {
    return FushiMenuAnchor(
      menuChildren: <Widget>[
        MenuItemButton(
          leadingIcon: const FushiIcon(Icons.sort_by_alpha, size: 20),
          onPressed: onSortByTitle,
          child: Text(t.collection_sort_by_title),
        ),
        MenuItemButton(
          leadingIcon: const FushiIcon(Icons.history, size: 20),
          onPressed: onSortByImported,
          child: Text(t.collection_sort_by_imported),
        ),
        if (onSortByAi != null)
          MenuItemButton(
            key: const ValueKey<String>('collection_detail_sort_ai'),
            leadingIcon: const FushiIcon(FushiIcons.ai, size: 20),
            onPressed: onSortByAi,
            child: Text(t.collection_sort_ai),
          ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) =>
          FushiIconButtonControl(
            tooltip: t.sort_by,
            icon: const FushiIcon(Icons.sort),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
    );
  }

  bool _detailAiSortBusy = false;

  /// 「AI 排序」（用户意图）：规则判不出的成员（SP / OVA / 汉字卷号 / 上下卷）
  /// 交 AI 定位，落盘走 `reorderCollectionItems` 并把排序偏好切成 manual
  /// （[runCollectionAiOrder]）。没指派提供商时**一个请求都不发**，只引导去
  /// 「设置 › 模型 › LLM」（BUG-2694 的约定）。落了盘返回 true，宿主据此重载。
  Future<bool> runDetailAiSort({
    required AiSettingsSource settings,
    CollectionAiClientFactory? clientFactory,
  }) async {
    if (_detailAiSortBusy) return false;
    if (resolveCollectionOrderAiProvider(settings) == null) {
      FushiToast.show(msg: t.ai_assist_no_provider);
      return false;
    }
    _detailAiSortBusy = true;
    FushiToast.show(msg: t.collection_sort_ai_running);
    final CollectionAiOrderOutcome outcome;
    try {
      outcome = await runCollectionAiOrder(
        db: detailDatabase,
        collectionId: detailCollection.id,
        settings: settings,
        userIntent: true,
        clientFactory: clientFactory,
      );
    } finally {
      _detailAiSortBusy = false;
    }
    final String? message = switch (outcome.status) {
      CollectionAiOrderStatus.aiOrdered =>
        outcome.changed
            ? t.collection_sort_ai_applied
            : t.collection_sort_ai_unchanged,
      CollectionAiOrderStatus.ruleOrdered => t.collection_sort_ai_rules_only,
      CollectionAiOrderStatus.noProvider => t.ai_assist_no_provider,
      CollectionAiOrderStatus.failed => t.ai_assist_failed(
        reason: aiFailureText(outcome.failure ?? ''),
      ),
      CollectionAiOrderStatus.invalidReply => t.collection_sort_ai_invalid,
      CollectionAiOrderStatus.unknown => t.collection_sort_ai_unknown,
      CollectionAiOrderStatus.tooLarge => t.collection_sort_ai_too_large,
      CollectionAiOrderStatus.notFound ||
      CollectionAiOrderStatus.tooFew ||
      CollectionAiOrderStatus.skippedManual ||
      CollectionAiOrderStatus.noAmbiguity => null,
    };
    if (message != null) {
      FushiToast.show(
        msg: message,
        severity:
            outcome.status == CollectionAiOrderStatus.failed ||
                outcome.status == CollectionAiOrderStatus.invalidReply
            ? ToastSeverity.error
            : ToastSeverity.success,
      );
    }
    if (outcome.persisted) detailOnChanged();
    return outcome.persisted;
  }

  /// 「删除合集」确认：统一走 PR-0 的 [FushiDestructiveConfirmDialog]。
  /// [checkboxLabel] 非空 = 提供「连同成员本体一起删」勾选行；null = 纯解链删除。
  /// 返回 null = 取消。
  Future<FushiDestructiveConfirmResult?> confirmDetailCollectionDelete({
    String? checkboxLabel,
    String? localFilesSubtitle,
    String? statisticsSubtitle,
    DeletionDisclosure? checkedDisclosure,
    String? deleteSubscriptionsLabel,
  }) {
    return showAppDialog<FushiDestructiveConfirmResult>(
      context: context,
      builder: (_) => FushiDestructiveConfirmDialog(
        title: t.delete_collection,
        message: t.delete_collection_confirm,
        confirmLabel: t.delete_collection,
        checkboxLabel: checkboxLabel,
        localFilesSubtitle: localFilesSubtitle,
        statisticsSubtitle: statisticsSubtitle,
        checkedDisclosure: checkedDisclosure,
        deleteSubscriptionsLabel: deleteSubscriptionsLabel,
      ),
    );
  }

  /// 「移出合集」确认（逐成员）：同走 [FushiDestructiveConfirmDialog]。true = 确认。
  Future<bool> confirmDetailRemoveMember() async {
    final FushiDestructiveConfirmResult? result =
        await showAppDialog<FushiDestructiveConfirmResult>(
          context: context,
          builder: (_) => FushiDestructiveConfirmDialog(
            title: t.collection_remove_member,
            message: t.collection_remove_member_confirm,
            confirmLabel: t.collection_remove_member,
            leadingIcon: Icons.remove_circle_outline,
          ),
        );
    return result != null;
  }
}
