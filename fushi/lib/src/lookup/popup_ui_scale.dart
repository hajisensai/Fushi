/// 查词弹窗独立「弹窗缩放」（反馈 2jGkpD-iD6）。
///
/// 用户把全局「界面大小」(appUiScale) 调大后 app 本体好看，但查词弹窗里的内容 /
/// 顶栏按钮在自己偏好的弹窗尺寸下显得过大。于是给弹窗单独一个**乘在 appUiScale 之上**
/// 的系数（偏好 `popup_ui_scale`，默认 1.0 = 与改动前完全一致）。
///
/// 作用面：弹窗 WebView 内容 CSS zoom（`popup_settings_injection` 注入）+ 弹窗 Dart 侧
/// 元素（顶栏按钮 `dictionaryPopupTopBarScale`、独立 `:popup` 进程的界面缩放）。
/// **不**作用于弹窗盒子尺寸——盒子仍是「弹窗最大宽高 × appUiScale」，用户在自己偏好的
/// 窗口尺寸里调内容大小，正是这条反馈要的。
///
/// 所有弹窗宿主（阅读器、视频、查词页嵌套、复习、全局查词 / 悬浮层、galgame、`:popup`
/// 进程）都经 `AppModel.popupUiScale` 取这一个值，不各写一份。
library;

/// 「弹窗缩放」系数的出厂默认值（1.0 = 跟随界面大小，与改动前一致）。
const double kPopupUiScaleDefault = 1.0;

/// 「弹窗缩放」系数下限。
const double kPopupUiScaleMin = 0.5;

/// 「弹窗缩放」系数上限。
const double kPopupUiScaleMax = 2.0;

/// 设置滑条的步进（0.05）对应的档数：(2.0 − 0.5) / 0.05 = 30。
const int kPopupUiScaleDivisions = 30;

/// 把存储 / 输入的「弹窗缩放」系数夹进合法区间；非有限 / 非正值回落默认 1.0。
double clampPopupUiScaleFactor(double factor) {
  if (!factor.isFinite || factor <= 0) return kPopupUiScaleDefault;
  return factor.clamp(kPopupUiScaleMin, kPopupUiScaleMax).toDouble();
}

/// 弹窗生效缩放 = 界面大小 × 弹窗缩放系数（系数先经 [clampPopupUiScaleFactor]）。
/// [appUiScale] 非法（非有限 / 非正）时按 1.0 计，保证默认 (1, 1) → 1。
double resolvePopupUiScale({
  required double appUiScale,
  required double popupScaleFactor,
}) {
  final double base = (appUiScale.isFinite && appUiScale > 0)
      ? appUiScale
      : 1.0;
  return base * clampPopupUiScaleFactor(popupScaleFactor);
}
