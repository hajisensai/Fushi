import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/video_apple_chrome.dart';
import 'package:fushi/src/media/video/video_chrome_colors.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

const Key videoVolumePopoverFrameKey = ValueKey<String>(
  'video-volume-popover-frame',
);
const Key videoSpeedPopoverFrameKey = ValueKey<String>(
  'video-speed-popover-frame',
);
const Key videoSpeedPopoverReadoutKey = ValueKey<String>(
  'video-speed-popover-readout',
);
const Key videoVolumePopoverSliderKey = ValueKey<String>(
  'video-volume-popover-slider',
);
const Key videoVolumeHudFrameKey = ValueKey<String>('video-volume-hud-frame');
const Key videoVolumeHudProgressKey = ValueKey<String>(
  'video-volume-hud-progress',
);
const Key videoBrightnessHudFrameKey = ValueKey<String>(
  'video-brightness-hud-frame',
);
const Key videoBrightnessHudProgressKey = ValueKey<String>(
  'video-brightness-hud-progress',
);

/// 播放器控件轻浮层（音量 / 倍速）的外框——两个浮层共用的**唯一**表面，按设计
/// 系统分派（反馈 DYSX-jy-6K「音量控制仍为 MD2 样式」）：
///
/// - Apple：深色液态玻璃（[VideoGlassHud]，与音量 / 亮度 HUD、跳转提示同一种），
///   里面白字白图标；
/// - MD3E：与悬浮胶囊同一无色相中性表面（[m3eSurfaceColor]，调用方按页面主题取
///   `videoM3eFloatingColor`），M3 菜单圆角 + 投影；
/// - 墨水屏 / 没给中性色：实底档 surfaceContainerHighest。
///
/// [frameKey] 挂在外框上，宽 = [width]（真实渲染测试量它，而不是全屏 barrier）。
///
/// 外框同时**向内容提供与自身底色匹配的主题**：Apple 玻璃恒深色，内容包进
/// [FushiAppleDarkTier]（浅色 app 里也是深色档，设计系统组件自动取白字 / 深色档
/// 强调色）；MD3E / 墨水屏把 [colorScheme] 设为内容的主题配色。内容不自己读页面
/// 主题、不写死颜色，读数 / 图标一律取 [foregroundOf] / [accentOf]（在外框**内**
/// 的 context 上调用）——此前倍速读数写死页面 `onSurface`，Apple 浅色主题下黑字压
/// 深色玻璃看不清。
class VideoControlPopoverFrame extends StatelessWidget {
  const VideoControlPopoverFrame({
    super.key,
    required this.width,
    required this.padding,
    required this.colorScheme,
    required this.child,
    this.m3eSurfaceColor,
    this.frameKey,
  });

  final double width;
  final EdgeInsets padding;
  final ColorScheme colorScheme;
  final Color? m3eSurfaceColor;
  final Key? frameKey;
  final Widget child;

  /// 浮层内文字（读数 / 百分比）的前景：Apple 取深色档 label，MD3E / 墨水屏取
  /// 外框配色的 onSurface。[context] 必须在外框内部。
  static Color foregroundOf(BuildContext context) => videoAppleChrome(context)
      ? appleColorsOf(context).label
      : Theme.of(context).colorScheme.onSurface;

  /// 浮层内图标的颜色：Apple 与前景同一 label（AVKit 播放控件不上强调色），
  /// MD3E / 墨水屏取外框配色的 primary。[context] 必须在外框内部。
  static Color accentOf(BuildContext context) => videoAppleChrome(context)
      ? appleColorsOf(context).label
      : Theme.of(context).colorScheme.primary;

