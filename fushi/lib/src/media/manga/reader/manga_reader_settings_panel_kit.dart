/// 漫画「阅读设置」侧板的 M3E 行件（2026-10 侧板重设计）。
///
/// 与小说阅读器设置侧板同一套语言：每页按任务分组成分段卡片列表
/// （[AdaptiveSettingsSection]：组首尾大圆角、行间 2px；Apple 为 inset grouped），
/// 开关用 [AdaptiveSettingsSwitchRow]，滑块用 [AdaptiveSettingsSliderRow]；这里只补
/// 共享件里没有的几种行：
///
/// * [MangaPanelChoiceRow]：M3E 选择行（当前值作副标题，点开底部弹层单选）；
///   Apple 设计系统退回 iOS 弹出按钮 / 分段控件（[AdaptiveSettingsPickerRow]）。
/// * [MangaPanelSegmentedRow]：标题 + 一行说明 + 整行连接式按钮组，长说明收进
///   info 按钮（[MangaPanelInfoButton]）。
/// * [MangaPanelRadioCards]：带图标的单选卡片组（OCR 引擎、选项弹层共用）。
/// * [MangaPanelModeCards]：带示意图标的选择卡网格（阅读模式）。
/// * [MangaPanelFilterPreview]：滤镜实时预览（与阅读器 CSS filter 同一换算）。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 一个可选项：值 + 标签 + 可选图标 / 取舍说明 / 是否可选。
@immutable
class MangaPanelOption<T> {
  const MangaPanelOption({
    required this.value,
    required this.label,
    this.icon,
    this.description,
    this.enabled = true,
    this.key,
  });

  final T value;
  final String label;
  final IconData? icon;
  final String? description;
  final bool enabled;
  final Key? key;
}

/// 一个带标题的分组（分段卡片列表）。空分组不画。
class MangaPanelGroup extends StatelessWidget {
  const MangaPanelGroup({
    required this.title,
    required this.children,
    super.key,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: AdaptiveSettingsSection(title: title, children: children),
    );
  }
}

/// 长说明弹窗（info 按钮的落点）。
Future<void> showMangaPanelInfo(
  BuildContext context, {
  required String title,
  required String message,
}) {
  return showAppDialog<void>(
    context: context,
    builder: (BuildContext ctx) => FushiAlertDialog(
      icon: const FushiIcon(FushiIcons.info),
      title: Text(title),
      content: SingleChildScrollView(child: Text(message)),
      actions: <Widget>[
        FushiTextButton(
          onPressed: () => Navigator.pop(ctx),
          child: Text(t.dialog_close),
        ),
      ],
    ),
  );
}

/// 行尾的 info 按钮：长说明不再平铺，点开看。
class MangaPanelInfoButton extends StatelessWidget {
  const MangaPanelInfoButton({
    required this.title,
    required this.message,
    super.key,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return FushiIconButtonControl(
      icon: FushiIcon(
        FushiIcons.info,
        size: 20,
        color: fushiNeutralSecondaryForeground(context),
      ),
      tooltip: t.manga_reader_more_info,
      onPressed: () =>
          showMangaPanelInfo(context, title: title, message: message),
    );
  }
}

/// 行标题块：标题 + 可选单行说明 + 可选 info 按钮（自绘行共用）。
class _MangaPanelRowHeader extends StatelessWidget {
  const _MangaPanelRowHeader({
    required this.title,
    this.subtitle,
    this.icon,
    this.info,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final String? info;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    final String? sub = subtitle?.trim();
    return Row(
      children: <Widget>[
        if (icon != null) ...<Widget>[
          FushiIcon(
            icon!,
            size: 22,
            color: fushiNeutralSecondaryForeground(context),
          ),
          const SizedBox(width: 16),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                title,
                style: tokens.type.listTitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (sub != null && sub.isNotEmpty)
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: fushiNeutralSecondaryForeground(context),
                  ),
                ),
            ],
          ),
        ),
        if (info != null) MangaPanelInfoButton(title: title, message: info!),
      ],
    );
  }
}

