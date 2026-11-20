/// 「这些文件是不是真的特别篇」的**纯 Dart 契约**（所有者 2026-11-20：「为什么
/// 不直接让 ai 看？模型不能全干吗？」）。
///
/// 库管家把一部剧集作品里「挂在第 0 季 / 没绑到任何一集」的本机文件连同作品事实
/// 打包成 [AiVideoPlacementQuery]，交给注入的 [AiVideoPlacementJudge]；怎么问模型
/// 是 `ai/ai_video_placement_assistant.dart` 的事。判定只有四种，模型不产生任何
/// 资料源 id、不指定磁盘路径：
///
/// - `special`：确实是这部作品的特别篇 / OVA / 特典，放得对；
/// - `movie`：其实是一部独立的作品（剧场版 / 电影），应当拆出去单独识别；
/// - `episode`：其实是这部作品正片的某一集，给出季号与集号；
/// - `unsure`：看不出来。
///
/// 置信度低于 [kAiVideoPlacementAutoAcceptConfidence] 的不自动执行，进待确认。
///
/// 纯 Dart（不 import flutter / 插件 / `package:fushi`）。
library;

/// 自动执行的置信度门槛（含），与认身份同一个数。
const double kAiVideoPlacementAutoAcceptConfidence = 0.85;

enum AiVideoPlacementVerdict { special, movie, episode, unsure }

/// 交给模型看的一个文件。
class AiVideoPlacementFile {
  const AiVideoPlacementFile({
    required this.key,
    required this.path,
    this.minutes,
    this.boundTo,
    this.episodeTitle,
    this.episodeMinutes,
  });

  /// 这次提问里的短键（`f1`、`f2`…），回复按它对回文件。
  final String key;

  /// 相对来源库根的路径（目录名往往比文件名更说明问题）。
  final String path;
  final int? minutes;

  /// 现在绑到的第 0 季集位（`S00E01`）；null = 在作品合集里但没绑到任何一集。
  final String? boundTo;

  /// 资料源里那一集的标题与时长。
  final String? episodeTitle;
  final int? episodeMinutes;

  Map<String, Object?> toJson() => <String, Object?>{
    'key': key,
    'path': path,
    if (minutes != null) 'minutes': minutes,
    'boundTo': boundTo,
    if (episodeTitle != null) 'episodeTitle': episodeTitle,
    if (episodeMinutes != null) 'episodeMinutes': episodeMinutes,
  };
}

/// 一次提问：一部作品 + 它要看的文件。
class AiVideoPlacementQuery {
  AiVideoPlacementQuery({
    required this.workTitle,
    required List<AiVideoPlacementFile> files,
    this.originalTitle,
    this.year,
    this.regularEpisodeMinutes,
    this.regularLocalFiles = 0,
    Map<int, int> regularSeasons = const <int, int>{},
    Map<int, List<int>> occupiedEpisodes = const <int, List<int>>{},
    this.locale = 'en',
  }) : files = List<AiVideoPlacementFile>.unmodifiable(files),
       regularSeasons = Map<int, int>.unmodifiable(regularSeasons),
       occupiedEpisodes = Map<int, List<int>>.unmodifiable(<int, List<int>>{
         for (final MapEntry<int, List<int>> e in occupiedEpisodes.entries)
           e.key: List<int>.unmodifiable(e.value),
       });

  final String workTitle;
  final String? originalTitle;
  final int? year;

  /// 正片单集时长（分钟）。
  final int? regularEpisodeMinutes;

  /// 绑在正片季上的本机文件数。
  final int regularLocalFiles;

  /// 资料源里的正片各季：季号 → 集数。
  final Map<int, int> regularSeasons;

  /// 正片季里已经绑着本机文件的集：季号 → 集号。判 `episode` 不能指到这些集。
  final Map<int, List<int>> occupiedEpisodes;
  final List<AiVideoPlacementFile> files;

  /// (季, 集) 是否已经绑着本机文件。
  bool isOccupied(int season, int episode) =>
      occupiedEpisodes[season]?.contains(episode) ?? false;
  final String locale;

  Map<String, Object?> toJson() => <String, Object?>{
    'work': <String, Object?>{
      'title': workTitle,
      if (originalTitle != null) 'originalTitle': originalTitle,
      if (year != null) 'year': year,
      if (regularEpisodeMinutes != null)
        'regularEpisodeMinutes': regularEpisodeMinutes,
      'regularSeasons': <String, int>{
        for (final MapEntry<int, int> e in regularSeasons.entries)
          '${e.key}': e.value,
      },
      'localRegularFiles': regularLocalFiles,
      if (occupiedEpisodes.isNotEmpty)
        'occupiedEpisodes': <String, List<int>>{
          for (final MapEntry<int, List<int>> e in occupiedEpisodes.entries)
            '${e.key}': e.value,
        },
    },
    'files': <Map<String, Object?>>[
      for (final AiVideoPlacementFile f in files) f.toJson(),
    ],
  };
}

/// 模型对一个文件的判定（已过本地校验）。
class AiVideoPlacementAnswer {
  const AiVideoPlacementAnswer({
    required this.key,
    required this.verdict,
    required this.confidence,
    this.title,
    this.season,
    this.episode,
    this.reason = '',
  });

  final String key;
  final AiVideoPlacementVerdict verdict;
  final double confidence;

  /// `movie`：这部电影在资料库里最可能的标题（给后面的候选搜索当搜索词）。
  final String? title;

  /// `episode`：正片的季号 / 集号（已校验落在作品的正片季集范围内）。
  final int? season;
  final int? episode;
  final String reason;

  bool get isAutoAcceptable =>
      verdict != AiVideoPlacementVerdict.unsure &&
      confidence >= kAiVideoPlacementAutoAcceptConfidence;
}

/// 判定器。回空表 / 缺某个文件 = 那个文件没有结论。
typedef AiVideoPlacementJudge =
    Future<List<AiVideoPlacementAnswer>> Function(AiVideoPlacementQuery query);
