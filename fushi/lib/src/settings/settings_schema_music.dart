import 'dart:async';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/models/module_registry.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/utils.dart';

/// 「音乐」一级设置分类（音乐模块，docs/specs/2026-10-23-music-module-design.md §11.1）：
/// 曲库入口 + 播放（无缝 / ReplayGain）。与 music 顶层 tab 同一个模块门。
///
/// 音乐来源（文件夹）的增删在曲库页顶栏，这里只放一条直达曲库的导航，不另做一份
/// 来源管理（两处各管一份会漂移）。
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
            subtitle: t.music_settings_summary,
            icon: FushiIcons.music,
            showIcon: true,
            onTap: (SettingsContext settingsContext) {
              homeShellTabNotifier.value = HomeTab.music;
            },
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
    ],
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
