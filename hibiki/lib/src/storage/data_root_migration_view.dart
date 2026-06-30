import 'package:flutter/material.dart';

import 'package:hibiki/i18n/strings.g.dart';

/// TODO-959：桌面「数据存储位置」整目录迁移期间的全屏遮罩内容。
///
/// 迁移会 `closeDatabase()`（置 `isInitialised=false`）以释放 Windows 文件锁；若不拦截，
/// 根 widget 会回退到裸 loading（近黑底 + 转圈），搬大库数秒~数分钟被误判死机。本视图给出
/// 明确文案「正在迁移数据，请勿关闭」+ 进度条 + 主题色背景，由 `main.dart` 在 loading 分支
/// **之前**渲染。抽成独立 widget 以便 widget 测试直接断言「不是裸 loading、背景非纯黑」。
class DataRootMigrationView extends StatelessWidget {
  const DataRootMigrationView({super.key, this.progress, this.background});

  /// 跨盘复制进度 (已复制文件数, 总文件数)；同盘 rename 瞬时完成不产生进度 → null →
  /// 显示不确定进度条。
  final ({int copied, int total})? progress;

  /// 遮罩背景色。传入 splash 色；为 null 由本视图回退到主题 `surface`（绝不留纯黑/透明）。
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
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
}
