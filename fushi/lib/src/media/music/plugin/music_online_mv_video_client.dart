/// 在线 MV（音乐插件的 `mvStream`）交给视频播放页播放的远端客户端。
///
/// 与视频源扩展（Aniyomi，`AnimeSourceVideoClient`）同一条路：播放页
/// `VideoFushiPage.neutralizedRemote` 在「正在连接视频流」阶段调
/// [remoteVideoStreamUrls]，这里才向插件取流（地址有时效，不能提前取）；取到的请求头
/// 记在本对象上，播放页紧接着的 load 经 [RemoteVideoStreamHeaders] 读到并下发给
/// libmpv。失败重试会再走一次 [remoteVideoStreamUrls]，即重新取流。
///
/// 不进视频库、不建 VideoBooks 行；断点 / 观看统计按 [RemoteVideoInfo.id] 记在本地
/// prefs（与作品页预告片 `work-extra:` 同律）。
library;

import 'dart:io';

import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo, RemoteVideoStreamUrls;

/// 在线 MV 播放身份的 id 前缀（视频页按它键控断点 / 观看统计）。
const String kMusicOnlineMvVideoIdPrefix = 'music-mv:';

/// 在线 MV 在视频页里显示的标题：有艺人时「艺人 - 曲名」。
String musicOnlineMvVideoTitle(String title, String? artist) {
  final String a = artist?.trim() ?? '';
  return a.isEmpty ? title : '$a - $title';
}

class MusicOnlineMvVideoClient
    implements RemoteVideoClient, RemoteVideoStreamHeaders {
  MusicOnlineMvVideoClient({required this.resolve, this.describeError});

  /// 取流：播放地址与请求头（插件宿主已按网络授权核对过地址）。
  final Future<({String url, Map<String, String> headers})> Function() resolve;

  /// 取流失败时给用户看的文字；null 时交给播放页按异常自行归类。
  final String Function(Object error)? describeError;

  Map<String, String> _headers = const <String, String>{};

  @override
  String get remoteLibrarySourceId => 'music_online_mv';

  @override
  Map<String, String> get httpHeaderFields => _headers;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async =>
      const <RemoteVideoInfo>[];

  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async {
    final ({String url, Map<String, String> headers}) s;
    try {
      s = await resolve();
    } on Exception catch (e) {
      final String Function(Object error)? describe = describeError;
      if (describe == null) rethrow;
      throw RemoteVideoStreamRefusedException(describe(e), e);
    }
    _headers = Map<String, String>.unmodifiable(s.headers);
    // MV 是单条 muxed 流：制卡音频直接从它抽。
    return RemoteVideoStreamUrls(streamUrl: s.url, miningVideoHasAudio: true);
  }

  /// MV 没有外挂字幕。
  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async {}

  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
    void Function(int received, int? total)? onBytes,
    Future<void>? cancelSignal,
  }) async {
    throw UnsupportedError('online MV not downloadable');
  }

  /// 无 host：断点以本地 prefs 为准。
  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async => (positionMs: 0, updatedAtMs: 0);

  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}
}
