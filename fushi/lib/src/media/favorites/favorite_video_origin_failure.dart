/// 视频收藏句跳不回原处的原因：收藏夹 / 首页「收藏句子」的提示与手机遥控的失败原因
/// （`favorite_source_unavailable` 的 `reason`）共用这一份，文案也只在这里写一次。
///
/// 本文件只依赖 i18n：手机遥控页（`video_remote_page.dart`）按 wire 原因取文案时不该
/// 为此拖进解析器的依赖。
library;

import 'package:fushi/i18n/strings.g.dart';

/// 视频收藏跳不回原处的原因。[wireReason] 是遥控协议 `reason` 的取值，与引擎
/// `videoRemoteFavoriteSourceReasons` 一一对应（守卫测试钉住）。
enum FavoriteVideoOriginFailure {
  /// 收藏没有视频键（不知道是哪个视频）。
  noLink('no_link'),

  /// 本机库里有这一行，但本地文件不在了。
  localFileMissing('local_file_missing'),

  /// 收藏落在当前视频已经没有的那一集上（剧集列表变短了，遥控）。
  episodeMissing('episode_missing'),

  /// 旧收藏（v179 之前）没记来源，已登录的媒体服务器 / 互联对端上都没对上。
  originUnknown('origin_unknown'),

  /// 媒体服务器：收藏记着的那台没登录（旧收藏 = 一台都没登录）。
  serverSignedOut('server_signed_out'),

  /// 媒体服务器：答了话，但没有这个可播条目。
  serverItemMissing('server_item_missing'),

  /// 媒体服务器：连不上。
  serverUnreachable('server_unreachable'),

  /// 互联：没开互联或没有配对的对端。
  peerUnavailable('peer_unavailable'),

  /// 互联：对端不在线（取清单失败）。
  peerOffline('peer_offline'),

  /// 互联：对端库里已经没有这个视频（或它没有可串流的字节）。
  peerItemMissing('peer_item_missing'),

  /// 云盘：云同步关了，或现在用的不是收藏时那种云盘。
  cloudUnavailable('cloud_unavailable'),

  /// 云盘：连不上。
  cloudUnreachable('cloud_unreachable'),

  /// 云盘：视频目录里已经没有这个视频。
  cloudItemMissing('cloud_item_missing'),

  /// 在线视频源：收藏时那个扩展没装或停用了。
  onlineSourceMissing('online_source_missing'),

  /// 在线视频源：这台设备不能跑在线视频源（iOS 商店版不带在线源宿主，或平台没有
  /// 扩展运行时），收藏是在别的设备上记的。
  onlineSourceUnsupported('online_source_unsupported'),

  /// 来源没有可回去的入口：粘贴的直链、音乐 MV、不能串流的云盘（FTP），或旧版本
  /// 收藏、没记下作品的在线源。
  notReopenable('not_reopenable'),

  /// 电脑上打开了来源，但视频流没能播放（遥控异步上报）。
  playbackFailed('playback_failed'),

  /// 前台播放器（网页）只能在本视频里跳（遥控）。
  otherVideo('other_video');

  const FavoriteVideoOriginFailure(this.wireReason);

  /// 遥控协议 `reason` 的取值。
  final String wireReason;

  /// 按遥控协议的 `reason` 取回原因；null / 认不出（更新版本电脑发来的新原因）返回
  /// null，调用方退回错误码本身的笼统文案。
  static FavoriteVideoOriginFailure? fromWireReason(String? reason) {
    if (reason == null) return null;
    for (final FavoriteVideoOriginFailure failure in values) {
      if (failure.wireReason == reason) return failure;
    }
    return null;
  }

  /// 给用户看的原因。
  String get message => switch (this) {
    noLink => t.video_favorite_no_link,
    localFileMissing => t.video_favorite_local_file_missing,
    episodeMissing => t.video_remote_error_episode_unavailable,
    originUnknown => t.video_favorite_source_unavailable,
    serverSignedOut => t.video_favorite_server_signed_out,
    serverItemMissing => t.video_favorite_server_item_missing,
    serverUnreachable => t.video_favorite_server_unreachable,
    peerUnavailable => t.video_favorite_peer_unavailable,
    peerOffline => t.video_favorite_peer_offline,
    peerItemMissing => t.video_favorite_peer_item_missing,
    cloudUnavailable => t.video_favorite_cloud_unavailable,
    cloudUnreachable => t.video_favorite_cloud_unreachable,
    cloudItemMissing => t.video_favorite_cloud_item_missing,
    onlineSourceMissing => t.video_favorite_online_source_missing,
    onlineSourceUnsupported => t.video_favorite_online_source_unsupported,
    notReopenable => t.video_favorite_not_reopenable,
    playbackFailed => t.video_favorite_playback_failed,
    otherVideo => t.video_favorite_other_video,
  };
}
