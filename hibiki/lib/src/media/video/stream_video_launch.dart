import 'package:hibiki/src/media/video/url_stream_video.dart';
import 'package:hibiki/src/media/video/youtube_source_resolver.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// 流媒体书判据（TODO-1157）：`videoPath` 是可播 http/https 流 URL。
///
/// 「粘贴 URL 导入」的流媒体书 [VideoBookRow.videoPath] 存原始 URL（YouTube=watch URL，
/// 直链/HLS=直链）；本地文件视频 videoPath 是文件路径 → false。判据唯一、不依赖额外
/// 标记列（[VideoBooks.streamSpecJson] 只在有外挂字幕/防盗链 header 时非空，不当判据）。
bool isStreamVideoBook(VideoBookRow book) =>
    isPlayableStreamUrl(book.videoPath);

/// 从流媒体书重建播放所需的 [UrlStreamVideoClient] + [RemoteVideoInfo]（TODO-1157）。
///
/// 让「粘贴 URL 导入」的流媒体像本地视频一样入库、在书架持久、可重复打开：重开时不复用
/// 过期的临时解析结果，而是按 [VideoBookRow.videoPath]（原始 URL）+ [VideoBookRow.streamSpecJson]
/// （外挂字幕 URL / 防盗链 header）重建客户端，与「导入即播」时 dialog 构建客户端的逻辑等价：
/// - YouTube（[isYoutubeUrl]）：按 watch URL 重新 [resolveYoutubeSource]（临时流 URL 会过期，
///   必须每次重解析），拿分离视频/音频流 + 预解析 cue + 防盗链 header 包成 client。
/// - 直链 / HLS：直接用 videoPath 作流 URL，附上 spec 里的外挂字幕 URL + Referer/User-Agent。
///
/// [RemoteVideoInfo.id] 用 [VideoBookRow.bookUid]（断点 prefs 按它 key，重开续看可对齐）。
/// YouTube 解析失败抛异常（调用方按打开失败处理，与 dialog 即播失败一致）。
Future<({UrlStreamVideoClient client, RemoteVideoInfo info})>
    buildStreamVideoLaunch(VideoBookRow book) async {
  final String url = book.videoPath;
  final StreamVideoSpec spec =
      StreamVideoSpec.fromStorageJson(book.streamSpecJson);
  final UrlStreamVideoClient client;
  if (isYoutubeUrl(url)) {
    final YoutubeResolvedSource resolved = await resolveYoutubeSource(url);
    client = UrlStreamVideoClient(
      streamUrl: resolved.streamUrl,
      audioStreamUrl: resolved.audioStreamUrl,
      miningVideoUrl: resolved.miningVideoUrl,
      // TODO-1301（BUG-588）：透传 muxed 挖矿流是否自带音轨，让应用内播放器复用批量制卡
      // 守卫（youtube_clip_miner.dart:67）——muxed 时把制卡音频源置 null 回落 miningSource
      // 抽音频，避免指向 audio-only DASH 流致 ffmpeg seek stall→无句子音频/GIF 连坐丢弃。
      miningVideoHasAudio: resolved.miningVideoHasAudio,
      preresolvedCues: resolved.cues,
      httpHeaderFields: resolved.httpHeaders,
    );
  } else {
    final String? subtitleUrl = spec.subtitleUrl;
    client = UrlStreamVideoClient(
      streamUrl: url,
      subtitleUrl: (subtitleUrl != null && isPlayableStreamUrl(subtitleUrl))
          ? subtitleUrl
          : null,
      subtitleFileName: spec.subtitleFileName,
      // 直链/HLS 是单条 muxed 流（自带音轨）→ 制卡音频从它抽，无分离 audio-only 流。
      miningVideoHasAudio: true,
      httpHeaderFields: spec.httpHeaderFields,
    );
  }
  final RemoteVideoInfo info =
      RemoteVideoInfo(id: book.bookUid, title: book.title);
  return (client: client, info: info);
}
