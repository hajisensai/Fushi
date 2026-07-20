import 'package:flutter/material.dart';
import 'package:hibiki/src/media/torrent/anime_download_config.dart';
import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
import 'package:hibiki/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/src/settings/settings_schema_fields.dart';
import 'package:hibiki/utils.dart';

SettingsDestination buildVideoDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.video,
    title: t.settings_destination_video,
    summary: t.video_settings_title,
    icon: Icons.movie_outlined,
    sections: <SettingsSection>[
      SettingsSection(
        title: t.section_video_playback,
        items: <SettingsItem>[
          // 自动连播开关（TODO-639）：纯 pref（appModel 直接读写 prefsRepo），默认开。
          // 关掉后一集播完停在本集结束、不自动进下一集；开则倒计时自动进下一集（倒计时
          // 期间画面会出现「取消」按钮，点了本次不进下一集）。
          SettingsSwitchItem(
            id: 'video.playback.auto_play_next',
            title: t.video_setting_auto_play_next,
            icon: Icons.playlist_play_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoAutoPlayNext,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setVideoAutoPlayNext(value);
            },
          ),
          SettingsSegmentedItem<VideoImmersiveMode>(
            id: 'video.playback.immersive_mode',
            title: t.video_setting_immersive_mode,
            subtitle: t.video_setting_immersive_mode_hint,
            icon: Icons.lock_outline,
            options: <SettingsSegmentOption<VideoImmersiveMode>>[
              for (final VideoImmersiveMode mode in VideoImmersiveMode.values)
                SettingsSegmentOption<VideoImmersiveMode>(
                  value: mode,
                  label: _videoImmersiveModeLabel(mode),
                ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoImmersiveMode,
            onChanged: (
              SettingsContext settingsContext,
              VideoImmersiveMode mode,
            ) async {
              await settingsContext.appModel.setVideoImmersiveMode(mode);
            },
          ),
          SettingsSegmentedItem<VideoFitMode>(
            id: 'video.playback.picture_fit',
            title: t.video_setting_picture_fit,
            icon: Icons.fit_screen_outlined,
            options: <SettingsSegmentOption<VideoFitMode>>[
              SettingsSegmentOption<VideoFitMode>(
                value: VideoFitMode.cover,
                label: t.video_setting_picture_fit_cover,
              ),
              SettingsSegmentOption<VideoFitMode>(
                value: VideoFitMode.contain,
                label: t.video_setting_picture_fit_contain,
              ),
              SettingsSegmentOption<VideoFitMode>(
                value: VideoFitMode.fill,
                label: t.video_setting_picture_fit_fill,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoFitMode,
            onChanged: (
              SettingsContext settingsContext,
              VideoFitMode mode,
            ) async {
              await settingsContext.appModel.setVideoFitMode(mode);
            },
          ),
          SettingsSegmentedItem<int>(
            id: 'video.playback.double_tap',
            title: t.video_setting_double_tap,
            subtitle: t.video_setting_double_tap_hint,
            icon: Icons.touch_app_outlined,
            options: <SettingsSegmentOption<int>>[
              SettingsSegmentOption<int>(
                value: 0,
                label: t.video_setting_double_tap_off,
              ),
              for (final int seconds in <int>[3, 5, 10])
                SettingsSegmentOption<int>(
                  value: seconds,
                  label: '${seconds}s',
                ),
              SettingsSegmentOption<int>(
                value: VideoAsbplayerConfig.kDoubleTapSubtitle,
                label: t.video_setting_double_tap_subtitle,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                VideoAsbplayerConfig.decode(
              settingsContext.appModel.videoAsbplayerConfig,
            ).doubleTapSeekSeconds,
            onChanged: (SettingsContext settingsContext, int value) async {
              final VideoAsbplayerConfig current = VideoAsbplayerConfig.decode(
                settingsContext.appModel.videoAsbplayerConfig,
              );
              await settingsContext.appModel.setVideoAsbplayerConfig(
                VideoAsbplayerConfig.encode(
                  current.copyWith(doubleTapSeekSeconds: value),
                ),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'video.playback.lock_window_aspect',
            title: t.video_setting_lock_window_aspect,
            icon: Icons.aspect_ratio_outlined,
            visible: (_) => isDesktopPlatform,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoLockWindowAspectRatio,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setVideoLockWindowAspectRatio(value);
            },
          ),
          // 长按倍速 / 跳转步长 / 句末暂停都落在 videoAsbplayerConfig（纯 pref，无需
          // 播放器 controller）；这里是它们的全局默认，下次播放即生效，与播放页内调一致。
          SettingsSliderItem(
            id: 'video.playback.long_press_speed',
            title: t.video_setting_long_press_speed,
            icon: Icons.touch_app_outlined,
            min: 1.0,
            max: 4.0,
            divisions: 30,
            step: 0.1,
            label: (double v) => '${v.toStringAsFixed(1)}x',
            value: (SettingsContext settingsContext) =>
                VideoAsbplayerConfig.decode(
              settingsContext.appModel.videoAsbplayerConfig,
            ).longPressSpeed,
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoAsbConfig(
                settingsContext,
                (VideoAsbplayerConfig c) => c.copyWith(
                  longPressSpeed: ((v * 10).roundToDouble() / 10)
                      .clamp(1.0, 4.0)
                      .toDouble(),
                ),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
          SettingsStepperItem(
            id: 'video.playback.seek_seconds',
            title: t.video_setting_seek_seconds,
            icon: Icons.keyboard_double_arrow_right_outlined,
            value: (SettingsContext settingsContext) =>
                VideoAsbplayerConfig.decode(
              settingsContext.appModel.videoAsbplayerConfig,
            ).seekSeconds.toDouble(),
            step: 1,
            min: 1,
            max: 30,
            format: (double v) => '${v.round()}s',
            onChanged: (SettingsContext settingsContext, double v) async {
              await _commitVideoAsbConfig(
                settingsContext,
                (VideoAsbplayerConfig c) =>
                    c.copyWith(seekSeconds: v.round().clamp(1, 30)),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'video.playback.pause_at_subtitle_end',
            title: t.playback_auto_pause,
            icon: Icons.pause_circle_outline,
            value: (SettingsContext settingsContext) =>
                VideoAsbplayerConfig.decode(
              settingsContext.appModel.videoAsbplayerConfig,
            ).pauseAtSubtitleEnd,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await _commitVideoAsbConfig(
                settingsContext,
                (VideoAsbplayerConfig c) =>
                    c.copyWith(pauseAtSubtitleEnd: value),
              );
            },
          ),
          // 「重置控件布局」原独占一个「控件」section（仅此一项）；单项撑一个分区
          // 是欠填充结构，并入「播放」尾部（t.video_settings_cat_controls key 仍被
          // 播放页快捷设置面板使用，勿删）。
          SettingsActionItem(
            id: 'video.controls.reset_layout',
            title: t.video_control_reset_layout,
            icon: Icons.restart_alt_outlined,
            onTap: (SettingsContext settingsContext) async {
              await settingsContext.appModel.setVideoControlLayout(
                VideoControlLayout.currentChrome,
              );
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.video_setting_mpv_group_quality,
        collapsedByDefault: true,
        items: <SettingsItem>[
          // 画质增强（mpv 内置高质量缩放开关）+ 解码 / 去色带 / 循环：这些 mpv 配置项
          // 都序列化进 videoMpvConfig（纯 pref），下次打开视频时 applyMpvConfigToPlayer
          // 应用；无需运行中的 controller，故可在首页全局设置改。着色器档位选择需下载 +
          // 文件系统，仍只在播放页内的「画质增强」管理视图里调。
          SettingsSwitchItem(
            id: 'video.quality.enhancement',
            title: t.video_shader_quality_tier,
            subtitle: t.video_quality_enhancement_hint,
            icon: Icons.auto_fix_high_outlined,
            value: (SettingsContext settingsContext) => VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).highQuality,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(highQuality: value),
              );
            },
          ),
          // S 形上采样（sigmoid-upscaling）：与「画质增强/着色器等级」并列的一档可选画质
          // 开关（TODO-1120/BUG-538）。默认关（性能占用偏大，见 VideoMpvConfig.defaults）；
          // 想要更锐利放大的用户可开。纯 pref，序列化进 videoMpvConfig，下次开视频时应用。
          SettingsSwitchItem(
            id: 'video.quality.sigmoid',
            title: t.video_setting_mpv_sigmoid,
            subtitle: t.video_setting_mpv_sigmoid_hint,
            icon: Icons.show_chart_outlined,
            value: (SettingsContext settingsContext) => VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).sigmoidUpscaling,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(sigmoidUpscaling: value),
              );
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'video.quality.hwdec',
            title: t.video_setting_mpv_hwdec,
            icon: Icons.memory_outlined,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'no',
                label: t.video_setting_mpv_hwdec_off,
              ),
              SettingsSegmentOption<String>(
                value: 'auto-safe',
                label: t.video_setting_mpv_hwdec_auto,
              ),
              SettingsSegmentOption<String>(
                value: 'auto-copy',
                label: t.video_setting_mpv_hwdec_copy,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).hwdec,
            onChanged: (SettingsContext settingsContext, String value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(hwdec: value),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'video.quality.deband',
            title: t.video_setting_mpv_deband,
            icon: Icons.gradient_outlined,
            value: (SettingsContext settingsContext) => VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).deband,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(deband: value),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'video.quality.loop',
            title: t.video_setting_mpv_loop,
            icon: Icons.repeat_outlined,
            value: (SettingsContext settingsContext) => VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).loopFile,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(loopFile: value),
              );
            },
          ),
          // TODO-1247：把播放页内 mpv 画质组里的其余布尔项平移到首页（纯 pref，下次开
          // 视频 applyMpvConfig 应用），与播放页内设置同源，消除「首页改不了」。
          _videoMpvSwitchItem(
            id: 'video.quality.dither',
            title: t.video_setting_mpv_dither,
            icon: Icons.grain_outlined,
            read: (VideoMpvConfig c) => c.dither,
            write: (VideoMpvConfig c, bool v) => c.copyWith(dither: v),
          ),
          _videoMpvSwitchItem(
            id: 'video.quality.interpolation',
            title: t.video_setting_mpv_interpolation,
            icon: Icons.animation_outlined,
            read: (VideoMpvConfig c) => c.interpolation,
            write: (VideoMpvConfig c, bool v) => c.copyWith(interpolation: v),
          ),
          _videoMpvSwitchItem(
            id: 'video.quality.deinterlace',
            title: t.video_setting_mpv_deinterlace,
            icon: Icons.view_stream_outlined,
            read: (VideoMpvConfig c) => c.deinterlace,
            write: (VideoMpvConfig c, bool v) => c.copyWith(deinterlace: v),
          ),
          _videoMpvSwitchItem(
            id: 'video.quality.correct_downscale',
            title: t.video_setting_mpv_correct_downscale,
            icon: Icons.photo_size_select_small_outlined,
            read: (VideoMpvConfig c) => c.correctDownscaling,
            write: (VideoMpvConfig c, bool v) =>
                c.copyWith(correctDownscaling: v),
          ),
          // 已知问题说明（TODO-1116/1119 / BUG-545）：Windows 渲染链在高显卡占用时
          // 可能黑屏闪烁；hwdec 真修属 device-gated 后续项，本轮先在画质组内明示，
          // 并指向上面真实存在的画质控件降低 GPU 负载。仅 Windows 展示。
          SettingsCustomItem(
            id: 'video.quality.windows_black_flash_notice',
            visible: (SettingsContext settingsContext) => isWindowsPlatform,
            builder: _buildWindowsBlackFlashNotice,
          ),
        ],
      ),
      // TODO-1247：把播放页内 mpv「画面几何 / 色彩均衡 / 音频」详情平移到首页，读写同一
      // videoMpvConfig（纯 pref，下次开视频 applyMpvConfig 应用），与播放页内设置同源。
      SettingsSection(
        title: t.video_setting_mpv_group_geometry,
        collapsedByDefault: true,
        items: <SettingsItem>[
          SettingsSegmentedItem<int>(
            id: 'video.geometry.rotate',
            title: t.video_setting_mpv_rotate,
            icon: Icons.screen_rotation_outlined,
            options: const <SettingsSegmentOption<int>>[
              SettingsSegmentOption<int>(value: 0, label: '0°'),
              SettingsSegmentOption<int>(value: 90, label: '90°'),
              SettingsSegmentOption<int>(value: 180, label: '180°'),
              SettingsSegmentOption<int>(value: 270, label: '270°'),
            ],
            selected: (SettingsContext settingsContext) =>
                VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).videoRotate,
            onChanged: (SettingsContext settingsContext, int value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(videoRotate: value),
              );
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'video.geometry.aspect',
            title: t.video_setting_mpv_aspect,
            icon: Icons.aspect_ratio_outlined,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: '-1',
                label: t.video_setting_mpv_aspect_auto,
              ),
              const SettingsSegmentOption<String>(value: '16:9', label: '16:9'),
              const SettingsSegmentOption<String>(value: '4:3', label: '4:3'),
              const SettingsSegmentOption<String>(
                value: '2.35:1',
                label: '2.35:1',
              ),
              const SettingsSegmentOption<String>(value: '1:1', label: '1:1'),
            ],
            selected: (SettingsContext settingsContext) =>
                VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).aspectOverride,
            onChanged: (SettingsContext settingsContext, String value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(aspectOverride: value),
              );
            },
          ),
          SettingsSliderItem(
            id: 'video.geometry.zoom',
            title: t.video_setting_mpv_zoom,
            icon: Icons.zoom_out_map_outlined,
            min: -2,
            max: 2,
            divisions: 40,
            label: (double v) => v.toStringAsFixed(2),
            value: (SettingsContext settingsContext) => VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).videoZoom.clamp(-2.0, 2.0),
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(videoZoom: v),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
          SettingsSliderItem(
            id: 'video.geometry.panscan',
            title: t.video_setting_mpv_panscan,
            icon: Icons.crop_outlined,
            min: 0,
            max: 1,
            divisions: 20,
            label: (double v) => v.toStringAsFixed(2),
            value: (SettingsContext settingsContext) => VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).panscan.clamp(0.0, 1.0),
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(panscan: v),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
        ],
      ),
      SettingsSection(
        title: t.video_setting_mpv_group_color,
        collapsedByDefault: true,
        items: <SettingsItem>[
          _videoMpvColorSliderItem(
            id: 'video.color.brightness',
            title: t.video_setting_mpv_brightness,
            icon: Icons.brightness_6_outlined,
            read: (VideoMpvConfig c) => c.brightness,
            write: (VideoMpvConfig c, int v) => c.copyWith(brightness: v),
          ),
          _videoMpvColorSliderItem(
            id: 'video.color.contrast',
            title: t.video_setting_mpv_contrast,
            icon: Icons.contrast_outlined,
            read: (VideoMpvConfig c) => c.contrast,
            write: (VideoMpvConfig c, int v) => c.copyWith(contrast: v),
          ),
          _videoMpvColorSliderItem(
            id: 'video.color.saturation',
            title: t.video_setting_mpv_saturation,
            icon: Icons.invert_colors_outlined,
            read: (VideoMpvConfig c) => c.saturation,
            write: (VideoMpvConfig c, int v) => c.copyWith(saturation: v),
          ),
          _videoMpvColorSliderItem(
            id: 'video.color.gamma',
            title: t.video_setting_mpv_gamma,
            icon: Icons.tonality_outlined,
            read: (VideoMpvConfig c) => c.gamma,
            write: (VideoMpvConfig c, int v) => c.copyWith(gamma: v),
          ),
          _videoMpvColorSliderItem(
            id: 'video.color.hue',
            title: t.video_setting_mpv_hue,
            icon: Icons.colorize_outlined,
            read: (VideoMpvConfig c) => c.hue,
            write: (VideoMpvConfig c, int v) => c.copyWith(hue: v),
          ),
        ],
      ),
      SettingsSection(
        title: t.video_setting_mpv_group_audio,
        collapsedByDefault: true,
        items: <SettingsItem>[
          _videoMpvSwitchItem(
            id: 'video.audio.pitch',
            title: t.video_setting_mpv_pitch,
            icon: Icons.graphic_eq_outlined,
            read: (VideoMpvConfig c) => c.audioPitchCorrection,
            write: (VideoMpvConfig c, bool v) =>
                c.copyWith(audioPitchCorrection: v),
          ),
          SettingsSegmentedItem<String>(
            id: 'video.audio.channels',
            title: t.video_setting_mpv_channels,
            icon: Icons.surround_sound_outlined,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: 'auto-safe',
                label: t.video_setting_mpv_channels_auto,
              ),
              SettingsSegmentOption<String>(
                value: 'stereo',
                label: t.video_setting_mpv_channels_stereo,
              ),
              SettingsSegmentOption<String>(
                value: 'mono',
                label: t.video_setting_mpv_channels_mono,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                VideoMpvConfig.decode(
              settingsContext.appModel.videoMpvConfig,
            ).audioChannels,
            onChanged: (SettingsContext settingsContext, String value) async {
              await _commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(audioChannels: value),
              );
            },
          ),
          _videoMpvSwitchItem(
            id: 'video.audio.normalize_downmix',
            title: t.video_setting_mpv_normalize,
            icon: Icons.volume_up_outlined,
            read: (VideoMpvConfig c) => c.normalizeDownmix,
            write: (VideoMpvConfig c, bool v) =>
                c.copyWith(normalizeDownmix: v),
          ),
        ],
      ),
      SettingsSection(
        title: t.section_video_subtitles,
        items: <SettingsItem>[
          // TODO-840 Part B：把原「字幕模糊」单一开关扩成遮蔽模式三态选择器——不遮蔽 /
          // 模糊（听力沉浸）/ 隐藏（主字幕不显示）。持久化是 preferences 层 lazy 投影
          // （见 [PreferencesRepository.videoSubtitleObscureMode]），无新 Drift schema。
          SettingsSegmentedItem<VideoSubtitleObscureMode>(
            id: 'video.subtitle.obscure',
            title: t.video_setting_subtitle_obscure,
            subtitle: t.video_setting_subtitle_obscure_hint,
            icon: Icons.blur_on_outlined,
            options: <SettingsSegmentOption<VideoSubtitleObscureMode>>[
              for (final VideoSubtitleObscureMode mode
                  in VideoSubtitleObscureMode.values)
                SettingsSegmentOption<VideoSubtitleObscureMode>(
                  value: mode,
                  label: _videoSubtitleObscureModeLabel(mode),
                ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoSubtitleObscureMode,
            onChanged: (
              SettingsContext settingsContext,
              VideoSubtitleObscureMode mode,
            ) async {
              await settingsContext.appModel.setVideoSubtitleObscureMode(mode);
            },
          ),
          // TODO-1382：副字幕遮蔽三态（镜像主字幕，独立开关）——不遮蔽 / 模糊 / 隐藏。
          // 复用同一 [_videoSubtitleObscureModeLabel] 选项标签；快捷键 Shift+G 循环、
          // Shift+H 隐藏。持久化同为 preferences lazy 投影（无新 Drift schema）。
          SettingsSegmentedItem<VideoSubtitleObscureMode>(
            id: 'video.secondary_subtitle.obscure',
            title: t.video_setting_secondary_subtitle_obscure,
            subtitle: t.video_setting_secondary_subtitle_obscure_hint,
            icon: Icons.blur_on_outlined,
            options: <SettingsSegmentOption<VideoSubtitleObscureMode>>[
              for (final VideoSubtitleObscureMode mode
                  in VideoSubtitleObscureMode.values)
                SettingsSegmentOption<VideoSubtitleObscureMode>(
                  value: mode,
                  label: _videoSubtitleObscureModeLabel(mode),
                ),
            ],
            selected: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoSecondarySubtitleObscureMode,
            onChanged: (
              SettingsContext settingsContext,
              VideoSubtitleObscureMode mode,
            ) async {
              await settingsContext.appModel
                  .setVideoSecondarySubtitleObscureMode(mode);
            },
          ),
          // TODO-1247：尊重 .ass 自带样式开关平移到首页（videoRespectAssStyle 纯 pref，
          // 下次开视频生效），与播放页内字幕设置同源。
          SettingsSwitchItem(
            id: 'video.subtitle.respect_ass_style',
            title: t.video_setting_subtitle_respect_ass,
            subtitle: t.video_setting_subtitle_respect_ass_hint,
            icon: Icons.style_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoRespectAssStyle,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setVideoRespectAssStyle(value);
              settingsContext.refresh();
            },
          ),
          // 字幕外观（字号/字重/阴影/背景不透明度/位置）全序列化进 videoSubtitleStyle
          // （纯 pref）。首页设置无实时预览（没有 overlay），落盘后下次播放生效；播放页内
          // 仍有拖动实时预览。字重/阴影粗细在 style 里以 null=「跟随界面缩放」存储，这里
          // 只在用户显式拖动时写显式值（与播放页一致），不主动把默认折成显式值。
          SettingsSliderItem(
            id: 'video.subtitle.font_size',
            title: t.video_setting_subtitle_font_size,
            icon: Icons.format_size_outlined,
            min: 12,
            max: 48,
            divisions: 36,
            label: (double v) => v.round().toString(),
            value: (SettingsContext settingsContext) =>
                VideoSubtitleStyle.decode(
              settingsContext.appModel.videoSubtitleStyle,
            ).fontSize.clamp(12, 48),
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(fontSize: v),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
          SettingsStepperItem(
            id: 'video.subtitle.font_weight',
            title: t.video_setting_subtitle_font_weight,
            icon: Icons.format_bold,
            value: (SettingsContext settingsContext) =>
                VideoSubtitleStyle.decode(
              settingsContext.appModel.videoSubtitleStyle,
            ).resolveFontWeight(settingsContext.appModel.appUiScale).toDouble(),
            step: 100,
            min: 100,
            max: 900,
            format: (double v) => v.round().toString(),
            onChanged: (SettingsContext settingsContext, double v) async {
              await _commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(fontWeight: v.round()),
              );
            },
          ),
          SettingsSliderItem(
            id: 'video.subtitle.shadow',
            title: t.video_setting_subtitle_shadow,
            icon: Icons.format_color_text_outlined,
            min: 0,
            max: 12,
            divisions: 12,
            label: (double v) => '${v.round()}px',
            value: (SettingsContext settingsContext) =>
                VideoSubtitleStyle.decode(
              settingsContext.appModel.videoSubtitleStyle,
            )
                    .resolveShadowThickness(
                      settingsContext.appModel.appUiScale,
                    )
                    .clamp(0, 12),
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(shadowThickness: v),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
          SettingsSliderItem(
            id: 'video.subtitle.bg_opacity',
            title: t.video_setting_subtitle_bg_opacity,
            icon: Icons.opacity_outlined,
            divisions: 20,
            value: (SettingsContext settingsContext) =>
                VideoSubtitleStyle.decode(
              settingsContext.appModel.videoSubtitleStyle,
            ).backgroundOpacity.clamp(0, 1),
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(backgroundOpacity: v),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
          SettingsSliderItem(
            id: 'video.subtitle.position',
            title: t.video_setting_subtitle_position,
            icon: Icons.height_outlined,
            min: 0,
            max: 240,
            divisions: 24,
            value: (SettingsContext settingsContext) =>
                VideoSubtitleStyle.decode(
              settingsContext.appModel.videoSubtitleStyle,
            ).bottomPadding.clamp(0, 240),
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await _commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(bottomPadding: v),
              );
            },
            onChanged: (SettingsContext settingsContext, double v) {},
          ),
        ],
      ),
      SettingsSection(
        title: t.section_video_danmaku,
        collapsedByDefault: true,
        items: <SettingsItem>[
          // 弹幕开关 / 在线匹配 / 同屏上限都是纯 pref（appModel 直接读写 prefsRepo），
          // 与播放页内弹幕设置语义一致，下次播放生效。
          SettingsSwitchItem(
            id: 'video.danmaku.enabled',
            title: t.video_setting_danmaku_enabled,
            subtitle: t.video_setting_danmaku_enabled_hint,
            icon: Icons.forum_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoDanmakuEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setVideoDanmakuEnabled(value);
            },
          ),
          SettingsSwitchItem(
            id: 'video.danmaku.online',
            title: t.video_setting_danmaku_online,
            subtitle: t.video_setting_danmaku_online_hint,
            icon: Icons.cloud_sync_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoDanmakuOnlineEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel
                  .setVideoDanmakuOnlineEnabled(value);
            },
          ),
          SettingsStepperItem(
            id: 'video.danmaku.max_active',
            title: t.video_setting_danmaku_max_active,
            subtitle: t.video_setting_danmaku_max_active_hint,
            icon: Icons.speed_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoDanmakuMaxActive.toDouble(),
            step: 10,
            min: 10,
            max: kMaxVideoDanmakuActive.toDouble(),
            format: (double v) => v.round().toString(),
            onChanged: (SettingsContext settingsContext, double v) async {
              await settingsContext.appModel.setVideoDanmakuMaxActive(
                normalizeVideoDanmakuMaxActive(v.round()),
              );
            },
          ),
          // 弹幕来源配置只剩自建/镜像 Dandanplay 服务器地址（高级项，空=官方
          // api.dandanplay.net）。官方 AppId/AppSecret 已内置（dandanplay_secret.dart，
          // 见 DandanplayConfig.embeddedAppId），请求自动 v2 签名，用户**无需手动输入
          // API**——故原 AppId/AppSecret 两个输入框已删除。写入 videoDanmakuConfig
          // （纯 pref），同步推进程级 DandanplayConfig.current，下次匹配弹幕即生效。
          SettingsCustomItem(
            id: 'video.danmaku.server_url',
            builder: _buildDanmakuServerField,
          ),
        ],
      ),
      SettingsSection(
        title: t.section_video_anime_download,
        items: <SettingsItem>[
          // 后端二选一：外接 qBittorrent（全平台）或内置 libtorrent 引擎
          // （桌面）。选内置时下面的 qb 连接字段隐藏（内置无需连接参数）。
          SettingsSegmentedItem<String>(
            id: 'video.anime_download.backend',
            title: t.video_setting_torrent_backend,
            icon: Icons.dns_outlined,
            options: <SettingsSegmentOption<String>>[
              SettingsSegmentOption<String>(
                value: QbConnectionConfig.backendQbittorrent,
                label: t.video_setting_torrent_backend_qb,
              ),
              SettingsSegmentOption<String>(
                value: QbConnectionConfig.backendEmbedded,
                label: t.video_setting_torrent_backend_embedded,
              ),
            ],
            selected: (SettingsContext settingsContext) =>
                (settingsContext.appModel.qbConnectionConfig ??
                        const QbConnectionConfig())
                    .resolveBackend(isDesktop: isDesktopPlatform),
            onChanged: (SettingsContext settingsContext, String backend) async {
              await _commitQbConfig(
                settingsContext,
                (QbConnectionConfig c) => c.copyWith(backend: backend),
              );
            },
          ),
          // qb 连接字段（内置引擎时隐藏）：纯 pref（一个 JSON 配置），
          // URL 留空 = 外接后端未启用。
          SettingsCustomItem(
            id: 'video.anime_download.qb_url',
            visible: _qbBackendSelected,
            builder: _buildQbUrlField,
          ),
          SettingsCustomItem(
            id: 'video.anime_download.qb_username',
            visible: _qbBackendSelected,
            builder: _buildQbUsernameField,
          ),
          SettingsCustomItem(
            id: 'video.anime_download.qb_password',
            visible: _qbBackendSelected,
            builder: _buildQbPasswordField,
          ),
          SettingsCustomItem(
            id: 'video.anime_download.qb_category',
            builder: _buildQbCategoryField,
          ),
          // 内置引擎资源限制（仅内置后端显示；外接 qb 有自己的设置）。
          // 均为数字输入，0 = 不限；改动即时应用到常驻引擎会话。
          SettingsCustomItem(
            id: 'video.anime_download.embedded_download_limit',
            visible: _embeddedBackendSelected,
            builder: _buildEmbeddedDownloadLimitField,
          ),
          // 上传/做种总开关（内置引擎；默认关，尊重带宽/隐私）。关时下面的
          // 上传限速/做种上限字段隐藏（无意义）。
          SettingsSwitchItem(
            id: 'video.anime_download.upload_enabled',
            title: t.video_setting_torrent_upload_enabled,
            subtitle: t.video_setting_torrent_upload_enabled_hint,
            icon: Icons.upload_outlined,
            visible: _embeddedBackendSelected,
            value: (SettingsContext settingsContext) =>
                (settingsContext.appModel.qbConnectionConfig ??
                        const QbConnectionConfig())
                    .uploadEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await _commitQbConfig(
                settingsContext,
                (QbConnectionConfig c) => c.copyWith(uploadEnabled: value),
              );
              settingsContext.refresh();
            },
          ),
          SettingsCustomItem(
            id: 'video.anime_download.embedded_upload_limit',
            visible: _embeddedUploadEnabled,
            builder: _buildEmbeddedUploadLimitField,
          ),
          SettingsCustomItem(
            id: 'video.anime_download.seed_time_limit',
            visible: _embeddedUploadEnabled,
            builder: _buildSeedTimeLimitField,
          ),
          SettingsCustomItem(
            id: 'video.anime_download.seed_ratio_limit',
            visible: _embeddedUploadEnabled,
            builder: _buildSeedRatioLimitField,
          ),
          SettingsCustomItem(
            id: 'video.anime_download.embedded_max_connections',
            visible: _embeddedBackendSelected,
            builder: _buildEmbeddedMaxConnectionsField,
          ),
          SettingsCustomItem(
            id: 'video.anime_download.embedded_memory_limit',
            visible: _embeddedBackendSelected,
            builder: _buildEmbeddedMemoryLimitField,
          ),
        ],
      ),
    ],
  );
}

