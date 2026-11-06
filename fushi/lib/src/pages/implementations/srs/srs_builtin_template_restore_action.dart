// 「恢复内置模板」的界面入口（笔记类型编辑页、模板编辑页、卡片外观页共用一份）：确认 → 写回内置定义 →
// 带「撤销」的提示条。存储层命令见 fushi_engine 的 srs_builtin_template_restore.dart。
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_engine/srs/srs_builtin_template_restore.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/srs/srs_providers.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';

/// 先确认再把内置笔记类型 [noteTypeId] 的内置模板 / CSS 写回代码定义；写了就推进刷新信号、调 [onChanged]
/// （页面重读），并给出可撤销的提示条（撤销后同样推进刷新信号、调 [onChanged]）。返回是否写了记录。
Future<bool> confirmAndRestoreBuiltinTemplates(
  BuildContext context, {
  required SrsDbStore store,
  required String noteTypeId,
  required VoidCallback onChanged,
}) async {
  final bool ok = await showFushiConfirmDialog(
    context: context,
    title: t.srs_note_types_builtin_restore,
    message: t.srs_note_types_builtin_restore_confirm,
    confirmLabel: t.srs_note_types_builtin_restore,
    cancelLabel: t.cancel,
    icon: FushiIcons.refresh,
  );
  if (!ok || !context.mounted) return false;
  // 提示条的撤销可能在页面关掉之后才按：刷新信号走容器，不依赖页面的 WidgetRef。
  final ProviderContainer container = ProviderScope.containerOf(
    context,
    listen: false,
  );
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  void bump() => container.read(srsRevisionProvider.notifier).state++;

  final SrsBuiltinTemplateRestore? restore = await store
      .restoreBuiltinTemplates(noteTypeId);
  if (restore == null) {
    FushiToast.show(msg: t.srs_note_types_builtin_restore_unchanged);
    return false;
  }
  bump();
  onChanged();
  messenger?.showSnackBar(
    FushiSnackBar(
      content: Text(t.srs_note_types_builtin_restore_done),
      action: SnackBarAction(
        label: t.undo,
        onPressed: () =>
            srsRunLogged('SrsBuiltinTemplateRestore.undo', () async {
              await store.undoBuiltinTemplateRestore(restore);
              bump();
              onChanged();
            }),
      ),
    ),
  );
  return true;
}
