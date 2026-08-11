import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/webdav_ops.dart';

/// Normalizes a manually-entered Hibiki interconnect URL.
///
/// Hibiki's LAN host mode is plain HTTP unless the host explicitly enables
/// TLS. Manual entry therefore defaults bare `host:port` input to `http://`
/// while preserving an explicit `https://` for pinned TLS hosts.
String normalizeFushiInterconnectManualUrl(String rawUrl) {
  final String trimmed = rawUrl.trim();
  final RegExpMatch? explicitScheme =
      RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*):\/\/').firstMatch(trimmed);
  final String withScheme;
  if (explicitScheme == null) {
    withScheme = 'http://$trimmed';
  } else if (explicitScheme.group(1)!.toLowerCase() == 'http' ||
      explicitScheme.group(1)!.toLowerCase() == 'https') {
    withScheme = trimmed;
  } else {
    throw SyncBackendError('Fushi URL must use http:// or https://');
  }
  return WebDavOps.normalizeUrl(withScheme);
}

/// BUG-1557：两条互联地址是否指向**同一个端点**（scheme + host + port 全同，
/// 大小写与末尾斜杠不计）。
///
/// 用途：编辑列表里某条地址时判断「还是那台机器吗」。不是同一端点就必须把该条已
/// TOFU 铉扎的证书指纹清掉——指纹铉的是**那台 host 的证书**，把地址改指另一台
/// 机器后它就只是一把永远开不了新锁的旧钥匙：https 握手每次都失败，UI 里又没有清
/// 指纹的入口，用户看到的只是「这条地址永远连不上」，删了重加才活。同一端点
/// （只是补了个斜杠 / 改了大小写）则保留指纹，不平白丢掉已建立的信任。
bool isSameInterconnectEndpoint(String a, String b) {
  final Uri? ua = Uri.tryParse(WebDavOps.normalizeUrl(a.trim()));
  final Uri? ub = Uri.tryParse(WebDavOps.normalizeUrl(b.trim()));
  if (ua == null || ub == null) return false;
  if (ua.host.isEmpty || ub.host.isEmpty) return a.trim() == b.trim();
  final String schemeA = ua.scheme.toLowerCase();
  final String schemeB = ub.scheme.toLowerCase();
  return schemeA == schemeB &&
      ua.host.toLowerCase() == ub.host.toLowerCase() &&
      _effectivePort(ua, schemeA) == _effectivePort(ub, schemeB);
}

/// 显式端口，缺省时用 scheme 默认端口（http=80 / https=443）。
int _effectivePort(Uri u, String scheme) {
  if (u.hasPort) return u.port;
  return scheme == 'https' ? 443 : 80;
}
