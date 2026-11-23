/// 全屏歌词动画的共享拍点 / 鼓击事件（移植 folia `services/beatFx/clock.ts`）。
///
/// 样式要「每拍做一件事」（开一朵花、生一圈波纹、推一下镜头）时，不要自己从
/// `LyricVisualizerAudio.beatTimesMs` + `frameAt(beat).accentImpact` 推增益：用
/// [LyricVisualizerBeats.of] 拿这一首的拍点事件表，它按 folia 的规则做好了：
///
/// - 合并（`mergeBeatFxEvents`）：强拍替换它所在的那一拍；有重音数据时去掉不是听感拍（`pulse = false`）的拍，
///   每拍带重音、音色、小节内位置；模型给的孤立强拍也留下。
/// - 增益（`resolveBeatFxAccentGain`）：没有节奏的小节为 0；有重音时 `(0.35 + 0.65 × impact) × trackScale`；
///   没有重音时为 trackScale（旧结果为 1）。
/// - 包络（`stepBeatFxClock`）：拍 / 强拍冲击 = 最近几拍 `gain × exp(-dt / decay × 2.3)` 的最大值，
///   衰减 160 / 200 ms；摆向每拍换一次边。
///
/// 时间：事件同时带音频时间与歌词显示时间（按建表时的 `offsetMs` 换算），窗口查询一律用显示时间。
///
/// 没有节拍网格（没分析 / 还没分析完）时事件表为空——folia 拍点特效在没有拍表时不触发，离散特效照此
/// 什么都不做；连续包络（[LyricVisualizerBeats.beatImpactAt] 等）则回落到歌词起字包络，与
/// `LyricVisualizerContext.audioFrameAt` 的回落一致（[LyricVisualizerBeats.fromLyrics] 为 true）。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

/// folia `BEAT_FX_WEAK_BEAT_FLOOR`：弱拍也至少冲到这么高。
const double kLyricVisualizerWeakBeatFloor = 0.35;

/// folia `BEAT_FX_BEAT_DECAY_MS`。
const int kLyricVisualizerBeatFxDecayMs = 160;

/// folia `BEAT_FX_DOWNBEAT_DECAY_MS`。
const int kLyricVisualizerDownbeatFxDecayMs = 200;

/// folia `resolveBeatFxAccentGain`：一拍的包络峰值，也是离散特效（每拍一圈波纹）按它缩放。
/// [rhythmic] false（没有节奏的小节）为 0；没有重音（[impact] 为 null）时为 [trackScale]。
double lyricVisualizerBeatAccentGain({
  required double? impact,
  required bool rhythmic,
  required double trackScale,
}) {
  if (!rhythmic) return 0;
  if (impact == null) return trackScale;
  return (kLyricVisualizerWeakBeatFloor +
          (1 - kLyricVisualizerWeakBeatFloor) * impact.clamp(0.0, 1.0)) *
      trackScale;
}

/// 一个拍点事件（folia `BeatFxEvent`）。
@immutable
class LyricVisualizerBeatEvent {
  const LyricVisualizerBeatEvent({
    required this.audioMs,
    required this.displayMs,
    required this.downbeat,
    required this.gain,
    required this.ordinal,
    this.impact,
    this.lowShare = 1 / 3,
    this.midShare = 1 / 3,
    this.highShare = 1 / 3,
    this.rhythmic = true,
    this.barPos,
  });

  /// 音频时间（毫秒）。
  final int audioMs;

  /// 歌词显示时间（毫秒）。
  final int displayMs;

  /// 显示时间，秒（folia 的时间单位）。
  double get seconds => displayMs / 1000;

  /// 强拍（folia `kind == 'downbeat'`）。
  final bool downbeat;

  /// 包络峰值 / 离散特效的缩放（[lyricVisualizerBeatAccentGain]）。0 = 不打。
  final double gain;

  /// 在事件表里的序号（摆向等按它交替）。
  final int ordinal;

