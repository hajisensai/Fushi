import 'package:flutter/material.dart';

import 'package:fushi/src/media/torrent/video_resource_provider.dart';
import 'package:fushi/src/media/video/download/video_resource_version_groups.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart'
    show ActivityRelativeTime, ActivityRelativeUnit, activityRelativeTime;
import 'package:fushi/utils.dart';

/// 下载模式的资源「版本卡」列表：一张卡 = 一个「发布组 › 清晰度」版本，
/// 组内逐集发布折在卡内展开。点卡：恰 1 条发布 → 直接选中；否则展开。
/// 点发布行 → 选中（选中态与外层提交按钮共用既有 `_selected` 模型）。
class VideoResourceVersionGroupList extends StatefulWidget {
  const VideoResourceVersionGroupList({
    required this.groups,
    required this.selectedIdentityKey,
    required this.onSelect,
    this.compact = false,
    super.key,
  });

  final List<VideoResourceVersionGroup> groups;

  /// 当前选中发布的 identityKey（外层 `_selected`）；null = 未选。
  final String? selectedIdentityKey;

  final void Function(VideoResourceCandidate candidate)? onSelect;

  /// 对话框态用紧凑密度（与旧平铺列表同参数语义）。
  final bool compact;

  @override
  State<VideoResourceVersionGroupList> createState() =>
      _VideoResourceVersionGroupListState();
}

class _VideoResourceVersionGroupListState
    extends State<VideoResourceVersionGroupList> {
  final Set<String> _expanded = <String>{};

  void _toggleExpanded(String key) {
    setState(() {
      if (!_expanded.add(key)) _expanded.remove(key);
    });
  }

  void _onCardTap(VideoResourceVersionGroup group) {
    final VideoResourceCandidate? picked = pickResourceVersionCandidate(group);
    if (picked != null && widget.onSelect != null) {
      widget.onSelect!(picked);
      return;
    }
    _toggleExpanded(group.key);
  }

  String _relativeLabel(DateTime at) {
    final ActivityRelativeTime rel = activityRelativeTime(
      at.millisecondsSinceEpoch,
      DateTime.now(),
    );
    return switch (rel.unit) {
      ActivityRelativeUnit.justNow => t.activity_just_now,
      ActivityRelativeUnit.minutesAgo => t.activity_minutes_ago(n: rel.value),
      ActivityRelativeUnit.hoursAgo => t.activity_hours_ago(n: rel.value),
      ActivityRelativeUnit.daysAgo => t.activity_days_ago(n: rel.value),
    };
  }

  String _metaLine(VideoResourceVersionGroup group) {
    final Set<int> episodes = group.episodes;
    final List<String> parts = <String>[];
    if (episodes.isNotEmpty) {
      final int first = episodes.reduce((int a, int b) => a < b ? a : b);
      final int last = episodes.reduce((int a, int b) => a > b ? a : b);
      final String range =
          episodes.length == 1 ? 'EP$first' : 'EP$first–EP$last';
      parts.add(
        '${t.resource_version_episode_count(n: episodes.length)} ($range)',
      );
    }
    final DateTime? latest = group.latestPublishedAt;
    if (latest != null) parts.add(_relativeLabel(latest));
    final int? size = group.representative.sizeBytes;
    if (size != null) parts.add(FushiByteFormat.bytes(size));
    parts.add('${group.bestSeeders}↑');
    return parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ListView.separated(
      key: const ValueKey<String>('video-resource-version-groups'),
      itemCount: widget.groups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) =>
          _buildCard(theme, widget.groups[index]),
    );
  }

  Widget _buildCard(ThemeData theme, VideoResourceVersionGroup group) {
    final bool expanded = _expanded.contains(group.key);
    final bool containsSelection = widget.selectedIdentityKey != null &&
        group.members.any((VideoResourceCandidate member) =>
            member.identityKey == widget.selectedIdentityKey);
    return FushiCard(
      key: ValueKey<String>('resource-version-${group.key}'),
      padding: const EdgeInsets.all(12),
      selected: containsSelection,
      onTap: widget.onSelect == null ? null : () => _onCardTap(group),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(
                group.trusted
                    ? Icons.verified_rounded
                    : Icons.cloud_download_outlined,
                size: 20,
                color: group.trusted
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      group.labelParts.join(' · '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      group.representative.title,
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
              if (group.batchCount > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: FushiTagChip(
                    label: t.resource_version_batch,
                    tone: FushiTagChipTone.surface,
                  ),
                ),
              FushiIconButton(
                icon: expanded ? Icons.expand_less : Icons.expand_more,
                tooltip: t.resource_version_show_files,
                onTap: () => _toggleExpanded(group.key),
              ),
            ],
          ),
          if (expanded) ...<Widget>[
            const SizedBox(height: 4),
            for (final VideoResourceCandidate member in group.members)
              _buildMemberRow(theme, member),
          ],
        ],
      ),
    );
  }

  Widget _buildMemberRow(ThemeData theme, VideoResourceCandidate member) {
    final int? episode = episodeNumberFromReleaseTitle(member.title);
    final List<String> meta = <String>[
      if (episode != null) 'EP$episode',
      if (member.sizeBytes != null) FushiByteFormat.bytes(member.sizeBytes),
      '${member.seeders}↑ ${member.leechers}↓',
      if (member.publishedAt != null) _relativeLabel(member.publishedAt!),
    ];
    return FushiListItem(
      key: ValueKey<String>('resource-release-${member.identityKey}'),
      density:
          widget.compact ? FushiListDensity.compact : FushiListDensity.standard,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      selected: widget.selectedIdentityKey == member.identityKey,
      onTap: widget.onSelect == null ? null : () => widget.onSelect!(member),
      title: Text(
        member.title,
        maxLines: 2,
        softWrap: true,
        overflow: TextOverflow.fade,
      ),
      titleMaxLines: 2,
      subtitle: Text(meta.join(' · ')),
    );
  }
}
