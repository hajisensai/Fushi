/// 「一组字幕文件里哪一个是这一集的」的**唯一决策原语**（泛型核心）。
///
/// 此前同一个问题在仓库里有三份互相矛盾的答案（BUG-1695）：番剧下载落位集号
/// 对不上就不配、合集批量集号对不上就退回列表第一个、播放页由用户肉眼挑。两条
/// 自动路径给出相反结论，说明判据没有被表达成一个东西。本文件就是那个东西：
/// [SubtitleEpisodeIndex] 是字幕侧的事实，[chooseSubtitleForEpisode] 是唯一判据。
///
/// 它对文件类型泛化（`T`）：Jimaku 的 `JimakuFile` 与 registry 的
/// [VideoSubtitleCandidate] 都只是 `T` 的一种实例，各自只提供「怎么取集号」与
/// 「同一集里怎么排序」，不允许再各写一遍 `where(...).isNotEmpty ? ... : ...`。
/// `jimaku_matching.dart` 是 `JimakuFile` 的薄适配层，决策逻辑只存在于这里。
library;

import 'package:fushi/src/media/video/jimaku_client.dart'
    show jimakuLanguageRank;
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

/// 按集索引：字幕侧的事实，不含任何决策。
///
/// [byEpisode] 每个 value 都是非空列表，且已按调用方给定的 [build] `compare`
/// 排好（约定：语言权重升序，首个即首选）；[unnumbered] 同样排好。
class SubtitleEpisodeIndex<T> {
  const SubtitleEpisodeIndex({
    required this.byEpisode,
    required this.unnumbered,
  });

  /// 通用构建：[episodeOf] 取集号（null = 未编号），[compare] 决定每集 /
  /// 未编号列表内的顺序（语言权重升序等）。不做任何过滤——要丢弃的文件
  /// （非文本字幕等）由调用方在传入前筛掉。
  factory SubtitleEpisodeIndex.build(
    Iterable<T> files, {
    required int? Function(T) episodeOf,
    required int Function(T, T) compare,
  }) {
    final Map<int, List<T>> byEpisode = <int, List<T>>{};
    final List<T> unnumbered = <T>[];
    for (final T file in files) {
      final int? episode = episodeOf(file);
      if (episode == null) {
        unnumbered.add(file);
      } else {
        byEpisode.putIfAbsent(episode, () => <T>[]).add(file);
      }
    }
    for (final List<T> candidates in byEpisode.values) {
      candidates.sort(compare);
    }
    unnumbered.sort(compare);
    return SubtitleEpisodeIndex<T>(
      byEpisode: byEpisode,
      unnumbered: unnumbered,
    );
  }

  /// 专为 registry 候选：集号取 [VideoSubtitleCandidate.episode]，语言权重用
  /// [jimakuLanguageRank]（[preferredLanguage] 优先 → ja → zh → en → ko），
  /// 同权重按 [VideoSubtitleCandidate.fileName] 小写 tie-break 保证确定性。
  static SubtitleEpisodeIndex<VideoSubtitleCandidate> fromCandidates(
    Iterable<VideoSubtitleCandidate> candidates, {
    String? preferredLanguage,
  }) {
    return SubtitleEpisodeIndex<VideoSubtitleCandidate>.build(
      candidates,
      episodeOf: (VideoSubtitleCandidate c) => c.episode,
      compare: (VideoSubtitleCandidate a, VideoSubtitleCandidate b) =>
          compareCandidatesByLanguagePreference(a, b, preferredLanguage),
    );
  }

  /// 集号 → 该集候选（已排序、非空）。
  final Map<int, List<T>> byEpisode;

  /// 认不出集号的字幕（剧场版 / 整季单文件等），同样已排序。
  final List<T> unnumbered;

  /// 索引内文件总数。
  int get totalFiles =>
      unnumbered.length +
      byEpisode.values.fold(0, (int sum, List<T> list) => sum + list.length);

  /// 索引是否为空（无任何可用字幕）。
  bool get isEmpty => totalFiles == 0;

  /// 字幕侧是否**存在**带集号的文件。
  ///
  /// 这是「集号对不上」与「字幕侧根本没编号」的分界线，也是 BUG-1695 的核心区分：
  /// 前者是冲突（错季 / 绝对集号 / 选错条目），后者是信息不足（剧场版 / 整季单文件）。
  /// 两者必须走不同分支——把后者的宽容度错用到前者身上，就是那个静默错配。
  bool get hasNumberedFiles => byEpisode.isNotEmpty;
}

