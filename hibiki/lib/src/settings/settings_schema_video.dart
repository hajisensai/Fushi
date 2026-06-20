import 'package:flutter/material.dart';
import 'package:hibiki/src/media/video/dandanplay_client.dart';
import 'package:hibiki/src/media/video/video_asbplayer_config.dart';
import 'package:hibiki/src/media/video/video_control_customization.dart';
import 'package:hibiki/src/media/video/video_danmaku_model.dart';
import 'package:hibiki/src/media/video/video_immersive_mode.dart';
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
            subtitle: t.video_setting_picture_fit_hint,
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
            subtitle: t.video_setting_long_press_speed_hint,
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
        ],
      ),
      SettingsSection(
        title: t.video_settings_cat_controls,
        items: <SettingsItem>[
          SettingsActionItem(
            id: 'video.controls.reset_layout',
            title: t.video_control_reset_layout,
            subtitle: t.video_control_reset_layout_hint,
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
        ],
      ),
      SettingsSection(
        title: t.section_video_subtitles,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'video.subtitle.blur',
            title: t.video_setting_subtitle_blur,
            subtitle: t.video_setting_subtitle_blur_hint,
            icon: Icons.blur_on_outlined,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.videoSubtitleBlur,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setVideoSubtitleBlur(value);
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
          SettingsActionItem(
            id: 'video.subtitle.no_background',
            title: t.video_setting_subtitle_no_background,
            subtitle: t.video_setting_subtitle_no_background_hint,
            icon: Icons.format_color_reset_outlined,
            onTap: (SettingsContext settingsContext) async {
              await _commitVideoSubtitleStyle(
                settingsContext,
                (VideoSubtitleStyle s) => s.copyWith(backgroundOpacity: 0),
              );
            },
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
          // TODO-277：弹幕来源配置——自建/镜像 Dandanplay 服务器地址 + 可选 API 凭据。
          // 空地址=用官方 api.dandanplay.net；AppId/AppSecret 同时填写时按 v2 签名请求。
          // 写入 videoDanmakuConfig（纯 pref），同步推进程级 DandanplayConfig.current，
          // 下次匹配弹幕即生效（播放页里无参构造的 DandanplayClient 自动读取）。
          SettingsCustomItem(
            id: 'video.danmaku.server_url',
            builder: _buildDanmakuServerField,
          ),
          SettingsCustomItem(
            id: 'video.danmaku.app_id',
            builder: _buildDanmakuAppIdField,
          ),
          SettingsCustomItem(
            id: 'video.danmaku.app_secret',
            builder: _buildDanmakuAppSecretField,
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

Widget _buildDanmakuAppIdField(SettingsContext settingsContext) {
  return SettingsSecretField(
    title: t.video_setting_danmaku_app_id,
    icon: Icons.badge_outlined,
    initialValue: settingsContext.appModel.videoDanmakuConfig.appId,
    onChanged: (String value) async {
      await _commitVideoDanmakuConfig(
        settingsContext,
        (DandanplayConfig c) => c.copyWith(appId: value.trim()),
      );
    },
  );
}

Widget _buildDanmakuAppSecretField(SettingsContext settingsContext) {
  return SettingsSecretField(
    title: t.video_setting_danmaku_app_secret,
    icon: Icons.key_outlined,
    initialValue: settingsContext.appModel.videoDanmakuConfig.appSecret,
    obscureText: true,
    keyboardType: TextInputType.visiblePassword,
    onChanged: (String value) async {
      await _commitVideoDanmakuConfig(
        settingsContext,
        (DandanplayConfig c) => c.copyWith(appSecret: value.trim()),
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
    case VideoImmersiveMode.seekAndLookup:
      return t.video_immersive_mode_seek_lookup;
    case VideoImmersiveMode.lookupOnly:
      return t.video_immersive_mode_lookup_only;
    case VideoImmersiveMode.unlockOnly:
      return t.video_immersive_mode_unlock_only;
  }
}