/// 当前是否选外接 qBittorrent 后端（决定 qb 连接字段是否显示）。历史配置
/// 无 backend 字段回退 qb（既有用户看得见连接字段，行为不变）。
bool _qbBackendSelected(SettingsContext settingsContext) {
  return (settingsContext.appModel.qbConnectionConfig ??
              const QbConnectionConfig())
          .resolveBackend(isDesktop: isDesktopPlatform) ==
      QbConnectionConfig.backendQbittorrent;
}

/// 当前是否选内置 libtorrent 引擎后端（决定内置引擎资源限制字段是否显示）。
bool _embeddedBackendSelected(SettingsContext settingsContext) {
  return (settingsContext.appModel.qbConnectionConfig ??
              const QbConnectionConfig())
          .resolveBackend(isDesktop: isDesktopPlatform) ==
      QbConnectionConfig.backendEmbedded;
}

/// 当前是否内置引擎且已开启上传（决定上传限速/做种上限字段是否显示）。
bool _embeddedUploadEnabled(SettingsContext settingsContext) {
  final QbConnectionConfig config =
      settingsContext.appModel.qbConnectionConfig ?? const QbConnectionConfig();
  return config.resolveBackend(isDesktop: isDesktopPlatform) ==
          QbConnectionConfig.backendEmbedded &&
      config.uploadEnabled;
}

