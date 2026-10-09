import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoIcons;
import 'package:material_ui/material_ui.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/audiobook/audiobook_speed_slider.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_glass_surface.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';

// 歌词模式倍速面板（2026-10-05，用户：「倍数可以设成跟普通的阅读模式一样，直接
// 拖动拉条，自己调更好些」）。
//
// 倍速按钮点开的锚定小面板，核心就是普通阅读模式快捷设置里那条
// [AudiobookSpeedSlider]——同一组件、同一范围 / 吸附 / 步进、回调同一个
// `AudiobookPlayerController.setSpeed`（生效 + 持久化），拖动实时生效。外观按
// 设计系统分两套：MD3 是 M3 对话框色阶的大圆角面 + tonal 复位键；Apple 是
// 深色档玻璃面 + 无底胶囊复位键。表面一律走 [FushiGlassSurface]（玻璃关闭时就是
// 实心底），进出场走 [FushiMotion]（墨水屏 / 减弱动态效果归零）。
//
// 键盘 / 手柄：面板打开即把焦点交给拖动条，←/→（D-pad 左右）按 0.05× 一档调，
// Tab 到复位键 Enter 复位，Esc / 手柄 B / 点面板外关闭，焦点回到倍速按钮。

/// 面板宽度（窄屏再按屏宽收窄）。
const double _kPanelWidth = 320;

/// 面板与倍速按钮之间的间隙。
const double _kAnchorGap = 10;

/// 面板离屏幕边缘的最小留白。
const double _kScreenMargin = 12;

/// 面板里拖动条的 key（测试与焦点驱动集成测试用）。
const ValueKey<String> kLyricsSpeedPanelKey = ValueKey<String>(
  'lyrics_speed_panel',
);

/// 面板里复位键的 key。
const ValueKey<String> kLyricsSpeedPanelResetKey = ValueKey<String>(
  'lyrics_speed_panel_reset',
);

/// 倍速读数：`1.0×` / `1.25×` / `0.75×`（至少一位小数，最多两位）。
String formatLyricsSpeed(double speed) {
  String s = speed.toStringAsFixed(2);
  while (s.endsWith('0') && !s.endsWith('.0')) {
    s = s.substring(0, s.length - 1);
  }
  return '$s×';
}

/// 从 [anchorContext]（倍速按钮）弹出倍速面板。[onChanged] 每次拖动 / 按键都会
/// 收到吸附后的新倍速（实时生效）；面板关闭时 Future 完成。
Future<void> showLyricsSpeedPanel({
  required BuildContext anchorContext,
  required double speed,
  required ValueChanged<double> onChanged,
}) {
  return showLyricsAnchoredPanel(
    anchorContext: anchorContext,
    builder: (BuildContext context) =>
        LyricsSpeedPanel(speed: speed, onChanged: onChanged),
  );
}

/// 从 [anchorContext]（覆盖层控件条上的按钮）弹出一块锚定小面板：优先在按钮
/// 上方，放不下翻到下方；主题沿用按钮所在的歌词模式主题。倍速面板与「Aa」文字
/// 面板共用。面板关闭时 Future 完成。
Future<void> showLyricsAnchoredPanel({
  required BuildContext anchorContext,
  required WidgetBuilder builder,
}) {
  final NavigatorState navigator = Navigator.of(anchorContext);
  final RenderObject? button = anchorContext.findRenderObject();
  final RenderObject? overlay = navigator.overlay?.context.findRenderObject();
  if (button is! RenderBox || overlay is! RenderBox || !button.hasSize) {
    return Future<void>.value();
  }
  final Rect anchor = Rect.fromPoints(
    button.localToGlobal(Offset.zero, ancestor: overlay),
    button.localToGlobal(
      button.size.bottomRight(Offset.zero),
      ancestor: overlay,
    ),
  );
  // 覆盖层外壳给歌词页换了封面取色的 ColorScheme（Apple 还套了深色档），
  // 弹到 Navigator 层后要原样带过去，面板才与按钮同一套配色。
  final CapturedThemes themes = InheritedTheme.capture(
    from: anchorContext,
    to: navigator.context,
  );
  return navigator.push<void>(
    _LyricsSpeedPanelRoute(
      anchor: anchor,
      themes: themes,
      builder: builder,
      barrierLabel: MaterialLocalizations.of(
        anchorContext,
      ).modalBarrierDismissLabel,
      enterDuration: fushiMotionDuration(anchorContext, FushiMotion.medium),
      exitDuration: fushiMotionDuration(anchorContext, FushiMotion.short),
    ),
  );
}

