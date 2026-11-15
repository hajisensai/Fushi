import 'package:fushi/src/media/video/video_mpv_config.dart'
    show isNetworkStreamUri;

/// 在线视频（媒体服务器 / 在线源扩展 / 互联主机等网络流）点「制卡」之后，卡往哪去。
///
/// 反馈 OeS0m8tLHc：视频页查词弹窗点「制卡」后**弹窗立刻关、视频立刻续播**，制卡一律
/// 在后台跑（见 [resolveVideoMineDispatch]）。所以这里只剩「卡去哪」一个选择：
/// - [background]（默认）：媒体在后台准备并写入 Anki，完成后 OSD 报结果；失败的结果卡
///   带「重试」。
/// - [deferred]：看完再制卡。后台只准备媒体、先暂存进待制卡列表，不碰 Anki；离开播放页
///   或在列表里点「全部写入」时统一写入。可以在写入前删掉点错的。
///
/// 原先的第三档 `wait`（弹窗陪着等整张卡落地）随反馈 OeS0m8tLHc 删除：弹窗不再陪等。
/// 持久化用 [wireName]（偏好键 `video_online_mining_mode` 冻结）；旧值 `wait` 与未知值
/// 一样回退 [background]。
enum VideoOnlineMiningMode {
  background('background'),
  deferred('deferred');

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

/// 一次视频制卡实际怎么跑（[resolveVideoMineDispatch] 的结果）。
enum VideoMineDispatch {
  /// 调用方等整张卡落地，拿到真实结果（note id / 失败原因）。
  awaitLanding,

  /// 立刻回「已加入」，媒体与写入在后台跑，结局由 OSD 报告。
  background,

  /// 看完再制卡：后台备好媒体后暂存，不写 Anki。
  deferred,
}

/// 这一次制卡实际走哪条路。纯函数。
///
/// - 覆盖已有卡片（[overwrite]）或在回看会话里改卡（[sourceReview]）→ 恒等待：这两条
///   的意义就在拿到落卡结果。
/// - 媒体源不是网络流（本地文件 / 无源）：本地不受「卡去哪」偏好影响。
///   [awaitLocalLanding] 为真（手机遥控制卡：要把真实结果报回手机）→ 等待；否则（查词
///   弹窗点「制卡」，反馈 OeS0m8tLHc：弹窗立刻关、视频立刻续播）→ 后台。
/// - 网络流按用户偏好 [preferred]。
VideoMineDispatch resolveVideoMineDispatch({
  required VideoOnlineMiningMode preferred,
  required String? mediaSource,
  required bool overwrite,
  required bool sourceReview,
  required bool awaitLocalLanding,
}) {
  if (overwrite || sourceReview) return VideoMineDispatch.awaitLanding;
  if (mediaSource == null || !isNetworkStreamUri(mediaSource)) {
    return awaitLocalLanding
        ? VideoMineDispatch.awaitLanding
        : VideoMineDispatch.background;
  }
  return switch (preferred) {
    VideoOnlineMiningMode.background => VideoMineDispatch.background,
    VideoOnlineMiningMode.deferred => VideoMineDispatch.deferred,
  };
}