/// 把限制字段的文本输入解析为非负整数（空/非数/负数 → 0 = 不限）。
int _parseNonNegLimit(String value) {
  final int n = int.tryParse(value.trim()) ?? 0;
  return n < 0 ? 0 : n;
}

/// 把分享率字段的文本输入解析为非负 double（空/非数/负数/非有限 → 0 = 不限）。
double _parseNonNegDouble(String value) {
  final double n = double.tryParse(value.trim()) ?? 0;
  return (n.isFinite && n > 0) ? n : 0;
}

Widget _buildEmbeddedDownloadLimitField(SettingsContext settingsContext) {
  final QbConnectionConfig? config =
      settingsContext.appModel.qbConnectionConfig;
  final int current = config?.downloadLimitKbps ?? 0;
  return SettingsSecretField(
    title: t.video_setting_torrent_download_limit,
    icon: Icons.south_outlined,
    initialValue: current == 0 ? '' : '$current',
    keyboardType: TextInputType.number,
    hintText: t.video_setting_torrent_limit_hint,
    onChanged: (String value) async {
      await _commitQbConfig(
        settingsContext,
        (QbConnectionConfig c) =>
            c.copyWith(downloadLimitKbps: _parseNonNegLimit(value)),
      );
    },
  );
}

Widget _buildEmbeddedUploadLimitField(SettingsContext settingsContext) {
  final QbConnectionConfig? config =
      settingsContext.appModel.qbConnectionConfig;
  final int current = config?.uploadLimitKbps ?? 0;
  return SettingsSecretField(
    title: t.video_setting_torrent_upload_limit,
    icon: Icons.north_outlined,
    initialValue: current == 0 ? '' : '$current',
    keyboardType: TextInputType.number,
    hintText: t.video_setting_torrent_limit_hint,
    onChanged: (String value) async {
      await _commitQbConfig(
        settingsContext,
        (QbConnectionConfig c) =>
            c.copyWith(uploadLimitKbps: _parseNonNegLimit(value)),
      );
    },
  );
}

