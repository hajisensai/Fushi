import 'dart:convert';

import 'package:fushi/src/media/video/video_horizontal_seek_gesture.dart';

class VideoAsbplayerConfig {
  const VideoAsbplayerConfig({
    required this.seekSeconds,
    required this.speedStep,
    required this.pauseAtSubtitleEnd,
    required this.doubleTapSeekSeconds,
    required this.longPressSpeed,
    required this.dragSeekSensitivity,
  });

  /// 双击「字幕跳句」哨兵值（TODO-173/BUG-231）：[doubleTapSeekSeconds] 取此值时，
  /// 双击左右区跳上/下一句（调 `_skipCueAndPokeControls`），而非相对 seek 秒数。
  /// 用单一离散字段（取值 `{kDoubleTapSubtitle, 0, 3, 5, 10}`）承载「关 / 秒数 /
  /// 字幕」三态——只一个特殊值、不引入第二个布尔，避免组合态。
  static const int kDoubleTapSubtitle = -1;

  /// 双击左右快进的合法取值集合（TODO-173）：0=关（保留原双击暂停/全屏，向后兼容，
  /// 默认）、3/5/10=相对 seek 该秒数、[kDoubleTapSubtitle]=字幕跳句。decode 用它兜底。
  static const List<int> doubleTapSeekOptions = <int>[
    kDoubleTapSubtitle,
    0,
    3,
    5,
    10,
  ];

  static const VideoAsbplayerConfig defaults = VideoAsbplayerConfig(
    seekSeconds: 3,
    speedStep: 0.1,
    pauseAtSubtitleEnd: false,
    doubleTapSeekSeconds: 0,
    longPressSpeed: 2.0,
    dragSeekSensitivity: VideoSeekSensitivity.medium,
  );

  final int seekSeconds;
  final double speedStep;
  final bool pauseAtSubtitleEnd;
  final double longPressSpeed;

  /// 移动端横滑拖动 seek 的灵敏度档位（BUG-1485）。语义是「拖过整屏 = 多长视频时间」，
  /// 与视频总时长解耦；换算模型见 [VideoHorizontalSeekGesture]。仅移动端消费（桌面
  /// 无横滑手势）。
  final VideoSeekSensitivity dragSeekSensitivity;

  /// 双击视频左/右区的行为（TODO-173/BUG-231）。见 [doubleTapSeekOptions] /
  /// [kDoubleTapSubtitle]。0=关（双击仍走平台默认的暂停/全屏，不分区）。
  final int doubleTapSeekSeconds;

  VideoAsbplayerConfig copyWith({
    int? seekSeconds,
    double? speedStep,
    bool? pauseAtSubtitleEnd,
    int? doubleTapSeekSeconds,
    double? longPressSpeed,
    VideoSeekSensitivity? dragSeekSensitivity,
  }) {
    return VideoAsbplayerConfig(
      seekSeconds: seekSeconds ?? this.seekSeconds,
      speedStep: speedStep ?? this.speedStep,
      pauseAtSubtitleEnd: pauseAtSubtitleEnd ?? this.pauseAtSubtitleEnd,
      doubleTapSeekSeconds: doubleTapSeekSeconds ?? this.doubleTapSeekSeconds,
      longPressSpeed: longPressSpeed ?? this.longPressSpeed,
      dragSeekSensitivity: dragSeekSensitivity ?? this.dragSeekSensitivity,
    );
  }

  Map<String, Object> toJson() => <String, Object>{
        'seekSeconds': seekSeconds,
        'speedStep': speedStep,
        'pauseAtSubtitleEnd': pauseAtSubtitleEnd,
        'doubleTapSeekSeconds': doubleTapSeekSeconds,
        'longPressSpeed': longPressSpeed,
        'dragSeekSensitivity': dragSeekSensitivity.name,
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
        doubleTapSeekSeconds: _readDoubleTap(raw['doubleTapSeekSeconds']),
        longPressSpeed:
            _readDouble(raw['longPressSpeed'], defaults.longPressSpeed)
                .clamp(1.0, 4.0)
                .toDouble(),
        dragSeekSensitivity: _readDragSeekSensitivity(
          raw['dragSeekSensitivity'],
        ),
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

  /// 双击行为：只接受 [doubleTapSeekOptions] 里的离散值，旧档/非法值兜底回默认
  /// （0=关），避免脏持久化值进入手势分流逻辑（TODO-173）。
  static int _readDoubleTap(Object? raw) {
    if (raw is num) {
      final int v = raw.round();
      if (doubleTapSeekOptions.contains(v)) return v;
    }
    return defaults.doubleTapSeekSeconds;
  }

  /// 横滑 seek 档位（BUG-1485）：只接受枚举 name 字符串（存 name 而非 index，改序不串
  /// 档）。旧档（无此键）/非法值回落默认档，不抛。
  static VideoSeekSensitivity _readDragSeekSensitivity(Object? raw) {
    if (raw is String) return VideoSeekSensitivity.fromName(raw);
    return defaults.dragSeekSensitivity;
  }
}
