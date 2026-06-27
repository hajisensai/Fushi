import 'dart:io';

import 'package:hibiki/src/sync/hibiki_library_host_service.dart';

abstract class RemoteVideoClient {
  Future<List<RemoteVideoInfo>> listRemoteVideos();

  /// 向 host 换取可直接播放的视频 stream URL。[episodeIndex]>0（TODO-885）请求远端
  /// 播放列表的某一集。
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  });

  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  });

  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  });

  /// 读 host 端记录的视频 [id] 播放断点（TODO-653 跨设备同步）。
  /// 返回 (位置毫秒, 更新时间毫秒)；无记录或不支持时返回 (0, 0)。
  /// [episodeIndex]>0（TODO-885）按集读断点。
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  });

  /// 向 host 上报视频 [id] 的本端播放断点（TODO-653）。host 端「取较新时间戳」决定
  /// 是否覆盖。[updatedAtMs] 为本端写入时刻（epoch 毫秒）。[episodeIndex]>0 按集上报。
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  });
}
