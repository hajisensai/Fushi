import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

/// 触感反馈的唯一出口（2026-10 交互重做）。
///
/// 只在手机平台（Android / iOS）发：桌面没有马达，鼠标点击再「震」一下也没有
/// 意义。墨水屏阅读器多是带马达的 Android 设备，触感反而是墨水屏下唯一不刷屏
/// 的即时反馈，所以**不**随 eink 关闭。
///
/// 只放「选择发生了变化」这一类语义：切换底栏目的地、分段按钮换段。普通点击
/// 已经由 `InkWell` 的 `Feedback.forTap` 负责，不重复。
void fushiSelectionHaptic(BuildContext context) {
  switch (Theme.of(context).platform) {
    case TargetPlatform.android:
    case TargetPlatform.iOS:
      HapticFeedback.selectionClick();
    case TargetPlatform.fuchsia:
    case TargetPlatform.linux:
    case TargetPlatform.macOS:
    case TargetPlatform.windows:
      break;
  }
}
