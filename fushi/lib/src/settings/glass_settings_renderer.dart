import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/settings/cupertino_settings_renderer.dart';
import 'package:fushi/src/settings/material_settings_renderer.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_kit.dart';
import 'package:fushi/src/settings/settings_search_sheet.dart';
import 'package:fushi/src/settings/settings_navigation_groups.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// 按当前设计系统选设置渲染器：玻璃 → [GlassSettingsRenderer]，Cupertino
/// （隐藏内部能力）→ [CupertinoSettingsRenderer]，其余 → MD3
/// [MaterialSettingsRenderer]。MD3 / Cupertino 的选择与此前逐字节一致。
SettingsRenderer resolveSettingsRenderer(BuildContext context) {
  if (isGlassDesign(context) && !isCupertinoPlatform(context)) {
    return const GlassSettingsRenderer();
  }
  return isCupertinoPlatform(context)
      ? const CupertinoSettingsRenderer()
      : const MaterialSettingsRenderer();
}

/// 「玻璃」设计系统的设置渲染器：桌面 / 宽屏是 macOS 26「系统设置」，窄屏 /
/// 触屏是 iOS 26「设置」。
///
/// - 分类列表：宽屏主从（`pushRoutes: false`）是 macOS 侧栏——单色强调色图标 +
///   单行标题、行高 32、圆角 8，选中行 = 强调色实底 + onAccent 前景，分组只留
///   一行克制的小灰字；没有卡片外框，直接坐在页面底上。窄屏 push 列表是 iOS
///   inset grouped 分组卡（图标 + 标题 + chevron，不显示摘要）。
/// - 详情：内容列全宽（只留常规左右留白），分组标题在卡片
///   上方，行 = 左标题 / 说明、右控件（行控件本身的 macOS 化在 settings_shared
///   的玻璃分支里：小号开关、弹出菜单按钮、右半宽滑块、行尾 chevron）。详情行
///   不画行首图标（macOS 系统设置的详情行没有图标），分类图标只在侧栏里。
/// - [showDetailHeader]：宽屏主从的详情窗格顶上画当前分类的大标题 + 一行说明
///   （macOS 系统设置的详情标题）。嵌进别的宿主（模块设置页签、快捷设置弹窗）
///   时不画——那些宿主自带标题。
class GlassSettingsRenderer implements SettingsRenderer {
  const GlassSettingsRenderer({this.showDetailHeader = false});

  final bool showDetailHeader;

  /// 宽屏侧栏宽。
  static const double sidebarWidth = 240;

  /// 详情正文的水平内边距：桌面 28（macOS 详情窗格的留白）、触屏 16
  /// （iOS inset grouped 卡片离屏幕边 16）。
  static double detailHorizontalInset(BuildContext context) =>
      FushiAppleMetrics.of(context).desktop ? 28 : 16;

