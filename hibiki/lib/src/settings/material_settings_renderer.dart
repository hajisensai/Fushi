import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_detail_page.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';
import 'package:hibiki/src/settings/settings_schema_widgets.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

class MaterialSettingsRenderer implements SettingsRenderer {
  const MaterialSettingsRenderer();

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
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.page,
        tokens.spacing.gap,
        tokens.spacing.page,
        tokens.spacing.page + mediaPadding.bottom,
      ),
      itemCount: destinations.length,
      separatorBuilder: (BuildContext context, int index) =>
          SizedBox(height: tokens.spacing.gap / 2),
      itemBuilder: (BuildContext context, int index) {
        final SettingsDestination destination = destinations[index];
        final bool selected = destination.id == selectedDestinationId;
        return HibikiListItem(
          selected: selected,
          // Master-detail (pushRoutes:false) keeps selection in-pane, so use the
          // MD3 rounded pill highlight; the narrow push list keeps full-bleed fill.
          selectedShape: pushRoutes
              ? HibikiListItemSelectedShape.fill
              : HibikiListItemSelectedShape.pill,
          leading: Icon(destination.icon),
          title: Text(destination.title),
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
        );
      },
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
  }) {
    final BuildContext context = settingsContext.context;
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    final List<SettingsSection> sections =
        destination.visibleSections(settingsContext);
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    // Left side hugs the pane divider; give it MD3 expanded breathing room
    // (page + gap = 24) so detail content isn't glued to the nav pane.
    final EdgeInsets padding = EdgeInsets.fromLTRB(
      tokens.spacing.page + tokens.spacing.gap,
      tokens.spacing.gap,
      tokens.spacing.page,
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
          (SettingsItem item) => SettingsSchemaItem(
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
