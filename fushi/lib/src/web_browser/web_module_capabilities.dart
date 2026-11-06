/// 「浏览器」模块在本平台上真正有哪些能力，以及按它分派的说明文案。
///
/// 模块本身五端都有，但里面的几块能力各有各的平台判据：视频站点只在 Windows
/// （[webVideoSitesAvailable]），网页漫画 / 小说导入是在线源能力、iOS 上整体缺席
/// （[StoreRestrictedCapability]），浏览器扩展只在桌面（[browserExtensionSupportedOn]）。
/// 说明文案若写死成一份，就会在 iOS 上宣传受限能力、在 Android / macOS / Linux 上
/// 宣传不存在的视频站点。判据各自只写一处，这里只做组合。
library;

import 'package:flutter/foundation.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/video/web_video_sites.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/store_compliance.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';

/// 本平台「浏览器」模块里实际存在的几块能力。
@immutable
class WebModuleCapabilities {
  const WebModuleCapabilities({
    required this.videoSites,
    required this.webReaders,
    required this.browserExtension,
  });

  /// 真实平台上的组合。
  factory WebModuleCapabilities.current() => WebModuleCapabilities(
    videoSites: webVideoSitesAvailable(),
    webReaders: StoreRestrictedCapability.onlineMangaSource.isAvailable,
    browserExtension: browserExtensionSupportedOn(
      isDesktop: DesktopLookupService.isDesktop,
    ),
  );

  /// 视频站点在 Fushi 播放器里看（Netflix / YouTube）。
  final bool videoSites;

  /// 网页漫画 / 网页小说用 Fushi 阅读器读（在线源合规门）。
  final bool webReaders;

  /// 可以安装浏览器扩展。
  final bool browserExtension;
}

/// 新手引导里「浏览器」功能项的一句话说明。
String webModuleOnboardingHint(WebModuleCapabilities c) {
  if (!c.webReaders) return t.onboarding_feature_web_basic_hint;
  if (c.videoSites && c.browserExtension) return t.onboarding_feature_web_hint;
  if (c.browserExtension) return t.onboarding_feature_web_reader_desktop_hint;
  return t.onboarding_feature_web_reader_hint;
}

/// 「网页广告拦截」总开关的说明：只列本平台真有的网页浏览场景。
String webAdblockEnabledHint(WebModuleCapabilities c) {
  if (!c.webReaders) return t.web_adblock_enabled_basic_hint;
  if (c.videoSites) return t.web_adblock_enabled_hint;
  return t.web_adblock_enabled_sources_hint;
}
