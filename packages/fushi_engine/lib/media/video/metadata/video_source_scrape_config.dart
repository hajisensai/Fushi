/// 视频来源规范刮削的全局配置与稳定偏好键。
///
/// 来源自己的开关落 v77 的 `video_source_scrape_settings`；其中
/// `provider_override` 是该来源的主资料源覆盖（`mal` / `tmdb`，NULL = 跟随
/// 全局 [kVideoMetadataPrimaryProviderPref]）。网络凭据与 AniDB client
/// identity 仍放 Preferences，避免混进
/// `media_sources.config_json`（该列只属于网络来源连接参数）。
library;

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/anidb_app_client.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/scraper/scrape_identifier_words.dart';

const String kVideoMetadataAniDbClientNamePref =
    'video_metadata_anidb_client_name';
const String kVideoMetadataAniDbClientVersionPref =
    'video_metadata_anidb_client_version';
const String kVideoMetadataLocalePref = 'video_metadata_locale';

/// 用户自定义识别词表（多行文本，语法见 [ScrapeIdentifierWords]）。默认空。
const String kVideoMetadataIdentifierWordsPref =
    'video_metadata_identifier_words';
const String kVideoAniDbHashEnabledPref = 'video_anidb_hash_enabled';
const String kVideoAniDbUsernamePref = 'video_anidb_username';
const String kVideoAniDbPasswordPref = 'video_anidb_password';

/// 全局主资料源偏好（`mal` / `tmdb`）。另一个源恒为兜底源；默认 MAL 沿用
/// 2026-09-07 的决定，用户可切 TMDB。
const String kVideoMetadataPrimaryProviderPref =
    'video_metadata_primary_provider';

/// 用户可选的主资料源全集。注册进生产 registry 的就是这两家；其余枚举值
/// （AniDB / Bangumi / Douban / AniList / Fanart）只是历史身份兼容，不可选。
const List<VideoMetadataProviderKind> kSelectableVideoMetadataProviders =
    <VideoMetadataProviderKind>[
  VideoMetadataProviderKind.mal,
  VideoMetadataProviderKind.tmdb,
];

/// 把偏好值 / `provider_override` 列值解析成可选主源；非法或历史值（如旧
/// `bangumi` override）返回 `null`，由调用方回落到全局默认。
VideoMetadataProviderKind? parseSelectableVideoMetadataProvider(
  String? value,
) {
  final VideoMetadataProviderKind? kind =
      VideoMetadataProviderKind.values.asNameMap()[value?.trim()];
  return kind != null && kSelectableVideoMetadataProviders.contains(kind)
      ? kind
      : null;
}

/// 双源策略里某个主源的兜底源：MAL ↔ TMDB 互为兜底；其它主源（AniDB 等
/// 单源语义）没有兜底。
VideoMetadataProviderKind? videoMetadataFallbackProvider(
  VideoMetadataProviderKind primary,
) =>
    switch (primary) {
      VideoMetadataProviderKind.mal => VideoMetadataProviderKind.tmdb,
      VideoMetadataProviderKind.tmdb => VideoMetadataProviderKind.mal,
      _ => null,
    };

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
    this.primaryProvider = VideoMetadataProviderKind.mal,
    this.identifierWords = ScrapeIdentifierWords.empty,
  });

  /// 全局主资料源（来源级 `provider_override` 可覆盖）；另一个可选源恒为兜底。
  final VideoMetadataProviderKind primaryProvider;

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

  /// 标题候选的用户预处理词表（屏蔽 / 替换 / 集偏移）。解析失败的行已在
  /// 构造时丢弃，只有可用的规则会进到这里。
  final ScrapeIdentifierWords identifierWords;

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
      primaryProvider: parseSelectableVideoMetadataProvider(
            read(kVideoMetadataPrimaryProviderPref),
          ) ??
          VideoMetadataProviderKind.mal,
      // 解析失败不抛：非法行在这里被丢弃，错误说明由设置页自己再解析一次展示。
      identifierWords: ScrapeIdentifierWords.parse(
        preferences.getPref(kVideoMetadataIdentifierWordsPref, defaultValue: '')
            as String,
      ).identifierWords,
    );
  }
}
