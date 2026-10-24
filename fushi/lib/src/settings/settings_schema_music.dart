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
        ],
      ),
    ],
  );
}