  /// 外框整块是命中面（BUG-4226）：浮层压在进度条 / 控制条之上，落在外框内、却
  /// 不在任何控件上的点按（内边距、控件间缝、百分比读数旁）必须被外框吃掉，不能
  /// 下穿。Apple 玻璃底是 [VideoGlassSurface] 里的 `IgnorePointer` 兄弟层，内容
  /// Row 的缝不命中，点按一路落到下面的 dismiss 层（translucent）与进度条的
  /// 原始 Listener——点浮层空白处 = 关浮层 + 跳进度。MD3E 的 [DecoratedBox] 本就
  /// 按装饰命中；两套统一由外框声明，不依赖底色的实现细节。
  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      child: _buildSurface(context),
    );
  }

  Widget _buildSurface(BuildContext context) {
    if (videoAppleChrome(context)) {
      return SizedBox(
        key: frameKey,
        width: width,
        child: VideoGlassHud(
          padding: padding,
          radius: FushiRadii.menuValue,
          child: FushiAppleDarkTier(child: child),
        ),
      );
    }
    final bool eink = isEinkTheme(context);
    final Color surface = !eink && m3eSurfaceColor != null
        ? m3eSurfaceColor!
        : colorScheme.surfaceContainerHighest.withValues(
            alpha: kVideoOverlaySolidAlpha,
          );
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        key: frameKey,
        decoration: BoxDecoration(
          color: surface,
          borderRadius: FushiBorderRadius.menu,
          border: Border.all(
            color: colorScheme.outlineVariant.withValues(alpha: 0.7),
          ),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: colorScheme.shadow.withValues(alpha: 0.28),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: ConstrainedBox(
          constraints: BoxConstraints.tightFor(width: width),
          child: Padding(
            padding: padding,
            child: Theme(
              data: Theme.of(context).copyWith(colorScheme: colorScheme),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 浮层内「按住」状态上报（BUG-4226）：有指针在浮层里按下时报 `true`，最后一个
/// 指针抬起 / 取消时报 `false`。
///
/// 控制条的自动隐藏只靠 hover 续命：桌面 media_kit 的 MouseRegion 与浮层自己的
/// hover keep-alive 都只收 [PointerHoverEvent]，按住拖滑条时发的是
/// [PointerMoveEvent]，没有任何东西重置隐藏计时 → 拖音量 / 倍速滑条到一半控制条
/// 淡出、浮层随之关掉。宿主据此在按住期间「按住控制条」（fork `holdVisible`），
/// 与 hover 续命是两条独立的输入通道。
///
/// 只旁听原始指针事件（[HitTestBehavior.translucent]），不改命中、不进手势竞技。
/// 浮层在按住期间被关掉（Esc / 控制条被门控收起）时本组件随之卸载、收不到抬起，
/// 宿主必须在关浮层时自己清掉按住状态。
class VideoControlPopoverPressHold extends StatefulWidget {
  const VideoControlPopoverPressHold({
    super.key,
    required this.onPressedChanged,
    required this.child,
  });

  final ValueChanged<bool> onPressedChanged;
  final Widget child;

  @override
  State<VideoControlPopoverPressHold> createState() =>
      _VideoControlPopoverPressHoldState();
}

class _VideoControlPopoverPressHoldState
    extends State<VideoControlPopoverPressHold> {
  final Set<int> _pointers = <int>{};

  void _down(PointerDownEvent event) {
    final bool wasPressed = _pointers.isNotEmpty;
    _pointers.add(event.pointer);
    if (!wasPressed) widget.onPressedChanged(true);
  }

  void _release(PointerEvent event) {
    if (!_pointers.remove(event.pointer)) return;
    if (_pointers.isEmpty) widget.onPressedChanged(false);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerUp: _release,
      onPointerCancel: _release,
      child: widget.child,
    );
  }
}

/// 音量轻浮层：静音键 + 滑条 + 百分比。
///
/// 滑条不再用 `RoundSliderThumbShape` + 3px 细轨覆写主题（那是 MD2 / 2023 版
/// 的圆钮细轨，反馈 DYSX-jy-6K）：MD3E 下沿用主题的 2024 版滑块（粗轨道 + 竖条
/// 把手 + 缝 + 停止点），只把轨道粗细与把手高度按播放器界面缩放折进浮层行高；
/// Apple 下 [FushiSlider] 本就是 iOS 滑块；墨水屏保留细轨圆钮（主题刻意留 2023
/// 版，缝与停止点在低分辨率面板上会糊）。
class VideoVolumePopoverCard extends StatelessWidget {
  const VideoVolumePopoverCard({
    super.key,
    required this.width,
    required this.value,
    required this.uiScale,
    required this.colorScheme,
    required this.icon,
    required this.tooltip,
    required this.onToggleMute,
    required this.onChanged,
    this.maximum = 100.0,
    this.m3eSurfaceColor,
    this.frameKey = videoVolumePopoverFrameKey,
    this.sliderKey = videoVolumePopoverSliderKey,
  });

  final double width;
  final double value;

  /// 滑条上限（百分比）：音量上限设置（100 / 150 / 200），超过 100 即放大。
  final double maximum;
  final double uiScale;
  final ColorScheme colorScheme;

  /// MD3E 浮层底色（见 [VideoControlPopoverFrame.m3eSurfaceColor]）。
  final Color? m3eSurfaceColor;
  final IconData icon;
  final String tooltip;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onChanged;
  final Key frameKey;
  final Key sliderKey;

  /// M3E XS 滑块的轨道粗细（`fushiSliderMetrics(FushiSliderSize.xs)`），按界面缩放。
  static const double _kM3eTrackHeight = 16;

  @override
  Widget build(BuildContext context) {
    final double scale = math.max(0.1, uiScale);
    final double max = math.max(100.0, maximum);
    final double clamped = value.clamp(0.0, max).toDouble();
    final double controlHeight = 40 * scale;
    final bool eink = isEinkTheme(context);
    final SliderThemeData base = SliderTheme.of(context);
    final SliderThemeData sliderTheme = eink
        ? base.copyWith(
            trackHeight: 3.0 * scale,
            thumbShape: RoundSliderThumbShape(enabledThumbRadius: 7.0 * scale),
            overlayShape: RoundSliderOverlayShape(overlayRadius: 14.0 * scale),
          )
        : base.copyWith(
            trackHeight: _kM3eTrackHeight * scale,
            // 2024 版竖条把手：宽 4（按下 2），高贴满浮层行高。
            thumbSize: WidgetStateProperty.resolveWith<Size?>(
              (Set<WidgetState> states) => Size(
                states.contains(WidgetState.pressed) ||
                        states.contains(WidgetState.dragged)
                    ? 2
                    : 4,
                controlHeight,
              ),
            ),
          );
    return VideoControlPopoverFrame(
      frameKey: frameKey,
      width: width,
      padding: EdgeInsets.all(8 * scale),
      colorScheme: colorScheme,
      m3eSurfaceColor: m3eSurfaceColor,
      // 前景在外框内取（外框按设计系统提供匹配底色的主题）。
      child: Builder(
        builder: (BuildContext inner) => SizedBox(
          height: controlHeight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiTooltip(
                message: tooltip,
                child: FushiIconButtonControl(
                  icon: FushiIcon(icon),
                  iconSize: 20 * scale,
                  color: VideoControlPopoverFrame.accentOf(inner),
                  padding: EdgeInsets.zero,
                  constraints: BoxConstraints.tightFor(
                    width: controlHeight,
                    height: controlHeight,
                  ),
                  onPressed: onToggleMute,
                ),
              ),
              SizedBox(width: 4 * scale),
              Expanded(
                child: SizedBox(
                  height: controlHeight,
                  child: SliderTheme(
                    data: sliderTheme,
                    child: FushiSlider(
                      key: sliderKey,
                      value: clamped,
                      min: 0,
                      max: max,
                      onChanged: onChanged,
                    ),
                  ),
                ),
              ),
              SizedBox(width: 6 * scale),
              Text(
                '${clamped.round()}%',
                style: TextStyle(
                  color: VideoControlPopoverFrame.foregroundOf(inner),
                  fontSize: 12 * scale,
                  fontWeight: FontWeight.w600,
                  // 百分比随拖动逐帧变化：等宽数字。
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 倍速轻浮层：图标 + 当前倍速读数 + 1.0x 复位 + 0.5x–2.0x 滑条。
///
/// 外框与音量浮层同一个 [VideoControlPopoverFrame]；读数 / 图标颜色在外框内取
/// [VideoControlPopoverFrame.foregroundOf] / [VideoControlPopoverFrame.accentOf]，
/// 文字按钮与滑条读外框提供的主题。吸附到预设档由调用方在 [onChanged] 里做。
class VideoSpeedPopoverCard extends StatelessWidget {
  const VideoSpeedPopoverCard({
    super.key,
    required this.width,
    required this.speed,
    required this.uiScale,
    required this.colorScheme,
    required this.icon,
    required this.onReset,
    required this.onChanged,
    this.divisions,
    this.m3eSurfaceColor,
    this.frameKey = videoSpeedPopoverFrameKey,
  });

  final double width;

  /// 当前播放倍速（读数原值；滑条夹到 0.5–2.0）。
  final double speed;
  final double uiScale;
  final ColorScheme colorScheme;

  /// 滑条分段数（预设档数 - 1）；null = 连续。
  final int? divisions;

  /// MD3E 浮层底色（见 [VideoControlPopoverFrame.m3eSurfaceColor]）。
  final Color? m3eSurfaceColor;

  /// 读数前的倍速图标（调用方给，与底栏倍速键同一字形）。
  final IconData icon;
  final VoidCallback onReset;
  final ValueChanged<double> onChanged;
  final Key frameKey;

  @override
  Widget build(BuildContext context) {
    final double scale = math.max(0.1, uiScale);
    final double sliderValue = speed.clamp(0.5, 2.0).toDouble();
    final String readout = '${speed.toStringAsFixed(1)}x';
    return VideoControlPopoverFrame(
      frameKey: frameKey,
      width: width,
      padding: EdgeInsets.all(10 * scale),
      colorScheme: colorScheme,
      m3eSurfaceColor: m3eSurfaceColor,
      child: Builder(
        builder: (BuildContext inner) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                FushiIcon(
                  icon,
                  color: VideoControlPopoverFrame.accentOf(inner),
                  size: 20 * scale,
                ),
                SizedBox(width: 8 * scale),
                Expanded(
                  child: Text(
                    readout,
                    key: videoSpeedPopoverReadoutKey,
                    style: TextStyle(
                      color: VideoControlPopoverFrame.foregroundOf(inner),
                      fontSize: 14 * scale,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                FushiTextButton(onPressed: onReset, child: const Text('1.0x')),
              ],
            ),
            FushiSlider(
              value: sliderValue,
              min: 0.5,
              max: 2.0,
              divisions: divisions,
              label: readout,
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class VideoLevelHudCard extends StatelessWidget {
  const VideoLevelHudCard({
    super.key,
    required this.value,
    required this.uiScale,
    required this.icon,
    required this.alignment,
    required this.minimum,
    required this.surfaceColor,
    required this.textColor,
    required this.shadowColor,
    required this.frameKey,
    required this.progressKey,
    this.maximum = 100.0,
  });

  final double value;

  /// 电平满格对应的值：亮度恒 100；音量是音量上限（150 / 200 时 100% 不再满格，
  /// 数字照实显示放大后的百分比）。
  final double maximum;
  final double uiScale;
  final IconData icon;
  final AlignmentGeometry alignment;
  final EdgeInsets minimum;
  final Color surfaceColor;
  final Color textColor;
  final Color shadowColor;
  final Key frameKey;
  final Key progressKey;

  @override
  Widget build(BuildContext context) {
    final double scale = math.max(0.1, uiScale);
    final double max = math.max(100.0, maximum);
    final double clamped = value.clamp(0.0, max).toDouble();
    final double rowHeight = 24 * scale;
    final double progressHeight = 4 * scale;
    if (videoAppleChrome(context)) {
      return _buildApple(context, scale: scale, fraction: clamped / max);
    }
    return Align(
      alignment: alignment,
      child: SafeArea(
        minimum: minimum,
        child: DecoratedBox(
          key: frameKey,
          decoration: BoxDecoration(
            color: surfaceColor,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: textColor.withValues(alpha: 0.12)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: shadowColor.withValues(alpha: 0.22),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: 12 * scale,
              vertical: 10 * scale,
            ),
            child: SizedBox(
              width: 96 * scale,
              height: 36 * scale,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SizedBox(
                    height: rowHeight,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        FushiIcon(icon, color: textColor, size: 20 * scale),
                        SizedBox(width: 8 * scale),
                        Expanded(
                          child: DefaultTextStyle.merge(
                            style: TextStyle(
                              color: textColor,
                              fontSize: 15 * scale,
                              fontWeight: FontWeight.w700,
                            ),
                            child: Text(
                              '${clamped.round()}%',
                              maxLines: 1,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: 8 * scale),
                  SizedBox(
                    height: progressHeight,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: FushiLinearProgressIndicator(
                        key: progressKey,
                        value: clamped / max,
                        minHeight: progressHeight,
                        backgroundColor: textColor.withValues(alpha: 0.24),
                        valueColor: AlwaysStoppedAnimation<Color>(textColor),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Apple（iOS 26 系统音量 / 亮度 HUD）：一枚竖向深色液态玻璃胶囊，里面一条
  /// 自下而上填充的白色电平条，底部是 SF 字形。不显示百分比数字——与系统 HUD
  /// 一样只靠填充高度表达电平。[frameKey] / [progressKey] 仍挂在外框与填充上。
  Widget _buildApple(
    BuildContext context, {
    required double scale,
    required double fraction,
  }) {
    final double width = 48 * scale;
    return Align(
      alignment: alignment,
      child: SafeArea(
        minimum: minimum,
        child: SizedBox(
          key: frameKey,
          width: width,
          height: 168 * scale,
          child: VideoGlassSurface(
            enabled: true,
            radius: width / 2,
            padding: EdgeInsets.fromLTRB(
              8 * scale,
              10 * scale,
              8 * scale,
              10 * scale,
            ),
            child: Column(
              children: <Widget>[
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(width / 2),
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        const ColoredBox(color: Color(0x38FFFFFF)),
                        Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            key: progressKey,
                            widthFactor: 1,
                            heightFactor: fraction,
                            child: const ColoredBox(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(height: 8 * scale),
                FushiIcon(icon, color: Colors.white, size: 20 * scale),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
