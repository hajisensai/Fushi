/// 字幕候选的两级「版本」聚类（纯函数，参照 RSS-Subtitle-Manager 的
/// 版本选择器）：文件名流水账 → 少数几张可决策的版本卡。
///
/// 第一级 = 来源合集（Jimaku entry / OpenSubtitles 整体）；第二级 = 同一合集内
/// 的「变体」：格式 + 语言 + 发布组标签 + CC/机翻标记。同版本的几十个集数文件
/// 折进一张卡，用户选一次版本，具体某集由 [pickGroupCandidateForEpisode] 解析。
library;

import 'package:fushi/src/media/video/jimaku_client.dart'
    show jimakuLanguageLabel, jimakuLanguageRank;
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';

/// 文件名开头的发布组标签（`[SubsPlease] xxx` → `SubsPlease`）。
/// 8 位 hex（CRC）、分辨率、纯语言 token 不算组名；认不出返回 null。
String? subtitleReleaseGroupTag(String fileName) {
  final RegExpMatch? match =
      RegExp(r'^\s*[\[【]([^\]】]{2,30})[\]】]').firstMatch(fileName);
  if (match == null) return null;
  final String tag = match.group(1)!.trim();
  if (tag.isEmpty) return null;
  if (RegExp(r'^[0-9a-fA-F]{8}$').hasMatch(tag)) return null;
  if (RegExp(r'^\d{3,4}[pP]$').hasMatch(tag)) return null;
  const Set<String> languageTokens = <String>{
    'ja', 'jp', 'jpn', 'zh', 'chs', 'cht', 'sc', 'tc', 'en', 'eng', 'ko',
    'kor', // 语言标签是变体维度，不是组名
  };
  if (languageTokens.contains(tag.toLowerCase())) return null;
  return tag;
}

/// 小写扩展名（不含点）；认不出为空串。
String subtitleFormatOf(String fileName) {
  final int dot = fileName.lastIndexOf('.');
  return dot < 0 ? '' : fileName.substring(dot + 1).toLowerCase();
}

/// 一张「版本卡」：同一来源合集下、同格式同语言同发布组的候选集合。
class SubtitleVersionGroup {
  SubtitleVersionGroup._({
    required this.key,
    required this.collectionLabel,
    required this.members,
  });

  final String key;

  /// 第一级标签：Jimaku entry 名 / 无合集概念的来源用 providerId。
  final String collectionLabel;

  /// 集号升序（无集号殿后），同集按文件名。
  final List<VideoSubtitleCandidate> members;

  VideoSubtitleCandidate get representative => latest;

  String get providerId => members.first.providerId;
  String get language => members.first.language;

  /// 字幕**容器**扩展名（ass / srt / …）。刻意不叫 `format`：那个词在本仓库已经属于
  /// `BookFormat`（epub / pdf / manga），有一整套纪律守卫钉着「不得裸字符串比较
  /// `.format`」。两个毫不相干的概念共用一个词，只会让那条守卫在这里误报、又诱使
  /// 后来人去削弱它。
  String get container => subtitleFormatOf(members.first.fileName);
  String? get releaseGroupTag =>
      subtitleReleaseGroupTag(members.first.fileName);
  bool get hearingImpaired => members.first.hearingImpaired;
  bool get aiTranslated => members.first.aiTranslated;
  bool get fromTrusted => members.any(
        (VideoSubtitleCandidate candidate) => candidate.fromTrusted,
      );

  /// 第二级标签的组成部分（UI 逐段拼、缺段跳过）：容器名大写、语言母语名、组名。
  List<String> get variantParts => <String>[
        if (container.isNotEmpty) container.toUpperCase(),
        if (language.isNotEmpty) jimakuLanguageLabel(language),
        if (releaseGroupTag != null) releaseGroupTag!,
      ];

  Set<int> get episodes => <int>{
        for (final VideoSubtitleCandidate candidate in members)
          if (candidate.episode != null) candidate.episode!,
      };

  int get unnumberedCount => members
      .where((VideoSubtitleCandidate candidate) => candidate.episode == null)
      .length;

  int? get latestUploadedAtMs {
    int? latest;
    for (final VideoSubtitleCandidate candidate in members) {
      final int? at = candidate.uploadedAtMs;
      if (at != null && (latest == null || at > latest)) latest = at;
    }
    return latest;
  }

