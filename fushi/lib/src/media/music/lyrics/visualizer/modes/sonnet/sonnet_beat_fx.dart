/// 商籁的随拍特效（folia `sonnetBeatFx.ts`，「智能动感模式」里的「推镜裂光」）与主题强度系数。
///
/// 每种效果跟自己的信号：
/// - 镜头推拉 + 左右交替的轻微倾斜 ← 共享拍钟的拍点冲击（`LyricVisualizerBeats`：每拍按重音增益冲顶），
///   按最近一拍的音色与小节位置塑形；
/// - 单色撕裂（与转场故障条共用，取大者）← 强拍冲击；
/// - 光晕增亮 ← 强拍冲击；
/// - 图标随词起跳（取代按频段呼吸）← 镜头里语义片段的起唱时刻；
/// - MG 线条闪亮 ← 高频，平滑后连续变化。
///
/// 只有**真节拍网格就绪**（共享拍点表非空）时才算随拍帧；否则返回 null，商籁画原来的画面（图标按频段
/// 呼吸：有音频分析时是真频段，没有时是歌词起字包络），与 folia 没装上拍点时一致。
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show immutable;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

/// folia `SONNET_BEAT_FX`（在 159 BPM 的实际画面上定下的常数）。
abstract final class SonnetBeatFxConstants {
  static const double zoomPercent = 6;
  static const double rotationDeg = 0.6;
  static const double downbeatZoomPercent = 5;
  static const double tear = 0.6;
  static const double tearRate = 24;
  static const double flare = 0.7;
  static const double iconPop = 0.4;
  static const double iconDecayMs = 300;

  /// MG 线条平时的透明度，高频把它推到 1。
  static const double lineBaseAlpha = 0.78;
}

/// 一帧随拍特效。
@immutable
class SonnetBeatFxFrame {
  const SonnetBeatFxFrame({
    required this.zoom,
    required this.rotation,
    required this.tear,
    required this.tearSeed,
    required this.flare,
    required this.lineLift,
  });

  /// 镜头缩放倍数。
  final double zoom;

  /// 额外镜头旋转（弧度）。
  final double rotation;

  /// 撕裂强度（强拍包络；不动时 0）。
  final double tear;
  final double tearSeed;

  /// 光晕增亮 0–0.7。
  final double flare;

  /// 平滑后的高频 0–1（MG 线条闪亮）。
  final double lineLift;
}

/// 最近一拍的重音塑形（folia `resolveSonnetBeatFxAccent`）：低频为主的拍推得更深（0.85–1.15 倍），
/// 高频为主的拍倾得更多（0.7–1.3 倍）；小节第 4 拍（强拍前一拍）倾斜再减半，镜头在强拍落下前先摆回来。
/// 没有重音数据（或还没打过拍）时不塑形。
(double zoom, double tilt) resolveSonnetBeatFxAccent(
  LyricVisualizerBeatEvent? event,
) {
  if (event == null || !event.hasAccents) return (1, 1);
  return (
    0.85 + 0.3 * event.lowShare,
    (0.7 + 0.6 * event.highShare) * (event.barPos == 3 ? 0.5 : 1),
  );
}

/// 一帧的包络数学（folia `resolveSonnetBeatFxFrame`）。[k] 拍点冲击、[d] 强拍冲击、
/// [rotationSign] ±1（每拍翻一次）。
SonnetBeatFxFrame resolveSonnetBeatFxFrame(
  double k,
  double d,
  double rotationSign,
  double wallTimeSec,
  double lineLift, {
  double accentZoom = 1,
  double accentTilt = 1,
}) => SonnetBeatFxFrame(
  zoom:
      1 +
      SonnetBeatFxConstants.zoomPercent / 100 * k * accentZoom +
      SonnetBeatFxConstants.downbeatZoomPercent / 100 * d,
  rotation:
      SonnetBeatFxConstants.rotationDeg *
      math.pi /
      180 *
      k *
      rotationSign *
      accentTilt,
  tear: d > 0.02 ? SonnetBeatFxConstants.tear * d : 0,
  tearSeed: ((wallTimeSec * SonnetBeatFxConstants.tearRate).floor() % 997)
      .toDouble(),
  flare: SonnetBeatFxConstants.flare * d,
  lineLift: lineLift,
);

