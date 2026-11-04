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

  @override
  Widget build(BuildContext context) {
    if (videoAppleChrome(context)) {
      return SizedBox(
        key: frameKey,
        width: width,
        child: VideoGlassHud(
          padding: padding,
          radius: FushiRadii.menuValue,
          child: child,
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
          child: Padding(padding: padding, child: child),
        ),
      ),
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
    final bool apple = videoAppleChrome(context);
    final bool eink = isEinkTheme(context);
    final Color foreground = apple ? Colors.white : colorScheme.onSurface;
    final Color iconColor = apple ? Colors.white : colorScheme.primary;
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
      child: SizedBox(
        height: controlHeight,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiTooltip(
              message: tooltip,
              child: FushiIconButtonControl(
                icon: FushiIcon(icon),
                iconSize: 20 * scale,
                color: iconColor,
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
                color: foreground,
                fontSize: 12 * scale,
                fontWeight: FontWeight.w600,
                // 百分比随拖动逐帧变化：等宽数字。
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
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
