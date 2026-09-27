/// 三域在线作品页（小说 / 漫画 / 视频）共用的版式件。
///
/// 2026-09-27「浏览」阶段 2：用户口径「统一小说漫画视频的操作逻辑和 ui，设计以目前
/// 视频的操作逻辑为主」。以视频源作品页（`AnimeSourceDetailPage`）为准：
/// - 头部：120×170 封面 + 标题 / 元信息行 / 类型标签 + 主操作区（默认在线打开，
///   另有「加入书架 / 媒体库」「下载」）；
/// - 简介在头部下方整宽；
/// - 条目区：小标题 + 一行一条（点行 = 在线打开，行尾是该条的次要动作）。
///
/// 各域只填内容与动作，不再各写一份版式——此前三页封面尺寸（120×170 / 150×220）、
/// 类型展示（纯文本 / 标签）、主操作的位置都各不相同。
library;

import 'package:flutter/material.dart';

import 'package:fushi/utils.dart';

/// 作品页封面尺寸（视频源作品页的原尺寸）。
const Size kOnlineWorkCoverSize = Size(120, 170);

/// 头部可用宽度（逻辑像素，按界面缩放折算）低于它时，主操作区挪到封面行下方
/// 占满整宽横排（见 [OnlineWorkHeader]）。
const double kOnlineWorkActionsBelowWidth = 560;

/// 把源给的「类型」字段拆成标签：扩展 / 插件多半给逗号分隔的一串。
List<String> splitOnlineWorkGenres(String? raw) {
  if (raw == null) return const <String>[];
  return raw
      .split(RegExp(r'[,，、]'))
      .map((String value) => value.trim())
      .where((String value) => value.isNotEmpty)
      .toList(growable: false);
}

/// 作品页头部：封面 + 标题 + 元信息 + 类型标签 + 主操作区，简介在下方整宽。
class OnlineWorkHeader extends StatelessWidget {
  const OnlineWorkHeader({
    required this.cover,
    required this.title,
    super.key,
    this.lines = const <String>[],
    this.genres = const <String>[],
    this.actions = const <Widget>[],
    this.description,
    this.selectableDescription = false,
  });

  /// 封面内容（各域自己的取图组件）；外面统一套卡片与尺寸。
  final Widget cover;
  final String title;

  /// 标题下的元信息行（作者、连载状态、来源等），空串自动跳过。
  final List<String?> lines;

  /// 类型标签，最多显示 8 个。
  final List<String> genres;

  /// 主操作区：第一个通常是「在线打开」的 FilledButton，其后是次要动作。
  final List<Widget> actions;

  final String? description;

  /// 简介可选中复制（小说简介常被拿去查词）。
  final bool selectableDescription;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) =>
          _buildForWidth(context, constraints.maxWidth),
    );
  }

  Widget _buildForWidth(BuildContext context, double width) {
    final ThemeData theme = Theme.of(context);
    final String? summary = description?.trim();
    // 窄屏（手机竖屏）封面右边只剩一百多像素：主操作区放在那里，每个按钮都会
    // 独占一行、竖着堆成一长条。窄宽时把操作区挪到封面行下方、占满整宽横排。
    final bool actionsBelow =
        width * FushiAppUiScale.of(context) < kOnlineWorkActionsBelowWidth;
    final Widget? actionBar = actions.isEmpty
        ? null
        : Wrap(
            key: const ValueKey<String>('online_work_actions'),
            spacing: 8,
            runSpacing: 8,
            children: actions,
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            SizedBox.fromSize(
              size: kOnlineWorkCoverSize,
              child: FushiCard(padding: EdgeInsets.zero, child: cover),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(title, style: theme.textTheme.titleLarge),
                  for (final String? line in lines)
                    if (line != null && line.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(line, style: theme.textTheme.bodyMedium),
                      ),
                  if (genres.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: <Widget>[
                        for (final String genre in genres.take(8))
                          FushiTagChip(label: genre),
                      ],
                    ),
                  ],
                  if (actionBar != null && !actionsBelow) ...<Widget>[
                    const SizedBox(height: 12),
                    actionBar,
                  ],
                ],
              ),
            ),
          ],
        ),
        if (actionBar != null && actionsBelow) ...<Widget>[
          const SizedBox(height: 12),
          actionBar,
        ],
        if (summary != null && summary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: selectableDescription
                ? SelectableText(summary, style: theme.textTheme.bodyMedium)
                : Text(summary, style: theme.textTheme.bodyMedium),
          ),
      ],
    );
  }
}

/// 条目区小标题（「剧集」「章节（N）」）。
class OnlineWorkSectionTitle extends StatelessWidget {
  const OnlineWorkSectionTitle(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

/// 条目区的一行：点行 = 在线打开这一条，[trailing] 放这一条的次要动作（下载等）。
class OnlineWorkItemTile extends StatelessWidget {
  const OnlineWorkItemTile({
    required this.title,
    super.key,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.current = false,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// 上次看到 / 读到的那一条：标题加粗提示续看位置。
  final bool current;

  @override
  Widget build(BuildContext context) {
    final String? secondary = subtitle;
    return FushiCard(
      padding: EdgeInsets.zero,
      child: FushiListItem(
        title: Text(
          title,
          style: current ? const TextStyle(fontWeight: FontWeight.w600) : null,
        ),
        subtitle: secondary == null || secondary.isEmpty
            ? null
            : Text(secondary),
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }
}

/// 加载中 / 空列表的占位（条目区）。
class OnlineWorkItemsPlaceholder extends StatelessWidget {
  const OnlineWorkItemsPlaceholder({
    required this.loading,
    required this.emptyText,
    super.key,
  });

  final bool loading;
  final String emptyText;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: adaptiveIndicator(context: context),
        ),
      );
    }
    return Text(emptyText);
  }
}
