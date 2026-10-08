/// 视频画面「双击落空」时做什么（中带双击，或双击快退快进关闭时任意位置双击）。
///
/// 左 / 右三分之一的快退快进由页面先行处理（设置开启时命中即早返回），走到这里
/// 的都是落空的双击，按平台与指针类型分流：
/// - 桌面 + 鼠标：切全屏（桌面播放器惯例，BUG-221 保留）；
/// - 移动端，以及桌面上的触屏 / 触控笔（Surface 等，用户 2026-10-05 拍板与移动端
///   一致）：播放 / 暂停，受「点击画面播放 / 暂停」开关门控——全屏改由控制栏按钮切。
enum VideoDoubleTapCenterAction {
  /// 不动作（触屏口径下用户关了「点击画面播放 / 暂停」）。
  none,

  /// 切换窗口全屏（桌面鼠标）。
  toggleFullscreen,

  /// 播放 / 暂停（移动端与桌面触屏）。
  togglePlayback,
}

/// 纯判据，页面 `_handleVideoPointerUp` 唯一消费者。
VideoDoubleTapCenterAction resolveVideoDoubleTapCenterAction({
  required bool desktopControls,
  required bool touchLikePointer,
  required bool tapTogglesPlayback,
}) {
  if (desktopControls && !touchLikePointer) {
    return VideoDoubleTapCenterAction.toggleFullscreen;
  }
  if (!tapTogglesPlayback) return VideoDoubleTapCenterAction.none;
  return VideoDoubleTapCenterAction.togglePlayback;
}
