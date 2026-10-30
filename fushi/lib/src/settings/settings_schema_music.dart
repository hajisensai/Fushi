import 'dart:async';

import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_stage_plan.dart'
    show MusicAssRenderPreference;
import 'package:fushi/src/media/music/metadata/music_scrape_service.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_crossfade.dart';
import 'package:fushi/src/media/music/music_equalizer.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/server/music_servers.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/media/music/plugin/music_plugin_gate.dart';
import 'package:fushi/src/pages/implementations/music/music_library_page.dart'
    show showMusicSourcesDialog;
import 'package:fushi/src/pages/implementations/music/music_lyrics_backdrop.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_providers.dart';
import 'package:fushi/src/pages/implementations/music/music_plugin_settings.dart';
import 'package:fushi/src/pages/implementations/music/music_server_settings.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「音乐」一级设置分类（音乐模块，docs/specs/2026-10-23-music-module-design.md §11.1）：
/// 曲库入口 + 播放（无缝 / ReplayGain）。与 music 顶层 tab 同一个模块门。
///
/// 音乐来源（文件夹）的管理是库页共用的来源管理对话框（[MediaSourcesDialog]，
/// 曲库页顶栏同一个入口）；这里只是又一条路进同一间屋子，不另做一份。「曲库」那行
/// 只是跳到音乐页，副标题照实说，不再写成「来源」（用户 2026-10-30：点了直接跳页、
/// 文案却像能管理来源）。
SettingsDestination buildMusicDestination() {
  return SettingsDestination(
    id: SettingsDestinationId.music,
    title: t.nav_music,
    summary: t.music_settings_summary,
    // 图标与底栏 / 侧栏同一真值。
    icon: homeNavItemFor(HomeTab.music).icon,
    visible: (SettingsContext c) => isSettingsDestinationVisible(
      SettingsDestinationId.music,
      c.appModel.moduleVisibility,
    ),
    sections: <SettingsSection>[
      SettingsSection(
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'music.library',
            title: t.music_open_library,
            subtitle: t.music_open_library_hint,
            icon: FushiIcons.music,
            showIcon: true,
            onTap: (SettingsContext settingsContext) {
              homeShellTabNotifier.value = HomeTab.music;
            },
          ),
          SettingsNavigationItem(
            id: 'music.sources',
            title: t.music_sources_manage,
            icon: FushiIcons.libraryAdd,
            showIcon: true,
            onTap: (SettingsContext settingsContext) =>
                showMusicSourcesDialog(settingsContext.context),
          ),
        ],
      ),
      SettingsSection(
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'music.gapless',
            title: t.music_gapless_title,
            subtitle: t.music_gapless_hint,
            icon: FushiIcons.playlist,
            defaultValue: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.musicGapless,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setMusicGapless(value);
            },
          ),
          // 交叉淡入（设计 §7.2）：双 libmpv 实例、逐样本等功率曲线；独占 / 硬件直出时
          // 后端自动停用（musicCrossfadeAvailability），这里与信号路径面板都标出来。
          SettingsSliderItem(
            id: 'music.crossfade',
            title: t.music_crossfade_title,
            subtitle: t.music_crossfade_hint,
            icon: FushiIcons.playlist,
            min: 0,
            max: 12,
            divisions: 12,
            defaultValue: 0,
            titleReadout: true,
            commitOnRelease: true,
            label: (double v) =>
                v.round() == 0 ? t.music_crossfade_off : '${v.round()} s',
            value: (SettingsContext c) => c.appModel.musicCrossfadeMs / 1000,
            onChanged: (SettingsContext c, double v) =>
                c.appModel.setMusicCrossfadeMs(v.round() * 1000),
          ),
          SettingsSwitchItem(
            id: 'music.crossfade_continuous',
            title: t.music_crossfade_continuous_title,
            subtitleBuilder: (SettingsContext c) =>
                switch (musicCrossfadeAvailability(
                  c.appModel.musicSession.engine.currentSettings,
                  platform: musicOutputPlatformOfHost(),
                )) {
                  MusicCrossfadeAvailability.disabledByExclusive =>
                    t.music_crossfade_disabled_exclusive,
                  MusicCrossfadeAvailability.disabledByDirectDevice =>
                    t.music_crossfade_disabled_direct,
                  MusicCrossfadeAvailability.off ||
                  MusicCrossfadeAvailability.available =>
                    t.music_crossfade_continuous_hint,
                },
            icon: FushiIcons.playlist,
            defaultValue: false,
            // 只在交叉淡入真正生效时有意义（关 / 独占 / 硬件直出时置灰，原因见副标题）。
            enabled: (SettingsContext c) =>
                musicCrossfadeAvailability(
                  c.appModel.musicSession.engine.currentSettings,
                  platform: musicOutputPlatformOfHost(),
                ) ==
                MusicCrossfadeAvailability.available,
            value: (SettingsContext c) => c.appModel.musicCrossfadeContinuous,
            onChanged: (SettingsContext c, bool value) =>
                c.appModel.setMusicCrossfadeContinuous(value),
          ),
          SettingsSwitchItem(
            id: 'music.replaygain',
            title: t.music_replaygain_title,
            subtitle: t.music_replaygain_hint,
            icon: FushiIcons.volumeUp,
            defaultValue: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.musicReplayGain,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setMusicReplayGain(value);
            },
          ),
          SettingsSliderItem(
            id: 'music.replaygain_preamp',
            title: t.music_replaygain_preamp_title,
            icon: FushiIcons.volumeUp,
            min: -15,
            max: 15,
            divisions: 30,
            defaultValue: 0,
            titleReadout: true,
            commitOnRelease: true,
            label: (double v) => '${v >= 0 ? '+' : ''}${v.round()} dB',
            value: (SettingsContext c) => c.appModel.musicReplayGainPreampDb,
            onChanged: (SettingsContext c, double v) =>
                c.appModel.setMusicReplayGainPreampDb(v.roundToDouble()),
          ),
          SettingsSwitchItem(
            id: 'music.loudness_scan',
            title: t.music_loudness_scan_title,
            subtitle: t.music_loudness_scan_hint,
            icon: FushiIcons.highQuality,
            defaultValue: true,
            value: (SettingsContext c) => c.appModel.musicLoudnessScan,
            onChanged: (SettingsContext c, bool value) =>
                c.appModel.setMusicLoudnessScan(value),
          ),
          SettingsActionItem(
            id: 'music.loudness_scan_now',
            title: t.music_loudness_scan_now,
            icon: FushiIcons.highQuality,
            cli: const SettingsCliAction.tap(),
            onTap: (SettingsContext c) =>
                unawaited(c.appModel.musicLoudness.schedule(force: true)),
          ),
        ],
      ),
      SettingsSection(
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'music.exclusive',
            title: t.music_exclusive_title,
            subtitle: t.music_exclusive_hint,
            icon: FushiIcons.verified,
            defaultValue: false,
            value: (SettingsContext c) => c.appModel.musicExclusiveOutput,
            onChanged: (SettingsContext c, bool value) =>
                c.appModel.setMusicExclusiveOutput(value),
          ),
          SettingsActionItem(
            id: 'music.audio_device',
            title: t.music_audio_device_title,
            icon: FushiIcons.volumeUp,
            subtitleBuilder: (SettingsContext c) =>
                c.appModel.musicAudioDevice == 'auto'
                ? t.music_audio_device_auto
                : c.appModel.musicAudioDevice,
            cli: SettingsCliAction(
              params: const <SettingsCliParam>[
                SettingsCliParam(
                  'device',
                  help:
                      'mpv audio-device name, e.g. wasapi/{guid}; auto = system default',
                ),
              ],
              run: (SettingsContext c, Map<String, String> args) async {
                await c.appModel.setMusicAudioDevice(args['device']!);
                return null;
              },
            ),
            onTap: _pickAudioDevice,
          ),
          // 图示均衡器（P5，可选）：子页里开关 + 10 段；开且不平直即非 bit-perfect（信号路径
          // 面板单独标「均衡器」），关 / 平直时不挂任何滤镜。
          SettingsNavigationItem(
            id: 'music.equalizer',
            title: t.music_eq_title,
            subtitleBuilder: (SettingsContext c) =>
                c.appModel.prefsRepo.musicEqEnabled
                ? t.music_eq_on
                : t.music_eq_off,
            icon: FushiIcons.barChart,
            showIcon: true,
            child: _equalizerDestination,
          ),
          SettingsSegmentedItem<int>(
            id: 'music.dsd_rate',
            title: t.music_dsd_rate_title,
            icon: FushiIcons.highQuality,
            defaultValue: MusicDsdPcmRate.khz176.hz,
            options: <SettingsSegmentOption<int>>[
              for (final MusicDsdPcmRate r in MusicDsdPcmRate.values)
                SettingsSegmentOption<int>(
                  value: r.hz,
                  label: '${(r.hz / 1000).toStringAsFixed(1)} kHz',
                ),
            ],
            selected: (SettingsContext c) => c.appModel.musicDsdPcmRate,
            onChanged: (SettingsContext c, int v) =>
                c.appModel.setMusicDsdPcmRate(v),
          ),
        ],
      ),
      // 识别（P4，设计 §8.1）：MusicBrainz 主源；AcoustID 需要用户自己的应用 key（本仓
      // 不内置任何 key），没填时声纹这一步跳过并在这里说明；VGMdb 默认关。
      SettingsSection(
        title: t.music_scrape_section,
        items: <SettingsItem>[
          SettingsTextItem(
            id: 'music.acoustid_api_key',
            title: t.music_setting_acoustid_key,
            // 随包内置了应用 key 时，这里只是「填自己的 key 覆盖」；没内置（fork / 无 secret
            // 的构建）才说明不填就没有声纹识别。
            subtitle: musicAcoustidBuiltinKeyAvailable
                ? t.music_setting_acoustid_key_builtin_hint
                : t.music_setting_acoustid_key_hint,
            icon: FushiIcons.key,
            secret: true,
            value: (SettingsContext c) => c.appModel.musicAcoustidApiKey,
            onChanged: (SettingsContext c, String v) =>
                c.appModel.setMusicAcoustidApiKey(v),
          ),
          SettingsSwitchItem(
            id: 'music.vgmdb',
            title: t.music_setting_vgmdb,
            subtitle: t.music_setting_vgmdb_hint,
            icon: FushiIcons.cloud,
            defaultValue: false,
            value: (SettingsContext c) => c.appModel.musicVgmdbEnabled,
            onChanged: (SettingsContext c, bool v) =>
                c.appModel.setMusicVgmdbEnabled(v),
          ),
          SettingsActionItem(
            id: 'music.identify_library',
            title: t.music_setting_identify_library,
            subtitle: t.music_setting_identify_library_hint,
            icon: FushiIcons.refresh,
            onTap: _identifyLibrary,
            cli: SettingsCliAction(
              offPageRunnable: true,
              run: (SettingsContext c, Map<String, String> args) async {
                final MusicLibraryScrapeReport r = await c.appModel.musicScrape
                    .scrapeLibrary();
                return <String, Object?>{
                  'total': r.total,
                  'matched': r.matched,
                  'unmatched': r.unmatched,
                  'failed': r.failed,
                  'byMethod': r.byMethod,
                };
              },
            ),
          ),
        ],
      ),
      // 服务器曲库（P5）：Jellyfin 家族复用视频的媒体服务器登录，OpenSubsonic 在子页里增删；
      // 混排进曲库是每台服务器的显式开关（子页）。
      SettingsSection(
        title: t.music_servers_title,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'music.servers',
            title: t.music_servers_manage,
            subtitle: t.music_servers_settings_hint,
            icon: FushiIcons.server,
            showIcon: true,
            child: () => SettingsDestination(
              id: SettingsDestinationId.music,
              title: t.music_servers_title,
              icon: FushiIcons.server,
              sections: const <SettingsSection>[],
              body: (SettingsContext c) =>
                  MusicServerSettingsBody(appModel: c.appModel),
            ),
          ),
          SettingsSegmentedItem<int>(
            id: 'music.server_bitrate',
            title: t.music_server_bitrate_title,
            subtitle: t.music_server_bitrate_hint,
            icon: FushiIcons.highQuality,
            defaultValue: 0,
            options: <SettingsSegmentOption<int>>[
              SettingsSegmentOption<int>(
                value: 0,
                label: t.music_server_bitrate_original,
              ),
              for (final int kbps in kMusicServerBitrateChoices)
                SettingsSegmentOption<int>(value: kbps, label: '$kbps kbps'),
            ],
            selected: (SettingsContext c) =>
                c.appModel.prefsRepo.musicServerMaxBitrate,
            onChanged: (SettingsContext c, int v) =>
                c.appModel.prefsRepo.setMusicServerMaxBitrate(v),
          ),
        ],
      ),
      // 插件音源（docs/specs/2026-10-28-music-plugins.md）：iOS 整节不渲染（合规门，
      // section 级 visible 同时管住分类正文 / 主从详情 / 设置搜索索引三条渲染路径）。
      SettingsSection(
        title: t.music_plugins_title,
        visible: (_) => isMusicPluginSourcesAvailable,
        items: <SettingsItem>[
          SettingsNavigationItem(
            id: 'music.plugins',
            title: t.music_plugins_title,
            subtitle: t.music_plugins_hint,
            icon: FushiIcons.browserExtension,
            showIcon: true,
            child: () => SettingsDestination(
              id: SettingsDestinationId.music,
              title: t.music_plugins_title,
              icon: FushiIcons.browserExtension,
              sections: const <SettingsSection>[],
              body: (SettingsContext c) =>
                  MusicPluginSettingsBody(appModel: c.appModel),
            ),
          ),
        ],
      ),
      // 歌词（P1，设计 §5.4 / §6.1）。
      SettingsSection(
        title: t.music_lyrics_title,
        items: <SettingsItem>[
          SettingsSwitchItem(
            id: 'music.lyrics_online',
            title: t.music_lyrics_online_title,
            subtitle: t.music_lyrics_online_hint,
            icon: FushiIcons.cloud,
            defaultValue: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.musicLyricsOnline,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setMusicLyricsOnline(value);
            },
          ),
          SettingsNavigationItem(
            id: 'music.lyrics_providers',
            title: t.music_lyrics_providers_title,
            subtitle: t.music_lyrics_providers_hint,
            icon: FushiIcons.lyrics,
            showIcon: true,
            // 与「插件音源」同一道合规门（iOS 不渲染）。
            visible: (_) => isMusicPluginSourcesAvailable,
            child: () => SettingsDestination(
              id: SettingsDestinationId.music,
              title: t.music_lyrics_providers_title,
              icon: FushiIcons.lyrics,
              sections: const <SettingsSection>[],
              body: (SettingsContext c) =>
                  MusicLyricsProvidersBody(appModel: c.appModel),
            ),
          ),
          SettingsSwitchItem(
            id: 'music.lyrics_lookup_pause',
            title: t.music_lyrics_lookup_pause_title,
            icon: FushiIcons.pause,
            defaultValue: true,
            value: (SettingsContext settingsContext) =>
                settingsContext.appModel.musicLyricsLookupPause,
            onChanged: (SettingsContext settingsContext, bool value) async {
              await settingsContext.appModel.setMusicLyricsLookupPause(value);
            },
          ),
          SettingsSwitchItem(
            id: 'music.desktop_lyrics',
            title: t.music_desktop_lyrics_title,
            subtitle: t.music_desktop_lyrics_hint,
            icon: FushiIcons.lyrics,
            defaultValue: false,
            // 原生悬浮字幕窗只有 Android / Windows / macOS（与有声书悬浮字幕同一个
            // 窗口）。
            visible: (SettingsContext c) => FloatingLyricChannel.supported,
            value: (SettingsContext c) => c.appModel.musicDesktopLyrics,
            onChanged: (SettingsContext c, bool value) =>
                c.appModel.setMusicDesktopLyrics(value),
          ),
          SettingsSwitchItem(
            id: 'music.lyrics_media_session',
            title: t.music_lyrics_media_session_title,
            subtitle: t.music_lyrics_media_session_hint,
            icon: FushiIcons.lyrics,
            defaultValue: true,
            value: (SettingsContext c) => c.appModel.musicLyricsMediaSession,
            onChanged: (SettingsContext c, bool value) =>
                c.appModel.setMusicLyricsMediaSession(value),
          ),
          // 卡拉 OK 字幕页里 ASS 的默认显示（P3，设计 §6.3）：自动 = 按 Rust 特效检测。
          SettingsSegmentedItem<MusicAssRenderPreference>(
            id: 'music.karaoke_ass_render',
            dropdown: true,
            title: t.music_karaoke_ass_render_title,
            subtitle: t.music_karaoke_ass_render_hint,
            icon: FushiIcons.lyrics,
            options: <SettingsSegmentOption<MusicAssRenderPreference>>[
              for (final MusicAssRenderPreference p
                  in MusicAssRenderPreference.values)
                SettingsSegmentOption<MusicAssRenderPreference>(
                  value: p,
                  label: switch (p) {
                    MusicAssRenderPreference.auto =>
                      t.music_karaoke_ass_render_auto,
                    MusicAssRenderPreference.original =>
                      t.music_karaoke_overlay_original,
                    MusicAssRenderPreference.structured =>
                      t.music_karaoke_overlay_structured,
                  },
                ),
            ],
            selected: (SettingsContext c) => c.appModel.musicKaraokeAssRender,
            onChanged: (SettingsContext c, MusicAssRenderPreference value) =>
                c.appModel.setMusicKaraokeAssRender(value),
            defaultValue: MusicAssRenderPreference.auto,
          ),
          SettingsSwitchItem(
            id: 'music.listening_counts_as_study',
            title: t.music_listening_study_title,
            subtitle: t.music_listening_study_hint,
            icon: FushiIcons.timer,
            defaultValue: false,
            value: (SettingsContext c) =>
                c.appModel.musicListeningCountsAsStudy,
            onChanged: (SettingsContext c, bool value) =>
                c.appModel.setMusicListeningCountsAsStudy(value),
          ),
        ],
      ),
      // 歌词页流体背景（MusicLyricsBackdrop；参照 QPlayer「背景」组）。
      SettingsSection(
        title: t.music_lyrics_backdrop_title,
        items: <SettingsItem>[
          SettingsSegmentedItem<bool>(
            id: 'music.lyrics_backdrop_animate',
            title: t.music_lyrics_backdrop_motion_title,
            icon: FushiIcons.lyrics,
            options: <SettingsSegmentOption<bool>>[
              SettingsSegmentOption<bool>(
                value: true,
                label: t.music_lyrics_backdrop_motion_dynamic,
              ),
              SettingsSegmentOption<bool>(
                value: false,
                label: t.music_lyrics_backdrop_motion_static,
              ),
            ],
            selected: (SettingsContext c) =>
                c.appModel.prefsRepo.musicLyricsBackdropAnimate,
            onChanged: (SettingsContext c, bool value) =>
                c.appModel.prefsRepo.setMusicLyricsBackdropAnimate(value),
            defaultValue: true,
          ),
          SettingsSegmentedItem<MusicLyricsBackdropStyle>(
            id: 'music.lyrics_backdrop_style',
            dropdown: true,
            title: t.music_lyrics_backdrop_style_title,
            subtitle: t.music_lyrics_backdrop_style_hint,
            icon: FushiIcons.lyrics,
            options: <SettingsSegmentOption<MusicLyricsBackdropStyle>>[
              for (final MusicLyricsBackdropStyle style
                  in MusicLyricsBackdropStyle.values)
                SettingsSegmentOption<MusicLyricsBackdropStyle>(
                  value: style,
                  label: musicLyricsBackdropStyleLabel(style),
                ),
            ],
            selected: (SettingsContext c) => MusicLyricsBackdropStyle.fromPref(
              c.appModel.prefsRepo.musicLyricsBackdropStyle,
            ),
            onChanged: (SettingsContext c, MusicLyricsBackdropStyle value) => c
                .appModel
                .prefsRepo
                .setMusicLyricsBackdropStyle(value.prefValue),
            defaultValue: MusicLyricsBackdropStyle.meshGradient,
          ),
          SettingsSliderItem(
            id: 'music.lyrics_backdrop_saturation',
            title: t.music_lyrics_backdrop_saturation_title,
            subtitle: t.music_lyrics_backdrop_saturation_hint,
            icon: FushiIcons.lyrics,
            min: kMusicLyricsBackdropSaturationMin * 100,
            max: kMusicLyricsBackdropSaturationMax * 100,
            divisions: 15,
            defaultValue: kMusicLyricsBackdropSaturationDefault * 100,
            titleReadout: true,
            commitOnRelease: true,
            label: (double v) => '${v.round()}%',
            value: (SettingsContext c) =>
                c.appModel.prefsRepo.musicLyricsBackdropSaturation * 100,
            onChanged: (SettingsContext c, double v) => c.appModel.prefsRepo
                .setMusicLyricsBackdropSaturation((v / 10).round() / 10),
          ),
        ],
      ),
    ],
  );
}

