/// 服务端的在线字幕来源装配：`subs` 命令、下载管线的字幕阶段、单视频补字幕
/// （`POST /api/library/videos/<id>/subtitle/backfill`）共用这一份。
///
/// 凭据只从环境变量或偏好表读，不进 argv：环境变量（显式意图，优先）
/// `FUSHI_OPENSUBTITLES_API_KEY` / `FUSHI_OPENSUBTITLES_USERNAME` /
/// `FUSHI_OPENSUBTITLES_PASSWORD`、`FUSHI_SUBDL_API_KEY`、`FUSHI_JIMAKU_API_KEY`；
/// 其次是与 app 同名的偏好键（`video_subtitle_opensubtitles_config` /
/// `video_subtitle_subdl_api_key` / `jimaku_api_key` 及其 `*_enabled`）。服务端上写这些
/// 偏好的入口是 WebUI「设置 → 在线字幕来源」/ `PUT /api/admin/settings` 的
/// `subtitleProviders` / `ctl settings subtitle-key|subtitle-source`（见
/// admin/subtitle_provider_settings.dart）；作为互联 host 时它们也在下发给已配对设备的
/// 「服务账号」共享清单里（`InterconnectServiceConfigSnapshot`）。
///
/// 两种用法的门控**有意不同**：
/// - 命令行（[SubsCredentials.unavailableReason]）：人在场、点名要用，设了环境变量
///   就视为临时启用，压过偏好里的关闭；
/// - 无人值守（[SubsCredentials.usableAutomatically]，下载 / 补字幕）：偏好里关掉的
///   来源一律不用，环境变量只补 key、不推翻关闭。没 key 的同样不用。
library;

import 'dart:convert';
import 'dart:io';

import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/video/download/video_download_subtitle_language.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart';
import 'package:fushi_engine/media/video/jimaku_subtitle_provider.dart';
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi_engine/media/video/subtitle/subdl_client.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/utils/net/app_http.dart';

/// 支持的字幕来源 id（与引擎 provider 的 `id` 一致）。
const List<String> kSubsProviderIds = <String>[
  'opensubtitles',
  kSubdlSubtitleProviderId,
  'jimaku',
];

const String kOpenSubtitlesApiKeyEnv = 'FUSHI_OPENSUBTITLES_API_KEY';
const String kOpenSubtitlesUsernameEnv = 'FUSHI_OPENSUBTITLES_USERNAME';
const String kOpenSubtitlesPasswordEnv = 'FUSHI_OPENSUBTITLES_PASSWORD';
const String kSubdlApiKeyEnv = 'FUSHI_SUBDL_API_KEY';
const String kJimakuApiKeyEnv = 'FUSHI_JIMAKU_API_KEY';

/// 与 app `PreferencesRepository` 同名的偏好键。
const String kOpenSubtitlesConfigPref = 'video_subtitle_opensubtitles_config';
const String kSubdlApiKeyPref = 'video_subtitle_subdl_api_key';
const String kSubdlEnabledPref = 'video_subtitle_subdl_enabled';
const String kJimakuApiKeyPref = 'jimaku_api_key';
const String kJimakuEnabledPref = 'jimaku_enabled';

/// 每系列字幕语言记忆（app 字幕工作台 / AI 下载写，`{ "<series 小写>": "<lang>" }`）。
const String kSeriesSubtitleLanguagesPref = 'jimaku_pref_langs';

/// 设置·外观·排版里的默认内容语言（app 同名键，`''` = 未设置）。
const String kDefaultContentLanguagePref = 'default_content_language';

/// 「自动下载的外挂字幕按内嵌字幕轨对时间轴」开关（app 同名键，默认开）。
const String kSubtitleReferenceSyncEnabledPref =
    'subtitle_reference_sync_enabled';

/// 按来源 id 与凭据造一个 provider（测试注入假实现）。
typedef SubsProviderFactory =
    VideoSubtitleProvider Function(
      String providerId,
      SubsCredentials credentials,
    );

/// 三家来源的凭据（环境变量优先，其次偏好表）。
class SubsCredentials {
  const SubsCredentials({
    required this.openSubtitles,
    required this.subdlApiKey,
    required this.subdlEnabled,
    required this.jimakuApiKey,
    required this.jimakuEnabled,
    this.openSubtitlesPrefEnabled = true,
    this.subdlPrefEnabled = true,
    this.jimakuPrefEnabled = true,
  });

  final OpenSubtitlesConfig openSubtitles;
  final String subdlApiKey;

  /// 命令行口径的「启用」：偏好开着，或设了环境变量（临时启用）。
  final bool subdlEnabled;
  final String jimakuApiKey;

  /// 同 [subdlEnabled]。
  final bool jimakuEnabled;

  /// 偏好表里的开关本身（不看环境变量）。无人值守路径只认这三个。
  final bool openSubtitlesPrefEnabled;
  final bool subdlPrefEnabled;
  final bool jimakuPrefEnabled;

