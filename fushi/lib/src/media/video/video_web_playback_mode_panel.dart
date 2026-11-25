// 网页档设置面板「画质增强」页签（拍板 cbKi3PN0G7-r2）：上面是播放档位二选一（「制卡优先」/
// 「画质优先」，各带能力说明），下面是本档的画质增强——「制卡优先」能选超分档位，「画质优先」
// 由站点直接绘制、给一行说明。两档同一个播放器、同一套控件，差别只在这里写清楚。
import 'package:material_ui/material_ui.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/media/video/web_video_hosting.dart';
import 'package:fushi/src/media/video/web_video_mode_chip.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// 网页帧能选的超分档位：low 是 mpv 内置缩放档，网页帧没有 mpv 缩放器，不列（与制卡重放宿主页
/// 的超分菜单同一组）。
const List<VideoShaderTier> kWebVideoShaderTiers = <VideoShaderTier>[
  VideoShaderTier.off,
  VideoShaderTier.medium,
  VideoShaderTier.high,
  VideoShaderTier.ultra,
];

/// 设置面板读写网页档档位与超分的能力槽（页面状态归播放器页，面板只读值、调回调）。
class VideoWebPlaybackModeHost {
  const VideoWebPlaybackModeHost({
    required this.current,
    required this.qualityFirstAvailable,
    required this.onSelectMode,
    required this.shaderTier,
    required this.onSelectShaderTier,
  });

  /// 本页正在用的档位。
  final WebVideoHosting current;

  /// 「画质优先」此刻能不能用（引擎支持底层合成）。
  final bool qualityFirstAvailable;

  /// 换到另一档（页面原地重开同一集）。
  final ValueChanged<WebVideoHosting> onSelectMode;

  /// 「制卡优先」档的超分档位（偏好 `web_video_shader_tier`）。
  final VideoShaderTier shaderTier;
  final ValueChanged<VideoShaderTier> onSelectShaderTier;
}

/// 「画质增强」页签在网页档的整页正文。
class VideoWebPlaybackModePanel extends StatefulWidget {
  const VideoWebPlaybackModePanel({required this.host, super.key});

  final VideoWebPlaybackModeHost host;

  @override
  State<VideoWebPlaybackModePanel> createState() =>
      _VideoWebPlaybackModePanelState();
}

class _VideoWebPlaybackModePanelState extends State<VideoWebPlaybackModePanel> {
  /// 面板里刚选的超分档位：页面重建传下新值之前也立即画成选中。
  late VideoShaderTier _tier = _shown(widget.host.shaderTier);

  /// 不在 [kWebVideoShaderTiers] 里的档（low：网页帧上就是直通）画成「关」。
  static VideoShaderTier _shown(VideoShaderTier tier) =>
      kWebVideoShaderTiers.contains(tier) ? tier : VideoShaderTier.off;

  @override
  void didUpdateWidget(VideoWebPlaybackModePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.host.shaderTier != widget.host.shaderTier) {
      _tier = _shown(widget.host.shaderTier);
    }
  }

  static String _tierLabel(VideoShaderTier tier) => switch (tier) {
    VideoShaderTier.off => t.video_shader_tier_off,
    VideoShaderTier.low => t.video_shader_tier_low,
    VideoShaderTier.medium => t.video_shader_tier_medium,
    VideoShaderTier.high => t.video_shader_tier_high,
    VideoShaderTier.ultra => t.video_shader_tier_ultra,
  };

  Widget _modeRow(BuildContext context, WebVideoHosting mode) {
    final VideoWebPlaybackModeHost host = widget.host;
    final bool selected = host.current == mode;
    final bool available =
        mode == WebVideoHosting.builtin || host.qualityFirstAvailable;
    final ColorScheme cs = Theme.of(context).colorScheme;
    return AdaptiveSettingsRow(
      key: ValueKey<String>('video.player.web_mode.${mode.name}'),
      icon: webVideoModeIcon(mode),
      showIcon: true,
      title: webVideoModeTitle(mode),
      subtitle: available
          ? webVideoModeSubtitle(mode)
          : t.web_video_mode_quality_unavailable,
      subtitleMaxLines: 3,
      trailing: selected
          ? FushiIcon(Icons.check_circle, color: cs.primary)
          : null,
      onTap: selected || !available ? null : () => host.onSelectMode(mode),
    );
  }

  @override
  Widget build(BuildContext context) {
    final VideoWebPlaybackModeHost host = widget.host;
    final bool capture = host.current == WebVideoHosting.builtin;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FushiStaggeredEntrance(
          index: 0,
          child: AdaptiveSettingsSection(
            title: t.web_video_mode_section,
            children: <Widget>[
              _modeRow(context, WebVideoHosting.builtin),
              _modeRow(context, WebVideoHosting.windowed),
            ],
          ),
        ),
        FushiStaggeredEntrance(
          index: 1,
          child: AdaptiveSettingsSection(
            title: t.video_shader_quality_tier,
            children: <Widget>[
              if (capture)
                AdaptiveSettingsSegmentedRow<VideoShaderTier>(
                  key: const ValueKey<String>(
                    'video.player.web_mode.shader_tier',
                  ),
                  title: t.video_shader_quality_tier,
                  segments: <ButtonSegment<VideoShaderTier>>[
                    for (final VideoShaderTier tier in kWebVideoShaderTiers)
                      ButtonSegment<VideoShaderTier>(
                        value: tier,
                        label: Text(_tierLabel(tier)),
                      ),
                  ],
                  selected: _tier,
                  onChanged: (VideoShaderTier tier) {
                    setState(() => _tier = tier);
                    host.onSelectShaderTier(tier);
                  },
                )
              else
                AdaptiveSettingsRow(
                  key: const ValueKey<String>(
                    'video.player.web_mode.shaders_unavailable',
                  ),
                  icon: Icons.info_outline,
                  showIcon: true,
                  title: t.web_video_mode_shaders_unavailable,
                  subtitle: t.web_video_mode_shaders_unavailable_hint,
                  subtitleMaxLines: 3,
                ),
            ],
          ),
        ),
      ],
    );
  }
}
