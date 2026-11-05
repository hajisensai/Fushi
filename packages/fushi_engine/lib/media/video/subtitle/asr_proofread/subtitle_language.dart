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

/// 声明过的语言标签（`VideoBooks.language`、TMDB `original_language`）→ 能跑的字幕
/// 语言。认不出或不支持（`ko` / `en`、粤语 `yue` / `cn` / `zh-HK` / `zh-MO`）返回
/// null，由下一档决定。
///
/// 不用 `normalizeSubtitleLanguageCode`：它把 `yue` 归成 `zh`（字幕筛选够用），但
/// 粤语音频喂普通话识别模型是错的。`zh-Hant` 只是书写系统，仍算普通话。
VideoSubtitleLanguage? videoSubtitleLanguageForTag(String? tag) {
  final List<String> parts = (tag ?? '')
      .trim()
      .toLowerCase()
      .replaceAll('_', '-')
      .split('-');
  final String base = parts.first;
  if (const <String>{'ja', 'jpn', 'jp'}.contains(base)) {
    return VideoSubtitleLanguage.japanese;
  }
  if (const <String>{'zh', 'zho', 'chi', 'cmn'}.contains(base)) {
    if (parts.contains('yue') || parts.contains('hk') || parts.contains('mo')) {
      return null;
    }
    return VideoSubtitleLanguage.mandarin;
  }
  return null;
}

/// 音轨标签**明确**时的语言：带标签的音轨里只出现一种能跑的语言（日语或中文）才算；
/// 日中双音轨、没有标签、只有别的语言都返回 null（标签说明不了要哪条）。
VideoSubtitleLanguage? videoSubtitleLanguageFromAudio(
  List<AudioTrackFacts> tracks,
) {
  final Set<VideoSubtitleLanguage> seen = <VideoSubtitleLanguage>{
    for (final AudioTrackFacts t in tracks)
      for (final VideoSubtitleLanguage l in VideoSubtitleLanguage.values)
        if (l.audioTrackTags.contains(t.language?.toLowerCase() ?? '')) l,
  };
  return seen.length == 1 ? seen.single : null;
}

/// 面板语言初值是从哪一档来的（面板据此提示「为什么选了它」）。
enum VideoSubtitleLanguageSource {
  /// 用户给这个视频设的内容语言。
  contentLanguage,

  /// 音轨语言标签（只有一种能跑的语言时）。
  audioTrack,

  /// 刮削资料里作品的原语言。
  metadata,

  /// 什么都没有：日语（原有默认）。
  fallback,
}

typedef VideoSubtitleLanguageGuess = ({
  VideoSubtitleLanguage language,
  VideoSubtitleLanguageSource source,
});

/// 每集的内容语言（[contentLanguages]，没设的为 null / 空）合成一个：设了的全部
/// 指向同一种能跑的语言才算；有冲突或有不支持的值返回 null。
VideoSubtitleLanguage? videoSubtitleLanguageForContent(
  Iterable<String?> contentLanguages,
) {
  final List<String> set = <String>[
    for (final String? tag in contentLanguages)
      if ((tag ?? '').trim().isNotEmpty) tag!,
  ];
  if (set.isEmpty) return null;
  final Set<VideoSubtitleLanguage?> mapped = <VideoSubtitleLanguage?>{
    for (final String tag in set) videoSubtitleLanguageForTag(tag),
  };
  return mapped.length == 1 ? mapped.single : null;
}

/// 面板语言初值（用户可改）。按「这部作品自己的证据」从强到弱，取第一档有结论的：
/// 1. 用户给视频设的内容语言（[contentLanguages]，整季要一致）；
/// 2. 明确的音轨标签（[videoSubtitleLanguageFromAudio]）；
/// 3. 刮削的作品原语言（[originalLanguage]）；
/// 4. 日语。
///
/// 音轨在原语言前面：日本动画的普通话配音版，刮削原语言是 `ja`，只有音轨说得对。
/// 全局「默认内容语言」不参与——它不是这部作品的证据（同字幕下载 BUG-3083）。
VideoSubtitleLanguageGuess resolveVideoSubtitleLanguage({
  Iterable<String?> contentLanguages = const <String?>[],
  List<AudioTrackFacts> audioTracks = const <AudioTrackFacts>[],
  String? originalLanguage,
}) {
  final VideoSubtitleLanguage? content = videoSubtitleLanguageForContent(
    contentLanguages,
  );
  if (content != null) {
    return (
      language: content,
      source: VideoSubtitleLanguageSource.contentLanguage,
    );
  }
  final VideoSubtitleLanguage? audio = videoSubtitleLanguageFromAudio(
    audioTracks,
  );
  if (audio != null) {
    return (language: audio, source: VideoSubtitleLanguageSource.audioTrack);
  }
  final VideoSubtitleLanguage? original = videoSubtitleLanguageForTag(
    originalLanguage,
  );
  if (original != null) {
    return (language: original, source: VideoSubtitleLanguageSource.metadata);
  }
  return (
    language: VideoSubtitleLanguage.japanese,
    source: VideoSubtitleLanguageSource.fallback,
  );
}