  /// [providerId] 能不能用；不能用时返回给用户的配置提示，能用返回 null。
  String? unavailableReason(String providerId) {
    switch (providerId) {
      case 'opensubtitles':
        if (!openSubtitles.enabled) {
          return 'OpenSubtitles 已在偏好里关闭（设 $kOpenSubtitlesApiKeyEnv 可临时启用）';
        }
        if (openSubtitles.effectiveApiKey.isEmpty) {
          return 'OpenSubtitles 没有 API key：设环境变量 $kOpenSubtitlesApiKeyEnv，或在 WebUI「设置 → 在线字幕来源」/ `fushi_server ctl settings subtitle-key` 里存';
        }
        return null;
      case kSubdlSubtitleProviderId:
        if (subdlApiKey.isEmpty) {
          return 'SubDL 没有 API key：设环境变量 $kSubdlApiKeyEnv，或在 WebUI「设置 → 在线字幕来源」/ `fushi_server ctl settings subtitle-key` 里存';
        }
        if (!subdlEnabled) return 'SubDL 已在偏好里关闭（设 $kSubdlApiKeyEnv 可临时启用）';
        return null;
      case 'jimaku':
        if (jimakuApiKey.isEmpty) {
          return 'Jimaku 没有 API key：设环境变量 $kJimakuApiKeyEnv，或在 WebUI「设置 → 在线字幕来源」/ `fushi_server ctl settings subtitle-key` 里存';
        }
        if (!jimakuEnabled) return 'Jimaku 已在偏好里关闭（设 $kJimakuApiKeyEnv 可临时启用）';
        return null;
    }
    return '未知字幕来源 $providerId';
  }

  /// 无人值守路径（下载管线 / 补字幕）能不能用 [providerId]：偏好开关开着**且**有 key。
  /// 与 app `createConfiguredVideoSubtitleProviders` 同一判据（`enabled && key`）；
  /// 环境变量只补 key，不推翻偏好里的关闭。
  bool usableAutomatically(String providerId) {
    switch (providerId) {
      case 'opensubtitles':
        return openSubtitlesPrefEnabled &&
            openSubtitles.effectiveApiKey.isNotEmpty;
      case kSubdlSubtitleProviderId:
        return subdlPrefEnabled && subdlApiKey.isNotEmpty;
      case 'jimaku':
        return jimakuPrefEnabled && jimakuApiKey.isNotEmpty;
    }
    return false;
  }
}

String _env(Map<String, String> env, String name) => (env[name] ?? '').trim();

/// 读凭据：环境变量是显式意图，给了就视为（命令行口径的）启用；否则按偏好表
/// （与 app 同一判据）。
SubsCredentials resolveSubsCredentials(
  PrefStore prefs,
  Map<String, String> env,
) {
  final OpenSubtitlesConfig fromPrefs = readStoredOpenSubtitlesConfig(prefs);
  OpenSubtitlesConfig openSubtitles = fromPrefs;
  final String osKey = _env(env, kOpenSubtitlesApiKeyEnv);
  final String osUser = _env(env, kOpenSubtitlesUsernameEnv);
  final String osPassword = env[kOpenSubtitlesPasswordEnv] ?? '';
  if (osKey.isNotEmpty || osUser.isNotEmpty) {
    openSubtitles = OpenSubtitlesConfig(
      apiKey: osKey.isNotEmpty ? osKey : openSubtitles.apiKey,
      username: osUser.isNotEmpty ? osUser : openSubtitles.username,
      password: osPassword.isNotEmpty ? osPassword : openSubtitles.password,
      userAgent: openSubtitles.userAgent,
      baseUrl: openSubtitles.baseUrl,
      priority: openSubtitles.priority,
      allowInsecureHttp: openSubtitles.allowInsecureHttp,
    );
  }
  final String subdlEnv = _env(env, kSubdlApiKeyEnv);
  final String jimakuEnv = _env(env, kJimakuApiKeyEnv);
  final bool subdlPref = prefBool(prefs, kSubdlEnabledPref, defaultValue: true);
  final bool jimakuPref = prefBool(
    prefs,
    kJimakuEnabledPref,
    defaultValue: true,
  );
  return SubsCredentials(
    openSubtitles: openSubtitles,
    subdlApiKey: subdlEnv.isNotEmpty
        ? subdlEnv
        : prefString(prefs, kSubdlApiKeyPref),
    subdlEnabled: subdlEnv.isNotEmpty || subdlPref,
    jimakuApiKey: jimakuEnv.isNotEmpty
        ? jimakuEnv
        : prefString(prefs, kJimakuApiKeyPref),
    jimakuEnabled: jimakuEnv.isNotEmpty || jimakuPref,
    openSubtitlesPrefEnabled: fromPrefs.enabled,
    subdlPrefEnabled: subdlPref,
    jimakuPrefEnabled: jimakuPref,
  );
}

/// 偏好里的字符串（去首尾空白；不是字符串按空串）。
String prefString(PrefStore prefs, String key) {
  final Object? value = prefs.getPref(key, defaultValue: '');
  return value is String ? value.trim() : '';
}

/// 偏好里的布尔（不是布尔按 [defaultValue]）。
bool prefBool(PrefStore prefs, String key, {required bool defaultValue}) {
  final Object? value = prefs.getPref(key, defaultValue: defaultValue);
  return value is bool ? value : defaultValue;
}

