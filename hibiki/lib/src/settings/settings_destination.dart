import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/src/settings/settings_context.dart';

enum SettingsDestinationId {
  appearance,
  profiles,
  readingDisplay,
  readingControls,
  lookup,
  cardCreation,
  listening,
  syncBackup,
  system,
  diagnostics,
  // Synthetic destination for the reader quick-settings dialog; its own id so
  // it never collides with the real readingDisplay destination (HBK-AUDIT-131).
  readerQuickSettings,
}

typedef SettingsVisibility = bool Function(SettingsContext context);
typedef SettingsItemAction = FutureOr<void> Function(SettingsContext context);
typedef SettingsItemBuilder = Widget Function(SettingsContext context);
typedef SettingsValueGetter<T extends Object> = T Function(
  SettingsContext context,
);
typedef SettingsValueChanged<T extends Object> = FutureOr<void> Function(
  SettingsContext context,
  T value,
);
typedef SettingsSwitchGetter = bool Function(SettingsContext context);
typedef SettingsSwitchChanged = FutureOr<void> Function(
  SettingsContext context,
  bool value,
);
typedef SettingsDoubleFormatter = String Function(double value);

class SettingsDestination {
  const SettingsDestination({
    required this.id,
    required this.title,
    required this.icon,
    required this.sections,
    this.summary,
    this.visible,
  });

  final SettingsDestinationId id;
  final String title;
  final IconData icon;
  final String? summary;
  final SettingsVisibility? visible;
  final List<SettingsSection> sections;

  bool isVisible(SettingsContext context) => visible?.call(context) ?? true;

  List<SettingsSection> visibleSections(SettingsContext context) {
    return sections
        .where((SettingsSection section) => section.isVisible(context))
        .map((SettingsSection section) => section.visibleCopy(context))
        .where((SettingsSection section) => section.items.isNotEmpty)
        .toList(growable: false);
  }
}

class SettingsSection {
  const SettingsSection({
    required this.items,
    this.title,
    this.footer,
    this.visible,
  });

  final String? title;
  final String? footer;
  final SettingsVisibility? visible;
  final List<SettingsItem> items;

  bool isVisible(SettingsContext context) => visible?.call(context) ?? true;

  SettingsSection visibleCopy(SettingsContext context) {
    return SettingsSection(
      title: title,
      footer: footer,
      visible: visible,
      items: items
          .where((SettingsItem item) => item.isVisible(context))
          .toList(growable: false),
    );
  }
}

sealed class SettingsItem {
  const SettingsItem({
    required this.id,
    required this.title,
    this.subtitle,
    this.icon,
    this.visible,
  });

  final String id;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final SettingsVisibility? visible;

  bool isVisible(SettingsContext context) => visible?.call(context) ?? true;
}

class SettingsNavigationItem extends SettingsItem {
  const SettingsNavigationItem({
    required super.id,
    required super.title,
    this.builder,
    this.onTap,
    this.showIcon = false,
    super.subtitle,
    super.icon,
    super.visible,
  }) : assert(builder != null || onTap != null);

  final WidgetBuilder? builder;
  final SettingsItemAction? onTap;
  final bool showIcon;
}

class SettingsActionItem extends SettingsItem {
  const SettingsActionItem({
    required super.id,
    required super.title,
    required this.onTap,
    super.subtitle,
    super.icon,
    super.visible,
  });

  final SettingsItemAction onTap;
}

class SettingsSwitchItem extends SettingsItem {
  const SettingsSwitchItem({
    required super.id,
    required super.title,
    required this.value,
    required this.onChanged,
    super.subtitle,
    super.icon,
    super.visible,
  });

  final SettingsSwitchGetter value;
  final SettingsSwitchChanged onChanged;
}

class SettingsSegmentOption<T extends Object> {
  const SettingsSegmentOption({
    required this.value,
    required this.label,
    this.icon,
    this.tooltip,
  });

  final T value;
  final String label;
  final IconData? icon;
  final String? tooltip;
}

class SettingsSegmentedItem<T extends Object> extends SettingsItem {
  const SettingsSegmentedItem({
    required super.id,
    required super.title,
    required this.options,
    required this.selected,
    required this.onChanged,
    super.subtitle,
    super.icon,
    super.visible,
    this.controlBelow = false,
  });

  final List<SettingsSegmentOption<T>> options;
  final SettingsValueGetter<T> selected;
  final SettingsValueChanged<T> onChanged;
  final bool controlBelow;
}

class SettingsSliderItem extends SettingsItem {
  const SettingsSliderItem({
    required super.id,
    required super.title,
    required this.value,
    required this.onChanged,
    super.subtitle,
    super.icon,
    super.visible,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeEnd,
  });

  final double Function(SettingsContext context) value;
  final double min;
  final double max;
  final int? divisions;
  final SettingsDoubleFormatter? label;
  final SettingsValueChanged<double> onChanged;
  final SettingsValueChanged<double>? onChangeEnd;
}

class SettingsStepperItem extends SettingsItem {
  const SettingsStepperItem({
    required super.id,
    required super.title,
    required this.value,
    required this.step,
    required this.min,
    required this.max,
    required this.format,
    required this.onChanged,
    super.subtitle,
    super.icon,
    super.visible,
  });

  final double Function(SettingsContext context) value;
  final double step;
  final double min;
  final double max;
  final SettingsDoubleFormatter format;
  final SettingsValueChanged<double> onChanged;
}

class SettingsCustomItem extends SettingsItem {
  const SettingsCustomItem({
    required super.id,
    required this.builder,
    super.title = '',
    super.subtitle,
    super.icon,
    super.visible,
  });

  final SettingsItemBuilder builder;
}
