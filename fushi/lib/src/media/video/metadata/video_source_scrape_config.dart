/// 视频来源规范刮削的全局配置与稳定偏好键。
///
/// 来源自己的开关落 v77 的 `video_source_scrape_settings`；其中历史
/// provider override 只读兼容。网络凭据与 AniDB client identity 仍放
/// Preferences，避免混进
/// `media_sources.config_json`（该列只属于网络来源连接参数）。
library;

import 'package:fushi/src/models/preferences_repository.dart';

const String kVideoMetadataAniDbClientNamePref =
    'video_metadata_anidb_client_name';
const String kVideoMetadataAniDbClientVersionPref =
    'video_metadata_anidb_client_version';
const String kVideoMetadataLocalePref = 'video_metadata_locale';

/// AniDB HTTP API 要求注册过的正整数 client version。
///
/// 无效值保留为 `null`，provider 因而只使用离线 title catalog，不会发 HTTP 请求。
int? parseAniDbClientVersion(String? value) {
  final int? parsed = int.tryParse(value?.trim() ?? '');
  return parsed != null && parsed > 0 ? parsed : null;
}

/// 一次批次开始时冻结的配置快照。执行中设置变化只影响下一批，避免同一来源半途
/// 切 provider 或密钥而产生不可复现的混合资料。
class VideoSourceScrapeGlobalConfig {
  const VideoSourceScrapeGlobalConfig({
    this.tmdbApiKey = '',
    this.anidbClientName = '',
    this.anidbClientVersion,
    this.locale = 'zh-CN',
    this.imageLanguages = const <String>['zh', 'en', ''],
  });

  final String tmdbApiKey;
  final String anidbClientName;
  final int? anidbClientVersion;
  final String locale;
  final List<String> imageLanguages;

  factory VideoSourceScrapeGlobalConfig.fromPreferences(
    PreferencesRepository preferences, {
    required String resolvedTmdbApiKey,
  }) {
    String read(String key, [String fallback = '']) =>
        (preferences.getPref(key, defaultValue: fallback) as String).trim();
    final String locale = read(kVideoMetadataLocalePref, 'zh-CN');
    final String anidbClientName = read(kVideoMetadataAniDbClientNamePref);
    return VideoSourceScrapeGlobalConfig(
      tmdbApiKey: resolvedTmdbApiKey.trim(),
      anidbClientName: anidbClientName,
      anidbClientVersion: parseAniDbClientVersion(
        read(kVideoMetadataAniDbClientVersionPref),
      ),
      locale: locale.isEmpty ? 'zh-CN' : locale,
    );
  }
}