Widget _buildSeedTimeLimitField(SettingsContext settingsContext) {
  final QbConnectionConfig? config =
      settingsContext.appModel.qbConnectionConfig;
  final int current = config?.seedTimeLimitMinutes ?? 0;
  return SettingsSecretField(
    title: t.video_setting_torrent_seed_time_limit,
    icon: Icons.timer_outlined,
    initialValue: current == 0 ? '' : '$current',
    keyboardType: TextInputType.number,
    hintText: t.video_setting_torrent_seed_time_hint,
    onChanged: (String value) async {
      await _commitQbConfig(
        settingsContext,
        (QbConnectionConfig c) =>
            c.copyWith(seedTimeLimitMinutes: _parseNonNegLimit(value)),
      );
    },
  );
}

Widget _buildSeedRatioLimitField(SettingsContext settingsContext) {
  final QbConnectionConfig? config =
      settingsContext.appModel.qbConnectionConfig;
  final double current = config?.seedRatioLimit ?? 0;
  return SettingsSecretField(
    title: t.video_setting_torrent_seed_ratio_limit,
    icon: Icons.balance_outlined,
    initialValue: current == 0 ? '' : '$current',
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    hintText: t.video_setting_torrent_seed_ratio_hint,
    onChanged: (String value) async {
      await _commitQbConfig(
        settingsContext,
        (QbConnectionConfig c) =>
            c.copyWith(seedRatioLimit: _parseNonNegDouble(value)),
      );
    },
  );
}

