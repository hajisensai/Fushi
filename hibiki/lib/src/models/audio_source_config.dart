import 'package:flutter/foundation.dart';

enum AudioSourceKind {
  hibikiRemote('hibikiRemote'),
  localAudio('localAudio'),
  remoteAudio('remoteAudio');

  const AudioSourceKind(this.wireName);

  final String wireName;

  static AudioSourceKind fromWireName(Object? value) {
    final String name = value?.toString() ?? '';
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

  factory AudioSourceConfig.hibikiRemote({bool enabled = false}) {
    return AudioSourceConfig._(
      kind: AudioSourceKind.hibikiRemote,
      enabled: enabled,
      label: 'Hibiki Remote',
    );
  }

  factory AudioSourceConfig.localAudio({
    required String label,
    required String path,
    bool enabled = true,
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
      case AudioSourceKind.hibikiRemote:
        return AudioSourceConfig.hibikiRemote(enabled: enabled);
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
      case AudioSourceKind.hibikiRemote:
        return label ?? 'Hibiki Remote';
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
