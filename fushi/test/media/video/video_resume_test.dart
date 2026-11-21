import 'package:test/test.dart';
import 'package:fushi/src/media/video/video_episode_start_policy.dart';
import 'package:fushi/src/media/video/video_resume.dart';

/// 拍板台 IVRHvZ3pmd：视频断点续播开关（三档，与音乐 `music_resume_mode` 对齐）。
void main() {
  const int min = 60000;

  int start(
    VideoResumeMode mode, {
    EpisodeStartIntent intent = EpisodeStartIntent.initialOpen,
    int saved = 5 * min,
    int? duration = 24 * min,
  }) => resolveVideoStart(
    intent: intent,
    savedPositionMs: saved,
    durationMs: duration,
    mode: mode,
  );

  test('关：按断点定起点的意图一律从头', () {
    for (final EpisodeStartIntent intent in <EpisodeStartIntent>[
      EpisodeStartIntent.initialOpen,
      EpisodeStartIntent.manualNext,
      EpisodeStartIntent.listSelect,
    ]) {
      expect(start(VideoResumeMode.off, intent: intent), 0, reason: '$intent');
    }
  });

  test('关：制卡回看 / 画质重载等明确起点（explicitCue）不受开关影响', () {
    expect(
      start(VideoResumeMode.off, intent: EpisodeStartIntent.explicitCue),
      5 * min,
    );
  });

  test('全部（默认）：与加开关前的 resolveEpisodeStart 完全一致', () {
    for (final EpisodeStartIntent intent in EpisodeStartIntent.values) {
      for (final int? duration in <int?>[null, 0, 3 * min, 24 * min]) {
        for (final int saved in <int>[-1, 0, 2 * min, 23 * min]) {
          expect(
            start(
              VideoResumeMode.all,
              intent: intent,
              saved: saved,
              duration: duration,
            ),
            resolveEpisodeStart(intent, saved, duration),
            reason: '$intent saved=$saved duration=$duration',
          );
        }
      }
    }
  });

  test('长视频：≥ 10 分钟续播，短视频从头，时长未知先按长视频（open 后复核）', () {
    expect(start(VideoResumeMode.longVideos, saved: min, duration: 4 * min), 0);
    expect(
      start(VideoResumeMode.longVideos, saved: min, duration: 10 * min),
      min,
    );
    expect(start(VideoResumeMode.longVideos, saved: min, duration: null), min);
    expect(start(VideoResumeMode.longVideos, saved: min, duration: 0), min);
  });

  test('开着时片尾区仍从头（沿用 resolveEpisodeStart 的判据）', () {
    expect(start(VideoResumeMode.all, saved: 23 * min + 50000), 0);
  });

  test('wire 值冻结，未知值回到默认「全部」', () {
    expect(VideoResumeMode.off.wire, 'off');
    expect(VideoResumeMode.longVideos.wire, 'long_videos');
    expect(VideoResumeMode.all.wire, 'all');
    for (final VideoResumeMode m in VideoResumeMode.values) {
      expect(VideoResumeMode.fromWire(m.wire), m);
    }
    expect(VideoResumeMode.fromWire(null), VideoResumeMode.all);
    expect(VideoResumeMode.fromWire('bogus'), VideoResumeMode.all);
  });
}
