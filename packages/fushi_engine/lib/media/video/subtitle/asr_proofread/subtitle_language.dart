/// 视频字幕管线的目标语言（spec `2026-11-04-video-subtitle-mandarin`）。
///
/// 一个值决定：识别用哪种 [asr.AsrLanguage]、抽哪条音轨、导出后缀、各 AI 阶段用哪套
/// 提示词、任务目录与专名表键怎么隔开。日语是原有行为：日语的任务目录名、专名表键、
/// 提示词都与加入本枚举前逐字相同（已有缓存照用）。
library;

import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';

enum VideoSubtitleLanguage {
  japanese(
    tag: 'ja',
    asrLanguage: asr.AsrLanguage.japanese,
    audioTrackTags: <String>{'jpn', 'ja'},
  ),
  mandarin(
    tag: 'zh',
    asrLanguage: asr.AsrLanguage.mandarin,
    audioTrackTags: <String>{
      'zho',
      'chi',
      'cmn',
      'zh',
      'zh-cn',
      'zh-tw',
      'zh-hans',
      'zh-hant',
    },
  );

  const VideoSubtitleLanguage({
    required this.tag,
    required this.asrLanguage,
    required this.audioTrackTags,
  });

  /// BCP-47 主标签：导出后缀（`<视频名>.<tag>.srt`）、证据的目标语言、CLI / 偏好里的值。
  final String tag;
  final asr.AsrLanguage asrLanguage;

  /// 探测到的音轨语言标签（小写）里算作本语言的值。
  final Set<String> audioTrackTags;

  /// 按 [tag] 找；不认识返回 null。
  static VideoSubtitleLanguage? fromTag(String? tag) {
    final String t = (tag ?? '').trim().toLowerCase();
    for (final VideoSubtitleLanguage l in values) {
      if (l.tag == t) return l;
    }
    return null;
  }

  /// 任务目录名：日语沿用原来的 [base]（已有缓存照用）；其它语言加 `.<tag>`，同一视频
  /// 换语言不会复用别的语言的识别稿 / 校对缓存。
  String jobId(String base) =>
      this == VideoSubtitleLanguage.japanese ? base : '$base.$tag';

  /// 专名表存储键：日语沿用作品键；其它语言加 `:<tag>`（同一部作品的中文配音与日语
  /// 原版要各自一张表）。
  String glossaryKey(String workKey) =>
      this == VideoSubtitleLanguage.japanese ? workKey : '$workKey:$tag';

  /// 提示词里的作品名。日语：日文原名 → AniDB 汉字标题 → 显示标题（原有规则）。
  /// 普通话：原名是中文（有汉字、没有假名）就用原名，否则用显示标题——中文配音的日本
  /// 动画原名是日文，拿去搜中文资料 / 写进中文提示词都不对。
  String workTitle(SubtitleWorkContext work) => switch (this) {
    VideoSubtitleLanguage.japanese => work.japaneseTitle,
    VideoSubtitleLanguage.mandarin =>
      looksLikeChineseText(work.originalTitle ?? '')
          ? work.originalTitle!
          : work.title,
  };
}

final RegExp _kHan = RegExp(r'\p{Script=Han}', unicode: true);
final RegExp _kKana = RegExp(
  r'[\p{Script=Hiragana}\p{Script=Katakana}]',
  unicode: true,
);

/// 有汉字、没有假名：按书写系统看像中文（日文标题几乎总带假名；全汉字的日文标题会被
/// 误判，那种标题拿来当中文作品名也读得通）。
bool looksLikeChineseText(String text) =>
    _kHan.hasMatch(text) && !_kKana.hasMatch(text);

/// 从探测结果里挑 [language] 的音轨：有对应语言标签的取第一条，否则取第一条音轨；
/// 没有音轨返回 null。返回的是**全局流序号**（`-map 0:<index>`）。
int? pickVideoSubtitleAudioStream(
  List<AudioTrackFacts> tracks,
  VideoSubtitleLanguage language,
) {
  if (tracks.isEmpty) return null;
  for (final AudioTrackFacts t in tracks) {
    final String? lang = t.language?.toLowerCase();
    if (lang != null && language.audioTrackTags.contains(lang)) return t.index;
  }
  return tracks.first.index;
}

/// 按音轨标签猜目标语言：有中文标签、没有日语标签 → 普通话；其余（含没有标签）→ 日语
/// （原有默认）。面板用它给语言选择定初值，用户可改。
VideoSubtitleLanguage guessVideoSubtitleLanguage(List<AudioTrackFacts> tracks) {
  bool has(VideoSubtitleLanguage l) => tracks.any(
    (AudioTrackFacts t) =>
        l.audioTrackTags.contains(t.language?.toLowerCase() ?? ''),
  );
  return has(VideoSubtitleLanguage.mandarin) &&
          !has(VideoSubtitleLanguage.japanese)
      ? VideoSubtitleLanguage.mandarin
      : VideoSubtitleLanguage.japanese;
}