class _LyricsSpeedPanelRoute extends PopupRoute<void> {
  _LyricsSpeedPanelRoute({
    required this.anchor,
    required this.themes,
    required this.builder,
    required this.barrierLabel,
    required this.enterDuration,
    required this.exitDuration,
  });

  final Rect anchor;
  final CapturedThemes themes;
  final WidgetBuilder builder;
  final Duration enterDuration;
  final Duration exitDuration;

  @override
  final String barrierLabel;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => enterDuration;

  @override
  Duration get reverseTransitionDuration => exitDuration;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final EdgeInsets padding = MediaQuery.paddingOf(context);
    return themes.wrap(
      CustomSingleChildLayout(
        delegate: _AnchoredPanelLayout(anchor: anchor, padding: padding),
        child: _AnimatedPanel(
          animation: animation,
          anchor: anchor,
          child: Builder(builder: builder),
        ),
      ),
    );
  }
}

/// 面板优先放在按钮上方（控制条都在屏幕下半），放不下才翻到下方；水平居中于
/// 按钮并夹进屏幕留白。
class _AnchoredPanelLayout extends SingleChildLayoutDelegate {
  const _AnchoredPanelLayout({required this.anchor, required this.padding});

  final Rect anchor;
  final EdgeInsets padding;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final double width = math.max(
      0,
      math.min(_kPanelWidth, constraints.maxWidth - 2 * _kScreenMargin),
    );
    return BoxConstraints.tightFor(width: width).copyWith(
      maxHeight: math.max(
        0,
        constraints.maxHeight - padding.vertical - 2 * _kScreenMargin,
      ),
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final double left = (anchor.center.dx - childSize.width / 2).clamp(
      _kScreenMargin,
      math.max(_kScreenMargin, size.width - childSize.width - _kScreenMargin),
    );
    final double above = anchor.top - _kAnchorGap - childSize.height;
    final double minTop = padding.top + _kScreenMargin;
    final double top = above >= minTop
        ? above
        : math.min(
            anchor.bottom + _kAnchorGap,
            size.height - padding.bottom - _kScreenMargin - childSize.height,
          );
    return Offset(left, math.max(minTop, top));
  }

  @override
  bool shouldRelayout(_AnchoredPanelLayout oldDelegate) =>
      anchor != oldDelegate.anchor || padding != oldDelegate.padding;
}

/// 进场：淡入 + 从按钮方向轻微放大（快进慢出，退出走加速曲线）。
class _AnimatedPanel extends StatelessWidget {
  const _AnimatedPanel({
    required this.animation,
    required this.anchor,
    required this.child,
  });

