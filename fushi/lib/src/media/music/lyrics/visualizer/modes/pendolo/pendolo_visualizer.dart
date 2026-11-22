/// 全屏歌词动画样式「pendolo」（移植自 folia-major `src/components/visualizer/pendolo/`）。
///
/// TODO(visualizer-port): 占位实现，等移植完成后替换。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_placeholder.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 注册项。
final LyricVisualizerEntry pendoloVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.pendolo,
  label: () => t.music_visualizer_mode_pendolo,
  icon: FushiIcons.timer,
  sharedBackdrop: true,
  builder: (LyricVisualizerContext c) => LyricVisualizerPlaceholder(context: c),
);
