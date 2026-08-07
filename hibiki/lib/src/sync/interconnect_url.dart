import 'package:fushi/src/sync/sync_backend.dart';
import 'package:fushi/src/sync/webdav_ops.dart';

/// Normalizes a manually-entered Hibiki interconnect URL.
///
/// Hibiki's LAN host mode is plain HTTP unless the host explicitly enables
/// TLS. Manual entry therefore defaults bare `host:port` input to `http://`
/// while preserving an explicit `https://` for pinned TLS hosts.
String normalizeHibikiInterconnectManualUrl(String rawUrl) {
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
