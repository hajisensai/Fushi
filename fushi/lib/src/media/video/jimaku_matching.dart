/// Jimaku 字幕「哪一个文件是这一集的」——`JimakuFile` 的**薄适配层**。
///
/// 决策逻辑**只存在于** `subtitle/subtitle_episode_matching.dart`
/// （[SubtitleEpisodeIndex] / [chooseSubtitleForEpisode]）；本文件不含任何
/// if/else，只负责三件事：
/// - 把 [JimakuFile] 列表筛成文本字幕并交给泛型索引构建（[JimakuEpisodeIndex.fromFiles]）；
/// - 给 Jimaku 侧提供排序键（[compareJimakuByLanguagePreference]）；
/// - 保留 `JimakuEpisodeIndex` / `JimakuEpisodeMatch` / `JimakuEpisodeMatchKind` /
///   `chooseJimakuFileForEpisode` 这组名字，让既有调用方零改动。
///
/// 历史（BUG-1695）：同一个问题曾在仓库里有三份互相矛盾的答案（番剧下载落位
/// 集号对不上就不配、合集批量集号对不上就退回列表第一个、播放页由用户肉眼挑）。
/// 判据只能有一个——现在它在泛型核心里，Jimaku 与 registry 候选共用同一份。
library;

import 'package:fushi/src/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_episode_matching.dart';

/// 从 Jimaku 文件列表构建的按集索引（[SubtitleEpisodeIndex] 的 `JimakuFile` 实例）。
///
/// 只收文本字幕（[JimakuFile.isTextSubtitle]）；每集候选按语言权重升序排列
/// （[jimakuLanguageRank] + [detectSubtitleLanguage]，即 ja 优先），同权重按
/// 文件名（大小写不敏感）tie-break 保证确定性。
class JimakuEpisodeIndex extends SubtitleEpisodeIndex<JimakuFile> {
  const JimakuEpisodeIndex._({
    required super.byEpisode,
    required super.unnumbered,
  });

  /// 从 [files] 构建索引（非文本字幕直接丢弃）。
  factory JimakuEpisodeIndex.fromFiles(
    List<JimakuFile> files, {
    String? preferredLanguage,
  }) {
    final SubtitleEpisodeIndex<JimakuFile> core =
        SubtitleEpisodeIndex<JimakuFile>.build(
      files.where((JimakuFile file) => file.isTextSubtitle),
      episodeOf: (JimakuFile file) => file.episode,
      compare: (JimakuFile a, JimakuFile b) =>
          compareJimakuByLanguagePreference(a, b, preferredLanguage),
    );
    return JimakuEpisodeIndex._(
      byEpisode: core.byEpisode,
      unnumbered: core.unnumbered,
    );
  }
}

/// 候选排序键：语言权重升序（ja 优先）→ 文件名（大小写不敏感）tie-break。
int compareJimakuByLanguagePreference(
  JimakuFile a,
  JimakuFile b,
  String? preferredLanguage,
) {
  final int rankA = jimakuLanguageRank(detectSubtitleLanguage(a.name),
      preferred: preferredLanguage);
  final int rankB = jimakuLanguageRank(detectSubtitleLanguage(b.name),
      preferred: preferredLanguage);
  if (rankA != rankB) return rankA.compareTo(rankB);
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// 单集选字幕的结论（同 [SubtitleEpisodeMatchKind]，保留旧名）。
typedef JimakuEpisodeMatchKind = SubtitleEpisodeMatchKind;

/// 单集选字幕的结果（同 [SubtitleEpisodeMatch]，`JimakuFile` 实例，保留旧名）。
typedef JimakuEpisodeMatch = SubtitleEpisodeMatch<JimakuFile>;

/// 为集号 [episode] 从 [index] 里选一个字幕文件。
///
/// 纯委托 [chooseSubtitleForEpisode]——判据不在这里。[soleTarget] 语义见那里。
JimakuEpisodeMatch chooseJimakuFileForEpisode(
  JimakuEpisodeIndex index, {
  required int episode,
  required bool soleTarget,
}) =>
    chooseSubtitleForEpisode<JimakuFile>(
      index,
      episode: episode,
      soleTarget: soleTarget,
    );
