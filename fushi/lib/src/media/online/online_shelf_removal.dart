import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_history_page.dart'
    show ReaderHistoryDeleteDialog;
import 'package:fushi/src/sync/deletion_disclosure.dart';
import 'package:fushi/src/sync/deletion_prompt_preferences.dart';
import 'package:fushi/src/sync/deletion_propagation_availability.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';

/// 在线作品页「移出书架」的确认框：与书架长按删除**同一个**对话框（披露 + 「同步
/// 删除」范围 + 记住选择），删除传播语义因此一致——用户选了同步删除，对端也跟着删。
///
/// 漫画作品页与小说作品页共用（2026-09-27「浏览」阶段 2 从 `MangaSeriesPage` 抽出）。
/// 返回 null = 用户取消。
Future<DeleteDecision?> confirmRemoveOnlineWorkFromShelf({
  required BuildContext context,
  required AppModel appModel,
  required String title,
  required String message,
  String? statisticsSubtitle,
}) async {
  final bool canSyncEverywhere = await hasDeletionPropagationChannel(
    SyncRepository(appModel.database),
  );
  final DeletePromptPreferenceStore preferenceStore =
      DeletePromptPreferenceStore(appModel.database);
  final DeletePromptRememberedChoices? rememberedChoices = await preferenceStore
      .load();
  if (!context.mounted) return null;
  return showAppDialog<DeleteDecision>(
    context: context,
    builder: (BuildContext ctx) => ReaderHistoryDeleteDialog(
      title: title,
      message: message,
      disclosure: buildDeletionDisclosure(
        target: DeletionDisclosureTarget.shelfBook,
      ),
      showSyncScope: canSyncEverywhere,
      statisticsSubtitle: statisticsSubtitle,
      rememberedChoices: rememberedChoices,
      onPersistChoices: preferenceStore.write,
      onConfirm: (DeleteDecision d) => Navigator.pop(ctx, d),
    ),
  );
}
