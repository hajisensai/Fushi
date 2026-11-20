import 'dart:ui' show Size;

import 'package:flutter/services.dart' show DeviceOrientation;

/// 视频页的屏幕方向与竖屏版式判据（拍板台 P9AS-fvjJh「安卓端视频竖屏播放」）。
///
/// 纯 Dart、不碰平台：页面只消费这里的结论去调 `SystemChrome.setPreferredOrientations`
/// 与选版式，判据本身可在 headless 环境单测（`test/media/video/
/// video_orientation_policy_test.dart`）。
///
/// 背景：视频页以前在移动端全程只允许两个横屏（TODO-099 / BUG-221）。BUG-221 的病根是
/// media_kit 退全屏时 `setPreferredOrientations([])` 放开全部方向、把设备弹回竖屏——
/// 不是「竖屏」本身有问题。竖屏版式上线后方向仍只有一个拥有者（视频页），方向集一律由
/// [videoDeviceOrientationsFor] 给出，**永不是空列表**，也永不含倒置竖屏。

/// 进入视频时用什么方向（设置项，键 `video_entry_orientation`）。
enum VideoEntryOrientation {
  /// 横屏（默认，老用户习惯不变）。
  landscape('landscape'),

  /// 按视频比例：竖版视频（宽 < 高）竖屏，其余横屏。比例没出来之前先横屏。
  videoAspect('video_aspect'),

  /// 跟随手机旋转（竖屏 + 两个横屏，不含倒置）。
  sensor('sensor');

  const VideoEntryOrientation(this.storageValue);

  /// 落库值（冻结，不随枚举名改）。
  final String storageValue;

  /// 解析落库值；未知 / 空值回落默认 [landscape]。
  static VideoEntryOrientation fromStorage(String? value) {
    for (final VideoEntryOrientation v in VideoEntryOrientation.values) {
      if (v.storageValue == value) return v;
    }
    return VideoEntryOrientation.landscape;
  }
}

/// 视频页当前实际锁定的方向集。
enum VideoOrientationLock {
  /// 只允许两个横屏。
  landscape('landscape'),

  /// 只允许正向竖屏。
  portrait('portrait'),

  /// 竖屏 + 两个横屏，跟手机转。
  sensor('sensor');

  const VideoOrientationLock(this.storageValue);

  /// 「记住每部作品的方向」的落库值（只会存 [landscape] / [portrait]）。
  final String storageValue;

  /// 解析每部作品记住的方向；只认 landscape / portrait，其余（含 sensor、空串）返回 null。
  static VideoOrientationLock? fromRemembered(String? value) {
    if (value == VideoOrientationLock.landscape.storageValue) {
      return VideoOrientationLock.landscape;
    }
    if (value == VideoOrientationLock.portrait.storageValue) {
      return VideoOrientationLock.portrait;
    }
    return null;
  }
}

/// 视频宽高比（宽 / 高）；尺寸未知或非法时 null。
double? videoAspectRatioOf(int? width, int? height) {
  if (width == null || height == null || width <= 0 || height <= 0) {
    return null;
  }
  return width / height;
}

/// 竖版视频（9:16 一类）：宽高比 < 1。
bool isPortraitVideo(double? aspectRatio) =>
    aspectRatio != null && aspectRatio < 1;

/// 解析视频页该锁的方向集。
///
/// [override] 是本次会话里用户点「转竖屏 / 转横屏」或「记住每部作品的方向」恢复出来的
/// 显式方向，优先于设置；为 null 时按 [entry] 设置：
///   * [VideoEntryOrientation.landscape] → 横屏；
///   * [VideoEntryOrientation.videoAspect] → 竖版视频竖屏，其余（含比例未知）横屏；
///   * [VideoEntryOrientation.sensor] → 跟手机转。
VideoOrientationLock resolveVideoOrientationLock({
  required VideoEntryOrientation entry,
  VideoOrientationLock? override,
  double? videoAspectRatio,
}) {
  if (override != null) return override;
  return switch (entry) {
    VideoEntryOrientation.landscape => VideoOrientationLock.landscape,
    VideoEntryOrientation.videoAspect =>
      isPortraitVideo(videoAspectRatio)
          ? VideoOrientationLock.portrait
          : VideoOrientationLock.landscape,
    VideoEntryOrientation.sensor => VideoOrientationLock.sensor,
  };
}

/// [lock] 对应的方向集。**永不为空**（空列表 = 放开全部方向含倒置，BUG-221 病根）。
List<DeviceOrientation> videoDeviceOrientationsFor(VideoOrientationLock lock) {
  return switch (lock) {
    VideoOrientationLock.landscape => const <DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ],
    VideoOrientationLock.portrait => const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
    ],
    VideoOrientationLock.sensor => const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ],
  };
}

