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
import 'package:fushi_engine/media/video/metadata/video_metadata_languages.dart';
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

/// 每部作品每类图保留张数上限（Shoko `TMDB.MaxAutoPosters` / `MaxAutoBackdrops`
/// / `MaxAutoLogos`，默认都是 10；0 = 不限）。分集剧照恒 1（`MaxAutoThumbnails`）。
const String kVideoMetadataMaxCoversPref = 'video_metadata_max_covers';
const String kVideoMetadataMaxBackdropsPref = 'video_metadata_max_backdrops';
const String kVideoMetadataMaxLogosPref = 'video_metadata_max_logos';
const int kVideoMetadataDefaultMaxImages = 10;

/// 刮削时把演职员头像下到本地（Shoko `TMDB.AutoDownloadStaffImages`）。默认关：
/// Shoko 默认 `AutoDownloadCrewAndCast = false` 根本不拉人物，本仓照片走按需
/// 缓存已等价；开了才落地，每部作品最多 [kVideoMetadataMaxStaffImages] 张
/// （Shoko `MaxAutoStaffImages`）。
const String kVideoMetadataStaffImagesPref =
    'video_metadata_download_staff_images';
const int kVideoMetadataMaxStaffImages = 10;
const String kVideoAniDbUsernamePref = 'video_anidb_username';
const String kVideoAniDbPasswordPref = 'video_anidb_password';

/// 全局主资料源偏好（`anidb` / `mal` / `tmdb`）。2026-09-20 用户拍板对齐 Shoko：
/// 默认 **AniDB 为主源**（哈希给出的 aid 直接就是作品身份，anime XML 出核心资料
/// 与全集播出日），TMDB 补充 / 兜底；MAL 保留为可选主源（MAL ↔ TMDB 互为兜底），
/// AniDB 主源下 MAL 只是交叉引用（Shoko `CrossRef_AniDB_MAL`）。
const String kVideoMetadataPrimaryProviderPref =
    'video_metadata_primary_provider';

/// 用户可选的主资料源全集。注册进生产 registry 的就是这三家；其余枚举值
/// （Bangumi / Douban / AniList / Fanart）只是历史身份兼容，不可选。
const List<VideoMetadataProviderKind> kSelectableVideoMetadataProviders =
    <VideoMetadataProviderKind>[
  VideoMetadataProviderKind.anidb,
  VideoMetadataProviderKind.mal,
  VideoMetadataProviderKind.tmdb,
];

/// 默认主源（Shoko 形态）。
const VideoMetadataProviderKind kDefaultVideoMetadataPrimaryProvider =
    VideoMetadataProviderKind.anidb;

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

