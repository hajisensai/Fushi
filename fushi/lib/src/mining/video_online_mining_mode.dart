import 'package:fushi/src/media/video/video_mpv_config.dart'
    show isNetworkStreamUri;

/// 在线视频（媒体服务器 / 在线源扩展 / 互联主机等网络流）点「制卡」之后怎么走。
///
/// 本地视频制卡秒出，不受本设置影响。网络流要从远端取句子音频与封面，就算有播放器
/// 缓冲副本（`VideoPlayerController.snapshotCachedRange`）也要几百毫秒到几秒，远端
/// 回退时更久——这段时间弹窗要不要陪着等，是交互选择而不是性能问题：
/// - [background]（默认）：弹窗立刻显示「已加入」，媒体在后台准备并写入 Anki，完成后
///   OSD 报结果。代价：弹窗没有「最新可改」（✓↩︎ 覆盖）——那张卡点击时还不存在。
/// - [deferred]：看完再制卡。后台只准备媒体、先暂存进待制卡列表，不碰 Anki；离开播放页
///   或在列表里点「全部写入」时统一写入。可以在写入前删掉点错的。
/// - [wait]：改动前的行为，弹窗等整张卡落地（保留「最新可改」）。
///
/// 持久化用 [wireName]；未知值回退 [background]。
enum VideoOnlineMiningMode {
  background('background'),
  deferred('deferred'),
  wait('wait');

  const VideoOnlineMiningMode(this.wireName);

  /// 偏好持久化用的稳定字符串键（勿随枚举名改动）。
  final String wireName;

  static VideoOnlineMiningMode fromWireName(String? name) {
    for (final VideoOnlineMiningMode mode in VideoOnlineMiningMode.values) {
      if (mode.wireName == name) return mode;
    }
    return VideoOnlineMiningMode.background;
  }
}

/// 这一次制卡实际走哪种模式。纯函数。
///
/// - 媒体源不是网络流（本地文件 / 无源）→ [VideoOnlineMiningMode.wait]：本地抽取秒出，
///   保持改动前行为（含「最新可改」）。
/// - 覆盖已有卡片（[overwrite]）或在回看会话里改卡（[sourceReview]）→ 恒等待：这两条
///   的意义就在拿到落卡结果，交给后台等于让弹窗失去它要显示的那张卡。
/// - 其余按用户偏好 [preferred]。
VideoOnlineMiningMode resolveVideoOnlineMiningMode({
  required VideoOnlineMiningMode preferred,
  required String? mediaSource,
  required bool overwrite,
  required bool sourceReview,
}) {
  if (mediaSource == null || !isNetworkStreamUri(mediaSource)) {
    return VideoOnlineMiningMode.wait;
  }
  if (overwrite || sourceReview) return VideoOnlineMiningMode.wait;
  return preferred;
}
