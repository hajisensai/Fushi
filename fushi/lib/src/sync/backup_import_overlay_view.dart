import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart' show BackupImportPhase;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart'
    show FushiDialogHeroIcon, FushiHeroTone;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// TODO-1151：本地备份「导入/恢复」期间的全屏遮罩内容。
///
/// 导入会 `closeDatabase()`（置 `isInitialised=false`）以整体替换 DB + 内容树；旧实现
/// 只在设置行显示一个 24px 小圈、成功后延迟 500ms 直接 `exit(0)`，用户看到 app「突然
/// 消失」误以为失败。本视图镜像 [DataRootMigrationView] 的做法，由 `main.dart` 在
/// loading 分支**之前**渲染：
/// - [BackupImportPhase.validating]：选完文件后「正在读取备份…」+ 不确定进度条 +
///   **「取消」按钮**（DB 仍打开，此段只是 validate + 合并预览，可安全中断回设置页）。
///   根治大 zip 校验/预览数十秒只有 24px 小圈、无明显反馈的问题；
/// - [BackupImportPhase.running]：明确文案「正在导入备份，请勿关闭」+ **确定进度条**
///   （[progress] 有值时按字节走动，否则回退不确定动画）；
/// - [BackupImportPhase.done]：成功文案 + 绿色 ✓ + 「立即重启」按钮；
/// - [BackupImportPhase.failed]：失败原因 + **红色错误图标** + 「立即重启」按钮（根治
///   TODO-1183「导入失败却显绿✓成功」的误导）。点按后由 [onRestart] 退出/重启进程。
///
/// 抽成独立 widget 以便 widget 测试直接断言各阶段 UI（校验遮罩 / 取消按钮 / 导入遮罩 /
/// 确认按钮），且 [onRestart] / [onCancel] 可注入，测试里不会真正 `exit(0)`。
class BackupImportOverlayView extends StatelessWidget {
  const BackupImportOverlayView({
    super.key,
    required this.phase,
    required this.onRestart,
    this.onCancel,
    this.message,
    this.background,
    this.progress,
  });

  /// 当前导入阶段。
  final BackupImportPhase phase;

  /// 用户在 [BackupImportPhase.done] 点「立即重启」时触发；由 `main.dart` 注入真正的
  /// 退出/重启逻辑（[FlutterExitApp.exitApp] / `exit(0)`）。测试注入 no-op 计数器。
  final VoidCallback onRestart;

  /// 用户在 [BackupImportPhase.validating] 点「取消」时触发；由 `main.dart` 注入
  /// [AppModel.cancelBackupValidating]（作废 in-flight 校验 token 并退出遮罩回设置页）。
  /// 仅 validating 相位显示取消按钮；为 null 时不渲染（防御）。
  final VoidCallback? onCancel;

  /// [BackupImportPhase.done] 时展示的结果文案（成功提示或失败原因）。
  final String? message;

  /// 遮罩背景色。传入 splash 色；为 null 由本视图回退到主题 `surface`（绝不留纯黑/透明）。
  final Color? background;

