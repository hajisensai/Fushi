/// Android 书库在外部时「建议移回内部存储」一次性提示（BUG-5492）。
///
/// 3.4.0 曾把书库默认放 / 引导迁到外部 app 专属目录 `Android/data/<包名>/files/data`
/// （[AppPaths.androidDocumentsLocationPrefKey]）。那里对文件管理器、电脑 USB、手机清理
/// 工具都可见，整树被删时 Fushi 拦不住（反馈 cH-HbP8XkQ、MXX0xhQDgt：数据库还在、书与
/// 词典文件全没了）。现在新装一律落内部；已经在外部的安装不自动搬（GB 级书库启动期搬会
/// 卡死启动画面），弹一次提示，确认后走带进度遮罩的迁移（与设置「数据存储位置」同一条
/// `startAndroidDocumentsMigration(toExternal: false)`），迁完自动重启。
///
/// 标记在弹框**之前**落：弹框期间杀进程也不会每次启动都弹；之后随时可在设置里迁。
///
/// 同文件还有「书库文件不见了」提示（[maybeShowLibraryVanishedAlert]）：启动期
/// [LibrarySentinel.check] 发现哨兵没了且书库条目变少时留下现场，首页首帧读出来请用户
/// 带日志反馈，处理过（上传或稍后）就清掉，不反复弹。同一个入口也接书库内容对账
/// （[LibraryContentAudit]，BUG-5570）：哨兵还在、但数据库里成片的书 / 有声书文件不在时，
/// 弹「书库里有些文件不见了」，说明书还在数据库里、进度没丢，引导重新扫描来源 / 从同步恢复 /
/// 带日志反馈。
///
/// 本文件不 import `AppModel` / 设置 schema / 反馈页面簇：迁移入口与打开反馈提交页由调用方
/// （首页）注入，否则首页 → 本文件 → AppModel 会把它拉进 lib/ 最大 import 环
/// （`import_cycle_guard_test.dart`）。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi_engine/feedback/feedback_models.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/feedback/feedback_compose_prefill.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/library_content_audit.dart';
import 'package:fushi/src/storage/library_sentinel.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 纯判定（测试钉住）：只有 Android、书库在外部、且没弹过时才弹。
bool shouldShowAndroidStorageMoveBackPrompt({
  required bool isAndroid,
  required bool documentsExternal,
  required bool prompted,
}) => isAndroid && documentsExternal && !prompted;

/// 首页首帧调用：按判定落标记并弹提示；用户选「移回内部存储」就调 [startMigration]（首页
/// 传 `startAndroidDocumentsMigration(toExternal: false)`：遮罩接管界面，成功后自动重启）。
Future<void> maybeShowAndroidStorageMoveBackPrompt({
  required BuildContext context,
  required Future<void> Function() startMigration,
}) async {
  if (!Platform.isAndroid) return;
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final bool show = shouldShowAndroidStorageMoveBackPrompt(
    isAndroid: true,
    documentsExternal: await AppPaths.androidDocumentsAreExternal(),
    prompted:
        prefs.getBool(AppPaths.androidDocumentsMoveBackPromptedPrefKey) ??
        false,
  );
  if (!show) return;
  await prefs.setBool(AppPaths.androidDocumentsMoveBackPromptedPrefKey, true);
  if (!context.mounted) return;
  final bool move = await showAndroidStorageMoveBackPromptDialog(context);
  if (!move || !context.mounted) return;
  await startMigration();
}

/// 提示框本体，返回用户是否选了「移回内部存储」。设置路径取界面上真实显示的标签。
Future<bool> showAndroidStorageMoveBackPromptDialog(
  BuildContext context,
) async {
  final bool? move = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      key: const ValueKey<String>('android_storage_move_back_prompt'),
      icon: const FushiIcon(FushiIcons.moveFile),
      title: Text(t.data_storage_android_move_back_prompt_title),
      content: Text(
        t.data_storage_android_move_back_prompt_body(
          settings: t.settings,
          storage: t.settings_destination_storage,
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('android_storage_move_back_prompt_later'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(t.data_storage_android_prompt_later),
        ),
        FushiTextButton(
          key: const ValueKey<String>('android_storage_move_back_prompt_move'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(t.data_storage_android_move_internal),
        ),
      ],
    ),
  );
  return move ?? false;
}

