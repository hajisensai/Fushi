import 'package:flutter/foundation.dart';

enum AudioSourceKind {
  fushiRemote('fushiRemote'),
  localAudio('localAudio'),
  remoteAudio('remoteAudio');

  const AudioSourceKind(this.wireName);

  final String wireName;

  /// Hibiki 时代写下的 wireName（W9-6 改名前）。音频源配置以 JSON 落偏好，存量
  /// 用户经迁移带过来的配置里仍是旧值；不认它会让 fromWireName 落到 orElse 的
  /// remoteAudio，把「Fushi 互联发音源」悄悄降级成一个空的自定义远程源。
  static const String _legacyFushiRemoteWireName = 'hibikiRemote';

  static AudioSourceKind fromWireName(Object? value) {
    final String name = value?.toString() ?? '';
    if (name == _legacyFushiRemoteWireName) return AudioSourceKind.fushiRemote;
    return AudioSourceKind.values.firstWhere(
      (AudioSourceKind kind) => kind.wireName == name,
      orElse: () => AudioSourceKind.remoteAudio,
    );
  }
}

@immutable
class AudioSourceConfig {
  const AudioSourceConfig._({
    required this.kind,
    required this.enabled,
    this.label,
    this.url,
    this.path,
  });

  factory AudioSourceConfig.fushiRemote({bool enabled = false}) {
    // label 留空：显示名由 UI 用 i18n（audio_source_fushi_interconnect）解析，
    // 不把英文写死进持久化 JSON。
    return AudioSourceConfig._(
      kind: AudioSourceKind.fushiRemote,
      enabled: enabled,
    );
  }

  factory AudioSourceConfig.localAudio({
    required String label,
    required String path,
    bool enabled = false,
  }) {
    return AudioSourceConfig._(
      kind: AudioSourceKind.localAudio,
      enabled: enabled,
      label: label,
      path: path,
    );
  }

  factory AudioSourceConfig.remoteAudio({
    required String url,
    String? label,
    bool enabled = true,
  }) {
    return AudioSourceConfig._(
      kind: AudioSourceKind.remoteAudio,
      enabled: enabled,
      label: label,
      url: url,
    );
  }

  factory AudioSourceConfig.fromJson(Map<String, dynamic> json) {
    final AudioSourceKind kind = AudioSourceKind.fromWireName(json['kind']);
    final bool enabled =
        json['enabled'] is bool ? json['enabled'] as bool : true;
    final String? label = _nullableString(json['label']);
    switch (kind) {
      case AudioSourceKind.fushiRemote:
        return AudioSourceConfig.fushiRemote(enabled: enabled);
      case AudioSourceKind.localAudio:
        return AudioSourceConfig.localAudio(
          label: label ?? _nullableString(json['path']) ?? '',
          path: _nullableString(json['path']) ?? '',
          enabled: enabled,
        );
      case AudioSourceKind.remoteAudio:
        return AudioSourceConfig.remoteAudio(
          url: _nullableString(json['url']) ?? '',
          label: label,
          enabled: enabled,
        );
    }
  }

  final AudioSourceKind kind;
  final bool enabled;
  final String? label;
  final String? url;
  final String? path;

  String get displayLabel {
    switch (kind) {
      case AudioSourceKind.fushiRemote:
        return label ?? '';
      case AudioSourceKind.localAudio:
        return (label?.isNotEmpty ?? false) ? label! : (path ?? '');
      case AudioSourceKind.remoteAudio:
        return (label?.isNotEmpty ?? false) ? label! : (url ?? '');
    }
  }

  AudioSourceConfig copyWith({
    bool? enabled,
    String? label,
    String? url,
    String? path,
  }) {
    return AudioSourceConfig._(
      kind: kind,
      enabled: enabled ?? this.enabled,
      label: label ?? this.label,
      url: url ?? this.url,
      path: path ?? this.path,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'kind': kind.wireName,
      'enabled': enabled,
      if (label != null) 'label': label,
      if (url != null) 'url': url,
      if (path != null) 'path': path,
    };
  }

  /// 该 URL 是否指向本机回环地址（localhost / 127.0.0.1 / ::1 / 0.0.0.0）。这类
  /// remoteAudio 源在导出机器有效，换机导入后指向的是**新机自己**（通常没有对应
  /// 服务）→ 查词发音静默失败。UI 据此打「换机需重指」标记、导入侧据此记可见日志，
  /// 绝不静默失败（TODO-1171）。模板占位符先中性化，避免污染 host 解析。
  static bool isLoopbackAudioUrl(String? url) {
    if (url == null || url.isEmpty) return false;
    final String probe =
        url.replaceAll('{term}', 'x').replaceAll('{reading}', 'x');
    final String host = (Uri.tryParse(probe)?.host ?? '').toLowerCase();
    if (host.isNotEmpty) {
      return host == 'localhost' ||
          host == '127.0.0.1' ||
          host == '0.0.0.0' ||
          host == '::1';
    }
    // 无 scheme 的裸 host:port / 畸形 URL：退回子串探测。
    final String lower = probe.toLowerCase();
    return lower.contains('localhost') ||
        lower.contains('127.0.0.1') ||
        lower.contains('0.0.0.0') ||
        lower.contains('[::1]');
  }

  /// 本源是否是指向本机回环地址的远端音频源（跨机不可移植，需用户重指）。
  bool get pointsAtLoopbackHost =>
      kind == AudioSourceKind.remoteAudio && isLoopbackAudioUrl(url);

  static List<AudioSourceConfig> fromLegacyUrls(List<String> urls) {
    return urls
        .where((String url) => url.trim().isNotEmpty)
        .map((String url) => AudioSourceConfig.remoteAudio(url: url.trim()))
        .toList();
  }

  static String? _nullableString(Object? value) {
    if (value == null) return null;
    final String text = value.toString();
    return text.isEmpty ? null : text;
  }

  @override
  bool operator ==(Object other) {
    return other is AudioSourceConfig &&
        other.kind == kind &&
        other.enabled == enabled &&
        other.label == label &&
        other.url == url &&
        other.path == path;
  }

  @override
  int get hashCode => Object.hash(kind, enabled, label, url, path);

  @override
  String toString() => 'AudioSourceConfig(${toJson()})';
}
