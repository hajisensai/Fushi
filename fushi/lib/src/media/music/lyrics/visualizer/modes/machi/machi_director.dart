/// 町景的编排（纯函数，三个场景共用；folia `engine/director.ts` / `environment.ts` /
/// `beatFx.ts` 的固定节拍部分 / `actors/schedules.ts` / `camera.ts` 的运镜）：歌词屏此刻
/// 该亮哪一行还是曲名卡、跑马灯写什么、副歌、副歌开头的闪电、招牌闪烁、时间与天气、
/// 固定节拍的霓虹与大屏闪拍、路上的车、运镜。时间一律是秒。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/machi/machi_math.dart';

// ---------------------------------------------------------------------------
// 场景 / 时间 / 天气的选择
// ---------------------------------------------------------------------------

/// 三个场景：便利店街角、加油站停车场、城寨酒吧。
enum MachiSceneId { konbini, station, kowloon }

enum MachiWeatherKind { clear, rain, snow, fog }

/// “自动”场景按 seed 选（同一首歌总是同一个）。
MachiSceneId resolveMachiSceneId(String choice, int seed) {
  for (final MachiSceneId id in MachiSceneId.values) {
    if (id.name == choice) return id;
  }
  final int h = machiHashString('machi-scene:$seed');
  return MachiSceneId.values[h % MachiSceneId.values.length];
}

/// “自动”天气按 seed 加权：雨 35%、晴 30%、雾 20%、雪 15%。
MachiWeatherKind resolveMachiWeatherKind(String choice, int seed) {
  for (final MachiWeatherKind k in MachiWeatherKind.values) {
    if (k.name == choice) return k;
  }
  double roll = machiHash01(machiHashString('machi-weather:$seed'), 0, 0x3d);
  const List<(MachiWeatherKind, double)> weights = <(MachiWeatherKind, double)>[
    (MachiWeatherKind.rain, 0.35),
    (MachiWeatherKind.clear, 0.3),
    (MachiWeatherKind.fog, 0.2),
    (MachiWeatherKind.snow, 0.15),
  ];
  for (final (MachiWeatherKind kind, double w) in weights) {
    if (roll < w) return kind;
    roll -= w;
  }
  return MachiWeatherKind.rain;
}

/// 白天程度：0 夜，0.45 黄昏，1 白天。
const double machiDaylightNight = 0;
const double machiDaylightDusk = 0.45;
const double machiDaylightDay = 1;

/// 本地时钟（带小数的小时）→ 白天程度：05:00–06:30 天亮，16:30–17:30 落到黄昏，
/// 17:30–18:30 入夜。
double resolveMachiDaylightAt(double hour) {
  final double h = ((hour % 24) + 24) % 24;
  if (h >= 5 && h < 6.5) return machiSmoothstep(5, 6.5, h);
  if (h >= 6.5 && h < 16.5) return 1;
  if (h >= 16.5 && h < 17.5) {
    return 1 - (1 - machiDaylightDusk) * machiSmoothstep(16.5, 17.5, h);
  }
  if (h >= 17.5 && h < 18.5) {
    return machiDaylightDusk * (1 - machiSmoothstep(17.5, 18.5, h));
  }
  return 0;
}

double resolveMachiDaylight(String timeOfDay, DateTime now) {
  switch (timeOfDay) {
    case 'day':
      return machiDaylightDay;
    case 'dusk':
      return machiDaylightDusk;
    case 'night':
      return machiDaylightNight;
  }
  return resolveMachiDaylightAt(now.hour + now.minute / 60 + now.second / 3600);
}

// ---------------------------------------------------------------------------
// 环境（时间与天气）：目标 → 阻尼追过去 → 灯光标量
// ---------------------------------------------------------------------------

class MachiEnvironmentTarget {
  const MachiEnvironmentTarget({
    required this.daylight,
    required this.rain,
    required this.snow,
    required this.fog,
  });

  factory MachiEnvironmentTarget.of(double daylight, MachiWeatherKind kind) =>
      MachiEnvironmentTarget(
        daylight: daylight,
        rain: kind == MachiWeatherKind.rain ? 1 : 0,
        snow: kind == MachiWeatherKind.snow ? 1 : 0,
        fog: kind == MachiWeatherKind.fog ? 1 : 0,
      );

  final double daylight;
  final double rain;
  final double snow;
  final double fog;
}