  static Route<void> _route(BuildContext context, WidgetBuilder builder) =>
      MaterialPageRoute<void>(builder: builder);

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
    // 分类列表的内边距按外层 context 算、不含页头让位：整体让开页头（Apple
    // 设计系统本就上下排，这里与 M3E 渲染器同一写法）。
    return FushiPageScaffold(
      title: settingsContext.context.t.settings,
      body: SafeArea(bottom: false, child: list),
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
    // 分类列表短而有界：全部常驻（不懒加载），滚到下面后 Tab 仍能绕回上面的分类。
    if (!pushRoutes) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(10, 2, 10, 16),
        child: GlassSettingsSidebarList(
          destinations: destinations,
          selectedDestinationId: selectedDestinationId,
          onDestinationSelected: onDestinationSelected,
        ),
      );
    }
    final double inset = detailHorizontalInset(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        inset,
        8,
        inset,
        24 + MediaQuery.of(context).padding.bottom,
      ),
      child: buildDestinationGroups(
        settingsContext: settingsContext,
        destinations: destinations,
        onDestinationSelected: onDestinationSelected,
      ),
    );
  }

  /// iOS「设置」首页的分组分类列表（不含滚动容器）：每组一张 inset grouped
  /// 卡，行 = 强调色单色图标 + 标题 + chevron，点进去 push 详情页。设置主页的
  /// 窄屏布局把它和大标题、搜索框放进同一个滚动视图。
  Widget buildDestinationGroups({
    required SettingsContext settingsContext,
    required List<SettingsDestination> destinations,
    required ValueChanged<SettingsDestinationId> onDestinationSelected,
  }) {
    final BuildContext context = settingsContext.context;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final SettingsNavigationGroup group in groupSettingsDestinations(
          destinations,
        ))
          AdaptiveSettingsSection(
            key: ValueKey<SettingsNavigationGroupId>(group.id),
            title: group.id.title(context),
            children: <Widget>[
              for (final SettingsDestination destination in group.destinations)
                AdaptiveSettingsNavigationRow(
                  key: ValueKey<SettingsDestinationId>(destination.id),
                  title: destination.title,
                  icon: destination.icon,
                  showIcon: true,
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
      ],
    );
  }

  @override
  Widget buildDetailPage({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
  }) {
    return _kitDetail(settingsContext, destination, showBack: true);
  }

  /// 设置子页整页壳（settings kit 的 Apple 形态）：返回 + 大标题（滚动收成
  /// 行内标题、玻璃胶囊）+ 搜索，≥ 3 个分组时分组跳转条。宽屏右窗格同一个壳、
  /// 不画返回钮。
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
      // 同 M3E 渲染器：schema 详情的滚动内边距加上壳的页头让位（Apple 设计
      // 系统下壳仍上下排，让位为 0）。
      bodyConsumesTopPadding: true,
      bodyBuilder:
          (
            BuildContext context,
            ScrollController controller,
            SettingsSectionSpy spy,
          ) => destination.fillsViewport(settingsContext)
          // 正文自管滚动（见 SettingsDestination.bodyFillsViewport）：只给水平
          // 内边距与顶部一点呼吸，正文占满剩余视口（吸顶工具区 / 两栏导航 /
          // 粘性分组标题都靠这一点）；底部安全区由正文自己的滚动视图负责。
          ? SafeArea(
              bottom: false,
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  detailHorizontalInset(context),
                  12,
                  detailHorizontalInset(context),
                  0,
                ),
                child: destination.body!(settingsContext),
              ),
            )
          : _detailBody(
              settingsContext: settingsContext,
              destination: destination,
              scrollController: controller,
              sectionSpy: spy,
              inlineHeader: false,
              shrinkWrap: false,
              insetHorizontally: true,
              topInset: MediaQuery.paddingOf(context).top,
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
    bool consumeTopPadding = false,
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
      consumeTopPadding: consumeTopPadding,
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
    bool consumeTopPadding = false,
    double topInset = 0,
  }) {
    final BuildContext context = settingsContext.context;
    final FushiAppleColors apple = appleColorsOf(context);
    final FushiAppleMetrics metrics = FushiAppleMetrics.of(context);
    final List<SettingsSection> sections = destination.visibleSections(
      settingsContext,
    );
    final double horizontal = insetHorizontally
        ? detailHorizontalInset(context)
        : 0;
    final EdgeInsets padding = EdgeInsets.fromLTRB(
      horizontal,
      (inlineHeader ? (metrics.desktop ? 22 : 12) : 12) +
          (consumeTopPadding ? MediaQuery.paddingOf(context).top : 0) +
          topInset,
      horizontal,
      24 + MediaQuery.of(context).padding.bottom,
    );

    Widget section(int index) => settingsSectionAnchor(
      spy: sectionSpy,
      section: sections[index],
      child: SettingsSchemaSection(
        key: ValueKey<String>('${destination.id.name}.${sections[index].id}'),
        scopeId: destination.id.name,
        section: sections[index],
        settingsContext: settingsContext,
        showIcons: false,
        routeBuilder: _route,
        footerStyle: (BuildContext context) =>
            FushiAppleMetrics.of(context).footnoteStyle(context),
      ),
    );

    // 整页正文逃生口（见 SettingsDestination.body）：与 schema section 共享同一个
    // 滚动容器与内容列。
    final Widget? bodyWidget = destination.body?.call(settingsContext);
    final List<Widget> rawContent = <Widget>[
      if (inlineHeader)
        Padding(
          padding: EdgeInsets.fromLTRB(
            metrics.desktop ? 2 : 4,
            0,
            0,
            metrics.desktop ? 18 : 14,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                destination.title,
                style: TextStyle(
                  fontSize: metrics.desktop ? 24 : 30,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                  letterSpacing: metrics.desktop ? 0 : 0.2,
                  color: apple.label,
                ),
              ),
              if (destination.summary?.isNotEmpty ?? false)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    destination.summary!,
                    style: metrics.footnoteStyle(context),
                  ),
                ),
            ],
          ),
        ),
      if (bodyWidget != null && destination.bodyBeforeSections) bodyWidget,
      for (int index = 0; index < sections.length; index++) section(index),
      if (bodyWidget != null && !destination.bodyBeforeSections) bodyWidget,
    ];

    // 分组错峰淡入上移（与 M3E 渲染器同一套 FushiStaggeredEntrance；只改
    // opacity / transform，滚动范围不变）。
    final List<Widget> content = <Widget>[
      for (final (int index, Widget child) in rawContent.indexed)
        FushiStaggeredEntrance(
          key: child.key == null ? null : ValueKey<Key>(child.key!),
          index: index,
          child: child,
        ),
    ];
    // 内容列全宽（用户 2026-10-04「设置页要做成全宽」）：分组卡、行与滑块随
    // 右栏伸缩，只保留常规左右留白。
    final Widget bounded = FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: content,
      ),
    );

    // shrinkWrap：嵌在外层可滚动宿主里（快捷设置弹窗等）。与 MD3 渲染器同一
    // 契约：没有自己的 controller 时不拥有滚动（BUG-042），有 controller 的
    // 调用点（弹窗自己驱动这张列表）保留真实 physics。
    if (shrinkWrap) {
      return ListView(
        controller: scrollController,
        shrinkWrap: true,
        physics: scrollController == null
            ? const NeverScrollableScrollPhysics()
            : null,
        padding: padding,
        children: <Widget>[bounded],
      );
    }
    // 自滚动详情：刻意非懒（SingleChildScrollView + Column），滚动范围精确且
    // 恒定（BUG-037，见 MaterialSettingsRenderer.buildDetailContent）。
    return SingleChildScrollView(
      controller: scrollController,
      padding: padding,
      child: bounded,
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
          // State 归属。
          (SettingsItem item) => SettingsSchemaItem(
            key: ValueKey<String>(item.id),
            item: item,
            settingsContext: settingsContext,
            showIcons: showIcons,
            routeBuilder: _route,
          ),
        )
        .toList(growable: false);
  }
}

