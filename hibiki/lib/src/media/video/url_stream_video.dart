import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;

import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/media/video/youtube_source_resolver.dart'
    show isYoutubeUrl, youtubeVideoIdOrNull, YoutubeCaptionTrack;
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

/// 已知「网页视频站」域名白名单（TODO-1000 part-A1）：这些站点的 URL 指向 **HTML 播放页**
/// 而非可直接 demux 的音视频流，libmpv 拿到 HTML 解不出轨 → duration 永不就绪 → 卡 loading /
/// 黑屏，且 `player.open` 对 HTML 不抛 Dart 异常 → 用户拿不到任何错误提示。
///
/// 只用于**软警告**（提示用户「这是网页地址不是直链」），**绝不据此硬拒导入**——大量合法
/// 直链没有扩展名（CDN 直链常无后缀），按后缀/格式拒会误杀。命中后仍给用户「仍要尝试」逃生口。
///
/// 命中规则：host 完全等于白名单条目，或以 `.<条目>` 结尾（覆盖 `www.` / `m.` 等子域）。
/// 大小写不敏感，并剥掉末尾的 `.`（FQDN 写法）。纯字符串判定，不碰网络。
const Set<String> kKnownWebPageVideoHosts = <String>{
  'youtube.com',
  'youtu.be',
  'm.youtube.com',
  'music.youtube.com',
  'bilibili.com',
  'b23.tv',
  'netflix.com',
  'nicovideo.jp',
  'nico.ms',
  'vimeo.com',
  'dailymotion.com',
  'dai.ly',
  'twitch.tv',
  'iqiyi.com',
  'youku.com',
  'v.qq.com',
  'abema.tv',
  'tver.jp',
};

/// 纯函数：判断 [uri] 的 host 是否命中已知网页视频站白名单（[kKnownWebPageVideoHosts]）。
///
/// host 为空直接 false。把 host 转小写并剥掉末尾 `.` 后，命中「完全相等」或「以
/// `.<条目>` 结尾」（如 `www.youtube.com` / `m.youtube.com` 命中 `youtube.com`）。
/// 用于导入路径的软警告判定（见 [kKnownWebPageVideoHosts]）。
bool isKnownWebPageVideoHost(Uri uri) {
  String host = uri.host.toLowerCase();
  if (host.endsWith('.')) host = host.substring(0, host.length - 1);
  if (host.isEmpty) return false;
  for (final String known in kKnownWebPageVideoHosts) {
    if (host == known || host.endsWith('.$known')) return true;
  }
  return false;
}

/// 纯函数：判断粘贴的 [url] 是否是已知网页视频站地址（解析 URI 后委托给
/// [isKnownWebPageVideoHost]）。非法 URI / 空串 → false。供导入对话框软警告调用。
bool isKnownWebPageVideoUrl(String url) {
  final Uri? uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  return isKnownWebPageVideoHost(uri);
}

/// 纯函数：从粘贴的流 URL 派生稳定 bookUid：`video/stream/<sha1前12>`。
///
/// 与 [externalVideoBookUid]（`video/ext/`）/ [singleVideoBookUid]（`video/`）/
/// [playlistBookUid]（`video/playlist/`）命名族同构、前缀不撞，保证同一 URL 每次
/// 命中同一身份（幂等，阶段②入库去重 / 断点续看稳定）。URL 先 `trim` 再哈希，避免
/// 首尾空白派生出不同 uid。
/// 流媒体书重开规格（TODO-1157）：把「粘贴 URL 导入」流媒体像本地视频一样入库后，
/// 重开时据此重建 [UrlStreamVideoClient]。存的是 `video_books.videoPath`（即原始粘贴
/// URL）**装不下**的侧信息——外挂字幕 URL / 文件名 + 防盗链 header（Referer / User-Agent）。
/// 直链流无这些时整条 spec 为空，落库时存 null（书仍是流媒体，判据看 videoPath 是 http）。
///
/// 不含 [streamUrl] 本身（它是 `videoPath`，是书的身份来源），避免两处真值不一致。
/// YouTube 的临时解析流 URL / 分离音轨 / cue **不入 spec**（会过期）——重开时按
/// videoPath（watch URL）重新 [resolveYoutubeSource]。
class StreamVideoSpec {
  const StreamVideoSpec({
    this.subtitleUrl,
    this.subtitleFileName,
    this.referer,
    this.userAgent,
  });

  /// 可选外挂字幕 URL（http/https）。
  final String? subtitleUrl;

  /// 字幕文件名（保留扩展名给字幕格式路由）。
  final String? subtitleFileName;

  /// 防盗链 Referer header。
  final String? referer;

  /// 防盗链 User-Agent header。
  final String? userAgent;

  /// 四项全空 = 无需持久化任何侧信息（直链流），落库存 null。
  bool get isEmpty =>
      (subtitleUrl == null || subtitleUrl!.isEmpty) &&
      (subtitleFileName == null || subtitleFileName!.isEmpty) &&
      (referer == null || referer!.isEmpty) &&
      (userAgent == null || userAgent!.isEmpty);