/// 环境此刻的状态：目标的几项，再加地面湿度与积雪（比降水慢）。
class MachiEnvironmentState {
  const MachiEnvironmentState({
    required this.daylight,
    required this.rain,
    required this.snow,
    required this.fog,
    required this.wetness,
    required this.snowCover,
  });

  /// 一上来就在目标上（换歌、静态帧）。
  factory MachiEnvironmentState.settled(MachiEnvironmentTarget t) =>
      MachiEnvironmentState(
        daylight: t.daylight,
        rain: t.rain,
        snow: t.snow,
        fog: t.fog,
        wetness: t.rain > 0.5 ? 1 : (t.fog > 0.5 ? 0.35 : 0),
        snowCover: t.snow > 0.5 ? 1 : 0,
      );

  final double daylight;
  final double rain;
  final double snow;
  final double fog;
  final double wetness;
  final double snowCover;
}

double _approach(double value, double target, double tau, double delta) {
  final double next = value + (target - value) * (1 - math.exp(-delta / tau));
  return (next - target).abs() < 1e-3 ? target : next;
}

/// 推进 [delta] 秒：降水、雾、白天程度追目标；雨停了路面约 20 秒才干，雪约 8 秒积起、
/// 12 秒化掉。
MachiEnvironmentState stepMachiEnvironment(
  MachiEnvironmentState s,
  MachiEnvironmentTarget t,
  double delta,
) {
  if (delta <= 0) return s;
  final double rain = _approach(s.rain, t.rain, 1.4, delta);
  final double snow = _approach(s.snow, t.snow, 1.4, delta);
  final double fog = _approach(s.fog, t.fog, 2.2, delta);
  final double wetTarget = math.max(rain, fog * 0.35);
  final double wetness = _approach(
    s.wetness,
    wetTarget,
    wetTarget > s.wetness ? 3 : 20,
    delta,
  );
  final double snowCover = _approach(
    s.snowCover,
    snow,
    snow > s.snowCover ? 8 : 12,
    delta,
  );
  return MachiEnvironmentState(
    daylight: _approach(s.daylight, t.daylight, 1.6, delta),
    rain: rain,
    snow: snow,
    fog: fog,
    wetness: wetness,
    snowCover: snowCover,
  );
}

/// 由环境状态推出的灯光与后处理标量。
class MachiEnvironmentLook {
  const MachiEnvironmentLook({
    required this.warmth,
    required this.overcast,
    required this.artificial,
    required this.streetLamps,
    required this.sunIntensity,
    required this.hemiIntensity,
    required this.bloom,
    required this.clouds,
    required this.stars,
    required this.mist,
    required this.haze,
  });

  final double warmth;
  final double overcast;
  final double artificial;
  final double streetLamps;
  final double sunIntensity;
  final double hemiIntensity;
  final double bloom;
  final double clouds;
  final double stars;
  final double mist;
  final double haze;
}

MachiEnvironmentLook resolveMachiEnvironmentLook(MachiEnvironmentState s) {
  final double d = s.daylight;
  final double overcast = math.min(
    1,
    math.max(s.rain, math.max(s.fog, s.snow * 0.8)),
  );
  final double night = 1 - d;
  return MachiEnvironmentLook(
    warmth: math.max(0, 1 - (d - machiDaylightDusk).abs() / 0.38),
    overcast: overcast,
    artificial: 0.55 + 0.45 * machiSmoothstep(0.85, 0.2, d),
    streetLamps: machiSmoothstep(0.62, 0.3, d),
    sunIntensity:
        (1.35 + (3.0 - 1.35) * d) *
        (1 - 0.55 * overcast * d) *
        (1 - 0.25 * s.fog),
    hemiIntensity: 2.1 + 0.35 * d + 0.25 * overcast * d,
    bloom: 0.12 + 0.38 * night,
    clouds: 0.18 + 0.82 * overcast,
    stars: night * (1 - overcast) * machiSmoothstep(0.35, 0.05, d),
    mist: 0.16 * (1 - 0.4 * d) + 0.1 * s.rain + 0.45 * s.fog + 0.06 * s.snow,
    haze: 0.42 * s.fog + 0.08 * s.snow,
  );
}

// ---------------------------------------------------------------------------
// 牌面：在唱或刚唱完的那一行，还是曲名卡
// ---------------------------------------------------------------------------

/// 一行唱完后、下一行还没来时牌面再留多久才换成曲名卡（秒）。
const double machiBoardHoldSeconds = 2.6;

/// 牌面比歌词略早一点亮出来（秒），换牌的信号切换落在唱起的那一刻。
const double machiBoardLeadSeconds = 0.12;

