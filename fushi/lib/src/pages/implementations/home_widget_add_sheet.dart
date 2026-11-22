/// 首页编辑态的「添加小组件」面板（spec 2026-11-15）：手机底部弹层、宽屏居中对话框
/// （[adaptiveModalSheet] 自己按宽度分派）。
///
/// 搜索框 + 分类（全部 / 学习 / 继续 / 工具）+ 每项默认尺寸的缩略比例与「可调范围
/// a×b – c×d」；点「添加」→ 按默认尺寸返回 [HomeWidgetItem]（页面追加到列表末尾并
/// 滚动到它，之后在网格里拖角 / 尺寸网格 / 键盘手柄再调）。已在当前布局里的
/// 组件置灰并标注「已在首页」；不可用的组件（模块关着 / 合规门）不出现。
library;

import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/home_widget_layout.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/content_language_picker.dart'
    show contentLanguageLabelOf;
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart'
    show FushiModalSheetFrame, FushiSearchField;
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 组件名（添加面板、编辑态读屏、组件小标题共用）。
String homeWidgetLabel(HomeWidgetKind kind) => switch (kind) {
  HomeWidgetKind.continueHero => t.home_continue,
  HomeWidgetKind.continueReading => t.book_continue_reading,
  HomeWidgetKind.continueWatching => t.video_continue_watching,
  HomeWidgetKind.continuePlaying => t.home_widget_continue_playing,
  HomeWidgetKind.today => t.stat_today,
  HomeWidgetKind.week => t.stat_week_past,
  HomeWidgetKind.srsReview => t.nav_srs,
  HomeWidgetKind.recentlyAdded => t.home_recently_added,
  HomeWidgetKind.tracking => t.home_tracking_panel_title,
  HomeWidgetKind.aiAgent => t.ai_agent_title,
  HomeWidgetKind.panorama => t.home_panel_panorama_title,
  HomeWidgetKind.languageGoals => t.home_widget_language_goals,
};

/// 组件一句话说明（添加面板）。
String homeWidgetDescription(HomeWidgetKind kind) => switch (kind) {
  HomeWidgetKind.continueHero => t.home_widget_desc_continue,
  HomeWidgetKind.continueReading => t.home_widget_desc_continue_reading,
  HomeWidgetKind.continueWatching => t.home_widget_desc_continue_watching,
  HomeWidgetKind.continuePlaying => t.home_widget_desc_continue_playing,
  HomeWidgetKind.today => t.home_widget_desc_today,
  HomeWidgetKind.week => t.home_widget_desc_week,
  HomeWidgetKind.srsReview => t.home_widget_desc_srs_review,
  HomeWidgetKind.recentlyAdded => t.home_widget_desc_recently_added,
  HomeWidgetKind.tracking => t.home_widget_desc_tracking,
  HomeWidgetKind.aiAgent => t.home_widget_desc_ai_agent,
  HomeWidgetKind.panorama => t.home_panel_panorama_hint,
  HomeWidgetKind.languageGoals => t.home_widget_desc_language_goals,
};

/// 布局里一块组件的名字（编辑态读屏 / 尺寸网格标题）：可配置的组件带上配置
/// （「日本語目标」）。
String homeWidgetItemLabel(HomeWidgetItem item) => switch (item.kind) {
  HomeWidgetKind.languageGoals => t.home_language_goals_title(
    language: item.language == null
        ? t.stat_goal_language_all
        : contentLanguageLabelOf(item.language!),
  ),
  _ => homeWidgetLabel(item.kind),
};

/// 添加面板的分类筛选。
enum HomeWidgetAddFilter { all, study, continueMedia, tools }

/// [kind] 是否落在分类 [filter] 里。
bool homeWidgetMatchesFilter(HomeWidgetKind kind, HomeWidgetAddFilter filter) =>
    switch (filter) {
      HomeWidgetAddFilter.all => true,
      HomeWidgetAddFilter.study => kind.category == HomeWidgetCategory.study,
      HomeWidgetAddFilter.continueMedia =>
        kind.category == HomeWidgetCategory.continueMedia,
      HomeWidgetAddFilter.tools => kind.category == HomeWidgetCategory.tools,
    };

