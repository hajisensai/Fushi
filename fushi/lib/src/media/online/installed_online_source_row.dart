import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

// 已装在线源列表（「浏览 › 来源」与各库页「来源」子标签）三域共用的 M3E 积木。
//
// 漫画 / 视频（Mihon / Aniyomi，`MihonInstalledSourcesSection`）、小说
// （LNReader，`LnReaderInstalledSourcesSection`）与内置 mokuro.moe 行
// （`MokuroMoeSourceRow`）同一种行形态：
//
// - 分段列表行（[FushiGroupedListItem]）：行首 M3E 开关、名称、副标题 = 语言
//   tag + 包名 / 站点；
// - 行尾只留一个主要动作（来源偏好）+ 「⋯」菜单（登录 / 置顶 / 上移下移 / 清数据），
//   宽窄同形——此前宽行把六个图标按钮铺成一排，标题被挤到只剩几个字；
// - 置顶组与其余组各自一组（[InstalledSourcesGroup]），组内可拖拽重排；搜索 /
//   筛选生效时不可拖（筛选后的顺序不是真实顺序）。

/// 「⋯」菜单里的一项。
class OnlineSourceMenuAction {
  const OnlineSourceMenuAction({
    required this.label,
    required this.icon,
    required this.onTap,
    this.key,
    this.destructive = false,
  });

  /// 挂在 [PopupMenuItem] 上（测试 / 焦点驱动按它找菜单项）。
  final Key? key;
  final String label;
  final IconData icon;

  /// 为 null 表示当前不可用（组首的「上移」、组尾的「下移」）：菜单里是禁用项，
  /// 不是消失——位置稳定，键盘用户不会摸不着。
  final VoidCallback? onTap;

  /// 破坏性动作（清数据）：菜单里用 error 色。
  final bool destructive;
}

/// 状态筛选（只影响显示，不改数据）。
enum OnlineSourceStatusFilter { all, enabled, disabled }

/// 语言 tag 的显示：语言码（`ja` / `zh-hans`）一律大写；LNReader 一类直接给语言
/// 名（`English`）的原样显示。
String onlineSourceLanguageLabel(String language) {
  final String value = language.trim();
  final bool looksLikeCode =
      value.length <= 3 ||
      RegExp(r'^[A-Za-z]{2,3}([-_][A-Za-z0-9]+)*$').hasMatch(value);
  return looksLikeCode ? value.toUpperCase() : value;
}

/// [languages] 去重（不分大小写）、去空、按显示名排序后的语言列表（筛选 chip 用）。
List<String> onlineSourceLanguages(Iterable<String> languages) {
  final Map<String, String> byKey = <String, String>{};
  for (final String raw in languages) {
    final String value = raw.trim();
    if (value.isEmpty) continue;
    byKey.putIfAbsent(value.toLowerCase(), () => value);
  }
  final List<String> result = byKey.values.toList()
    ..sort(
      (String a, String b) =>
          onlineSourceLanguageLabel(a).compareTo(onlineSourceLanguageLabel(b)),
    );
  return result;
}

/// 一个源是否通过当前筛选（[languageFilter] 为 null = 不限语言，比较不分大小写）。
bool matchesOnlineSourceFilter({
  required bool enabled,
  required String language,
  required OnlineSourceStatusFilter status,
  required String? languageFilter,
}) {
  final bool statusOk = switch (status) {
    OnlineSourceStatusFilter.all => true,
    OnlineSourceStatusFilter.enabled => enabled,
    OnlineSourceStatusFilter.disabled => !enabled,
  };
  if (!statusOk) return false;
  if (languageFilter == null) return true;
  return language.trim().toLowerCase() == languageFilter.trim().toLowerCase();
}

/// 搜索框下的一行筛选 chip（横向可滚）：全部 / 已启用 / 已停用 + 各语言。
///
/// 「全部」= 两个维度都清空；状态 chip 与语言 chip 各自再点一次即取消。
class OnlineSourcesFilterBar extends StatelessWidget {
  const OnlineSourcesFilterBar({
    required this.status,
    required this.language,
    required this.languages,
    required this.onChanged,
    super.key,
  });

  final OnlineSourceStatusFilter status;
  final String? language;

  /// 可选语言（[onlineSourceLanguages] 的结果）；少于两种时不出语言 chip。
  final List<String> languages;
  final void Function(OnlineSourceStatusFilter status, String? language)
  onChanged;

  bool _isLanguage(String value) =>
      language != null && language!.toLowerCase() == value.toLowerCase();

