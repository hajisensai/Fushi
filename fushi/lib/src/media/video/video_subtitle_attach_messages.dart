import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_subtitle_attach.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';

/// **纯映射**：把 [SubtitleAttachResult] 翻成给用户看的一句话。
///
/// BUG-1504：把字幕挂到已有视频书有两个入口（主页视频卡拖放、字幕搜索页安装到
/// 「已存在视频」），此前一个只在成功时提示、另一个在异常时什么都不提示。文案
/// 必须**从同一份失败分类派生**，否则同一个坏字幕在两处会得到两种说法。
///
/// cue 相关的失败直接沿用播放页那份 [SubtitleCueLoadFailure]（BUG-1490 四态），
/// 只有措辞按「挂载」语境选（播放页说「切不过去」，这里说「挂不上」）。
String subtitleAttachMessage(
  SubtitleAttachResult result, {
  required String title,
}) {
  switch (result.outcome) {
    case SubtitleAttachOutcome.attached:
      return t.video_subtitle_attached_to_video(
        title: title,
        count: result.cueCount,
      );
    case SubtitleAttachOutcome.playlistNeedsPlayer:
      return t.video_subtitle_attach_playlist_hint;
    case SubtitleAttachOutcome.persistFailed:
      return t.video_subtitle_import_failed;
    case SubtitleAttachOutcome.cueLoadFailed:
      return _cueFailureMessage(result.cueFailure!, result.label);
  }
}

String _cueFailureMessage(SubtitleCueLoadFailure failure, String label) {
  switch (failure) {
    case SubtitleCueLoadFailure.unsupportedFormat:
      // 拖进来的扩展名不在 srt/ass/ssa/vtt 里——这句比「无法加载」更能指路。
      return t.video_subtitle_import_unsupported;
    case SubtitleCueLoadFailure.extractionFailed:
      // 挂载路径永远是外挂文件，不经 ffmpeg 抽取；列在这里只为穷尽 switch，
      // 将来分类扩展时编译器会逼着重新决策。
      return t.video_subtitle_load_failed(label: label);
    case SubtitleCueLoadFailure.fileUnreadable:
    case SubtitleCueLoadFailure.parseFailed:
      // 扩展名是对的却读不出/解不出 = 文件本身坏或空。原来这里复用「可能是图形
      // 或不支持的字幕轨」，对一个明明是文本 ASS 的文件是错的（BUG-1490 同理）。
      return t.video_subtitle_read_failed(label: label);
  }
}
