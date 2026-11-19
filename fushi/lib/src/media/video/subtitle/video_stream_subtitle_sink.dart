/// 在线流「生成字幕」的产物落点（[AppSubtitleOutputSink] 的流实现）。
///
/// - 导出目录：应用自有的 `<文档>/video_subtitles/generated`（流没有「媒体旁」可写；输入
///   是拉到本机的整集音频副本，见 `video_stream_subtitle_audio.dart`）。归在存储页
///   「字幕」类目下，与 Jimaku 下载、导入的字幕同一个根。
/// - 登记：流没有 `video_books` 行可写 `subtitleSource`。远端视频的字幕选择按集记在
///   prefs（`remote_subtitle_sources`），由调用方给的 [VideoStreamSubtitleSink.remember]
///   写入——转录要好几分钟，用户常常先退出播放页，页面那条「结束后切成当前字幕」走不到时，
///   重进这一集靠它用上生成的字幕（与本机视频单集入口替换字幕选择同一个理由，用户反馈
///   DEStBY5I66）。
/// - 登记后删掉暂存的整集音频副本（它只是转写的输入，识别稿与导出都在各自的目录里）；
///   登记失败时留着，下次生成直接复用、不重拉。
/// - 样式参考不用：流没有媒体旁的 ASS。证据只有管线默认收集的（副本旁 / 内嵌都没有）
///   加播放器里正对照着的字幕（页面经 `pinnedEvidence` 交过来）。
library;

import 'dart:io';

import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart'
    show VideoSubtitleEpisodeResult;

import 'package:fushi/src/media/video/subtitle/app_video_subtitle_types.dart';
import 'package:fushi/src/media/video/video_playback_remote.dart'
    show VideoRemoteJobKind;

class VideoStreamSubtitleSink implements AppSubtitleOutputSink {
  VideoStreamSubtitleSink({
    required this.exportDir,
    this.stagedAudio = const <String>{},
    this.remember,
  });

  /// 导出目录（`video_stream_subtitle_audio.dart` 的 `videoStreamSubtitleExportDirUnder`）。
  final Directory exportDir;

  /// 只为这次转写拉到本机的整集音频副本：登记后删掉。
  final Set<String> stagedAudio;

  /// 把导出的字幕记成这一集的字幕选择（远端按集的 prefs）；null = 不记（测试）。
  final Future<void> Function(String subtitlePath)? remember;

  @override
  AppSubtitleTargetDomain get domain => AppSubtitleTargetDomain.video;

  @override
  Directory exportDirFor(String mediaPath) => exportDir;

  @override
  bool get registersSkippedExisting => false;

  @override
  bool get usesStyleReference => false;

  @override
  VideoRemoteJobKind get mirrorKind => VideoRemoteJobKind.subtitleGenerate;

  @override
  String mirrorSubject(AppVideoSubtitleTarget target) => target.key;

  @override
  Future<List<String>> extraEvidenceFiles(
    AppVideoSubtitleEpisode episode,
  ) async => const <String>[];

  @override
  Future<List<String>> register(
    AppVideoSubtitleEpisode episode,
    VideoSubtitleEpisodeResult result,
  ) async {
    final String? output = result.outputPath;
    if (output == null) return const <String>[];
    final Future<void> Function(String subtitlePath)? remember = this.remember;
    if (remember != null) await remember(output);
    // 删的是本 sink 自己拉下来的整集音频副本（[stagedAudio] 里登记的那一份），不是
    // 库路径：按登记表取出这份副本再删。
    final String? staged = stagedAudio.lookup(episode.videoPath);
    if (staged != null) {
      final File audio = File(staged);
      if (await audio.exists()) await audio.delete();
    }
    // 没有库条目 / 曲目身份可报（选择记在按集的 prefs 里）。
    return const <String>[];
  }
}
