/// 三域在线作品页（小说 / 漫画 / 视频）共用的版式件。
///
/// 2026-09-27「浏览」阶段 2：用户口径「统一小说漫画视频的操作逻辑和 ui，设计以目前
/// 视频的操作逻辑为主」。各域只填内容与动作，不再各写一份版式。
///
/// 2026-10 M3E 重做：视觉全部委托作品详情共享骨架
/// （`media/detail/media_detail_kit.dart`，与视频系列 / 媒体服务器详情同一套）：
/// - 头部 = [MediaDetailHero]：封面模糊大背景 + 色晕 scrim、2:3 封面卡、Display 级
///   标题、作者 / 来源 / 状态 chip 行、主操作按钮组（filled 大号 + tonal + 「⋯」）、
///   类型标签与可展开简介；
/// - 条目区 = [MediaDetailSectionHeader] + [MediaDetailItemRow] 分段列表（已读 /
///   续看高亮 / 下载状态 / 多选）。
///
/// 旧 API（`lines` / `actions` / `OnlineWorkItemTile(title, subtitle, trailing)`）
/// 保持可用：不传新参数时同样走新骨架。
library;

import 'package:flutter/material.dart';

import 'package:fushi/src/media/detail/media_detail_kit.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

export 'package:fushi/src/media/detail/media_detail_kit.dart';

/// 作品页封面尺寸（旧口径，保留给仍按它定尺的取图组件）。
const Size kOnlineWorkCoverSize = Size(120, 170);

/// 头部可用宽度（逻辑像素，按界面缩放折算）低于它时，主操作区挪到封面下方
/// 居中横排（新骨架里即 [kMediaDetailHeroWideMinWidth] 以下的窄式 hero）。
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

/// 作品页头部：M3E 详情 hero（见 [MediaDetailHero]）。
///
/// 主操作区两种接法：
/// - 新：[primaryAction]（[MediaDetailPrimaryButton]）+ [secondaryActions]
///   （[MediaDetailSecondaryButton]）+ [moreItems]（「⋯」菜单：在网站打开 / 刷新 /
///   换源…），组成 [MediaDetailActionBar]；
/// - 旧：[actions] 原样横排（Wrap）。
class OnlineWorkHeader extends StatelessWidget {
  const OnlineWorkHeader({
    required this.cover,
    required this.title,
    super.key,
    this.lines = const <String>[],
    this.chips = const <MediaDetailChip>[],
    this.genres = const <String>[],
    this.actions = const <Widget>[],
    this.primaryAction,
    this.secondaryActions = const <Widget>[],
    this.moreItems = const <MediaDetailMenuItem>[],
    this.description,
    this.selectableDescription = false,
    this.backdrop,
    this.overline,
    this.extra,
  });

  /// 封面内容（各域自己的取图组件）；外面统一套 2:3 封面卡。
  final Widget cover;
  final String title;

  /// 标题下的元信息（作者、连载状态、来源等），空串自动跳过；每条渲染成一枚
  /// 中性 chip。需要强调色（「连载中」「已在书架」）的用 [chips]。
  final List<String?> lines;

  /// 额外的元信息 chip（排在 [lines] 之后）。
  final List<MediaDetailChip> chips;

  /// 类型标签，最多显示 8 个。
  final List<String> genres;

  /// 旧接法的主操作区（原样横排）。给了 [primaryAction] 时忽略。
  final List<Widget> actions;

  final Widget? primaryAction;
  final List<Widget> secondaryActions;
  final List<MediaDetailMenuItem> moreItems;

  final String? description;

  /// 简介可选中复制（小说简介常被拿去查词）。
  final bool selectableDescription;

  /// 背景图（缺省不画图，只有色晕）；通常传封面的 ImageProvider。
  final ImageProvider? backdrop;

  /// 标题上方的小字（来源名）。
  final String? overline;

  /// 简介之后的附加内容（Cloudflare 验证、错误提示条等）。
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final String? summary = description?.trim();
    final List<MediaDetailChip> allChips = <MediaDetailChip>[
      for (final String? line in lines)
        if (line != null && line.trim().isNotEmpty)
          MediaDetailChip(line.trim()),
      ...chips,
    ];
    final Widget? primary = primaryAction;
    final Widget? actionBar = primary != null
        ? MediaDetailActionBar(
            key: const ValueKey<String>('online_work_actions'),
            primary: primary,
            secondary: secondaryActions,
            more: moreItems.isEmpty
                ? null
                : MediaDetailMoreButton(
                    buttonKey: const ValueKey<String>('online_work_more'),
                    items: moreItems,
                  ),
          )
        : actions.isEmpty
        ? null
        : MediaDetailActionBar(
            key: const ValueKey<String>('online_work_actions'),
            primary: actions.first,
            secondary: actions.sublist(1),
          );
    final List<String> tags = genres.take(8).toList(growable: false);
    final Widget? extra = this.extra;
    final bool hasFooter =
        tags.isNotEmpty ||
        (summary != null && summary.isNotEmpty) ||
        extra != null;
    return MediaDetailHero(
      title: title,
      cover: cover,
      backdrop: backdrop,
      overline: overline,
      chips: allChips,
      actions: actionBar,
      footer: hasFooter
          ? _OnlineWorkFooter(
              tags: tags,
              summary: summary,
              selectable: selectableDescription,
              extra: extra,
            )
          : null,
    );
  }
}