/// 牌面：某一行（[lineIndex] 是 runtime.lines 的下标），或曲名卡（null）。
class MachiBoardTarget {
  const MachiBoardTarget.line(int this.lineIndex);
  const MachiBoardTarget.card() : lineIndex = null;

  final int? lineIndex;

  bool get isCard => lineIndex == null;

  @override
  bool operator ==(Object other) =>
      other is MachiBoardTarget && other.lineIndex == lineIndex;

  @override
  int get hashCode => lineIndex.hashCode;

  @override
  String toString() => isCard ? 'card' : 'line:$lineIndex';
}

/// 纯间奏标记（♪、…）：只有符号没有字。
bool machiIsInterludeText(String text) {
  final String t = text.trim();
  if (t.isEmpty) return true;
  return !RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(t);
}

MachiBoardTarget resolveMachiBoardTarget(
  List<LyricVisualizerLine> lines,
  double time,
) {
  int index = -1;
  for (int i = 0; i < lines.length; i++) {
    if (lines[i].startMs / 1000 <= time + machiBoardLeadSeconds) {
      index = i;
    } else {
      break;
    }
  }
  if (index < 0) return const MachiBoardTarget.card();
  final LyricVisualizerLine line = lines[index];
  if (machiIsInterludeText(line.text)) return const MachiBoardTarget.card();
  final LyricVisualizerLine? next = index + 1 < lines.length
      ? lines[index + 1]
      : null;
  final double hold = line.endMs / 1000 + machiBoardHoldSeconds;
  if (time > hold &&
      (next == null || next.startMs / 1000 - machiBoardLeadSeconds > time)) {
    return const MachiBoardTarget.card();
  }
  return MachiBoardTarget.line(index);
}

/// 副歌权重（folia `resolveMachiChorus`）：牌面在副歌行上为 1（运行时再做平滑）。副歌取运行时的
/// `isChorus`（来源带段落标注时用标注，否则 folia 的文本启发式）。
double resolveMachiChorus(
  List<LyricVisualizerLine> lines,
  MachiBoardTarget target,
) {
  final int? i = target.lineIndex;
  if (i == null || i < 0 || i >= lines.length) return 0;
  return lines[i].isChorus ? 1 : 0;
}

/// 每段副歌的开头（相邻副歌行算一段），秒。
List<double> buildMachiLightningTimes(List<LyricVisualizerLine> lines) =>
    <double>[
      for (int i = 0; i < lines.length; i++)
        if (lines[i].isChorus && (i == 0 || !lines[i - 1].isChorus))
          lines[i].startMs / 1000,
    ];

/// 闪电亮度 0..1：两下闪，第二下略弱，一秒多收尽。
double resolveMachiLightning(List<double> times, double time) {
  double since = double.infinity;
  for (int i = times.length - 1; i >= 0; i--) {
    if (times[i] <= time) {
      since = time - times[i];
      break;
    }
  }
  if (since > 1.2) return 0;
  double flash(double at, double width, double height) =>
      height * math.exp(-((since - at) * (since - at)) / (width * width));
  return math.min(
    1,
    flash(0.04, 0.05, 1) +
        flash(0.24, 0.06, 0.7) +
        0.25 * math.exp(-since * 3.5),
  );
}

/// 招牌闪烁：每 6.5 秒一个窗口，按哈希决定有没有一阵三下的明暗，返回亮度倍数 0.5..1。
double resolveMachiFlicker(double time, int seed, {double rate = 1}) {
  final double window = 6.5 / math.max(0.3, rate);
  final int index = (time / window).floor();
  final int key = machiHashString('flicker:$seed');
  if (machiHash01(key, index, 0x51) > 0.42) return 1;
  final double offset = machiHash01(key, index, 0x7a) * (window - 0.6);
  final double local = time - index * window - offset;
  if (local < 0 || local > 0.46) return 1;
  const List<(double, double, double)> dips = <(double, double, double)>[
    (0, 0.07, 0.5),
    (0.15, 0.2, 0.68),
    (0.32, 0.36, 0.8),
  ];
  for (final (double from, double to, double depth) in dips) {
    if (local >= from && local <= to) return depth;
  }
  return 1;
}

