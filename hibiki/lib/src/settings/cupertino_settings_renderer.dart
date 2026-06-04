import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart' show ButtonSegment;
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_detail_page.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

class CupertinoSettingsRenderer implements SettingsRenderer {
  const CupertinoSettingsRenderer();

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
    return CupertinoPageScaffold(
      child: CustomScrollView(
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: Text(settingsContext.context.t.settings),
          ),
          SliverFillRemaining(child: list),
        ],
      ),
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
    final Color primaryColor =
        CupertinoTheme.of(settingsContext.context).primaryColor;
    return CupertinoListSection.insetGrouped(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        settingsContext.context,
      ),
      children: destinations.map((SettingsDestination destination) {
        return CupertinoListTile(
          leading: Icon(destination.icon, color: primaryColor),
          title: Text(destination.title),
          subtitle:
              destination.summary != null ? Text(destination.summary!) : null,
          trailing: const CupertinoListTileChevron(),
          onTap: () {
            onDestinationSelected(destination.id);
            if (!pushRoutes) return;
            Navigator.of(settingsContext.context).push(
              CupertinoPageRoute<void>(
                builder: (_) => SettingsDetailPage(destination: destination),
              ),
            );
          },
        );
      }).toList(growable: false),
    );
  }

  @override
  Widget buildDetailPage({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
  }) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        settingsContext.context,
      ),
      child: CustomScrollView(
        slivers: <Widget>[
          CupertinoSliverNavigationBar(
            largeTitle: Text(destination.title),
          ),
          SliverToBoxAdapter(
            child: buildDetailContent(
              settingsContext: settingsContext,
              destination: destination,
              // sliver 沿滚动轴无界，详情须收缩到内容高、由外层 CustomScrollView
              // 滚动（large-title 折叠依赖同一 scrollview）。
              shrinkWrap: true,
            ),
          ),
        ],
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
    final List<SettingsSection> sections =
        destination.visibleSections(settingsContext);
    final EdgeInsets mediaPadding =
        MediaQuery.of(settingsContext.context).padding;
    // 与 MaterialSettingsRenderer.buildDetailContent 对齐：用可滚动 ListView 而非
    // 裸 Column。宽屏 master-detail 的 primary 是有限高度的 Expanded，裸 Column
    // 内容超高会 RenderFlex 溢出（真机右下角黄黑条纹，BUG-009 R1）。
    // shrinkWrap 时禁用自身滚动，交由外层 sliver / SingleChildScrollView 滚动
    // （buildDetailPage 的 CustomScrollView 复用此路径）。底部留安全区，自滚到底
    // 时最后一项不贴边（对齐 Material 渲染器）。
    return ListView.builder(
      controller: scrollController,
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: EdgeInsets.only(bottom: mediaPadding.bottom),
      itemCount: sections.length,
      itemBuilder: (BuildContext context, int index) {
        return _SettingsSchemaSection(
          section: sections[index],
          settingsContext: settingsContext,
          showIcons: false,
          routeBuilder: (BuildContext context, WidgetBuilder builder) {
            return CupertinoPageRoute<void>(builder: builder);
          },
        );
      },
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
          (SettingsItem item) => _SettingsSchemaItem(
            item: item,
            settingsContext: settingsContext,
            showIcons: showIcons,
            routeBuilder: (BuildContext context, WidgetBuilder builder) {
              return CupertinoPageRoute<void>(builder: builder);
            },
          ),
        )
        .toList(growable: false);
  }
}

class _SettingsSchemaSection extends StatelessWidget {
  const _SettingsSchemaSection({
    required this.section,
    required this.settingsContext,
    required this.showIcons,
    required this.routeBuilder,
  });

  final SettingsSection section;
  final SettingsContext settingsContext;
  final bool showIcons;
  final Route<void> Function(BuildContext context, WidgetBuilder builder)
      routeBuilder;

  @override
  Widget build(BuildContext context) {
    if (section.items.isEmpty) return const SizedBox.shrink();
    final List<Widget> rows = section.items
        .map(
          (SettingsItem item) => _SettingsSchemaItem(
            item: item,
            settingsContext: settingsContext,
            showIcons: showIcons,
            routeBuilder: routeBuilder,
          ),
        )
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AdaptiveSettingsSection(title: section.title, children: rows),
        if (section.footer != null && section.footer!.isNotEmpty)
          _SettingsSectionFooter(section.footer!),
      ],
    );
  }
}

class _SettingsSchemaItem extends StatelessWidget {
  const _SettingsSchemaItem({
    required this.item,
    required this.settingsContext,
    required this.showIcons,
    required this.routeBuilder,
  });

