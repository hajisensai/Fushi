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
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/notice_dwell.dart';

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
/// [addedWithWarning]：卡建成了，但有一项需要用户知道的缺失（如单词音频下载失败）。
/// 它与 [added] 分开，是因为用户关掉「制卡成功提示」后，这一条仍必须弹出来——
/// 否则「没音频不知为何」又回来了（TODO-779）。
/// [overwritten]：覆盖了 Anki 里已有的卡（update 路径）。与 [added] 分开是为了配色——
/// 新制与覆盖此前同为绿色，用户分不出这次是新加了一张还是改掉了旧卡。
enum MineToastStatus {
  added,
  overwritten,
  addedWithWarning,
  duplicate,
  failed,
  pending,
  queued,
}

/// 「制卡提示」开关组（设置 → 制卡 → 制卡提示）对一条制卡结果 toast 的裁决。
///
/// * [showSuccess] 管 added / queued / pending：都是「收下了」的确认，阅读时弹在正文
///   上会挡字（反馈 zNuGKLIhmT）。pending 跟着关——它只是结果 toast 的过渡态，结果不弹
///   时它会独自停留 4 秒。
/// * [showDuplicate] 管 duplicate：用户明知是重复卡，提示是噪音（反馈 aK5wv0CnWf）。
/// * failed 与 addedWithWarning 恒弹：前者是这张卡没制成，后者是卡缺了东西，关掉
///   提示不该让用户错过它们。
bool mineToastShown(
  MineToastStatus status, {
  required bool showSuccess,
  required bool showDuplicate,
}) => switch (status) {
  MineToastStatus.added ||
  MineToastStatus.overwritten ||
  MineToastStatus.queued ||
  MineToastStatus.pending => showSuccess,
  MineToastStatus.duplicate => showDuplicate,
  MineToastStatus.addedWithWarning || MineToastStatus.failed => true,
};

/// 制卡结果通知「该不该说」的**唯一裁决点**（反馈 3aFpRYC6a1 / jYEPxVSrts /
/// iH6RY1kqQn：关了开关后阅读器、弹窗内提示、视频 OSD 仍在说）。
///
/// 制卡结果有三个说出口，全部先问这里：
/// * 底部 toast —— [FushiToast.showMine]；
/// * 查词弹窗按钮旁的就地提示 —— `MineFailureNotice.settle`（重复 / 失败原因随回包
///   交给 popup.js，被裁掉时回包标 `hostReported`、去掉 `message`，弹窗不再说）；
/// * 视频页左上角 OSD —— `_showMineOsd`（视频页禁止 import toast，见文件头）。
///
/// 住在这个文件而不是 `fushi_toast.dart`，理由同文件头：视频页要用它。
/// 各 entry point 拿到 `AppModel` 后经 [filter] 装上读偏好的闭包
/// （`AppModel.mineNoticeShown` → [mineToastShown]）；没装时一律说（存量行为）。
abstract final class MineNotices {
  static bool Function(MineToastStatus status) filter = _showEvery;

  static bool _showEvery(MineToastStatus status) => true;