  /// TODO-1183：running 期的确定进度（0..1，来自 [AppModel.backupImportProgress]）。
  /// 监听它让**只有进度条**随每 4MB 落盘重建。为 null（或值 ≤0）时回退到不确定动画。
  /// validating 期忽略它（读取/预览无字节进度，始终走不确定动画）。
  final ValueListenable<double>? progress;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool validating = phase == BackupImportPhase.validating;
    final bool running = phase == BackupImportPhase.running;
    final bool failed = phase == BackupImportPhase.failed;
    // validating/running 都是「进行中」：显示进度条、不显示「立即重启」出口。
    final bool inProgress = validating || running;
    // 状态图标：validating/running=恢复中；failed=红色错误（根治「失败显绿✓」）；done=绿色 ✓。
    final IconData statusIcon = inProgress
        ? FushiIcons.restoreBackup
        : failed
            ? FushiIcons.error
            : FushiIcons.success;
    // M3E：状态图标是形状库饼干底的 hero（进行中 primary、失败 errorContainer、
    // 完成 tertiary 色块）；Apple 下 hero 退化成单色字形，完成态用系统绿。
    final FushiHeroTone heroTone = failed
        ? FushiHeroTone.destructive
        : (inProgress ? FushiHeroTone.primary : FushiHeroTone.tertiary);
    final Color? appleStatusColor = isGlassDesign(context)
        ? (failed
            ? cs.error
            : (!inProgress ? appleColorsOf(context).success : cs.primary))
        : null;
    final FushiTypography type = context.fushiType;
    // 主行文案：validating=「正在读取备份…」；running=「正在导入备份」；done/failed=结果文案。
    final String title = validating
        ? t.backup_import_validating_title
        : running
            ? t.backup_import_overlay_title
            : (message ?? t.backup_import_success);
    // 副行文案（仅进行中）：validating=校验提示；running=「请勿关闭」警示。
    final String? subtitle = validating
        ? t.backup_import_validating_hint
        : running
            ? t.backup_import_overlay_warning
            : null;
    int slot = 0;
    Widget stagger(Widget child) =>
        FushiStaggeredEntrance(index: slot++, child: child);
    return Scaffold(
      backgroundColor: background ?? cs.surface,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  stagger(
                    FushiDialogHeroIcon(
                      key: ValueKey<IconData>(statusIcon),
                      icon: statusIcon,
                      tone: heroTone,
                      color: appleStatusColor,
                      size: 96,
                    ),
                  ),
                  const SizedBox(height: 24),
                  stagger(
                    Text(
                      title,
                      style: type.headlineSmallEmphasized
                          .copyWith(color: cs.onSurface),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  if (subtitle != null) ...<Widget>[
                    const SizedBox(height: 12),
                    stagger(
                      Text(
                        subtitle,
                        style: type.bodyMedium
                            .copyWith(color: cs.onSurfaceVariant),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ],
                  const SizedBox(height: 32),
                  if (inProgress)
                    stagger(
                      // validating：读取/预览无字节进度 → 始终不确定动画。
                      // running：progress 有值走确定条 + Display 大号百分比，
                      // 否则不确定动画。
                      (validating || progress == null)
                          ? const SizedBox(
                              width: 280,
                              child: FushiLinearProgressIndicator(),
                            )
                          : ValueListenableBuilder<double>(
                              valueListenable: progress!,
                              builder: (
                                BuildContext context,
                                double value,
                                _,
                              ) =>
                                  _ImportProgress(value: value),
                            ),
                    ),
                  // validating：进度条下给「取消」出口（中断读取/预览回设置页）。
                  if (validating && onCancel != null) ...<Widget>[
                    const SizedBox(height: 24),
                    stagger(
                      FushiOutlinedButton.icon(
                        onPressed: onCancel,
                        icon: const FushiIcon(FushiIcons.close),
                        label: Text(t.dialog_cancel),
                      ),
                    ),
                  ],
                  // done/failed：「立即重启」确认出口。
                  if (!inProgress)
                    stagger(
                      FushiFilledButton.icon(
                        onPressed: onRestart,
                        autofocus: true,
                        size: FushiButtonSize.m,
                        icon: const FushiIcon(FushiIcons.restart),
                        label: Text(t.backup_import_restart_button),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// running 期的确定进度：Display 大号等宽百分比 + M3E 波浪进度条。value ≤0
/// 时（首个 chunk 落盘前）先走不确定动画、不显示数字，避免「卡在 0%」的观感。
class _ImportProgress extends StatelessWidget {
  const _ImportProgress({required this.value});

  final double value;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool determinate = value > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (determinate) ...<Widget>[
          Text(
            '${(value.clamp(0.0, 1.0) * 100).round()}%',
            style: context.fushiType.displaySmallEmphasized.tabular
                .copyWith(color: cs.primary),
          ),
          const SizedBox(height: 12),
        ],
        SizedBox(
          width: 280,
          child: FushiLinearProgressIndicator(
            value: determinate ? value : null,
          ),
        ),
      ],
    );
  }
}
