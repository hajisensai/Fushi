/// WebUI / admin API / `ctl settings` 的「在线字幕来源」读写面（OpenSubtitles / SubDL / Jimaku）。
///
/// 存储与 app 完全同一份：`preferences` 表里的 `video_subtitle_opensubtitles_config`（整份
/// JSON，编解码走引擎 `OpenSubtitlesConfig`）、`video_subtitle_subdl_api_key` /
/// `video_subtitle_subdl_enabled`、`jimaku_api_key` / `jimaku_enabled`。写经 [PrefStore]
/// （服务端 = `ServerPrefs`），下载管线每轮字幕阶段、补字幕每次请求都现读，所以保存即生效。
///
/// 规则（与 TMDB key / qBittorrent 密码 / 资源索引器 key 同一口径）：
/// - key / 密码永不回显，只报 `apiKeySet` / `passwordSet`；
/// - 提交时留空（或不给）= 不改；`clearApiKey: true` / `clearPassword: true` 才清空；
/// - 整个 `subtitleProviders` 先全部校验再落库：任何一项非法 → [FormatException]（admin API
///   回 400），一个字节都不写。
///
/// 与环境变量的先后：沿用 [resolveSubsCredentials] 的既有口径——`FUSHI_*` 环境变量给了
/// key 就压过偏好里存的 key（偏好里的开关仍然作数）。GET 用 `apiKeyFromEnv` 如实报出
/// 「存的 key 此刻被环境变量盖住」，`active` 报下一轮字幕阶段会不会用这一家。
library;

import 'dart:convert';

import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi_engine/media/video/subtitle/subdl_client.dart';
import 'package:fushi_server/src/server_subtitle_providers.dart';

/// 请求体里的键（`PUT /api/admin/settings` 的 `subtitleProviders`）。
const String kSubtitleProvidersSettingsKey = 'subtitleProviders';

/// GET 的 JSON 形状：每家只报开关、「设过没有」与是否生效，凭据一律不出境。
Map<String, Object?> subtitleProviderSettingsToJson(
  PrefStore prefs,
  Map<String, String> environment,
) {
  final SubsCredentials credentials = resolveSubsCredentials(
    prefs,
    environment,
  );
  final OpenSubtitlesConfig storedOs = readStoredOpenSubtitlesConfig(prefs);
  bool fromEnv(String name) => (environment[name] ?? '').trim().isNotEmpty;
  return <String, Object?>{
    'opensubtitles': <String, Object?>{
      'enabled': credentials.openSubtitlesPrefEnabled,
      'apiKeySet': storedOs.apiKey.trim().isNotEmpty,
      'apiKeyFromEnv': fromEnv(kOpenSubtitlesApiKeyEnv),
      // 没填自己的 key 时走 app 内置的应用 key（仅官方 API 地址）。
      'builtinKey':
          storedOs.apiKey.trim().isEmpty && storedOs.effectiveApiKey.isNotEmpty,
      'username': storedOs.username ?? '',
      'passwordSet': (storedOs.password ?? '').isNotEmpty,
      'active': credentials.usableAutomatically('opensubtitles'),
    },
    kSubdlSubtitleProviderId: <String, Object?>{
      'enabled': credentials.subdlPrefEnabled,
      'apiKeySet': prefString(prefs, kSubdlApiKeyPref).isNotEmpty,
      'apiKeyFromEnv': fromEnv(kSubdlApiKeyEnv),
      'active': credentials.usableAutomatically(kSubdlSubtitleProviderId),
    },
    'jimaku': <String, Object?>{
      'enabled': credentials.jimakuPrefEnabled,
      'apiKeySet': prefString(prefs, kJimakuApiKeyPref).isNotEmpty,
      'apiKeyFromEnv': fromEnv(kJimakuApiKeyEnv),
      'active': credentials.usableAutomatically('jimaku'),
    },
  };
}

/// 一次已校验的修改：[apply] 只做写入。
class SubtitleProviderSettingsUpdate {
  SubtitleProviderSettingsUpdate._(this._writes);

  /// 偏好键 → 新值（已按存储格式编码好）。
  final Map<String, Object> _writes;

  /// 会写哪些偏好键（测试 / 诊断用；不含值）。
  Iterable<String> get keys => _writes.keys;

  bool get isEmpty => _writes.isEmpty;

  Future<void> apply(PrefStore prefs) async {
    for (final MapEntry<String, Object> e in _writes.entries) {
      await prefs.setPref(e.key, e.value);
    }
  }
}

