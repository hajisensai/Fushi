// issue #3405：歌曲制卡的句子音频按播放时听到的响度截（与播放同一份 ReplayGain，缺数据时
// 测这一段），而不是源文件的原始电平。
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/music/music_clip_gain.dart';
import 'package:fushi/src/media/music/music_loudness_scanner.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';

MusicPlayItem _item({
  double? trackGain,
  double? trackPeak,
  double? albumGain,
  double? albumPeak,
}) => MusicPlayItem(
  trackUid: 'uid-1',
  path: '/music/song.flac',
  title: 'Song',
  rgTrackGain: trackGain,
  rgTrackPeak: trackPeak,
  rgAlbumGain: albumGain,
  rgAlbumPeak: albumPeak,
);

MusicOutputSettings _settings(
  MusicReplayGainMode mode, {
  double preampDb = 0,
  double volume = 100,
}) => MusicOutputSettings(
  gapless: true,
  replayGain: mode,
  replayGainPreampDb: preampDb,
  volume: volume,
);

void main() {
  group('musicClipKnownGainDb', () {
    test('ReplayGain 关：0 dB（播放也是原始电平），不看曲目数据', () {
      expect(
        musicClipKnownGainDb(
          item: _item(trackGain: -8),
          settings: _settings(MusicReplayGainMode.off),
        ),
        0,
      );
      expect(
        musicClipKnownGainDb(
          item: _item(),
          settings: _settings(MusicReplayGainMode.off),
        ),
        0,
      );
    });

    test('曲目模式：track gain + preamp', () {
      expect(
        musicClipKnownGainDb(
          item: _item(trackGain: -8.5, albumGain: -6),
          settings: _settings(MusicReplayGainMode.track, preampDb: 2),
        ),
        closeTo(-6.5, 1e-9),
      );
    });

    test('专辑模式：album gain 优先', () {
      expect(
        musicClipKnownGainDb(
          item: _item(trackGain: -8.5, albumGain: -6),
          settings: _settings(MusicReplayGainMode.album),
        ),
        closeTo(-6, 1e-9),
      );
    });

    test('峰值限幅与播放同口径：增益不让峰值超过 0 dBFS', () {
      // peak 0.5 → 最多 +6.02 dB。
      expect(
        musicClipKnownGainDb(
          item: _item(trackGain: 10, trackPeak: 0.5),
          settings: _settings(MusicReplayGainMode.track),
        ),
        closeTo(6.0206, 1e-3),
      );
    });

    test('音量滑块不进片段增益', () {
      final MusicPlayItem item = _item(trackGain: -8);
      expect(
        musicClipKnownGainDb(
          item: item,
          settings: _settings(MusicReplayGainMode.track, volume: 25),
        ),
        musicClipKnownGainDb(
          item: item,
          settings: _settings(MusicReplayGainMode.track),
        ),
      );
    });

    test('ReplayGain 开但没有任何增益数据 → null（去测片段）', () {
      expect(
        musicClipKnownGainDb(
          item: _item(),
          settings: _settings(MusicReplayGainMode.track),
        ),
        isNull,
      );
    });
  });

  group('musicClipGainFromMeasurement', () {
    test('归一到 -18 LUFS + preamp', () {
      expect(
        musicClipGainFromMeasurement(
          const MusicLoudnessMeasurement(
            integratedLufs: -9,
            truePeakDbtp: -0.3,
          ),
          preampDb: 1,
        ),
        closeTo(-8, 1e-9),
      );
    });

    test('安静片段的正增益按真峰值限幅到 0 dBTP', () {
      expect(
        musicClipGainFromMeasurement(
          const MusicLoudnessMeasurement(integratedLufs: -30, truePeakDbtp: -4),
          preampDb: 0,
        ),
        closeTo(4, 1e-9),
      );
    });

    test('静音测不出 → null', () {
      expect(
        musicClipGainFromMeasurement(
          const MusicLoudnessMeasurement(
            integratedLufs: -70,
            truePeakDbtp: null,
          ),
          preampDb: 0,
        ),
        isNull,
      );
    });
  });

  test('musicClipEbur128Args：测的就是要裁的那一段', () {
    expect(
      musicClipEbur128Args(
        inputPath: '/music/song.flac',
        startMs: 3500,
        endMs: 8500,
      ),
      <String>[
        '-hide_banner',
        '-nostats',
        '-ss',
        '3.500',
        '-t',
        '5.000',
        '-i',
        '/music/song.flac',
        '-vn',
        '-filter:a',
        'ebur128=peak=true',
        '-f',
        'null',
        '-',
      ],
    );
  });

  group('resolveMusicClipGainDb', () {
    test('有增益数据时不测', () async {
      int calls = 0;
      final double db = await resolveMusicClipGainDb(
        item: _item(trackGain: -7),
        settings: _settings(MusicReplayGainMode.track),
        inputPath: '/music/song.flac',
        httpHeaders: const <String, String>{},
        startMs: 0,
        endMs: 1000,
        measurer:
            ({
              required String inputPath,
              required Map<String, String> httpHeaders,
              required int startMs,
              required int endMs,
            }) async {
              calls++;
              return null;
            },
      );
      expect(db, closeTo(-7, 1e-9));
      expect(calls, 0);
    });

    test('缺数据时测片段（同一源、同一段、同一组请求头）', () async {
      final List<Object> seen = <Object>[];
      final double db = await resolveMusicClipGainDb(
        item: _item(),
        settings: _settings(MusicReplayGainMode.track, preampDb: -1),
        inputPath: 'https://cdn.example/track.m4a',
        httpHeaders: const <String, String>{'Referer': 'https://example'},
        startMs: 3500,
        endMs: 8500,
        measurer:
            ({
              required String inputPath,
              required Map<String, String> httpHeaders,
              required int startMs,
              required int endMs,
            }) async {
              seen.addAll(<Object>[inputPath, httpHeaders, startMs, endMs]);
              return const MusicLoudnessMeasurement(
                integratedLufs: -8,
                truePeakDbtp: 0.2,
              );
            },
      );
      expect(seen, <Object>[
        'https://cdn.example/track.m4a',
        const <String, String>{'Referer': 'https://example'},
        3500,
        8500,
      ]);
      expect(db, closeTo(-11, 1e-9));
    });

    test('测不出 → 0 dB（片段照常写卡）', () async {
      final double db = await resolveMusicClipGainDb(
        item: _item(),
        settings: _settings(MusicReplayGainMode.track),
        inputPath: '/music/song.flac',
        httpHeaders: const <String, String>{},
        startMs: 0,
        endMs: 1000,
        measurer:
            ({
              required String inputPath,
              required Map<String, String> httpHeaders,
              required int startMs,
              required int endMs,
            }) async => null,
      );
      expect(db, 0);
    });
  });
}
