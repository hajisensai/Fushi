import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/mining_audio_clip.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

/// TODO-1115 动态高亮片段视频：逐帧渲染计划 [clipFramePlan] 的纯函数守卫。
///
/// 覆盖：每帧 highlightCueIndex 正确、帧总数 = 时长×fps、句边界切换时刻精确、相邻同句
/// 帧合并计数、单句退化、句间 gap 策略（holdPrevious / none）。
void main() {
  group('clipFramePlan', () {
    test('single cue: all frames highlight index 0, merged into one run', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 1000),
      ];
      // fps=10 → 100ms/frame；[0,1000) → ceil(1000/100)=10 帧，全部落在 cue 0。
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 1000,
        fps: 10,
      );
      expect(plan.length, 1);
      expect(plan.first.highlightCueIndex, 0);
      expect(plan.first.frameCount, 10);
    });

    test('frame count = ceil(durationMs / (1000/fps))', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 2500),
      ];
      // fps=12 → 1000/12≈83.33ms/frame；2500/83.33 = 30 → ceil 30 帧。
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 2500,
        fps: 12,
      );
      final int total =
          plan.fold<int>(0, (int acc, ClipFrameSpec s) => acc + s.frameCount);
      expect(total, 30);
    });

    test('two cues: highlight switches exactly at the boundary', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 500),
        _cue(startMs: 500, endMs: 1000),
      ];
      // fps=10 → 100ms/frame。t=0,100,200,300,400 → cue0（5 帧）；
      // t=500,600,700,800,900 → cue1（5 帧）。
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 1000,
        fps: 10,
      );
      expect(plan.length, 2);
      expect(plan[0].highlightCueIndex, 0);
      expect(plan[0].frameCount, 5);
      expect(plan[1].highlightCueIndex, 1);
      expect(plan[1].frameCount, 5);
    });

    test(
        'mid-frame cue start switches on the covering frame '
        '(early, never late; TODO-1147)', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 250),
        _cue(startMs: 250, endMs: 900),
      ];
      // fps=10 → 100ms/frame，帧尾采样。cue1 起点 250ms 落在第 2 帧显示区间
      // [200,300) 内 → 第 2 帧就切换（提前 50ms），绝不等到第 3 帧（迟 50ms）。
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 900,
        fps: 10,
      );
      expect(plan.length, 2);
      expect(plan[0], const ClipFrameSpec(highlightCueIndex: 0, frameCount: 2));
      expect(plan[1], const ClipFrameSpec(highlightCueIndex: 1, frameCount: 7));
    });

    test(
        '12fps: switch frame covers the cue start (frame 12 for a 1040ms '
        'cue start), never one frame late (TODO-1147)', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 1040),
        _cue(startMs: 1040, endMs: 2000),
      ];
      // fps=12 → Δ≈83.33ms，总帧数 ceil(2000/83.33)=24。cue1 起点 1040ms 落在
      // 第 12 帧显示区间 [1000,1083) 内 → 第 12 帧切换（提前 40ms）；旧的帧起点
      // 采样要等第 13 帧（1083ms 起，迟 43ms）——这正是 12fps 量化「只迟不早」
      // 的迟钝方向，本用例钉死新方向。
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 2000,
        fps: 12,
      );
      expect(plan.length, 2);
      expect(
          plan[0], const ClipFrameSpec(highlightCueIndex: 0, frameCount: 12));
      expect(
          plan[1], const ClipFrameSpec(highlightCueIndex: 1, frameCount: 12));
    });

    test('adjacent same-index frames merge into one run', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 300),
        _cue(startMs: 300, endMs: 900),
      ];
      // fps=10 → 100ms/frame。t=0,100,200 → cue0（3 帧合并）；
      // t=300..800 → cue1（6 帧合并）。总 9 帧。
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 900,
        fps: 10,
      );
      expect(plan.length, 2);
      expect(plan[0], const ClipFrameSpec(highlightCueIndex: 0, frameCount: 3));
      expect(plan[1], const ClipFrameSpec(highlightCueIndex: 1, frameCount: 6));
    });

    test('gap between cues holds previous cue by default (holdPrevious)', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 300),
        // gap [300, 600)
        _cue(startMs: 600, endMs: 900),
      ];
      // fps=10。t=0,100,200 → cue0；t=300,400,500 → gap（保持上一句 cue0）；
      // t=600,700,800 → cue1。gap 帧被并入 cue0 的 run（相邻同 index 合并）。
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 900,
        fps: 10,
        gapHighlight: ClipGapHighlight.holdPrevious,
      );
      // cue0（3 帧）+ gap 保持 cue0（3 帧）合并 = 6 帧，然后 cue1（3 帧）。
      expect(plan.length, 2);
      expect(plan[0], const ClipFrameSpec(highlightCueIndex: 0, frameCount: 6));
      expect(plan[1], const ClipFrameSpec(highlightCueIndex: 1, frameCount: 3));
    });

    test('gap with ClipGapHighlight.none yields a -1 (no-highlight) run', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 300),
        _cue(startMs: 600, endMs: 900),
      ];
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 900,
        fps: 10,
        gapHighlight: ClipGapHighlight.none,
      );
      // cue0（3）→ gap 无高亮 -1（3）→ cue1（3）。
      expect(plan.length, 3);
      expect(plan[0], const ClipFrameSpec(highlightCueIndex: 0, frameCount: 3));
      expect(
          plan[1], const ClipFrameSpec(highlightCueIndex: -1, frameCount: 3));
      expect(plan[2], const ClipFrameSpec(highlightCueIndex: 1, frameCount: 3));
    });

    test('leading head-padding before first cue has no previous → -1', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 200, endMs: 600),
      ];
      // global 从 0 起（head padding），首两帧 t=0,100 在 cue 之前无上一句 → -1；
      // t=200..500 → cue0。
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: 0,
        globalEndMs: 600,
        fps: 10,
      );
      expect(plan.length, 2);
      expect(plan[0].highlightCueIndex, -1);
      expect(plan[0].frameCount, 2);
      expect(plan[1].highlightCueIndex, 0);
      expect(plan[1].frameCount, 4);
    });

    test('empty cues / invalid fps / non-positive window → empty plan', () {
      expect(
        clipFramePlan(
            cues: const <AudioCue>[],
            globalStartMs: 0,
            globalEndMs: 1000,
            fps: 12),
        isEmpty,
      );
      expect(
        clipFramePlan(
            cues: <AudioCue>[_cue(startMs: 0, endMs: 100)],
            globalStartMs: 0,
            globalEndMs: 100,
            fps: 0),
        isEmpty,
      );
      expect(
        clipFramePlan(
            cues: <AudioCue>[_cue(startMs: 0, endMs: 100)],
            globalStartMs: 500,
            globalEndMs: 500,
            fps: 12),
        isEmpty,
      );
    });

    test('sum of frameCount always equals the total frame count', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(startMs: 0, endMs: 400),
        _cue(startMs: 400, endMs: 700),
        _cue(startMs: 700, endMs: 1300),
      ];
      const int fps = 12;
      const int start = 0;
      const int end = 1300;
      final List<ClipFrameSpec> plan = clipFramePlan(
        cues: cues,
        globalStartMs: start,
        globalEndMs: end,
        fps: fps,
      );
      const double msPerFrame = 1000.0 / fps;
      final int expectedFrames = ((end - start) / msPerFrame).ceil();
      final int total =
          plan.fold<int>(0, (int acc, ClipFrameSpec s) => acc + s.frameCount);
      expect(total, expectedFrames);
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
    ..bookKey = 'book'
    ..chapterHref = 'chapter.xhtml'
    ..sentenceIndex = 0
    ..textFragmentId = '#s0'
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = audioFileIndex;
}
