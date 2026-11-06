import 'dart:convert';

import 'package:fushi_engine/foundation/pref_store.dart';

/// 按站点记住的权限种类。值名即持久化值，改名要迁移。
enum WebBrowserSitePermission {
  camera,
  microphone,
  geolocation,
  notifications,
  clipboard,

  /// 受保护内容（EME / DRM：Android WebView 的 `RESOURCE_PROTECTED_MEDIA_ID`）。
  /// 没记住时默认允许，见 [webBrowserEffectiveDecision]。
  protectedContent,
  autoplay,
  popups,
}

/// 没记住（`ask`）时直接允许、不弹框的权限：受保护内容与 Chrome 默认一致——不放行
/// Widevine 站点就放不了正版视频，弹框问用户也只会点允许。用户在网站设置里显式阻止的照样阻止。
const Set<WebBrowserSitePermission> kWebBrowserDefaultAllowedPermissions =
    <WebBrowserSitePermission>{WebBrowserSitePermission.protectedContent};

/// 记住的决定 → 生效的决定：默认允许的权限把 `ask` 当 `allow`。
WebBrowserPermissionDecision webBrowserEffectiveDecision(
  WebBrowserSitePermission permission,
  WebBrowserPermissionDecision remembered,
) =>
    remembered == WebBrowserPermissionDecision.ask &&
        kWebBrowserDefaultAllowedPermissions.contains(permission)
    ? WebBrowserPermissionDecision.allow
    : remembered;

/// 用户对某站点某权限的决定。`ask` = 没记住（每次问），不落盘。
enum WebBrowserPermissionDecision { ask, allow, block }

/// 偏好键（设备本地，不进备份 / 同步）：`{origin: {permission: decision}}`。
const String kWebBrowserSitePermissionsPref = 'web_browser_site_permissions';

/// 站点身份：`scheme://host[:port]`（非默认端口才带）。非 http(s) 或无主机返回 null。
String? webBrowserOriginOf(Uri url) {
  if ((url.scheme != 'http' && url.scheme != 'https') || url.host.isEmpty) {
    return null;
  }
  final String host = url.host.toLowerCase();
  final String hostPart = host.contains(':') ? '[$host]' : host;
  final bool defaultPort =
      !url.hasPort ||
      (url.scheme == 'http' && url.port == 80) ||
      (url.scheme == 'https' && url.port == 443);
  return '${url.scheme}://$hostPart${defaultPort ? '' : ':${url.port}'}';
}

/// 把调用方给的 origin 字符串（也可能是整条网址）规整成 [webBrowserOriginOf] 口径；
/// 解析不出来就原样 trim 后使用，保证同一个键读写一致。
String _normalizeOrigin(String origin) {
  final Uri? uri = Uri.tryParse(origin.trim());
  final String? normalized = uri == null ? null : webBrowserOriginOf(uri);
  return normalized ?? origin.trim();
}

/// 按站点（origin）记住的权限决定。读一次偏好后缓存在内存，写入立即落盘。
class WebBrowserSiteSettings {
  WebBrowserSiteSettings(this._prefs);

  final PrefStore _prefs;
  Map<String, Map<WebBrowserSitePermission, WebBrowserPermissionDecision>>?
  _cache;

  Map<String, Map<WebBrowserSitePermission, WebBrowserPermissionDecision>>
  _load() => _cache ??= decodeWebBrowserSitePermissions(
    _prefs.getPref(kWebBrowserSitePermissionsPref)?.toString() ?? '',
  );

  Future<void> _save() => _prefs.setPref(
    kWebBrowserSitePermissionsPref,
    encodeWebBrowserSitePermissions(_load()),
  );

  WebBrowserPermissionDecision decision(
    String origin,
    WebBrowserSitePermission permission,
  ) =>
      _load()[_normalizeOrigin(origin)]?[permission] ??
      WebBrowserPermissionDecision.ask;