/// macOS「系统设置」侧栏的分类列表（不含滚动容器）：分组之间留 14 的空隙，
/// 组首一行克制的 11 号 semibold 灰字；行 = 单色强调色图标 + 单行标题。
class GlassSettingsSidebarList extends StatelessWidget {
  const GlassSettingsSidebarList({
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
    final FushiAppleColors apple = appleColorsOf(context);
    final List<SettingsNavigationGroup> groups = groupSettingsDestinations(
      destinations,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (int g = 0; g < groups.length; g++)
          Padding(
            key: ValueKey<SettingsNavigationGroupId>(groups[g].id),
            padding: EdgeInsets.only(top: g == 0 ? 0 : 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
                  child: Text(
                    groups[g].id.title(context),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: apple.tertiaryLabel,
                    ),
                  ),
                ),
                for (final SettingsDestination destination
                    in groups[g].destinations)
                  GlassSettingsSidebarRow(
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

/// macOS 侧栏行：行高 32、圆角 8；选中 = 强调色实底 + onAccent 图标 / 文字，
/// 悬停 = tertiaryFill，按下 = systemFill。可选 [subtitle] 给搜索结果的面包屑
/// 用（行随之长高）。
///
/// 焦点契约同 [FushiListItem]：有 [FushiFocusRoot] 时外包一个焦点目标（方向键
/// / 手柄可达，Enter / A 经 [ActivateIntent] 触发），行自身不再是停靠点；没有
/// 焦点根时行自己可 Tab、Enter 激活。
class GlassSettingsSidebarRow extends StatefulWidget {
  const GlassSettingsSidebarRow({
    required this.icon,
    required this.title,
    required this.onTap,
    super.key,
    this.subtitle,
    this.selected = false,
    this.tone,
  });

  final IconData icon;

  /// 分类色调（iOS 系统色着色字形）；null = 强调色（搜索结果等）。
  final SettingsIconTone? tone;
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<GlassSettingsSidebarRow> createState() =>
      _GlassSettingsSidebarRowState();
}

class _GlassSettingsSidebarRowState extends State<GlassSettingsSidebarRow> {
  late final FushiFocusId _focusId = FushiFocusId(
    'settings-sidebar-${identityHashCode(this)}',
  );

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool selected = widget.selected;
    final Color fg = selected ? apple.onAccent : apple.label;
    final bool hasFocusRoot = FushiFocusRoot.maybeControllerOf(context) != null;
    final String? subtitle = widget.subtitle;
    final Widget row = FushiAppleRow(
      onTap: widget.onTap,
      selected: selected,
      selectedBackground: apple.accent,
      focusable: !hasFocusRoot,
      borderRadius: BorderRadius.circular(8),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 10,
            vertical: subtitle == null ? 0 : 5,
          ),
          child: Row(
            children: <Widget>[
              if (widget.tone == null)
                FushiIcon(
                  widget.icon,
                  size: 17,
                  color: selected ? apple.onAccent : apple.accent,
                )
              else
                SettingsShapeIcon(
                  icon: widget.icon,
                  tone: widget.tone!,
                  selected: selected,
                  size: 22,
                ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.25,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: fg,
                      ),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.3,
                          color: selected
                              ? apple.onAccent.withValues(alpha: 0.8)
                              : apple.secondaryLabel,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (!hasFocusRoot) return Semantics(selected: selected, child: row);
    return Actions(
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap();
            return null;
          },
        ),
      },
      child: FushiFocusTarget(id: _focusId, child: row),
    );
  }
}
