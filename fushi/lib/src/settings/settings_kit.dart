import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_destination_id.dart';
import 'package:fushi/src/settings/settings_navigation_groups.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show FushiAppleMetrics;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

import 'package:fushi/src/settings/settings_kit_core.dart';

export 'package:fushi/src/settings/settings_kit_core.dart';

// settings kit 中绑定设置 schema（SettingsDestination / SettingsContext）的部分；
// 与 schema 无关的壳、行、动效积木在 settings_kit_core.dart（底层组件只依赖那里）。

/// 分类的图标色调：同一导航分组同一主色系，组内再错开，首页一眼能分区。
///
/// [SettingsIconTone.red] 只留给破坏性操作行（[SettingsDangerRow]）：M3E 下它映射
/// 到 error 容器，error 角色是固定的红、**不随主题种子色变化**——分类图标用它，
/// 换主题时就只有那一枚还是红的（2026-10-09 用户截图「视频图标不变色」）。
SettingsIconTone settingsIconToneFor(SettingsDestinationId id) => switch (id) {
  SettingsDestinationId.appearance => SettingsIconTone.purple,
  SettingsDestinationId.floatingBall => SettingsIconTone.pink,
  SettingsDestinationId.reading => SettingsIconTone.blue,
  SettingsDestinationId.manga => SettingsIconTone.teal,
  SettingsDestinationId.video => SettingsIconTone.pink,
  SettingsDestinationId.music => SettingsIconTone.purple,
  SettingsDestinationId.game => SettingsIconTone.green,
  SettingsDestinationId.mediaTracking => SettingsIconTone.orange,
  SettingsDestinationId.lookup => SettingsIconTone.orange,
  SettingsDestinationId.cardCreation => SettingsIconTone.green,
  SettingsDestinationId.downloads => SettingsIconTone.teal,
  SettingsDestinationId.services => SettingsIconTone.blue,
  SettingsDestinationId.localServices => SettingsIconTone.teal,
  SettingsDestinationId.ai => SettingsIconTone.purple,
  SettingsDestinationId.models => SettingsIconTone.purple,
  SettingsDestinationId.profiles => SettingsIconTone.pink,
  SettingsDestinationId.syncBackup => SettingsIconTone.blue,
  SettingsDestinationId.interconnect => SettingsIconTone.teal,
  SettingsDestinationId.storage => SettingsIconTone.gray,
  SettingsDestinationId.widgets => SettingsIconTone.blue,
  SettingsDestinationId.system ||
  SettingsDestinationId.readerQuickSettings ||
  SettingsDestinationId.videoQuickSettings ||
  SettingsDestinationId.appIcon ||
  SettingsDestinationId.shortcuts => SettingsIconTone.gray,
};

/// 导航分组的色调（分组标题的小色点、搜索结果分组头用）。
SettingsIconTone settingsIconToneForGroup(SettingsNavigationGroupId id) =>
    switch (id) {
      SettingsNavigationGroupId.interface => SettingsIconTone.purple,
      SettingsNavigationGroupId.content => SettingsIconTone.blue,
      SettingsNavigationGroupId.learning => SettingsIconTone.orange,
      SettingsNavigationGroupId.connections => SettingsIconTone.teal,
      SettingsNavigationGroupId.data => SettingsIconTone.green,
      SettingsNavigationGroupId.app => SettingsIconTone.gray,
    };

// -----------------------------------------------------------------------------
// 高亮文本 / 搜索结果
// -----------------------------------------------------------------------------

/// 按 [query]（空白分词、大小写不敏感）高亮命中片段：M3E 是 primary 前景 +
/// 加粗 + primaryContainer 底，Apple 是强调色 + semibold。
class SettingsHighlightedText extends StatelessWidget {
  const SettingsHighlightedText(
    this.text, {
    required this.query,
    super.key,
    this.style,
    this.maxLines,
  });

