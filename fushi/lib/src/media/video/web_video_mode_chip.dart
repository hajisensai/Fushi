// 网页视频播放档位（「制卡优先」/「画质优先」）的显示名与播放器顶栏常驻档位标识。
//
// 拍板 cbKi3PN0G7-r2（维护者：「a 吧，但是我觉得要更显眼一点」）：两档都在原生播放器页里播、
// 同一套控件，用户只选「画质上限 vs 能否截图制卡」；当前档位在播放器里常驻可见、一点就切，
// 详细说明与超分档位在设置面板「画质增强」页签。
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart'
    show FushiTooltip;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';

/// 档位显示名：[WebVideoHosting.builtin] =「制卡优先」，[WebVideoHosting.windowed] =「画质优先」。
String webVideoModeTitle(WebVideoHosting hosting) => switch (hosting) {
  WebVideoHosting.builtin => t.web_video_mode_capture_title,
  WebVideoHosting.windowed => t.web_video_mode_quality_title,
};

/// 档位能力说明（设置面板里两档各一行的副标题）。
String webVideoModeSubtitle(WebVideoHosting hosting) => switch (hosting) {
  WebVideoHosting.builtin => t.web_video_mode_capture_subtitle,
  WebVideoHosting.windowed => t.web_video_mode_quality_subtitle,
};

/// 档位图标：制卡优先 = 卡片，画质优先 = HD。
IconData webVideoModeIcon(WebVideoHosting hosting) => switch (hosting) {
  WebVideoHosting.builtin => Icons.style_outlined,
  WebVideoHosting.windowed => Icons.hd_outlined,
};

/// 另一档（一键切换的目标）。
WebVideoHosting otherWebVideoMode(WebVideoHosting hosting) => switch (hosting) {
  WebVideoHosting.builtin => WebVideoHosting.windowed,
  WebVideoHosting.windowed => WebVideoHosting.builtin,
};

/// 播放器顶栏的常驻档位标识：图标 + 档位名的实心胶囊（两档不同色，一眼分得清），点一下
/// 调 [onPressed]（换到另一档，另一档用不了时打开设置面板的档位说明）。
///
/// [filled] = false 时不画底色（Apple 外观由外层玻璃胶囊供底）。
class WebVideoModeChip extends StatelessWidget {
  const WebVideoModeChip({
    required this.hosting,
    required this.tooltip,
    required this.onPressed,
    this.scale = 1,
    this.filled = true,
    super.key,
  });

  final WebVideoHosting hosting;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 播放器控件缩放（`_videoUiScale`）。
  final double scale;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final bool capture = hosting == WebVideoHosting.builtin;
    final Color background = !filled
        ? Colors.transparent
        : capture
        ? cs.tertiaryContainer
        : cs.secondaryContainer;
    final Color foreground = !filled
        ? (Theme.of(context).iconTheme.color ?? cs.onSurface)
        : capture
        ? cs.onTertiaryContainer
        : cs.onSecondaryContainer;
    final String label = webVideoModeTitle(hosting);
    final Duration switchDuration = fushiMotionDuration(
      context,
      FushiMotion.short,
    );
    return FushiTooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: label,
        hint: tooltip,
        excludeSemantics: true,
        child: FushiPressScale(
          enabled: onPressed != null,
          child: Material(
            color: background,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              customBorder: const StadiumBorder(),
              canRequestFocus: false,
              onTap: onPressed,
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: 36 * scale),
                child: Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12 * scale),
                  child: AnimatedSwitcher(
                    duration: switchDuration,
                    child: Row(
                      key: ValueKey<WebVideoHosting>(hosting),
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        FushiIcon(
                          webVideoModeIcon(hosting),
                          size: 18 * scale,
                          color: foreground,
                        ),
                        SizedBox(width: 6 * scale),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                color: foreground,
                                fontSize: 14 * scale,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
