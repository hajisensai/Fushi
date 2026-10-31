import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/download/video_resource_version_groups.dart';
import 'package:fushi/src/pages/implementations/activity_feed.dart'
    show ActivityRelativeTime, ActivityRelativeUnit, activityRelativeTime;
import 'package:fushi/src/media/video/episode_span_format.dart';
import 'package:fushi/utils.dart';

/// 下载模式的资源「版本卡」列表：一张卡 = 一个「发布组 › 清晰度」版本，
/// 组内逐集发布折在卡内展开。点卡：恰 1 条发布 → 直接选中；否则展开。
/// 点发布行 → 选中（选中态与外层提交按钮共用既有 `_selected` 模型）。
class VideoResourceVersionGroupList extends StatefulWidget {
  const VideoResourceVersionGroupList({
    required this.groups,
    required this.selectedIdentityKeys,
    required this.onSelect,
    this.onSetGroupSelected,
    this.multiSelect = false,
    this.compact = false,
    this.sliver = false,
    super.key,
  });

  final List<VideoResourceVersionGroup> groups;

  /// 当前选中发布的 identityKey 集合（外层选中集）；空集 = 未选。
  final Set<String> selectedIdentityKeys;

  /// 是否允许多选（下载模式）。订阅是「一条规则跟一个 release 模板」，多选在那里
  /// 没有意义，所以订阅模式传 false：不摆勾选框、点卡仍是「挑一条」。
  final bool multiSelect;

  final void Function(VideoResourceCandidate candidate)? onSelect;

  /// 多选模式下「整组（合辑）一次选中 / 取消」：成员全部设成 `selected`。
  /// null 或非多选时不摆「全选本组」行。
  final void Function(List<VideoResourceCandidate> members, bool selected)?
  onSetGroupSelected;

  /// 对话框态用紧凑密度（与旧平铺列表同参数语义）。
  final bool compact;

  /// true = 产出 sliver（嵌进外层 [CustomScrollView]，与查询头部同滚）；
  /// false = 自带滚动的 [ListView]。
  final bool sliver;

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
    // 点卡仍走「这组里唯一合理的那条」：对单成员组它就是那一条，对能唯一确定的
    // 组（整季包 / 集号精确命中）也是用户要的默认，挑不出来才展开手选。多选并不
    // 改变这条快捷路径——多选模式下 onSelect 本身是 toggle，点第二下即取消；
    // 想挑分集照旧展开后逐行勾。
    final VideoResourceCandidate? picked = pickResourceVersionCandidate(group);
    if (picked != null && widget.onSelect != null) {
      widget.onSelect!(picked);
      return;
    }
    _toggleExpanded(group.key);
  }

  /// 本组里已被选中的成员数——多选时卡片上直接写出来，免得折起来后看不见。
  int _selectedCountIn(VideoResourceVersionGroup group) => group.members
      .where(
        (VideoResourceCandidate member) =>
            widget.selectedIdentityKeys.contains(member.identityKey),
      )
      .length;

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
      parts.add(
        '${t.resource_version_episode_count(n: episodes.length)} '
        '(${formatEpisodeSpans(episodes)})',
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
    Widget item(BuildContext context, int index) =>
        _buildCard(theme, widget.groups[index]);
    Widget separator(BuildContext _, int __) => const SizedBox(height: 8);
    const Key key = ValueKey<String>('video-resource-version-groups');
    if (widget.sliver) {
      return SliverList.separated(
        key: key,
        itemCount: widget.groups.length,
        separatorBuilder: separator,
        itemBuilder: item,
      );
    }
    return ListView.separated(
      key: key,
      itemCount: widget.groups.length,
      separatorBuilder: separator,
      itemBuilder: item,
    );
  }

  Widget _buildCard(ThemeData theme, VideoResourceVersionGroup group) {
    final bool expanded = _expanded.contains(group.key);
    final int selectedInGroup = _selectedCountIn(group);
    final bool containsSelection = selectedInGroup > 0;
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
              FushiIcon(
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
            if (widget.multiSelect &&
                widget.onSetGroupSelected != null &&
                group.members.length > 1)
              _buildSelectAllRow(group),
            for (final VideoResourceCandidate member in group.members)
              _buildMemberRow(theme, member),
          ],
        ],
      ),
    );
  }

  /// 「全选本组」：合辑可以整包选中，不必展开后逐条点；
  /// 部分选中时显示半选，点一下补满，再点清空。
  Widget _buildSelectAllRow(VideoResourceVersionGroup group) {
    final int selected = _selectedCountIn(group);
    final bool all = selected == group.members.length;
    return FushiListItem(
      key: ValueKey<String>('resource-select-all-${group.key}'),
      density: widget.compact
          ? FushiListDensity.compact
          : FushiListDensity.standard,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      selected: all,
      leading: FushiCheckbox(
        value: all ? true : (selected == 0 ? false : null),
        tristate: true,
        onChanged: (_) => widget.onSetGroupSelected!(group.members, !all),
      ),
      onTap: () => widget.onSetGroupSelected!(group.members, !all),
      title: Text(t.resource_version_select_all(n: group.members.length)),
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
      density: widget.compact
          ? FushiListDensity.compact
          : FushiListDensity.standard,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      selected: widget.selectedIdentityKeys.contains(member.identityKey),
      leading: widget.multiSelect && widget.onSelect != null
          ? FushiCheckbox(
              value: widget.selectedIdentityKeys.contains(member.identityKey),
              onChanged: (_) => widget.onSelect!(member),
            )
          : null,
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
