import 'package:fushi/src/ops/ctl_settings_body_items.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';
import 'package:fushi/utils.dart';

/// Jellyfin / Emby 配置页里的两个全局偏好开关在控制通道上的条目
/// （服务器列表本身走 `services.media_server.jellyfin` 的 `cliList`）。
///
/// 读写调页面里同一组 `prefsRepo` 方法：混排显示 / 进视频页自动列出。
List<CtlBodyPage> buildCtlMediaServerBodyPages() => <CtlBodyPage>[
  CtlBodyPage(
    breadcrumb: 'Jellyfin · Emby',
    items: <SettingsItem>[
      SettingsSwitchItem(
        id: 'services.media_server.jellyfin.show_in_library',
        title: t.jellyfin_show_in_library_title,
        subtitle: t.jellyfin_show_in_library_hint,
        value: (SettingsContext c) =>
            c.appModel.prefsRepo.jellyfinShowInLibrary,
        onChanged: (SettingsContext c, bool value) =>
            c.appModel.prefsRepo.setJellyfinShowInLibrary(value),
        defaultValue: false,
      ),
      SettingsSwitchItem(
        id: 'services.media_server.jellyfin.auto_list_videos',
        title: t.jellyfin_auto_list_title,
        subtitle: t.jellyfin_auto_list_hint,
        value: (SettingsContext c) =>
            c.appModel.prefsRepo.jellyfinAutoListVideos,
        onChanged: (SettingsContext c, bool value) =>
            c.appModel.prefsRepo.setJellyfinAutoListVideos(value),
        defaultValue: true,
      ),
    ],
  ),
];