/// 双源策略里某个主源的兜底源：AniDB → TMDB（Shoko：TMDB 恒为 AniDB 的补充）；
/// MAL ↔ TMDB 互为兜底；其它历史主源没有兜底。
VideoMetadataProviderKind? videoMetadataFallbackProvider(
  VideoMetadataProviderKind primary,
) =>
    switch (primary) {
      VideoMetadataProviderKind.anidb => VideoMetadataProviderKind.tmdb,
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
    this.locale = kFallbackVideoMetadataLocale,
    this.primaryProvider = kDefaultVideoMetadataPrimaryProvider,
    this.identifierWords = ScrapeIdentifierWords.empty,
    this.maxCovers = kVideoMetadataDefaultMaxImages,
    this.maxBackdrops = kVideoMetadataDefaultMaxImages,
    this.maxLogos = kVideoMetadataDefaultMaxImages,
    this.downloadStaffImages = false,
  });

  /// 每类图保留张数（0 = 不限），见 [kVideoMetadataMaxCoversPref] 等。
  final int maxCovers, maxBackdrops, maxLogos;

  /// 见 [kVideoMetadataStaffImagesPref]。
  final bool downloadStaffImages;

  /// 图种 → 上限，喂 `selectVideoMetadataImages(maxPerKind:)`。
  Map<VideoMetadataImageKind, int> get maxImagesPerKind =>
      <VideoMetadataImageKind, int>{
        VideoMetadataImageKind.cover: maxCovers,
        VideoMetadataImageKind.backdrop: maxBackdrops,
        VideoMetadataImageKind.logo: maxLogos,
      };

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

  /// 哈希识别在本快照下会不会真的跑：开关打开且 UDP 凭据 / 客户端身份完整，
  /// 与协调器里 `AnidbHashIdentityService` 的 `enabled` + `isConfigured` 同一判据。
  ///
  /// 设置页状态、首页「配置在线服务」提醒都读这个，别再各自按偏好键名判空：
  /// 客户端名留空时 [resolveAniDbAppClient] 走内置 `fushiplayer`，按键名判空会把
  /// 「测试登录」已成功的账号标成「未配置」（BUG-2586）。
  bool get anidbHashReady => hashEnabled && anidbUdpConfig.isAvailable;

  /// 装配点判「配置变没变、要不要重建协调器 / 发现服务」的唯一指纹。
  ///
  /// 所有会被烘进 [VideoSourceScrapeCoordinator] / `VideoDiscoveryService`
  /// 构造快照的字段都必须在这里：BUG-2581 手动刮削装配点自己手写指纹时漏掉了
  /// `hashEnabled` / 用户名 / 密码，用户填好 AniDB 账号后仍复用旧协调器，
  /// 旧协调器里的 `AnidbHashIdentityService` 还是构建时那份「未配置」快照。
  String get runtimeFingerprint => <Object>[
        tmdbApiKey,
        anidbClientName,
        anidbClientVersion ?? 0,
        hashEnabled,
        anidbUsername,
        anidbPassword,
        locale,
        primaryProvider.name,
        identifierWords.source,
        maxCovers,
        maxBackdrops,
        maxLogos,
        downloadStaffImages,
      ].join('\u0000');

  /// 本批次的**全局**资料语言（BCP-47）。来源级 `metadata_locale` 可覆盖，所以
  /// 消费端一律从**有效** locale 派生语言参数（`VideoSourceScrapeCoordinator._locale`
  /// / provider 的 `language`），不要在这里加一个从全局 locale 派生的 getter——
  /// 那会成为第二个入口，悄悄无视来源级覆盖，正是 BUG-2454 修掉的那类接错线。
  ///
  /// 曾经旁边还有一个 `List<String> imageLanguages` 字段，声明了却**从没被任何
  /// 地方读过**——真正生效的是 provider 里 4 处 `'zh,en,null'` 字面量和
  /// `selectVideoMetadataImages` 的默认参数。字段与生效常量接错了，改字段等于
  /// 什么都没改。
  final String locale;

  /// 标题候选的用户预处理词表（屏蔽 / 替换 / 集偏移）。解析失败的行已在
  /// 构造时丢弃，只有可用的规则会进到这里。
  final ScrapeIdentifierWords identifierWords;

  /// [uiLocaleTag] 是**界面语言**（app 侧 `AppModel.appLocale.toLanguageTag()`）；
  /// 用户没显式设过资料语言时就用它。此前这里回落到写死的 `zh-CN`，等于让每个
  /// 德语、韩语、阿拉伯语用户默认拉中文简介和中文海报——app 出 17 种语言，没有
  /// 哪种语言配当隐含默认值。
  ///
  /// **必填**而不是给默认值：有默认值的可选参数 + 某个调用点忘传 = 那条路径静默
  /// 退回兜底、单测全绿（本 bug 的根因形状）。拿不到界面语言的调用方要**显式**
  /// 说出用什么：无头服务端传它自己的配置项，只查凭据是否配齐的场景传
  /// [kFallbackVideoMetadataLocale]。空白串同样退到该兜底。
  factory VideoSourceScrapeGlobalConfig.fromPreferences(
    PrefStore preferences, {
    required String resolvedTmdbApiKey,
    required String uiLocaleTag,
    AniDbAppClientIdentity bundledAniDbClient = kBundledAniDbClient,
  }) {
    String read(String key, [String fallback = '']) =>
        (preferences.getPref(key, defaultValue: fallback) as String).trim();
    int readLimit(String key) {
      final Object? raw =
          preferences.getPref(key, defaultValue: kVideoMetadataDefaultMaxImages);
      final int value = raw is int
          ? raw
          : int.tryParse('$raw') ?? kVideoMetadataDefaultMaxImages;
      return value < 0 ? kVideoMetadataDefaultMaxImages : value;
    }
    final String uiLocale = uiLocaleTag.trim().isEmpty
        ? kFallbackVideoMetadataLocale
        : uiLocaleTag.trim();
    final String locale = read(kVideoMetadataLocalePref, uiLocale);
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
      locale: locale.isEmpty ? uiLocale : locale,
      primaryProvider: parseSelectableVideoMetadataProvider(
            read(kVideoMetadataPrimaryProviderPref),
          ) ??
          kDefaultVideoMetadataPrimaryProvider,
      // 解析失败不抛：非法行在这里被丢弃，错误说明由设置页自己再解析一次展示。
      identifierWords: ScrapeIdentifierWords.parse(
        preferences.getPref(kVideoMetadataIdentifierWordsPref, defaultValue: '')
            as String,
      ).identifierWords,
      maxCovers: readLimit(kVideoMetadataMaxCoversPref),
      maxBackdrops: readLimit(kVideoMetadataMaxBackdropsPref),
      maxLogos: readLimit(kVideoMetadataMaxLogosPref),
      downloadStaffImages: preferences.getPref(kVideoMetadataStaffImagesPref,
          defaultValue: false) as bool,
    );
  }
}