/// 跑马灯（LED 字条、出租车顶灯）写什么：下一句（加这一句的译文）；曲名卡时是曲名与歌手。
String resolveMachiTickerText(
  MachiBoardTarget target,
  List<LyricVisualizerLine> lines, {
  required String title,
  required String artist,
}) {
  if (target.isCard) {
    return '♪ $title${artist.isNotEmpty ? ' — $artist' : ''}   ◆   OPEN 24H   ◆   ';
  }
  final int i = target.lineIndex!;
  LyricVisualizerLine? next;
  for (int k = i + 1; k < lines.length; k++) {
    if (!machiIsInterludeText(lines[k].text)) {
      next = lines[k];
      break;
    }
  }
  final String? translation = i < lines.length ? lines[i].translation : null;
  final List<String> parts = <String>[
    if (next != null) 'NEXT ▸ ${next.text}',
    if (translation != null && translation.trim().isNotEmpty) '◆ $translation',
  ];
  return parts.isNotEmpty ? '${parts.join('   ')}   ' : '♪ $title   ◆   ';
}

/// 段落开头（与上一句隔了至少 [gap] 秒的行，含第一句）：便利店在这时开一下自动门。
List<double> buildMachiParagraphStarts(
  List<LyricVisualizerLine> lines, {
  double gap = 4,
}) => <double>[
  for (int i = 0; i < lines.length; i++)
    if (i == 0 || (lines[i].startMs - lines[i - 1].endMs) / 1000 >= gap)
      lines[i].startMs / 1000,
];

/// 自动门开合 0..1：段落开头前 0.6 秒开始开，开 3 秒后关上。
double resolveMachiDoorOpen(List<double> starts, double time) {
  double best = 0;
  for (final double s in starts) {
    final double local = time - (s - 0.6);
    if (local < 0 || local > 4.6) continue;
    final double open = local < 0.8
        ? machiSmoothstep(0, 0.8, local)
        : (local < 3.6 ? 1 : 1 - machiSmoothstep(3.6, 4.6, local));
    best = math.max(best, open);
  }
  return best;
}

// ---------------------------------------------------------------------------
// 固定节拍（folia 没开智能动感模式时的 MACHI_BEAT.steady）
// ---------------------------------------------------------------------------

const int machiNeonGroups = 3;

/// 慢慢亮起、再慢慢暗下的一下（0..1）。
double machiSwell(double age, double attack, double fall) {
  if (age < 0 || age >= attack + fall) return 0;
  if (age < attack) {
    final double u = age / attack;
    return u * u * (3 - 2 * u);
  }
  final double u = (age - attack) / fall;
  return 1 - u * u * (3 - 2 * u);
}

/// 一帧的节拍量：三组霓虹的倍数、平均、店里暖灯、大屏上亮起的几处。
class MachiBeatFrame {
  MachiBeatFrame();

  final List<double> neonGroups = List<double>.filled(machiNeonGroups, 1);
  double neon = 1;
  double warm = 1;

  /// 辉光强度的倍数（跟三组霓虹的平均走）。
  double bloom = 1;
  final List<double> swellAt = List<double>.filled(4, 0.5);
  final List<double> swellAmp = List<double>.filled(4, 0);

  void reset() {
    neonGroups.fillRange(0, machiNeonGroups, 1);
    neon = 1;
    warm = 1;
    bloom = 1;
    swellAt.fillRange(0, 4, 0.5);
    swellAmp.fillRange(0, 4, 0);
  }

  /// 第 [group] 组霓虹。
  double group(int group) => neonGroups[group % machiNeonGroups];

  /// 近白的灯箱只跟霓虹那一路的三成。
  double lightbox(int group) => 1 + 0.3 * (this.group(group) - 1);
}

const double _beatPeriod = 0.75;
const int _beatsPerBar = 4;

/// 一拍（folia `BeatFxEvent` 里用得到的那几项；显示时间，秒）。
class MachiBeatEvent {
  const MachiBeatEvent({
    required this.t,
    required this.downbeat,
    required this.gain,
  });

  final double t;
  final bool downbeat;

  /// folia `resolveBeatFxAccentGain`：0 = 没有节奏的小节里的拍，不亮。
  final double gain;
}

/// 音频分析 → 节拍表（显示时间，秒）。每拍的重音读该拍那一刻的 `accentImpact`（正好在拍上时就是这一拍的
/// 峰值，folia 弱拍底 0.35）；没有重音数据时每拍按 1 算。没有节拍网格返回空表。
List<MachiBeatEvent> machiBeatEventsOf(LyricVisualizerContext c) {
  final LyricVisualizerAudio? audio = c.audio;
  if (audio == null || !audio.beatsReady) return const <MachiBeatEvent>[];
  final Set<int> downbeats = audio.downbeatTimesMs.toSet();
  return <MachiBeatEvent>[
    for (final int ms in audio.beatTimesMs)
      () {
        final double? accent = audio.frameAt(ms).accentImpact;
        return MachiBeatEvent(
          t: c.displayTimeOfAudio(ms) / 1000,
          downbeat: downbeats.contains(ms),
          gain: accent == null
              ? 1
              : accent <= 1e-3
              ? 0
              : 0.35 + 0.65 * accent.clamp(0.0, 1.0),
        );
      }(),
  ];
}

