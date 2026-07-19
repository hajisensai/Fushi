import 'package:hibiki/src/media/torrent/nyaa_client.dart';
import 'package:hibiki/src/media/video/jimaku_client.dart';

/// 番剧下载选种对话框的纯决策逻辑：Jimaku 字幕按集索引 + 种子↔字幕匹配。
///
/// 全部纯函数/纯数据（不打网络、不碰磁盘），便于单测；对话框只做编排与渲染。

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
  factory JimakuEpisodeIndex.fromFiles(List<JimakuFile> files) {
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
      candidates.sort(_compareByLanguagePreference);
    }
    unnumbered.sort(_compareByLanguagePreference);
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
}

/// 候选排序键：语言权重升序（ja 优先）→ 文件名（大小写不敏感）tie-break。
int _compareByLanguagePreference(JimakuFile a, JimakuFile b) {
  final int rankA = jimakuLanguageRank(detectSubtitleLanguage(a.name));
  final int rankB = jimakuLanguageRank(detectSubtitleLanguage(b.name));
  if (rankA != rankB) return rankA.compareTo(rankB);
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

/// 计算种子 [t] 的字幕覆盖度（列表徽标「字幕 covered/total」用）。
///
/// 分支（batch 优先——合集标题常同时被解析出区间末位当「单集号」，
/// 区间存在时它才是真相，与 [NyaaTorrent.isBatch] 的判定一致）：
/// - batch（`episodeRange != null`）→ `total` = 区间长度，`covered` = 区间内
///   有候选的集数；
/// - 单集（`episode != null`）→ `total` 1，`covered` 0/1；
/// - 两者皆无（剧场版/单文件，无法判断集数）→ `total` null，`covered` =
///   索引里有任意文件则 1，否则 0。
({int covered, int? total}) jimakuCoverageFor(
  NyaaTorrent t,
  JimakuEpisodeIndex index,
) {
  final (int, int)? range = t.episodeRange;
  if (range != null) {
    int covered = 0;
    for (int episode = range.$1; episode <= range.$2; episode++) {
      if (index.byEpisode.containsKey(episode)) covered++;
    }
    return (covered: covered, total: range.$2 - range.$1 + 1);
  }
  final int? episode = t.episode;
  if (episode != null) {
    return (covered: index.byEpisode.containsKey(episode) ? 1 : 0, total: 1);
  }
  return (covered: index.isEmpty ? 0 : 1, total: null);
}

/// 为种子 [t] 挑选随下载暂存的字幕清单（`(集号, 文件)`，集号 null = 未知）。
///
/// 分支（batch 优先，理由同 [jimakuCoverageFor]）：
/// - batch → 区间内每集取首选（语言权重最优）各 1 条，缺集跳过；
/// - 单集 → 该集首选 1 条（记录集号）；无候选返回空；
/// - 无集数 → 有无集号文件（[JimakuEpisodeIndex.unnumbered]）时取其首选，
///   否则全部文件恰好只有 1 条时给它；其余情况不猜，返回空。两种给出场景
///   均记 episode null（种子本身无集数概念，sidecar 落位不按集对位）。
List<(int?, JimakuFile)> chooseSubtitlesFor(
  NyaaTorrent t,
  JimakuEpisodeIndex index,
) {
  final (int, int)? range = t.episodeRange;
  if (range != null) {
    final List<(int?, JimakuFile)> out = <(int?, JimakuFile)>[];
    for (int episode = range.$1; episode <= range.$2; episode++) {
      final List<JimakuFile>? candidates = index.byEpisode[episode];
      if (candidates != null && candidates.isNotEmpty) {
        out.add((episode, candidates.first));
      }
    }
    return out;
  }
  final int? episode = t.episode;
  if (episode != null) {
    final List<JimakuFile>? candidates = index.byEpisode[episode];
    if (candidates == null || candidates.isEmpty) {
      return const <(int?, JimakuFile)>[];
    }
    return <(int?, JimakuFile)>[(episode, candidates.first)];
  }
  if (index.unnumbered.isNotEmpty) {
    return <(int?, JimakuFile)>[(null, index.unnumbered.first)];
  }
  if (index.totalFiles == 1) {
    return <(int?, JimakuFile)>[(null, index.byEpisode.values.first.first)];
  }
  return const <(int?, JimakuFile)>[];
}
