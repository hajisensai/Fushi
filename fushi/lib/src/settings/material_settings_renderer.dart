import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/settings/settings_search_sheet.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_navigation_groups.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// MD3 设置渲染器（2026-10-04 按 Android 16「设置」/ Material 3 Expressive 重做）：
/// - 宽屏主从左栏是 MD3 导航抽屉式分类列表（单色图标 + 单行标题、行高 48，选中
///   = secondaryContainer 全圆角胶囊），见 [Md3SettingsNavRow]；
/// - 窄屏分类列表与详情都是 Android 16 的「分段分组列表」（组内每行一张卡、
///   2px 缝、外侧大圆角内侧小圆角，见 settings_shared 的
///   `AdaptiveSettingsSection` MD3 形态），分组标题 titleSmall primary 在组上方；
/// - [showDetailHeader]：宽屏详情窗格顶上画分类大标题（headlineMedium）+ 一行
///   说明。嵌进别的宿主（模块设置页签、快捷设置弹窗）时不画。
class MaterialSettingsRenderer implements SettingsRenderer {
  const MaterialSettingsRenderer({this.showDetailHeader = false});

  final bool showDetailHeader;

  /// 宽屏左栏宽。
  static const double navPaneWidth = 240;

  /// 详情页正文的水平内边距（唯一真相源）：左右都是 page。[buildDetailContent]
  /// 与任何要与 schema section 等宽对齐的兄弟卡片（如阅读器快捷设置里并入 layout
  /// 子页顶部的主题选择器卡）都必须从这里取横向缩进，避免各自硬编码导致左右对不齐。
  ///
  /// 左侧曾是 `page + gap`（28），比右侧宽 8：详情正文在自己的窗格里左右不等宽，
  /// 而且宽屏主从下正文左缘紧邻 pane 分隔线——线左边是导航窗格的 20，右边是详情的
  /// 28，一条线两侧呼吸不一样宽，线看着偏向左侧。两边同取 page 后，正文在窗格内
  /// 左右对称，分隔线也居中于 20 + 20 的缝里。
  static EdgeInsets detailHorizontalInsets(FushiDesignTokens tokens) {
    return EdgeInsets.only(
      left: tokens.spacing.page,
      right: tokens.spacing.page,
    );
  }

  @override
  Widget buildHomePage({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required SettingsDestinationId selectedDestinationId,
    required ValueChanged<SettingsDestinationId> onDestinationSelected,
    bool embedded = false,
  }) {
    final Widget list = buildDestinationList(
      settingsContext: settingsContext,
      destinations: destinations,
      selectedDestinationId: selectedDestinationId,
      onDestinationSelected: onDestinationSelected,
    );
    if (embedded) return list;
    return FushiPageScaffold(
      title: settingsContext.context.t.settings,
      body: list,
    );
  }