/// 「书库文件不见了」的反馈预填（测试钉住）：分类「问题」默认带日志，正文是现场摘要。
FeedbackComposePrefill libraryVanishedFeedbackPrefill(
  LibraryVanishIncident incident,
) => FeedbackComposePrefill(
  category: FeedbackCategory.bug,
  title: t.data_storage_library_vanished_feedback_title,
  body:
      '${t.data_storage_library_vanished_feedback_body}\n\n${incident.describe()}',
);

/// 「书库里有些文件不见了」的反馈预填（测试钉住）：同 [libraryVanishedFeedbackPrefill]。
FeedbackComposePrefill libraryContentMissingFeedbackPrefill(
  LibraryContentLoss loss,
) => FeedbackComposePrefill(
  category: FeedbackCategory.bug,
  title: t.data_storage_library_content_missing_feedback_title,
  body:
      '${t.data_storage_library_content_missing_feedback_body}\n\n${loss.describe()}',
);

/// 等启动期对账最多这么久；没跑完就不等，现场留在文件里，下次启动再弹。
const Duration kLibraryContentAuditPromptWait = Duration(seconds: 10);

/// 首页首帧调用：[supportRoot] 的哨兵记录里有待处理现场就弹「书库文件不见了」；否则等
/// [contentAudit]（本次冷启动的书库内容对账，可为 null）跑完，内容对账留了现场就弹「书库里
/// 有些文件不见了」。用户选「上传日志」就调 [openFeedback]（首页传 `openFeedbackComposeWith`）；
/// 选「重新扫描来源」就调 [rescanSources]（首页按现有来源扫描入口逐个重扫书 / 漫画来源）。
/// [countRescannableSources] 为 0 时不给重新扫描按钮。
///
/// 弹之前先清现场：弹框期间杀进程不会每次启动都弹；书库要是再丢东西，下次启动会留下新的
/// 现场。两种现场同时在时只弹整树那一个（它已经说明了一切），内容对账的现场一并清掉、
/// 摘要并进反馈正文。
Future<void> maybeShowLibraryVanishedAlert({
  required BuildContext context,
  required Directory supportRoot,
  required Future<void> Function(
    BuildContext context,
    FeedbackComposePrefill prefill,
  )
  openFeedback,
  Future<LibraryContentAuditResult>? contentAudit,
  Future<int> Function()? countRescannableSources,
  Future<void> Function()? rescanSources,
}) async {
  final LibraryVanishIncident? incident = await LibrarySentinel.pendingIncident(
    supportRoot,
  );
  if (incident != null) {
    await LibrarySentinel.clearIncident(supportRoot);
    final LibraryContentLoss? alsoMissing = await _takeContentLoss(
      supportRoot,
      contentAudit,
    );
    if (!context.mounted) return;
    final bool upload = await showLibraryVanishedAlertDialog(context, incident);
    if (!upload || !context.mounted) return;
    final FeedbackComposePrefill prefill = libraryVanishedFeedbackPrefill(
      incident,
    );
    await openFeedback(
      context,
      alsoMissing == null
          ? prefill
          : FeedbackComposePrefill(
              category: prefill.category,
              title: prefill.title,
              body: '${prefill.body}\n${alsoMissing.describe()}',
            ),
    );
    return;
  }

  final LibraryContentLoss? loss = await _takeContentLoss(
    supportRoot,
    contentAudit,
  );
  if (loss == null || !context.mounted) return;
  final int sources = rescanSources == null || countRescannableSources == null
      ? 0
      : await countRescannableSources();
  if (!context.mounted) return;
  final LibraryContentMissingChoice choice =
      await showLibraryContentMissingDialog(
        context,
        loss,
        canRescan: sources > 0,
      );
  if (!context.mounted) return;
  switch (choice) {
    case LibraryContentMissingChoice.later:
      return;
    case LibraryContentMissingChoice.rescan:
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        FushiSnackBar(
          content: Text(t.data_storage_library_content_missing_rescan_started),
        ),
      );
      await rescanSources!();
    case LibraryContentMissingChoice.upload:
      await openFeedback(context, libraryContentMissingFeedbackPrefill(loss));
  }
}

