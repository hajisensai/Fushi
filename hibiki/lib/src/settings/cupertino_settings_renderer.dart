import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_detail_page.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';

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
    return CupertinoListSection.insetGrouped(
      backgroundColor: CupertinoColors.systemGroupedBackground.resolveFrom(
        settingsContext.context,
      ),
      children: destinations.map((SettingsDestination destination) {
        return CupertinoListTile(
          leading: Icon(destination.icon),
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
    return Column(
      children: sections.map((SettingsSection section) {
        return _CupertinoSettingsSection(
          section: section,
          settingsContext: settingsContext,
        );
      }).toList(growable: false),
    );
  }
}

class _CupertinoSettingsSection extends StatelessWidget {
  const _CupertinoSettingsSection({
    required this.section,
    required this.settingsContext,
  });

  final SettingsSection section;
  final SettingsContext settingsContext;

  @override
  Widget build(BuildContext context) {
    if (section.items.isEmpty) return const SizedBox.shrink();
    return CupertinoListSection.insetGrouped(
      header: section.title == null ? null : Text(section.title!),
      footer: section.footer == null ? null : Text(section.footer!),
      children: section.items
          .map((SettingsItem item) => _CupertinoSettingsItem(
                item: item,
                settingsContext: settingsContext,
              ))
          .toList(growable: false),
    );
  }
}

class _CupertinoSettingsItem extends StatelessWidget {
  const _CupertinoSettingsItem({
    required this.item,
    required this.settingsContext,
  });

  final SettingsItem item;
  final SettingsContext settingsContext;

  @override
  Widget build(BuildContext context) {
    return switch (item) {
      SettingsNavigationItem navigation => _navigation(context, navigation),
      SettingsActionItem action => _action(action),
      SettingsSwitchItem toggle => _switch(toggle),
      SettingsSegmentedItem<dynamic> segmented => _segmented(segmented),
      SettingsSliderItem slider => _slider(slider),
      SettingsStepperItem stepper => _stepper(stepper),
      SettingsCustomItem custom => custom.builder(settingsContext),
    };
  }

  Widget _navigation(
    BuildContext context,
    SettingsNavigationItem navigation,
  ) {
    return _tile(
      trailing: const CupertinoListTileChevron(),
      showIcon: navigation.showIcon,
      onTap: () async {
        if (navigation.onTap != null) {
          await navigation.onTap!(settingsContext);
          return;
        }
        final WidgetBuilder? builder = navigation.builder;
        if (builder == null) return;
        Navigator.of(context).push(CupertinoPageRoute<void>(builder: builder));
      },
    );
  }

  Widget _action(SettingsActionItem action) {
    return _tile(onTap: () async => action.onTap(settingsContext));
  }

  Widget _switch(SettingsSwitchItem toggle) {
    final bool value = toggle.value(settingsContext);
    return _tile(
      trailing: CupertinoSwitch(
        value: value,
        onChanged: (bool next) async {
          await toggle.onChanged(settingsContext, next);
          settingsContext.refresh();
        },
      ),
      onTap: () async {
        await toggle.onChanged(settingsContext, !value);
        settingsContext.refresh();
      },
    );
  }

  Widget _segmented(SettingsSegmentedItem<dynamic> segmented) {
    final Object selected = segmented.selected(settingsContext) as Object;
    final Widget control = CupertinoSlidingSegmentedControl<Object>(
      groupValue: selected,
      children: <Object, Widget>{
        for (final SettingsSegmentOption<dynamic> option in segmented.options)
          option.value as Object: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: option.icon == null
                ? Text(option.label)
                : Icon(option.icon, size: 16),
          ),
      },
      onValueChanged: (Object? value) async {
        if (value == null) return;
        await segmented.onChanged(settingsContext, value);
        settingsContext.refresh();
      },
    );
    return _tile(
      trailing: control,
      controlBelow: segmented.controlBelow,
    );
  }

  Widget _slider(SettingsSliderItem slider) {
    final double value = slider.value(settingsContext);
    return _tile(
      controlBelow: true,
      trailing: CupertinoSlider(
        value: value.clamp(slider.min, slider.max).toDouble(),
        min: slider.min,
        max: slider.max,
        divisions: slider.divisions,
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
      ),
    );
  }

  Widget _stepper(SettingsStepperItem stepper) {
    final double value = stepper.value(settingsContext);
    return _tile(
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          CupertinoButton(
            padding: EdgeInsets.zero,
            minSize: 30,
            onPressed: () async {
              final double next = (value - stepper.step)
                  .clamp(stepper.min, stepper.max)
                  .toDouble();
              await stepper.onChanged(settingsContext, next);
              settingsContext.refresh();
            },
            child: const Icon(CupertinoIcons.minus, size: 18),
          ),
          SizedBox(
            width: 48,
            child: Text(
              stepper.format(value),
              textAlign: TextAlign.center,
            ),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            minSize: 30,
            onPressed: () async {
              final double next = (value + stepper.step)
                  .clamp(stepper.min, stepper.max)
                  .toDouble();
              await stepper.onChanged(settingsContext, next);
              settingsContext.refresh();
            },
            child: const Icon(CupertinoIcons.add, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _tile({
    Widget? trailing,
    GestureTapCallback? onTap,
    bool controlBelow = false,
    bool showIcon = false,
  }) {
    final Widget? leading =
        showIcon && item.icon != null ? Icon(item.icon) : null;
    if (controlBelow) {
      return CupertinoListTile(
        leading: leading,
        title: Text(item.title),
        subtitle: item.subtitle == null ? null : Text(item.subtitle!),
        onTap: onTap,
        trailing: null,
        additionalInfo: null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ).withBelow(trailing);
    }
    return CupertinoListTile(
      leading: leading,
      title: Text(item.title),
      subtitle: item.subtitle == null ? null : Text(item.subtitle!),
      trailing: trailing,
      onTap: onTap,
    );
  }
}

extension _CupertinoTileBelow on CupertinoListTile {
  Widget withBelow(Widget? child) {
    if (child == null) return this;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        this,
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Align(alignment: Alignment.centerLeft, child: child),
        ),
      ],
    );
  }
}
