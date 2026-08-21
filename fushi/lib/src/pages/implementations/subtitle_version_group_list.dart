import 'package:flutter/material.dart';

import 'package:fushi/src/media/video/jimaku_client.dart'
    show jimakuLanguageLabel;
import 'package:fushi/src/media/video/subtitle/subtitle_content_language.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_version_groups.dart';
import 'package:fushi/src/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart'
    show ActivityRelativeTime, ActivityRelativeUnit, activityRelativeTime;
import 'package:fushi/utils.dart';

/// 字幕「版本卡」列表（参照 RSS-Subtitle-Manager 的版本选择器）：一张卡 =
/// 一个来源合集下的一个变体（格式+语言+发布组），几十个集数文件折进卡内。
///
/// 交互：点卡片 → 有明确目标集时直接下载该集文件（[requestedEpisode] +
/// [pickGroupCandidateForEpisode]），解析不出唯一文件则展开卡片让用户手选；
/// 右侧 chevron 恒可手动展开。每行/每卡的下载动作都回 [onPickCandidate]。
class SubtitleVersionGroupList extends StatefulWidget {
  const SubtitleVersionGroupList({
    required this.groups,
    required this.requestedEpisode,
    required this.busyIdentityKey,
    required this.onPickCandidate,
    this.probedLanguages = const <String, SubtitleContentLanguage>{},
    super.key,
  });

  final List<SubtitleVersionGroup> groups;

  /// 用户在集数框里要的那一集；null = 没指定。
  final int? requestedEpisode;

  /// 正在下载的候选 identityKey；null = 空闲。非空时所有动作禁用。
  final String? busyIdentityKey;

  /// 用户最终选定某个文件（下载动作由宿主执行）。null = 全部禁用。
  final void Function(VideoSubtitleCandidate candidate)? onPickCandidate;

  /// 正文语言探测结果（group.key → 检测值）：文件名认不出语言的组，宿主可
  /// 后台探测正文后回填，本组件只展示（`正文：简体中文`），不参与分组。
  final Map<String, SubtitleContentLanguage> probedLanguages;

  @override
  State<SubtitleVersionGroupList> createState() =>
      _SubtitleVersionGroupListState();
}

class _SubtitleVersionGroupListState extends State<SubtitleVersionGroupList> {
  final Set<String> _expanded = <String>{};

  bool get _busy => widget.busyIdentityKey != null;

  void _onCardTap(SubtitleVersionGroup group) {
    if (_busy || widget.onPickCandidate == null) return;
    final VideoSubtitleCandidate? picked =
        pickGroupCandidateForEpisode(group, widget.requestedEpisode);
    if (picked != null) {
      widget.onPickCandidate!(picked);
      return;
    }
    setState(() {
      if (!_expanded.add(group.key)) _expanded.remove(group.key);
    });
  }

  String _relativeLabel(int epochMs) {
    final ActivityRelativeTime rel =
        activityRelativeTime(epochMs, DateTime.now());
    return switch (rel.unit) {
      ActivityRelativeUnit.justNow => t.activity_just_now,
      ActivityRelativeUnit.minutesAgo => t.activity_minutes_ago(n: rel.value),
      ActivityRelativeUnit.hoursAgo => t.activity_hours_ago(n: rel.value),
      ActivityRelativeUnit.daysAgo => t.activity_days_ago(n: rel.value),
    };
  }