const double _neonAttack = 0.4;
const double _neonFall = 1.5;
const double _neonLift = 0.2;
const double _neonContrast = 0.2;
const double _neonDownbeat = 1.2;
const double _warmAttack = 0.6;
const double _warmFall = 2.2;
const double _warmLift = 0.08;
const double _bloomLift = 0.1;
const double _neonLife = 2.8; // max(0.4 + 1.5, 0.6 + 2.2)

void _resetNeon(MachiBeatFrame out) {
  out.neonGroups.fillRange(0, machiNeonGroups, 1);
  out.neon = 1;
  out.warm = 1;
  out.bloom = 1;
}

/// 把一拍叠进 [swells]：第 index 拍轮到 index % 组数 那组；返回这拍给店里暖灯的量（不是小节第一拍为 0）。
double _addNeonBeat(
  List<double> swells,
  int index,
  double age,
  double gain,
  bool downbeat,
) {
  final int group = index % machiNeonGroups;
  final double swell =
      gain *
      (downbeat ? _neonDownbeat : 1) *
      machiSwell(age, _neonAttack, _neonFall);
  swells[group] = math.max(swells[group], swell);
  if (!downbeat) return 0;
  return gain * machiSwell(age, _warmAttack, _warmFall);
}

/// 每组的倍数 = 1 + 强度 ×（lift × 这组 + contrast ×（这组 − 三组平均）），三组一样亮时只是轮流。
void _writeNeon(
  List<double> swells,
  double strength,
  double bar,
  MachiBeatFrame out,
) {
  double mean = 0;
  for (final double v in swells) {
    mean += v;
  }
  mean /= machiNeonGroups;
  for (int g = 0; g < machiNeonGroups; g++) {
    out.neonGroups[g] = math.max(
      0,
      1 +
          strength *
              (_neonLift * swells[g] + _neonContrast * (swells[g] - mean)),
    );
  }
  out.neon = 1 + strength * _neonLift * mean;
  out.warm = 1 + strength * _warmLift * bar;
  out.bloom = 1 + strength * _bloomLift * mean;
}

