/// 花火的两个节拍特效（移植 folia `hanabi/hanabiBeatFx.ts`，纯数据与包络运算）：
/// - 随拍开花：按整张节拍表，每拍在夜空上半部开一朵小烟花；小节第一拍提前升空、正好在拍上开一朵大的。
///   重音强的拍开得更大，没有节奏的小节不开。哪一拍在哪开、开多大只由拍的时刻与种子决定，画面仍然只由
///   时间决定，拖进度、暂停都对。
/// - 随拍推镜：拍 / 重拍包络让整个画面每拍推近一下、左右交替轻轻一摆，小节第一拍推得更深。
/// 没有节拍网格（还没分析完 / 没有音频分析）时什么都不做，画面与原来一样。时间单位是秒（歌词显示时间）。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_catalog.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/hanabi/hanabi_math.dart';

/// 一拍（folia `BeatFxEvent` 里用得到的那几项）。
class HanabiBeatEvent {
  const HanabiBeatEvent({
    required this.t,
    required this.downbeat,
    required this.gain,
  });

  /// 歌词显示时间，秒。
  final double t;
  final bool downbeat;

  /// folia `resolveBeatFxAccentGain`：0 = 没有节奏的小节里的拍。
  final double gain;
}

const double _weakBeatFloor = 0.35;

/// 音频分析 → 节拍表（显示时间，秒）。每拍的重音读该拍那一刻的 `accentImpact`（正好在拍上时就是这一拍
/// 的峰值）；没有重音数据时每拍按 1 算。没有节拍网格返回空表。
List<HanabiBeatEvent> hanabiBeatEventsOf(LyricVisualizerContext c) {
  final LyricVisualizerAudio? audio = c.audio;
  if (audio == null || !audio.beatsReady) return const <HanabiBeatEvent>[];
  final Set<int> downbeats = audio.downbeatTimesMs.toSet();
  return <HanabiBeatEvent>[
    for (final int ms in audio.beatTimesMs)
      () {
        final double? accent = audio.frameAt(ms).accentImpact;
        return HanabiBeatEvent(
          t: c.displayTimeOfAudio(ms) / 1000,
          downbeat: downbeats.contains(ms),
          gain: accent == null
              ? 1
              : accent <= 1e-3
              ? 0
              : _weakBeatFloor + (1 - _weakBeatFloor) * accent.clamp(0.0, 1.0),
        );
      }(),
  ];
}

/// 一拍的烟花（画面坐标按比例给，场景再换算进那时所在的镜头）。
class HanabiBeatShell {
  const HanabiBeatShell({
    required this.t,
    required this.downbeat,
    required this.sx,
    required this.sy,
    required this.spec,
    required this.launch,
    required this.seed,
  });

  final double t;
  final bool downbeat;

  /// 开花的位置（画面宽 / 高的比例）。
  final double sx;
  final double sy;
  final BurstSpec spec;

  /// 小节第一拍从画面底边升空，到达时刻 = [t]。
  final bool launch;
  final String seed;
}

/// 一拍的烟花从开花到熄灭最多多久（秒）。
const double kHanabiBeatShellLife = 1.8;

const List<BurstKind> _beatKinds = <BurstKind>[
  BurstKind.botan,
  BurstKind.senrin,
  BurstKind.strobe,
  BurstKind.star,
  BurstKind.heart,
  BurstKind.ring,
];
const List<BurstKind> _downbeatKinds = <BurstKind>[
  BurstKind.kiku,
  BurstKind.ring,
  BurstKind.willowRing,
  BurstKind.crossette,
  BurstKind.palm,
];

/// 一拍的烟花；没有节奏的小节（gain 为 0）或强度 0 返回 null。[strength] 是效果强度 0..2（1 是调好的样子）：
/// 粒子数与半径都跟着它，重音只改半径。
HanabiBeatShell? resolveHanabiBeatShell(
  HanabiBeatEvent event,
  String seed,
  double strength,
) {
  if (event.gain <= 0 || strength <= 0) return null;
  final String key = '$seed:beat:${(event.t * 1000).round()}';
  final HanabiRng random = hanabiRng(key);
  final bool downbeat = event.downbeat;
  final List<BurstKind> kinds = downbeat ? _downbeatKinds : _beatKinds;
  final BurstKind kind = kinds[(random() * kinds.length).floor()];
  final List<int> colors = <int>[
    for (int k = 0; k < 3; k++) (k + (random() * 5).floor()) % 5,
  ];
  final double size = (0.55 + 0.45 * event.gain) * (0.7 + 0.3 * strength);
  final BurstSpec base = burstPreset(kind, colors);
  final BurstSpec spec = downbeat
      ? base.copyWith(
          count: (80 * (0.5 + 0.5 * strength)).round(),
          radius: 0.2 * size,
          duration: 1.7,
        )
      : base.copyWith(
          count: (28 * (0.5 + 0.5 * strength)).round(),
          radius: 0.09 * size,
          duration: 1.1,
          trail: 0.25,
        );
  // 小烟花散在夜空上半部与两侧，大的开在上方中间一带。
  final double sx = downbeat ? 0.2 + random() * 0.6 : 0.06 + random() * 0.88;
  final double sy = downbeat ? 0.12 + random() * 0.2 : 0.07 + random() * 0.36;
  return HanabiBeatShell(
    t: event.t,
    downbeat: downbeat,
    sx: sx,
    sy: sy,
    spec: spec,
    launch: downbeat,
    seed: key,
  );
}

/// [events]（按时刻排好）里第一个 t ≥ [time] 的下标。
int firstHanabiBeatAtOrAfter(List<HanabiBeatEvent> events, double time) {
  int low = 0;
  int high = events.length;
  while (low < high) {
    final int middle = (low + high) >> 1;
    if (events[middle].t < time) {
      low = middle + 1;
    } else {
      high = middle;
    }
  }
  return low;
}

/// 每拍推近的比例、重拍额外推近的比例、每拍左右摆的角度（度）（强度 1 时）。
const double _pulseZoom = 0.035;
const double _pulseDownbeatZoom = 0.045;
const double _pulseKickDeg = 1.6;

/// 一帧的推镜：[k] / [d] 是这个效果强度下的拍 / 重拍包络（0..2），[sign] 每拍换边。
({double scale, double rotation}) resolveHanabiBeatPulse(
  double k,
  double d,
  double sign,
) => (
  scale: 1 + _pulseZoom * math.max(0, k) + _pulseDownbeatZoom * math.max(0, d),
  rotation: (_pulseKickDeg * math.pi / 180) * math.max(0, k) * sign,
);

/// 这一帧的推镜（[strength] 0 = 关；没有节拍网格时不推）。包络用音频帧的拍 / 重拍冲击（有重音时拍按重音），
/// 摆的方向每拍换一次边。
({double scale, double rotation}) hanabiBeatPulseAt(
  LyricVisualizerContext c,
  int displayMs,
  double strength,
) {
  final LyricVisualizerAudio? audio = c.audio;
  if (strength <= 0 || audio == null || !audio.beatsReady) {
    return (scale: 1, rotation: 0);
  }
  final LyricVisualizerAudioFrame f = c.audioFrameAt(displayMs);
  final int beat = lyricVisualizerLastAtOrBefore(
    audio.beatTimesMs,
    c.audioTimeOf(displayMs),
  );
  return resolveHanabiBeatPulse(
    f.accentOrBeat * strength,
    f.downbeatImpact * strength,
    beat.isEven ? 1 : -1,
  );
}
