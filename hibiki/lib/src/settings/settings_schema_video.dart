import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
import 'package:hibiki/src/media/video/video_mpv_config.dart';
import 'package:hibiki/src/media/video/video_settings_actions.dart';
import 'package:hibiki/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:hibiki/src/media/video/video_subtitle_style.dart';
import 'package:hibiki/src/models/preferences_repository.dart';
import 'package:hibiki/src/settings/settings_context.dart';
import 'package:hibiki/src/settings/settings_destination.dart';
import 'package:hibiki/utils.dart';

/// 视频设置唯一真相源（阶段 B）：每个条目声明一次，同时服务两个宿主——
/// 全局设置页（本 destination 的 sections 直接渲染；无 host 时读写纯 pref、下次
/// 播放生效）与播放页快捷面板（按 [VideoPlacement] group/order/section 投影，
/// `buildVideoGroupDestination` 复刻旧手写面板的分组/排序/小节结构；host 在场时
/// 经页面回调实时应用）。双路写穿细节见 video_settings_actions.dart。
/// 仅播放中有意义的控制器绑定行集中在末尾的 host 门控 section（全局设置页恒隐藏，
/// 不设 searchTitle——全局搜索命中它们只会是死胡同）。
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
          // 期间画面会出现「取消」按钮，点了本次不进下一集）。播放页面板不单列（无
          // VideoPlacement），行为与旧面板一致。
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
          // 沉浸/画面缩放都是长标签四态：dropdown 渲染（TODO-209，分段条在窄 pane
          // 只能横向滚动裁断）。
          SettingsSegmentedItem<VideoImmersiveMode>(
            id: 'video.playback.immersive_mode',
            title: t.video_setting_immersive_mode,
            subtitle: t.video_setting_immersive_mode_hint,
            icon: Icons.lock_outline,
            dropdown: true,
            video: VideoPlacement(group: VideoGroup.playback, order: 70),
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
              await setVideoImmersiveModeDual(settingsContext, mode);
            },
          ),
          SettingsSegmentedItem<VideoFitMode>(
            id: 'video.playback.picture_fit',
            title: t.video_setting_picture_fit,
            subtitle: t.video_setting_picture_fit_hint,
            icon: Icons.fit_screen_outlined,
            dropdown: true,
            video: VideoPlacement(group: VideoGroup.playback, order: 30),
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
              await setVideoFitModeDual(settingsContext, mode);
            },
          ),
          SettingsSegmentedItem<int>(
            id: 'video.playback.double_tap',
            title: t.video_setting_double_tap,
            subtitle: t.video_setting_double_tap_hint,
            icon: Icons.touch_app_outlined,
            video: VideoPlacement(group: VideoGroup.playback, order: 90),
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
                currentVideoAsbConfig(settingsContext).doubleTapSeekSeconds,
            onChanged: (SettingsContext settingsContext, int value) async {
              await commitVideoAsbConfig(
                settingsContext,
                (VideoAsbplayerConfig c) =>
                    c.copyWith(doubleTapSeekSeconds: value),
              );
            },
          ),
          SettingsSwitchItem(
            id: 'video.playback.lock_window_aspect',
            title: t.video_setting_lock_window_aspect,
            icon: Icons.aspect_ratio_outlined,
            visible: (_) => isDesktopPlatform,
            video: VideoPlacement(group: VideoGroup.playback, order: 40),
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoLockWindowAspectRatio,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await setVideoLockWindowAspectRatioDual(settingsContext, value);
            },
          ),
          // 长按倍速 / 跳转步长 / 句末暂停都落在 videoAsbplayerConfig；无 host 时是
          // 全局默认（下次播放生效），host 在场经页面回调即时生效（与播放页内调一致）。
          SettingsSliderItem(
            id: 'video.playback.long_press_speed',
            title: t.video_setting_long_press_speed,
            subtitle: t.video_setting_long_press_speed_hint,
            icon: Icons.touch_app_outlined,
            video: VideoPlacement(group: VideoGroup.playback, order: 60),
            min: 1.0,
            max: 4.0,
            divisions: 30,
            step: 0.1,
            label: (double v) => '${v.toStringAsFixed(1)}x',
            value: (SettingsContext settingsContext) =>
                currentVideoAsbConfig(settingsContext).longPressSpeed,
            // 播放中拖动逐档即时写穿（旧面板即改即生效）；全局设置页维持松手才落盘。
            onChanged: (SettingsContext settingsContext, double v) async {
              if (!videoHostVisible(settingsContext)) return;
              await commitVideoAsbConfig(
                settingsContext,
                (VideoAsbplayerConfig c) =>
                    c.copyWith(longPressSpeed: snapVideoLongPressSpeed(v)),
              );
            },
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await commitVideoAsbConfig(
                settingsContext,
                (VideoAsbplayerConfig c) =>
                    c.copyWith(longPressSpeed: snapVideoLongPressSpeed(v)),
              );
            },
          ),
          SettingsStepperItem(
            id: 'video.playback.seek_seconds',
            title: t.video_setting_seek_seconds,
            icon: Icons.keyboard_double_arrow_right_outlined,
            video: VideoPlacement(group: VideoGroup.playback, order: 80),
            value: (SettingsContext settingsContext) =>
                currentVideoAsbConfig(settingsContext).seekSeconds.toDouble(),
            step: 1,
            min: 1,
            max: 30,
            format: (double v) => '${v.round()}s',
            onChanged: (SettingsContext settingsContext, double v) async {
              await commitVideoAsbConfig(
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
            // 面板里按语义归「字幕」分类（句尾自动暂停按字幕 cue 边界暂停）。
            video: VideoPlacement(group: VideoGroup.subtitle, order: 30),
            value: (SettingsContext settingsContext) =>
                currentVideoAsbConfig(settingsContext).pauseAtSubtitleEnd,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await commitVideoAsbConfig(
                settingsContext,
                (VideoAsbplayerConfig c) =>
                    c.copyWith(pauseAtSubtitleEnd: value),
              );
            },
          ),
          // 「重置控件布局」原独占一个「控件」section（仅此一项）；单项撑一个分区
          // 是欠填充结构，并入「播放」尾部。面板里归「控制」分类、排在拖拽编辑器后。
          SettingsActionItem(
            id: 'video.controls.reset_layout',
            title: t.video_control_reset_layout,
            icon: Icons.restart_alt_outlined,
            video: VideoPlacement(group: VideoGroup.controls, order: 20),
            onTap: (SettingsContext settingsContext) async {
              await resetVideoControlLayoutDual(settingsContext);
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.video_setting_mpv_group_quality,
        collapsedByDefault: true,
        items: <SettingsItem>[
          // 画质增强（mpv 内置高质量缩放开关）+ 解码 / 去色带 / 循环：这些 mpv 配置项
          // 都序列化进 videoMpvConfig，无 host 时下次打开视频 applyMpvConfigToPlayer
          // 应用，host 在场即改即生效。着色器档位选择需下载 + 文件系统，仍只在播放页
          // 「画质增强」分类里调（本开关在面板里由着色器管理视图承载，无 placement）。
          SettingsSwitchItem(
            id: 'video.quality.enhancement',
            title: t.video_shader_quality_tier,
            subtitle: t.video_quality_enhancement_hint,
            icon: Icons.auto_fix_high_outlined,
            value: (SettingsContext settingsContext) =>
                currentVideoMpvConfig(settingsContext).highQuality,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(highQuality: value),
              );
            },
          ),
          // S 形上采样（sigmoid-upscaling）：与「画质增强/着色器等级」并列的一档可选画质
          // 开关（TODO-1120/BUG-538）。默认关（性能占用偏大，见 VideoMpvConfig.defaults）。
          _videoMpvSwitchItem(
            id: 'video.quality.sigmoid',
            title: t.video_setting_mpv_sigmoid,
            subtitle: t.video_setting_mpv_sigmoid_hint,
            icon: Icons.show_chart_outlined,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 60,
              section: t.video_setting_mpv_group_quality,
            ),
            read: (VideoMpvConfig c) => c.sigmoidUpscaling,
            write: (VideoMpvConfig c, bool v) =>
                c.copyWith(sigmoidUpscaling: v),
          ),
          SettingsSegmentedItem<String>(
            id: 'video.quality.hwdec',
            title: t.video_setting_mpv_hwdec,
            icon: Icons.memory_outlined,
            dropdown: true,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 10,
              section: t.video_setting_mpv_group_decode,
            ),
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
                currentVideoMpvConfig(settingsContext).hwdec,
            onChanged: (SettingsContext settingsContext, String value) async {
              await commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(hwdec: value),
              );
            },
          ),
          _videoMpvSwitchItem(
            id: 'video.quality.deband',
            title: t.video_setting_mpv_deband,
            icon: Icons.gradient_outlined,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 20,
              section: t.video_setting_mpv_group_quality,
            ),
            read: (VideoMpvConfig c) => c.deband,
            write: (VideoMpvConfig c, bool v) => c.copyWith(deband: v),
          ),
          _videoMpvSwitchItem(
            id: 'video.quality.loop',
            title: t.video_setting_mpv_loop,
            icon: Icons.repeat_outlined,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 200,
              section: t.video_setting_mpv_group_playback,
            ),
            read: (VideoMpvConfig c) => c.loopFile,
            write: (VideoMpvConfig c, bool v) => c.copyWith(loopFile: v),
          ),
          // TODO-1247：把播放页内 mpv 画质组里的其余布尔项平移到首页（纯 pref），与播放
          // 页内设置同源，消除「首页改不了」。
          _videoMpvSwitchItem(
            id: 'video.quality.dither',
            title: t.video_setting_mpv_dither,
            icon: Icons.grain_outlined,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 30,
              section: t.video_setting_mpv_group_quality,
            ),
            read: (VideoMpvConfig c) => c.dither,
            write: (VideoMpvConfig c, bool v) => c.copyWith(dither: v),
          ),
          _videoMpvSwitchItem(
            id: 'video.quality.interpolation',
            title: t.video_setting_mpv_interpolation,
            icon: Icons.animation_outlined,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 40,
              section: t.video_setting_mpv_group_quality,
            ),
            read: (VideoMpvConfig c) => c.interpolation,
            write: (VideoMpvConfig c, bool v) => c.copyWith(interpolation: v),
          ),
          _videoMpvSwitchItem(
            id: 'video.quality.deinterlace',
            title: t.video_setting_mpv_deinterlace,
            icon: Icons.view_stream_outlined,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 50,
              section: t.video_setting_mpv_group_quality,
            ),
            read: (VideoMpvConfig c) => c.deinterlace,
            write: (VideoMpvConfig c, bool v) => c.copyWith(deinterlace: v),
          ),
          _videoMpvSwitchItem(
            id: 'video.quality.correct_downscale',
            title: t.video_setting_mpv_correct_downscale,
            icon: Icons.photo_size_select_small_outlined,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 70,
              section: t.video_setting_mpv_group_quality,
            ),
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
      // TODO-1247：播放页内 mpv「画面几何 / 色彩均衡 / 音频」详情与首页同源（同一
      // videoMpvConfig；无 host 下次开视频应用，host 在场即改即生效）。
      SettingsSection(
        title: t.video_setting_mpv_group_geometry,
        collapsedByDefault: true,
        items: <SettingsItem>[
          SettingsSegmentedItem<int>(
            id: 'video.geometry.rotate',
            title: t.video_setting_mpv_rotate,
            icon: Icons.screen_rotation_outlined,
            dropdown: true,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 80,
              section: t.video_setting_mpv_group_geometry,
            ),
            options: const <SettingsSegmentOption<int>>[
              SettingsSegmentOption<int>(value: 0, label: '0°'),
              SettingsSegmentOption<int>(value: 90, label: '90°'),
              SettingsSegmentOption<int>(value: 180, label: '180°'),
              SettingsSegmentOption<int>(value: 270, label: '270°'),
            ],
            selected: (SettingsContext settingsContext) =>
                currentVideoMpvConfig(settingsContext).videoRotate,
            onChanged: (SettingsContext settingsContext, int value) async {
              await commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(videoRotate: value),
              );
            },
          ),
          SettingsSegmentedItem<String>(
            id: 'video.geometry.aspect',
            title: t.video_setting_mpv_aspect,
            icon: Icons.aspect_ratio_outlined,
            dropdown: true,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 90,
              section: t.video_setting_mpv_group_geometry,
            ),
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
                currentVideoMpvConfig(settingsContext).aspectOverride,
            onChanged: (SettingsContext settingsContext, String value) async {
              await commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(aspectOverride: value),
              );
            },
          ),
          SettingsSliderItem(
            id: 'video.geometry.zoom',
            title: t.video_setting_mpv_zoom,
            icon: Icons.zoom_out_map_outlined,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 100,
              section: t.video_setting_mpv_group_geometry,
            ),
            min: -2,
            max: 2,
            divisions: 40,
            label: (double v) => v.toStringAsFixed(2),
            value: (SettingsContext settingsContext) =>
                currentVideoMpvConfig(settingsContext).videoZoom.clamp(-2, 2),
            // 播放中拖动逐 tick 写穿实时生效（旧面板行为）；全局设置页松手才落盘。
            onChanged: (SettingsContext settingsContext, double v) async {
              if (!videoHostVisible(settingsContext)) return;
              await commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(videoZoom: v),
              );
            },
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(videoZoom: v),
              );
            },
          ),
          SettingsSliderItem(
            id: 'video.geometry.panscan',
            title: t.video_setting_mpv_panscan,
            icon: Icons.crop_outlined,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 110,
              section: t.video_setting_mpv_group_geometry,
            ),
            min: 0,
            max: 1,
            divisions: 20,
            label: (double v) => v.toStringAsFixed(2),
            value: (SettingsContext settingsContext) =>
                currentVideoMpvConfig(settingsContext).panscan.clamp(0, 1),
            onChanged: (SettingsContext settingsContext, double v) async {
              if (!videoHostVisible(settingsContext)) return;
              await commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(panscan: v),
              );
            },
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(panscan: v),
              );
            },
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
            order: 120,
            read: (VideoMpvConfig c) => c.brightness,
            write: (VideoMpvConfig c, int v) => c.copyWith(brightness: v),
          ),
          _videoMpvColorSliderItem(
            id: 'video.color.contrast',
            title: t.video_setting_mpv_contrast,
            icon: Icons.contrast_outlined,
            order: 130,
            read: (VideoMpvConfig c) => c.contrast,
            write: (VideoMpvConfig c, int v) => c.copyWith(contrast: v),
          ),
          _videoMpvColorSliderItem(
            id: 'video.color.saturation',
            title: t.video_setting_mpv_saturation,
            icon: Icons.invert_colors_outlined,
            order: 140,
            read: (VideoMpvConfig c) => c.saturation,
            write: (VideoMpvConfig c, int v) => c.copyWith(saturation: v),
          ),
          _videoMpvColorSliderItem(
            id: 'video.color.gamma',
            title: t.video_setting_mpv_gamma,
            icon: Icons.tonality_outlined,
            order: 150,
            read: (VideoMpvConfig c) => c.gamma,
            write: (VideoMpvConfig c, int v) => c.copyWith(gamma: v),
          ),
          _videoMpvColorSliderItem(
            id: 'video.color.hue',
            title: t.video_setting_mpv_hue,
            icon: Icons.colorize_outlined,
            order: 160,
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
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 170,
              section: t.video_setting_mpv_group_audio,
            ),
            read: (VideoMpvConfig c) => c.audioPitchCorrection,
            write: (VideoMpvConfig c, bool v) =>
                c.copyWith(audioPitchCorrection: v),
          ),
          SettingsSegmentedItem<String>(
            id: 'video.audio.channels',
            title: t.video_setting_mpv_channels,
            icon: Icons.surround_sound_outlined,
            dropdown: true,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 180,
              section: t.video_setting_mpv_group_audio,
            ),
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
                currentVideoMpvConfig(settingsContext).audioChannels,
            onChanged: (SettingsContext settingsContext, String value) async {
              await commitVideoMpvConfig(
                settingsContext,
                (VideoMpvConfig c) => c.copyWith(audioChannels: value),
              );
            },
          ),
          _videoMpvSwitchItem(
            id: 'video.audio.normalize_downmix',
            title: t.video_setting_mpv_normalize,
            icon: Icons.volume_up_outlined,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 190,
              section: t.video_setting_mpv_group_audio,
            ),
            read: (VideoMpvConfig c) => c.normalizeDownmix,
            write: (VideoMpvConfig c, bool v) =>
                c.copyWith(normalizeDownmix: v),
          ),
        ],
      ),
      SettingsSection(
        title: t.section_video_subtitles,
        items: <SettingsItem>[
          // TODO-840 Part B：遮蔽模式三态选择器——不遮蔽 / 模糊（听力沉浸）/ 隐藏。
          // 持久化是 preferences 层 lazy 投影（见
          // [PreferencesRepository.videoSubtitleObscureMode]），无新 Drift schema。
          SettingsSegmentedItem<VideoSubtitleObscureMode>(
            id: 'video.subtitle.obscure',
            title: t.video_setting_subtitle_obscure,
            subtitle: t.video_setting_subtitle_obscure_hint,
            icon: Icons.blur_on_outlined,
            video: VideoPlacement(group: VideoGroup.subtitle, order: 40),
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
              await setVideoSubtitleObscureModeDual(settingsContext, mode);
            },
          ),
          // TODO-1382：副字幕遮蔽三态（镜像主字幕，独立开关）。快捷键 Shift+G 循环、
          // Shift+H 隐藏。
          SettingsSegmentedItem<VideoSubtitleObscureMode>(
            id: 'video.secondary_subtitle.obscure',
            title: t.video_setting_secondary_subtitle_obscure,
            subtitle: t.video_setting_secondary_subtitle_obscure_hint,
            icon: Icons.blur_on_outlined,
            video: VideoPlacement(group: VideoGroup.subtitle, order: 50),
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
              await setVideoSecondarySubtitleObscureModeDual(
                settingsContext,
                mode,
              );
            },
          ),
          // TODO-1105：尊重 .ass 自带样式开关。开时字幕优先用 .ass 的字体/主色/描边/
          // 阴影，缺失回退统一外观；关时全走统一外观。默认开。
          SettingsSwitchItem(
            id: 'video.subtitle.respect_ass_style',
            title: t.video_setting_subtitle_respect_ass,
            subtitle: t.video_setting_subtitle_respect_ass_hint,
            icon: Icons.style_outlined,
            video: VideoPlacement(
              group: VideoGroup.subtitle,
              order: 60,
              section: t.video_setting_subtitle_appearance,
            ),
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoRespectAssStyle,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await setVideoRespectAssStyleDual(settingsContext, value);
              settingsContext.refresh();
            },
          ),
          // 字幕外观（字号/字重/阴影/背景不透明度/位置）全序列化进 videoSubtitleStyle。
          // 全局设置页无实时预览（没有 overlay），落盘后下次播放生效；播放中拖动经
          // host 实时预览、松手落盘。字重/阴影粗细在 style 里以 null=「跟随界面缩放」
          // 存储，这里只在用户显式拖动时写显式值，不主动把默认折成显式值。
          SettingsSliderItem(
            id: 'video.subtitle.font_size',
            title: t.video_setting_subtitle_font_size,
            icon: Icons.format_size_outlined,
            video: VideoPlacement(
              group: VideoGroup.subtitle,
              order: 70,
              section: t.video_setting_subtitle_appearance,
            ),
            min: 12,
            max: 48,
            divisions: 36,
            label: (double v) => v.round().toString(),
            value: (SettingsContext settingsContext) =>
                currentVideoSubtitleStyle(settingsContext)
                    .fontSize
                    .clamp(12, 48),
            onChanged: (SettingsContext settingsContext, double v) {
              previewVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(fontSize: v),
              );
            },
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(fontSize: v),
              );
            },
          ),
          SettingsStepperItem(
            id: 'video.subtitle.font_weight',
            title: t.video_setting_subtitle_font_weight,
            icon: Icons.format_bold,
            video: VideoPlacement(
              group: VideoGroup.subtitle,
              order: 80,
              section: t.video_setting_subtitle_appearance,
            ),
            value: (SettingsContext settingsContext) =>
                currentVideoSubtitleStyle(settingsContext)
                    .resolveFontWeight(videoSubtitleUiScale(settingsContext))
                    .toDouble(),
            step: 100,
            min: 100,
            max: 900,
            format: (double v) => v.round().toString(),
            onChanged: (SettingsContext settingsContext, double v) async {
              await commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(fontWeight: v.round()),
              );
            },
          ),
          SettingsSliderItem(
            id: 'video.subtitle.shadow',
            title: t.video_setting_subtitle_shadow,
            icon: Icons.format_color_text_outlined,
            video: VideoPlacement(
              group: VideoGroup.subtitle,
              order: 100,
              section: t.video_setting_subtitle_appearance,
            ),
            min: 0,
            max: 12,
            divisions: 12,
            label: (double v) => '${v.round()}px',
            value: (SettingsContext settingsContext) =>
                currentVideoSubtitleStyle(settingsContext)
                    .resolveShadowThickness(
                      videoSubtitleUiScale(settingsContext),
                    )
                    .clamp(0, 12),
            onChanged: (SettingsContext settingsContext, double v) {
              previewVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(shadowThickness: v),
              );
            },
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(shadowThickness: v),
              );
            },
          ),
          SettingsSliderItem(
            id: 'video.subtitle.bg_opacity',
            title: t.video_setting_subtitle_bg_opacity,
            icon: Icons.opacity_outlined,
            video: VideoPlacement(
              group: VideoGroup.subtitle,
              order: 110,
              section: t.video_setting_subtitle_appearance,
            ),
            divisions: 20,
            value: (SettingsContext settingsContext) =>
                currentVideoSubtitleStyle(settingsContext)
                    .backgroundOpacity
                    .clamp(0, 1),
            onChanged: (SettingsContext settingsContext, double v) {
              previewVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(backgroundOpacity: v),
              );
            },
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(backgroundOpacity: v),
              );
            },
          ),
          SettingsSliderItem(
            id: 'video.subtitle.position',
            title: t.video_setting_subtitle_position,
            icon: Icons.height_outlined,
            video: VideoPlacement(
              group: VideoGroup.subtitle,
              order: 140,
              section: t.video_setting_subtitle_appearance,
            ),
            min: 0,
            max: 240,
            divisions: 24,
            value: (SettingsContext settingsContext) =>
                currentVideoSubtitleStyle(settingsContext)
                    .bottomPadding
                    .clamp(0, 240),
            onChanged: (SettingsContext settingsContext, double v) {
              previewVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(bottomPadding: v),
              );
            },
            onChangeEnd: (SettingsContext settingsContext, double v) async {
              await commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(bottomPadding: v),
              );
            },
          ),
        ],
      ),
      SettingsSection(
        title: t.section_video_danmaku,
        collapsedByDefault: true,
        items: <SettingsItem>[
          // 弹幕开关 / 在线匹配 / 同屏上限都是纯 pref，与播放页内弹幕设置语义一致；
          // 无 host 下次播放生效，host 在场即时重载/清空弹幕层。
          SettingsSwitchItem(
            id: 'video.danmaku.enabled',
            title: t.video_setting_danmaku_enabled,
            subtitle: t.video_setting_danmaku_enabled_hint,
            icon: Icons.forum_outlined,
            video: VideoPlacement(group: VideoGroup.danmaku, order: 10),
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoDanmakuEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await setVideoDanmakuEnabledDual(settingsContext, value);
            },
          ),
          SettingsSwitchItem(
            id: 'video.danmaku.online',
            title: t.video_setting_danmaku_online,
            subtitle: t.video_setting_danmaku_online_hint,
            icon: Icons.cloud_sync_outlined,
            video: VideoPlacement(group: VideoGroup.danmaku, order: 20),
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoDanmakuOnlineEnabled,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await setVideoDanmakuOnlineEnabledDual(settingsContext, value);
            },
          ),
          SettingsStepperItem(
            id: 'video.danmaku.max_active',
            title: t.video_setting_danmaku_max_active,
            subtitle: t.video_setting_danmaku_max_active_hint,
            icon: Icons.speed_outlined,
            video: VideoPlacement(group: VideoGroup.danmaku, order: 40),
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoDanmakuMaxActive.toDouble(),
            step: 10,
            min: 10,
            max: kMaxVideoDanmakuActive.toDouble(),
            format: (double v) => v.round().toString(),
            onChanged: (SettingsContext settingsContext, double v) async {
              await setVideoDanmakuMaxActiveDual(settingsContext, v.round());
            },
          ),
          // 弹幕来源配置只剩自建/镜像 Dandanplay 服务器地址（高级项，空=官方
          // api.dandanplay.net）。官方 AppId/AppSecret 已内置（dandanplay_secret.dart，
          // 见 DandanplayConfig.embeddedAppId），请求自动 v2 签名，用户**无需手动输入
          // API**——故原 AppId/AppSecret 两个输入框已删除。写入 videoDanmakuConfig
          // （纯 pref），同步推进程级 DandanplayConfig.current，下次匹配弹幕即生效。
          SettingsTextItem(
            id: 'video.danmaku.server_url',
            title: t.video_setting_danmaku_server_url,
            icon: Icons.dns_outlined,
            keyboardType: TextInputType.url,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoDanmakuConfig.baseUrl,
            onChanged: (SettingsContext settingsContext, String value) async {
              await _commitVideoDanmakuConfig(
                settingsContext,
                (DandanplayConfig c) => c.copyWith(baseUrl: value.trim()),
              );
            },
          ),
        ],
      ),
      // ── 播放中专属（控制器绑定 / 仅播放页有意义）───────────────────────────
      // 全部 host 门控：全局设置页 `SettingsContext.video == null` 恒隐藏（本 section
      // 渲染为空被丢弃），播放页面板经 VideoPlacement 投影到对应分类。builder 集中在
      // video_settings_actions.dart（settings/ 不引播放器依赖）。
      SettingsSection(
        items: <SettingsItem>[
          // TODO-1158：HLS 多档画质入口（仅当前流是 HLS master 时显示）。
          SettingsCustomItem(
            id: 'video.player.quality_entry',
            visible: (SettingsContext c) {
              final int count =
                  videoQuickSettingsHostOf(c)?.qualityOptionCount ?? 0;
              return count > 0 &&
                  videoQuickSettingsHostOf(c)?.onOpenQuality != null;
            },
            video: VideoPlacement(group: VideoGroup.playback, order: 10),
            builder: buildVideoQualityEntryRow,
          ),
          // TODO-1232 / BUG-597：「切 Skia 渲染器并重启」黑屏降级入口。
          SettingsCustomItem(
            id: 'video.player.skia_fallback',
            visible: (SettingsContext c) =>
                videoQuickSettingsHostOf(c)?.onSwitchToSkiaRenderer != null,
            video: VideoPlacement(group: VideoGroup.playback, order: 20),
            builder: buildVideoSkiaFallbackRow,
          ),
          // 倍速：MD3 全长滑条（0.5–2.0，0.1 步）；拖动实时预览（下发真实播放倍速，
          // 不落盘），松手提交并持久化。
          SettingsSliderItem(
            id: 'video.player.speed',
            title: t.video_setting_speed,
            icon: Icons.speed_outlined,
            visible: videoHostVisible,
            video: VideoPlacement(group: VideoGroup.playback, order: 50),
            min: 0.5,
            max: 2.0,
            divisions: 15,
            label: (double v) => '${v.toStringAsFixed(1)}x',
            value: (SettingsContext c) =>
                snapVideoSpeed(videoQuickSettingsHostOf(c)!.speed()),
            onChanged: (SettingsContext c, double v) async {
              await videoQuickSettingsHostOf(c)!
                  .onPreviewSpeed(snapVideoSpeed(v));
            },
            onChangeEnd: (SettingsContext c, double v) async {
              await videoQuickSettingsHostOf(c)!.onSetSpeed(snapVideoSpeed(v));
            },
          ),
          // 倍速快捷键步进（+/- 每按一次的增量）。
          SettingsStepperItem(
            id: 'video.playback.speed_step',
            title: t.video_setting_speed_step,
            icon: Icons.speed_outlined,
            visible: videoHostVisible,
            video: VideoPlacement(group: VideoGroup.playback, order: 100),
            value: (SettingsContext c) => currentVideoAsbConfig(c).speedStep,
            step: 0.05,
            min: 0.05,
            max: 0.5,
            format: (double v) => v.toStringAsFixed(2),
            onChanged: (SettingsContext c, double v) async {
              await commitVideoAsbConfig(
                c,
                (VideoAsbplayerConfig a) => a.copyWith(
                  speedStep: double.parse(v.toStringAsFixed(2)),
                ),
              );
            },
          ),
          // TODO-1351：音频轨切换区（「音频」分类，参考「检查器」音频 tab）。
          SettingsCustomItem(
            id: 'video.player.audio_track',
            visible: videoHostVisible,
            video: VideoPlacement(
              group: VideoGroup.audio,
              order: 10,
              section: t.video_audio_track,
            ),
            builder: buildVideoAudioTrackSection,
          ),
          // TODO-1351：字幕轨/字幕源切换区（「字幕」分类顶部）。
          SettingsCustomItem(
            id: 'video.player.subtitle_track',
            visible: (SettingsContext c) =>
                videoQuickSettingsHostOf(c)?.subtitleTrackSection != null,
            video: VideoPlacement(
              group: VideoGroup.subtitle,
              order: 10,
              section: t.video_menu_subtitle_track,
            ),
            builder: buildVideoSubtitleTrackSection,
          ),
          // 字幕调轴（A/V 延迟 + 自动对轴 + 波形对轴入口）。
          SettingsCustomItem(
            id: 'video.player.subtitle_sync',
            visible: videoHostVisible,
            video: VideoPlacement(group: VideoGroup.subtitle, order: 20),
            builder: buildVideoSubtitleSyncRow,
          ),
          // 字幕**文字**颜色调色盘行（TODO-1326）。
          SettingsCustomItem(
            id: 'video.player.subtitle_text_color',
            visible: videoHostVisible,
            video: VideoPlacement(
              group: VideoGroup.subtitle,
              order: 90,
              section: t.video_setting_subtitle_appearance,
            ),
            builder: buildVideoSubtitleTextColorRow,
          ),
          // 一键无背景：与相邻 bg_opacity 滑到 0 等效的便捷动作，全局设置页有意不
          // 单列（冗余），播放页快捷面板保留。
          SettingsActionItem(
            id: 'video.subtitle.no_background',
            title: t.video_setting_subtitle_no_background,
            subtitle: t.video_setting_subtitle_no_background_hint,
            icon: Icons.format_color_reset_outlined,
            visible: videoHostVisible,
            video: VideoPlacement(
              group: VideoGroup.subtitle,
              order: 120,
              section: t.video_setting_subtitle_appearance,
            ),
            onTap: (SettingsContext c) async {
              await commitVideoSubtitleStyle(
                c,
                (VideoSubtitleStyle s) => s.copyWith(backgroundOpacity: 0),
              );
            },
          ),
          // TODO-1059：字幕背景颜色调色盘行。
          SettingsCustomItem(
            id: 'video.player.subtitle_bg_color',
            visible: videoHostVisible,
            video: VideoPlacement(
              group: VideoGroup.subtitle,
              order: 130,
              section: t.video_setting_subtitle_appearance,
            ),
            builder: buildVideoSubtitleBgColorRow,
          ),
          SettingsActionItem(
            id: 'video.player.subtitle_style_reset',
            title: t.video_setting_subtitle_reset,
            icon: Icons.restart_alt_outlined,
            visible: videoHostVisible,
            video: VideoPlacement(
              group: VideoGroup.subtitle,
              order: 150,
              section: t.video_setting_subtitle_appearance,
            ),
            onTap: (SettingsContext c) async {
              await commitVideoSubtitleStyle(
                c,
                (VideoSubtitleStyle _) => VideoSubtitleStyle.defaults,
              );
            },
          ),
          // 着色器内嵌管理视图（导入/发现/下载/勾选/一键选档，需文件系统 + 实时应用）。
          SettingsCustomItem(
            id: 'video.player.shaders',
            visible: videoHostVisible,
            video: VideoPlacement(group: VideoGroup.shaders, order: 10),
            builder: buildVideoShaderManager,
          ),
          // 原始 mpv.conf 多行逃生口（高级）。
          SettingsCustomItem(
            id: 'video.player.mpv_raw',
            visible: videoHostVisible,
            video: VideoPlacement(
              group: VideoGroup.mpv,
              order: 210,
              section: t.video_setting_mpv_group_advanced,
            ),
            builder: buildVideoMpvRawConfField,
          ),
          // 重置：全部回 mpv 默认（含清空原始 conf 框，经 pref 回填输入框）。
          SettingsActionItem(
            id: 'video.player.mpv_reset',
            title: t.video_setting_mpv_reset,
            icon: Icons.restart_alt_outlined,
            visible: videoHostVisible,
            video: VideoPlacement(group: VideoGroup.mpv, order: 220),
            onTap: (SettingsContext c) async {
              await commitVideoMpvConfig(
                c,
                (VideoMpvConfig _) => VideoMpvConfig.defaults,
              );
            },
          ),
          // TODO-1376：自动匹配失败/错集时的手动搜索选集入口（回调由视频页开搜索侧栏）。
          SettingsNavigationItem(
            id: 'video.player.danmaku_manual_match',
            title: t.video_setting_danmaku_manual_match,
            subtitle: t.video_setting_danmaku_manual_match_hint,
            icon: Icons.manage_search_outlined,
            showIcon: true,
            visible: (SettingsContext c) =>
                videoQuickSettingsHostOf(c)?.onManualDanmakuMatch != null,
            video: VideoPlacement(group: VideoGroup.danmaku, order: 30),
            onTap: (SettingsContext c) {
              videoQuickSettingsHostOf(c)!.onManualDanmakuMatch!();
            },
          ),
          // TODO-1376：弹幕样式（字号/不透明度/速度/显示区域）。拖动即时预览，松手落盘。
          _videoDanmakuStyleSliderItem(
            id: 'video.danmaku.font_scale',
            title: t.video_setting_danmaku_font_scale,
            subtitle: t.video_setting_danmaku_font_scale_hint,
            icon: Icons.format_size_outlined,
            order: 50,
            min: VideoDanmakuStyle.minFontScale,
            max: VideoDanmakuStyle.maxFontScale,
            divisions: 15,
            step: 0.1,
            label: (double v) => '${v.toStringAsFixed(1)}x',
            read: (VideoDanmakuStyle s) => s.fontScale,
            write: (VideoDanmakuStyle s, double v) => s.copyWith(fontScale: v),
          ),
          _videoDanmakuStyleSliderItem(
            id: 'video.danmaku.opacity',
            title: t.video_setting_danmaku_opacity,
            subtitle: t.video_setting_danmaku_opacity_hint,
            icon: Icons.opacity_outlined,
            order: 60,
            min: VideoDanmakuStyle.minOpacity,
            max: VideoDanmakuStyle.maxOpacity,
            divisions: 9,
            step: 0.1,
            label: (double v) => '${(v * 100).round()}%',
            read: (VideoDanmakuStyle s) => s.opacity,
            write: (VideoDanmakuStyle s, double v) => s.copyWith(opacity: v),
          ),
          _videoDanmakuStyleSliderItem(
            id: 'video.danmaku.speed',
            title: t.video_setting_danmaku_speed,
            subtitle: t.video_setting_danmaku_speed_hint,
            icon: Icons.fast_forward_outlined,
            order: 70,
            min: VideoDanmakuStyle.minSpeedScale,
            max: VideoDanmakuStyle.maxSpeedScale,
            divisions: 15,
            step: 0.1,
            label: (double v) => '${v.toStringAsFixed(1)}x',
            read: (VideoDanmakuStyle s) => s.speedScale,
            write: (VideoDanmakuStyle s, double v) => s.copyWith(speedScale: v),
          ),
          _videoDanmakuStyleSliderItem(
            id: 'video.danmaku.area',
            title: t.video_setting_danmaku_area,
            subtitle: t.video_setting_danmaku_area_hint,
            icon: Icons.vertical_align_top_outlined,
            order: 80,
            min: VideoDanmakuStyle.minAreaFraction,
            max: VideoDanmakuStyle.maxAreaFraction,
            divisions: 15,
            step: 0.05,
            label: (double v) => '${(v * 100).round()}%',
            read: (VideoDanmakuStyle s) => s.areaFraction,
            write: (VideoDanmakuStyle s, double v) =>
                s.copyWith(areaFraction: v),
          ),
          // TODO-1376：弹幕屏蔽词/正则过滤（多行文本）。
          SettingsCustomItem(
            id: 'video.player.danmaku_block_rules',
            visible: videoHostVisible,
            video: VideoPlacement(
              group: VideoGroup.danmaku,
              order: 90,
              section: t.video_setting_danmaku_block_rules,
            ),
            builder: buildVideoDanmakuBlockRulesField,
          ),
          // 控制条 9 槽位拖拽编辑器（TODO-274/312 phase 2）。
          SettingsCustomItem(
            id: 'video.player.controls_editor',
            visible: videoHostVisible,
            video: VideoPlacement(group: VideoGroup.controls, order: 10),
            builder: buildVideoControlLayoutEditor,
          ),
        ],
      ),
    ],
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