  final String text;
  final String query;
  final TextStyle? style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final List<TextRange> ranges = settingsSearchMatchRanges(text, query);
    if (ranges.isEmpty) {
      return Text(text, style: style, maxLines: maxLines);
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool apple = SettingsKitStyle.of(context) == SettingsKitStyle.apple;
    final TextStyle highlight = apple
        ? TextStyle(
            color: appleColorsOf(context).accent,
            fontWeight: FontWeight.w600,
          )
        : TextStyle(
            color: isEinkTheme(context)
                ? scheme.onSurface
                : scheme.onPrimaryContainer,
            backgroundColor: isEinkTheme(context)
                ? null
                : scheme.primaryContainer,
            fontWeight: FontWeight.w700,
            decoration: isEinkTheme(context) ? TextDecoration.underline : null,
          );
    final List<InlineSpan> spans = <InlineSpan>[];
    int cursor = 0;
    for (final TextRange range in ranges) {
      if (range.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, range.start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(range.start, range.end),
          style: highlight,
        ),
      );
      cursor = range.end;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(
      TextSpan(children: spans),
      style: style,
      maxLines: maxLines,
    );
  }
}

/// 搜索结果视图：按顶层分类分组（分组头 = 分类图标块 + 分类名 + 条数），
/// 每条 = 高亮标题 + 「分区 › 子页」面包屑（命中在说明里时再带一行高亮说明），
/// 首屏错峰进场。没有结果时是 [SettingsEmptyState]。
///
/// [onOpen] 由宿主决定怎么跳（宽屏切分类、窄屏 push），视图只负责呈现。
class SettingsSearchResultsView extends StatelessWidget {
  const SettingsSearchResultsView({
    required this.results,
    required this.query,
    required this.onOpen,
    super.key,
    this.padding = EdgeInsets.zero,
    this.shrinkWrap = false,
  });

  final List<SettingsSearchEntry> results;
  final String query;
  final ValueChanged<SettingsSearchEntry> onOpen;
  final EdgeInsetsGeometry padding;

  /// true = 不自带滚动（嵌进外层滚动视图）。
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    if (results.isEmpty) {
      final Widget empty = SettingsEmptyState(
        icon: FushiIcons.searchOff,
        title: t.settings_search_empty_title,
        message: t.settings_search_empty_hint,
      );
      return shrinkWrap
          ? Padding(padding: padding, child: empty)
          : Padding(
              padding: padding,
              child: Center(child: empty),
            );
    }
    final List<(SettingsDestination, List<SettingsSearchEntry>)> groups =
        <(SettingsDestination, List<SettingsSearchEntry>)>[];
    for (final SettingsSearchEntry entry in results) {
      final int index = groups.indexWhere(
        ((SettingsDestination, List<SettingsSearchEntry>) g) =>
            g.$1.id == entry.destination.id,
      );
      if (index < 0) {
        groups.add((entry.destination, <SettingsSearchEntry>[entry]));
      } else {
        groups[index].$2.add(entry);
      }
    }
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ThemeData theme = Theme.of(context);
    final List<Widget> children = <Widget>[
      Padding(
        padding: EdgeInsetsDirectional.only(
          start: tokens.spacing.rowHorizontal,
          bottom: tokens.spacing.gap,
        ),
        child: Text(
          t.settings_search_result_count(n: results.length),
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
      for (final (
            int index,
            (
              SettingsDestination destination,
              List<SettingsSearchEntry> entries,
            ),
          )
          in groups.indexed)
        FushiStaggeredEntrance(
          key: ValueKey<String>('settings-search-group.${destination.id.name}'),
          index: index,
          child: Padding(
            padding: EdgeInsets.only(bottom: tokens.spacing.card),
            child: _ResultGroup(
              destination: destination,
              entries: entries,
              query: query,
              onOpen: onOpen,
            ),
          ),
        ),
    ];
    final Widget column = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
    // replayKey = 查询词：每次改词都重放一次进场，结果「刷新」有反馈。
    if (shrinkWrap) {
      return FushiEntranceScope(
        replayKey: query,
        child: Padding(padding: padding, child: column),
      );
    }
    return FushiEntranceScope(
      replayKey: query,
      child: SingleChildScrollView(padding: padding, child: column),
    );
  }
}

class _ResultGroup extends StatelessWidget {
  const _ResultGroup({
    required this.destination,
    required this.entries,
    required this.query,
    required this.onOpen,
  });

