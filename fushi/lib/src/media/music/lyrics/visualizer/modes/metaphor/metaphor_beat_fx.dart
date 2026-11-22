/// 隐喻的「湮灭对撞」节拍特效（移植 folia `metaphor/metaphorBeatFx.ts`）：对撞跟着节拍表走。
/// - 对撞的时刻挪到拍上：附近有小节第一拍就挪到那一拍，没有就挪到最近的一拍，都够不着的不动。两颗
///   墨球是提前出发的（[metaphorCollisionApproach]），所以正好在拍上撞，不是听到拍才动。
/// - 平常的每一拍，离它最近的那个对撞点放出一圈小的冲击环；拍越重环越大，没有节奏的小节不放。
/// 都是纯函数：只看节拍表和播放时间，拖进度、暂停都对。没有节拍网格（还没分析完 / 歌词回落）或强度
/// 为 0 时调用方不走这里，画面和原来一样。时间单位是秒（歌词显示时间）。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/metaphor/metaphor_shapes.dart';

/// 一拍（folia `BeatFxEvent` 里这里用得到的那几项）。
class MetaphorBeatEvent {
  const MetaphorBeatEvent({
    required this.t,
    required this.downbeat,
    required this.gain,
  });

  /// 歌词显示时间，秒。
  final double t;
  final bool downbeat;

  /// 这一拍放多大（folia `resolveBeatFxAccentGain`）；0 = 没有节奏的小节里的拍，不放效果。
  final double gain;

  bool get rhythmic => gain > 0;
}

/// folia `BEAT_FX_WEAK_BEAT_FLOOR`：弱拍也至少这么高。
const double _weakBeatFloor = 0.35;

/// 离小节第一拍多近才挪过去（秒）。
const double _snapDownbeat = 0.9;

/// 离普通的一拍多近才挪过去（秒）。
const double _snapBeat = 0.3;

/// 两次对撞挪完以后至少隔这么久，不然后一次不挪。
const double _snapApart = 0.4;

/// 一圈拍上的小环活多久。
const double metaphorBeatRingLife = 2.2;

/// 强度拉满时最多按几倍算。
const double _strengthMax = 2;

/// 音频分析 → 节拍表（显示时间，秒）。每拍的重音从该拍那一刻的 `accentImpact` 读（正好在拍上时
/// 就是这一拍的峰值）；没有重音数据时每拍都按 1 算。没有节拍网格返回空表。
List<MetaphorBeatEvent> metaphorBeatEventsOf(LyricVisualizerContext c) {
  final LyricVisualizerAudio? audio = c.audio;
  if (audio == null || !audio.beatsReady) return const <MetaphorBeatEvent>[];
  final Set<int> downbeats = audio.downbeatTimesMs.toSet();
  final List<MetaphorBeatEvent> out = <MetaphorBeatEvent>[];
  for (final int ms in audio.beatTimesMs) {
    final double? accent = audio.frameAt(ms).accentImpact;
    final double gain = accent == null
        ? 1
        : accent <= 1e-3
        ? 0
        : _weakBeatFloor + (1 - _weakBeatFloor) * accent.clamp(0.0, 1.0);
    out.add(
      MetaphorBeatEvent(
        t: c.displayTimeOfAudio(ms) / 1000,
        downbeat: downbeats.contains(ms),
        gain: gain,
      ),
    );
  }
  return out;
}

/// 第一个时刻不早于 [time] 的拍在第几个。
int _firstAtOrAfter(List<MetaphorBeatEvent> events, double time) {
  int low = 0;
  int high = events.length;
  while (low < high) {
    final int mid = (low + high) >> 1;
    if (events[mid].t < time) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

/// [time] 附近 [reach] 秒以内最近的一拍（[downbeat] 时只看小节第一拍）；没节奏的拍不算。
double? _nearestBeat(
  List<MetaphorBeatEvent> events,
  double time,
  double reach,
  bool downbeat,
) {
  double? best;
  for (
    int i = _firstAtOrAfter(events, time - reach);
    i < events.length && events[i].t <= time + reach;
    i++
  ) {
    final MetaphorBeatEvent e = events[i];
    if (!e.rhythmic || (downbeat && !e.downbeat)) continue;
    if (best == null || (e.t - time).abs() < (best - time).abs()) best = e.t;
  }
  return best;
}

/// 把一个 cue 的对撞挪到拍上（挪不动的原样）。[earliest] 是最早能撞的时刻（cue 开始：不挪到上一句里）。
/// 循环的 cue（时间会折回去）不要调这个。
List<MetaphorCollision> snapMetaphorCollisions(
  List<MetaphorCollision> collisions,
  List<MetaphorBeatEvent> events, {
  double earliest = double.negativeInfinity,
}) {
  if (events.isEmpty) return List<MetaphorCollision>.of(collisions);
  final List<double> taken = <double>[];
  bool free(double? time) =>
      time != null &&
      time >= earliest &&
      taken.every((double other) => (other - time).abs() >= _snapApart);
  return <MetaphorCollision>[
    for (final MetaphorCollision hit in collisions)
      () {
        final double? bar = _nearestBeat(events, hit.time, _snapDownbeat, true);
        final double? beat = _nearestBeat(events, hit.time, _snapBeat, false);
        final double time = free(bar)
            ? bar!
            : free(beat)
            ? beat!
            : hit.time;
        taken.add(time);
        return time == hit.time
            ? hit
            : MetaphorCollision(
                time: time,
                x: hit.x,
                y: hit.y,
                angle: hit.angle,
                unit: hit.unit,
                fragments: hit.fragments,
              );
      }(),
  ];
}

/// 把拍上的小环在 [time]（歌里的秒）这一刻的样子写进 [out]。[shift] 是 cue 里的时间减去歌里的秒；
/// [strength] 是效果强度（0..2，1 是调好的样子）。
void writeMetaphorBeatRings(
  List<MetaphorCollision> collisions,
  List<MetaphorBeatEvent> events,
  double time,
  double shift,
  double strength,
  MetaphorInstances out,
) {
  if (collisions.isEmpty || strength <= 0) return;
  final double scale = math.min(_strengthMax, strength);
  for (
    int i = _firstAtOrAfter(events, time - metaphorBeatRingLife);
    i < events.length && events[i].t <= time;
    i++
  ) {
    final MetaphorBeatEvent e = events[i];
    if (e.gain <= 0) continue;
    // 这一拍归哪个对撞点：墨球正飞过去的，或者刚撞完碎片还没散的，挑时刻最近的
    final double at = e.t + shift;
    MetaphorCollision? site;
    for (final MetaphorCollision hit in collisions) {
      final double since = at - hit.time;
      if (since < -metaphorCollisionApproach ||
          since >= metaphorCollisionLife) {
        continue;
      }
      if (site == null || since.abs() < (at - site.time).abs()) site = hit;
    }
    // 正好是撞上的那一拍：那一下自己有一圈大的
    if (site == null || (at - site.time).abs() < 0.05) continue;
    final double age = time - e.t;
    final double fade = 1 - age / metaphorBeatRingLife;
    final double reach = (e.downbeat ? 1.5 : 1) * (0.5 + 0.9 * e.gain) * scale;
    final double radius =
        site.unit * (0.16 + reach * (1 - math.exp(-age * 1.1)));
    // 刚放出来的一小会儿是墨线，之后只剩越来越淡的网点
    out.put(
      metaphorShapeRing,
      site.x,
      site.y,
      radius,
      radius,
      0,
      age < 0.25 ? 1 : 0,
      fade,
      0,
    );
  }
}
