/// 一条已登记的本地音频来源（从 app 的 local_audio_manager.dart 抽出：互联 host
/// 列/导出本地音频包要用它，而 manager 拖着偏好仓储与 TTS 通道）。
library;

import 'package:fushi_engine/models/local_audio_source_pref.dart';

class LocalAudioDbEntry {
  const LocalAudioDbEntry({
    required this.path,
    required this.displayName,
    this.enabled = false,
    this.sources = const <LocalAudioSourcePref>[],
  });

  factory LocalAudioDbEntry.fromJson(Map<String, dynamic> json) =>
      LocalAudioDbEntry(
        path: json['path'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        enabled: json['enabled'] as bool? ?? true,
        sources: (json['sources'] as List<dynamic>?)
                ?.map((dynamic e) =>
                    LocalAudioSourcePref.fromJson(e as Map<String, dynamic>))
                .toList() ??
            const <LocalAudioSourcePref>[],
      );

  final String path;
  final String displayName;
  final bool enabled;

  /// 库内子来源偏好（优先级序，首=最高）。空=未配置 → 查询退回 DB 自然序、全启用。
  final List<LocalAudioSourcePref> sources;

  LocalAudioDbEntry copyWith({
    String? displayName,
    bool? enabled,
    List<LocalAudioSourcePref>? sources,
  }) =>
      LocalAudioDbEntry(
        path: path,
        displayName: displayName ?? this.displayName,
        enabled: enabled ?? this.enabled,
        sources: sources ?? this.sources,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'displayName': displayName,
        'enabled': enabled,
        if (sources.isNotEmpty)
          'sources':
              sources.map((LocalAudioSourcePref s) => s.toJson()).toList(),
      };
}
