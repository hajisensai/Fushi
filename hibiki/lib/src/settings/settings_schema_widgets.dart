import 'package:flutter/material.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/settings/settings_schema_fields.dart';
import 'package:fushi/src/settings/settings_search.dart';
import 'package:fushi/src/utils/components/hibiki_design_tokens.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

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
          // 行级稳定 key：visible 谓词可在运行时增删行（如 qualityOptionCount
          // 变化），无 key 时同类型相邻行会按位置错配旧 State（陈旧文本 / 在途
          // 防抖写错项）；以 item.id 锚定 State 归属。
          (SettingsItem item) => SettingsSchemaItem(
            key: ValueKey<String>(item.id),
            item: item,
            settingsContext: settingsContext,
            showIcons: showIcons,
            routeBuilder: routeBuilder,
          ),
        )
        .toList(growable: false);
    // 折叠能力只取决于「有没有标题」（无标题 section 没有可点的折叠头）；
    // 「默认展开还是收起」由 collapsedByDefault 单独决定（见下方 initiallyExpanded）。
    // 两者解耦——所有带标题分区都可折叠，各自默认态互不影响。
    final bool collapsible = section.title?.isNotEmpty ?? false;
    // 搜索跳转落在折叠 section 内的项时强制展开——否则收起态下目标行不入树、
    // SettingsSearchReveal 的一次性挂点永不被消费，定位失效。测试钩子强制全展开
    // 让覆盖守卫能焦点驱动到所有行（见 debugSettingsForceExpandAllSections）。
    final bool containsPendingReveal =
        SettingsSearchReveal.pendingItemId != null &&
            section.items.any((SettingsItem item) =>
                item.id == SettingsSearchReveal.pendingItemId);
    final bool initiallyExpanded = debugSettingsForceExpandAllSections ||
        !section.collapsedByDefault ||
        containsPendingReveal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        AdaptiveSettingsSection(
          title: section.title,
          titlePlacement: SettingsSectionTitlePlacement.inside,
          collapsible: collapsible,
          initiallyExpanded: initiallyExpanded,
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
    final Widget row = switch (item) {
      SettingsNavigationItem navigation => _routeRow(context, navigation),
      SettingsActionItem action => _action(action),
      SettingsSwitchItem toggle => _switch(toggle),
      SettingsSegmentedItem<dynamic> segmented => _segmented<Object>(
          segmented as SettingsSegmentedItem<Object>,
        ),
      SettingsSliderItem slider => _slider(slider),
      SettingsStepperItem stepper => _stepper(stepper),
      SettingsTextItem text => _text(text),
      SettingsNumberItem number => _number(number),
      SettingsCustomItem custom => custom.builder(settingsContext),
    };
    // 设置搜索跳转落点：本项是待定位目标时消费一次性挂点，包上滚动定位 +
    // 闪烁高亮（见 SettingsSearchReveal）。消费即清除，后续 rebuild 不再包装。
    if (SettingsSearchReveal.pendingItemId == item.id) {
      SettingsSearchReveal.pendingItemId = null;
      return SettingsRevealTarget(child: row);
    }
    return row;
  }

  Widget _routeRow(
    BuildContext context,
    SettingsNavigationItem navigation,
  ) {
    return AdaptiveSettingsNavigationRow(
      // resolveTitle：诊断行的实时计数在这里求值（schema 树本身是缓存的常量树）。
      title: navigation.resolveTitle(settingsContext),
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
      icon: toggle.icon,
      showIcon: showIcons,
      value: value,
      onChanged: (bool next) async {
        await toggle.onChanged(settingsContext, next);
        settingsContext.refresh();
      },
    );
  }

  Widget _segmented<T extends Object>(SettingsSegmentedItem<T> segmented) {
    // dropdown 渲染分支（TODO-209）：同一数据模型换下拉单选控件——标签长/选项多的
    // 行在窄 pane 里分段条只能横向滚动裁断，下拉行内只显示当前选中标签、永不被裁。
    if (segmented.dropdown) {
      return AdaptiveSettingsPickerRow<T>(
        title: segmented.title,
        subtitle: segmented.subtitle,
        icon: segmented.icon,
        showIcon: showIcons,
        controlBelow: segmented.controlBelow,
        selected: segmented.selected(settingsContext),
        options: <AdaptiveSettingsPickerOption<T>>[
          for (final SettingsSegmentOption<T> option in segmented.options)
            AdaptiveSettingsPickerOption<T>(
              value: option.value,
              label: option.label,
            ),
        ],
        onChanged: (T value) async {
          await segmented.dispatchChange(settingsContext, value);
          settingsContext.refresh();
        },
      );
    }
    return AdaptiveSettingsSegmentedRow<T>(
      title: segmented.title,
      subtitle: segmented.subtitle,
      icon: segmented.icon,
      showIcon: showIcons,
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
    if (slider.commitOnRelease) {
      return _CommitOnReleaseSlider(
        item: slider,
        settingsContext: settingsContext,
        showIcons: showIcons,
      );
    }
    final double value = slider.value(settingsContext);
    return AdaptiveSettingsSliderRow(
      title: slider.title,
      subtitle: slider.subtitle,
      icon: slider.icon,
      showIcon: showIcons,
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
      icon: stepper.icon,
      showIcon: showIcons,
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

  /// 文本项渲染复用 [SettingsSecretField] 内部（防抖/提交/遮蔽语义单一实现）。
  /// 写穿后不强制 refresh：输入框自持编辑态，重建反而无意义；需要联动的项在
  /// onChanged 里自行 refresh。
  Widget _text(SettingsTextItem text) {
    final String? reset = text.resetValue?.call(settingsContext);
    return SettingsSecretField(
      title: text.title,
      subtitle: text.subtitle,
      icon: text.icon,
      showIcon: showIcons,
      initialValue: text.value(settingsContext),
      obscureText: text.secret,
      revealToggle: text.secret,
      keyboardType: text.keyboardType ??
          (text.secret ? TextInputType.visiblePassword : TextInputType.text),
      hintText: text.placeholder,
      debounce: text.debounce,
      resetValue: reset,
      onReset: reset == null
          ? null
          : () async => text.onChanged(settingsContext, reset),
      onChanged: (String value) async => text.onChanged(settingsContext, value),
    );
  }

  /// 数字项渲染复用 [SettingsNumberField]；解析/夹取收在此处（widget 保持哑）：
  /// int/double 按 [SettingsNumberItem.integer] 解析，失败不写，越界夹到 min/max。
  Widget _number(SettingsNumberItem number) {
    final num? reset = number.resetValue?.call(settingsContext);
    String format(num value) =>
        number.integer ? value.toInt().toString() : value.toString();
    num clamp(num value) {
      num result = value;
      final num? min = number.min;
      final num? max = number.max;
      if (min != null && result < min) result = min;
      if (max != null && result > max) result = max;
      return result;
    }

    return SettingsNumberField(
      title: number.title,
      subtitle: number.subtitle,
      icon: number.icon,
      showIcon: showIcons,
      suffixText: number.suffixText,
      initialValue: format(number.value(settingsContext)),
      // 失焦回显真实存储值：写穿时越界被夹取（如 max 100 键入 9999 实存 100），
      // 输入框不再停留在未夹取的陈旧文本。
      committedText: () => format(number.value(settingsContext)),
      resetValue: reset == null ? null : format(reset),
      onReset: reset == null
          ? null
          : () async {
              await number.onChanged(settingsContext, clamp(reset));
              settingsContext.refresh();
            },
      onChanged: (String value) async {
        final num? parsed = number.integer
            ? int.tryParse(value.trim())
            : double.tryParse(value.trim());
        if (parsed == null) return;
        await number.onChanged(settingsContext, clamp(parsed));
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

/// [SettingsSliderItem.commitOnRelease] 滑条的渲染载体：拖动中的临时值放在与
/// 拖动 UI 同生命周期的本 State（滑块跟手、label/读数实时），不调 item.onChanged、
/// 不 refresh；松手（onChangeEnd）才把最终值经 item.onChanged 一次性提交。与
/// 界面大小滑条（settings_actions.dart 的 _AppUiScaleSliderRow）同款拖动解耦——
/// 逐 tick 写穿在重页面（如 ~6400 行视频页）会触发全页 rebuild 掉帧（BUG-963）。
/// 键盘/手柄步进经 _KeyboardSlider 同时回调 onChanged+onChangeEnd，每按即提交。
class _CommitOnReleaseSlider extends StatefulWidget {
  const _CommitOnReleaseSlider({
    required this.item,
    required this.settingsContext,
    required this.showIcons,
  });

  final SettingsSliderItem item;
  final SettingsContext settingsContext;
  final bool showIcons;

  @override
  State<_CommitOnReleaseSlider> createState() => _CommitOnReleaseSliderState();
}

class _CommitOnReleaseSliderState extends State<_CommitOnReleaseSlider> {
  /// 拖动进行中的临时值；非拖动时为 null，显示已提交的 item.value。
  double? _dragValue;

  /// 拖动活动序号：每次 onChanged 递增。onChangeEnd 的异步提交 await 期间用户
  /// 可能已开始新一轮拖动；提交回来只有序号未变（无新动作）才清 [_dragValue]，
  /// 否则会把进行中的新拖动瞬间弹回旧值。
  int _dragSession = 0;

  @override
  Widget build(BuildContext context) {
    final SettingsSliderItem item = widget.item;
    final double value = (_dragValue ?? item.value(widget.settingsContext))
        .clamp(item.min, item.max)
        .toDouble();
    return AdaptiveSettingsSliderRow(
      title: item.title,
      subtitle: item.subtitle,
      icon: item.icon,
      showIcon: widget.showIcons,
      value: value,
      min: item.min,
      max: item.max,
      divisions: item.divisions,
      label: item.label?.call(value),
      step: item.step,
      readout: item.titleReadout ? item.label?.call(value) : null,
      onChanged: (double next) {
        _dragSession++;
        setState(() => _dragValue = next);
      },
      onChangeEnd: (double next) async {
        final int session = _dragSession;
        await item.onChanged(widget.settingsContext, next);
        if (mounted && _dragSession == session) {
          setState(() => _dragValue = null);
        }
        widget.settingsContext.refresh();
      },
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
