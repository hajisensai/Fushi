/// Jimaku 字幕「哪一个文件是这一集的」的**唯一决策原语**。
///
/// 此前同一个问题在仓库里有三份互相矛盾的答案（BUG-1695）：
/// - `matchJimakuFilesToVideoNames`（番剧下载落位）：集号对不上就**不配**；
/// - `pickBestSubtitleFile`（合集批量）：集号对不上就**退回列表第一个**，于是
///   整季 12 集全挂同一个错字幕，状态还显示 done；
/// - 播放页对话框：由用户肉眼挑。
///
/// 两条自动路径给出相反结论，说明判据没有被表达成一个东西。本文件就是那个东西：
/// [JimakuEpisodeIndex] 是字幕侧的事实，[chooseJimakuFileForEpisode] 是唯一判据，
/// 其它模块只允许调用它，不再各写一遍 `where(...).isNotEmpty ? ... : ...`。
library;

import 'package:fushi/src/media/video/jimaku_client.dart';

/// 从 Jimaku 文件列表构建的按集索引。
///
/// 只收文本字幕（[JimakuFile.isTextSubtitle]）；每集候选按语言权重升序排列
/// （[jimakuLanguageRank] + [detectSubtitleLanguage]，即 ja 优先），同权重按
/// 文件名（大小写不敏感）tie-break 保证确定性。
class JimakuEpisodeIndex {
  const JimakuEpisodeIndex._({
    required this.byEpisode,
    required this.unnumbered,
  });

  /// 从 [files] 构建索引（非文本字幕直接丢弃）。
  factory JimakuEpisodeIndex.fromFiles(
    List<JimakuFile> files, {
    String? preferredLanguage,
  }) {
    final Map<int, List<JimakuFile>> byEpisode = <int, List<JimakuFile>>{};
    final List<JimakuFile> unnumbered = <JimakuFile>[];
    for (final JimakuFile file in files) {
      if (!file.isTextSubtitle) continue;
      final int? episode = file.episode;
      if (episode == null) {
        unnumbered.add(file);
      } else {
        byEpisode.putIfAbsent(episode, () => <JimakuFile>[]).add(file);
      }
    }
    for (final List<JimakuFile> candidates in byEpisode.values) {
      candidates.sort((JimakuFile a, JimakuFile b) =>
          compareJimakuByLanguagePreference(a, b, preferredLanguage));
    }
    unnumbered.sort((JimakuFile a, JimakuFile b) =>
        compareJimakuByLanguagePreference(a, b, preferredLanguage));
    return JimakuEpisodeIndex._(byEpisode: byEpisode, unnumbered: unnumbered);
  }

  /// 集号 → 该集候选（语言权重升序 = ja 优先，非空列表）。
  final Map<int, List<JimakuFile>> byEpisode;

  /// 认不出集号的文本字幕（剧场版/整季单文件等），同样按语言权重升序。
  final List<JimakuFile> unnumbered;

  /// 索引内文本字幕总数。
  int get totalFiles =>
      unnumbered.length +
      byEpisode.values
          .fold(0, (int sum, List<JimakuFile> list) => sum + list.length);

  /// 索引是否为空（无任何可用文本字幕）。
  bool get isEmpty => totalFiles == 0;

  /// 字幕侧是否**存在**带集号的文件。
  ///
  /// 这是「集号对不上」与「字幕侧根本没编号」的分界线，也是 BUG-1695 的核心区分：
  /// 前者是冲突（错季 / 绝对集号 / 选错条目），后者是信息不足（剧场版 / 整季单文件）。
  /// 两者必须走不同分支——把后者的宽容度错用到前者身上，就是那个静默错配。
  bool get hasNumberedFiles => byEpisode.isNotEmpty;
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

/// 单集选字幕的结论。
///
/// 之所以不是 `JimakuFile?`：三种「没选到」的原因对用户是三件不同的事
/// （去改条目 / 去补字幕 / 无能为力），全压成 null 就只能显示一句「无匹配」。
enum JimakuEpisodeMatchKind {
  /// 集号精确命中。
  exact,

  /// 字幕侧一个集号都没有（剧场版 / 整季单文件），且调用方确认目标唯一 → 采用。
  unnumbered,

  /// 字幕侧**有**集号但没有目标集号：错季 / 绝对集号 / 条目选错。不配。
  episodeConflict,

  /// 字幕侧只有未编号文件，但目标不止一个 → 无法确定给谁。不配。
  ambiguousUnnumbered,

  /// 没有任何可解析的文本字幕。
  none,
}

/// 单集选字幕的结果：[file] 仅在 [JimakuEpisodeMatchKind.exact] /
/// [JimakuEpisodeMatchKind.unnumbered] 时非空。
class JimakuEpisodeMatch {
  const JimakuEpisodeMatch._(this.kind, this.file);

  const JimakuEpisodeMatch.exact(JimakuFile file)
      : this._(JimakuEpisodeMatchKind.exact, file);

  const JimakuEpisodeMatch.unnumbered(JimakuFile file)
      : this._(JimakuEpisodeMatchKind.unnumbered, file);

  const JimakuEpisodeMatch.episodeConflict()
      : this._(JimakuEpisodeMatchKind.episodeConflict, null);

  const JimakuEpisodeMatch.ambiguousUnnumbered()
      : this._(JimakuEpisodeMatchKind.ambiguousUnnumbered, null);

  const JimakuEpisodeMatch.none() : this._(JimakuEpisodeMatchKind.none, null);

  final JimakuEpisodeMatchKind kind;
  final JimakuFile? file;

  /// 可用（真的选到了一个文件）。
  bool get isMatched => file != null;

  /// 落任务行 / 日志的英文短语；[isMatched] 时为 null。
  String? get failureReason => switch (kind) {
        JimakuEpisodeMatchKind.exact ||
        JimakuEpisodeMatchKind.unnumbered =>
          null,
        JimakuEpisodeMatchKind.episodeConflict =>
          'jimaku entry has subtitles but none for this episode',
        JimakuEpisodeMatchKind.ambiguousUnnumbered =>
          'jimaku subtitles carry no episode numbers',
        JimakuEpisodeMatchKind.none => 'jimaku entry has no text subtitle',
      };
}

/// 为集号 [episode] 从 [index] 里选一个字幕文件——**全仓唯一判据**。
///
/// [soleTarget]：本次匹配是否只有这一个待配视频。只有它为 true 时，未编号字幕
/// （剧场版 / 整季单文件）才允许被采用；否则 N 个目标会拿到同一个文件。这个参数
/// 是 `required` 而非有默认值，正是因为默认值就是 BUG-1695 的形状：调用方不表态，
/// 判据就替它猜。
JimakuEpisodeMatch chooseJimakuFileForEpisode(
  JimakuEpisodeIndex index, {
  required int episode,
  required bool soleTarget,
}) {
  if (index.isEmpty) return const JimakuEpisodeMatch.none();
  final List<JimakuFile>? exact = index.byEpisode[episode];
  if (exact != null && exact.isNotEmpty) {
    return JimakuEpisodeMatch.exact(exact.first);
  }
  // 字幕侧有编号却没有这一集 ⇒ 集号语义冲突，绝不用别集顶替。
  if (index.hasNumberedFiles) {
    return const JimakuEpisodeMatch.episodeConflict();
  }
  if (index.unnumbered.isEmpty) return const JimakuEpisodeMatch.none();
  if (!soleTarget) return const JimakuEpisodeMatch.ambiguousUnnumbered();
  return JimakuEpisodeMatch.unnumbered(index.unnumbered.first);
}
