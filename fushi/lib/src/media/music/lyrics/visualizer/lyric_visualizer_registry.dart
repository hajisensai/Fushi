/// 全屏歌词动画样式注册表：样式 → 注册项。加样式 = 枚举加值 + `modes/<样式>/` 一个目录 + 这里一行。
library;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/luminous/luminous_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/mindscape/mindscape_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/fume/fume_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/partita/partita_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/cappella/cappella_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/monet/monet_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/pendolo/pendolo_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/sonnet/sonnet_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tempera/tempera_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/lumiere/lumiere_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/nebbia/nebbia_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/tilt/tilt_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/still/still_visualizer.dart';

/// 全部样式（枚举顺序即选择面板顺序）。守卫测试核对与 [LyricVisualizerMode.values] 一一对应。
final Map<LyricVisualizerMode, LyricVisualizerEntry> lyricVisualizerRegistry =
    <LyricVisualizerMode, LyricVisualizerEntry>{
      LyricVisualizerMode.luminous: luminousVisualizerEntry,
      LyricVisualizerMode.mindscape: mindscapeVisualizerEntry,
      LyricVisualizerMode.fume: fumeVisualizerEntry,
      LyricVisualizerMode.partita: partitaVisualizerEntry,
      LyricVisualizerMode.cappella: cappellaVisualizerEntry,
      LyricVisualizerMode.claddagh: claddaghVisualizerEntry,
      LyricVisualizerMode.monet: monetVisualizerEntry,
      LyricVisualizerMode.diorama: dioramaVisualizerEntry,
      LyricVisualizerMode.pendolo: pendoloVisualizerEntry,
      LyricVisualizerMode.sonnet: sonnetVisualizerEntry,
      LyricVisualizerMode.tempera: temperaVisualizerEntry,
      LyricVisualizerMode.lumiere: lumiereVisualizerEntry,
      LyricVisualizerMode.nebbia: nebbiaVisualizerEntry,
      LyricVisualizerMode.metaphor: metaphorVisualizerEntry,
      LyricVisualizerMode.hanabi: hanabiVisualizerEntry,
      LyricVisualizerMode.machi: machiVisualizerEntry,
      LyricVisualizerMode.tilt: tiltVisualizerEntry,
      LyricVisualizerMode.still: stillVisualizerEntry,
    };

/// 取注册项（枚举全覆盖，恒有值）。
LyricVisualizerEntry lyricVisualizerEntryOf(LyricVisualizerMode mode) =>
    lyricVisualizerRegistry[mode]!;