  @override
  Widget buildDestinationList({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required SettingsDestinationId selectedDestinationId,
    required ValueChanged<SettingsDestinationId> onDestinationSelected,
    bool pushRoutes = true,
  }) {
    final BuildContext context = settingsContext.context;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    // 分类列表短而有界：全部常驻（不懒加载），滚到下面后 Tab 仍能绕回上面的分类。
    if (!pushRoutes) {
      // 宽屏主从左栏：MD3 导航抽屉式列表，直接坐在页面底上（不再装进一张卡）。
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          tokens.spacing.gap + 4,
          0,
          tokens.spacing.gap + 4,
          tokens.spacing.page,
        ),
        child: Md3SettingsNavList(
          destinations: destinations,
          selectedDestinationId: selectedDestinationId,
          onDestinationSelected: onDestinationSelected,
        ),
      );
    }
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.page + mediaPadding.bottom,
      ),
      child: buildDestinationGroups(
        settingsContext: settingsContext,
        destinations: destinations,
        onDestinationSelected: onDestinationSelected,
      ),
    );
  }

  /// Android 16「设置」首页的分类列表（不含滚动容器）：每组一个分段分组列表，
  /// 行 = 单色图标 + 标题（不显示摘要，用户 2026-10-04），点进去 push 详情页。
  /// 设置主页的窄屏布局把它放进带大标题顶栏的滚动视图。
  Widget buildDestinationGroups({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required ValueChanged<SettingsDestinationId> onDestinationSelected,
  }) {
    final BuildContext context = settingsContext.context;
    // 2026-10 动效重做：分类分组首次出现时错峰淡入（进场窗口跟着本列表挂载）。
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (int index, SettingsNavigationGroup group)
              in groupSettingsDestinations(destinations).indexed)
            FushiStaggeredEntrance(
              key: ValueKey<(String, SettingsNavigationGroupId)>(
                ('entrance', group.id),
              ),
              index: index,
              child: AdaptiveSettingsSection(
                key: ValueKey<SettingsNavigationGroupId>(group.id),
                title: group.id.title(context),
                children: <Widget>[
                  for (final SettingsDestination destination
                      in group.destinations)
                    FushiListItem(
                      key: ValueKey<SettingsDestinationId>(destination.id),
                      // M3E：分类图标坐在按分组着色的形状色块里（饱和
                      // container 分区），首页一眼能分出「内容 / 学习 / 连接」。
                      leading: SettingsShapeIcon(
                        icon: destination.icon,
                        tone: settingsIconToneFor(destination.id),
                        size: 36,
                      ),
                      title: Text(destination.title),
                      titleMaxLines: 2,
                      onTap: () {
                        onDestinationSelected(destination.id);
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                SettingsDetailPage(destination: destination),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget buildDetailPage({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
  }) {
    return _kitDetail(settingsContext, destination, showBack: true);
  }

  /// 设置子页整页壳（settings kit）：浮动页头（返回 + 分类图标块 + 标题胶囊 +
  /// 搜索）、≥ 3 个分组时的分组跳转条（当前分组粘在标题下）、错峰进场的正文。
  /// 宽屏主从的右窗格同一个壳，只是不画返回钮——左右两种入口长得一样。
  Widget _kitDetail(
    SettingsContext settingsContext,
    SettingsDestination destination, {
    required bool showBack,
  }) {
    return SettingsKitScaffold(
      key: ValueKey<String>('settings-detail.${destination.id.name}'),
      title: destination.title,
      leadingIcon: destination.icon,
      leadingTone: settingsIconToneFor(destination.id),
      showBack: showBack,
      sections: settingsJumpSections(
        destination.visibleSections(settingsContext),
      ),
      actions: showBack
          ? const <Widget>[SettingsSearchAction()]
          : const <Widget>[],
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => destination.fillsViewport(settingsContext)
          // 正文自管滚动（见 SettingsDestination.bodyFillsViewport）：只给水平
          // 内边距与顶部一点呼吸，正文占满剩余视口（吸顶工具区 / 两栏导航 /
          // 粘性分组标题都靠这一点）；底部安全区由正文自己的滚动视图负责。
          ? Padding(
              padding: EdgeInsets.fromLTRB(
                detailHorizontalInsets(FushiDesignTokens.of(context)).left,
                FushiDesignTokens.of(context).spacing.gap,
                detailHorizontalInsets(FushiDesignTokens.of(context)).right,
                0,
              ),
              child: destination.body!(settingsContext),
            ) : _detailBody(
            settingsContext: settingsContext,
            destination: destination,
            scrollController: controller,
            sectionSpy: spy,
            inlineHeader: false,
            shrinkWrap: false,
            insetHorizontally: true,
          ),
    );
  }

  @override
  Widget buildDetailContent({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
    ScrollController? scrollController,
    bool shrinkWrap = false,
    bool insetHorizontally = true,
  }) {
    // 宽屏主从右窗格：与 push 出来的子页同一个 kit 壳（不画返回钮）。
    if (showDetailHeader && !shrinkWrap && scrollController == null) {
      return _kitDetail(settingsContext, destination, showBack: false);
    }
    return _detailBody(
      settingsContext: settingsContext,
      destination: destination,
      scrollController: scrollController,
      sectionSpy: null,
      inlineHeader: showDetailHeader,
      shrinkWrap: shrinkWrap,
      insetHorizontally: insetHorizontally,
    );
  }

  Widget _detailBody({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
    required ScrollController? scrollController,
    required SettingsSectionSpy? sectionSpy,
    required bool inlineHeader,
    required bool shrinkWrap,
    required bool insetHorizontally,
  }) {
    final BuildContext context = settingsContext.context;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<SettingsSection> sections = destination.visibleSections(
      settingsContext,
    );
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    // Left side hugs the pane divider; give it MD3 expanded breathing room
    // (page + gap = 28) so detail content isn't glued to the nav pane. Horizontal
    // insets come from the shared [detailHorizontalInsets] so sibling cards that
    // must match this width (reader quick-settings 主题选择器) can reuse the same
    // source instead of hardcoding their own left/right padding.
    // Own horizontal insets only when NOT embedded in a parent that already
    // pads horizontally. The reader quick-settings pane passes
    // insetHorizontally:false (it applies its own widePrimaryPadding /
    // narrowPadding), so its schema-projected sub-pages line up with the
    // pane's bespoke 导航 / 有声书 sub-pages instead of double-indenting and
    // rendering narrower (TODO-1321). Mirrors the Cupertino renderer, whose
    // detail body never owns a horizontal inset.
    final EdgeInsets horizontal = insetHorizontally
        ? detailHorizontalInsets(tokens)
        : EdgeInsets.zero;
    final EdgeInsets padding = EdgeInsets.fromLTRB(
      horizontal.left,
      tokens.spacing.gap,
      horizontal.right,
      tokens.spacing.page + mediaPadding.bottom,
    );

    Widget section(int index) => settingsSectionAnchor(
      spy: sectionSpy,
      section: sections[index],
      child: SettingsSchemaSection(
        key: ValueKey<String>('${destination.id.name}.${sections[index].id}'),
        scopeId: destination.id.name,
        section: sections[index],
        settingsContext: settingsContext,
        showIcons: true,
        routeBuilder: (BuildContext context, WidgetBuilder builder) {
          return MaterialPageRoute<void>(builder: builder);
        },
        footerStyle: (BuildContext context) => Theme.of(context)
            .textTheme
            .bodySmall
            ?.copyWith(color: FushiDesignTokens.of(context).surfaces.onVariant),
      ),
    );

    // 整页正文逃生口（见 SettingsDestination.body）：接在所有 schema section 之后，
    // 与它们共享同一个滚动容器与内边距。
    final Widget? bodyWidget = destination.body?.call(settingsContext);
    final ThemeData theme = Theme.of(context);
    final List<Widget> rawContent = <Widget>[
      // 宽屏详情窗格的分类大标题（Android 16 设置的详情标题）+ 一行说明。
      // kit 壳里由浮动页头承担标题，这里不再重复。
      if (inlineHeader)
        Padding(
          padding: EdgeInsets.fromLTRB(
            tokens.spacing.rowHorizontal,
            tokens.spacing.gap,
            tokens.spacing.rowHorizontal,
            tokens.spacing.card,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                destination.title,
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w400,
                ),
              ),
              if (destination.summary?.isNotEmpty ?? false)
                Padding(
                  padding: EdgeInsets.only(top: tokens.spacing.gap / 2),
                  child: Text(
                    destination.summary!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      if (bodyWidget != null && destination.bodyBeforeSections) bodyWidget,
      for (int index = 0; index < sections.length; index++) section(index),
      if (bodyWidget != null && !destination.bodyBeforeSections) bodyWidget,
    ];
    // 2026-10 动效重做：详情的各分组卡错峰淡入上移。宽屏主从切分类时详情整棵
    // 按 destination id 重建（settings_home_page 的 KeyedSubtree），新分类的分组
    // 随之重播一次进场——此前切分类是整块瞬间替换。只改 opacity / transform、
    // 不改布局，滚动范围（BUG-037）与 shrinkWrap 测量不受影响。
    final List<Widget> content = <Widget>[
      for (final (int index, Widget child) in rawContent.indexed)
        FushiStaggeredEntrance(
          // 包装层按子项 key 锚定：分组随谓词增删时，内层带 key 的分组仍能在
          // 兄弟间按 key 认领自己的 State（包装层若按位置配对，内层 key 只在
          // 单子槽里比，错位后 State 会被重建）。
          key: child.key == null ? null : ValueKey<Key>(child.key!),
          index: index,
          child: child,
        ),
    ];

    // Embedded in a PARENT scrollable (cupertino CustomScrollView, the desktop
    // settings SingleChildScrollView, the reader quick-settings sheet): a
    // shrink-wrapped ListView must lay out every child to measure its own height,
    // so its extent is already exact. Keep it — it doesn't own the scroll, so
    // the lazy-extent drift below never applies.
    if (shrinkWrap) {
      return FushiEntranceScope(
        child: ListView.builder(
          controller: scrollController,
          shrinkWrap: true,
          // Embedded in a PARENT scrollable (no own controller) ⇒ must NOT own the
          // scroll. A shrink-wrapped ListView still installs its own Scrollable
          // with a vertical drag recognizer; sized to content its scroll extent is
          // zero, so a drag that lands ON its rows wins the gesture arena, moves
          // nothing, and never bubbles to the parent — the reader quick-settings
          // 布局 sub-page couldn't be scrolled by touch (BUG-042). Disabling the
          // inner physics lets every drag reach the parent. Mirrors the cupertino
          // renderer, which is already NeverScrollable here. The one caller that
          // drives this list itself (fushi_settings_page master-detail) passes a
          // controller and keeps real physics so it can still scroll.
          physics: scrollController == null
              ? const NeverScrollableScrollPhysics()
              : null,
          padding: padding,
          itemCount: content.length,
          itemBuilder: (BuildContext context, int index) => content[index],
        ),
      );
    }

    // Own-scrolling detail page. A lazy `ListView.builder` (SliverList) only
    // lays out visible sections and ESTIMATES the extent of the off-screen ones
    // from the average of the laid-out children. The sync/backup sections have
    // wildly unequal heights (a 1-row toggle vs. the tall LAN discovery / URL
    // list / server-config widgets), so that estimate — and thus
    // `maxScrollExtent` — drifts as you scroll; a fling computed against one
    // extent is re-clamped when it changes mid-flight, which the eye sees as the
    // content jumping (BUG-037). A settings page has a bounded, small number of
    // sections, so laying them ALL out (non-lazy SingleChildScrollView + Column)
    // costs nothing and makes the scroll extent exact and constant.
    return FushiEntranceScope(
      child: SingleChildScrollView(
        controller: scrollController,
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: content,
        ),
      ),
    );
  }

  @override
  List<Widget> buildSectionRows({
    required SettingsContext settingsContext,
    required SettingsSection section,
    bool showIcons = true,
  }) {
    final SettingsSection visible = section.visibleCopy(settingsContext);
    return visible.items
        .map(
          // 行级稳定 key：visibleCopy 按运行时谓词过滤，行增删时以 item.id 锚定
          // State 归属（否则同类型相邻行按位置错配旧 State）。
          (SettingsItem item) => SettingsSchemaItem(
            key: ValueKey<String>(item.id),
            item: item,
            settingsContext: settingsContext,
            showIcons: showIcons,
            routeBuilder: (BuildContext context, WidgetBuilder builder) {
              return MaterialPageRoute<void>(builder: builder);
            },
          ),
        )
        .toList(growable: false);
  }
}

/// 宽屏左栏的分类列表（不含滚动容器）：分组之间留 12，组首一行 titleSmall
/// onSurfaceVariant 小标题；行见 [Md3SettingsNavRow]。
class Md3SettingsNavList extends StatelessWidget {
  const Md3SettingsNavList({
    required this.destinations,
    required this.selectedDestinationId,
    required this.onDestinationSelected,
    super.key,
  });

  final List<SettingsDestination> destinations;
  final SettingsDestinationId selectedDestinationId;
  final ValueChanged<SettingsDestinationId> onDestinationSelected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final List<SettingsNavigationGroup> groups = groupSettingsDestinations(
      destinations,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int g = 0; g < groups.length; g++)
          Padding(
            key: ValueKey<SettingsNavigationGroupId>(groups[g].id),
            padding: EdgeInsets.only(top: g == 0 ? 0 : tokens.spacing.gap + 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: EdgeInsets.fromLTRB(
                    tokens.spacing.rowHorizontal,
                    tokens.spacing.gap,
                    tokens.spacing.rowHorizontal,
                    tokens.spacing.gap / 2,
                  ),
                  child: Text(
                    groups[g].id.title(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final SettingsDestination destination
                    in groups[g].destinations)
                  Md3SettingsNavRow(
                    key: ValueKey<SettingsDestinationId>(destination.id),
                    icon: destination.icon,
                    tone: settingsIconToneFor(destination.id),
                    title: destination.title,
                    selected: destination.id == selectedDestinationId,
                    onTap: () => onDestinationSelected(destination.id),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// MD3 导航抽屉式分类行：24 单色图标 + 标题（labelLarge，最多两行），行高至少 48；选中
/// = secondaryContainer 全圆角胶囊、图标与文字 onSecondaryContainer；悬停 /
/// 焦点 / 按下是 InkWell 状态层。墨水屏下选中填充塌缩成背景色，补 2px 实描边
/// 作唯一选中信号。
///
/// 焦点契约同 [FushiListItem]：有 [FushiFocusRoot] 时外包焦点目标（方向键 /
/// 手柄可达，Enter / A 经 [ActivateIntent] 触发），InkWell 不再是停靠点；没有
/// 焦点根时 InkWell 自己可 Tab、Enter 激活。
class Md3SettingsNavRow extends StatefulWidget {
  const Md3SettingsNavRow({
    required this.icon,
    required this.title,
    required this.onTap,
    super.key,
    this.selected = false,
    this.tone = SettingsIconTone.blue,
  });

  final IconData icon;

  /// 图标色块的色调（按分类，见 settingsIconToneFor）。
  final SettingsIconTone tone;
  final String title;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<Md3SettingsNavRow> createState() => _Md3SettingsNavRowState();
}

class _Md3SettingsNavRowState extends State<Md3SettingsNavRow> {
  late final FushiFocusId _focusId = FushiFocusId(
    'settings-nav-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final bool selected = widget.selected;
    final bool hasFocusRoot = FushiFocusRoot.maybeControllerOf(context) != null;
    final ShapeBorder shape = StadiumBorder(
      side: selected && isEinkTheme(context)
          ? BorderSide(color: tokens.surfaces.outline, width: 2)
          : BorderSide.none,
    );
    final Widget row = Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? scheme.secondaryContainer : Colors.transparent,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: widget.onTap,
          customBorder: const StadiumBorder(),
          canRequestFocus: !hasFocusRoot,
          // 行高至少 48 = 交互控件高度令牌（MD3 导航抽屉行的触控高度）；长分类
          // 名折到第二行时行随内容长高，不裁字（TODO-1143）。
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: tokens.density.controlHeight,
            ),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: tokens.spacing.rowHorizontal,
              ),
              child: Row(
                children: <Widget>[
                  // M3E「当前项」形状对比：图标坐在分组着色的方圆角色块里，
                  // 选中时弹簧变形成 primary 实底圆（SettingsShapeIcon）。
                  SettingsShapeIcon(
                    icon: widget.icon,
                    tone: widget.tone,
                    selected: selected,
                    size: 32,
                  ),
                  SizedBox(width: tokens.spacing.gap + 4),
                  Expanded(
                    child: Text(
                      widget.title,
                      // TODO-1143：窄导航窗格里长 CJK 分类名（如「同步与备份」
                      // 加后缀）放行第二行，不被单行省略号截断。
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: selected
                            ? scheme.onSecondaryContainer
                            : scheme.onSurface,
                        fontWeight:
                            selected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // 按压回弹（M3E）：只旁观指针，不参与手势竞技。
    final Widget pressable = FushiPressScale(child: row);
    if (!hasFocusRoot) return pressable;
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(id: _focusId, child: pressable),
    );
  }
}