  /// 重音 0–1；null = 没有重音数据。
  final double? impact;

  /// 音色：这一拍突起里低 / 中 / 高频的占比（folia `tone`；没有重音数据时各 1/3）。
  final double lowShare;
  final double midShare;
  final double highShare;

  /// 有节奏（false 时 [gain] 为 0）。
  final bool rhythmic;

  /// 离上一个强拍几拍（0 = 强拍本身）；第一个强拍之前、或没有重音数据时为 null（folia `barPos`）。
  final int? barPos;

  /// 有重音数据。
  bool get hasAccents => impact != null;

  /// folia `stepBeatFxClock` 每触发一拍把 `rotationSign` 翻一次（初值 1）：第 [ordinal] 拍触发后的摆向。
  double get rotationSign => ordinal.isEven ? -1 : 1;

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerBeatEvent &&
      other.audioMs == audioMs &&
      other.displayMs == displayMs &&
      other.downbeat == downbeat &&
      other.gain == gain &&
      other.ordinal == ordinal &&
      other.impact == impact &&
      other.lowShare == lowShare &&
      other.midShare == midShare &&
      other.highShare == highShare &&
      other.rhythmic == rhythmic &&
      other.barPos == barPos;

  @override
  int get hashCode => Object.hash(
    audioMs,
    displayMs,
    downbeat,
    gain,
    ordinal,
    impact,
    lowShare,
    midShare,
    highShare,
    rhythmic,
    barPos,
  );

  @override
  String toString() =>
      'LyricVisualizerBeatEvent(#$ordinal @$displayMs, downbeat: $downbeat, '
      'gain: $gain, impact: $impact, barPos: $barPos)';
}

/// 一下鼓击（显示时间已换算好）。
@immutable
class LyricVisualizerDrumHitEvent {
  const LyricVisualizerDrumHitEvent({
    required this.audioMs,
    required this.displayMs,
    required this.kind,
    required this.strength,
  });

  final int audioMs;
  final int displayMs;
  final LyricVisualizerDrumKind kind;

  /// 力度 0–1。
  final double strength;

  double get seconds => displayMs / 1000;

  @override
  bool operator ==(Object other) =>
      other is LyricVisualizerDrumHitEvent &&
      other.audioMs == audioMs &&
      other.displayMs == displayMs &&
      other.kind == kind &&
      other.strength == strength;

  @override
  int get hashCode => Object.hash(audioMs, displayMs, kind, strength);
}

/// 按 folia `mergeBeatFxEvents` 合并拍与强拍（音频时间），算好增益与小节位置。纯函数，测试直接调。
List<LyricVisualizerBeatEvent> lyricVisualizerMergeBeatEvents({
  required List<LyricVisualizerBeat> beats,
  required List<int> downbeatTimesMs,
  required double trackScale,
  int offsetMs = 0,
}) {
  final bool accents = beats.any((LyricVisualizerBeat b) => b.hasAccents);
  // 复合拍子：只留听感拍（folia：有重音时 pulse 为 0 的拍不进表）。
  final List<LyricVisualizerBeat> kept = accents
      ? beats.where((LyricVisualizerBeat b) => b.pulse).toList()
      : beats;
  final Set<int> allTimes = <int>{
    for (final LyricVisualizerBeat b in beats) b.timeMs,
  };
  final Set<int> downSet = downbeatTimesMs.toSet();
  final List<({int t, bool down, LyricVisualizerBeat? beat})> raw =
      <({int t, bool down, LyricVisualizerBeat? beat})>[
        for (final LyricVisualizerBeat b in kept)
          (t: b.timeMs, down: downSet.contains(b.timeMs), beat: b),
        // 模型把强拍都对在拍上，但不在任何一拍上的强拍也留下（被听感过滤掉的那拍不算孤立）。
        for (final int d in downbeatTimesMs)
          if (!allTimes.contains(d)) (t: d, down: true, beat: null),
      ]..sort(
        (
          ({int t, bool down, LyricVisualizerBeat? beat}) a,
          ({int t, bool down, LyricVisualizerBeat? beat}) b,
        ) => a.t.compareTo(b.t),
      );
  final List<LyricVisualizerBeatEvent> out = <LyricVisualizerBeatEvent>[];
  int? barPos;
  for (int i = 0; i < raw.length; i++) {
    final ({int t, bool down, LyricVisualizerBeat? beat}) e = raw[i];
    final LyricVisualizerBeat? b = e.beat;
    if (accents) {
      barPos = e.down ? 0 : (barPos == null ? null : barPos + 1);
    }
    final double? impact = b?.impact;
    final bool rhythmic = b?.rhythmic ?? true;
    out.add(
      LyricVisualizerBeatEvent(
        audioMs: e.t,
        displayMs: e.t + offsetMs,
        downbeat: e.down,
        gain: lyricVisualizerBeatAccentGain(
          impact: impact,
          rhythmic: rhythmic,
          trackScale: trackScale,
        ),
        ordinal: i,
        impact: impact,
        lowShare: b?.lowShare ?? 1 / 3,
        midShare: b?.midShare ?? 1 / 3,
        highShare: b?.highShare ?? 1 / 3,
        rhythmic: rhythmic,
        barPos: accents ? barPos : null,
      ),
    );
  }
  return List<LyricVisualizerBeatEvent>.unmodifiable(out);
}