/// 流体样式的显示名（设置页下拉）。
String musicLyricsBackdropStyleLabel(MusicLyricsBackdropStyle style) =>
    switch (style) {
      MusicLyricsBackdropStyle.pixi => t.music_lyrics_backdrop_style_pixi,
      MusicLyricsBackdropStyle.meshGradient =>
        t.music_lyrics_backdrop_style_mesh,
      MusicLyricsBackdropStyle.classic => t.music_lyrics_backdrop_style_classic,
    };

/// 均衡器子页：开关 + 每段一个 ±12 dB 滑块 + 复位。改动立即经引擎重新下发（`af`）。
SettingsDestination _equalizerDestination() => SettingsDestination(
  id: SettingsDestinationId.music,
  title: t.music_eq_title,
  icon: FushiIcons.barChart,
  sections: <SettingsSection>[
    SettingsSection(
      items: <SettingsItem>[
        SettingsSwitchItem(
          id: 'music.eq_enabled',
          title: t.music_eq_enabled_title,
          subtitle: t.music_eq_enabled_hint,
          icon: FushiIcons.barChart,
          defaultValue: false,
          value: (SettingsContext c) => c.appModel.prefsRepo.musicEqEnabled,
          onChanged: (SettingsContext c, bool v) async {
            await c.appModel.prefsRepo.setMusicEqEnabled(v);
            await c.appModel.musicSession.engine.reapplySettings();
          },
        ),
      ],
    ),
    SettingsSection(
      title: t.music_eq_bands,
      items: <SettingsItem>[
        for (int i = 0; i < kMusicEqualizerBandsHz.length; i++)
          SettingsSliderItem(
            id: 'music.eq_band_${kMusicEqualizerBandsHz[i]}',
            title: musicEqualizerBandLabel(kMusicEqualizerBandsHz[i]),
            icon: FushiIcons.barChart,
            min: -kMusicEqualizerMaxGainDb,
            max: kMusicEqualizerMaxGainDb,
            divisions: (kMusicEqualizerMaxGainDb * 4).round(),
            defaultValue: 0,
            titleReadout: true,
            commitOnRelease: true,
            label: (double v) =>
                '${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)} dB',
            value: (SettingsContext c) => MusicEqualizerSettings.parseGains(
              c.appModel.prefsRepo.musicEqGains,
            )[i],
            onChanged: (SettingsContext c, double v) async {
              final List<double> gains = MusicEqualizerSettings.parseGains(
                c.appModel.prefsRepo.musicEqGains,
              );
              gains[i] = (v * 2).roundToDouble() / 2;
              await c.appModel.prefsRepo.setMusicEqGains(
                MusicEqualizerSettings.encodeGains(gains),
              );
              await c.appModel.musicSession.engine.reapplySettings();
            },
          ),
        SettingsActionItem(
          id: 'music.eq_reset',
          title: t.music_eq_reset,
          icon: FushiIcons.restart,
          cli: const SettingsCliAction.tap(),
          onTap: (SettingsContext c) async {
            await c.appModel.prefsRepo.setMusicEqGains('');
            await c.appModel.musicSession.engine.reapplySettings();
            c.refresh();
          },
        ),
      ],
    ),
  ],
);