Widget _buildEmbeddedMemoryLimitField(SettingsContext settingsContext) {
  final QbConnectionConfig? config =
      settingsContext.appModel.qbConnectionConfig;
  final int current = config?.memoryLimitMb ?? 0;
  return SettingsSecretField(
    title: t.video_setting_torrent_memory_limit,
    icon: Icons.memory_outlined,
    initialValue: current == 0 ? '' : '$current',
    keyboardType: TextInputType.number,
    hintText: t.video_setting_torrent_memory_hint,
    onChanged: (String value) async {
      await _commitQbConfig(
        settingsContext,
        (QbConnectionConfig c) =>
            c.copyWith(memoryLimitMb: _parseNonNegLimit(value)),
      );
    },
  );
}

Widget _buildEmbeddedMaxConnectionsField(SettingsContext settingsContext) {
  final QbConnectionConfig? config =
      settingsContext.appModel.qbConnectionConfig;
  final int current = config?.maxConnections ?? 0;
  return SettingsSecretField(
    title: t.video_setting_torrent_max_connections,
    icon: Icons.lan_outlined,
    initialValue: current == 0 ? '' : '$current',
    keyboardType: TextInputType.number,
    hintText: t.video_setting_torrent_connections_hint,
    onChanged: (String value) async {
      await _commitQbConfig(
        settingsContext,
        (QbConnectionConfig c) =>
            c.copyWith(maxConnections: _parseNonNegLimit(value)),
      );
    },
  );
}

