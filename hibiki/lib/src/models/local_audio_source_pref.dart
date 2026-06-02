import 'package:flutter/foundation.dart';

/// 本地音频库内单个子来源（如 nhk16 / forvo）的偏好：名字 + 是否启用。
///
/// 一个本地音频库（Yomitan Local Audio SQLite）的 `entries.source` 列可有多个
/// distinct 值；当一个词在多来源下都有音频时，按用户配置的优先级序选第一个启用的。
/// 持久化在 [LocalAudioDbEntry.sources]（按优先级排序，首=最高）。
@immutable
class LocalAudioSourcePref {
  const LocalAudioSourcePref({required this.name, this.enabled = true});

  factory LocalAudioSourcePref.fromJson(Map<String, dynamic> json) =>
      LocalAudioSourcePref(
        name: json['name'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
      );

  final String name;
  final bool enabled;

  LocalAudioSourcePref copyWith({bool? enabled}) =>
      LocalAudioSourcePref(name: name, enabled: enabled ?? this.enabled);

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'name': name, 'enabled': enabled};

  @override
  bool operator ==(Object other) =>
      other is LocalAudioSourcePref &&
      other.name == name &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(name, enabled);

  @override
  String toString() => 'LocalAudioSourcePref(name: $name, enabled: $enabled)';
}
