/// 绘光的音频采样（folia `lumiereAudio.ts`）：共享音频帧的低频 / 高频 / 响度 → 平滑后的
/// bass / treble / power（0..1）。起音快（60 ms）、释放慢（250 ms），跟得上鼓点又不闪；暂停或关掉
/// 动态效果时整帧归零（场景当作安静）。
library;

import 'dart:math' as math;

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_audio.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_theme.dart';

const double kLumiereAudioAttack = 0.06;
const double kLumiereAudioRelease = 0.25;

/// 一阶低通，起音与释放各自的时间常数；[dt] 秒（folia `smoothLumiereAudioValue`）。
double smoothLumiereAudioValue(double current, double target, double dt) {
  final double tau = target > current
      ? kLumiereAudioAttack
      : kLumiereAudioRelease;
  final double k = 1 - math.exp(-math.max(0, dt) / tau);
  return current + (target - current) * k;
}

double _unit(double v) => v.isFinite && v > 0 ? math.min(1, v) : 0;

/// 每帧采一次的平滑音频值。
class LumiereAudioSampler {
  double bass = 0;
  double treble = 0;
  double power = 0;

  /// [frame] 为 null（暂停 / 关动态）时归零。
  void sample(LyricVisualizerAudioFrame? frame, double dt) {
    if (frame == null) {
      bass = 0;
      treble = 0;
      power = 0;
      return;
    }
    bass = smoothLumiereAudioValue(bass, _unit(frame.low), dt);
    treble = smoothLumiereAudioValue(treble, _unit(frame.high), dt);
    power = smoothLumiereAudioValue(power, _unit(frame.power), dt);
  }
}

/// 主题动画强度对运镜浮动 / 呼吸 / 摆动的倍数（folia `createLumiereCamera` 的 motion）。
double lumiereCameraMotion(LyricVisualizerIntensity intensity) =>
    switch (intensity) {
      LyricVisualizerIntensity.calm => 0.6,
      LyricVisualizerIntensity.normal => 1,
      LyricVisualizerIntensity.chaotic => 1.4,
    };