  @override
  Widget build(BuildContext context) {
    final double gap = FushiDesignTokens.of(context).spacing.gap;
    final List<Widget> chips = <Widget>[
      FushiChoiceChip(
        key: const ValueKey<String>('online_sources_filter_all'),
        label: Text(t.online_sources_filter_all),
        selected: status == OnlineSourceStatusFilter.all && language == null,
        onSelected: (bool _) => onChanged(OnlineSourceStatusFilter.all, null),
      ),
      FushiChoiceChip(
        key: const ValueKey<String>('online_sources_filter_enabled'),
        label: Text(t.online_sources_filter_enabled),
        selected: status == OnlineSourceStatusFilter.enabled,
        onSelected: (bool _) => onChanged(
          status == OnlineSourceStatusFilter.enabled
              ? OnlineSourceStatusFilter.all
              : OnlineSourceStatusFilter.enabled,
          language,
        ),
      ),
      FushiChoiceChip(
        key: const ValueKey<String>('online_sources_filter_disabled'),
        label: Text(t.online_sources_filter_disabled),
        selected: status == OnlineSourceStatusFilter.disabled,
        onSelected: (bool _) => onChanged(
          status == OnlineSourceStatusFilter.disabled
              ? OnlineSourceStatusFilter.all
              : OnlineSourceStatusFilter.disabled,
          language,
        ),
      ),
      if (languages.length > 1)
        for (final String value in languages)
          FushiChoiceChip(
            key: ValueKey<String>(
              'online_sources_filter_lang_${value.toLowerCase()}',
            ),
            label: Text(onlineSourceLanguageLabel(value)),
            selected: _isLanguage(value),
            onSelected: (bool _) =>
                onChanged(status, _isLanguage(value) ? null : value),
          ),
    ];
    return FocusTraversalGroup(
      child: HorizontalDragScrollable(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: <Widget>[
              for (int i = 0; i < chips.length; i++) ...<Widget>[
                if (i > 0) SizedBox(width: gap),
                chips[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 搜索 / 筛选生效时的一行说明：此刻不能拖拽排序。
class OnlineSourcesReorderDisabledHint extends StatelessWidget {
  const OnlineSourcesReorderDisabledHint({super.key});

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: <Widget>[
          FushiIcon(FushiIcons.info, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              t.font_library_reorder_filtered_hint,
              style: context.fushiType.bodySmall.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// 一个已装在线源的一行（分段列表行）。
///
/// [index] / [count] 是组内位置（决定分段圆角）；行间缝由外层
/// [InstalledSourcesGroup] 统一插（拖拽浮层只包行本身）。
class InstalledOnlineSourceRow extends StatelessWidget {
  const InstalledOnlineSourceRow({
    required this.index,
    required this.count,
    required this.title,
    required this.enabled,
    required this.onEnabledChanged,
    super.key,
    this.rowKey,
    this.language,
    this.detail,
    this.pinned = false,
    this.onOpen,
    this.primaryAction,
    this.menuKey,
    this.menuActions = const <OnlineSourceMenuAction>[],
    this.dragEnabled = false,
  });

  final int index;
  final int count;

  /// 挂在行内 [FushiListItem] 上的 key（测试按它找行）。
  final Key? rowKey;
  final String title;
  final bool enabled;

  /// null = 开关只读（偏好未就绪）。
  final ValueChanged<bool>? onEnabledChanged;
  final String? language;

  /// 副标题 tag 之后的文字：扩展包名 / 站点。
  final String? detail;
  final bool pinned;

  /// 点行进该源；只在已启用时生效（停用的源不可点，与此前同一口径）。
  final VoidCallback? onOpen;

  /// 行尾唯一的常驻动作（来源偏好）。
  final Widget? primaryAction;
  final Key? menuKey;
  final List<OnlineSourceMenuAction> menuActions;

  /// 行尾显示拖拽把手（组内可拖时）。手势由外层 [FushiReorderableColumn] 负责：
  /// 鼠标按下即拖、触摸长按再拖。
  final bool dragEnabled;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    final ColorScheme cs = Theme.of(context).colorScheme;
    final String? lang = language?.trim();
    final String? detailText = detail?.trim();
    final double contentOpacity = enabled ? 1 : 0.6;
    return FushiGroupedListItem(
      index: index,
      count: count,
      includeGap: false,
      onTap: enabled ? onOpen : null,
      child: FushiListItem(
        key: rowKey,
        leading: FushiSwitch.adaptive(
          value: enabled,
          onChanged: onEnabledChanged,
        ),
        // 启停：标题与副标题的淡出走 effects 弹簧（透明度不过冲）。
        title: AnimatedOpacity(
          opacity: contentOpacity,
          duration: motion.effectsDefault.duration,
          curve: motion.effectsDefault.curve,
          child: Row(
            children: <Widget>[
              // 置顶：钉子图标随 spatial 弹簧展开 / 收起。
              AnimatedSize(
                duration: motion.spatialFast.duration,
                curve: motion.spatialFast.curve,
                alignment: AlignmentDirectional.centerStart,
                child: pinned
                    ? Padding(
                        padding: const EdgeInsetsDirectional.only(end: 6),
                        child: FushiIcon(
                          FushiIcons.filled(FushiIcons.pin),
                          size: 16,
                          color: cs.primary,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        subtitle:
            (lang == null || lang.isEmpty) &&
                (detailText == null || detailText.isEmpty)
            ? null
            : AnimatedOpacity(
                opacity: contentOpacity,
                duration: motion.effectsDefault.duration,
                curve: motion.effectsDefault.curve,
                child: Row(
                  children: <Widget>[
                    if (lang != null && lang.isNotEmpty) ...<Widget>[
                      FushiTag(
                        text: onlineSourceLanguageLabel(lang),
                        tone: FushiTagTone.neutral,
                        dense: true,
                      ),
                      const SizedBox(width: 8),
                    ],
                    if (detailText != null && detailText.isNotEmpty)
                      Flexible(
                        child: Text(
                          detailText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (primaryAction != null) primaryAction!,
            if (menuActions.isNotEmpty)
              FushiPopupMenuButton<OnlineSourceMenuAction>(
                key: menuKey,
                tooltip: t.common_more_actions,
                icon: const FushiIcon(FushiIcons.more),
                onSelected: (OnlineSourceMenuAction action) =>
                    action.onTap?.call(),
                itemBuilder: (BuildContext context) =>
                    <PopupMenuEntry<OnlineSourceMenuAction>>[
                      for (final OnlineSourceMenuAction action in menuActions)
                        PopupMenuItem<OnlineSourceMenuAction>(
                          key: action.key,
                          value: action,
                          enabled: action.onTap != null,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              FushiIcon(
                                action.icon,
                                size: 20,
                                color: action.destructive ? cs.error : null,
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  action.label,
                                  style: action.destructive
                                      ? TextStyle(color: cs.error)
                                      : null,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
              ),
            if (dragEnabled) ...<Widget>[
              const SizedBox(width: 4),
              const FushiDragHandle(),
            ],
          ],
        ),
      ),
    );
  }
}

/// 组内一行的构造器：[dragEnabled] 为 true 时行尾应显示拖拽把手。
typedef InstalledSourceRowBuilder<T> =
    Widget Function(
      BuildContext context,
      T item,
      int index,
      int count,
      bool dragEnabled,
    );

/// 一组已装源（置顶组 / 其余组）：可选小标题 + 分段列表，组内拖拽重排。
///
/// [reorderable] 为 true 且多于一行时用 [FushiReorderableColumn]（自实现的重排列，
/// 在 `FushiAppUiScale` 祖先缩放下不漂移，鼠标按下即拖、触摸长按再拖），只在本组
/// 内拖；落点后 [onReorder] 收到整组的新顺序，由调用方批量回写。
///
/// 每行包一层 [FushiStaggeredEntrance]（序号从 [entranceOffset] 起），调用方在外层
/// 挂 [FushiEntranceScope]；行数变化（置顶 / 取消置顶把行挪到另一组）用 spatial
/// 弹簧 [AnimatedSize] 过渡。
class InstalledSourcesGroup<T> extends StatelessWidget {
  const InstalledSourcesGroup({
    required this.items,
    required this.keyOf,
    required this.rowBuilder,
    required this.reorderable,
    required this.onReorder,
    super.key,
    this.header,
    this.entranceOffset = 0,
  });

  final List<T> items;

  /// 行身份（拖拽时的稳定 key）。
  final String Function(T item) keyOf;
  final InstalledSourceRowBuilder<T> rowBuilder;
  final bool reorderable;
  final void Function(List<T> reordered) onReorder;

  /// 组小标题；null 不显示。
  final String? header;
  final int entranceOffset;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    final double gap = fushiGroupedListGap(context);
    final int count = items.length;
    final bool drag = reorderable && count > 1;
    Widget row(BuildContext context, int index) => FushiStaggeredEntrance(
      index: entranceOffset + index,
      child: rowBuilder(context, items[index], index, count, drag),
    );
    final Widget body = drag
        ? FushiReorderableColumn(
            itemCount: count,
            spacing: gap,
            keyForIndex: (int index) =>
                ValueKey<String>('online_source_drag_${keyOf(items[index])}'),
            onReorder: (int from, int to) {
              final List<T> reordered = List<T>.of(items);
              final T moved = reordered.removeAt(from);
              reordered.insert(to, moved);
              onReorder(reordered);
            },
            itemBuilder: row,
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              for (int i = 0; i < count; i++) ...<Widget>[
                if (i > 0) SizedBox(height: gap),
                KeyedSubtree(
                  key: ValueKey<String>('online_source_${keyOf(items[i])}'),
                  child: row(context, i),
                ),
              ],
            ],
          );
    final String? title = header;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (title != null)
          FushiSectionTitle.group(
            title,
            trailing: Text(
              '$count',
              style: context.fushiType.labelMedium.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        AnimatedSize(
          duration: motion.spatialDefault.duration,
          curve: motion.spatialDefault.curve,
          alignment: Alignment.topCenter,
          child: body,
        ),
      ],
    );
  }
}

/// 加载中：三行与真实行同轮廓的骨架。
class InstalledSourcesSkeleton extends StatelessWidget {
  const InstalledSourcesSkeleton({super.key, this.rows = 3});

  final int rows;

  @override
  Widget build(BuildContext context) {
    final double gap = fushiGroupedListGap(context);
    return FushiSkeletonShimmer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int i = 0; i < rows; i++) ...<Widget>[
            if (i > 0) SizedBox(height: gap),
            FushiSkeleton(
              height: 72,
              borderRadius: fushiGroupedItemRadius(context, i, rows),
            ),
          ],
        ],
      ),
    );
  }
}
