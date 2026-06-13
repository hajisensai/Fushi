import 'package:flutter/foundation.dart';

const int kVideoDanmakuLocalMaxBytes = 20 * 1024 * 1024;
const int kDefaultVideoDanmakuMaxActive = 80;
const int kMaxVideoDanmakuActive = 200;
const int kDefaultVideoDanmakuMaxLanes = 12;
const Duration kDefaultVideoDanmakuScrollDuration = Duration(seconds: 8);
const Duration kDefaultVideoDanmakuFixedDuration = Duration(seconds: 4);

enum VideoDanmakuMode { scroll, top, bottom }

@immutable
class VideoDanmakuItem {
  const VideoDanmakuItem({
    required this.startMs,
    required this.text,
    required this.mode,
    required this.colorArgb,
  });

  final int startMs;
  final String text;
  final VideoDanmakuMode mode;
  final int colorArgb;

  VideoDanmakuItem copyWith({
    int? startMs,
    String? text,
    VideoDanmakuMode? mode,
    int? colorArgb,
  }) {
    return VideoDanmakuItem(
      startMs: startMs ?? this.startMs,
      text: text ?? this.text,
      mode: mode ?? this.mode,
      colorArgb: colorArgb ?? this.colorArgb,
    );
  }
}

@immutable
class VideoDanmakuLoadResult {
  const VideoDanmakuLoadResult({
    required this.items,
    required this.sourcePath,
    this.tooLarge = false,
    this.error,
  });

  final List<VideoDanmakuItem> items;
  final String sourcePath;
  final bool tooLarge;
  final Object? error;
}

int normalizeVideoDanmakuMaxActive(int value) =>
    value.clamp(1, kMaxVideoDanmakuActive).toInt();