/// 添加面板里一项的 key。
ValueKey<String> homeWidgetAddItemKey(HomeWidgetKind kind) =>
    ValueKey<String>('home-widget-add-item/${kind.id}');

/// 添加按钮的 key。
ValueKey<String> homeWidgetAddButtonKey(HomeWidgetKind kind) =>
    ValueKey<String>('home-widget-add/${kind.id}');

/// 默认尺寸缩略块的 key。
ValueKey<String> homeWidgetAddSizeKey(
  HomeWidgetKind kind,
  HomeWidgetSize size,
) => ValueKey<String>(
  'home-widget-add-size/${kind.id}/${size.cols}x${size.rows}',
);

/// 弹出添加面板；用户点了「添加」时返回选中的组件与尺寸，关掉面板返回 null。
Future<HomeWidgetItem?> showHomeWidgetAddSheet(
  BuildContext context, {
  required HomeGridKind grid,
  required List<HomeWidgetKind> available,
  required Set<HomeWidgetKind> present,
  required String Function(HomeWidgetKind kind) labelOf,
  required String Function(HomeWidgetKind kind) descriptionOf,
}) => adaptiveModalSheet<HomeWidgetItem>(
  context: context,
  builder: (BuildContext sheetContext) => HomeWidgetAddSheet(
    grid: grid,
    available: available,
    present: present,
    labelOf: labelOf,
    descriptionOf: descriptionOf,
    onAdd: (HomeWidgetItem item) => Navigator.of(sheetContext).pop(item),
  ),
);

class HomeWidgetAddSheet extends StatefulWidget {
  const HomeWidgetAddSheet({
    super.key,
    required this.grid,
    required this.available,
    required this.present,
    required this.labelOf,
    required this.descriptionOf,
    required this.onAdd,
  });

  final HomeGridKind grid;

  /// 此刻可用的组件（按目录顺序）。
  final List<HomeWidgetKind> available;

  /// 已在当前布局里的组件（置灰）。
  final Set<HomeWidgetKind> present;
  final String Function(HomeWidgetKind kind) labelOf;
  final String Function(HomeWidgetKind kind) descriptionOf;
  final ValueChanged<HomeWidgetItem> onAdd;

  @override
  State<HomeWidgetAddSheet> createState() => _HomeWidgetAddSheetState();
}

