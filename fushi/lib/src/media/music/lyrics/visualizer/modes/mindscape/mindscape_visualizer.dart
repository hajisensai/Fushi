/// 全屏歌词动画样式「mindscape」（移植自 folia-major `src/components/visualizer/cadenza/`）。
///
/// TODO(visualizer-port): 占位实现，等移植完成后替换。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_placeholder.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 注册项。
final LyricVisualizerEntry mindscapeVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.mindscape,
  label: () => t.music_visualizer_mode_mindscape,
  icon: FushiIcons.hub,
  sharedBackdrop: true,
  builder: (LyricVisualizerContext c) => LyricVisualizerPlaceholder(context: c),
);