/// 一首歌的拍点 / 鼓击事件表（显示时间）。用 [LyricVisualizerBeats.of] 取（按音频对象 + 偏移缓存）。
class LyricVisualizerBeats {
  LyricVisualizerBeats._({
    required this.events,
    required this.drumHits,
    required this.vocalOnsetsMs,
    required this.trackScale,
    required this.hasAccents,
    required this.drumsReady,
    required this.offsetMs,
    required LyricVisualizerRuntime runtime,
  }) : _runtime = runtime,
       _eventTimes = <int>[
         for (final LyricVisualizerBeatEvent e in events) e.displayMs,
       ],
       _downbeats = <LyricVisualizerBeatEvent>[
         for (final LyricVisualizerBeatEvent e in events)
           if (e.downbeat) e,
       ],
       _downbeatTimes = <int>[
         for (final LyricVisualizerBeatEvent e in events)
           if (e.downbeat) e.displayMs,
       ],
       _hitTimes = <int>[
         for (final LyricVisualizerDrumHitEvent h in drumHits) h.displayMs,
       ];

  /// 直接从数据建表（测试 / 样式离屏预演用；样式一般用 [of]）。
  factory LyricVisualizerBeats.build({
    required LyricVisualizerAudio? audio,
    required LyricVisualizerRuntime runtime,
    required int offsetMs,
  }) {
    final LyricVisualizerAudio? a = audio;
    if (a == null) {
      return LyricVisualizerBeats._(
        events: const <LyricVisualizerBeatEvent>[],
        drumHits: const <LyricVisualizerDrumHitEvent>[],
        vocalOnsetsMs: const <int>[],
        trackScale: 1,
        hasAccents: false,
        drumsReady: false,
        offsetMs: offsetMs,
        runtime: runtime,
      );
    }
    return LyricVisualizerBeats._(
      events: a.beatsReady
          ? lyricVisualizerMergeBeatEvents(
              beats: a.beats,
              downbeatTimesMs: a.downbeatTimesMs,
              trackScale: a.trackScale,
              offsetMs: offsetMs,
            )
          : const <LyricVisualizerBeatEvent>[],
      drumHits: List<LyricVisualizerDrumHitEvent>.unmodifiable(
        <LyricVisualizerDrumHitEvent>[
          for (final LyricVisualizerDrumHit h in a.drumHits)
            LyricVisualizerDrumHitEvent(
              audioMs: h.timeMs,
              displayMs: h.timeMs + offsetMs,
              kind: h.kind,
              strength: h.strength,
            ),
        ],
      ),
      vocalOnsetsMs: List<int>.unmodifiable(<int>[
        for (final int t in a.vocalOnsetsMs) t + offsetMs,
      ]),
      trackScale: a.trackScale,
      hasAccents: a.hasBeatAccents,
      drumsReady: a.drumsReady,
      offsetMs: offsetMs,
      runtime: runtime,
    );
  }