/// mpv 布尔开关的声明模板：读写同一 [AppModel.videoMpvConfig]，无 host 落 pref
/// 下次生效，host 在场即改即生效（commitVideoMpvConfig 双路写穿）。
SettingsSwitchItem _videoMpvSwitchItem({
  required String id,
  required String title,
  required IconData icon,
  required bool Function(VideoMpvConfig config) read,
  required VideoMpvConfig Function(VideoMpvConfig config, bool value) write,
  String? subtitle,
  VideoPlacement? video,
}) {
  return SettingsSwitchItem(
    id: id,
    title: title,
    subtitle: subtitle,
    icon: icon,
    video: video,
    value: (SettingsContext settingsContext) =>
        read(currentVideoMpvConfig(settingsContext)),
    onChanged: (SettingsContext settingsContext, bool value) async {
      await commitVideoMpvConfig(
        settingsContext,
        (VideoMpvConfig config) => write(config, value),
      );
    },
  );
}

/// mpv 色彩均衡滑条（-100..100 整数）：全局设置页松手（onChangeEnd）才落盘避免每
/// tick 写 DB；播放中拖动逐 tick 写穿实时生效（旧面板行为）。
SettingsSliderItem _videoMpvColorSliderItem({
  required String id,
  required String title,
  required IconData icon,
  required int order,
  required int Function(VideoMpvConfig config) read,
  required VideoMpvConfig Function(VideoMpvConfig config, int value) write,
}) {
  return SettingsSliderItem(
    id: id,
    title: title,
    icon: icon,
    video: VideoPlacement(
      group: VideoGroup.mpv,
      order: order,
      section: t.video_setting_mpv_group_color,
    ),
    min: -100,
    max: 100,
    divisions: 200,
    label: (double v) => v.round().toString(),
    value: (SettingsContext settingsContext) =>
        read(currentVideoMpvConfig(settingsContext))
            .toDouble()
            .clamp(-100, 100),
    onChanged: (SettingsContext settingsContext, double v) async {
      if (!videoHostVisible(settingsContext)) return;
      await commitVideoMpvConfig(
        settingsContext,
        (VideoMpvConfig config) => write(config, v.round()),
      );
    },
    onChangeEnd: (SettingsContext settingsContext, double v) async {
      await commitVideoMpvConfig(
        settingsContext,
        (VideoMpvConfig config) => write(config, v.round()),
      );
    },
  );
}

