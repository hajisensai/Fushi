import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:hibiki/src/media/torrent/anime_download_config.dart';

class VideoDownloadBackendIdentity {
  const VideoDownloadBackendIdentity({
    required this.kind,
    required this.profileId,
    required this.fingerprint,
    required this.category,
  });

  final String kind;
  final String profileId;
  final String fingerprint;
  final String category;
}

VideoDownloadBackendIdentity buildVideoDownloadBackendIdentity({
  required QbConnectionConfig config,
  required String resolvedBackend,
  required String embeddedInstallationId,
}) {
  if (resolvedBackend == QbConnectionConfig.backendEmbedded) {
    final String installationId = embeddedInstallationId.trim();
    if (installationId.isEmpty) {
      throw ArgumentError('embedded installation id must not be empty');
    }
    return VideoDownloadBackendIdentity(
      kind: QbConnectionConfig.backendEmbedded,
      profileId: 'embedded',
      fingerprint: _sha256('embedded|$installationId'),
      category: config.category,
    );
  }
  final String address = normalizeQbBackendAddress(config.baseUrl);
  if (address.isEmpty) {
    throw ArgumentError('qBittorrent address must not be empty');
  }
  final String identity = _sha256(
    'qbittorrent|$address|${config.username.trim()}',
  );
  return VideoDownloadBackendIdentity(
    kind: QbConnectionConfig.backendQbittorrent,
    profileId: identity,
    fingerprint: identity,
    category: config.category,
  );
}

String normalizeQbBackendAddress(String raw) {
  final Uri? parsed = Uri.tryParse(raw.trim());
  if (parsed == null ||
      (parsed.scheme != 'http' && parsed.scheme != 'https') ||
      parsed.host.isEmpty) {
    return '';
  }
  final String scheme = parsed.scheme.toLowerCase();
  final int defaultPort = scheme == 'https' ? 443 : 80;
  final String host = parsed.host.toLowerCase();
  final String authority = parsed.hasPort && parsed.port != defaultPort
      ? '$host:${parsed.port}'
      : host;
  String path = parsed.path.replaceFirst(RegExp(r'/+$'), '');
  if (path == '/') path = '';
  return '$scheme://$authority$path';
}

String generateVideoDownloadInstallationId({Random? random}) {
  final Random source = random ?? Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final String hex =
      bytes.map((int value) => value.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-'
      '${hex.substring(20)}';
}

String _sha256(String value) => sha256.convert(utf8.encode(value)).toString();