/// 频段名（`31 Hz` / `1 kHz`）：单位是国际通用写法，不翻译。
String musicEqualizerBandLabel(int hz) =>
    hz >= 1000 ? '${hz ~/ 1000} kHz' : '$hz Hz';

/// 识别整个曲库：串行跑（MusicBrainz 1 req/s），进度与结果走 toast。
Future<void> _identifyLibrary(SettingsContext c) async {
  FushiToast.show(msg: t.music_scrape_identifying);
  final MusicLibraryScrapeReport r = await c.appModel.musicScrape
      .scrapeLibrary();
  FushiToast.show(
    msg: t.music_scrape_library_done(matched: r.matched, total: r.total),
    severity: r.failed > 0 ? ToastSeverity.warning : ToastSeverity.success,
  );
}

/// 输出设备选择：设备清单来自 mpv `audio-device-list`（含 `auto`）。
Future<void> _pickAudioDevice(SettingsContext c) async {
  final List<MusicAudioDevice> devices = await c.appModel.musicSession.engine
      .listAudioDevices();
  if (!c.context.mounted) return;
  final String? picked = await showFushiChoiceDialog<String>(
    context: c.context,
    title: t.music_audio_device_title,
    selected: c.appModel.musicAudioDevice,
    options: <FushiChoiceOption<String>>[
      for (final MusicAudioDevice d in devices)
        FushiChoiceOption<String>(
          value: d.name,
          label: d.isAuto ? t.music_audio_device_auto : d.description,
          subtitle: d.isAuto ? null : d.name,
        ),
    ],
  );
  if (picked == null) return;
  await c.appModel.setMusicAudioDevice(picked);
  c.refresh();
}