  final SettingsDestination destination;
  final List<SettingsSearchEntry> entries;
  final String query;
  final ValueChanged<SettingsSearchEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final SettingsKitStyle style = SettingsKitStyle.of(context);
    final SettingsIconTone tone = settingsIconToneFor(destination.id);
    final Widget header = Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.rowHorizontal - 4,
        0,
        tokens.spacing.rowHorizontal,
        tokens.spacing.gap,
      ),
      child: Row(
        children: <Widget>[
          SettingsShapeIcon(
            icon: destination.icon,
            tone: tone,
            size: style == SettingsKitStyle.apple ? 22 : 28,
          ),
          SizedBox(width: tokens.spacing.gap + 4),
          Expanded(
            child: Text(
              destination.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style == SettingsKitStyle.apple
                  ? FushiAppleMetrics.of(context).footnoteStyle(context)
                  : theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
            ),
          ),
          SettingsCountBadge(count: entries.length),
        ],
      ),
    );
    final double radius = SettingsKitRadii.card(style);
    final Color surface = style == SettingsKitStyle.apple
        ? appleColorsOf(context).secondaryGroupedBackground
        : tokens.surfaces.card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header,
        FushiCard(
          padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 2),
          borderRadius: BorderRadius.circular(radius),
          color: surface,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (final SettingsSearchEntry entry in entries)
                _ResultRow(entry: entry, query: query, onOpen: onOpen),
            ],
          ),
        ),
      ],
    );
  }
}

class _ResultRow extends StatelessWidget {
  const _ResultRow({
    required this.entry,
    required this.query,
    required this.onOpen,
  });

  final SettingsSearchEntry entry;
  final String query;
  final ValueChanged<SettingsSearchEntry> onOpen;

  @override
  Widget build(BuildContext context) {
    final String breadcrumb = settingsSearchLocation(entry);
    final String? detail = entry.matchedDetail(query);
    return FushiPressScale(
      child: FushiListItem(
        key: ValueKey<String>('settings-search-result.${entry.item.id}'),
        leading: FushiIcon(entry.item.icon ?? entry.destination.icon),
        title: SettingsHighlightedText(entry.title, query: query, maxLines: 2),
        titleMaxLines: 2,
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (detail != null)
              SettingsHighlightedText(detail, query: query, maxLines: 2),
            if (breadcrumb.isNotEmpty)
              Text(breadcrumb, maxLines: 1, overflow: TextOverflow.ellipsis),
          ],
        ),
        subtitleMaxLines: 3,
        trailing: const FushiIcon(FushiIcons.forward),
        onTap: () => onOpen(entry),
      ),
    );
  }
}

/// 设置项「是否改过默认值」与恢复动作的统一判据（schema 渲染层的页级「恢复本页
/// 默认」与自定义行共用）。[currentLabel] / [defaultLabel] 是给恢复确认框看的
/// 当前值 / 默认值简述。
class SettingsResetSpec {
  const SettingsResetSpec({
    required this.modified,
    required this.reset,
    required this.currentLabel,
    required this.defaultLabel,
  });

  final bool modified;
  final Future<void> Function() reset;
  final String currentLabel;
  final String defaultLabel;
}