/// 偏好里存的 OpenSubtitles 配置（不叠环境变量）。与 app
/// `PreferencesRepository.videoSubtitleOpenSubtitlesConfig` 同一解码口径：
/// 没配置过 / 解不开 = [OpenSubtitlesConfig.unconfigured]。
OpenSubtitlesConfig readStoredOpenSubtitlesConfig(PrefStore prefs) {
  final String raw = prefString(prefs, kOpenSubtitlesConfigPref);
  if (raw.isEmpty) return OpenSubtitlesConfig.unconfigured();
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return OpenSubtitlesConfig.unconfigured();
    return OpenSubtitlesConfig.fromJson(<String, Object?>{
      for (final MapEntry<Object?, Object?> e in decoded.entries)
        e.key.toString(): e.value,
    });
  } on Object catch (e, st) {
    engineLog.log(
      'ServerSubtitleProviders.openSubtitlesConfig ($kOpenSubtitlesConfigPref 解不开，按未配置处理)',
      e,
      st,
    );
    return OpenSubtitlesConfig.unconfigured();
  }
}

/// 生产的 provider 装配（Jimaku 出站经 `createAppHttpIoClient`，跟随全应用代理）。
VideoSubtitleProvider createSubsProvider(
  String providerId,
  SubsCredentials credentials,
) {
  switch (providerId) {
    case 'opensubtitles':
      return OpenSubtitlesClient(config: credentials.openSubtitles);
    case kSubdlSubtitleProviderId:
      return SubdlClient(apiKey: credentials.subdlApiKey);
    case 'jimaku':
      // 与 app 同一个 provider：AniList id / TMDB 关联键直查，标题只是回退词；
      // 整季压缩包按集号解包。
      return JimakuVideoSubtitleProvider(
        client: JimakuClient(
          apiKey: credentials.jimakuApiKey,
          client: createAppHttpIoClient(),
        ),
        closesClient: true,
      );
  }
  throw ArgumentError.value(providerId, 'providerId', '未知字幕来源');
}

/// 无人值守路径用的字幕 registry：只装 [SubsCredentials.usableAutomatically] 的来源。
/// 一家都没有时 registry 为空——下载管线据此跳过字幕阶段，补字幕回 `unavailable`。
/// 调用方持有并负责 `close()`。
VideoSubtitleRegistry buildServerSubtitleRegistry(
  PrefStore prefs, {
  Map<String, String>? environment,
  SubsProviderFactory providerFactory = createSubsProvider,
}) {
  final SubsCredentials credentials = resolveSubsCredentials(
    prefs,
    environment ?? Platform.environment,
  );
  return VideoSubtitleRegistry(<VideoSubtitleProvider>[
    for (final String id in kSubsProviderIds)
      if (credentials.usableAutomatically(id)) providerFactory(id, credentials),
  ]);
}

/// 配置里的字幕语言（`subtitle_language`）→ 显式字幕语言列表（空 = 不限）。
List<String> serverPreferredSubtitleLanguages(String configured) {
  final String trimmed = configured.trim();
  return trimmed.isEmpty ? const <String>[] : <String>[trimmed];
}

/// 默认内容语言（app 同名偏好）；未设置为 null。
String? serverDefaultContentLanguage(PrefStore prefs) {
  final String value = prefString(prefs, kDefaultContentLanguagePref);
  return value.isEmpty ? null : value;
}

/// 每系列字幕语言记忆：[seriesKey] 记过就返回语言码，否则 null（app
/// `AppModel._seriesSubtitleLanguage` 同一张表、同一解码）。
String? serverSeriesSubtitleLanguage(PrefStore prefs, String seriesKey) {
  final String raw = prefString(prefs, kSeriesSubtitleLanguagesPref);
  if (raw.isEmpty) return null;
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return null;
    final String code = (decoded[seriesKey] ?? '').toString().trim();
    return code.isEmpty ? null : code;
  } on FormatException catch (e, st) {
    engineLog.log('ServerSubtitleProviders.seriesLanguage', e, st);
    return null;
  }
}

/// 下载管线字幕阶段的按作品语言解析器：先合集名、再裸标题（与 app
/// `_resolveVideoDownloadSubtitleLanguage` 同两把钥匙）。
VideoDownloadSubtitleLanguageResolver serverDownloadSubtitleLanguageResolver(
  PrefStore prefs,
) =>
    (VideoDownloadSubtitleLanguageQuery query) =>
        serverSeriesSubtitleLanguage(prefs, query.seriesKey) ??
        serverSeriesSubtitleLanguage(prefs, query.title.trim().toLowerCase());

/// 自动路径共用的对齐钩子：开关每次调用现读（app `alignDownloadedSubtitle` 同形）。
AutomaticSubtitleAligner serverSubtitleAligner(PrefStore prefs) =>
    gatedAutomaticSubtitleAligner(
      () => prefBool(
        prefs,
        kSubtitleReferenceSyncEnabledPref,
        defaultValue: true,
      ),
    );