/// registry 候选排序键：语言权重升序（[preferredLanguage] 优先，其次 ja）→
/// 文件名（大小写不敏感）tie-break。
int compareCandidatesByLanguagePreference(
  VideoSubtitleCandidate a,
  VideoSubtitleCandidate b,
  String? preferredLanguage,
) {
  final int rankA = jimakuLanguageRank(
    a.language,
    preferred: preferredLanguage,
  );
  final int rankB = jimakuLanguageRank(
    b.language,
    preferred: preferredLanguage,
  );
  if (rankA != rankB) return rankA.compareTo(rankB);
  return a.fileName.toLowerCase().compareTo(b.fileName.toLowerCase());
}

/// 单集选字幕的结论。
///
/// 之所以不是 `T?`：三种「没选到」的原因对用户是三件不同的事
/// （去改条目 / 去补字幕 / 无能为力），全压成 null 就只能显示一句「无匹配」。
enum SubtitleEpisodeMatchKind {
  /// 集号精确命中。
  exact,

  /// 字幕侧一个集号都没有（剧场版 / 整季单文件），且调用方确认目标唯一 → 采用。
  unnumbered,

  /// 字幕侧**有**集号但没有目标集号：错季 / 绝对集号 / 条目选错。不配。
  episodeConflict,

  /// 字幕侧只有未编号文件，但目标不止一个 → 无法确定给谁。不配。
  ambiguousUnnumbered,

  /// 没有任何可解析的字幕。
  none,
}

/// 单集选字幕的结果：[file] 仅在 [SubtitleEpisodeMatchKind.exact] /
/// [SubtitleEpisodeMatchKind.unnumbered] 时非空。
class SubtitleEpisodeMatch<T> {
  const SubtitleEpisodeMatch._(this.kind, this.file);

  const SubtitleEpisodeMatch.exact(T file)
    : this._(SubtitleEpisodeMatchKind.exact, file);

  const SubtitleEpisodeMatch.unnumbered(T file)
    : this._(SubtitleEpisodeMatchKind.unnumbered, file);

  const SubtitleEpisodeMatch.episodeConflict()
    : this._(SubtitleEpisodeMatchKind.episodeConflict, null);

  const SubtitleEpisodeMatch.ambiguousUnnumbered()
    : this._(SubtitleEpisodeMatchKind.ambiguousUnnumbered, null);

  const SubtitleEpisodeMatch.none()
    : this._(SubtitleEpisodeMatchKind.none, null);

  final SubtitleEpisodeMatchKind kind;
  final T? file;

  /// 可用（真的选到了一个文件）。
  bool get isMatched => file != null;

  /// 落任务行 / 日志的英文短语；[isMatched] 时为 null。
  ///
  /// 短语沿用 Jimaku 时代的原文（下游任务行 / 测试按字面断言），泛化后不改。
  String? get failureReason => switch (kind) {
    SubtitleEpisodeMatchKind.exact ||
    SubtitleEpisodeMatchKind.unnumbered => null,
    SubtitleEpisodeMatchKind.episodeConflict =>
      'jimaku entry has subtitles but none for this episode',
    SubtitleEpisodeMatchKind.ambiguousUnnumbered =>
      'jimaku subtitles carry no episode numbers',
    SubtitleEpisodeMatchKind.none => 'jimaku entry has no text subtitle',
  };
}

/// 为集号 [episode] 从 [index] 里选一个字幕文件——**全仓唯一判据**。
///
/// [soleTarget]：本次匹配是否只有这一个待配视频。只有它为 true 时，未编号字幕
/// （剧场版 / 整季单文件）才允许被采用；否则 N 个目标会拿到同一个文件。这个参数
/// 是 `required` 而非有默认值，正是因为默认值就是 BUG-1695 的形状：调用方不表态，
/// 判据就替它猜。
SubtitleEpisodeMatch<T> chooseSubtitleForEpisode<T>(
  SubtitleEpisodeIndex<T> index, {
  required int episode,
  required bool soleTarget,
}) {
  if (index.isEmpty) return SubtitleEpisodeMatch<T>.none();
  final List<T>? exact = index.byEpisode[episode];
  if (exact != null && exact.isNotEmpty) {
    return SubtitleEpisodeMatch<T>.exact(exact.first);
  }
  // 字幕侧有编号却没有这一集 ⇒ 集号语义冲突，绝不用别集顶替。
  if (index.hasNumberedFiles) {
    return SubtitleEpisodeMatch<T>.episodeConflict();
  }
  if (index.unnumbered.isEmpty) return SubtitleEpisodeMatch<T>.none();
  if (!soleTarget) return SubtitleEpisodeMatch<T>.ambiguousUnnumbered();
  return SubtitleEpisodeMatch<T>.unnumbered(index.unnumbered.first);
}