/// 等对账跑完（最多 [kLibraryContentAuditPromptWait]），取出并清掉待提示的内容缺失现场。
Future<LibraryContentLoss?> _takeContentLoss(
  Directory supportRoot,
  Future<LibraryContentAuditResult>? contentAudit,
) async {
  if (contentAudit != null) {
    try {
      await contentAudit.timeout(kLibraryContentAuditPromptWait);
    } on Object {
      // 超时 / 出错：现场（若有）还在文件里，下次启动再弹。
    }
  }
  final LibraryContentLoss? loss = await LibraryContentAudit.pendingLoss(
    supportRoot,
  );
  if (loss != null) await LibraryContentAudit.clearPending(supportRoot);
  return loss;
}

/// 「书库里有些文件不见了」提示的选择。
enum LibraryContentMissingChoice { later, rescan, upload }

/// 提示框本体。[canRescan] 为 false（没有可重扫的书 / 漫画来源）时不给「重新扫描来源」。
Future<LibraryContentMissingChoice> showLibraryContentMissingDialog(
  BuildContext context,
  LibraryContentLoss loss, {
  required bool canRescan,
}) async {
  final LibraryContentMissingChoice? choice =
      await showAppDialog<LibraryContentMissingChoice>(
        context: context,
        builder: (BuildContext dialogContext) => FushiAlertDialog(
          key: const ValueKey<String>('library_content_missing_alert'),
          icon: const FushiIcon(FushiIcons.warning),
          title: Text(t.data_storage_library_content_missing_title),
          content: Text(
            t.data_storage_library_content_missing_body(
              missing: loss.missingRows,
              total: loss.checkedRows,
            ),
          ),
          actions: <Widget>[
            FushiTextButton(
              key: const ValueKey<String>('library_content_missing_later'),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(LibraryContentMissingChoice.later),
              child: Text(t.data_storage_android_prompt_later),
            ),
            if (canRescan)
              FushiTextButton(
                key: const ValueKey<String>('library_content_missing_rescan'),
                onPressed: () => Navigator.of(
                  dialogContext,
                ).pop(LibraryContentMissingChoice.rescan),
                child: Text(t.data_storage_library_content_missing_rescan),
              ),
            FushiTextButton(
              key: const ValueKey<String>('library_content_missing_upload'),
              onPressed: () => Navigator.of(
                dialogContext,
              ).pop(LibraryContentMissingChoice.upload),
              child: Text(t.data_storage_library_vanished_upload),
            ),
          ],
        ),
      );
  return choice ?? LibraryContentMissingChoice.later;
}

/// 提示框本体，返回用户是否选了「上传日志」。
Future<bool> showLibraryVanishedAlertDialog(
  BuildContext context,
  LibraryVanishIncident incident,
) async {
  final bool? upload = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      key: const ValueKey<String>('library_vanished_alert'),
      icon: const FushiIcon(FushiIcons.warning),
      title: Text(t.data_storage_library_vanished_title),
      content: Text(t.data_storage_library_vanished_body),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('library_vanished_alert_later'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(t.data_storage_android_prompt_later),
        ),
        FushiTextButton(
          key: const ValueKey<String>('library_vanished_alert_upload'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(t.data_storage_library_vanished_upload),
        ),
      ],
    ),
  );
  return upload ?? false;
}
