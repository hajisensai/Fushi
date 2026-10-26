import 'package:fushi/src/ops/ctl_settings_body_anki.dart';
import 'package:fushi/src/ops/ctl_settings_body_anki_sync.dart';
import 'package:fushi/src/ops/ctl_settings_body_audio_sources.dart';
import 'package:fushi/src/ops/ctl_settings_body_browser_extension.dart';
import 'package:fushi/src/ops/ctl_settings_body_content_language.dart';
import 'package:fushi/src/ops/ctl_settings_body_custom_themes.dart';
import 'package:fushi/src/ops/ctl_settings_body_dict_style.dart';
import 'package:fushi/src/ops/ctl_settings_body_discovery.dart';
import 'package:fushi/src/ops/ctl_settings_body_downloads.dart';
import 'package:fushi/src/ops/ctl_settings_body_fonts.dart';
import 'package:fushi/src/ops/ctl_settings_body_media_server.dart';
import 'package:fushi/src/ops/ctl_settings_body_misc.dart';
import 'package:fushi/src/ops/ctl_settings_body_storage.dart';
import 'package:fushi/src/ops/ctl_settings_body_plex.dart';
import 'package:fushi/src/ops/ctl_settings_body_sync.dart';
import 'package:fushi/src/ops/ctl_settings_body_tracking.dart';
import 'package:fushi/src/ops/ctl_settings_body_update.dart';
import 'package:fushi/src/ops/ctl_settings_body_video_providers.dart';
import 'package:fushi/src/ops/ctl_settings_body_video_shaders.dart';
import 'package:fushi/src/settings/settings_context.dart';
import 'package:fushi/src/settings/settings_destination.dart';

/// 走 `SettingsDestination.body` 逃生口 / 独立页面实现的设置页（Anki 设置页、
/// Jellyfin / Plex 配置页…）在控制通道上的条目。
///
/// 这些页面的设置项不在 schema 的 item 树里（正文是自绘 widget），`config` 的
/// 索引看不到它们。这里用**同一套 schema item 类型**把它们声明出来——值的读写
/// 调页面里同一个 AppModel / 仓库方法，动作走 [SettingsCliAction] 的无交互入口
/// ——于是 `fushi_cli config ls/get/set/reset/run/items` 不需要任何特例就能覆盖。
///
/// 条目只给控制通道用，不进设置页渲染与搜索。
class CtlBodyPage {
  const CtlBodyPage({
    required this.breadcrumb,
    required this.items,
    this.visible,
  });

  /// 索引里的分区路径（`config ls` 的 section 列），如「制卡 › Anki」。
  final String breadcrumb;
  final List<SettingsItem> items;

  /// 整页在当前平台 / 模块下是否可用；null = 恒可用。
  final bool Function(SettingsContext context)? visible;
}

/// 全部逃生口页面的控制通道条目。每个页面一个 `ctl_settings_body_<页>.dart`，
/// 在这里汇总一行。
List<CtlBodyPage> buildCtlBodyPages() => <CtlBodyPage>[
  ...buildCtlAnkiBodyPages(),
  ...buildCtlMediaServerBodyPages(),
  ...buildCtlUpdateBodyPages(),
  ...buildCtlAudioSourcesBodyPages(),
  ...buildCtlSyncBodyPages(),
  ...buildCtlVideoShaderBodyPages(),
  ...buildCtlPlexBodyPages(),
  ...buildCtlAnkiSyncBodyPages(),
  ...buildCtlDiscoveryBodyPages(),
  ...buildCtlDownloadsBodyPages(),
  ...buildCtlVideoProvidersBodyPages(),
  ...buildCtlTrackingBodyPages(),
  ...buildCtlStorageBodyPages(),
  ...buildCtlFontsBodyPages(),
  ...buildCtlCustomThemesBodyPages(),
  ...buildCtlContentLanguageBodyPages(),
  ...buildCtlMiscBodyPages(),
  ...buildCtlBrowserExtensionBodyPages(),
  ...buildCtlDictStyleBodyPages(),
];
