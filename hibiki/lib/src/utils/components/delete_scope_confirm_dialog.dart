import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/sync/deletion_propagation.dart' show DeleteScope;
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

/// 全 app 统一的「删除确认（可选删除范围）」弹窗本体：正文 + 可选「从所有设备
/// 删除」勾选行（[showSyncScope]，默认显示、默认不勾）+「取消 / 破坏性确认」
/// footer；chrome 恒为 `HibikiDialogFrame(maxWidth: 420, maxHeightFactor: 0.74)`
/// + `HibikiModalSheetFrame`（MD3 静态守卫对本文件断言真实 chrome）。
///
/// 三处薄壳共用本体（2026-07-24 去重，此前三份 build 逐字相同）：
/// - `showDeleteScopeConfirm`（`lib/src/sync/deletion_prompt.dart`）：
///   pop 出 [DeleteScope]?（取消 null）；
/// - `ReaderHistoryDeleteDialog`（书架 `reader_history/dialogs.part.dart`）：
///   确认走 onConfirm 回调、由调用方自行 pop；
/// - `StatDeleteConfirmDialog` / `StatClearAllConfirmDialog`（统计页）：
///   pop bool、无勾选行。
///
/// pop 语义完全交给 [onCancel] / [onConfirm]，本体自身绝不 `Navigator.pop`——
/// 各宿主的返回值类型（`DeleteScope?` / `bool`）与回调时序因此保持原样。
/// 与 `HibikiDestructiveConfirmDialog`（自带 pop 协议 + 通用勾选行）职责不同：
/// 本体专供「删除范围」语义（勾选行带 sync / keep-local 动态副标题）与外置 pop。
class DeleteScopeConfirmDialog extends StatefulWidget {
  const DeleteScopeConfirmDialog({
    required this.title,
    required this.message,
    required this.onCancel,
    required this.onConfirm,
    this.showSyncScope = true,
    this.leadingIcon = Icons.delete_outline,
    this.confirmLabel,
    super.key,
  });

  final String title;
  final String message;

  /// false 时隐藏「从所有设备删除」勾选行，[onConfirm] 恒回
  /// [DeleteScope.keepLocalOnly]（用于不参与删除传播的实体 / 场景）。
  final bool showSyncScope;

  /// header 图标；统计「清空全部」用 [Icons.delete_sweep_outlined]。
  final IconData leadingIcon;

  /// 确认按钮文案；null 用 t.dialog_delete。
  final String? confirmLabel;

  /// 「取消」按钮回调（宿主决定 pop 出什么：null / false）。
  final VoidCallback onCancel;

  /// 确认按钮回调，回传用户选择的 [DeleteScope]
  /// （勾选=syncEverywhere / 不勾或无勾选行=keepLocalOnly）。
  final ValueChanged<DeleteScope> onConfirm;

  @override
  State<DeleteScopeConfirmDialog> createState() =>
      _DeleteScopeConfirmDialogState();
}

class _DeleteScopeConfirmDialogState extends State<DeleteScopeConfirmDialog> {
  bool _syncDelete = false;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: HibikiModalSheetFrame(
        title: widget.title,
        leadingIcon: widget.leadingIcon,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(widget.message, style: tokens.type.listSubtitle),
            if (widget.showSyncScope) ...[
              SizedBox(height: tokens.spacing.gap),
              AdaptiveSettingsRow(
                title: t.delete_scope_sync_everywhere,
                subtitle: _syncDelete
                    ? t.delete_scope_sync_everywhere_desc
                    : t.delete_scope_keep_local_desc,
                onTap: () => setState(() => _syncDelete = !_syncDelete),
                trailing: Icon(
                  _syncDelete ? Icons.check_box : Icons.check_box_outline_blank,
                  color: _syncDelete
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: <Widget>[
            adaptiveDialogAction(
              context: context,
              onPressed: widget.onCancel,
              child: Text(t.dialog_cancel),
            ),
            adaptiveDialogAction(
              context: context,
              isDestructiveAction: true,
              onPressed: () => widget.onConfirm(
                widget.showSyncScope && _syncDelete
                    ? DeleteScope.syncEverywhere
                    : DeleteScope.keepLocalOnly,
              ),
              child: Text(widget.confirmLabel ?? t.dialog_delete),
            ),
          ],
        ),
      ),
    );
  }
}
