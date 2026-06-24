import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hibiki/src/settings/settings_context.dart';

enum SettingsDestinationId {
  appearance,
  profiles,
  reading,
  lookup,
  cardCreation,
  video,
  listening,
  syncBackup,
  system,
  // Synthetic destination for the reader quick-settings dialog; its own id so
  // it never collides with the real reading destination (HBK-AUDIT-131).
  readerQuickSettings,
}

/// 书内快捷面板的分组维度，与全局 [SettingsDestinationId] 正交。
/// 一个设置项可以同时出现在全局某 destination 和书内某 [ReaderGroup]。
///
/// TODO-802/774：原「外观」组（appearance）已删——字体/行高/缩进早已并入
/// [layout]（TODO-774），最后只剩主题选择器，亦并入 [layout]（主题改的也是阅读
/// 显示），外观组整个不再存在。
enum ReaderGroup { layout, behavior, lookup, audiobook }

/// 描述某个 [SettingsItem] 在书内快捷面板里的放置位置。
/// 为 null 表示该项不出现在书内面板（仅全局可见）。
class ReaderPlacement {
  const ReaderPlacement({required this.group, required this.order});

  final ReaderGroup group;

  /// 在所属 [group] 内的升序排序键（仅组内有效，可有间隔）。
  final int order;
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
    this.body,
  });

  final SettingsDestinationId id;
  final String title;
  final IconData icon;
  final String? summary;
  final SettingsVisibility? visible;
  final List<SettingsSection> sections;

  /// 可选的「整页正文」逃生口：非空时，渲染器在渲染完 [sections] 后把
  /// `body(context)` 接在同一个滚动容器里。用于把原本藏在子级菜单（独立路由
  /// 页）的复杂正文——Anki 设置、Profile 管理——直接平铺进本 destination 详情页，
  /// 消掉一层多余跳转。返回的 widget 必须自带 [AdaptiveSettingsSection] 布局且
  /// **不得**自带脚手架/独立滚动（外层渲染器已提供滚动与内边距）。
  final SettingsItemBuilder? body;

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
    this.reader,
  });

  final String id;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final SettingsVisibility? visible;

  /// 书内快捷面板放置；null = 仅全局可见。
  final ReaderPlacement? reader;

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
    super.reader,
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
    super.reader,
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
    super.reader,
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
    super.reader,
    this.controlBelow = true,
  });

  final List<SettingsSegmentOption<T>> options;
  final SettingsValueGetter<T> selected;
  final SettingsValueChanged<T> onChanged;
  final bool controlBelow;

  /// 类型安全地派发一次值变更。渲染器统一把本项当 `SettingsSegmentedItem<Object>`
  /// 持有派发；若在渲染层静态读 [onChanged]（其实际签名是 `(ctx, T)`），会因函数参数
  /// 逆变（`(Object)` 不是 `(String)` 的子类型）抛 `_TypeError`。这里在实例的真实 [T]
  /// 上下文里把 [value] 转回 [T] 再调用，让类型校验落在编译期、渲染层不必 `as dynamic`。
  FutureOr<void> dispatchChange(SettingsContext context, Object value) =>
      onChanged(context, value as T);
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
    super.reader,
    this.min = 0,
    this.max = 1,
    this.divisions,
    this.label,
    this.onChangeEnd,
    this.step,
    this.titleReadout = false,
  });

  final double Function(SettingsContext context) value;
  final double min;
  final double max;
  final int? divisions;
  final SettingsDoubleFormatter? label;
  final SettingsValueChanged<double> onChanged;
  final SettingsValueChanged<double>? onChangeEnd;

  /// 键盘 / 手柄左右键单按步进（覆盖默认的「一档 divisions」步进）。
  /// 用于拖动档位（细）与按键步进（粗）需要解耦的滑条。
  final double? step;

  /// 为 true 时渲染器在标题后追加实时读数 `(label(value))`，如「音量 (95%)」。
  /// [title] 本身保持裸标题不变（焦点遍历 / 覆盖测试以裸标题为身份 key）。
  final bool titleReadout;
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
    super.reader,
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
    super.reader,
  });

  final SettingsItemBuilder builder;
}
