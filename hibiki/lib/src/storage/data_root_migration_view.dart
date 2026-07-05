import 'package:flutter/material.dart';

import 'package:hibiki/i18n/strings.g.dart';

/// TODO-959：桌面「数据存储位置」整目录迁移期间的全屏遮罩内容。
///
/// 迁移会 `closeDatabase()`（置 `isInitialised=false`）以释放 Windows 文件锁；若不拦截，
/// 根 widget 会回退到裸 loading（近黑底 + 转圈），搬大库数秒~数分钟被误判死机。本视图给出
/// 明确文案「正在迁移数据，请勿关闭」+ 进度条 + 主题色背景，由 `main.dart` 在 loading 分支
/// **之前**渲染。抽成独立 widget 以便 widget 测试直接断言「不是裸 loading、背景非纯黑」。
class DataRootMigrationView extends StatelessWidget {
  const DataRootMigrationView({
    super.key,
    this.progress,
    this.background,
    this.failure,
    this.onRestart,
  });

  /// 跨盘复制进度 (已复制文件数, 总文件数)；同盘 rename 瞬时完成不产生进度 → null →
  /// 显示不确定进度条。
  final ({int copied, int total})? progress;

  /// 遮罩背景色。传入 splash 色；为 null 由本视图回退到主题 `surface`（绝不留纯黑/透明）。
  final Color? background;

  /// TODO-1182：迁移失败原因文案。非 null → 本视图切到「失败」态：显示原因 + 可执行建议
  /// （选空目录 / 别选安装目录 / 别选有文件占用的位置）+ 重启按钮，取代进度条。这样即便
  /// 迁移过程中根 widget 树被换掉（设置页 State 已 unmount），用户仍能醒目看到失败原因。
  final String? failure;

  /// 用户在失败态点「重启」时触发；由 `main.dart` 注入真正的重启逻辑，测试注入 no-op。
  final VoidCallback? onRestart;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    if (failure != null) return _buildFailure(context, cs, failure!);
    final ({int copied, int total})? p = progress;
    final double? fraction =
        p != null && p.total > 0 ? p.copied / p.total : null;
    return Scaffold(
      backgroundColor: background ?? cs.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.drive_file_move_outlined, size: 48, color: cs.primary),
              const SizedBox(height: 16),
              Text(
                t.data_storage_migrate_overlay_title,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                t.data_storage_migrate_overlay_warning,
                style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: 240,
                child: LinearProgressIndicator(value: fraction),
              ),
              if (p != null && p.total > 0) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  t.data_storage_migrate_overlay_progress(
                    copied: p.copied,
                    total: p.total,
                  ),
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// TODO-1182：失败态全屏视图：错误图标 + 标题 + 具体原因 + 可执行建议 + 重启按钮。
  Widget _buildFailure(BuildContext context, ColorScheme cs, String reason) {
    return Scaffold(
      backgroundColor: background ?? cs.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.error_outline, size: 48, color: cs.error),
                const SizedBox(height: 16),
                Text(
                  t.data_storage_migrate_failed_title,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: cs.onSurface,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  reason,
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                Text(
                  t.data_storage_migrate_failed_suggestions,
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: onRestart,
                  icon: const Icon(Icons.restart_alt),
                  label: Text(t.data_storage_migrate_failed_restart),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