class _HomeWidgetAddSheetState extends State<HomeWidgetAddSheet> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _queryFocus = FocusNode(debugLabel: 'home-widget-add-search');
  HomeWidgetAddFilter _filter = HomeWidgetAddFilter.all;

  @override
  void dispose() {
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  List<HomeWidgetKind> get _visible {
    final String q = _query.text.trim().toLowerCase();
    return <HomeWidgetKind>[
      for (final HomeWidgetKind k in widget.available)
        if (homeWidgetMatchesFilter(k, _filter) &&
            (q.isEmpty ||
                widget.labelOf(k).toLowerCase().contains(q) ||
                widget.descriptionOf(k).toLowerCase().contains(q)))
          k,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<HomeWidgetKind> visible = _visible;
    return FushiModalSheetFrame(
      title: t.home_widget_add,
      leadingIcon: FushiIcons.add,
      scrollable: true,
      body: FushiEntranceScope(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiSearchField(
              fieldKey: const ValueKey<String>('home-widget-add-search'),
              controller: _query,
              focusNode: _queryFocus,
              hintText: t.home_widget_search_hint,
              onChanged: (String _) => setState(() {}),
              onSubmitted: (String _) {},
              onClear: () => setState(_query.clear),
            ),
            SizedBox(height: tokens.spacing.gap),
            adaptiveSegmentedButton<HomeWidgetAddFilter>(
              context: context,
              segments: <ButtonSegment<HomeWidgetAddFilter>>[
                ButtonSegment<HomeWidgetAddFilter>(
                  value: HomeWidgetAddFilter.all,
                  label: Text(t.home_widget_category_all),
                ),
                ButtonSegment<HomeWidgetAddFilter>(
                  value: HomeWidgetAddFilter.study,
                  label: Text(t.home_widget_category_study),
                ),
                ButtonSegment<HomeWidgetAddFilter>(
                  value: HomeWidgetAddFilter.continueMedia,
                  label: Text(t.home_continue),
                ),
                ButtonSegment<HomeWidgetAddFilter>(
                  value: HomeWidgetAddFilter.tools,
                  label: Text(t.home_widget_category_tools),
                ),
              ],
              selected: <HomeWidgetAddFilter>{_filter},
              onSelectionChanged: (Set<HomeWidgetAddFilter> s) =>
                  setState(() => _filter = s.first),
            ),
            SizedBox(height: tokens.spacing.card),
            if (visible.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: tokens.spacing.card),
                child: Text(
                  t.home_widget_no_results,
                  key: const ValueKey<String>('home-widget-add-empty'),
                  textAlign: TextAlign.center,
                  style: tokens.type.metadata,
                ),
              ),
            for (int i = 0; i < visible.length; i++)
              FushiStaggeredEntrance(
                index: i,
                child: Padding(
                  padding: EdgeInsets.only(bottom: tokens.spacing.gap),
                  child: _AddItem(
                    key: homeWidgetAddItemKey(visible[i]),
                    kind: visible[i],
                    grid: widget.grid,
                    label: widget.labelOf(visible[i]),
                    description: widget.descriptionOf(visible[i]),
                    present: widget.present.contains(visible[i]),
                    onAdd: widget.onAdd,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AddItem extends StatelessWidget {
  const _AddItem({
    super.key,
    required this.kind,
    required this.grid,
    required this.label,
    required this.description,
    required this.present,
    required this.onAdd,
  });

  final HomeWidgetKind kind;
  final HomeGridKind grid;
  final String label;
  final String description;
  final bool present;
  final ValueChanged<HomeWidgetItem> onAdd;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final HomeWidgetSize size = kind.defaultFor(grid);
    final Widget body = DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.surfaces.group,
        borderRadius: FushiBorderRadius.card,
        // 墨水屏：group 底色塌成页面底色，补描边。
        border: isEinkTheme(context)
            ? Border.all(color: tokens.surfaces.outline)
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              present ? '$label · ${t.home_widget_already_added}' : label,
              style: tokens.type.listTitle,
            ),
            const SizedBox(height: 2),
            Text(description, style: tokens.type.metadata),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                _SizeThumb(
                  key: homeWidgetAddSizeKey(kind, size),
                  size: size,
                  color: scheme,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    t.home_widget_size_range(
                      min: kind.minFor(grid).toString(),
                      max: kind.maxFor(grid).toString(),
                    ),
                    key: ValueKey<String>('home-widget-add-range/${kind.id}'),
                    style: tokens.type.metadata,
                  ),
                ),
                const SizedBox(width: 8),
                FushiPressScale(
                  enabled: !present,
                  child: FushiFilledButton(
                    key: homeWidgetAddButtonKey(kind),
                    onPressed: present
                        ? null
                        : () => onAdd(HomeWidgetItem(kind, size)),
                    child: Text(t.home_widget_add_confirm),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    return Opacity(opacity: present ? 0.5 : 1, child: body);
  }
}

/// 默认尺寸的缩略比例块（宽高按列 × 行等比，纯展示）。
class _SizeThumb extends StatelessWidget {
  const _SizeThumb({super.key, required this.size, required this.color});

  final HomeWidgetSize size;
  final ColorScheme color;

  @override
  Widget build(BuildContext context) {
    const double unit = 24;
    final double w = size.cols * unit + (size.cols - 1) * 3;
    final double h = size.rows * unit + (size.rows - 1) * 3;
    return Semantics(
      label: '$size',
      excludeSemantics: true,
      child: Container(
        width: w,
        height: h,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: color.primaryContainer,
          borderRadius: FushiBorderRadius.chip,
        ),
        child: Text(
          '$size',
          style: context.fushiType.labelSmall.copyWith(
            fontWeight: FontWeight.w700,
            color: color.onPrimaryContainer,
          ),
        ),
      ),
    );
  }
}