  static final Expando<LyricVisualizerBeats> _byAudio =
      Expando<LyricVisualizerBeats>('lyricVisualizerBeats');
  static final Expando<LyricVisualizerBeats> _byRuntime =
      Expando<LyricVisualizerBeats>('lyricVisualizerBeatsNoAudio');

  /// [c] 这一首的事件表。同一音频对象 + 同一运行时 + 同一偏移返回同一个对象（建表 O(拍数)，只做一次）。
  static LyricVisualizerBeats of(LyricVisualizerContext c) {
    final LyricVisualizerAudio? a = c.audio;
    final Expando<LyricVisualizerBeats> cache = a == null
        ? _byRuntime
        : _byAudio;
    final Object key = a ?? c.runtime;
    final LyricVisualizerBeats? hit = cache[key];
    if (hit != null &&
        hit.offsetMs == c.offsetMs &&
        identical(hit._runtime, c.runtime)) {
      return hit;
    }
    final LyricVisualizerBeats built = LyricVisualizerBeats.build(
      audio: a,
      runtime: c.runtime,
      offsetMs: c.offsetMs,
    );
    cache[key] = built;
    return built;
  }

  /// 合并后的拍点事件（显示时间升序）。没有节拍网格时为空。
  final List<LyricVisualizerBeatEvent> events;

  /// 鼓击（显示时间升序）。
  final List<LyricVisualizerDrumHitEvent> drumHits;

  /// 人声起音（显示时间毫秒，升序；只有人声分轨时有）。
  final List<int> vocalOnsetsMs;

  final double trackScale;
  final bool hasAccents;

  /// 鼓击检测就绪（见 `LyricVisualizerAudio.drumsReady`）。
  final bool drumsReady;

  /// 建表时的歌词偏移。
  final int offsetMs;

  final LyricVisualizerRuntime _runtime;
  final List<int> _eventTimes;
  final List<LyricVisualizerBeatEvent> _downbeats;
  final List<int> _downbeatTimes;
  final List<int> _hitTimes;

  /// 有真拍点。
  bool get hasBeats => events.isNotEmpty;

  /// 没有拍点：连续包络是歌词起字包络的代用品。
  bool get fromLyrics => events.isEmpty;

  /// 最后一个不晚于 [displayMs] 的拍（序号）；没有为 -1。
  int lastBeatIndexAt(int displayMs) =>
      lyricVisualizerLastAtOrBefore(_eventTimes, displayMs);

  /// 最后一个不晚于 [displayMs] 的拍；没有为 null。
  LyricVisualizerBeatEvent? lastBeatAt(int displayMs) {
    final int i = lastBeatIndexAt(displayMs);
    return i < 0 ? null : events[i];
  }

  /// 第一个晚于 [displayMs] 的拍；没有为 null。
  LyricVisualizerBeatEvent? nextBeatAfter(int displayMs) {
    final int i = lastBeatIndexAt(displayMs) + 1;
    return i < events.length ? events[i] : null;
  }

  /// 显示时间落在 `(fromMs, toMs]` 里的拍（逐帧「这一帧新触发了哪些拍」用：上一帧时刻 → 这一帧时刻）。
  List<LyricVisualizerBeatEvent> beatsBetween(int fromMs, int toMs) {
    if (toMs <= fromMs || events.isEmpty) {
      return const <LyricVisualizerBeatEvent>[];
    }
    final int a = lyricVisualizerLastAtOrBefore(_eventTimes, fromMs) + 1;
    final int b = lyricVisualizerLastAtOrBefore(_eventTimes, toMs);
    if (b < a) return const <LyricVisualizerBeatEvent>[];
    return events.sublist(a, b + 1);
  }

