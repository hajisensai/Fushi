import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/remote_video_client.dart';
import 'package:http/http.dart' as http;

/// 纯函数：判断 [url] 是否是可直接交给播放器的网络流 URL（TODO-850 阶段①）。
///
/// 仅看 scheme：`http` / `https`（大小写不敏感）且 host 非空才算可播。`file://`、
/// 裸路径、空串、非法 URI 一律 false——播放内核（libmpv）只对 http(s) 流做网络直传，
/// 其它协议不在阶段①范围内。纯字符串判定，不碰文件系统 / 网络。
bool isPlayableStreamUrl(String url) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  final String scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return false;
  return uri.host.isNotEmpty;
}

/// 纯函数：从粘贴的流 URL 派生稳定 bookUid：`video/stream/<sha1前12>`。
///
/// 与 [externalVideoBookUid]（`video/ext/`）/ [singleVideoBookUid]（`video/`）/
/// [playlistBookUid]（`video/playlist/`）命名族同构、前缀不撞，保证同一 URL 每次
/// 命中同一身份（幂等，阶段②入库去重 / 断点续看稳定）。URL 先 `trim` 再哈希，避免
/// 首尾空白派生出不同 uid。
String streamVideoBookUid(String url) {
  final String normalized = url.trim();
  final String digest =
      sha1.convert(utf8.encode(normalized)).toString().substring(0, 12);
  return 'video/stream/$digest';
}

/// 单 URL 流的 [RemoteVideoClient]（TODO-850 阶段①）：把「用户粘贴的一条流 URL +
/// 可选外挂字幕 URL + 可选防盗链 header」喂进既有远端播放链
/// （`VideoHibikiPage._initRemote → _loadRemoteEpisode`），**播放内核零改**。
///
/// 单 URL 流不是远端 host/client 模型：
/// - 不走列举（[listRemoteVideos] 返回空），手动粘贴即播；
/// - 不分集（episodeIndex 一律忽略，恒返回同一条流）；
/// - 不支持下载入库（[downloadRemoteVideo] 抛 [UnsupportedError]，阶段②再议）；
/// - 断点权威是本地 prefs（host 无记录：[remoteVideoPosition] 返 (0,0)、
///   [putRemoteVideoPosition] no-op）。
///
/// [httpHeaderFields] 是可选防盗链 header（Referer / User-Agent 等），由播放页在
/// load 时下发到 libmpv `http-header-fields`（阶段①仅 session 内有效，不落 DB）。
class UrlStreamVideoClient implements RemoteVideoClient {
  UrlStreamVideoClient({
    required this.streamUrl,
    this.subtitleUrl,
    this.subtitleFileName,
    this.httpHeaderFields = const <String, String>{},
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// 用户粘贴的视频流 URL（http/https 直链 / HLS / m3u8）。
  final String streamUrl;

  /// 可选外挂字幕 URL（http/https）；非空时 [getRemoteVideoSubtitle] 下载到 dest。
  final String? subtitleUrl;

  /// 字幕文件名（保留扩展名给字幕格式路由）；为空时由调用方按 URL 兜底。
  final String? subtitleFileName;

  /// 防盗链 header（Referer / User-Agent 等），下发到 libmpv `http-header-fields`。
  final Map<String, String> httpHeaderFields;

  final http.Client _httpClient;

  @override
  Future<List<RemoteVideoInfo>> listRemoteVideos() async =>
      const <RemoteVideoInfo>[];

  /// 忽略 [episodeIndex]（单 URL 流不分集），恒返回同一条粘贴的流 URL + 字幕。
  @override
  Future<RemoteVideoStreamUrls> remoteVideoStreamUrls(
    String id, {
    int episodeIndex = 0,
  }) async {
    return RemoteVideoStreamUrls(
      streamUrl: streamUrl,
      subtitleUrl: subtitleUrl,
      subtitleFileName: subtitleFileName,
    );
  }

  /// 有 [subtitleUrl] 则 `http.get` 下载到 [dest]；无字幕 URL 时 no-op。
  ///
  /// 防盗链流的字幕同站时也需要 header，故下载请求带 [httpHeaderFields]。
  @override
  Future<void> getRemoteVideoSubtitle(
    String id,
    File dest, {
    int? embeddedStreamIndex,
    int episodeIndex = 0,
    void Function(double progress)? onProgress,
  }) async {
    final String? url = subtitleUrl;
    if (url == null || url.isEmpty) return;
    final http.Response res = await _httpClient.get(
      Uri.parse(url),
      headers: httpHeaderFields.isEmpty ? null : httpHeaderFields,
    );
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw http.ClientException(
        'subtitle download failed: HTTP ${res.statusCode}',
        Uri.parse(url),
      );
    }
    await dest.parent.create(recursive: true);
    await dest.writeAsBytes(res.bodyBytes);
    onProgress?.call(1.0);
  }

  /// 单 URL 在线流不支持下载入库（阶段②再议）。
  @override
  Future<void> downloadRemoteVideo(
    String id,
    File dest, {
    void Function(double progress)? onProgress,
  }) async {
    throw UnsupportedError('stream not downloadable');
  }

  /// host 无记录：断点走本地 prefs，恒返回 (0, 0)。
  @override
  Future<({int positionMs, int updatedAtMs})> remoteVideoPosition(
    String id, {
    int episodeIndex = 0,
  }) async =>
      (positionMs: 0, updatedAtMs: 0);

  /// 本地 prefs 已是断点权威：no-op（不向任何 host 上报）。
  @override
  Future<void> putRemoteVideoPosition(
    String id,
    int positionMs,
    int updatedAtMs, {
    int episodeIndex = 0,
  }) async {}

  /// 释放底层 http client（页面 dispose 时调用）。
  @visibleForTesting
  void close() => _httpClient.close();
}
