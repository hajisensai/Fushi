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
    // 底部留安全区，自滚到底时最后一项不贴边（对齐 Material 渲染器）。
    final EdgeInsets padding = EdgeInsets.only(bottom: mediaPadding.bottom);

    Widget section(int index) => _SettingsSchemaSection(
          section: sections[index],
          settingsContext: settingsContext,
          showIcons: false,
          routeBuilder: (BuildContext context, WidgetBuilder builder) {
            return CupertinoPageRoute<void>(builder: builder);
          },
        );

    // 整页正文逃生口（见 SettingsDestination.body）：接在所有 schema section 之后，
    // 与它们共享同一个滚动容器与内边距。
    final Widget? bodyWidget = destination.body?.call(settingsContext);

    // shrinkWrap：嵌在外层 sliver / SingleChildScrollView 里（buildDetailPage 的
    // CustomScrollView 复用此路径），由父滚动；shrinkWrap ListView 必须布局全部子项
    // 来量自身高度，extent 已精确，禁用自身滚动即可。
    if (shrinkWrap) {
      return ListView.builder(
        controller: scrollController,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: padding,
        itemCount: sections.length + (bodyWidget != null ? 1 : 0),
        itemBuilder: (BuildContext context, int index) =>
            index < sections.length ? section(index) : bodyWidget!,
      );
    }

    // 自滚动（宽屏 master-detail 详情面板）。镜像 MaterialSettingsRenderer：懒加载
    // ListView.builder 按已布局子项平均高估算视口外 section 的 extent，section 高度
    // 悬殊时 maxScrollExtent 随滚动漂移、弹道落点被重新 clamp → 视口跳跃（BUG-037）。
    // 全 section 布局（SingleChildScrollView + Column）让 extent 精确恒定；它本身可
    // 滚动，也不会像裸 Column 那样在有界 Expanded 里 RenderFlex 溢出（BUG-009 R1）。
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
        // 同 MaterialSettingsRenderer._segmented：用类型安全的
        // SettingsSegmentedItem.dispatchChange 派发，避免静态读 onChanged 因
        // 泛型逆变抛 _TypeError（不再 `as dynamic`）。
        await segmented.dispatchChange(settingsContext, value);
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
      step: slider.step,
      readout: slider.titleReadout ? slider.label?.call(value) : null,
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