/// 读改写 qbConnectionConfig（纯 pref）：取当前（null 视为空配置）→ [mutate] → 落盘。
Future<void> _commitQbConfig(
  SettingsContext settingsContext,
  QbConnectionConfig Function(QbConnectionConfig config) mutate,
) async {
  final QbConnectionConfig current =
      settingsContext.appModel.qbConnectionConfig ?? const QbConnectionConfig();
  await settingsContext.appModel.setQbConnectionConfig(mutate(current));
  settingsContext.refresh();
}

Widget _buildQbUrlField(SettingsContext settingsContext) {
  return SettingsSecretField(
    title: t.video_setting_qb_url,
    icon: Icons.download_outlined,
    initialValue: settingsContext.appModel.qbConnectionConfig?.baseUrl ?? '',
    keyboardType: TextInputType.url,
    hintText: t.video_setting_qb_url_hint,
    onChanged: (String value) async {
      await _commitQbConfig(
        settingsContext,
        (QbConnectionConfig c) => c.copyWith(baseUrl: value.trim()),
      );
    },
  );
}

Widget _buildQbUsernameField(SettingsContext settingsContext) {
  return SettingsSecretField(
    title: t.video_setting_qb_username,
    icon: Icons.person_outline,
    initialValue: settingsContext.appModel.qbConnectionConfig?.username ?? '',
    onChanged: (String value) async {
      await _commitQbConfig(
        settingsContext,
        (QbConnectionConfig c) => c.copyWith(username: value.trim()),
      );
    },
  );
}