/// hero 页脚：类型标签 + 可展开简介 + 附加内容。宽度占满 hero 信息列（窄式 hero
/// 居中排版时简介仍左对齐，长文居中难读）。
class _OnlineWorkFooter extends StatelessWidget {
  const _OnlineWorkFooter({
    required this.tags,
    required this.summary,
    required this.selectable,
    required this.extra,
  });

  final List<String> tags;
  final String? summary;
  final bool selectable;
  final Widget? extra;

  @override
  Widget build(BuildContext context) {
    final String? summary = this.summary;
    final Widget? extra = this.extra;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 760),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (tags.isNotEmpty)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final String genre in tags) FushiTagChip(label: genre),
              ],
            ),
          if (summary != null && summary.isNotEmpty) ...<Widget>[
            if (tags.isNotEmpty) const SizedBox(height: 16),
            MediaDetailSynopsis(
              key: const ValueKey<String>('online_work_description'),
              text: summary,
              selectable: selectable,
            ),
          ],
          if (extra != null) ...<Widget>[const SizedBox(height: 12), extra],
        ],
      ),
    );
  }
}

/// 条目区小标题（「剧集」「章节（N）」）：[MediaDetailSectionHeader]。
class OnlineWorkSectionTitle extends StatelessWidget {
  const OnlineWorkSectionTitle(
    this.text, {
    super.key,
    this.count,
    this.trailing,
    this.padding,
  });

  final String text;
  final int? count;
  final Widget? trailing;

  /// null = 页边距由外层给（左右 0，上 24 下 8）。
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) => MediaDetailSectionHeader(
    text,
    count: count,
    trailing: trailing,
    padding: padding ?? const EdgeInsets.fromLTRB(0, 24, 0, 8),
  );
}

/// 条目区的一行（分段列表行，见 [MediaDetailItemRow]）：点行 = 在线打开这一条，
/// [trailing] 放这一条的次要动作（下载等）。
///
/// 不给 [index] / [count] 时当作单独一行（四角大圆角）。
class OnlineWorkItemTile extends StatelessWidget {
  const OnlineWorkItemTile({
    required this.title,
    super.key,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.current = false,
    this.completed = false,
    this.index = 0,
    this.count = 1,
    this.number,
    this.leading,
    this.meta = const <String>[],
    this.progress,
    this.downloadState = MediaDetailDownloadState.none,
    this.downloadProgress,
    this.selected,
    this.focusId,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 上次看到 / 读到的那一条：整行 primaryContainer 高亮。
  final bool current;

  /// 已读 / 已看完：tertiary 对勾 + 标题降调。
  final bool completed;
  final int index;
  final int count;
  final String? number;
  final Widget? leading;
  final List<String> meta;
  final double? progress;
  final MediaDetailDownloadState downloadState;
  final double? downloadProgress;

  /// 非 null = 多选模式。
  final bool? selected;
  final FushiFocusId? focusId;

  @override
  Widget build(BuildContext context) {
    return MediaDetailItemRow(
      index: index,
      count: count,
      title: title,
      subtitle: subtitle,
      number: number,
      leading: leading,
      meta: meta,
      progress: progress,
      completed: completed,
      current: current,
      downloadState: downloadState,
      downloadProgress: downloadProgress,
      trailing: trailing,
      selected: selected,
      onTap: onTap,
      onLongPress: onLongPress,
      focusId: focusId,
    );
  }
}

/// 加载中 / 空列表的占位（条目区）：加载 = 分段行骨架；空 = M3E 占位。
class OnlineWorkItemsPlaceholder extends StatelessWidget {
  const OnlineWorkItemsPlaceholder({
    required this.loading,
    required this.emptyText,
    super.key,
    this.rows = 6,
  });

  final bool loading;
  final String emptyText;
  final int rows;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return FushiSkeletonShimmer(
        child: Column(
          key: const ValueKey<String>('online_work_items_loading'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < rows; i++)
              Padding(
                padding: EdgeInsets.only(bottom: i == rows - 1 ? 0 : 2),
                child: FushiSkeleton(
                  height: 64,
                  borderRadius: fushiGroupedItemRadius(context, i, rows),
                ),
              ),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: FushiPlaceholderMessage(
        icon: FushiIcons.searchOff,
        message: emptyText,
      ),
    );
  }
}
