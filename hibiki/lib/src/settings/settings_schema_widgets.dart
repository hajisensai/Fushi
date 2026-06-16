import 'package:flutter/material.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/settings_shared.dart';

/// 把一个父级 [WidgetBuilder] 包成平台对应的页面路由（Material/Cupertino）。
/// 两个渲染器各自提供工厂，是它们之间唯一的导航差异。
typedef SettingsRouteBuilder = Route<void> Function(
  BuildContext context,
  WidgetBuilder builder,
);

/// section footer 文字样式解析器。两个渲染器对 footer 用不同的 TextStyle
/// （Material：bodySmall + surfaces.onVariant；Cupertino：metadata + secondaryLabel），
/// 是这套共享 schema widget 里唯一的平台差异，作参数注入。
typedef SettingsFooterStyle = TextStyle? Function(BuildContext context);

/// 渲染单个 schema [SettingsSection]：一组 [SettingsSchemaItem] + 可选 footer。
///
/// 收口自 material_settings_renderer 与 cupertino_settings_renderer 此前逐字节复制的
/// 同名私有类（~210 行），平台差异（PageRoute 工厂、footer 文字样式）经
/// [routeBuilder] / [footerStyle] 参数注入。底层行控件本就是 settings_shared 的
/// 自适应组件，dispatch 层没有任何平台理由复制两份。
class SettingsSchemaSection extends StatelessWidget {
  const SettingsSchemaSection({
    super.key,
    required this.section,
    required this.settingsContext,
    required this.showIcons,
    required this.routeBuilder,
    required this.footerStyle,
  });

  final SettingsSection section;
  final SettingsContext settingsContext;
  final bool showIcons;
  final SettingsRouteBuilder routeBuilder;
  final SettingsFooterStyle footerStyle;

  @override
  Widget build(BuildContext context) {
    if (section.items.isEmpty) return const SizedBox.shrink();
    final List<Widget> rows = section.items
        .map(
          (SettingsItem item) => SettingsSchemaItem(
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
        AdaptiveSettingsSection(
          title: section.title,
          titlePlacement: SettingsSectionTitlePlacement.inside,
          children: rows,
        ),
        if (section.footer != null && section.footer!.isNotEmpty)
          SettingsSectionFooter(section.footer!, style: footerStyle),
      ],
    );
  }
}

/// 把一个 schema [SettingsItem] 派发渲染成对应的自适应行控件。
class SettingsSchemaItem extends StatelessWidget {
  const SettingsSchemaItem({
    super.key,
    required this.item,
    required this.settingsContext,
    required this.showIcons,
    required this.routeBuilder,
  });

  final SettingsItem item;
  final SettingsContext settingsContext;
  final bool showIcons;
  final SettingsRouteBuilder routeBuilder;

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
        // 类型安全派发：SettingsSegmentedItem.dispatchChange 在实例真实 T 上下文里
        // 把 value 转回 T 再调 onChanged，避免渲染层静态读 onChanged 因泛型逆变
        // 抛 _TypeError（不再 `as dynamic`）。
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

/// section 底部说明文字。padding 两渲染器一致，文字样式经 [style] 注入。
class SettingsSectionFooter extends StatelessWidget {
  const SettingsSectionFooter(this.text, {super.key, required this.style});

  final String text;
  final SettingsFooterStyle style;

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
      child: Text(text, style: style(context)),
    );
  }
}