  final SettingsItem item;
  final SettingsContext settingsContext;
  final bool showIcons;
  final Route<void> Function(BuildContext context, WidgetBuilder builder)
      routeBuilder;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      SettingsNavigationItem navigation => _routeRow(context, navigation),
      SettingsActionItem action => _action(action),
      SettingsSwitchItem toggle => _switch(toggle),
      SettingsSegmentedItem<dynamic> segmented => _segmented<Object>(
          segmented as SettingsSegmentedItem<Object>,
        ),
      SettingsSliderItem slider => _slider(slider),
      SettingsStepperItem stepper => _stepper(stepper),
      SettingsCustomItem custom => custom.builder(settingsContext),
    };
  }

  Widget _routeRow(
    BuildContext context,
    SettingsNavigationItem navigation,
  ) {
    return AdaptiveSettingsNavigationRow(
      title: navigation.title,
      subtitle: navigation.subtitle,
      icon: navigation.icon,
      showIcon: showIcons || navigation.showIcon,
      onTap: () async {
        if (navigation.onTap != null) {
          await navigation.onTap!(settingsContext);
          return;
        }
        final WidgetBuilder? builder = navigation.builder;
        if (builder == null) return;
        Navigator.of(context).push(routeBuilder(context, builder));
      },
    );
  }

  Widget _action(SettingsActionItem action) {
    return AdaptiveSettingsRow(
      title: action.title,
      subtitle: action.subtitle,
      icon: action.icon,
      showIcon: showIcons,
      onTap: () async => action.onTap(settingsContext),
    );
  }

  Widget _switch(SettingsSwitchItem toggle) {
    final bool value = toggle.value(settingsContext);
    return AdaptiveSettingsSwitchRow(
      title: toggle.title,
      subtitle: toggle.subtitle,
      icon: showIcons ? toggle.icon : null,
      value: value,
      onChanged: (bool next) async {
        await toggle.onChanged(settingsContext, next);
        settingsContext.refresh();
      },
    );
  }

  Widget _segmented<T extends Object>(SettingsSegmentedItem<T> segmented) {
    return AdaptiveSettingsSegmentedRow<T>(
      title: segmented.title,
      subtitle: segmented.subtitle,
      icon: showIcons ? segmented.icon : null,
      segments: segmented.options.map(_segment).toList(growable: false),
      selected: segmented.selected(settingsContext),
      controlBelow: segmented.controlBelow,
      onChanged: (T value) async {
        // 同 MaterialSettingsRenderer._segmented：派发处把
        // SettingsSegmentedItem<String> 转型到 T=Object，静态读
        // `segmented.onChanged` 会因函数参数逆变抛 _TypeError（改 String 型
        // segmented 设置时崩）。用 dynamic 调用绕开读取期检查。
        await (segmented as dynamic).onChanged(settingsContext, value);
        settingsContext.refresh();
      },
    );
  }

  Widget _slider(SettingsSliderItem slider) {
    final double value = slider.value(settingsContext);
    return AdaptiveSettingsSliderRow(
      title: slider.title,
      subtitle: slider.subtitle,
      icon: showIcons ? slider.icon : null,
      value: value.clamp(slider.min, slider.max).toDouble(),
      min: slider.min,
      max: slider.max,
      divisions: slider.divisions,
      label: slider.label?.call(value),
      onChanged: (double next) async {
        await slider.onChanged(settingsContext, next);
        settingsContext.refresh();
      },
      onChangeEnd: slider.onChangeEnd == null
          ? null
          : (double next) async {
              await slider.onChangeEnd!(settingsContext, next);
              settingsContext.refresh();
            },
    );
  }

  Widget _stepper(SettingsStepperItem stepper) {
    final double value = stepper.value(settingsContext);
    return AdaptiveSettingsStepperRow(
      title: stepper.title,
      subtitle: stepper.subtitle,
      icon: showIcons ? stepper.icon : null,
      value: value,
      step: stepper.step,
      min: stepper.min,
      max: stepper.max,
      format: stepper.format,
      onChanged: (double next) async {
        await stepper.onChanged(settingsContext, next);
        settingsContext.refresh();
      },
    );
  }

  ButtonSegment<T> _segment<T extends Object>(SettingsSegmentOption<T> option) {
    return ButtonSegment<T>(
      value: option.value,
      label: Text(option.label),
      icon: option.icon != null ? Icon(option.icon, size: 16) : null,
      tooltip: option.tooltip ?? option.label,
    );
  }
}

class _SettingsSectionFooter extends StatelessWidget {
  const _SettingsSectionFooter(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        tokens.spacing.gap + tokens.spacing.gap / 2,
        0,
        tokens.spacing.gap + tokens.spacing.gap / 2,
        tokens.spacing.gap + tokens.spacing.gap / 2,
      ),
      child: Text(
        text,
        style: tokens.type.metadata.copyWith(
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
        ),
      ),
    );
  }
}