/// 读 schema item 的 `defaultValue`（自定义行读 [SettingsCustomItem.reset]）判断是否
/// 改过；没声明默认值的项返回 null（不参与页级恢复默认）。
SettingsResetSpec? settingsResetSpecFor(
  SettingsItem item,
  SettingsContext context,
) {
  if (item is SettingsSwitchItem) {
    final bool? defaultValue = item.defaultValue;
    if (defaultValue == null) return null;
    final bool current = item.value(context);
    return SettingsResetSpec(
      modified: current != defaultValue,
      currentLabel: _settingsSwitchLabel(current),
      defaultLabel: _settingsSwitchLabel(defaultValue),
      reset: () async {
        await item.onChanged(context, defaultValue);
        context.refresh();
      },
    );
  }
  if (item is SettingsSliderItem) {
    final double? defaultValue = item.defaultValue;
    if (defaultValue == null) return null;
    final double current = item.value(context);
    String format(double value) =>
        item.label?.call(value) ?? _settingsNumberLabel(value);
    return SettingsResetSpec(
      modified: (current - defaultValue).abs() > 1e-6,
      currentLabel: format(current),
      defaultLabel: format(defaultValue),
      reset: () async {
        await item.onChanged(context, defaultValue);
        await item.onChangeEnd?.call(context, defaultValue);
        context.refresh();
      },
    );
  }
  if (item is SettingsStepperItem) {
    final double? defaultValue = item.defaultValue;
    if (defaultValue == null) return null;
    final double current = item.value(context);
    return SettingsResetSpec(
      modified: (current - defaultValue).abs() > 1e-6,
      currentLabel: item.format(current),
      defaultLabel: item.format(defaultValue),
      reset: () async {
        await item.onChanged(context, defaultValue);
        context.refresh();
      },
    );
  }
  if (item is SettingsSegmentedItem) {
    final SettingsSegmentedItem<Object> segmented = item;
    final Object? defaultValue = segmented.defaultValue;
    if (defaultValue == null) return null;
    final Object current = segmented.selected(context);
    String format(Object value) {
      for (final SettingsSegmentOption<Object> option in segmented.options) {
        if (option.value == value) return option.label;
      }
      return value.toString();
    }

    return SettingsResetSpec(
      modified: current != defaultValue,
      currentLabel: format(current),
      defaultLabel: format(defaultValue),
      reset: () async {
        await segmented.dispatchChange(context, defaultValue);
        context.refresh();
      },
    );
  }
  if (item is SettingsCustomItem) {
    final SettingsCustomReset? custom = item.reset;
    if (custom == null) return null;
    return SettingsResetSpec(
      modified: custom.isModified(context),
      currentLabel: custom.currentLabel(context),
      defaultLabel: custom.defaultLabel(context),
      reset: () async {
        await custom.reset(context);
        context.refresh();
      },
    );
  }
  return null;
}

String _settingsSwitchLabel(bool value) =>
    value ? t.settings_page_reset_value_on : t.settings_page_reset_value_off;

String _settingsNumberLabel(double value) {
  if (value == value.roundToDouble()) return value.toInt().toString();
  return value.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
}

/// 详情页分组跳转条的条目：只收带标题的分组，id 与渲染层锚点同一口径
/// （`section.id ?? 第一项 id`）。
List<(String, String)> settingsJumpSections(List<SettingsSection> sections) {
  return <(String, String)>[
    for (final SettingsSection section in sections)
      if ((section.title?.isNotEmpty ?? false) && section.items.isNotEmpty)
        (settingsSectionAnchorId(section), section.title!),
  ];
}

/// 分组锚点 id（[settingsJumpSections] 与渲染层共用）。
String settingsSectionAnchorId(SettingsSection section) =>
    section.id ?? section.items.first.id;

/// 旧接口保留：分组锚点现在由共享分组组件（AdaptiveSettingsSection /
/// SettingsSectionHeader）自动挂，schema 分组也走那条路，这里原样返回。
Widget settingsSectionAnchor({
  required SettingsSectionSpy? spy,
  required SettingsSection section,
  required Widget child,
}) => child;