  /// 卡片第三行：覆盖集数 · 相对时间 · 大小 · 下载量。缺段跳过。
  String _metaLine(SubtitleVersionGroup group) {
    final Set<int> episodes = group.episodes;
    final List<String> parts = <String>[];
    if (episodes.isNotEmpty) {
      final int first = episodes.reduce((int a, int b) => a < b ? a : b);
      final int last = episodes.reduce((int a, int b) => a > b ? a : b);
      final String range =
          episodes.length == 1 ? 'EP$first' : 'EP$first–EP$last';
      parts.add(
        '${t.subtitle_version_episode_count(n: episodes.length)} ($range)',
      );
    }
    if (group.unnumberedCount > 0) {
      parts.add(
        t.subtitle_version_unnumbered_count(n: group.unnumberedCount),
      );
    }
    final int? latestAt = group.latestUploadedAtMs;
    if (latestAt != null) parts.add(_relativeLabel(latestAt));
    final int? size = group.latest.fileSize;
    if (size != null) parts.add(FushiByteFormat.bytes(size));
    if (group.totalDownloadCount > 0) {
      parts.add('${group.totalDownloadCount}↓');
    }
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView.separated(
      itemCount: widget.groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        final SubtitleVersionGroup group = widget.groups[index];
        return _buildCard(theme, group);
      },
    );
  }

  Widget _buildCard(ThemeData theme, SubtitleVersionGroup group) {
    final bool expanded = _expanded.contains(group.key);
    final SubtitleContentLanguage? probed = widget.probedLanguages[group.key];
    final String? probedLabel =
        probed == null ? null : subtitleContentLanguageNativeLabel(probed);
    final String variant = group.variantParts.join(' · ');
    return FushiCard(
      key: ValueKey<String>('subtitle-version-${group.key}'),
      padding: const EdgeInsets.all(12),
      onTap: () => _onCardTap(group),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      variant.isEmpty
                          ? group.collectionLabel
                          : '${group.collectionLabel} › $variant',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      group.latest.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _metaLine(group),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (widget.busyIdentityKey != null &&
                  group.members.any((VideoSubtitleCandidate candidate) =>
                      candidate.identityKey == widget.busyIdentityKey))
                const Padding(
                  padding: EdgeInsets.all(8),
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                FushiIconButton(
                  icon: expanded ? Icons.expand_less : Icons.expand_more,
                  tooltip: t.subtitle_version_show_files,
                  onTap: _busy
                      ? null
                      : () => setState(() {
                            if (!_expanded.add(group.key)) {
                              _expanded.remove(group.key);
                            }
                          }),
                ),
            ],
          ),
          if (group.aiTranslated ||
              group.hearingImpaired ||
              probedLabel != null) ...<Widget>[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: <Widget>[
                if (probedLabel != null)
                  FushiTagChip(
                    label:
                        '${t.subtitle_version_content_language}: $probedLabel',
                    tone: FushiTagChipTone.surface,
                  ),
                if (group.aiTranslated)
                  FushiTagChip(
                    label: t.subtitle_version_ai_translated,
                    color: theme.colorScheme.tertiary,
                    tone: FushiTagChipTone.surface,
                  ),
                if (group.hearingImpaired)
                  const FushiTagChip(
                    label: 'CC',
                    tone: FushiTagChipTone.surface,
                  ),
              ],
            ),
          ],
          if (expanded) ...<Widget>[
            const SizedBox(height: 4),
            for (final VideoSubtitleCandidate candidate in group.members)
              _buildFileRow(theme, group, candidate),
          ],
        ],
      ),
    );
  }

  Widget _buildFileRow(
    ThemeData theme,
    SubtitleVersionGroup group,
    VideoSubtitleCandidate candidate,
  ) {
    final bool busyThis = widget.busyIdentityKey == candidate.identityKey;
    final bool highlight = widget.requestedEpisode != null &&
        candidate.episode == widget.requestedEpisode;
    final List<String> meta = <String>[
      if (candidate.episode != null) 'EP${candidate.episode}',
      if (candidate.language.isNotEmpty)
        jimakuLanguageLabel(candidate.language),
      if (candidate.fileSize != null) FushiByteFormat.bytes(candidate.fileSize),
      if (candidate.uploadedAtMs != null)
        _relativeLabel(candidate.uploadedAtMs!),
    ];
    return FushiListItem(
      key: ValueKey<String>('subtitle-file-${candidate.identityKey}'),
      density: FushiListDensity.compact,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      selected: highlight,
      onTap: _busy || widget.onPickCandidate == null
          ? null
          : () => widget.onPickCandidate!(candidate),
      title: Text(
        candidate.fileName,
        maxLines: 2,
        softWrap: true,
        overflow: TextOverflow.fade,
      ),
      titleMaxLines: 2,
      subtitle: meta.isEmpty ? null : Text(meta.join(' · ')),
      trailing: busyThis
          ? const SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download, size: 18),
    );
  }
}
