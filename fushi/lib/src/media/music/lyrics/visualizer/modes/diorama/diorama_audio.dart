/// 镜台的音频驱动（移植 folia `dioramaParticleModel.ts` 的频段追踪器、`dioramaBeatRipples.ts` 的
/// 拍点波纹 / 整体呼吸 / 歌词跳动，以及 `dioramaKeywordColor.ts` 的关键词配色）。纯 Dart，可单测。
///
/// 信号来自 `LyricVisualizerContext.audioFrameAt`：整首离线分析就绪时是真频段与真拍点；没有分析时
/// 框架用歌词起字包络合成一帧（`fallback`），追踪器照样从它读出起音，波纹跟着唱词走。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_camera_path.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_math.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/diorama/diorama_particles.dart';

double _clamp01(double v) => v.clamp(0.0, 1.0);

double _smoothstep(double e0, double e1, double v) {
  final double a = ((v - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return a * a * (3 - 2 * a);
}

/// 一个频段这一帧的信号（folia `DioramaBandSignal`）。
class DioramaBandSignal {
  const DioramaBandSignal({
    required this.transient,
    required this.sustained,
    required this.onset,
  });

  /// 0–1 起音强度（按本频段自己的动态范围归一）。
  final double transient;

  /// 0–1 相对整首响度的持续能量。
  final double sustained;

  /// 起音越过触发线的那一帧为 true（只有它生波纹）。
  final bool onset;
}

/// folia `stepDioramaBandTracker`：分别追谷底（慢升快降）和峰值（快升慢降），起音 =（快包络 − 谷底）
/// ÷（峰值 − 谷底），稳定鼓点下不会被当成背景吃掉；施密特触发，一下鼓点一个波纹。
class DioramaBandTracker {
  double fast = 0;
  double floor = 0;
  double peak = 0;
  bool armed = false;
  bool primed = false;

  static const double _fastAttack = 22;
  static const double _fastRelease = 7;
  static const double _floorRise = 2.5;
  static const double _floorFall = 4;
  static const double _peakRise = 9;
  static const double _peakFall = 0.28;
  static const double _minRange = 0.12;
  static const double _minPeak = 0.22;
  static const double _triggerHigh = 0.42;
  static const double _triggerLow = 0.2;

  DioramaBandSignal step(double level, double delta) {
    final double safe = _clamp01(level);
    if (!primed) {
      // 从信号本身起步，不从 0：否则头几帧是一个后面再也追不上的满幅起音。
      fast = safe;
      floor = safe;
      peak = safe;
      primed = true;
    } else {
      fast = dioramaStepEnvelope(fast, safe, _fastAttack, _fastRelease, delta);
      floor = dioramaStepEnvelope(floor, safe, _floorRise, _floorFall, delta);
      peak = dioramaStepEnvelope(peak, safe, _peakRise, _peakFall, delta);
    }
    final double range = math.max(_minRange, peak - floor);
    final double transient = _clamp01((fast - floor) / range);
    final double sustained = _clamp01(fast / math.max(_minPeak, peak));
    bool onset = false;
    if (!armed && transient >= _triggerHigh) {
      armed = true;
      onset = true;
    } else if (armed && transient <= _triggerLow) {
      armed = false;
    }
    return DioramaBandSignal(
      transient: transient,
      sustained: sustained,
      onset: onset,
    );
  }
}

/// folia `resolveDioramaParticleAudioResponse`：(流速, 整体呼吸)。流速跟持续低频，呼吸跟起音。
(double, double) dioramaParticleAudioResponse(
  DioramaBandSignal bass,
  DioramaBandSignal mid,
) => (
  math.min(1.55, 0.3 + _clamp01(bass.sustained) * 1.25),
  math.min(
    dioramaParticleAudioScaleMax,
    1 +
        _smoothstep(0.1, 0.9, bass.transient) * 0.14 +
        _smoothstep(0.15, 0.95, mid.transient) * 0.05,
  ),
);

/// folia `resolveDioramaPulseTarget`：走廊只留 12% 的整体呼吸（否则整面墙绕着相机一缩一胀）。
double dioramaPulseTarget(double clusterPulse, double gain, bool corridor) =>
    1 + (clusterPulse - 1) * gain * (corridor ? 0.12 : 1);

/// 拍点的波纹强度（folia `DIORAMA_BEAT_RIPPLE_STRENGTH` / `DOWNBEAT`）。
const double dioramaBeatRippleStrength = 1.6;
const double dioramaDownbeatRippleStrength = 2.2;

/// folia `resolveDioramaBeatClusterPulse`：每拍一次明显的呼吸，强拍更大。
double dioramaBeatClusterPulse(double beat, double downbeat) => math.min(
  dioramaParticleAudioScaleMax,
  1 + math.max(0, beat) * 0.2 + math.max(0, downbeat) * 0.28,
);

/// folia `resolveDioramaLyricHop`：正在唱的单元随拍跳起的高度（行高倍数），拍上 1/4、强拍 2/5，
/// 上限 0.8。
double dioramaLyricHop(double beat, double downbeat) =>
    math.min(0.8, math.max(0, beat) * 0.25 + math.max(0, downbeat) * 0.4);

/// 一帧新落下的普通拍 / 强拍（没有为 null）。
typedef DioramaBeatTriggers = ({
  LyricVisualizerBeatEvent? beat,
  LyricVisualizerBeatEvent? downbeat,
});

/// 两帧之间新落下的拍（folia `stepDioramaBeatCounter` + 拍钟的 `lastBeat` / `lastDownbeat`）：显示时间
/// `(prevMs, nowMs]` 里最后一个普通拍、最后一个强拍（没有为 null）。强拍也算一拍，但只生强拍的波纹；
/// 一帧里落了好几拍也只各生一个；拖进度（[jump]）不生。
DioramaBeatTriggers dioramaBeatTriggers(
  LyricVisualizerBeats beats,
  int prevMs,
  int nowMs, {
  required bool jump,
}) {
  if (jump || nowMs <= prevMs) return (beat: null, downbeat: null);
  LyricVisualizerBeatEvent? beat;
  LyricVisualizerBeatEvent? downbeat;
  for (final LyricVisualizerBeatEvent e in beats.beatsBetween(prevMs, nowMs)) {
    if (e.downbeat) {
      downbeat = e;
    } else {
      beat = e;
    }
  }
  return (beat: beat, downbeat: downbeat);
}

/// folia `DIORAMA_LOW_BEAT_SHARE`：普通拍的突起里低频占比超过它就生低频尺度的波纹。
const double dioramaLowBeatShare = 0.5;

/// folia `resolveDioramaBeatRipple`：一拍生的波纹（频段下标 0 低频尺度 / 1 中频尺度，强度）。强度按这一拍
/// 的重音增益（`resolveBeatFxAccentGain`，无节奏段为 0）；强拍生低频尺度，普通拍低频为主时也生低频尺度。
({int index, double strength}) dioramaBeatRipple(LyricVisualizerBeatEvent e) {
  if (e.downbeat) {
    return (index: 0, strength: dioramaDownbeatRippleStrength * e.gain);
  }
  final bool low = e.hasAccents && e.lowShare > dioramaLowBeatShare;
  return (index: low ? 0 : 1, strength: dioramaBeatRippleStrength * e.gain);
}

// ─── 关键词配色（folia dioramaKeywordColor.ts） ────────────────────────────

/// 当前行的字在屏上的不透明度（folia `ACTIVE_LINE_OPACITY`）。
const double _activeLineOpacity = 0.92;
const double _keywordMinBgContrast = 4.5;
const double _keywordMinPrimarySeparation = 0.4;

double _separation(ui.Color a, ui.Color b) =>
    (a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs();

/// 关键词字在背景上实际呈现的颜色（按 0.92 不透明度叠在背景上）与背景的对比度。
double dioramaKeywordDisplayedContrast(ui.Color c, ui.Color background) =>
    dioramaContrastRatio(
      ui.Color.lerp(background, c.withValues(alpha: 1), _activeLineOpacity)!,
      background,
    );

ui.Color _nudgeUntil(
  ui.Color color,
  ui.Color target,
  double minimum,
  double Function(ui.Color c) measure,
) {
  if (measure(color) >= minimum) return color;
  double lo = 0, hi = 1;
  for (int i = 0; i < 10; i++) {
    final double mid = (lo + hi) / 2;
    if (measure(ui.Color.lerp(color, target, mid)!) >= minimum) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return ui.Color.lerp(color, target, hi)!;
}

/// folia `resolveDioramaKeywordColor`：先往强调色推到与正文色拉开，再往黑 / 白推到在背景上看得清
/// （后者说了算），各自只推最小的一步。
ui.Color dioramaKeywordColor(
  ui.Color keyword,
  ui.Color primary,
  ui.Color accent,
  ui.Color background,
) {
  final ui.Color separated = _nudgeUntil(
    keyword.withValues(alpha: 1),
    accent.withValues(alpha: 1),
    _keywordMinPrimarySeparation,
    (ui.Color c) => _separation(c, primary),
  );
  const ui.Color light = ui.Color(0xFFFFFFFF);
  const ui.Color dark = ui.Color(0xFF050505);
  final ui.Color pole =
      dioramaKeywordDisplayedContrast(light, background) >=
          dioramaKeywordDisplayedContrast(dark, background)
      ? light
      : dark;
  return _nudgeUntil(
    separated,
    pole,
    _keywordMinBgContrast,
    (ui.Color c) => dioramaKeywordDisplayedContrast(c, background),
  );
}

/// folia `resolveDioramaKeywordUnitColors`：行里每个单元（按 UTF-16 区间）命中的关键词颜色，修正后
/// 按单元下标给出；没命中的单元不在表里。
Map<int, ui.Color> dioramaKeywordUnitColors(
  LyricVisualizerTheme? theme,
  String lineText,
  List<(int, int)> unitRanges,
  ui.Color primary,
  ui.Color accent,
  ui.Color background,
) {
  final Map<int, ui.Color> out = <int, ui.Color>{};
  if (theme == null || !theme.hasWordColors || lineText.isEmpty) return out;
  final List<LyricVisualizerWordColorRange> ranges = theme.colorRangesFor(
    lineText,
  );
  if (ranges.isEmpty) return out;
  final Map<int, ui.Color> adapted = <int, ui.Color>{};
  for (int i = 0; i < unitRanges.length; i++) {
    final (int s, int e) = unitRanges[i];
    final ui.Color? hit = LyricVisualizerTheme.colorForSpan(ranges, s, e);
    if (hit == null) continue;
    out[i] = adapted.putIfAbsent(
      hit.toARGB32(),
      () => dioramaKeywordColor(hit, primary, accent, background),
    );
  }
  return out;
}