/// 标题 + 一行说明 + 整行连接式按钮组（M3E）/ 分段控件（Apple）。
class MangaPanelSegmentedRow<T> extends StatelessWidget {
  const MangaPanelSegmentedRow({
    required this.title,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.subtitle,
    this.icon,
    this.info,
    this.footer,
    super.key,
  });

  final String title;
  final String? subtitle;
  final IconData? icon;
  final String? info;
  final List<MangaPanelOption<T>> options;
  final T selected;
  final ValueChanged<T>? onChanged;

  /// 按钮组下方的补充（警告、入口按钮）。
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsetsDirectional.fromSTEB(
        16,
        12,
        info == null ? 16 : 4,
        14,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _MangaPanelRowHeader(
            title: title,
            subtitle: subtitle,
            icon: icon,
            info: info,
          ),
          const SizedBox(height: 10),
          Padding(
            padding: EdgeInsetsDirectional.only(end: info == null ? 0 : 12),
            child: FushiSegmentedButton<T>(
              expandedInsets: EdgeInsets.zero,
              showSelectedIcon: false,
              segments: <ButtonSegment<T>>[
                for (final MangaPanelOption<T> option in options)
                  ButtonSegment<T>(
                    value: option.value,
                    enabled: option.enabled,
                    label: Text(
                      option.label,
                      key: option.key,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              selected: <T>{selected},
              onSelectionChanged: onChanged == null
                  ? null
                  : (Set<T> values) {
                      if (values.isEmpty) return;
                      if (values.first != selected) onChanged!(values.first);
                    },
            ),
          ),
          if (footer != null)
            Padding(
              padding: EdgeInsetsDirectional.only(
                top: 8,
                end: info == null ? 0 : 12,
              ),
              child: footer,
            ),
        ],
      ),
    );
  }
}

/// M3E 选择行：标题 + 当前值（副标题），点按从底部弹出单选列表。Apple 设计系统
/// 退回 [AdaptiveSettingsPickerRow]（iOS 弹出按钮 / 分段控件）。
class MangaPanelChoiceRow<T> extends StatelessWidget {
  const MangaPanelChoiceRow({
    required this.title,
    required this.options,
    required this.selected,
    required this.onChanged,
    this.icon,
    this.info,
    super.key,
  });

  final String title;
  final IconData? icon;
  final String? info;
  final List<MangaPanelOption<T>> options;
  final T selected;
  final ValueChanged<T>? onChanged;

  String? get _selectedLabel {
    for (final MangaPanelOption<T> option in options) {
      if (option.value == selected) return option.label;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (isGlassDesign(context) || isCupertinoPlatform(context)) {
      return AdaptiveSettingsPickerRow<T>(
        title: title,
        icon: icon,
        showIcon: icon != null,
        options: <AdaptiveSettingsPickerOption<T>>[
          for (final MangaPanelOption<T> option in options)
            AdaptiveSettingsPickerOption<T>(
              value: option.value,
              label: option.label,
            ),
        ],
        selected: selected,
        onChanged: (T value) => onChanged?.call(value),
      );
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AdaptiveSettingsRow(
      title: title,
      subtitle: _selectedLabel,
      icon: icon,
      showIcon: icon != null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (info != null) MangaPanelInfoButton(title: title, message: info!),
          FushiIcon(
            FushiIcons.dropDown,
            size: 22,
            color: scheme.onSurfaceVariant,
          ),
        ],
      ),
      onTap: onChanged == null
          ? null
          : () async {
              final T? picked = await showMangaPanelOptionSheet<T>(
                context: context,
                title: title,
                options: options,
                selected: selected,
              );
              if (picked != null && picked != selected) onChanged!(picked);
            },
    );
  }
}

