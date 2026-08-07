import 'package:flutter/material.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_detail_page.dart';
import 'package:fushi/src/settings/settings_renderer.dart';
import 'package:fushi/src/settings/settings_schema_widgets.dart';
import 'package:fushi/src/utils/components/hibiki_design_tokens.dart';
import 'package:fushi/src/utils/components/hibiki_material_components.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

class MaterialSettingsRenderer implements SettingsRenderer {
  const MaterialSettingsRenderer();

  /// 详情页正文的水平内边距（唯一真相源）：左侧贴近 pane 分隔线，给 MD3 expanded
  /// 呼吸量（page + gap），右侧 page。[buildDetailContent] 与任何要与 schema
  /// section 等宽对齐的兄弟卡片（如阅读器快捷设置里并入 layout 子页顶部的主题选
  /// 择器卡）都必须从这里取横向缩进，避免各自硬编码导致左右对不齐。
  static EdgeInsets detailHorizontalInsets(HibikiDesignTokens tokens) {
    return EdgeInsets.only(
      left: tokens.spacing.page + tokens.spacing.gap,
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
    return HibikiPageScaffold(
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
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    final List<Widget> rows = <Widget>[
      for (final SettingsDestination destination in destinations)
        HibikiListItem(
          selected: destination.id == selectedDestinationId,
          // Master-detail (pushRoutes:false) keeps selection in-pane, so use the
          // MD3 rounded pill highlight; the narrow push list keeps full-bleed fill.
          selectedShape: pushRoutes
              ? HibikiListItemSelectedShape.fill
              : HibikiListItemSelectedShape.pill,
          leading: Icon(destination.icon),
          title: Text(destination.title),
          // TODO-1143：左父菜单在窄布局（clamp 280..360，最窄 280px）下曾把长分类
          // 标签（如「同步与备份（实验性）」）用 HibikiListItem 默认 titleMaxLines:1
          // 截成「同步与…」。放行第二行；全宽布局本就不换行，无害。
          titleMaxLines: 2,
          subtitle:
              destination.summary != null ? Text(destination.summary!) : null,
          // Chevron implies push navigation; only show it when tapping actually
          // pushes a detail route (narrow layout), not in the master-detail pane.
          trailing: pushRoutes ? const Icon(Icons.chevron_right) : null,
          onTap: () {
            onDestinationSelected(destination.id);
            if (!pushRoutes) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SettingsDetailPage(destination: destination),
              ),
            );
          },
        ),
    ];

    return ListView(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.page + mediaPadding.bottom,
      ),
      children: <Widget>[
        AdaptiveSettingsSection(
          surfaceColor: tokens.surfaces.card,
          children: rows,
        ),
      ],
    );
  }

  @override
  Widget buildDetailPage({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
  }) {
    return HibikiPageScaffold(
      title: destination.title,
      subtitle: destination.summary,
      body: buildDetailContent(
        settingsContext: settingsContext,
        destination: destination,
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
    final BuildContext context = settingsContext.context;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<SettingsSection> sections =
        destination.visibleSections(settingsContext);
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
    final EdgeInsets horizontal =
        insetHorizontally ? detailHorizontalInsets(tokens) : EdgeInsets.zero;
    final EdgeInsets padding = EdgeInsets.fromLTRB(
      horizontal.left,
      tokens.spacing.gap,
      horizontal.right,
      tokens.spacing.page + mediaPadding.bottom,
    );

    Widget section(int index) => SettingsSchemaSection(
          section: sections[index],
          settingsContext: settingsContext,
          showIcons: true,
          routeBuilder: (BuildContext context, WidgetBuilder builder) {
            return MaterialPageRoute<void>(builder: builder);
          },
          footerStyle: (BuildContext context) =>
              Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: HibikiDesignTokens.of(context).surfaces.onVariant,
                  ),
        );

    // 整页正文逃生口（见 SettingsDestination.body）：接在所有 schema section 之后，
    // 与它们共享同一个滚动容器与内边距。
    final Widget? bodyWidget = destination.body?.call(settingsContext);

    // Embedded in a PARENT scrollable (cupertino CustomScrollView, the desktop
    // settings SingleChildScrollView, the reader quick-settings sheet): a
    // shrink-wrapped ListView must lay out every child to measure its own height,
    // so its extent is already exact. Keep it — it doesn't own the scroll, so
    // the lazy-extent drift below never applies.
    if (shrinkWrap) {
      return ListView.builder(
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
        // drives this list itself (hibiki_settings_page master-detail) passes a
        // controller and keeps real physics so it can still scroll.
        physics: scrollController == null
            ? const NeverScrollableScrollPhysics()
            : null,
        padding: padding,
        itemCount: sections.length + (bodyWidget != null ? 1 : 0),
        itemBuilder: (BuildContext context, int index) =>
            index < sections.length ? section(index) : bodyWidget!,
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
    return SingleChildScrollView(
      controller: scrollController,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (int index = 0; index < sections.length; index++) section(index),
          if (bodyWidget != null) bodyWidget,
        ],
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
