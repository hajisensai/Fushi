/// Android 老安装「把书库移到可访问的文件夹」一次性提示。
///
/// 全新安装的书库直接落外部 app 专属目录 `Android/data/<包名>/files/data`
/// （[AppPaths.androidDocumentsLocationPrefKey]）。升级上来的老安装锚定内部、不自动搬：
/// 内部 `app_flutter` 到外部跨挂载点，只能逐文件复制，GB 级书库在启动期悄悄搬会卡死
/// 启动画面。所有者 2026-11-22 拍板：老用户弹一次提示，确认后走带进度遮罩的迁移
/// （与设置「数据存储位置」同一条 `startAndroidDocumentsMigration`），迁完自动重启。
///
/// 标记在弹框**之前**落：弹框期间杀进程也不会每次启动都弹；之后随时可在设置里迁。
///
/// 本文件不 import `AppModel` / 设置 schema：迁移入口由调用方（首页）注入，否则首页 →
/// 本文件 → AppModel 会把它拉进 lib/ 最大 import 环（`import_cycle_guard_test.dart`）。
library;

import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

/// 纯判定（测试钉住）：只有 Android、书库仍在内部、且没处理过时才弹。
bool shouldShowAndroidStorageMovePrompt({
  required bool isAndroid,
  required bool documentsExternal,
  required bool prompted,
}) => isAndroid && !documentsExternal && !prompted;

/// 首页首帧调用：按判定落标记并弹提示；用户选「现在迁移」就调 [startMigration]（首页传
/// `startAndroidDocumentsMigration(toExternal: true)`：遮罩接管界面，成功后自动重启）。
Future<void> maybeShowAndroidStorageMovePrompt({
  required BuildContext context,
  required Future<void> Function() startMigration,
}) async {
  if (!Platform.isAndroid) return;
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  final bool show = shouldShowAndroidStorageMovePrompt(
    isAndroid: true,
    documentsExternal: await AppPaths.androidDocumentsAreExternal(),
    prompted:
        prefs.getBool(AppPaths.androidDocumentsMovePromptedPrefKey) ?? false,
  );
  if (!show) return;
  await prefs.setBool(AppPaths.androidDocumentsMovePromptedPrefKey, true);
  if (!context.mounted) return;
  final bool move = await showAndroidStorageMovePromptDialog(context);
  if (!move || !context.mounted) return;
  await startMigration();
}

/// 提示框本体，返回用户是否选了「现在迁移」。设置路径取界面上真实显示的标签。
Future<bool> showAndroidStorageMovePromptDialog(BuildContext context) async {
  final bool? move = await showAppDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => FushiAlertDialog(
      key: const ValueKey<String>('android_storage_move_prompt'),
      icon: const FushiIcon(FushiIcons.moveFile),
      title: Text(t.data_storage_android_prompt_title),
      content: Text(
        t.data_storage_android_prompt_body(
          settings: t.settings,
          storage: t.settings_destination_storage,
        ),
      ),
      actions: <Widget>[
        FushiTextButton(
          key: const ValueKey<String>('android_storage_move_prompt_later'),
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(t.data_storage_android_prompt_later),
        ),
        FushiTextButton(
          key: const ValueKey<String>('android_storage_move_prompt_move'),
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(t.data_storage_android_prompt_move),
        ),
      ],
    ),
  );
  return move ?? false;
}
