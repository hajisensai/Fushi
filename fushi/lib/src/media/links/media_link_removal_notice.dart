/// 移除 / 否决作品关联后的提示条：带「撤销」，点下把这次移除原样恢复。
///
/// 「同一作品」区块（卡片角上的「移除 AI 关联」、卡片菜单「移除关联」、建议卡
/// 「不相关」）与关系网页的否决边共用。否决墓碑会让推断永不再提议这一对，误点
/// 之后没有撤销就只能手动重连（反馈 bkrkQrYhnX）。
library;

import 'dart:async';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/links/work_plans.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// 撤销按钮停留多久（带动作的提示条不常驻：过了这段时间就不再能撤销）。
const Duration kMediaLinkRemovalUndoVisible = Duration(seconds: 6);

/// 移除 [ids]（[rejectMediaLinks]），然后弹「已移除关联 · 撤销」。没有
/// [ScaffoldMessenger]（极少的独立宿主）时退回普通 toast——那里点不了撤销。
Future<void> removeMediaLinksWithUndo(
  BuildContext context,
  FushiDatabase db,
  Iterable<MediaLinkId> ids,
) async {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final MediaLinkRemovalUndo undo = await rejectMediaLinks(db, ids);
  if (messenger == null || !messenger.mounted || undo.isEmpty) {
    FushiToast.show(msg: t.media_link_removed, severity: ToastSeverity.info);
    return;
  }
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      FushiSnackBar(
        key: const ValueKey<String>('media-link-removed-snack'),
        content: Text(t.media_link_removed),
        duration: kMediaLinkRemovalUndoVisible,
        persist: false,
        action: SnackBarAction(
          key: const ValueKey<String>('media-link-removed-undo'),
          label: t.undo,
          onPressed: () => unawaited(_revert(db, undo)),
        ),
      ),
    );
}

Future<void> _revert(FushiDatabase db, MediaLinkRemovalUndo undo) async {
  final int restored = await undo.revert(db);
  FushiToast.show(
    msg: restored > 0 ? t.media_link_restored : t.ai_agent_undo_partial,
    severity: restored > 0 ? ToastSeverity.success : ToastSeverity.info,
  );
}
