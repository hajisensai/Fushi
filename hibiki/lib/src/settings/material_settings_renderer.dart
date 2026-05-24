import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_detail_page.dart';
import 'package:hibiki/src/settings/settings_renderer.dart';

class MaterialSettingsRenderer implements SettingsRenderer {
  const MaterialSettingsRenderer();

  static const EdgeInsets _pagePadding = EdgeInsets.fromLTRB(16, 8, 16, 16);

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
    return Scaffold(
      appBar: AppBar(title: Text(settingsContext.context.t.settings)),
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
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(
        _pagePadding.left,
        _pagePadding.top,
        _pagePadding.right,
        _pagePadding.bottom + mediaPadding.bottom,
      ),
      itemCount: destinations.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 4),
      itemBuilder: (BuildContext context, int index) {
        final SettingsDestination destination = destinations[index];
        final bool selected = destination.id == selectedDestinationId;
        return Material(
          color: selected
              ? Theme.of(context).colorScheme.secondaryContainer
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          child: ListTile(
            leading: Icon(destination.icon),
            title: Text(destination.title),
            subtitle:
                destination.summary != null ? Text(destination.summary!) : null,
            trailing: const Icon(Icons.chevron_right),
            selected: selected,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
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
        );
      },
    );
  }

  @override
  Widget buildDetailPage({
    required SettingsContext settingsContext,
    required SettingsDestination destination,
  }) {
    return Scaffold(
      appBar: AppBar(title: Text(destination.title)),
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
  }) {
    final BuildContext context = settingsContext.context;
    final List<SettingsSection> sections =
        destination.visibleSections(settingsContext);
    final EdgeInsets mediaPadding = MediaQuery.of(context).padding;
    return ListView.builder(
      padding: EdgeInsets.fromLTRB(
        _pagePadding.left,
        _pagePadding.top,
        _pagePadding.right,
        _pagePadding.bottom + mediaPadding.bottom,
      ),
      itemCount: sections.length,
      itemBuilder: (BuildContext context, int index) {
        return _MaterialSettingsSection(
          section: sections[index],
          settingsContext: settingsContext,
        );
      },
    );
  }
}

class _MaterialSettingsSection extends StatelessWidget {
  const _MaterialSettingsSection({
    required this.section,
    required this.settingsContext,
  });

  final SettingsSection section;
  final SettingsContext settingsContext;

  @override
  Widget build(BuildContext context) {
    if (section.items.isEmpty) return const SizedBox.shrink();
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (section.title != null && section.title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                section.title!,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLowest,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              children: _withDividers(
                context,
                section.items
                    .map((SettingsItem item) => _MaterialSettingsItem(
                          item: item,
                          settingsContext: settingsContext,
                        ))
                    .toList(growable: false),
              ),
            ),
          ),
          if (section.footer != null && section.footer!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
              child: Text(
                section.footer!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _withDividers(BuildContext context, List<Widget> rows) {
    final List<Widget> result = <Widget>[];
    for (int index = 0; index < rows.length; index++) {
      if (index > 0) {
        result.add(Divider(
          height: 1,
          thickness: 0.5,
          color: Theme.of(context).colorScheme.outlineVariant,
        ));
      }
      result.add(rows[index]);
    }
    return result;
  }
}

class _MaterialSettingsItem extends StatelessWidget {
  const _MaterialSettingsItem({
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
      trailing: const Icon(Icons.chevron_right),
      onTap: () async {
        if (navigation.onTap != null) {
          await navigation.onTap!(settingsContext);
          return;
        }
        final WidgetBuilder? builder = navigation.builder;
        if (builder == null) return;
        Navigator.of(context).push(
          MaterialPageRoute<void>(builder: builder),
        );
      },
    );
  }

  Widget _action(SettingsActionItem action) {
    return _tile(onTap: () async => action.onTap(settingsContext));
  }

  Widget _switch(SettingsSwitchItem toggle) {
    final bool value = toggle.value(settingsContext);
    return _tile(
      trailing: Switch(
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
    final Widget control = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SegmentedButton<Object>(
        showSelectedIcon: false,
        style: const ButtonStyle(
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        segments:
            segmented.options.map((SettingsSegmentOption<dynamic> option) {
          final Object value = option.value as Object;
          return ButtonSegment<Object>(
            value: value,
            label: Text(option.label),
            icon: option.icon != null ? Icon(option.icon, size: 16) : null,
          );
        }).toList(growable: false),
        selected: <Object>{selected},
        onSelectionChanged: (Set<Object> values) async {
          if (values.isEmpty) return;
          await segmented.onChanged(settingsContext, values.first);
          settingsContext.refresh();
        },
      ),
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
      trailing: Slider(
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
      ),
    );
  }

  Widget _stepper(SettingsStepperItem stepper) {
    final double value = stepper.value(settingsContext);
    return _tile(
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.remove, size: 18),
            onPressed: () async {
              final double next = (value - stepper.step)
                  .clamp(stepper.min, stepper.max)
                  .toDouble();
              await stepper.onChanged(settingsContext, next);
              settingsContext.refresh();
            },
          ),
          SizedBox(
            width: 48,
            child: Text(
              stepper.format(value),
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.add, size: 18),
            onPressed: () async {
              final double next = (value + stepper.step)
                  .clamp(stepper.min, stepper.max)
                  .toDouble();
              await stepper.onChanged(settingsContext, next);
              settingsContext.refresh();
            },
          ),
        ],
      ),
    );
  }

  Widget _tile({
    Widget? trailing,
    GestureTapCallback? onTap,
    bool controlBelow = false,
  }) {
    final Widget label = _SettingsLabel(
      title: item.title,
      subtitle: item.subtitle,
    );
    final Widget? leading = item.icon == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Icon(item.icon, size: 22),
          );
    final Widget child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: controlBelow
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    if (leading != null) leading,
                    Expanded(child: label),
                  ],
                ),
                if (trailing != null) ...<Widget>[
                  const SizedBox(height: 8),
                  Align(alignment: Alignment.centerLeft, child: trailing),
                ],
              ],
            )
          : Row(
              children: <Widget>[
                if (leading != null) leading,
                Expanded(child: label),
                if (trailing != null) ...<Widget>[
                  const SizedBox(width: 12),
                  trailing,
                ],
              ],
            ),
    );
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: child,
      ),
    );
  }
}

class _SettingsLabel extends StatelessWidget {
  const _SettingsLabel({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        Text(
          title,
          style: Theme.of(context).textTheme.bodyMedium,
          overflow: TextOverflow.ellipsis,
        ),
        if (subtitle != null && subtitle!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              subtitle!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
    );
  }
}
