import 'dart:convert';

class VideoAsbplayerConfig {
  const VideoAsbplayerConfig({
    required this.seekSeconds,
    required this.speedStep,
    required this.pauseAtSubtitleEnd,
  });

  static const VideoAsbplayerConfig defaults = VideoAsbplayerConfig(
    seekSeconds: 3,
    speedStep: 0.1,
    pauseAtSubtitleEnd: false,
  );

  final int seekSeconds;
  final double speedStep;
  final bool pauseAtSubtitleEnd;

  VideoAsbplayerConfig copyWith({
    int? seekSeconds,
    double? speedStep,
    bool? pauseAtSubtitleEnd,
  }) {
    return VideoAsbplayerConfig(
      seekSeconds: seekSeconds ?? this.seekSeconds,
      speedStep: speedStep ?? this.speedStep,
      pauseAtSubtitleEnd: pauseAtSubtitleEnd ?? this.pauseAtSubtitleEnd,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
        'seekSeconds': seekSeconds,
        'speedStep': speedStep,
        'pauseAtSubtitleEnd': pauseAtSubtitleEnd,
      };

  static String encode(VideoAsbplayerConfig config) =>
      jsonEncode(config.toJson());

  static VideoAsbplayerConfig decode(String json) {
    if (json.trim().isEmpty) return defaults;
    try {
      final Object? raw = jsonDecode(json);
      if (raw is! Map<String, dynamic>) return defaults;
      return VideoAsbplayerConfig(
        seekSeconds:
            _readInt(raw['seekSeconds'], defaults.seekSeconds).clamp(1, 30),
        speedStep: _readDouble(raw['speedStep'], defaults.speedStep)
            .clamp(0.05, 0.5)
            .toDouble(),
        pauseAtSubtitleEnd:
            raw['pauseAtSubtitleEnd'] as bool? ?? defaults.pauseAtSubtitleEnd,
      );
    } catch (_) {
      return defaults;
    }
  }

  static int _readInt(Object? raw, int fallback) {
    if (raw is num) return raw.round();
    return fallback;
  }

  static double _readDouble(Object? raw, double fallback) {
    if (raw is num) return raw.toDouble();
    return fallback;
  }
}