Widget _buildQbPasswordField(SettingsContext settingsContext) {
  return SettingsSecretField(
    title: t.video_setting_qb_password,
    icon: Icons.password_outlined,
    initialValue: settingsContext.appModel.qbConnectionConfig?.password ?? '',
    obscureText: true,
    onChanged: (String value) async {
      await _commitQbConfig(
        settingsContext,
        (QbConnectionConfig c) => c.copyWith(password: value),
      );
    },
  );
}

Widget _buildQbCategoryField(SettingsContext settingsContext) {
  return SettingsSecretField(
    title: t.video_setting_qb_category,
    icon: Icons.label_outline,
    initialValue:
        settingsContext.appModel.qbConnectionConfig?.category ?? 'hibiki',
    hintText: t.video_setting_qb_category_hint,
    onChanged: (String value) async {
      await _commitQbConfig(
        settingsContext,
        (QbConnectionConfig c) => c.copyWith(
          category: value.trim().isEmpty ? 'hibiki' : value.trim(),
        ),
      );
    },
  );
}

/// 读改写 videoDanmakuConfig（纯 pref）：decode 当前 → 应用 [mutate] → 落盘 → 刷新面板。
Future<void> _commitVideoDanmakuConfig(
  SettingsContext settingsContext,
  DandanplayConfig Function(DandanplayConfig config) mutate,
) async {
  final DandanplayConfig current = settingsContext.appModel.videoDanmakuConfig;
  await settingsContext.appModel.setVideoDanmakuConfig(mutate(current));
  settingsContext.refresh();
}

Widget _buildDanmakuServerField(SettingsContext settingsContext) {
  return SettingsSecretField(
    title: t.video_setting_danmaku_server_url,
    icon: Icons.dns_outlined,
    initialValue: settingsContext.appModel.videoDanmakuConfig.baseUrl,
    keyboardType: TextInputType.url,
    onChanged: (String value) async {
      await _commitVideoDanmakuConfig(
        settingsContext,
        (DandanplayConfig c) => c.copyWith(baseUrl: value.trim()),
      );
    },
  );
}