  /// 「最新」文件：上传时间最大者；全部无时间时取集号最大者（近似最新一集）。
  VideoSubtitleCandidate get latest {
    VideoSubtitleCandidate best = members.first;
    for (final VideoSubtitleCandidate candidate in members.skip(1)) {
      final int? bestAt = best.uploadedAtMs;
      final int? at = candidate.uploadedAtMs;
      if (at != null && (bestAt == null || at > bestAt)) {
        best = candidate;
        continue;
      }
      if (at == null && bestAt == null) {
        final int bestEp = best.episode ?? -1;
        final int ep = candidate.episode ?? -1;
        if (ep > bestEp) best = candidate;
      }
    }
    return best;
  }

  int get totalDownloadCount => members.fold(
        0,
        (int sum, VideoSubtitleCandidate candidate) =>
            sum + candidate.downloadCount,
      );
}

String _groupKeyOf(VideoSubtitleCandidate candidate) => <String>[
      candidate.providerId,
      candidate.collectionId ?? '',
      subtitleFormatOf(candidate.fileName),
      candidate.language,
      subtitleReleaseGroupTag(candidate.fileName) ?? '',
      candidate.hearingImpaired ? 'hi' : '',
      candidate.aiTranslated ? 'ai' : '',
    ].join('\u001f');

int _compareMembers(VideoSubtitleCandidate a, VideoSubtitleCandidate b) {
  final int byEpisode = (a.episode ?? 1 << 30).compareTo(b.episode ?? 1 << 30);
  return byEpisode != 0 ? byEpisode : a.fileName.compareTo(b.fileName);
}

/// 聚类 + 排序。组间排序：语言权重（[preferredLanguage] 最前）→ 机翻殿后 →
/// 最新上传时间降序（无时间殿后）→ 累计下载量 → key（稳定）。
List<SubtitleVersionGroup> buildSubtitleVersionGroups(
  Iterable<VideoSubtitleCandidate> candidates, {
  String? preferredLanguage,
}) {
  final Map<String, List<VideoSubtitleCandidate>> byKey =
      <String, List<VideoSubtitleCandidate>>{};
  for (final VideoSubtitleCandidate candidate in candidates) {
    byKey
        .putIfAbsent(_groupKeyOf(candidate), () => <VideoSubtitleCandidate>[])
        .add(candidate);
  }
  final List<SubtitleVersionGroup> groups = <SubtitleVersionGroup>[
    for (final MapEntry<String, List<VideoSubtitleCandidate>> entry
        in byKey.entries)
      SubtitleVersionGroup._(
        key: entry.key,
        collectionLabel:
            entry.value.first.collectionLabel ?? entry.value.first.providerId,
        members: List<VideoSubtitleCandidate>.unmodifiable(
          entry.value..sort(_compareMembers),
        ),
      ),
  ];
  groups.sort((SubtitleVersionGroup a, SubtitleVersionGroup b) {
    final int byLanguage = jimakuLanguageRank(
      a.language.isEmpty ? null : a.language,
      preferred: preferredLanguage,
    ).compareTo(jimakuLanguageRank(
      b.language.isEmpty ? null : b.language,
      preferred: preferredLanguage,
    ));
    if (byLanguage != 0) return byLanguage;
    if (a.aiTranslated != b.aiTranslated) return a.aiTranslated ? 1 : -1;
    final int aAt = a.latestUploadedAtMs ?? -1;
    final int bAt = b.latestUploadedAtMs ?? -1;
    if (aAt != bAt) return bAt.compareTo(aAt);
    final int byDownloads =
        b.totalDownloadCount.compareTo(a.totalDownloadCount);
    return byDownloads != 0 ? byDownloads : a.key.compareTo(b.key);
  });
  return List<SubtitleVersionGroup>.unmodifiable(groups);
}

/// 从版本卡解析「用户要的那一集」：
/// - [episode] 非空：精确集号命中 → 该文件；无命中但组里恰有 1 个无集号文件
///   （剧场版/整季包常态）→ 那一个；否则 null（UI 展开让用户手选）。
/// - [episode] 为空：组里只有 1 个文件 → 它；否则 null。
VideoSubtitleCandidate? pickGroupCandidateForEpisode(
  SubtitleVersionGroup group,
  int? episode,
) {
  if (episode != null) {
    for (final VideoSubtitleCandidate candidate in group.members) {
      if (candidate.episode == episode) return candidate;
    }
    final List<VideoSubtitleCandidate> unnumbered = group.members
        .where((VideoSubtitleCandidate candidate) => candidate.episode == null)
        .toList(growable: false);
    return unnumbered.length == 1 ? unnumbered.single : null;
  }
  return group.members.length == 1 ? group.members.single : null;
}
