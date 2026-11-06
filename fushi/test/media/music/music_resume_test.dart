// 音乐逐曲断点续播的纯判定（反馈 QAondMh4M5）：模式门 + 复用视频的续播意图分类。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/mpv_music_output_backend.dart';
import 'package:fushi/src/media/music/music_resume.dart';
import 'package:fushi/src/media/video/video_episode_start_policy.dart';

void main() {
  const int min = 60000;

  Duration start(
    MusicResumeMode mode, {
    EpisodeStartIntent intent = EpisodeStartIntent.listSelect,
    int? saved,
    int? duration,
  }) => resolveMusicResumeStart(
    mode: mode,
    intent: intent,
    savedPositionMs: saved,
    durationMs: duration,
  );

  test('模式门：关一律从头；长曲目只给 ≥ 8 分钟或时长未知的；全部都给', () {
    expect(
      start(MusicResumeMode.off, saved: 5 * min, duration: 60 * min),
      Duration.zero,
    );
    expect(
      start(MusicResumeMode.longTracks, saved: min, duration: 4 * min),
      Duration.zero,
      reason: '歌曲每次从头放',
    );
    expect(
      start(MusicResumeMode.longTracks, saved: min, duration: 8 * min),
      const Duration(minutes: 1),
    );
    expect(
      start(MusicResumeMode.longTracks, saved: min, duration: null),
      const Duration(minutes: 1),
      reason: '时长未知按长曲目',
    );
    expect(
      start(MusicResumeMode.all, saved: min, duration: 4 * min),
      const Duration(minutes: 1),
    );
    expect(
      start(MusicResumeMode.all, saved: null, duration: 4 * min),
      Duration.zero,
      reason: '没有断点',
    );
  });

  test('意图与视频同一套：上一首 / 自动连播从头，点开 / 下一首 / 初次打开续播', () {
    for (final EpisodeStartIntent i in <EpisodeStartIntent>[
      EpisodeStartIntent.manualPrevious,
      EpisodeStartIntent.autoAdvance,
    ]) {
      expect(
        start(MusicResumeMode.all, intent: i, saved: min, duration: 60 * min),
        Duration.zero,
        reason: '$i',
      );
    }
    for (final EpisodeStartIntent i in <EpisodeStartIntent>[
      EpisodeStartIntent.listSelect,
      EpisodeStartIntent.manualNext,
      EpisodeStartIntent.initialOpen,
    ]) {
      expect(
        start(MusicResumeMode.all, intent: i, saved: min, duration: 60 * min),
        const Duration(minutes: 1),
        reason: '$i',
      );
    }
  });

  test('片尾区按纯音频的 98%：60 分钟广播剧停在 55 分钟仍续播，59 分钟从头', () {
    expect(
      start(MusicResumeMode.all, saved: 55 * min, duration: 60 * min),
      const Duration(minutes: 55),
      reason: '视频的 90% 会在这里从头放',
    );
    expect(
      start(MusicResumeMode.all, saved: 59 * min, duration: 60 * min),
      Duration.zero,
    );
    // 剩余 ≤ 3 秒的下限与视频共用（短曲目上比例还没到也算听完）。
    expect(
      start(MusicResumeMode.all, saved: 57000, duration: 60000),
      Duration.zero,
    );
    expect(
      start(MusicResumeMode.all, saved: 50000, duration: 60000),
      const Duration(seconds: 50),
    );
    // 视频口径不受影响。
    expect(
      resolveEpisodeStart(EpisodeStartIntent.listSelect, 55 * min, 60 * min),
      0,
    );
  });

  test('写入侧与读取侧同一判据：读时会从头放的位置写时删行', () {
    for (final (int pos, int? dur) c in <(int, int?)>[
      (0, 60 * min),
      (55 * min, 60 * min),
      (59 * min, 60 * min),
      (57000, 60000),
      (50000, 60000),
      (30000, null),
    ]) {
      final bool finished = musicResumePointIsFinished(
        positionMs: c.$1,
        durationMs: c.$2,
      );
      expect(
        finished,
        start(MusicResumeMode.all, saved: c.$1, duration: c.$2) ==
            Duration.zero,
        reason: '$c',
      );
      expect(
        musicResumeDisplayStart(
          mode: MusicResumeMode.all,
          savedPositionMs: c.$1,
          durationMs: c.$2,
        ),
        finished ? isNull : Duration(milliseconds: c.$1),
      );
    }
  });

  test('wire 值冻结；不认识的回到长曲目', () {
    expect(
      MusicResumeMode.values.map((MusicResumeMode m) => m.wire).toList(),
      <String>['off', 'long_tracks', 'all'],
    );
    expect(MusicResumeMode.fromWire('all'), MusicResumeMode.all);
    expect(MusicResumeMode.fromWire('bogus'), MusicResumeMode.longTracks);
    expect(MusicResumeMode.fromWire(null), MusicResumeMode.longTracks);
  });

  test('mpv 逐文件起点：普通文件 / EDL 段直接写 start，CD 盘时间轴在本曲起点上加', () {
    expect(
      musicFileLocalWithStart(const <String, String>{}, Duration.zero),
      isEmpty,
    );
    expect(
      musicFileLocalWithStart(
        const <String, String>{},
        const Duration(minutes: 1, milliseconds: 500),
      ),
      <String, String>{'start': '60.500000000'},
    );
    final Map<String, String> cd = musicCddaFileLocal(
      startMs: 120000,
      endMs: 180000,
    );
    final Map<String, String> resumed = musicFileLocalWithStart(
      cd,
      const Duration(seconds: 30),
    );
    expect(
      double.parse(resumed['start']!),
      closeTo(double.parse(cd['start']!) + 30, 1e-9),
    );
    expect(resumed['end'], cd['end'], reason: '终点不动');
    expect(resumed['vid'], 'no');
  });
}
