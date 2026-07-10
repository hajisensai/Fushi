import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/mining_audio_clip.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// BUG-713 守卫：有声书导出片段「逐句高亮进度慢了」的根因是**帧量化残差**——
/// [clipFramePlan] 用帧中心（round）采样，句起点 S 的高亮在视频时刻 `round(S/Δ)·Δ`
/// 出现（Δ=1000/fps，音视频锁定），与真实音频对称误差 ≤Δ/2。fps 越低 Δ 越大、滞后越
/// 明显：12fps 下 Δ≈83ms，约一半 cue 晚最多 ~42ms（可感知）。TODO-1147/1256 三次改采样
/// 都只在 ±Δ 里挪、没动 Δ；根治是提高 fps 缩小 Δ。
///
/// 覆盖两层：
/// 1. 行为（红→绿）：给定一批跨多个「相位偏移」的 cue，导出高亮相对音频的**最大滞后**
///    严格 ≤ Δ/2 = 500/fps；fps=12 时该上限 >40ms（旧行为可感知），fps=24 时 ≤21ms
///    （不可感知）——量化提 fps 确实把滞后压到阈下。
/// 2. 源码守卫：动态导出路径 [_synthDynamicClipVideo] 的导出 fps 常量 ≥ 24，防止有人
///    改回 12（或更低）令帧量化滞后回归。
void main() {
  group('BUG-713 导出高亮帧量化滞后', () {
    // 每个 cue 高亮在导出视频里**首次出现**的帧时刻（相对 globalStart，ms）。
    // clipFramePlan 返回 run-length（highlightCueIndex + frameCount）；某句首个 run 之前
    // 的累计帧数 × Δ 即该句高亮第一次亮起的视频时刻。
    Map<int, double> highlightOnsetMs({
      required List<ClipFrameSpec> plan,
      required int fps,
    }) {
      final double msPerFrame = 1000.0 / fps;
      final Map<int, double> onset = <int, double>{};
      int cumulativeFrames = 0;
      for (final ClipFrameSpec spec in plan) {
        onset.putIfAbsent(
          spec.highlightCueIndex,
          () => cumulativeFrames * msPerFrame,
        );
        cumulativeFrames += spec.frameCount;
      }
      return onset;
    }

    // 确定性相位扫描：对每个句起点 S 建 [cue0(0..S), cueTarget(S..S+500)]，驱动真实
    // clipFramePlan，测 cueTarget 高亮亮起时刻相对 S 的滞后，取全扫描最大值。1ms 步长密集
    // 覆盖 round 采样的所有相位，必然扫到「最坏相位」（frac(S/Δ)→0.5+ → 高亮等到下一帧）。
    double maxLatenessMs({required int fps}) {
      double worst = 0;
      for (int s = 1; s <= 2000; s++) {
        final List<AudioCue> cues = <AudioCue>[
          _cue(startMs: 0, endMs: s),
          _cue(startMs: s, endMs: s + 500),
        ];
        final List<ClipFrameSpec> plan = clipFramePlan(
          cues: cues,
          globalStartMs: 0,
          globalEndMs: s + 500,
          fps: fps,
        );
        final Map<int, double> onset = highlightOnsetMs(plan: plan, fps: fps);
        final double? shownAt = onset[1];
        if (shownAt == null) continue;
        // 滞后 = 高亮亮起时刻 − 该句真实音频起点；>0 即高亮晚于声音（用户感知的「慢」）。
        final double lateness = shownAt - s;
        if (lateness > worst) worst = lateness;
      }
      return worst;
    }

    test('高亮最大滞后 ≤ Δ/2 = 500/fps（帧中心采样的数学上界）', () {
      // fps=24：上界 500/24≈20.83ms，取整容差 1ms。
      expect(maxLatenessMs(fps: 24), lessThanOrEqualTo(500.0 / 24 + 1.0));
      // fps=12：上界 500/12≈41.67ms。
      expect(maxLatenessMs(fps: 12), lessThanOrEqualTo(500.0 / 12 + 1.0));
    });

    test('提高 fps 把可感知滞后压到阈下：12fps 会 >40ms，24fps ≤21ms', () {
      // 旧行为（12fps）：最坏相位下滞后确实越过 ~40ms（用户可感知「滞后」）。
      expect(
        maxLatenessMs(fps: 12),
        greaterThan(40.0),
        reason: '12fps 帧量化让部分 cue 高亮晚 >40ms，即用户报告的「导出高亮进度慢」',
      );
      // 新行为（24fps）：最坏滞后 ≤21ms，落在人眼音画同步阈值以下。
      expect(
        maxLatenessMs(fps: 24),
        lessThanOrEqualTo(21.0),
        reason: '24fps 把最大滞后压到 ≤Δ/2≈20.8ms，不可感知',
      );
    });

    test('源码守卫：动态导出路径 fps 常量 ≥ 24（防退回 12fps 帧量化滞后）', () {
      final String body = File(
              'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final RegExp fpsDecl = RegExp(r'const int fps = (\d+);');
      final Iterable<RegExpMatch> matches = fpsDecl.allMatches(body);
      expect(matches, isNotEmpty, reason: '未找到导出 fps 常量声明，测试锚点可能已漂移，请更新守卫');
      for (final RegExpMatch m in matches) {
        final int fps = int.parse(m.group(1)!);
        expect(fps, greaterThanOrEqualTo(24),
            reason: 'BUG-713：导出 fps 必须 ≥24 以把逐句高亮滞后压到 ≤Δ/2≈21ms；'
                '回到 12fps 会让约一半 cue 高亮晚最多 ~42ms 重现「进度慢」');
      }
    });
  });
}

AudioCue _cue({
  required int startMs,
  required int endMs,
  int audioFileIndex = 0,
  String text = '文',
}) {
  return AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = 0
    ..textFragmentId = ''
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = audioFileIndex;
}