/// 弹幕样式滑条的声明模板（TODO-1376）：拖动经 host 即时预览，松手落盘。仅播放中
/// 可见（全局设置页无弹幕层可预览；纯 pref 化入首页留给阶段 C 决策）。
SettingsSliderItem _videoDanmakuStyleSliderItem({
  required String id,
  required String title,
  required String subtitle,
  required IconData icon,
  required int order,
  required double min,
  required double max,
  required int divisions,
  required double step,
  required String Function(double value) label,
  required double Function(VideoDanmakuStyle style) read,
  required VideoDanmakuStyle Function(VideoDanmakuStyle style, double value)
      write,
}) {
  return SettingsSliderItem(
    id: id,
    title: title,
    subtitle: subtitle,
    icon: icon,
    visible: videoHostVisible,
    video: VideoPlacement(group: VideoGroup.danmaku, order: order),
    min: min,
    max: max,
    divisions: divisions,
    step: step,
    label: label,
    titleReadout: true,
    value: (SettingsContext c) => read(currentVideoDanmakuStyle(c)),
    onChanged: (SettingsContext c, double v) {
      previewVideoDanmakuStyle(c, (VideoDanmakuStyle s) => write(s, v));
    },
    onChangeEnd: (SettingsContext c, double v) async {
      await commitVideoDanmakuStyle(c, (VideoDanmakuStyle s) => write(s, v));
    },
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
