/// 视频页**页内非路由**遮挡层是否压着画面——学习计时门
/// （`StudyClockRunGate.setLocallyCovered`）的唯一判据，视频页与测试同源调用。
///
/// 与小说「面板 / 弹层压着正文就停表、查词浮窗与制卡是阅读的一部分」同律
/// （`docs/agent/statistics.md`「写入面」）：
///
/// - **停**：侧板（设置 / 字幕 / 音频 / 章节 / 画质 / 倍速 / 弹幕手动匹配，
///   [sidePanelOpen]）、画面内控件布局编辑（[controlEditMode]）。
/// - **不停**：统计侧板（[statisticsPanelOpen]；同小说统计侧栏——实时秒表本身就是
///   给「边看边瞄一眼」用的，盖住就永远看不到它在走）、push-aside 字幕列表（把画面
///   挤窄、不遮挡，且是学习主路径）、剧集列表（同样把画面挤开、不盖视频，所有者
///   2026-11-07 拍板不停表）、查词浮层、控制条的小 popover（音量 / 倍速）、
///   小窗、提示条。
/// - 路由类遮挡（对话框 / 菜单 / 整页）不在这里，由 `StudyCoverTracker` 判；全屏路由
///   声明了豁免。
bool videoStudyClockLocallyCovered({
  required bool sidePanelOpen,
  required bool statisticsPanelOpen,
  required bool controlEditMode,
}) {
  if (controlEditMode) return true;
  return sidePanelOpen && !statisticsPanelOpen;
}