  /// 设成 `ask` 等于忘掉这条；站点下没剩任何决定时整站移除。
  Future<void> setDecision(
    String origin,
    WebBrowserSitePermission permission,
    WebBrowserPermissionDecision decision,
  ) async {
    final String key = _normalizeOrigin(origin);
    if (key.isEmpty) return;
    final Map<
      String,
      Map<WebBrowserSitePermission, WebBrowserPermissionDecision>
    >
    all = _load();
    if (decision == WebBrowserPermissionDecision.ask) {
      final Map<WebBrowserSitePermission, WebBrowserPermissionDecision>? site =
          all[key];
      if (site == null || site.remove(permission) == null) return;
      if (site.isEmpty) all.remove(key);
    } else {
      (all[key] ??=
              <
                WebBrowserSitePermission,
                WebBrowserPermissionDecision
              >{})[permission] =
          decision;
    }
    await _save();
  }

  /// 全部站点的只读快照（按 origin 排序）。
  Map<String, Map<WebBrowserSitePermission, WebBrowserPermissionDecision>>
  all() {
    final List<String> origins = _load().keys.toList()..sort();
    return Map<
      String,
      Map<WebBrowserSitePermission, WebBrowserPermissionDecision>
    >.unmodifiable(
      <String, Map<WebBrowserSitePermission, WebBrowserPermissionDecision>>{
        for (final String origin in origins)
          origin:
              Map<
                WebBrowserSitePermission,
                WebBrowserPermissionDecision
              >.unmodifiable(_load()[origin]!),
      },
    );
  }

  Future<void> clearSite(String origin) async {
    if (_load().remove(_normalizeOrigin(origin)) == null) return;
    await _save();
  }

  Future<void> clearAll() async {
    _load().clear();
    await _save();
  }
}

/// 偏好 JSON → 内存表；坏 JSON / 未知权限名 / 未知决定一律丢弃（不抛）。
Map<String, Map<WebBrowserSitePermission, WebBrowserPermissionDecision>>
decodeWebBrowserSitePermissions(String raw) {
  final Map<String, Map<WebBrowserSitePermission, WebBrowserPermissionDecision>>
  result =
      <String, Map<WebBrowserSitePermission, WebBrowserPermissionDecision>>{};
  if (raw.trim().isEmpty) return result;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return result;
  }
  if (decoded is! Map) return result;
  for (final MapEntry<Object?, Object?> site in decoded.entries) {
    final Object? perms = site.value;
    if (site.key is! String || perms is! Map) continue;
    final Map<WebBrowserSitePermission, WebBrowserPermissionDecision> parsed =
        <WebBrowserSitePermission, WebBrowserPermissionDecision>{};
    for (final MapEntry<Object?, Object?> entry in perms.entries) {
      final WebBrowserSitePermission? permission = _byName(
        WebBrowserSitePermission.values,
        entry.key,
      );
      final WebBrowserPermissionDecision? decision = _byName(
        WebBrowserPermissionDecision.values,
        entry.value,
      );
      if (permission == null ||
          decision == null ||
          decision == WebBrowserPermissionDecision.ask) {
        continue;
      }
      parsed[permission] = decision;
    }
    if (parsed.isNotEmpty) result[site.key! as String] = parsed;
  }
  return result;
}

String encodeWebBrowserSitePermissions(
  Map<String, Map<WebBrowserSitePermission, WebBrowserPermissionDecision>> all,
) => jsonEncode(<String, Object?>{
  for (final MapEntry<
        String,
        Map<WebBrowserSitePermission, WebBrowserPermissionDecision>
      >
      site
      in all.entries)
    site.key: <String, String>{
      for (final MapEntry<
            WebBrowserSitePermission,
            WebBrowserPermissionDecision
          >
          e
          in site.value.entries)
        e.key.name: e.value.name,
    },
});

T? _byName<T extends Enum>(List<T> values, Object? name) {
  for (final T v in values) {
    if (v.name == name) return v;
  }
  return null;
}