/// MG 线条在给定高频下的透明度（folia `resolveSonnetLineFlashAlpha`）。
double resolveSonnetLineFlashAlpha(double lineLift) =>
    SonnetBeatFxConstants.lineBaseAlpha +
    (1 - SonnetBeatFxConstants.lineBaseAlpha) * lineLift.clamp(0.0, 1.0);

/// 图标随词起跳包络（folia `resolveSonnetIconOnsetPop`）：最近一个不晚于 [time] 的起唱处为 1，
/// 约 300 ms 衰减完。无状态，拖动进度也对。
double resolveSonnetIconOnsetPop(double time, List<double> cues) {
  double lastAt = double.negativeInfinity;
  for (final double at in cues) {
    if (at <= time && at > lastAt) lastAt = at;
  }
  final double elapsedMs = (time - lastAt) * 1000;
  return elapsedMs >= 0 && elapsedMs.isFinite
      ? math.exp(-elapsedMs / SonnetBeatFxConstants.iconDecayMs * 2.3)
      : 0;
}

/// 起跳包络 → 图标缩放（folia `resolveSonnetIconPopScale`）。
double resolveSonnetIconPopScale(double k) =>
    1 + SonnetBeatFxConstants.iconPop * k * (1.15 - 0.15 * k);

/// 按频段呼吸的图标目标值（folia `sonnetShotMg.updateTime` 的原路径）：低频 0.34 + 人声 0.52 +
/// 响度 0.14，去掉空闲呼吸底噪后拉开可闻范围。
double resolveSonnetIconAudioTarget(LyricVisualizerAudioFrame f) {
  final double energy = f.low * 0.34 + f.vocal * 0.52 + f.power * 0.14;
  final double gated = math.max(0, (energy - 0.08) / 0.92);
  return math.min(1, math.pow(gated, 0.68) * 1.35).toDouble();
}

/// 主题强度对镜头与字效的倍数（folia `resolveSonnetAnimationScale`）。
double sonnetAnimationScale(LyricVisualizerIntensity intensity) =>
    switch (intensity) {
      LyricVisualizerIntensity.calm => 0.65,
      LyricVisualizerIntensity.normal => 1,
      LyricVisualizerIntensity.chaotic => 1.35,
    };

/// 逐帧读随拍特效（folia `createSonnetBeatFxReader`）：持有高频平滑状态。
class SonnetBeatFxReader {
  double _smoothedTreble = 0;

  /// 歌词显示时间 [displayMs] 的随拍帧；节拍网格没就绪（或 [frame] 不是正在播放）时为 null，
  /// 并清掉平滑状态。
  SonnetBeatFxFrame? read(
    LyricVisualizerContext c,
    LyricVisualizerAudioFrame frame,
    int displayMs, {
    required double wallTimeSec,
  }) {
    final LyricVisualizerBeats beats = LyricVisualizerBeats.of(c);
    if (!beats.hasBeats) {
      _smoothedTreble = 0;
      return null;
    }
    // 暂停时不跟着空闲呼吸闪。
    final double treble = c.playing ? frame.high.clamp(0.0, 1.0) : 0;
    final double target = ((treble - 0.04) / 0.35).clamp(0.0, 1.0);
    _smoothedTreble +=
        (target - _smoothedTreble) * (target > _smoothedTreble ? 0.25 : 0.08);
    // 画面上的那一下是最近打的那一拍（强拍或普通拍）。
    final (double az, double at) = resolveSonnetBeatFxAccent(
      beats.lastBeatAt(displayMs),
    );
    return resolveSonnetBeatFxFrame(
      beats.beatImpactAt(displayMs),
      beats.downbeatImpactAt(displayMs),
      beats.rotationSignAt(displayMs),
      wallTimeSec,
      _smoothedTreble,
      accentZoom: az,
      accentTilt: at,
    );
  }
}
