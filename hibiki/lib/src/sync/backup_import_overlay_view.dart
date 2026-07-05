import 'package:flutter/material.dart';

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/models/app_model.dart' show BackupImportPhase;

/// TODO-1151：本地备份「导入/恢复」期间的全屏遮罩内容。
///
/// 导入会 `closeDatabase()`（置 `isInitialised=false`）以整体替换 DB + 内容树；旧实现
/// 只在设置行显示一个 24px 小圈、成功后延迟 500ms 直接 `exit(0)`，用户看到 app「突然
/// 消失」误以为失败。本视图镜像 [DataRootMigrationView] 的做法，由 `main.dart` 在
/// loading 分支**之前**渲染：
/// - [BackupImportPhase.running]：明确文案「正在导入备份，请勿关闭」+ 不确定进度条；
/// - [BackupImportPhase.done]：结果文案（成功/失败）+「立即重启」按钮，点按后由
///   [onRestart] 退出/重启进程（根治「突然消失」＝以为失败）。
///
/// 抽成独立 widget 以便 widget 测试直接断言两阶段 UI（遮罩出现 / 确认按钮出现），
/// 且 [onRestart] 可注入，测试里不会真正 `exit(0)`。
class BackupImportOverlayView extends StatelessWidget {
  const BackupImportOverlayView({
    super.key,
    required this.phase,
    required this.onRestart,
    this.message,
    this.background,
  });

  /// 当前导入阶段。
  final BackupImportPhase phase;

  /// 用户在 [BackupImportPhase.done] 点「立即重启」时触发；由 `main.dart` 注入真正的
  /// 退出/重启逻辑（[FlutterExitApp.exitApp] / `exit(0)`）。测试注入 no-op 计数器。
  final VoidCallback onRestart;

  /// [BackupImportPhase.done] 时展示的结果文案（成功提示或失败原因）。
  final String? message;

  /// 遮罩背景色。传入 splash 色；为 null 由本视图回退到主题 `surface`（绝不留纯黑/透明）。
  final Color? background;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool running = phase == BackupImportPhase.running;
    return Scaffold(
      backgroundColor: background ?? cs.surface,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                running ? Icons.settings_backup_restore : Icons.check_circle,
                size: 48,
                color: cs.primary,
              ),
              const SizedBox(height: 16),
              // running：主行=「正在导入备份」，副行=「请勿关闭」警示；
              // done：主行直接=结果文案（成功/失败），不再重复副行。
              Text(
                running
                    ? t.backup_import_overlay_title
                    : (message ?? t.backup_import_success),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: cs.onSurface,
                ),
                textAlign: TextAlign.center,
              ),
              if (running) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  t.backup_import_overlay_warning,
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              if (running)
                const SizedBox(
                  width: 240,
                  child: LinearProgressIndicator(),
                )
              else
                FilledButton.icon(
                  onPressed: onRestart,
                  icon: const Icon(Icons.restart_alt),
                  label: Text(t.backup_import_restart_button),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
