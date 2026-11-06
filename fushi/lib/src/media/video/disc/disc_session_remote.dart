import 'package:flutter/foundation.dart';

import 'package:fushi/src/media/video/video_disc_menu.dart'
    show VideoDiscMenuKey, VideoDiscType;

/// 视频播放页对原盘会话的遥控面（控制通道 `fushi_cli disc …` / AI 助手用）。
///
/// 与 [VideoPlayerRemoteControl] 一样由播放页实现、经 `videoPlaybackRemotes` 登记；
/// 路由层按 `remote is VideoDiscRemoteControl` 判能力。每个动作都转调页内已有执行体：
/// 菜单键 = 盘菜单键位 / 遥控器背后的 `VideoPlayerController.discMenuKey`，退出 = 「退出
/// 原盘」/ 按住 Esc 背后的同一个退出汇聚点。失败抛 `VideoRemoteFailure`。
abstract interface class VideoDiscRemoteControl {
  /// 当前原盘会话的状态；页面不是原盘会话（普通视频）或还在加载时为 null。
  VideoDiscSessionSnapshot? discSession();

  /// 向盘发一个菜单键（方向 / 确认 / 返回 / 顶层菜单 / 标题菜单 / 弹出菜单），按会话的
  /// 盘类型（蓝光 libbluray / DVD libdvdnav）查命令表。
  Future<void> discMenuKey(VideoDiscMenuKey key);

  /// 退出整个原盘会话回到上一页（先退会话进过的全屏，再走返回汇聚点落库并离开）。
  Future<void> exitDiscSession();
}

/// [VideoDiscRemoteControl.discSession] 的只读快照。
@immutable
class VideoDiscSessionSnapshot {
  const VideoDiscSessionSnapshot({
    required this.bookUid,
    required this.title,
    required this.discType,
    required this.remote,
    required this.navigationSupported,
    required this.menuStarting,
    required this.menuActive,
    required this.titleReady,
    this.discTitle,
    this.playlistPath,
    this.error,
  });

  /// 会话绑定的库条目（远端原盘会话不绑本地条目时为页面身份）。
  final String bookUid;
  final String? title;
  final VideoDiscType discType;

  /// 盘在已配对 host 上、经 HTTP 读（远端原盘）。
  final bool remote;

  /// 本机播放组件能导航这张盘（不能时只放正片，菜单键无效）。
  final bool navigationSupported;

  /// 初始菜单还在启动：此时菜单键会被拒。
  final bool menuStarting;

  /// 盘菜单（顶层菜单 / 弹出菜单 / DVD 菜单域）在屏幕上。
  final bool menuActive;

  /// 正片已就绪（可查词 / 制卡的那种「在放某条标题」）。
  final bool titleReady;

  /// 盘的导航标题号（蓝光：0 = 顶层菜单，65535 = 首播，1..N = 标题）。
  final int? discTitle;

  /// 当前选中的播放列表（蓝光 `.mpls` 路径 / DVD title 路径）。
  final String? playlistPath;

  /// 菜单打不开 / 导航失败的原因码（`navigation-open-failed` 等）。
  final String? error;

  Map<String, Object?> toJson() => <String, Object?>{
    'bookUid': bookUid,
    'title': title,
    'type': discType.name,
    'remote': remote,
    'navigationSupported': navigationSupported,
    'menuStarting': menuStarting,
    'menuActive': menuActive,
    'titleReady': titleReady,
    'discTitle': ?discTitle,
    'playlist': ?playlistPath,
    'error': ?error,
  };
}
