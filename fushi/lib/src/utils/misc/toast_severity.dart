/// 应用内短时通知的**语义**与配色，供两套互不相干的通知系统共用：
/// 底部 [FushiToast]（`fushi_toast.dart`）与视频页左上角 OSD
/// （`video_fushi/volume_osd.part.dart`）。
///
/// 独立成文件而不是塞进 `fushi_toast.dart`：视频页有一条守卫测试禁止它出现
/// `FushiToast.show`（BUG-931，两套通知必须各归各位），若语义枚举住在 toast 文件
/// 里，视频页就得为了一个枚举 import 整套 toast API——那正是守卫想避免的耦合。
///
/// 背景：改这套之前，326 个 `FushiToast.show` 里 325 个走默认无色（其中 170 余条
/// 是失败、70 余条是成功），70 个 `_showOsd` 100% 无色，只有 18 个制卡 toast 有颜色。
/// 用户只能靠读文字分辨「成了还是崩了」。
library;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 通知语义。
///
/// [neutral] 保留旧观感（主题 inverseSurface / OSD 灰，无图标），用于纯信息提示。
enum ToastSeverity { neutral, info, success, warning, error }

/// 把 [ToastSeverity] 映射成 (背景色, 前景色, 图标)。[ToastSeverity.neutral] 返回
/// null＝不着色，交回各系统的主题默认（旧行为）。
///
/// 图标是 M3E 语义符号（FushiIcons，实心版作状态徽记）；Apple 设计系统下 FushiIcon
/// 渲染时自动换成同语义 SF 符号。
///
/// 用固定 Material 800 色阶而非主题取色：保证四态在任意主题下语义清晰、对比达标，
/// 也让无 BuildContext 的降级路径（独立弹窗 Activity 的原生 toast）能复用同一配色。
/// **每态都带图标**——e-ink（灰阶）与色觉障碍下颜色会塌掉，图标形状是那时唯一的
/// 区分手段（与 `game_diagnostics_page` 的 e-ink 降级同口径）。
({Color background, Color foreground, IconData icon})? toastSeverityPalette(
  ToastSeverity severity,
) {
  switch (severity) {
    case ToastSeverity.neutral:
      return null;
    case ToastSeverity.success:
      return (
        background: const Color(0xFF2E7D32), // green 800
        foreground: Colors.white,
        icon: FushiIcons.filled(FushiIcons.success),
      );
    case ToastSeverity.warning:
      return (
        background: const Color(0xFFEF6C00), // orange 800
        // orange 800 配白字仅约 3.08:1；黑字约 6.81:1，满足普通正文 4.5:1。
        foreground: Colors.black,
        icon: FushiIcons.filled(FushiIcons.warning),
      );
    case ToastSeverity.error:
      return (
        background: const Color(0xFFC62828), // red 800
        foreground: Colors.white,
        icon: FushiIcons.filled(FushiIcons.error),
      );
    case ToastSeverity.info:
      return (
        background: const Color(0xFF1565C0), // blue 800
        foreground: Colors.white,
        icon: FushiIcons.filled(FushiIcons.info),
      );
  }
}

/// TODO-1325 #6: 制卡结果 toast 的语义状态。决定 MD3 toast 的着色与 Material 图标，
/// 让「加入了 / 已存在 / 失败 / 制卡中」一眼可辨，而不再只靠弹窗里 mine 按钮的图标变化。
/// [queued]：卡存进了设备端待发制卡队列，稍后补发（不是失败，也还没进 Anki）。
enum MineToastStatus { added, duplicate, failed, pending, queued }

/// 把 [MineToastStatus] 映射成 toast 的 (背景色, 前景色, 图标)。用固定 Material 色阶
/// （绿/橙/红/蓝）而非主题取色，保证四态在任意主题下都语义清晰、对比达标；也让无
/// BuildContext 的降级路径（独立弹窗 Activity）能直接复用同一配色。
({Color background, Color foreground, IconData icon}) mineToastPalette(
  MineToastStatus status,
) {
  switch (status) {
    case MineToastStatus.added:
      return (
        background: const Color(0xFF2E7D32), // green 800
        foreground: Colors.white,
        icon: FushiIcons.filled(FushiIcons.success),
      );
    case MineToastStatus.duplicate:
      return (
        background: const Color(0xFFEF6C00), // orange 800
        foreground: Colors.black,
        icon: FushiIcons.filled(FushiIcons.libraryAdd),
      );
    case MineToastStatus.failed:
      return (
        background: const Color(0xFFC62828), // red 800
        foreground: Colors.white,
        icon: FushiIcons.filled(FushiIcons.error),
      );
    case MineToastStatus.pending:
      return (
        background: const Color(0xFF1565C0), // blue 800
        foreground: Colors.white,
        icon: FushiIcons.sync,
      );
    case MineToastStatus.queued:
      return (
        background: const Color(0xFF1565C0), // blue 800
        foreground: Colors.white,
        icon: FushiIcons.schedule,
      );
  }
}

/// 制卡状态 → 通用语义。让视频页左上角 OSD 与底部制卡 toast 说同一门颜色语言
/// （`duplicate` 是「已存在」而非失败，落在 warning 而不是 error）。
ToastSeverity mineToastSeverity(MineToastStatus status) {
  switch (status) {
    case MineToastStatus.added:
      return ToastSeverity.success;
    case MineToastStatus.duplicate:
      return ToastSeverity.warning;
    case MineToastStatus.failed:
      return ToastSeverity.error;
    case MineToastStatus.pending:
    case MineToastStatus.queued:
      return ToastSeverity.info;
  }
}