  /// 组装防盗链 header map（空值不写入）。
  Map<String, String> get httpHeaderFields {
    final Map<String, String> headers = <String, String>{};
    if (referer != null && referer!.isNotEmpty) headers['Referer'] = referer!;
    if (userAgent != null && userAgent!.isNotEmpty) {
      headers['User-Agent'] = userAgent!;
    }
    return headers;
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (subtitleUrl != null && subtitleUrl!.isNotEmpty)
          'subtitleUrl': subtitleUrl,
        if (subtitleFileName != null && subtitleFileName!.isNotEmpty)
          'subtitleFileName': subtitleFileName,
        if (referer != null && referer!.isNotEmpty) 'referer': referer,
        if (userAgent != null && userAgent!.isNotEmpty) 'userAgent': userAgent,
      };

  /// 落库字符串：空 spec → null（不占列）；否则 JSON。
  String? toStorageJson() => isEmpty ? null : jsonEncode(toJson());

  factory StreamVideoSpec.fromJson(Map<String, dynamic> json) =>
      StreamVideoSpec(
        subtitleUrl: json['subtitleUrl'] as String?,
        subtitleFileName: json['subtitleFileName'] as String?,
        referer: json['referer'] as String?,
        userAgent: json['userAgent'] as String?,
      );

  /// 从落库字符串解析（null / 空 / 非法 JSON → 空 spec，绝不抛，重开不因脏数据崩）。
  factory StreamVideoSpec.fromStorageJson(String? raw) {
    if (raw == null || raw.isEmpty) return const StreamVideoSpec();
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return StreamVideoSpec.fromJson(decoded);
      }
    } catch (_) {}
    return const StreamVideoSpec();
  }
}

/// 纯函数：从粘贴的流 URL 派生稳定 bookUid。
///
/// **YouTube**（[isYoutubeUrl]）：先用 [youtubeVideoIdOrNull] 解出 canonical videoId，
/// 用 `video/stream/yt:<videoId>` 作身份——TODO-1304 修去重：同一视频的
/// `watch?v=<id>` / `youtu.be/<id>` / `shorts/<id>` / `m.youtube.com` 各种写法、以及
/// `&t=` / `&list=` / `&si=` / `&feature=` 追踪参数，旧逻辑（对整条 URL 直接 sha1）会各
/// 得不同 uid → 全部重复导入；规范化后任意写法收敛到同一 book_uid，`_uniqueBookUid`
/// 自然去重。videoId 解析失败（带 query 的 shorts 等）回退 sha1，不阻断导入。
///
/// **非 YouTube**（直链 / HLS / m3u8）：保持原行为——`sha1(url.trim())` 前 12 位。直链常
/// 带签名 / 过期 token query，这些 query 往往正是身份的一部分，剥掉会误合并不同的流，故
/// 不做 query 归一（Never break userspace：既有入库身份不变）。
///
/// 与 [singleVideoBookUid]（`video/`）/ [playlistBookUid]（`video/playlist/`）命名族
/// 前缀不撞；结果恒是三段 `video/stream/<身份>`（split('/').length == 3）。
String streamVideoBookUid(String url) {
  final String normalized = url.trim();
  if (isYoutubeUrl(normalized)) {
    final String? videoId = youtubeVideoIdOrNull(normalized);
    if (videoId != null && videoId.isNotEmpty) {
      return 'video/stream/yt:$videoId';
    }
  }
  final String digest =
      sha1.convert(utf8.encode(normalized)).toString().substring(0, 12);
  return 'video/stream/$digest';
}

/// 流媒体导入封面策略（TODO-1304）。数据结构化「怎么取封面」这个决策，消除
/// `_importStreamUrl` 里「只有 isYoutubeUrl 才下封面、直链/HLS 落到无封面分支」的特殊情况。
enum StreamImportCoverStrategy {
  /// YouTube：videoPath 是 HTML watch URL、ffmpeg 抽帧不适用 → 走缩略图 URL 下载
  /// （[youtubeThumbnailUrl] + downloadVideoCoverToPath）。
  youtubeThumbnail,

  /// 直链 / HLS / m3u8：videoPath 是可 seek 的流 URL → ffmpeg 直接抽帧
  /// （extractVideoCover 经 _isRemoteFfmpegInput 放行远端 URL；移动端走 ffmpeg-kit）。
  ffmpegFrame,
}

