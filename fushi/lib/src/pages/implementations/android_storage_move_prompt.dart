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
/// 带日志反馈，处理过（上传或稍后）就清掉，不反复弹。
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

/// 首页首帧调用：[supportRoot] 的哨兵记录里有待处理现场就弹提示。用户选「上传日志」就调
/// [openFeedback]（首页传 `openFeedbackComposeWith`）。弹之前先清现场：弹框期间杀进程不会
/// 每次启动都弹；书库要是再被清空，下次启动会留下新的现场。
Future<void> maybeShowLibraryVanishedAlert({
  required BuildContext context,
  required Directory supportRoot,
  required Future<void> Function(
    BuildContext context,
    FeedbackComposePrefill prefill,
  )
  openFeedback,
}) async {
  final LibraryVanishIncident? incident = await LibrarySentinel.pendingIncident(
    supportRoot,
  );
  if (incident == null) return;
  await LibrarySentinel.clearIncident(supportRoot);
  if (!context.mounted) return;
  final bool upload = await showLibraryVanishedAlertDialog(context, incident);
  if (!upload || !context.mounted) return;
  await openFeedback(context, libraryVanishedFeedbackPrefill(incident));
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