/// 「转竖屏 / 转横屏」按钮按下后的目标方向：看**当前屏幕实际是不是竖的**，而不是看锁，
/// 这样跟随旋转模式下也是「转到另一边并锁住」。
VideoOrientationLock videoOrientationToggleTarget({
  required bool screenIsPortrait,
}) => screenIsPortrait
    ? VideoOrientationLock.landscape
    : VideoOrientationLock.portrait;

/// 竖屏时视频页用哪种版式。
enum VideoPortraitLayoutKind {
  /// 不是竖屏学习版式：横屏、桌面、小窗、竖版视频（铺满屏幕，字幕压在画面上、操作
  /// 按钮竖排在右边——即普通播放布局），或用户关了「竖屏时显示字幕列表」。
  none,

  /// 手机竖屏：视频贴顶，下面是当前句 + 页签面板（字幕 / 选集 / 章节），底部浮动工具栏。
  stacked,

  /// 平板竖屏（宽 ≥ [kVideoPortraitSplitMinWidth]）：左边视频 + 当前句 + 工具栏，右边页签面板。
  split,
}

/// 平板竖屏改左右分栏的最小宽度（dp）。
const double kVideoPortraitSplitMinWidth = 600;

/// 解析竖屏版式。
VideoPortraitLayoutKind resolveVideoPortraitLayout({
  required bool mobile,
  required Size screen,
  required double? videoAspectRatio,
  required bool showSubtitleList,
  required bool miniSurface,
}) {
  if (!mobile || miniSurface) return VideoPortraitLayoutKind.none;
  if (screen.height <= screen.width) return VideoPortraitLayoutKind.none;
  // 竖版视频竖屏看：画面本来就是竖的，铺满屏幕即可，不再切上下两块。
  if (isPortraitVideo(videoAspectRatio)) return VideoPortraitLayoutKind.none;
  if (!showSubtitleList) return VideoPortraitLayoutKind.none;
  return screen.width >= kVideoPortraitSplitMinWidth
      ? VideoPortraitLayoutKind.split
      : VideoPortraitLayoutKind.stacked;
}

/// 竖屏版式里视频那一条的高度：按视频比例（未知按 16:9），比例夹在 1:1..2.4:1 之间
/// （再宽的片子也不至于扁成一条线），且不超过可用高度的 [maxFraction]。
double videoPortraitStripHeight({
  required double width,
  required double availableHeight,
  double? videoAspectRatio,
  double maxFraction = 0.45,
}) {
  final double aspect = (videoAspectRatio ?? 16 / 9).clamp(1.0, 2.4);
  final double natural = width / aspect;
  final double cap = availableHeight * maxFraction;
  return natural < cap ? natural : cap;
}

/// 竖屏查词卡（底部弹出）的高度：收起 = 屏高一半，展开 = 拉到视频那条下沿。
/// [videoBottom] 是视频条下沿到屏顶的距离（竖版视频铺满时传 0）。
double videoPortraitLookupSheetHeight({
  required Size screen,
  required double videoBottom,
  required bool expanded,
}) {
  final double full = screen.height - videoBottom;
  final double half = screen.height / 2;
  final double height = expanded ? full : (half < full ? half : full);
  return height < 0 ? 0 : height;
}

/// 平板竖屏左右分栏时右侧页签面板的宽度。
double videoPortraitSplitPaneWidth(double screenWidth) =>
    (screenWidth * 0.42).clamp(320.0, 480.0);

/// 竖屏学习版式里视频条下沿到屏顶的距离（含顶部安全区）。页面据此让查词卡展开时停在
/// 视频下沿（视频始终看得见），版式组件据此摆视频条——两边同一个函数，不各算各的。
/// [kind] 为 [VideoPortraitLayoutKind.none] 时返回 0（画面铺满，查词卡直接从底部升起）。
double videoPortraitVideoBottom({
  required VideoPortraitLayoutKind kind,
  required Size screen,
  required double topInset,
  double? videoAspectRatio,
}) {
  final double columnWidth = switch (kind) {
    VideoPortraitLayoutKind.none => 0,
    VideoPortraitLayoutKind.stacked => screen.width,
    VideoPortraitLayoutKind.split =>
      screen.width - videoPortraitSplitPaneWidth(screen.width),
  };
  if (columnWidth <= 0) return 0;
  return topInset +
      videoPortraitStripHeight(
        width: columnWidth,
        availableHeight: screen.height - topInset,
        videoAspectRatio: videoAspectRatio,
      );
}