  /// 显示时间落在 `(fromMs, toMs]` 里的鼓击；[kinds] 给了时只留这几类。
  List<LyricVisualizerDrumHitEvent> drumHitsBetween(
    int fromMs,
    int toMs, {
    Set<LyricVisualizerDrumKind>? kinds,
  }) {
    if (toMs <= fromMs || drumHits.isEmpty) {
      return const <LyricVisualizerDrumHitEvent>[];
    }
    final int a = lyricVisualizerLastAtOrBefore(_hitTimes, fromMs) + 1;
    final int b = lyricVisualizerLastAtOrBefore(_hitTimes, toMs);
    return <LyricVisualizerDrumHitEvent>[
      for (int i = a; i <= b; i++)
        if (kinds == null || kinds.contains(drumHits[i].kind)) drumHits[i],
    ];
  }

  /// 拍点冲击（folia clock `beatImpact`）：最近几拍 `gain × exp(-dt / 160 × 2.3)` 的最大值。没有拍点时
  /// 回落到歌词起字包络。
  double beatImpactAt(int displayMs) {
    if (events.isEmpty) return _runtime.pulseAt(displayMs, decayMs: 180);
    return _envelope(
      events,
      lastBeatIndexAt(displayMs),
      displayMs,
      kLyricVisualizerBeatFxDecayMs,
    );
  }

  /// 强拍冲击（folia clock `downbeatImpact`，衰减 200 ms）。没有拍点时回落到句首包络。
  double downbeatImpactAt(int displayMs) {
    if (events.isEmpty) {
      final int li = _runtime.activeLineAt(displayMs);
      if (li < 0) return 0;
      return math.exp(-(displayMs - _runtime.lines[li].startMs) / 400.0);
    }
    return _envelope(
      _downbeats,
      lyricVisualizerLastAtOrBefore(_downbeatTimes, displayMs),
      displayMs,
      kLyricVisualizerDownbeatFxDecayMs,
    );
  }

  /// 摆向（folia `rotationSign`：每触发一拍翻一次，初值 1）。
  double rotationSignAt(int displayMs) {
    final int i = lastBeatIndexAt(displayMs);
    return i < 0 ? 1 : events[i].rotationSign;
  }

  /// 鼓击冲击：最近几下里 `strength × exp(-dt / decayMs)` 的最大值；[kinds] 给了时只算这几类。
  /// 没有鼓击时为 0（没有歌词回落：鼓击类特效在没鼓时本就不打）。
  double drumImpactAt(
    int displayMs, {
    Set<LyricVisualizerDrumKind>? kinds,
    int decayMs = 150,
  }) {
    final int last = lyricVisualizerLastAtOrBefore(_hitTimes, displayMs);
    double best = 0;
    for (int k = last; k >= 0; k--) {
      final LyricVisualizerDrumHitEvent h = drumHits[k];
      final double dt = (displayMs - h.displayMs).toDouble();
      if (dt > decayMs * 8) break;
      if (kinds != null && !kinds.contains(h.kind)) continue;
      best = math.max(best, h.strength * math.exp(-dt / decayMs));
    }
    return best;
  }

  /// [list] 里到第 [last] 项为止、还没衰减完的几项的 `gain × exp(-dt / decay × 2.3)` 最大值。
  static double _envelope(
    List<LyricVisualizerBeatEvent> list,
    int last,
    int displayMs,
    int decayMs,
  ) {
    double best = 0;
    for (int k = last; k >= 0; k--) {
      final LyricVisualizerBeatEvent e = list[k];
      final double dt = (displayMs - e.displayMs).toDouble();
      if (dt > decayMs * 8) break;
      best = math.max(best, e.gain * math.exp(-dt / decayMs * 2.3));
    }
    return best;
  }
}
