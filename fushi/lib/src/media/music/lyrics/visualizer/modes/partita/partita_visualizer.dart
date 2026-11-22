/// 全屏歌词动画样式「partita」（移植自 folia-major `src/components/visualizer/partita/`）。
///
/// TODO(visualizer-port): 占位实现，等移植完成后替换。
library;

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_placeholder.dart';
import 'package:fushi/src/utils/fushi_icons.dart';

/// 注册项。
final LyricVisualizerEntry partitaVisualizerEntry = LyricVisualizerEntry(
  mode: LyricVisualizerMode.partita,
  label: () => t.music_visualizer_mode_partita,
  icon: FushiIcons.viewAgenda,
  sharedBackdrop: true,
  builder: (LyricVisualizerContext c) => LyricVisualizerPlaceholder(context: c),
);
