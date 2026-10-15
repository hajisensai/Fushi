import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 某个下载后端配置档的路径映射快照。
///
/// 映射必须绑定到实际使用的 backend profile id；切换 qB 地址或账号后，新配置档
/// 不能接管旧任务。这里只保存本机路径，不包含后端密码或 token。
class VideoDownloadBackendPathMappingConfig {
  const VideoDownloadBackendPathMappingConfig({
    required this.backendProfileId,
    required this.remoteRoot,
    required this.localRoot,
  });

  factory VideoDownloadBackendPathMappingConfig.fromJson(
    Map<String, Object?> json,
  ) =>
      VideoDownloadBackendPathMappingConfig(
        backendProfileId: json['backendProfileId'] as String? ?? '',
        remoteRoot: json['remoteRoot'] as String? ?? '',
        localRoot: json['localRoot'] as String? ?? '',
      );

  final String backendProfileId;
  final String remoteRoot;
  final String localRoot;

  bool get isValid =>
      backendProfileId.trim().isNotEmpty &&
      remoteRoot.trim().isNotEmpty &&
      localRoot.trim().isNotEmpty;

  VideoDownloadPathMapping toMapping() => VideoDownloadPathMapping(
        remoteRoot: remoteRoot,
        localRoot: localRoot,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'backendProfileId': backendProfileId,
        'remoteRoot': remoteRoot,
        'localRoot': localRoot,
      };
}

List<VideoDownloadBackendPathMappingConfig>
    decodeVideoDownloadBackendPathMappings(String raw) {
  if (raw.trim().isEmpty) {
    return const <VideoDownloadBackendPathMappingConfig>[];
  }
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List<Object?>) {
      return const <VideoDownloadBackendPathMappingConfig>[];
    }
    return List<VideoDownloadBackendPathMappingConfig>.unmodifiable(
      decoded
          .whereType<Map<Object?, Object?>>()
          .map((Map<Object?, Object?> entry) {
        final Map<String, Object?> json = <String, Object?>{
          for (final MapEntry<Object?, Object?> field in entry.entries)
            field.key.toString(): field.value,
        };
        return VideoDownloadBackendPathMappingConfig.fromJson(json);
      }).where(
        (VideoDownloadBackendPathMappingConfig value) => value.isValid,
      ),
    );
  } on Object {
    return const <VideoDownloadBackendPathMappingConfig>[];
  }
}

String encodeVideoDownloadBackendPathMappings(
  Iterable<VideoDownloadBackendPathMappingConfig> mappings,
) =>
    jsonEncode(
      mappings
          .where(
            (VideoDownloadBackendPathMappingConfig value) => value.isValid,
          )
          .map(
            (VideoDownloadBackendPathMappingConfig value) => value.toJson(),
          )
          .toList(growable: false),
    );

/// qBittorrent 所见路径与 Fushi 本机路径之间的双向映射。
///
/// 远端统一用 `/` 比较和输出；本机侧按当前平台归一化。未配置时可用
/// [VideoDownloadPathMapping.identity]，但目标路径仍须由调用方验证可访问。
class VideoDownloadPathMapping {
  VideoDownloadPathMapping({
    required String remoteRoot,
    required String localRoot,
    bool? localCaseSensitive,
  })  : remoteRoot = _normalizeRemoteRoot(remoteRoot),
        localRoot = p.normalize(p.absolute(localRoot)),
        localCaseSensitive = localCaseSensitive ?? !Platform.isWindows {
    if (this.remoteRoot.isEmpty || this.localRoot.isEmpty) {
      throw ArgumentError('download path mapping roots must not be empty');
    }
  }

  factory VideoDownloadPathMapping.identity(String root) =>
      VideoDownloadPathMapping(remoteRoot: root, localRoot: root);

  final String remoteRoot;
  final String localRoot;
  final bool localCaseSensitive;

  String? remoteToLocal(String remotePath) {
    final String normalized = _normalizeRemote(remotePath);
    final String? suffix = _relativeSuffix(
      normalized,
      remoteRoot,
      caseSensitive: true,
    );
    if (suffix == null) return null;
    if (suffix.isEmpty) return localRoot;
    return p.normalize(p.joinAll(<String>[
      localRoot,
      ...suffix.split('/').where((String segment) => segment.isNotEmpty),
    ]));
  }

  String? localToRemote(String localPath) {
    final String normalized = p.normalize(p.absolute(localPath));
    final String? suffix = _relativeSuffix(
      _portable(normalized),
      _portable(localRoot),
      caseSensitive: localCaseSensitive,
    );
    if (suffix == null) return null;
    return suffix.isEmpty ? remoteRoot : '$remoteRoot/$suffix';
  }

  static String _normalizeRemoteRoot(String value) {
    final String normalized = _normalizeRemote(value);
    if (normalized == '/') return normalized;
    return normalized.replaceFirst(RegExp(r'/+$'), '');
  }

  static String _normalizeRemote(String value) {
    final List<String> segments = <String>[];
    final String portable = _portable(value.trim());
    final bool absolute = portable.startsWith('/');
    final String? drive = RegExp(r'^[A-Za-z]:').firstMatch(portable)?.group(0);
    for (final String segment in portable.split('/')) {
      if (segment.isEmpty || segment == '.') continue;
      if (segment == '..') {
        if (segments.isNotEmpty && segments.last != drive) {
          segments.removeLast();
        }
        continue;
      }
      segments.add(segment);
    }
    final String joined = segments.join('/');
    return absolute ? '/$joined' : joined;
  }

  static String _portable(String value) => value.replaceAll('\\', '/');

  static String? _relativeSuffix(
    String path,
    String root, {
    required bool caseSensitive,
  }) {
    final String comparablePath = caseSensitive ? path : path.toLowerCase();
    final String comparableRoot = caseSensitive ? root : root.toLowerCase();
    if (comparablePath == comparableRoot) return '';
    final String prefix =
        comparableRoot.endsWith('/') ? comparableRoot : '$comparableRoot/';
    if (!comparablePath.startsWith(prefix)) return null;
    return path.substring(prefix.length);
  }
}
