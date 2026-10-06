import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:fushi/src/media/video/video_apple_chrome.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_controls.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

const Key videoVolumePopoverFrameKey =
    ValueKey<String>('video-volume-popover-frame');
const Key videoVolumePopoverSliderKey =
    ValueKey<String>('video-volume-popover-slider');
const Key videoVolumeHudFrameKey = ValueKey<String>('video-volume-hud-frame');
const Key videoVolumeHudProgressKey =
    ValueKey<String>('video-volume-hud-progress');
const Key videoBrightnessHudFrameKey =
    ValueKey<String>('video-brightness-hud-frame');
const Key videoBrightnessHudProgressKey =
    ValueKey<String>('video-brightness-hud-progress');

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
    this.frameKey = videoVolumePopoverFrameKey,
    this.sliderKey = videoVolumePopoverSliderKey,
  });

  final double width;
  final double value;
  final double uiScale;
  final ColorScheme colorScheme;
  final IconData icon;
  final String tooltip;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onChanged;
  final Key frameKey;
  final Key sliderKey;

  @override
  Widget build(BuildContext context) {
    final double scale = math.max(0.1, uiScale);
    final double clamped = value.clamp(0.0, 100.0).toDouble();
    final double controlHeight = 40 * scale;
    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        key: frameKey,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.94),
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
            padding: EdgeInsets.all(8 * scale),
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
                      color: colorScheme.primary,
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
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3.0 * scale,
                          thumbShape: RoundSliderThumbShape(
                            enabledThumbRadius: 7.0 * scale,
                          ),
                          overlayShape: RoundSliderOverlayShape(
                            overlayRadius: 14.0 * scale,
                          ),
                        ),
                        child: FushiSlider(
                          key: sliderKey,
                          value: clamped,
                          min: 0,
                          max: 100,
                          onChanged: onChanged,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: 6 * scale),
                  Text(
                    '${clamped.round()}%',
                    style: TextStyle(
                      color: colorScheme.onSurface,
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
  });

  final double value;
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
    final double clamped = value.clamp(0.0, 100.0).toDouble();
    final double rowHeight = 24 * scale;
    final double progressHeight = 4 * scale;
    if (videoAppleChrome(context)) {
      return _buildApple(context, scale: scale, clamped: clamped);
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
            border: Border.all(
              color: textColor.withValues(alpha: 0.12),
            ),
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
                        FushiIcon(
                          icon,
                          color: textColor,
                          size: 20 * scale,
                        ),
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
                        value: clamped / 100.0,
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
    required double clamped,
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
                            heightFactor: clamped / 100.0,
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
