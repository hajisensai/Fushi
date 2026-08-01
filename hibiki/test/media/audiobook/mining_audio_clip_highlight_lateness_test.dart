import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_clip_export.dart';
import 'package:hibiki/src/media/audiobook/mining_audio_clip.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import '../../helpers/source_guard.dart';

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
/// 2. 受控来源契约：[clipExportFps] 在 ≤120s 恒返 24fps（BUG-1320 放宽上限后
///    长片段按总帧数预算降 fps，但短片段精度不退）。
/// 3. 源码守卫：动态导出路径 [_synthDynamicClipVideo] 的 fps **来自** [clipExportFps]，
///    并禁止 <24 的裸字面量——防有人改回 12fps 令帧量化滞后回归。
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

    // 受控来源本身的数值契约。BUG-713 真正要守的是「短片段的 Δ 足够小」，而 Δ=1000/fps
    // 由 [clipExportFps] 唯一决定 —— 所以下界断言挂在这个纯函数上，是**行为**判据，
    // 不依赖生产代码写成什么形态。
    test('clipExportFps 契约：≤120s 恒 24fps（Δ≈41.7ms → 最大滞后 ≤21ms）', () {
      for (final int durationMs in <int>[
        0,
        1,
        1000,
        30 * 1000,
        60 * 1000,
        120 * 1000,
      ]) {
        expect(clipExportFps(durationMs: durationMs), 24,
            reason: 'BUG-713：${durationMs}ms 片段的导出 fps 必须是 24；'
                '降到 12 会让约一半 cue 高亮晚最多 ~42ms 重现「进度慢」');
      }
      // BUG-1320 把上限放宽到 300s 后长片段按总帧数预算降 fps —— 允许降，但必须有下界，
      // 且总帧数不超过提限前的既有最坏情况（120s×24fps=2880 帧）。
      final int fps300 = clipExportFps(durationMs: 300 * 1000);
      expect(fps300, greaterThanOrEqualTo(6), reason: '长片段 fps 仍需有下界，不能降到不可看');
      expect(fps300 * 300, lessThanOrEqualTo(2880),
          reason: '总帧数必须落在 2880 预算内（序列帧落盘量 = 提限前的最坏情况）');
    });

    // 源码守卫锚在**契约**上，不锚实现写法。
    // 旧写法 `RegExp(r'const int fps = (\d+);')` + `expect(matches, isNotEmpty)` 是典型的
    // 「要求型字面量锚点」：BUG-1320 把生产代码从 `const int fps = 24;` 改成
    // `final int fps = clipExportFps(...)` 后匹配集直接变空、当场红 —— 那不是行为退化，
    // 是守卫自身塌掉（换匹配器也救不了，因为被锚的对象本身消失了）。
    // 新判据：动态导出路径的 fps 必须**由受控来源 clipExportFps 派生**（数值下界由上面
    // 那条行为断言钉住），并禁止任何把 fps 直接钉成 <24 字面量的写法。
    test('源码守卫：动态导出 fps 来自 clipExportFps，且无 <24 的裸字面量', () {
      final String src = File(
              'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final String body =
          methodBody(src, 'Future<bool> _synthDynamicClipVideo(');
      expect(
        containsIdentifierCall(body, 'clipExportFps'),
        isTrue,
        reason: 'BUG-713/BUG-1320：动态导出路径的 fps 必须来自受控来源 clipExportFps(...)，'
            '不得回到裸字面量。改名 clipExportFps 请同步本守卫与上面的行为断言',
      );
      // 禁止型判据：允许零命中（当前实现就是零），一旦命中就必须 ≥24。
      final RegExp literalFps = RegExp(r'\bint\s+fps\s*=\s*(\d+)\s*;');
      for (final RegExpMatch m in literalFps.allMatches(body)) {
        expect(int.parse(m.group(1)!), greaterThanOrEqualTo(24),
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