  /// 这一类制卡结果此刻该不该告诉用户。闭包每次现读偏好，设置页改完立即生效。
  static bool shown(MineToastStatus status) => filter(status);
}

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
    case MineToastStatus.overwritten:
      return (
        background: const Color(0xFF6750A4), // M3 baseline primary（紫）
        foreground: Colors.white,
        icon: FushiIcons.filled(FushiIcons.swap),
      );
    case MineToastStatus.addedWithWarning:
      return (
        background: const Color(0xFFEF6C00), // orange 800
        foreground: Colors.black,
        icon: FushiIcons.filled(FushiIcons.warning),
      );
    case MineToastStatus.duplicate:
      // 「已存在」不是警告也不是失败：用青色（M3 tertiary 系），与「有缺失」的琥珀
      // 分开（用户 2026-11-22 重设计：两者此前同琥珀，意思却相反）。
      return (
        background: const Color(0xFF006874), // teal 40，白字约 6.1:1
        foreground: Colors.white,
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
/// （`duplicate` 是「已存在、不用管」，落在 info，不与「有缺失」同为 warning）。
ToastSeverity mineToastSeverity(MineToastStatus status) {
  switch (status) {
    case MineToastStatus.added:
    case MineToastStatus.overwritten:
      return ToastSeverity.success;
    case MineToastStatus.addedWithWarning:
      return ToastSeverity.warning;
    case MineToastStatus.failed:
      return ToastSeverity.error;
    case MineToastStatus.duplicate:
    case MineToastStatus.pending:
    case MineToastStatus.queued:
      return ToastSeverity.info;
  }
}

/// 制卡结果卡片（[FushiMineNoticeCard]）的 M3 tonal 三色 + 图标。
///
/// * [container] / [onContainer]：卡片底与文字（正文对比 ≥ 7:1）；
/// * [accent]：图标色块与倒计时条；[onAccent] 是压在色块上的图标色（图形对比
///   ≥ 3:1）；[actionColor] 是卡上文字按钮的颜色（在 [container] 上 ≥ 4.5:1）。
///
/// 用固定色阶、不随主题取色：结果卡多半压在视频画面 / 正文上，主题取色在画面上
/// 不醒目。但**分深浅两套**（用户 2026-11-22 重设计）：深色主题下浅色卡又亮又
/// 刺眼，改用深 tonal 底 + 调亮的强调色、色块上换深色图标。六种结果六种颜色
/// （新制绿 / 覆盖紫 / 缺东西琥珀 / 已存在青 / 处理中与待发蓝 / 失败红），每种再配
/// 一个不同形状的图标——墨水屏与色觉障碍下颜色塌掉时靠形状区分。
typedef MineNoticeTone = ({
  Color container,
  Color onContainer,
  Color accent,
  Color onAccent,
  Color actionColor,
  IconData icon,
});

MineNoticeTone mineNoticeTone(MineToastStatus status, {bool dark = false}) {
  final IconData icon = mineToastPalette(status).icon;
  MineNoticeTone tone(
    int container,
    int onContainer,
    int accent,
    int onAccent,
    int action,
  ) => (
    container: Color(container),
    onContainer: Color(onContainer),
    accent: Color(accent),
    onAccent: Color(onAccent),
    actionColor: Color(action),
    icon: icon,
  );
  switch (status) {
    case MineToastStatus.added:
      return dark
          ? tone(0xFF0F3A1E, 0xFFC8F5D0, 0xFF6DD58C, 0xFF00391A, 0xFF6DD58C)
          : tone(0xFFC8F5D0, 0xFF00210B, 0xFF1E8E3E, 0xFFFFFFFF, 0xFF146C2E);
    case MineToastStatus.overwritten:
      return dark
          ? tone(0xFF3A2770, 0xFFE9DDFF, 0xFFCFBCFF, 0xFF381E72, 0xFFCFBCFF)
          : tone(0xFFE9DDFF, 0xFF22005D, 0xFF6750A4, 0xFFFFFFFF, 0xFF4F378B);
    case MineToastStatus.addedWithWarning:
      return dark
          ? tone(0xFF4A2C00, 0xFFFFDDB3, 0xFFFFB95C, 0xFF462A00, 0xFFFFB95C)
          : tone(0xFFFFDDB3, 0xFF2A1800, 0xFFB26A00, 0xFFFFFFFF, 0xFF6E3F00);
    case MineToastStatus.duplicate:
      return dark
          ? tone(0xFF00363D, 0xFFCDE7EC, 0xFF4FD8EB, 0xFF00363D, 0xFF4FD8EB)
          : tone(0xFFCDE7EC, 0xFF001F25, 0xFF006874, 0xFFFFFFFF, 0xFF004F58);
    case MineToastStatus.pending:
    case MineToastStatus.queued:
      return dark
          ? tone(0xFF0A2A5E, 0xFFD3E3FD, 0xFFA8C7FA, 0xFF062E6F, 0xFFA8C7FA)
          : tone(0xFFD3E3FD, 0xFF041E49, 0xFF0B57D0, 0xFFFFFFFF, 0xFF0842A0);
    case MineToastStatus.failed:
      return dark
          ? tone(0xFF5C1411, 0xFFFFDAD6, 0xFFFFB4AB, 0xFF690005, 0xFFFFB4AB)
          : tone(0xFFFFDAD6, 0xFF410002, 0xFFC5221F, 0xFFFFFFFF, 0xFFA50E0E);
  }
}

/// 一张结果卡停留多久（倒计时条与自动收起同长）。按严重程度分档（用户
/// 2026-11-22 重设计）：成功 / 已存在一眼即过，待发多停一点，缺东西要读原因，
/// 失败最久；带动作按钮的至少留出去点的时间。处理中正常会被结果原地替换，
/// 时长只是兜底上限。
Duration mineNoticeDwell(MineToastStatus status, {required bool hasAction}) {
  final Duration base = switch (status) {
    MineToastStatus.added ||
    MineToastStatus.overwritten ||
    MineToastStatus.duplicate => FushiNoticeDwell.mineResult,
    MineToastStatus.queued => FushiNoticeDwell.mineQueued,
    MineToastStatus.addedWithWarning => FushiNoticeDwell.mineWarning,
    MineToastStatus.failed => FushiNoticeDwell.mineFailed,
    MineToastStatus.pending => FushiNoticeDwell.minePending,
  };
  if (hasAction && base < FushiNoticeDwell.mineAction) {
    return FushiNoticeDwell.mineAction;
  }
  return base;
}

/// 结果卡上**看得见**的状态标题（用户 2026-11-22 重设计：此前只进读屏 label）。
/// 有词时它在第二行开头（粗体，后接牌组名 / 原因），没词时它就是第一行。
String mineNoticeTitle(MineToastStatus status) => switch (status) {
  MineToastStatus.added => t.card_notice_title_added,
  MineToastStatus.overwritten => t.card_notice_title_overwritten,
  MineToastStatus.addedWithWarning => t.card_notice_title_warning,
  MineToastStatus.duplicate => t.card_notice_title_duplicate,
  MineToastStatus.queued => t.card_notice_title_queued,
  MineToastStatus.failed => t.card_notice_title_failed,
  MineToastStatus.pending => t.card_notice_title_pending,
};
