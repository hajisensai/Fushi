import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'package:fushi/src/media/torrent/anime_download_config.dart';

/// 一个下载后端**实例**的身份。
///
/// 只包含「这是哪一台下载器」——内置引擎的安装 id，或 qBittorrent 的
/// 地址+账号。**分类不在其中，也永远不要加回来**：分类是「种子往哪个篮子
/// 放」的投放偏好，用户随时可以改，改了并不意味着换了一台下载器。
///
/// 曾经 `category` 是本类的字段并参与流水线的后端一致性守卫，导致用户在设置
/// 里改一次分类（或升级后默认分类漂移）就把全部在途任务判成「后端换了」并
/// 卡死在 needsAttention，重试还会再撞同一道门（BUG-1879）。任务自己的
/// 投放分类记录在 `VideoDownloadJobs.category` 一列里，由任务自己带着走。
class VideoDownloadBackendIdentity {
  const VideoDownloadBackendIdentity({
    required this.kind,
    required this.profileId,
    required this.fingerprint,
  });

  final String kind;
  final String profileId;
  final String fingerprint;

  /// 两个身份是否指向同一个后端实例。流水线守卫的唯一判据。
  bool matches(VideoDownloadBackendIdentity other) =>
      kind == other.kind &&
      profileId == other.profileId &&
      fingerprint == other.fingerprint;
}

/// 新任务/新订阅的落点：往**哪个后端实例**的**哪个分类**里投。
///
/// 只在创建任务时使用——创建那一刻的分类会被快照进任务行，之后任务始终用
/// 自己那一份，不再与当前设置比较。
class VideoDownloadBackendTarget {
  const VideoDownloadBackendTarget({
    required this.identity,
    required this.category,
  });

  final VideoDownloadBackendIdentity identity;

  /// 当前设置里的投放分类。
  final String category;

  String get kind => identity.kind;
  String get profileId => identity.profileId;
  String get fingerprint => identity.fingerprint;
}

class VideoDownloadBackendUnavailable implements Exception {
  const VideoDownloadBackendUnavailable(this.message);

  final String message;

  @override
  String toString() => message;
}

const String videoDownloadEmbeddedBackendUnavailableMessage =
    'The built-in download engine runtime is missing. Restore the bundled '
    'Windows runtime or reinstall the complete Windows package.';

/// 当前配置对应的后端**实例身份**（不含分类）。
VideoDownloadBackendIdentity buildVideoDownloadBackendIdentity({
  required QbConnectionConfig config,
  required String resolvedBackend,
  required String embeddedInstallationId,
  bool embeddedAvailable = true,
}) {
  if (resolvedBackend == QbConnectionConfig.backendEmbedded) {
    if (!embeddedAvailable) {
      throw const VideoDownloadBackendUnavailable(
        videoDownloadEmbeddedBackendUnavailableMessage,
      );
    }
    final String installationId = embeddedInstallationId.trim();
    if (installationId.isEmpty) {
      throw ArgumentError('embedded installation id must not be empty');
    }
    return VideoDownloadBackendIdentity(
      kind: QbConnectionConfig.backendEmbedded,
      profileId: 'embedded',
      fingerprint: _sha256('embedded|$installationId'),
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
  );
}

/// 当前配置对应的新任务落点（实例身份 + 当前投放分类）。
VideoDownloadBackendTarget buildVideoDownloadBackendTarget({
  required QbConnectionConfig config,
  required String resolvedBackend,
  required String embeddedInstallationId,
  bool embeddedAvailable = true,
}) =>
    VideoDownloadBackendTarget(
      identity: buildVideoDownloadBackendIdentity(
        config: config,
        resolvedBackend: resolvedBackend,
        embeddedInstallationId: embeddedInstallationId,
        embeddedAvailable: embeddedAvailable,
      ),
      category: config.category,
    );

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
