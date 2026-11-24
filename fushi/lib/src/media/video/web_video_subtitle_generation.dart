/// 网页档（站点自己的播放器放在 WebView 里）这一集的「生成字幕」：两个承载页共用同一套
/// 身份、拉整集音频、管线目标与产物认领——
///
/// - 原生播放器页的网页档（`video_fushi/web_source.part.dart`，站点画面垫在原生控件下面）；
/// - 内置网页播放器页（`web_video_fushi_page.dart`，Windows 上 YouTube 等非 DRM 站点的默认
///   播放方式「Fushi 播放」）。
///
/// 两页只负责入口、进度 UI 与把产物装成一条轨。拉音频的来源见 `web_video_subtitle_media.dart`
/// （YouTube 现取 audio-only 流，其它站点用页面给的直链 / 清单），之后与在线流同一条路：
/// 拉成本机副本（[appVideoStreamSubtitleAudioStager]）→ `AppVideoSubtitleService.resolveStream`，
/// 产物登记在这一集的书上（`video_books.subtitleSource`），两页重进时都按它读回。
library;

import 'dart:io';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart' show immutable;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show VideoSubtitleEpisodeResult;
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart'
    show
        AppVideoSubtitleJob,
        AppVideoSubtitleService,
        AppVideoSubtitleTarget,
        AppVideoSubtitleTargetNotFound;
import 'package:fushi/src/media/video/subtitle/video_stream_subtitle_audio.dart'
    show
        VideoStreamSubtitleAudioInput,
        VideoStreamSubtitleAudioStaging,
        VideoStreamSubtitleAudioUnavailable,
        appVideoStreamSubtitleAudioStager,
        videoStreamSubtitleAudioKey,
        videoStreamSubtitleExportDirUnder,
        videoStreamSubtitleFrameSource;
import 'package:fushi/src/media/video/web_video_session.dart';
import 'package:fushi/src/media/video/web_video_sites.dart'
    show webVideoEpisodeUrl;
import 'package:fushi/src/media/video/web_video_subtitle_media.dart'
    show
        WebVideoSubtitleMediaBlock,
        WebVideoSubtitleMediaBlocked,
        prepareWebVideoSubtitleAudio,
        webVideoSubtitleFrameInput;
import 'package:fushi/src/storage/app_paths.dart';

/// 网页档这一集整集音频副本的身份：[key] 由来源 `web` + 这一集的规范地址 + 站点音轨派生
/// （[videoStreamSubtitleAudioKey]），[title] 给副本 / 导出字幕的文件名用，[bookUid] 是产物
/// 登记到的那本书。
@immutable
class WebVideoSubtitleEpisode {
  const WebVideoSubtitleEpisode({
    required this.episodeUrl,
    required this.title,
    required this.bookUid,
    this.audioTrack = '',
  });

  /// 这一集的规范地址（[webVideoEpisodeUrl]）。
  final String episodeUrl;
  final String title;
  final String bookUid;

  /// 站点当前音轨（多音轨站点换轨后是另一份音频）；空 = 站点没给。
  final String audioTrack;

  String get key => videoStreamSubtitleAudioKey(
    sourceId: 'web',
    videoId: episodeUrl,
    episode: 0,
    audioTrack: audioTrack.isEmpty ? '-' : audioTrack,
  );
}

/// 内置网页播放器页这一集的身份：页面此刻（[href]）所在的那一集就是本页那本书
/// （[bookVideoPath] 是书的观看页地址）的那一集才有——用户在站点里点去别的视频后，那段音频
/// 不属于这本书，产物不能登记到它上面。
WebVideoSubtitleEpisode? webVideoBookSubtitleEpisode({
  required String bookUid,
  required String bookVideoPath,
  required String title,
  required String href,
  required String audioTrack,
}) {
  final String? episodeUrl = webVideoEpisodeUrl(bookVideoPath);
  if (episodeUrl == null || webVideoEpisodeUrl(href) != episodeUrl) {
    return null;
  }
  return WebVideoSubtitleEpisode(
    episodeUrl: episodeUrl,
    title: title.isEmpty ? episodeUrl : title,
    bookUid: bookUid,
    audioTrack: audioTrack,
  );
}

/// 内置网页播放器页里站点换了视频 key（仍是这本书那一集）后，按新 key 重挂的生成字幕要不要
/// 选中：换 key 前正选着它（[generatedWasActive]，用户亲手选的也算）就接着选；否则只在用户
/// 这次会话没亲手选过轨（[userChosen]）、没关字幕（[subtitlesOff]）时替他选。
bool webVideoGeneratedTrackReselectOnVideoChange({
  required bool generatedWasActive,
  required bool userChosen,
  required bool subtitlesOff,
}) => generatedWasActive || (!userChosen && !subtitlesOff);

