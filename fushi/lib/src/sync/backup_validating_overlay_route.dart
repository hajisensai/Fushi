import 'package:flutter/material.dart';

import 'package:fushi/src/models/app_model.dart' show BackupImportPhase;
import 'package:fushi/src/sync/backup_import_overlay_view.dart';

/// BUG-2106：「正在读取备份…」（[BackupImportPhase.validating]）遮罩的宿主 = 压在
/// **调用方页面之上的不可 pop 模态路由**，而不是换根。
///
/// 原实现让 `main.dart` 的根 build 在 `backupImportActive` 时返回另一个根 widget
/// （`TranslationProvider(MaterialApp(home: BackupImportOverlayView))`），与正常分支的
/// `KeyedSubtree(TranslationProvider(MaterialApp(navigatorKey: ...)))` **根类型不同** →
/// 整棵 app 子树连 `Navigator` 一起 unmount：调用方页面及其全部 State 当场蒸发。设置页
/// 丢一条路由无感（导入结束后回首页即可），但**引导向导**丢的是整个流程：
///   * 向导的 `_stepIndex` / `_selected` 随 State 消失，用户被踢回第 1 步（观感=「强制退出引导」）；
///   * `home_page.dart` 里 `await Navigator.push(OnboardingWizardPage)` 的 future 在
///     Navigator 被 dispose 后**永不完成**，其后的 `setOnboardingCompleted(true)` 永不执行；
///   * 校验阶段的失败/无效提示要在「切回正常树 + navigator 重新挂载」之后才能弹，
///     `_rootContextAfterOverlay` 只等 2 帧，拿不到就静默 return —— 于是「什么提示都没有」。
///
/// 相位边界（不能一刀切）：`validating` 只是读 zip + 生成合并预览，**DB 仍打开**、可取消，
/// 没有任何理由卸载整棵树；`running` / `done` / `failed` 之前先 `closeDatabase()`，此时页面
/// 若还挂着就会去查已关闭的库，**必须**换根独占（且随后重启进程）。所以只把 `validating`
/// 从换根改成模态路由，`running` 之后保持原样。
///
/// 用 `opaque: true` 挡住底下页面的绘制与命中测试；`PopScope(canPop: false)` 让系统返回 /
/// 手势返回在校验期不再把底下的调用方路由 pop 掉（它是本遮罩之下的页面，back 事件由
/// `WidgetsApp` 的 Navigator 处理，压在栈顶的本路由才是接收方）。**因此摘除它必须走
/// `Navigator.removeRoute`**：`pop` 会被 `PopScope` 拦下（同 BUG-2043 的接管手法）。
Route<void> buildBackupValidatingOverlayRoute({
  required VoidCallback onCancel,
  Color? background,
}) {
  return PageRouteBuilder<void>(
    opaque: true,
    barrierDismissible: false,
    transitionDuration: Duration.zero,
    reverseTransitionDuration: Duration.zero,
    pageBuilder: (BuildContext _, Animation<double> __, Animation<double> ___) =>
        PopScope(
      canPop: false,
      child: BackupImportOverlayView(
        phase: BackupImportPhase.validating,
        background: background,
        // validating 相位本视图不渲染「立即重启」出口（只有 done/failed 才渲染），
        // 故这里给一个不可达的 no-op，而不是把重启能力泄漏到校验期。
        onRestart: _unreachableRestart,
        onCancel: onCancel,
      ),
    ),
  );
}

void _unreachableRestart() {}
