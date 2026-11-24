import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart'
    show fushiAppleCompact;
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart'
    show fushiAppleMacScale;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// Apple 设计系统下的 Apple Music（iOS 27 / macOS 27）式裸字形按钮：静止时无底、
/// 无着色、无玻璃圆钮，只有一枚 label / secondaryLabel 色的 SF 字形；按下时字形
/// 缩小（[FushiPressScale]）、身后浮出一枚半透明圆形高亮，松手即淡出。
///
/// 只在 `isGlassDesign(context)` 为真的分支里用（M3E 分支走
/// `FushiIconButtonControl` / `FushiExpressivePlayButton` 的 M3E 外形）。使用方：
/// 音乐「正在播放」页 / 迷你条 / 队列面板，以及所有播放条共用的
/// `FushiExpressivePlayButton` 的 Apple 分支（经 [FushiApplePlayPauseButton]）。
///
/// 开关类（循环 / 随机 / 喜欢 / AB 循环 / 音效）的「开」不铺色块：[selected] 时
/// 字形换实心版（[FushiIcons.filled]）并提到 label 色，关时是 secondaryLabel 的
/// 描边版。[prominent]（上一首 / 播放 / 下一首）恒为 label 色实心字形；其余非开关
/// 按钮静止时按 [secondary] 取 secondaryLabel（Apple Music 底部那排工具图标）或
/// label。
///
/// 键盘 / 手柄可达：自带 [FocusableActionDetector]，Enter / 手柄 A
/// （[ActivateIntent]）触发 [onPressed]，键盘焦点时画一圈强调色焦点环；
/// [tooltip] 同时作悬停提示与无障碍名称。
class FushiAppleGlyphButton extends StatefulWidget {
  const FushiAppleGlyphButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.selected,
    this.prominent = false,
    this.secondary = true,
    this.glyphSize,
    this.extent,
    this.focusNode,
    this.autofocus = false,
  });

  /// 描边版字形；选中时自动换 [FushiIcons.filled]。
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 开关态；null = 不是开关（语义上不报 selected）。
  final bool? selected;

  /// 主操作（上一首 / 下一首 / 播放）：恒为 label 色的实心字形。
  final bool prominent;

  /// 非开关、非主操作的按钮静止时用 secondaryLabel（true）还是 label（false）。
  final bool secondary;

  /// 字形边长；null = Apple bar button 口径（桌面 18 × macOS 档缩放 / 移动 20）。
  final double? glyphSize;

  /// 命中区 / 按下高亮圆的直径；null = 桌面 36 × 缩放 / 移动 44。
  final double? extent;

  final FocusNode? focusNode;
  final bool autofocus;

  @override
  State<FushiAppleGlyphButton> createState() => _FushiAppleGlyphButtonState();
}

class _FushiAppleGlyphButtonState extends State<FushiAppleGlyphButton> {
  bool _pressed = false;
  bool _focusHighlight = false;

  bool get _enabled => widget.onPressed != null;

  void _setPressed(bool value) {
    if (_pressed == value || !mounted) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final FushiAppleColors apple = appleColorsOf(context);
    final bool compact = fushiAppleCompact(context);
    final double macScale = fushiAppleMacScale(context);
    final double glyphSize = widget.glyphSize ?? (compact ? 18 * macScale : 20);
    final double extent = widget.extent ?? (compact ? 36 * macScale : 44);
    final bool on = widget.selected ?? false;
    final bool filled = widget.prominent || on;
    final Color color = !_enabled
        ? apple.tertiaryLabel
        : (widget.prominent ||
                  on ||
                  (widget.selected == null && !widget.secondary)
              ? apple.label
              : apple.secondaryLabel);
    final IconData glyph = filled
        ? FushiIcons.filled(widget.icon)
        : widget.icon;
    final Widget icon = AnimatedSwitcher(
      duration: fushiMotionDuration(context, FushiMotion.short),
      switchInCurve: FushiMotion.standard,
      switchOutCurve: FushiMotion.exit,
      transitionBuilder: (Widget child, Animation<double> animation) =>
          FadeTransition(
            opacity: animation,
            child: ScaleTransition(scale: animation, child: child),
          ),
      child: FushiIcon(
        glyph,
        key: ValueKey<IconData>(glyph),
        size: glyphSize,
        color: color,
      ),
    );
    final Widget body = SizedBox.square(
      dimension: extent,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          // 按下高亮：只在按住时出现（按下立即出、松手按 short 淡出）。
          Positioned.fill(
            child: AnimatedOpacity(
              duration: _pressed
                  ? Duration.zero
                  : fushiMotionDuration(context, FushiMotion.short),
              opacity: _pressed ? 1 : 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: apple.label.withValues(alpha: 0.14),
                ),
              ),
            ),
          ),
          if (_focusHighlight)
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: apple.accent, width: 2),
                ),
              ),
            ),
          icon,
        ],
      ),
    );
    // 语义边界放在最外层：按钮自成一个节点（与 Material 按钮同形），内层
    // Focus 的可聚焦 / 聚焦动作与手势的点按动作都并进这个节点；不设 container
    // 时这些配置会沿父链漂到相邻控件或路由节点上。
    return Semantics(
      container: true,
      button: true,
      enabled: _enabled,
      selected: widget.selected,
      label: widget.tooltip,
      child: FushiTooltip(
        message: widget.tooltip,
        excludeFromSemantics: true,
        child: FocusableActionDetector(
          enabled: _enabled,
          focusNode: widget.focusNode,
          autofocus: widget.autofocus,
          mouseCursor: _enabled ? SystemMouseCursors.click : MouseCursor.defer,
          actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (ActivateIntent intent) {
                widget.onPressed?.call();
                return null;
              },
            ),
          },
          onShowFocusHighlight: (bool value) =>
              setState(() => _focusHighlight = value),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _enabled ? (_) => _setPressed(true) : null,
            onTapUp: _enabled ? (_) => _setPressed(false) : null,
            onTapCancel: _enabled ? () => _setPressed(false) : null,
            onTap: widget.onPressed,
            child: FushiPressScale(enabled: _enabled, scale: 0.86, child: body),
          ),
        ),
      ),
    );
  }
}

/// Apple Music 式播放 / 暂停键：无底、无着色的大号实心字形（play.fill /
/// pause.fill，label 色），按下缩小 + 身后半透明圆高亮；两态之间字形交叉淡入 +
/// 缩放（[FushiAppleGlyphButton] 里的 [AnimatedSwitcher]，时长取动效令牌）。
class FushiApplePlayPauseButton extends StatelessWidget {
  const FushiApplePlayPauseButton({
    super.key,
    required this.isPlaying,
    required this.tooltip,
    required this.onPressed,
    required this.glyphSize,
    required this.extent,
  });

  final bool isPlaying;
  final String tooltip;
  final VoidCallback? onPressed;
  final double glyphSize;
  final double extent;

  @override
  Widget build(BuildContext context) => FushiAppleGlyphButton(
    icon: isPlaying ? FushiIcons.pause : FushiIcons.play,
    tooltip: tooltip,
    onPressed: onPressed,
    prominent: true,
    glyphSize: glyphSize,
    extent: extent,
  );
}