/// 校验 `subtitleProviders` 并算出要写的偏好；非法 → [FormatException]（消息里不带凭据）。
SubtitleProviderSettingsUpdate parseSubtitleProviderSettings(
  Object? raw,
  PrefStore prefs,
) {
  if (raw is! Map) {
    throw const FormatException('subtitleProviders must be an object');
  }
  final Map<String, Object> writes = <String, Object>{};
  for (final MapEntry<Object?, Object?> entry in raw.entries) {
    final String id = '${entry.key}';
    final Object? value = entry.value;
    if (value == null) continue;
    if (value is! Map) {
      throw FormatException('subtitleProviders.$id must be an object');
    }
    final _Fields f = _Fields(id, value);
    switch (id) {
      case 'opensubtitles':
        f.only(const <String>{
          'enabled',
          'apiKey',
          'clearApiKey',
          'username',
          'password',
          'clearPassword',
        });
        final OpenSubtitlesConfig current = readStoredOpenSubtitlesConfig(
          prefs,
        );
        final String? apiKey = f.secret('apiKey', clear: 'clearApiKey');
        final String? password = f.secret(
          'password',
          clear: 'clearPassword',
          trim: false,
        );
        final String? username = f.text('username');
        final bool? enabled = f.flag('enabled');
        if (apiKey == null &&
            password == null &&
            username == null &&
            enabled == null) {
          break;
        }
        final OpenSubtitlesConfig next = OpenSubtitlesConfig(
          apiKey: apiKey ?? current.apiKey,
          username: username ?? current.username,
          password: password ?? current.password,
          userAgent: current.userAgent,
          baseUrl: current.baseUrl,
          enabled: enabled ?? current.enabled,
          priority: current.priority,
          allowInsecureHttp: current.allowInsecureHttp,
        );
        writes[kOpenSubtitlesConfigPref] = jsonEncode(next.toJson());
      case kSubdlSubtitleProviderId:
        f.only(const <String>{'enabled', 'apiKey', 'clearApiKey'});
        final String? apiKey = f.secret('apiKey', clear: 'clearApiKey');
        final bool? enabled = f.flag('enabled');
        if (apiKey != null) writes[kSubdlApiKeyPref] = apiKey;
        if (enabled != null) writes[kSubdlEnabledPref] = enabled;
      case 'jimaku':
        f.only(const <String>{'enabled', 'apiKey', 'clearApiKey'});
        final String? apiKey = f.secret('apiKey', clear: 'clearApiKey');
        final bool? enabled = f.flag('enabled');
        if (apiKey != null) writes[kJimakuApiKeyPref] = apiKey;
        if (enabled != null) writes[kJimakuEnabledPref] = enabled;
      default:
        throw FormatException(
          'subtitleProviders.$id: unknown provider '
          '(expected ${kSubsProviderIds.join(' / ')})',
        );
    }
  }
  return SubtitleProviderSettingsUpdate._(writes);
}

/// 单家来源字段的类型校验。
class _Fields {
  _Fields(this.id, Map<Object?, Object?> raw)
    : values = <String, Object?>{
        for (final MapEntry<Object?, Object?> e in raw.entries)
          '${e.key}': e.value,
      };

  final String id;
  final Map<String, Object?> values;

  void only(Set<String> allowed) {
    for (final String key in values.keys) {
      if (!allowed.contains(key)) {
        throw FormatException('subtitleProviders.$id.$key is not a setting');
      }
    }
  }

  bool? flag(String key) {
    final Object? v = values[key];
    if (v != null && v is! bool) {
      throw FormatException('subtitleProviders.$id.$key must be a boolean');
    }
    return v as bool?;
  }

  /// 普通文本：null = 不改。
  String? text(String key) {
    final Object? v = values[key];
    if (v != null && v is! String) {
      throw FormatException('subtitleProviders.$id.$key must be a string');
    }
    return (v as String?)?.trim();
  }

  /// 凭据：空 / 不给 = 不改（null）；[clear] 为 true = 清空（''）。同时给值又要清空 = 400。
  String? secret(String key, {required String clear, bool trim = true}) {
    final Object? raw = values[key];
    if (raw != null && raw is! String) {
      throw FormatException('subtitleProviders.$id.$key must be a string');
    }
    final String value = trim
        ? (raw as String? ?? '').trim()
        : raw as String? ?? '';
    final bool clearIt = flag(clear) ?? false;
    if (clearIt && value.isNotEmpty) {
      throw FormatException(
        'subtitleProviders.$id: give either $key or $clear, not both',
      );
    }
    if (clearIt) return '';
    return value.isEmpty ? null : value;
  }
}