/// 读改写 videoAsbplayerConfig（纯 pref）：decode 当前 → 应用 [mutate] → encode 落盘 →
/// 刷新设置面板。所有视频播放手势 / 字幕 pref 都装在这一个 JSON 里，故统一一个 helper。
Future<void> _commitVideoAsbConfig(
  SettingsContext settingsContext,
  VideoAsbplayerConfig Function(VideoAsbplayerConfig config) mutate,
) async {
  final VideoAsbplayerConfig current = VideoAsbplayerConfig.decode(
    settingsContext.appModel.videoAsbplayerConfig,
  );
  await settingsContext.appModel.setVideoAsbplayerConfig(
    VideoAsbplayerConfig.encode(mutate(current)),
  );
  settingsContext.refresh();
}

/// 读改写 videoMpvConfig（纯 pref）：decode → [mutate] → encode 落盘 → 刷新面板。
Future<void> _commitVideoMpvConfig(
  SettingsContext settingsContext,
  VideoMpvConfig Function(VideoMpvConfig config) mutate,
) async {
  final VideoMpvConfig current = VideoMpvConfig.decode(
    settingsContext.appModel.videoMpvConfig,
  );
  await settingsContext.appModel.setVideoMpvConfig(
    VideoMpvConfig.encode(mutate(current)),
  );
  settingsContext.refresh();
}

/// TODO-1247：把播放页内 mpv 详情里的布尔开关平移到首页，读写同一
/// [AppModel.videoMpvConfig]（纯 pref，下次开视频时 applyMpvConfig 应用）——与播放页内
/// 设置同源，消除「首页改不了对应设置」。
SettingsSwitchItem _videoMpvSwitchItem({
  required String id,
  required String title,
  required IconData icon,
  required bool Function(VideoMpvConfig config) read,
  required VideoMpvConfig Function(VideoMpvConfig config, bool value) write,
}) {
  return SettingsSwitchItem(
    id: id,
    title: title,
    icon: icon,
    value: (SettingsContext settingsContext) => read(
      VideoMpvConfig.decode(settingsContext.appModel.videoMpvConfig),
    ),
    onChanged: (SettingsContext settingsContext, bool value) async {
      await _commitVideoMpvConfig(
        settingsContext,
        (VideoMpvConfig config) => write(config, value),
      );
    },
  );
}

/// TODO-1247：mpv 色彩均衡滑条（-100..100 整数）平移到首页；与播放页内详情同源
/// （落 [AppModel.videoMpvConfig]，下次开视频应用）。松手（onChangeEnd）才落盘避免每
/// tick 写 DB。
SettingsSliderItem _videoMpvColorSliderItem({
  required String id,
  required String title,
  required IconData icon,
  required int Function(VideoMpvConfig config) read,
  required VideoMpvConfig Function(VideoMpvConfig config, int value) write,
}) {
  return SettingsSliderItem(
    id: id,
    title: title,
    icon: icon,
    min: -100,
    max: 100,
    divisions: 200,
    label: (double v) => v.round().toString(),
    value: (SettingsContext settingsContext) => read(
      VideoMpvConfig.decode(settingsContext.appModel.videoMpvConfig),
    ).toDouble().clamp(-100, 100),
    onChangeEnd: (SettingsContext settingsContext, double v) async {
      await _commitVideoMpvConfig(
        settingsContext,
        (VideoMpvConfig config) => write(config, v.round()),
      );
    },
    onChanged: (SettingsContext settingsContext, double v) {},
  );
}

/// 「Windows 高显卡占用黑屏闪烁」已知问题说明行（TODO-1116/1119 / BUG-545）。
/// 纯说明文案，不写偏好、不改默认值；仅 Windows 平台在画质组内展示，指向上面真实
/// 存在的画质控件（画质增强 / S 形上采样 / 去色带 / 硬件解码）降低 GPU 负载。
Widget _buildWindowsBlackFlashNotice(SettingsContext settingsContext) {
  return AdaptiveSettingsRow(
    title: t.video_windows_black_flash_notice_title,
    subtitle: t.video_windows_black_flash_notice_body,
    icon: Icons.info_outline,
    showIcon: true,
  );
}

/// 读改写 videoSubtitleStyle（纯 pref）：decode → [mutate] → encode 落盘 → 刷新面板。
Future<void> _commitVideoSubtitleStyle(
  SettingsContext settingsContext,
  VideoSubtitleStyle Function(VideoSubtitleStyle style) mutate,
) async {
  final VideoSubtitleStyle current = VideoSubtitleStyle.decode(
    settingsContext.appModel.videoSubtitleStyle,
  );
  await settingsContext.appModel.setVideoSubtitleStyle(
    VideoSubtitleStyle.encode(mutate(current)),
  );
  settingsContext.refresh();
}

String _videoImmersiveModeLabel(VideoImmersiveMode mode) {
  switch (mode) {
    case VideoImmersiveMode.full:
      return t.video_immersive_mode_full;
    case VideoImmersiveMode.shortcutAndLookup:
      return t.video_immersive_mode_seek_lookup;
    case VideoImmersiveMode.lookupOnly:
      return t.video_immersive_mode_lookup_only;
    case VideoImmersiveMode.unlockOnly:
      return t.video_immersive_mode_unlock_only;
  }
}

/// 字幕遮蔽模式三态的本地化标签（TODO-840 Part B）。穷举枚举无 default，新增态
/// 编译期强制补齐。
String _videoSubtitleObscureModeLabel(VideoSubtitleObscureMode mode) {
  switch (mode) {
    case VideoSubtitleObscureMode.none:
      return t.video_setting_subtitle_obscure_none;
    case VideoSubtitleObscureMode.blur:
      return t.video_setting_subtitle_obscure_blur;
    case VideoSubtitleObscureMode.hide:
      return t.video_setting_subtitle_obscure_hide;
  }
}
