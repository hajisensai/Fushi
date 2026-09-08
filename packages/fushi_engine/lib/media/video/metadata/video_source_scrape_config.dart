/// 视频来源规范刮削的全局配置与稳定偏好键。
///
/// 来源自己的开关落 v77 的 `video_source_scrape_settings`；其中历史
/// provider override 只读兼容。网络凭据与 AniDB client identity 仍放
/// Preferences，避免混进
/// `media_sources.config_json`（该列只属于网络来源连接参数）。
library;

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/anidb_app_client.dart';

const String kVideoMetadataAniDbClientNamePref =
    'video_metadata_anidb_client_name';
const String kVideoMetadataAniDbClientVersionPref =
    'video_metadata_anidb_client_version';
const String kVideoMetadataLocalePref = 'video_metadata_locale';
const String kVideoAniDbHashEnabledPref = 'video_anidb_hash_enabled';
const String kVideoAniDbUsernamePref = 'video_anidb_username';
const String kVideoAniDbPasswordPref = 'video_anidb_password';

/// AniDB HTTP API 要求注册过的正整数 client version。
///
/// 无效值保留为 `null`，需要已注册客户端的 AniDB 文件识别不会发请求。
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
    this.hashEnabled = false,
    this.anidbUsername = '',
    this.anidbPassword = '',
    this.locale = 'zh-CN',
    this.imageLanguages = const <String>['zh', 'en', ''],
  });

  final String tmdbApiKey;
  final String anidbClientName;
  final int? anidbClientVersion;
  final bool hashEnabled;
  final String anidbUsername;
  final String anidbPassword;
  AnidbUdpConfig get anidbUdpConfig => AnidbUdpConfig(
        username: anidbUsername,
        password: anidbPassword,
        clientName: anidbClientName,
        clientVersion: anidbClientVersion ?? 0,
      );
  final String locale;
  final List<String> imageLanguages;

  factory VideoSourceScrapeGlobalConfig.fromPreferences(
    PrefStore preferences, {
    required String resolvedTmdbApiKey,
    AniDbAppClientIdentity bundledAniDbClient = kBundledAniDbClient,
  }) {
    String read(String key, [String fallback = '']) =>
        (preferences.getPref(key, defaultValue: fallback) as String).trim();
    final String locale = read(kVideoMetadataLocalePref, 'zh-CN');
    final AniDbAppClientIdentity client = resolveAniDbAppClient(
      customName: read(kVideoMetadataAniDbClientNamePref),
      customVersion: parseAniDbClientVersion(
        read(kVideoMetadataAniDbClientVersionPref),
      ),
      bundled: bundledAniDbClient,
    );
    return VideoSourceScrapeGlobalConfig(
      tmdbApiKey: resolvedTmdbApiKey.trim(),
      anidbClientName: client.name,
      anidbClientVersion: client.version,
      hashEnabled: preferences.getPref(kVideoAniDbHashEnabledPref,
          defaultValue: false) as bool,
      anidbUsername: read(kVideoAniDbUsernamePref),
      // Password whitespace is significant; do not apply the display-string trimmer.
      anidbPassword: preferences.getPref(kVideoAniDbPasswordPref,
          defaultValue: '') as String,
      locale: locale.isEmpty ? 'zh-CN' : locale,
    );
  }
}