  final Animation<double> animation;
  final Rect anchor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final CurvedAnimation curved = CurvedAnimation(
      parent: animation,
      curve: FushiMotion.enter,
      reverseCurve: FushiMotion.exit,
    );
    // 放大原点朝向按钮：面板在按钮上方时从底边长出，否则从顶边。
    final bool above = anchor.center.dy > MediaQuery.sizeOf(context).height / 2;
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        alignment: above ? Alignment.bottomCenter : Alignment.topCenter,
        scale: Tween<double>(begin: 0.9, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

/// 倍速面板本体（两套设计系统共用骨架，表面与复位键按设计系统分派）。公开
/// 是为了让行为测试直接 pump。
class LyricsSpeedPanel extends StatefulWidget {
  const LyricsSpeedPanel({
    required this.speed,
    required this.onChanged,
    super.key,
  });

  /// 打开时的倍速。
  final double speed;

  /// 吸附后的新倍速（实时）。
  final ValueChanged<double> onChanged;

  @override
  State<LyricsSpeedPanel> createState() => _LyricsSpeedPanelState();
}

class _LyricsSpeedPanelState extends State<LyricsSpeedPanel> {
  late double _speed = widget.speed;

  void _set(double value) {
    final double snapped = AudiobookSpeedSlider.snap(value);
    if ((snapped - _speed).abs() < 0.001) return;
    setState(() => _speed = snapped);
    widget.onChanged(snapped);
  }

  @override
  Widget build(BuildContext context) {
    final bool apple = isGlassDesign(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final FushiAppleColors? appleColors = apple ? appleColorsOf(context) : null;
    final Color labelColor = appleColors?.label ?? cs.onSurface;
    final Color secondaryColor =
        appleColors?.secondaryLabel ?? cs.onSurfaceVariant;
    final Color readoutColor = appleColors?.label ?? cs.primary;
    final BorderRadius radius = apple
        ? const BorderRadius.all(Radius.circular(26))
        : FushiBorderRadius.dialog;
    const List<FontFeature> tabular = <FontFeature>[
      FontFeature.tabularFigures(),
    ];
    final TextStyle? endStyle = theme.textTheme.labelSmall?.copyWith(
      color: secondaryColor,
      fontFeatures: tabular,
    );

    final Widget body = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                apple ? CupertinoIcons.speedometer : Icons.speed_rounded,
                size: 20,
                color: secondaryColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  t.playback_speed,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: labelColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                formatLyricsSpeed(_speed),
                style:
                    (apple
                            ? theme.textTheme.titleLarge
                            : theme.textTheme.headlineSmall)
                        ?.copyWith(
                          color: readoutColor,
                          fontWeight: FontWeight.w700,
                          fontFeatures: tabular,
                        ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          AudiobookSpeedSlider(
            key: kLyricsSpeedPanelKey,
            speed: _speed,
            autofocus: true,
            onChanged: _set,
          ),
          Row(
            children: <Widget>[
              Text(
                formatLyricsSpeed(AudiobookSpeedSlider.minSpeed),
                style: endStyle,
              ),
              const Spacer(),
              _ResetButton(
                apple: apple,
                enabled: (_speed - 1.0).abs() >= 0.001,
                onPressed: () => _set(1),
              ),
              const Spacer(),
              Text(
                formatLyricsSpeed(AudiobookSpeedSlider.maxSpeed),
                style: endStyle,
              ),
            ],
          ),
        ],
      ),
    );

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: t.playback_speed,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: apple ? 0.32 : 0.18),
              blurRadius: apple ? 28 : 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: FushiGlassSurface(
          borderRadius: radius,
          // MD3 取令牌默认面（M3 对话框色阶）；Apple 取深色档分组底。
          baseColor: appleColors?.secondaryGroupedBackground,
          child: Material(type: MaterialType.transparency, child: body),
        ),
      ),
    );
  }
}

/// 复位到 1.0×：MD3 tonal 键 / Apple 无底胶囊键，两套都带按压缩放。
class _ResetButton extends StatelessWidget {
  const _ResetButton({
    required this.apple,
    required this.enabled,
    required this.onPressed,
  });

  final bool apple;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final String label = formatLyricsSpeed(1);
    final Widget button;
    if (apple) {
      final FushiAppleColors colors = appleColorsOf(context);
      button = FushiPlainButton(
        key: kLyricsSpeedPanelResetKey,
        semanticLabel: '${t.av_sync_reset} $label',
        borderRadius: const BorderRadius.all(Radius.circular(15)),
        fill: colors.tertiaryFill,
        onPressed: enabled ? onPressed : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: <Widget>[
              Icon(
                CupertinoIcons.arrow_counterclockwise,
                size: 15,
                color: enabled ? colors.accent : colors.tertiaryLabel,
              ),
              Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: enabled ? colors.label : colors.tertiaryLabel,
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      button = Tooltip(
        message: t.av_sync_reset,
        child: FushiFilledButton.tonalIcon(
          key: kLyricsSpeedPanelResetKey,
          onPressed: enabled ? onPressed : null,
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: Text(label),
        ),
      );
    }
    return FushiPressScale(enabled: enabled, child: button);
  }
}
