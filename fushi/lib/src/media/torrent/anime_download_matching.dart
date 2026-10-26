import 'package:path/path.dart' as p;

import 'package:fushi_engine/media/video/jimaku_client.dart';
import 'package:fushi/src/media/video/jimaku_matching.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';

/// 旧番剧下载计划（`AnimeDownloadPlan`）的字幕落位纯逻辑：种子 add 之后按**包内
/// 真实文件名**把计划里记下的 Jimaku 条目的字幕配给视频（BUG-1206）。
///
/// 全部纯函数/纯数据（不打网络、不碰磁盘），便于单测；网络与磁盘在
/// `JimakuPlanSubtitleResolver`。按集索引与单集判据在
/// `media/video/jimaku_matching.dart`（BUG-1695，合集批量与本路径共用）。
///
/// 旧「番剧下载」对话框按种子标题预估字幕覆盖度 / 预选字幕的那一层随对话框删除
/// （BT 搜索改走 `VideoResourceRegistry`），这里只留结论是**事实**的落位层。

// ---------------------------------------------------------------------------
// 落位阶段：按包内真实文件名反查（BUG-1206 根治层）
// ---------------------------------------------------------------------------

/// 一条「包内真实视频文件 ↔ Jimaku 字幕」的配对结论。
class ResolvedSubtitleMatch {
  const ResolvedSubtitleMatch({
    required this.videoFileName,
    required this.file,
    this.episode,
  });

  /// 包内视频文件名（basename，含扩展名）。
  final String videoFileName;

  /// 配上的 Jimaku 字幕文件。
  final JimakuFile file;

  /// 从**视频文件名**解析出的集号；null = 走了 1v1 兜底（至少一方无集号）。
  ///
  /// 落位（`pairSubtitlesToVideos`）按集号严格相等对位，所以这里必须记视频侧
  /// 的集号（而不是字幕侧的）——两者本来就相等，记视频侧才是「以真实文件为准」。
  final int? episode;
}

/// 用**包内真实视频文件名**反查该配哪条 Jimaku 字幕。纯函数。
///
/// 这是 BUG-1206 的根治点。此前配对发生在种子 add 之前，输入只有种子标题：
/// 「包里有几集」靠 `全13話` / AniList `media.episodes` 猜（两者都没有就不设
/// 上界），「哪一集」靠标题区间推。于是两个毛病：
/// ① Jimaku 条目按**绝对集号**编号（S2 编 13-24）而包内文件是 01-12 时，
///    旧的 season 分支「取最前 cap 个」照样交出 13-24 的字幕，条数看着对、
///    集号根本对不上，UI 还画成「有字幕」；
/// ② 条目 24 集、包只 12 集时下满 24 条，多下的永远配不上任何视频。
///
/// 改用真实文件名后两个毛病都消失，且**不需要任何上界启发式**：
/// - 条数上界 = 真实视频文件数（每个视频至多配一条），不再有「猜上界」这回事；
/// - 集号来自真实文件名，与字幕集号**严格相等**才配；S2 包 01-12 遇上绝对编号
///   条目 13-24 时集号集合交集为空 → **一条都不配**，而不是配上错的。
///
/// 匹配规则（真实文件名格式五花八门，宁可不配也不猜）：
/// 1. 视频集号走 [parseVideoFilename]（覆盖 `[Group] Title - 05 [1080p].mkv` /
///    `S02E05` / `第5話` 等既有规则，与播放器侧同一套解析器，不另写一份）；
///    字幕集号走 [JimakuFile.episode]（[parseSubtitleEpisode]，先剥字幕扩展名
///    与语言子标签）。
/// 2. 集号**严格相等**才配；同集多候选按语言权重取首选
///    （[JimakuEpisodeIndex] 已按 [jimakuLanguageRank] 排好）。
/// 3. 一条都没配上时，只在「恰好 1 个视频 + 字幕侧唯一确定」的场景做 1v1 兜底
///    （剧场版 / 整季单文件字幕），且**双方都有集号却不相等时不兜底**——那正是
///    错季的典型形状。
/// 4. 其余一律不配（返回空），由调用方显式降级并告知用户，不静默。
///
/// [videoFileNames] 可以传绝对路径或裸文件名，内部一律取 basename。
List<ResolvedSubtitleMatch> matchJimakuFilesToVideoNames(
  List<String> videoFileNames,
  List<JimakuFile> jimakuFiles, {
  String? preferredLanguage,
}) {
  if (videoFileNames.isEmpty || jimakuFiles.isEmpty) {
    return const <ResolvedSubtitleMatch>[];
  }
  final JimakuEpisodeIndex index = JimakuEpisodeIndex.fromFiles(
    jimakuFiles,
    preferredLanguage: preferredLanguage,
  );
  if (index.isEmpty) return const <ResolvedSubtitleMatch>[];

  // ① 按集号严格相等逐个视频反查。判据本身走共享原语
  // （[chooseJimakuFileForEpisode]，BUG-1695），这里只负责「有几个视频、集号从
  // 文件名怎么来」——即本函数相对批量路径多出来的那部分信息。
  final List<ResolvedSubtitleMatch> out = <ResolvedSubtitleMatch>[];
  for (final String path in videoFileNames) {
    final String name = p.basename(path);
    final int? episode = parseVideoFilename(name).episode;
    if (episode == null) continue;
    final JimakuEpisodeMatch match = chooseJimakuFileForEpisode(
      index,
      episode: episode,
      // 未编号字幕的 1v1 兜底由下面 ② 统一处理（它还要看视频侧集号），这里
      // 只取精确命中，故一律 false。
      soleTarget: false,
    );
    if (match.kind != JimakuEpisodeMatchKind.exact) continue;
    out.add(
      ResolvedSubtitleMatch(
        videoFileName: name,
        file: match.file!,
        episode: episode,
      ),
    );
  }
  if (out.isNotEmpty) return out;

  // ② 1v1 兜底：只覆盖「1 个视频 + 字幕侧唯一确定」，多文件时绝不猜。
  if (videoFileNames.length != 1) return const <ResolvedSubtitleMatch>[];
  final String only = p.basename(videoFileNames.first);
  final JimakuFile? sole = index.unnumbered.isNotEmpty
      ? index.unnumbered.first
      : (index.totalFiles == 1 ? index.byEpisode.values.first.first : null);
  if (sole == null) return const <ResolvedSubtitleMatch>[];
  // 双方都有集号却没在 ① 配上 ⇒ 集号不等 ⇒ 错季/错编号，不配。
  if (parseVideoFilename(only).episode != null && sole.episode != null) {
    return const <ResolvedSubtitleMatch>[];
  }
  return <ResolvedSubtitleMatch>[
    ResolvedSubtitleMatch(videoFileName: only, file: sole),
  ];
}
