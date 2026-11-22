/// 移植自 folia `backgrounds/registry.tsx` 的背景（顺序同 folia `order`：通用 10、莫奈 20、漫游 30、
/// 隐现 35、嵌入 40、空 50）。框架的 `lyricVisualizerBackgrounds` 把它们接在「歌词页背景 / 纯色」后面。
library;

import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/monet_background.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_background.dart';

final List<LyricVisualizerBackgroundEntry> lyricVisualizerPortedBackgrounds =
    <LyricVisualizerBackgroundEntry>[monetBackgroundEntry];