/// 单选底部弹层：标题 + 带图标 / 说明的单选卡片组，选中即关。
Future<T?> showMangaPanelOptionSheet<T>({
  required BuildContext context,
  required String title,
  required List<MangaPanelOption<T>> options,
  required T? selected,
}) {
  return adaptiveModalSheet<T>(
    context: context,
    builder: (BuildContext sheetContext) {
      final ThemeData theme = Theme.of(sheetContext);
      return ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.7,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            16,
            4,
            16,
            16 + MediaQuery.viewPaddingOf(sheetContext).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 8, 16),
                child: Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              MangaPanelRadioCards<T>(
                options: options,
                selected: selected,
                onChanged: (T value) => Navigator.pop(sheetContext, value),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// 单选卡片组：分段卡片列表，每项 = 形状底图标 + 标签 + 说明 + 选中勾。
/// 选中项 secondaryContainer 底、图标弹成 cookie 形；不可选的项置灰。
class MangaPanelRadioCards<T> extends StatelessWidget {
  const MangaPanelRadioCards({
    required this.options,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final List<MangaPanelOption<T>> options;
  final T? selected;

  /// null = 整组锁住（导入 / 删除进行中）。
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    final int count = options.length;
    return FushiEntranceScope(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < count; i++)
            FushiStaggeredEntrance(
              index: i,
              child: Semantics(
                selected: options[i].value == selected,
                inMutuallyExclusiveGroup: true,
                child: FushiGroupedListItem(
                  key: options[i].key,
                  index: i,
                  count: count,
                  selected: options[i].value == selected,
                  onTap: onChanged == null || !options[i].enabled
                      ? null
                      : () => onChanged!(options[i].value),
                  child: _MangaPanelRadioContent(
                    option: options[i],
                    selected: options[i].value == selected,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MangaPanelRadioContent extends StatelessWidget {
  const _MangaPanelRadioContent({required this.option, required this.selected});

  final MangaPanelOption<Object?> option;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool glass = isGlassDesign(context);
    final Color accent = glass
        ? appleColorsOf(context).accent
        : theme.colorScheme.primary;
    final String? description = option.description?.trim();
    final Duration duration = fushiMotionDuration(context, FushiMotion.medium);
    final Widget body = Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 12, 12),
      child: Row(
        children: <Widget>[
          if (option.icon != null) ...<Widget>[
            AnimatedSwitcher(
              duration: duration,
              switchInCurve: FushiMotion.release,
              transitionBuilder: (Widget child, Animation<double> a) =>
                  ScaleTransition(
                    scale: Tween<double>(begin: 0.7, end: 1).animate(a),
                    child: FadeTransition(opacity: a, child: child),
                  ),
              child: FushiListLeadingIcon(
                option.icon!,
                key: ValueKey<bool>(selected),
                shape: selected
                    ? FushiLeadingShape.cookie
                    : FushiLeadingShape.circle,
                tone: selected ? FushiCardTone.primary : FushiCardTone.neutral,
              ),
            ),
            const SizedBox(width: 16),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  option.label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
                if (description != null && description.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      description,
                      maxLines: selected ? 4 : 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: fushiNeutralSecondaryForeground(context),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          AnimatedSwitcher(
            duration: duration,
            switchInCurve: FushiMotion.release,
            transitionBuilder: (Widget child, Animation<double> a) =>
                ScaleTransition(scale: a, child: child),
            child: selected
                ? FushiIcon(
                    FushiIcons.check,
                    key: const ValueKey<String>('checked'),
                    color: accent,
                    size: 22,
                  )
                : const SizedBox(
                    key: ValueKey<String>('unchecked'),
                    width: 22,
                    height: 22,
                  ),
          ),
        ],
      ),
    );
    return AnimatedOpacity(
      duration: duration,
      opacity: option.enabled ? 1 : 0.38,
      child: body,
    );
  }
}

/// 阅读模式选择卡网格：每格 = 形状底示意图标 + 标签；选中格 secondaryContainer
/// 色块 + 图标弹成 cookie。窄屏两列、宽一些三列。
class MangaPanelModeCards<T> extends StatelessWidget {
  const MangaPanelModeCards({
    required this.options,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  final List<MangaPanelOption<T>> options;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double gap = 8;
        final int columns = constraints.maxWidth >= 340 ? 3 : 2;
        final double width =
            (constraints.maxWidth - gap * (columns - 1)) / columns;
        return FushiEntranceScope(
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: <Widget>[
              for (final (int i, MangaPanelOption<T> option) in options.indexed)
                FushiStaggeredEntrance(
                  index: i,
                  child: SizedBox(
                    width: math.max(0, width),
                    child: Semantics(
                      selected: option.value == selected,
                      inMutuallyExclusiveGroup: true,
                      child: FushiCard(
                        key: option.key,
                        tone: option.value == selected
                            ? FushiCardTone.secondary
                            : FushiCardTone.neutral,
                        morph: true,
                        padding: const EdgeInsets.fromLTRB(8, 14, 8, 12),
                        onTap: () => onChanged(option.value),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            AnimatedSwitcher(
                              duration: fushiMotionDuration(
                                context,
                                FushiMotion.medium,
                              ),
                              switchInCurve: FushiMotion.release,
                              transitionBuilder:
                                  (Widget child, Animation<double> a) =>
                                      ScaleTransition(
                                        scale: Tween<double>(
                                          begin: 0.6,
                                          end: 1,
                                        ).animate(a),
                                        child: child,
                                      ),
                              child: FushiListLeadingIcon(
                                option.icon ?? FushiIcons.readingMode,
                                key: ValueKey<bool>(option.value == selected),
                                size: 48,
                                shape: option.value == selected
                                    ? FushiLeadingShape.cookie
                                    : FushiLeadingShape.circle,
                                tone: option.value == selected
                                    ? FushiCardTone.primary
                                    : FushiCardTone.neutral,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              option.label,
                              textAlign: TextAlign.center,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelLarge?.copyWith(
                                fontWeight: option.value == selected
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 颜色色板：预设色圆点（选中描边 + 勾），按压回弹、焦点可达。
class MangaPanelColorSwatches extends StatelessWidget {
  const MangaPanelColorSwatches({
    required this.colors,
    required this.selected,
    required this.onChanged,
    super.key,
  });

  /// `#RRGGBB`。
  final List<String> colors;
  final String? selected;
  final ValueChanged<String> onChanged;

  static Color? parse(String? hex) {
    if (hex == null || !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(hex)) {
      return null;
    }
    return Color(0xFF000000 | int.parse(hex.substring(1), radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color ring = isGlassDesign(context)
        ? appleColorsOf(context).accent
        : scheme.primary;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: <Widget>[
        for (final String hex in colors)
          Builder(
            builder: (BuildContext context) {
              final Color color = parse(hex)!;
              final bool isSelected = hex.toUpperCase() == selected;
              final Color check =
                  ThemeData.estimateBrightnessForColor(color) == Brightness.dark
                  ? Colors.white
                  : Colors.black;
              return FushiPressScale(
                child: Semantics(
                  button: true,
                  selected: isSelected,
                  label: hex,
                  child: Material(
                    color: Colors.transparent,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: () => onChanged(hex),
                      child: AnimatedContainer(
                        duration: fushiMotionDuration(
                          context,
                          FushiMotion.short,
                        ),
                        curve: FushiMotion.standard,
                        width: 40,
                        height: 40,
                        decoration: ShapeDecoration(
                          color: color,
                          shape: CircleBorder(
                            side: BorderSide(
                              color: isSelected ? ring : scheme.outlineVariant,
                              width: isSelected ? 3 : 1,
                            ),
                          ),
                        ),
                        child: isSelected
                            ? FushiIcon(
                                FushiIcons.check,
                                size: 20,
                                color: check,
                              )
                            : null,
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

// ── 滤镜预览 ─────────────────────────────────────────────────────────────

/// 4×5 颜色矩阵（行主序，与 [ColorFilter.matrix] 同形）。
typedef _Matrix = List<double>;

const _Matrix _identity = <double>[
  1, 0, 0, 0, 0, //
  0, 1, 0, 0, 0, //
  0, 0, 1, 0, 0, //
  0, 0, 0, 1, 0, //
];

/// 先 [first] 后 [second] 的合成矩阵（second · first，含平移列）。
_Matrix _then(_Matrix first, _Matrix second) {
  final List<double> out = List<double>.filled(20, 0);
  for (int r = 0; r < 4; r++) {
    for (int c = 0; c < 5; c++) {
      double v = 0;
      for (int k = 0; k < 4; k++) {
        v += second[r * 5 + k] * first[k * 5 + c];
      }
      if (c == 4) v += second[r * 5 + 4];
      out[r * 5 + c] = v;
    }
  }
  return out;
}

/// 与阅读器 `mangaImageFilterCss` 同序同值的 CSS filter 链：
/// invert → grayscale → brightness → contrast → saturate。
List<double> mangaPanelFilterMatrix({
  required bool invert,
  required bool grayscale,
  required int brightness,
  required int contrast,
  required int saturation,
}) {
  _Matrix m = _identity;
  if (invert) {
    m = _then(m, const <double>[
      -1, 0, 0, 0, 255, //
      0, -1, 0, 0, 255, //
      0, 0, -1, 0, 255, //
      0, 0, 0, 1, 0, //
    ]);
  }
  if (grayscale) {
    m = _then(m, const <double>[
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0.2126, 0.7152, 0.0722, 0, 0, //
      0, 0, 0, 1, 0, //
    ]);
  }
  final double b = (100 + brightness.clamp(-100, 100)) / 100;
  m = _then(m, <double>[
    b, 0, 0, 0, 0, //
    0, b, 0, 0, 0, //
    0, 0, b, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);
  final double c = contrast.clamp(0, 200) / 100;
  final double o = (0.5 - 0.5 * c) * 255;
  m = _then(m, <double>[
    c, 0, 0, 0, o, //
    0, c, 0, 0, o, //
    0, 0, c, 0, o, //
    0, 0, 0, 1, 0, //
  ]);
  final double s = saturation.clamp(0, 200) / 100;
  m = _then(m, <double>[
    0.213 + 0.787 * s, 0.715 - 0.715 * s, 0.072 - 0.072 * s, 0, 0, //
    0.213 - 0.213 * s, 0.715 + 0.285 * s, 0.072 - 0.072 * s, 0, 0, //
    0.213 - 0.213 * s, 0.715 - 0.715 * s, 0.072 + 0.928 * s, 0, 0, //
    0, 0, 0, 1, 0, //
  ]);
  return m;
}

/// 滤镜实时预览卡：一页示意漫画（墨线分格、网点渐变、对白气泡、彩色块），
/// 套上与阅读器同一换算的颜色矩阵与叠加色。滑块拖动中即随之变化。
class MangaPanelFilterPreview extends StatelessWidget {
  const MangaPanelFilterPreview({
    required this.invert,
    required this.grayscale,
    required this.brightness,
    required this.contrast,
    required this.saturation,
    required this.overlayColor,
    required this.overlayOpacity,
    super.key,
  });

  final bool invert;
  final bool grayscale;
  final int brightness;
  final int contrast;
  final int saturation;

  /// null = 不叠加。
  final Color? overlayColor;

  /// 0..100。
  final int overlayOpacity;

  @override
  Widget build(BuildContext context) {
    final double radius = isGlassDesign(context) ? 14 : 20;
    return Semantics(
      label: t.manga_reader_filter_preview,
      image: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ColorFiltered(
                colorFilter: ColorFilter.matrix(
                  mangaPanelFilterMatrix(
                    invert: invert,
                    grayscale: grayscale,
                    brightness: brightness,
                    contrast: contrast,
                    saturation: saturation,
                  ),
                ),
                child: const CustomPaint(painter: _SamplePagePainter()),
              ),
              if (overlayColor != null)
                IgnorePointer(
                  child: AnimatedContainer(
                    duration: fushiMotionDuration(context, FushiMotion.short),
                    color: overlayColor!.withValues(
                      alpha: overlayOpacity.clamp(0, 100) / 100,
                    ),
                  ),
                ),
              PositionedDirectional(
                start: 10,
                top: 10,
                child: DecoratedBox(
                  decoration: ShapeDecoration(
                    color: Colors.black.withValues(alpha: 0.55),
                    shape: const StadiumBorder(),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Text(
                      t.manga_reader_filter_preview,
                      style: Theme.of(
                        context,
                      ).textTheme.labelMedium?.copyWith(color: Colors.white),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SamplePagePainter extends CustomPainter {
  const _SamplePagePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Rect page = Offset.zero & size;
    canvas.drawRect(page, Paint()..color = const Color(0xFFF7F3EA));
    final Paint ink = Paint()
      ..color = const Color(0xFF1A1A1A)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.5, size.shortestSide * 0.012);
    final double pad = size.shortestSide * 0.06;
    final double midX = size.width * 0.58;
    final double midY = size.height * 0.52;
    // 三个分格。
    final Rect left = Rect.fromLTRB(
      pad,
      pad,
      midX - pad / 2,
      size.height - pad,
    );
    final Rect topRight = Rect.fromLTRB(
      midX + pad / 2,
      pad,
      size.width - pad,
      midY - pad / 2,
    );
    final Rect bottomRight = Rect.fromLTRB(
      midX + pad / 2,
      midY + pad / 2,
      size.width - pad,
      size.height - pad,
    );
    // 左格：网点渐变天空 + 彩色远景。
    canvas.drawRect(
      left,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFF8FB7E0), Color(0xFFF2E3C6)],
        ).createShader(left),
    );
    canvas.drawCircle(
      Offset(left.left + left.width * 0.72, left.top + left.height * 0.3),
      left.shortestSide * 0.14,
      Paint()..color = const Color(0xFFE85A4F),
    );
    final Path hill = Path()
      ..moveTo(left.left, left.bottom)
      ..quadraticBezierTo(
        left.left + left.width * 0.35,
        left.top + left.height * 0.45,
        left.right,
        left.top + left.height * 0.7,
      )
      ..lineTo(left.right, left.bottom)
      ..close();
    canvas.drawPath(hill, Paint()..color = const Color(0xFF3E8E7E));
    // 右上：对白气泡 + 文字行。
    canvas.drawRect(topRight, Paint()..color = Colors.white);
    final Rect bubble = topRight.deflate(topRight.shortestSide * 0.16);
    canvas.drawOval(bubble, Paint()..color = Colors.white);
    canvas.drawOval(bubble, ink);
    final Paint text = Paint()
      ..color = const Color(0xFF1A1A1A)
      ..strokeWidth = math.max(1, size.shortestSide * 0.01)
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 3; i++) {
      final double x = bubble.center.dx + (i - 1) * bubble.width * 0.18;
      canvas.drawLine(
        Offset(x, bubble.top + bubble.height * 0.25),
        Offset(x, bubble.bottom - bubble.height * 0.25),
        text,
      );
    }
    // 右下：灰阶网点条（看对比度 / 亮度）。
    const int steps = 6;
    for (int i = 0; i < steps; i++) {
      final double w = bottomRight.width / steps;
      final int v = (255 * i / (steps - 1)).round();
      canvas.drawRect(
        Rect.fromLTWH(
          bottomRight.left + w * i,
          bottomRight.top,
          w + 0.5,
          bottomRight.height,
        ),
        Paint()..color = Color.fromARGB(255, v, v, v),
      );
    }
    for (final Rect panel in <Rect>[left, topRight, bottomRight]) {
      canvas.drawRect(panel, ink);
    }
  }

  @override
  bool shouldRepaint(_SamplePagePainter oldDelegate) => false;
}
