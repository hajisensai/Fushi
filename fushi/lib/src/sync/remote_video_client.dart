import 'dart:io';

import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_library_source.dart';

/// **任何**远端视频来源都具备的能力：列清单 + 按 id 把整片下载到本地。
///
/// 互联 host 的 live 库与云盘的 `__videos__/` 目录都能做到这两件事，所以库页的
/// 「列清单 → 混排占位卡 → 点击下载入库」这条主干可以只依赖本接口，不必知道背后
/// 是哪一种源。
///
/// **为什么要分成两级**（TODO-2119）——此前只有 [RemoteVideoClient] 一个接口，而
/// 云盘没有 live host、给不出流播 URL / 外挂字幕 / 跨端断点，于是
/// `CloudRemoteVideoClient` 干脆**不实现**任何接口，逼得视频页同时持有两个互斥的
/// nullable 字段，每条下载 / 封面 / 字幕路径都要 `if (cloud != null) ... else ...`，
/// 还要在页面里手写一个 manifest→DTO 的适配函数（给 `RemoteVideoInfo` 加字段时
/// 漏改那里，云侧该字段就永远是空的）。
///
/// 反过来让云端 `implements RemoteVideoClient` 再把 4 个方法写成抛异常也不对：那只是
/// 把「能力靠 `is` 判断」换成「调了会抛」，编译器照样拦不住。按能力分级之后，
/// `source is RemoteVideoClient` 是**类型系统认可**的能力判据——拿不到 live 能力的
/// 地方根本调不出流播/字幕/断点方法。
abstract class RemoteVideoSource implements RemoteLibrarySource {
  /// 列出该源可见的远端视频。云盘源在这里就把目录清单适配成 [RemoteVideoInfo]，
  /// 消费方（库页）不再需要知道 manifest 长什么样。
  Future<List<RemoteVideoInfo>> listRemoteVideos();

  /// 把 [id] 对应的视频整片下载到 [dest]。
  ///
  /// 续传口径按源写实：互联走 host live 下载引擎（Range + `.part`，中断可续）；
  /// 云盘是整文件重下，失败清残片、无断点续传。
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  });
}

/// 具备实时流播 / 外挂字幕 / 跨端断点的远端视频源——只有互联 host 的 live 库有这些
/// 端点（云盘目录只是一堆静态资产，没有服务端能回答这些请求）。
abstract class RemoteVideoClient extends RemoteVideoSource {
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

/// 「播放偏好跨设备同步」的**可选**能力（BUG-1620 调轴起步，播放偏好同步泛化批
/// 扩展为统一带戳字段模型）——只有互联 host 有 `/playback` 端点；URL 直链 /
/// YouTube（[RemoteVideoClient] 的另一个实现 `UrlStreamVideoClient`）没有 host
/// 可上报。
///
/// 不并进 [RemoteVideoClient] 的理由与上面的两级拆分一致：该接口有十余个测试 fake
/// 用 `implements` 全量实现，扩面强制全部补桩；播放页用 `client is
/// RemoteVideoPlaybackSync` 做类型系统认可的能力判据，拿不到能力的源根本调不出上报。
abstract interface class RemoteVideoPlaybackSync {
  /// 读 host 端视频 [id] 的播放偏好带戳状态。host 无记录 / 旧 host 无端点（404）
  /// 返回全默认状态。
  Future<VideoPlaybackSyncState> remoteVideoPlayback(String id);

  /// 向 host 上报视频 [id] 的播放偏好带戳字段（可只带一个字段——调整哪个报哪个）。
  /// host 端逐字段「严格较新时间戳者胜」合并。旧 host 无端点时抛（404 经
  /// checkStatus），调用方 best-effort 捕获——本地 prefs 已持久化，不阻塞播放。
  Future<void> putRemoteVideoPlayback(String id, VideoPlaybackSyncState state);
}
