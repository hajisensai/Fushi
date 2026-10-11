import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';

/// M3E 分段选择器（Material 设计系统）：一条扁平的 tonal 胶囊轨道，选中段是
/// 一枚 primary 实底小胶囊（见 [fushiPillSegmentSelectedFill]）——与浏览页「书架 / 漫画 / 游戏 / 视频」的二级
/// 页签（`LibrarySectionTabs(floating: true, secondary: true)`）同一形态。
///
/// 2026-10-09 用户截图：设置里「深色模式」的三图标分段是 Material 2 式的描边
/// 分段按钮，与浏览页的胶囊页签两种风格。统一取胶囊页签这一种：M3E 的分段 /
/// 页签都是「轨道 + 选中胶囊」，没有描边分隔线；每段的悬停 / 按下 state layer
/// 与命中区就是那枚胶囊（与选中胶囊同形同大）。
///
/// 继承 [SegmentedButton] 只为让既有调用点、焦点 / 无障碍判据与测试
/// （`widget is SegmentedButton`）照常识别它是分段按钮；渲染完全由本类负责。
///
/// [style] 只为签名兼容而接收、**不参与渲染**：调用方传的都是 Material
/// 分段的密度 / 命中区（`kSettingsSegmentedStyle` = compact + shrinkWrap），
/// 胶囊分段本身就是紧凑几何（段高 [segmentHeight] = 36，低于 Material 分段默认
/// 40），与浏览页二级页签同形，不随调用方的 Material 密度再缩。估宽见
/// `SegmentedStripMetrics.pill`（settings_shared.dart），与这里的几何常量同源。
class FushiPillSegmentedButton<T> extends SegmentedButton<T> {
  const FushiPillSegmentedButton({
    required super.segments,
    required super.selected,
    super.onSelectionChanged,
    super.multiSelectionEnabled,
    super.emptySelectionAllowed,
    super.style,
    super.key,
  }) : super(showSelectedIcon: false);

  /// 段高（与浏览页二级页签同高）。
  static const double segmentHeight = 36;

  /// 轨道内边距（与二级页签胶囊框同值）。
  static const double trackPadding = 4;

  /// 段的左右内边距：文字段 / 纯图标段。
  static const double labelPadding = 16;
  static const double iconOnlyPadding = 12;

  /// 段内图标尺寸与「图标 + 文字」段的图标 / 文字间距。
  static const double iconSize = 18;
  static const double iconLabelGap = 8;

  @override
  State<SegmentedButton<T>> createState() =>
      _FushiPillSegmentedButtonState<T>();
}

class _FushiPillSegmentedButtonState<T> extends State<SegmentedButton<T>> {
  FushiPillSegmentedButton<T> get _w => widget as FushiPillSegmentedButton<T>;

  void _toggle(T value) {
    final ValueChanged<Set<T>>? changed = _w.onSelectionChanged;
    if (changed == null) return;
    final Set<T> current = _w.selected;
    if (!_w.multiSelectionEnabled) {
      if (current.contains(value)) {
        if (_w.emptySelectionAllowed) changed(<T>{});
        return;
      }
      changed(<T>{value});
      return;
    }
    final Set<T> next = Set<T>.of(current);
    if (next.contains(value)) {
      if (next.length == 1 && !_w.emptySelectionAllowed) return;
      next.remove(value);
    } else {
      next.add(value);
    }
    changed(next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final bool eink = isEinkTheme(context);
    final Duration duration = fushiMotionDuration(context, FushiMotion.short);
    final TextStyle base = (theme.textTheme.labelLarge ?? const TextStyle())
        .copyWith(height: 1.2);

    Widget segment(ButtonSegment<T> s) {
      final bool on = _w.selected.contains(s.value);
      final bool enabled = s.enabled && _w.onSelectionChanged != null;
      final Color fg = !enabled
          ? cs.onSurface.withValues(alpha: 0.38)
          : on
          ? fushiPillSegmentSelectedForeground(cs, eink: eink)
          : cs.onSurfaceVariant;
      final bool iconOnly = s.label == null;
      final Widget content = IconTheme.merge(
        data: IconThemeData(
          color: fg,
          size: FushiPillSegmentedButton.iconSize,
        ),
        child: DefaultTextStyle.merge(
          style: base.copyWith(
            color: fg,
            fontWeight: on ? FontWeight.w700 : FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (s.icon != null) s.icon!,
              if (s.icon != null && s.label != null)
                const SizedBox(width: FushiPillSegmentedButton.iconLabelGap),
              if (s.label != null) Flexible(child: s.label!),
            ],
          ),
        ),
      );
      const ShapeBorder pill = StadiumBorder();
      Widget body = AnimatedContainer(
        duration: duration,
        curve: FushiMotion.standard,
        height: FushiPillSegmentedButton.segmentHeight,
        padding: EdgeInsets.symmetric(
          horizontal: iconOnly
              ? FushiPillSegmentedButton.iconOnlyPadding
              : FushiPillSegmentedButton.labelPadding,
        ),
        alignment: Alignment.center,
        decoration: ShapeDecoration(
          color: on
              ? fushiPillSegmentSelectedFill(cs, eink: eink)
              : fushiPillSegmentSelectedFill(
                  cs,
                  eink: eink,
                ).withValues(alpha: 0),
          shape: StadiumBorder(side: BorderSide.none),
        ),
        child: content,
      );
      body = Material(
        type: MaterialType.transparency,
        shape: pill,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: pill,
          onTap: enabled ? () => _toggle(s.value) : null,
          child: body,
        ),
      );
      body = Semantics(
        button: true,
        selected: on,
        enabled: enabled,
        inMutuallyExclusiveGroup: !_w.multiSelectionEnabled,
        child: body,
      );
      final String? tip = s.tooltip;
      if (tip != null && tip.isNotEmpty) {
        body = FushiTooltip(message: tip, child: body);
      }
      return body;
    }

    return DecoratedBox(
      decoration: ShapeDecoration(
        // 轨道 = surfaceContainerHigh（设计令牌的 search 面，与浏览页二级页签
        // 胶囊框同一角色）。
        color: FushiDesignTokens.of(context).surfaces.search,
        shape: StadiumBorder(
          side: eink ? BorderSide(color: cs.outline) : BorderSide.none,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(FushiPillSegmentedButton.trackPadding),
        // 各段等宽（取最宽段，与 Material SegmentedButton 同一约定）：选中胶囊
        // 在段间切换时宽度不跳。
        child: IntrinsicWidth(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (final ButtonSegment<T> s in _w.segments)
                Expanded(child: segment(s)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中段的填充色。
///
/// 2026-10-09 审查：最初取 secondaryContainer（与浏览页二级页签同色），但它和
/// surfaceContainerHigh 轨道在 M3 色调上只差几档（亮色 tone 90 vs 92），选中
/// 与未选中几乎分不出来，所有设置分段都受影响。改取 primary：与轨道至少相差
/// 一半色调区间，亮 / 暗、任意种子色下都满足 WCAG 非文本 3:1（测试按多种子
/// 实测）。墨水屏用 onSurface 实底（灰阶下也是最强对比）。
Color fushiPillSegmentSelectedFill(ColorScheme cs, {bool eink = false}) =>
    eink ? cs.onSurface : cs.primary;

/// 选中段的图标 / 文字色（与 [fushiPillSegmentSelectedFill] 配对的 on- 色）。
Color fushiPillSegmentSelectedForeground(ColorScheme cs, {bool eink = false}) =>
    eink ? cs.surface : cs.onPrimary;