/// 霓虹随拍（folia `resolveMachiNeonPulse`）：[events] 是整张节拍表（升序），按拍在表里的序号轮到第几组
/// （拖进度也是同一组）；没有节奏的小节里的拍不亮。
void resolveMachiNeonPulse(
  List<MachiBeatEvent> events,
  double time,
  double strength,
  MachiBeatFrame out,
) {
  _resetNeon(out);
  if (events.isEmpty || strength <= 0) return;
  final List<double> swells = List<double>.filled(machiNeonGroups, 0);
  double bar = 0;
  int last = -1;
  int lo = 0;
  int hi = events.length - 1;
  while (lo <= hi) {
    final int mid = (lo + hi) >> 1;
    if (events[mid].t <= time) {
      last = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  for (int index = last; index >= 0; index--) {
    final MachiBeatEvent e = events[index];
    final double age = time - e.t;
    if (age >= _neonLife) break;
    if (e.gain <= 0) continue;
    bar = math.max(bar, _addNeonBeat(swells, index, age, e.gain, e.downbeat));
  }
  _writeNeon(swells, strength, bar, out);
}

/// 固定节拍的霓虹随拍（folia `resolveMachiSteadyNeonPulse`）：第 k 拍在 k × 0.75 秒，每 4 拍一个小节第一拍，
/// 别的与 [resolveMachiNeonPulse] 一样；强度再乘 0.8。
void resolveMachiSteadyNeonPulse(
  double time,
  double strength,
  MachiBeatFrame out,
) {
  _resetNeon(out);
  if (strength <= 0 || time < 0) return;
  final List<double> swells = List<double>.filled(machiNeonGroups, 0);
  double bar = 0;
  for (int index = (time / _beatPeriod).floor(); index >= 0; index--) {
    final double age = time - index * _beatPeriod;
    if (age >= _neonLife) break;
    bar = math.max(
      bar,
      _addNeonBeat(swells, index, age, 1, index % _beatsPerBar == 0),
    );
  }
  _writeNeon(swells, strength * 0.8, bar, out);
}

/// 第 index 下在屏上的位置（0..1）：黄金分割步进，先后几下左右错开。
double machiSwellPlace(int index) => 0.15 + 0.7 * ((index * 0.618034) % 1);

/// 固定节拍的大屏闪拍：每小节第二、四拍在屏上亮一处（约 0.25 秒亮起、1.15 秒暗下），
/// 最多四处。
void resolveMachiSteadyScreenFlash(
  double time,
  double strength,
  MachiBeatFrame out,
) {
  out.swellAt.fillRange(0, 4, 0.5);
  out.swellAmp.fillRange(0, 4, 0);
  if (strength <= 0) return;
  const double every = _beatPeriod * 2;
  int slot = 0;
  for (
    int index = ((time - _beatPeriod) / every).floor();
    index >= 0 && slot < 4;
    index--
  ) {
    final double age = time - (index * every + _beatPeriod);
    if (age >= 1.4) break;
    out.swellAt[slot] = machiSwellPlace(index);
    out.swellAmp[slot] = strength * 0.6 * machiSwell(age, 0.25, 1.15);
    slot++;
  }
}

// ---------------------------------------------------------------------------
// 路上的车（folia actors/schedules.ts）
// ---------------------------------------------------------------------------

/// 车道：从 from 开到 to（xz，两端伸出底座）。
class MachiLane {
  const MachiLane(this.fromX, this.fromZ, this.toX, this.toZ);

  final double fromX;
  final double fromZ;
  final double toX;
  final double toZ;

  double get length =>
      math.sqrt((toX - fromX) * (toX - fromX) + (toZ - fromZ) * (toZ - fromZ));
}

/// 车速（米/秒，约 23 km/h）。
const double machiCarSpeed = 6.5;
const double _carWindow = 9.5;

class MachiCarPass {
  const MachiCarPass({
    required this.lane,
    required this.distance,
    required this.colorIndex,
  });

  final int lane;
  final double distance;
  final int colorIndex;
}

/// 时刻 [time]（氛围时钟）路上的车：按 9.5 秒切窗口，每个窗口按哈希决定有没有一辆、
/// 走哪条道、什么颜色；同时最多一辆。
MachiCarPass? resolveMachiCar(
  double time,
  int seed,
  List<MachiLane> lanes, {
  double chance = 0.62,
}) {
  if (lanes.isEmpty) return null;
  final int key = machiHashString('car:$seed');
  final int window = (time / _carWindow).floor();
  for (final int index in <int>[window, window - 1]) {
    if (machiHash01(key, index, 0x11) > chance) continue;
    final double start =
        index * _carWindow + machiHash01(key, index, 0x22) * (_carWindow * 0.5);
    final double local = time - start;
    final int lane = math.min(
      lanes.length - 1,
      (machiHash01(key, index, 0x33) * lanes.length).floor(),
    );
    if (local < 0 || local > lanes[lane].length / machiCarSpeed) continue;
    return MachiCarPass(
      lane: lane,
      distance: local * machiCarSpeed,
      colorIndex: (machiHash01(key, index, 0x44) * 1000).floor(),
    );
  }
  return null;
}

// ---------------------------------------------------------------------------
// 运镜（folia camera.ts resolveMachiDrift）
// ---------------------------------------------------------------------------

/// 相对静止视角的偏移：转角 / 俯仰（度）、缩放倍数、沿地面平移（米）。
class MachiViewOffset {
  const MachiViewOffset({
    this.azimuth = 0,
    this.elevation = 0,
    this.zoom = 1,
    this.panX = 0,
    this.panZ = 0,
  });

  final double azimuth;
  final double elevation;
  final double zoom;
  final double panX;
  final double panZ;
}

/// 几道周期互不成倍数的慢正弦：转角 ±20°、俯仰 ±4°、缩放 ±8%、平移半米以内。
MachiViewOffset resolveMachiDrift(double time) {
  double wave(double period, double phase) =>
      math.sin(time / period * math.pi * 2 + phase);
  return MachiViewOffset(
    azimuth: 15 * wave(67, 0) + 5 * wave(29, 1.3),
    elevation: 4 * wave(47, 0.7),
    zoom: math.exp(0.08 * wave(41, 2.1)),
    panX: 0.45 * wave(53, 0.4),
    panZ: 0.3 * wave(71, 2.6),
  );
}
