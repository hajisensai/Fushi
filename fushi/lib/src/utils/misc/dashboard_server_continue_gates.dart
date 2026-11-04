import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';

/// 用户自配服务器条目混进首页「继续」的门控（显式 opt-in），首页与桌面「接下来」
/// 小组件共用同一份判定：
/// - Jellyfin / Emby / Plex 走既有的「在视频库中混排显示」
///   （`jellyfin_show_in_library`，默认关，文案即「混排进首页、系列与全部视频」）；
/// - Audiobookshelf 走「在首页『继续』中显示」（`audiobookshelf_show_in_home`，
///   默认关）。
/// 各自还要所属模块开着（视频模块关着不问媒体服务器，书模块关着不问 ABS）。
({bool mediaServers, bool audiobookshelf, String signature})
serverContinueGates(AppModel appModel) {
  final bool ready = appModel.isPreferencesReady;
  final ModuleVisibility visibility = appModel.moduleVisibility;
  final bool media =
      ready &&
      appModel.prefsRepo.jellyfinShowInLibrary &&
      visibility.isEnabled(ModuleId.video);
  final bool abs =
      ready &&
      appModel.prefsRepo.audiobookshelfShowInHome &&
      visibility.isEnabled(ModuleId.books);
  return (mediaServers: media, audiobookshelf: abs, signature: '$media|$abs');
}