/// 拿不到媒体的原因（给用户看）。
String webVideoSubtitleMediaBlockMessage(WebVideoSubtitleMediaBlock reason) =>
    switch (reason) {
      WebVideoSubtitleMediaBlock.noVideo => t.web_video_subtitle_media_no_video,
      WebVideoSubtitleMediaBlock.encrypted =>
        t.web_video_subtitle_media_encrypted,
      WebVideoSubtitleMediaBlock.noMediaAddress =>
        t.web_video_subtitle_media_no_address,
    };

/// 页面媒体地址的 Referer / YouTube 视频 id 用的观看页地址：快照里对过主机的地址，没有就用
/// [fallback]（这一集的规范地址）。
String webVideoSubtitlePageUrl(
  WebVideoSession session, {
  required String fallback,
}) {
  final String href = session.lastState?.href ?? '';
  return href.isNotEmpty ? href : fallback;
}

/// 开拉前现取输入（[prepareWebVideoSubtitleAudio]，地址短时效，不沿用起播时那一条）；拿不到
/// 媒体时以说明原因的 [VideoStreamSubtitleAudioUnavailable] 结束（进度对话框 / 内嵌面板照常
/// 显示原因）。
Future<VideoStreamSubtitleAudioInput> prepareWebVideoSessionSubtitleAudio(
  WebVideoSession session, {
  required String pageUrl,
}) async {
  try {
    return await prepareWebVideoSubtitleAudio(
      probe: () => session.evaluate('window.__fushiWebVideo.mediaSource()'),
      pageUrl: pageUrl,
      cookieHeader: session.cookieHeaderFor,
    );
  } on WebVideoSubtitleMediaBlocked catch (e) {
    throw VideoStreamSubtitleAudioUnavailable(
      webVideoSubtitleMediaBlockMessage(e.reason),
    );
  }
}

/// 开拉 [episode] 的整集音频（同一集已在拉就接上那一次）。[pageUrl] 在真正开拉时才读。
VideoStreamSubtitleAudioStaging startWebVideoSubtitleAudio({
  required WebVideoSession session,
  required WebVideoSubtitleEpisode episode,
  required int durationMs,
  required String Function() pageUrl,
}) => appVideoStreamSubtitleAudioStager.start(
  key: episode.key,
  title: episode.title,
  durationMs: durationMs,
  prepare: () =>
      prepareWebVideoSessionSubtitleAudio(session, pageUrl: pageUrl()),
);

/// [episode] 的管线目标：[audio] 是整集音频副本，产物落 app 字幕目录、登记成这一集的书的
/// 字幕（页面关了也生效，重进时读回），参考画面从页面给的视频地址抽（YouTube / 拿不到时
/// 不带画面）。副本已被清掉时 null。
Future<AppVideoSubtitleTarget?> webVideoSubtitleTarget({
  required AppVideoSubtitleService service,
  required VideoBookRepository repo,
  required WebVideoSession session,
  required WebVideoSubtitleEpisode episode,
  required String pageUrl,
  required File audio,
  String? contentLanguage,
}) async {
  final ({String url, Map<String, String> headers})? frame =
      await webVideoSubtitleFrameInput(
        probe: () => session.evaluate('window.__fushiWebVideo.mediaSource()'),
        pageUrl: pageUrl,
        cookieHeader: session.cookieHeaderFor,
      );
  final String bookUid = episode.bookUid;
  try {
    return await service.resolveStream(
      audioPath: audio.path,
      title: episode.title,
      key: episode.key,
      exportDir: videoStreamSubtitleExportDirUnder(
        await AppPaths.videoSubtitlesDirectory(),
      ),
      contentLanguage: contentLanguage == null || contentLanguage.isEmpty
          ? null
          : contentLanguage,
      remember: (String subtitlePath) =>
          repo.updateSubtitleSource(bookUid, subtitlePath),
      frameSource: frame == null
          ? null
          : videoStreamSubtitleFrameSource(
              headers: frame.headers,
              input: () async => frame.url,
            ),
    );
  } on AppVideoSubtitleTargetNotFound {
    return null;
  }
}

/// 管线任务里这一集（按整集音频副本路径 [audioPath] 认）的结果；任务没跑到它时 null。
VideoSubtitleEpisodeResult? webVideoSubtitleJobEpisode(
  AppVideoSubtitleJob job,
  String audioPath,
) => job.result?.episodes.firstWhereOrNull(
  (VideoSubtitleEpisodeResult r) => p.equals(r.videoPath, audioPath),
);