/// 纯函数：据 [url] 选流媒体导入封面策略。TODO-1304 修「非 YouTube 流恒无封面」——旧代码
/// 把下封面整块门控在 `if (isYoutubeUrl(url))` 内，直链/HLS 落到无封面分支。现在两类都出
/// 封面：YouTube 缩略图下载、其余 ffmpeg 抽帧。
StreamImportCoverStrategy streamImportCoverStrategy(String url) =>
    isYoutubeUrl(url)
        ? StreamImportCoverStrategy.youtubeThumbnail
        : StreamImportCoverStrategy.ffmpegFrame;

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
    this.audioStreamUrl,
    this.miningVideoUrl,
    this.miningVideoHasAudio = false,
    this.preresolvedCues = const <AudioCue>[],
    this.youtubeCaptionsUrl,
    this.httpHeaderFields = const <String, String>{},
    http.Client? httpClient,
  }) : _httpClient = httpClient ?? http.Client();

  /// 远端清单缓存里的来源身份（BUG-1202）。本 client 从不进库页的清单缓存
  /// （[listRemoteVideos] 恒空，它只是把一条粘贴来的 URL 包成播放页能吃的契约），
  /// 但契约要求每个源都能报出身份，给一个独立值即可，绝不与互联/云盘同槽。
  @override
  String get remoteLibrarySourceId => 'url_stream';

  /// 用户粘贴的视频流 URL（http/https 直链 / HLS / m3u8）。
  final String streamUrl;

  /// TODO-1000：分离流（YouTube video-only）的 audio-only 流 URL；null=同轨/muxed。
  /// 经 [remoteVideoStreamUrls] 回给播放页外挂（[AudioTrack.uri]）+ 制卡音频源。
  final String? audioStreamUrl;

  /// TODO-1000（BUG-528）：制卡 GIF/帧专用的低分辨率视频流 URL（见
  /// [YoutubeResolvedSource.miningVideoUrl]）。null=用 [streamUrl] 抽。
  final String? miningVideoUrl;

  /// TODO-1301（BUG-600）：[miningVideoUrl] 是否自带音轨（muxed）。true 时制卡音频从
  /// [miningVideoUrl] 抽（audio-only DASH 流 ffmpeg `-ss` HTTP seek 会 stall→120s 超时→
  /// 无句子音频），播放页据此把制卡音频源置 null 回落 miningSource。见
  /// [YoutubeResolvedSource.miningVideoHasAudio]。经 [remoteVideoStreamUrls] 透传给播放页。
  final bool miningVideoHasAudio;

  /// TODO-1000 / TODO-1307：预解析好的字幕 cue（YouTube timedtext 已转 [AudioCue]）。
  /// **字幕后置**（TODO-1307）：快解析 gate 起播时为空（未阻塞首帧），播放页 load 返回后
  /// 据 [youtubeCaptionsUrl] 异步 [resolveYoutubeCaptions]，cue 就绪由 [setPreresolvedCues]
  /// 回填——供 1302 的 YouTube 字幕轨菜单（`_youtubeCaptionsAvailable` / `_applyYoutubeCaptions`
  /// 读此字段）渲染 / 重选。非空时播放页直接用，跳过 [subtitleUrl] 下载+解析。
  List<AudioCue> preresolvedCues;

  /// 回填字幕后置解析出的 cue（TODO-1307）。快解析 gate 起播后字幕异步就绪时由播放页调用，
  /// 使 [preresolvedCues] 与真实字幕轨对齐（1302 菜单据此渲染「YouTube 字幕」行）。
  void setPreresolvedCues(List<AudioCue> cues) {
    preresolvedCues = cues;
  }

  /// TODO-1302 track-list-first：起播后 [resolveYoutubeCaptionTracks] 拿到的字幕轨列表
  /// （元数据，无 cue 正文）。字幕轨选择器据此渲染每条可选轨——**列表出现不依赖 cue 就绪**
  /// （修「快加载 withCaptions:false 后字幕整个消失」）。空 = 尚未解析 / 无字幕轨。
  List<YoutubeCaptionTrack> youtubeCaptionTracks =
      const <YoutubeCaptionTrack>[];

  /// 回填字幕轨列表（TODO-1302）。快解析 gate 起播后由播放页异步解析就绪时调用。
  void setYoutubeCaptionTracks(List<YoutubeCaptionTrack> tracks) {
    youtubeCaptionTracks = tracks;
  }

  /// per-track cue 缓存（[YoutubeCaptionTrack.trackKey] → 已懒下载的 cue）：重选同一轨不重复
  /// 网络下载 timedtext。仅内存、session 内有效（换书重建 client 即清）。
  final Map<String, List<AudioCue>> _captionCueCache =
      <String, List<AudioCue>>{};

  /// 读缓存的某轨 cue（未缓存 → 空表，由调用方 [resolveYoutubeCaptionCues] 懒下载）。
  List<AudioCue> cachedCaptionCues(String trackKey) =>
      _captionCueCache[trackKey] ?? const <AudioCue>[];

  /// 缓存某轨懒下载好的 cue（TODO-1302）。
  void cacheCaptionCues(String trackKey, List<AudioCue> cues) {
    _captionCueCache[trackKey] = cues;
  }

  /// TODO-1307：YouTube watch URL（字幕后置解析源）。快解析 gate 只取流起播、不解字幕，
  /// 播放页 load 返回后据此异步 [resolveYoutubeCaptions] 灌 1302 字幕轨。null=非 YouTube
  /// （直链/HLS 无 timedtext 字幕后置，字幕仍走 [subtitleUrl] 下载）。
  final String? youtubeCaptionsUrl;

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
      audioStreamUrl: audioStreamUrl,
      miningVideoUrl: miningVideoUrl,
      miningVideoHasAudio: miningVideoHasAudio,
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
