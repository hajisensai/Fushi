import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/mining/mining_playback_volume_gain.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// 反馈 d7mXlstcv9（issue #3405）：制卡句子音频跟随播放音量，默认开。
///
/// 锁住：
/// 1. 增益换算（纯函数）：mpv 立方曲线 / 线性曲线、静音不烤进卡、歌曲叠加与播放同一份
///    ReplayGain（没有增益数据时 0 dB，与播放端一致）、开关关 → null；
/// 2. 偏好默认**开** + 写穿 Drift + key 在白名单；
/// 3. 有声书制卡调用点把增益喂给 `extractAudioSegment`；设置页 / 搜索 / 操作目录三处都挂了开关；
/// 4. 统一 FFmpeg 能力清单编入 `volume` 滤镜。
///
/// 歌曲制卡调用点由 `test/pages/music_lyrics_page_test.dart` 端到端钉住（音量 50 →
/// -18.06 dB，关掉 → null）。

FushiDatabase _testDb() {
  return FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
}

MusicPlayItem _item({double? trackGain, double? trackPeak}) => MusicPlayItem(
  trackUid: 'uid',
  path: '/music/song.flac',
  title: 'song',
  rgTrackGain: trackGain,
  rgTrackPeak: trackPeak,
);

void main() {
  group('增益换算', () {
    test('mpv 立方曲线：100 不变，50 ≈ -18.06 dB，130 ≈ +6.84 dB', () {
      expect(playbackVolumeGainDb(100, PlaybackVolumeCurve.mpvCubic), 0);
      expect(
        playbackVolumeGainDb(50, PlaybackVolumeCurve.mpvCubic),
        closeTo(-18.06, 0.01),
      );
      expect(
        playbackVolumeGainDb(130, PlaybackVolumeCurve.mpvCubic),
        closeTo(6.84, 0.01),
      );
    });

    test('线性曲线：1 不变，0.5 ≈ -6.02 dB', () {
      expect(playbackVolumeGainDb(1, PlaybackVolumeCurve.linear), 0);
      expect(
        playbackVolumeGainDb(0.5, PlaybackVolumeCurve.linear),
        closeTo(-6.02, 0.01),
      );
    });

    test('静音 / 负数 / 非有限：不烤进卡（0 dB）', () {
      for (final PlaybackVolumeCurve c in PlaybackVolumeCurve.values) {
        expect(playbackVolumeGainDb(0, c), 0);
        expect(playbackVolumeGainDb(-5, c), 0);
        expect(playbackVolumeGainDb(double.nan, c), 0);
        expect(playbackVolumeGainDb(double.infinity, c), 0);
      }
    });

    test('歌曲：ReplayGain（与播放同一份）+ 音量滑块', () {
      const MusicOutputSettings settings = MusicOutputSettings(
        gapless: false,
        replayGain: MusicReplayGainMode.track,
        replayGainPreampDb: 0,
        volume: 50,
      );
      expect(
        musicMiningClipGainDb(
          followPlayback: true,
          item: _item(trackGain: -8),
          settings: settings,
        ),
        closeTo(-8 - 18.06, 0.01),
      );
      expect(
        musicMiningClipGainDb(
          followPlayback: true,
          item: _item(),
          settings: settings,
        ),
        closeTo(-18.06, 0.01),
        reason: '没有增益数据：播放端 ReplayGain 为 0 dB，卡也不另测片段响度',
      );
    });

    test('歌曲：ReplayGain 关时只跟音量滑块', () {
      expect(
        musicMiningClipGainDb(
          followPlayback: true,
          item: _item(trackGain: -8),
          settings: const MusicOutputSettings(
            gapless: false,
            replayGain: MusicReplayGainMode.off,
            volume: 100,
          ),
        ),
        0,
      );
    });

    test('开关关 → null（原始电平，ffmpeg 参数逐字节不变）', () {
      expect(
        musicMiningClipGainDb(
          followPlayback: false,
          item: _item(trackGain: -8),
          settings: const MusicOutputSettings(
            gapless: false,
            replayGain: MusicReplayGainMode.track,
            volume: 50,
          ),
        ),
        isNull,
      );
      expect(
        audiobookMiningClipGainDb(
          followPlayback: false,
          volume: 0.5,
          curve: PlaybackVolumeCurve.linear,
        ),
        isNull,
      );
    });

    test('有声书：just_audio 0～2 刻度；mpv 后端按 ×100 后再套立方曲线', () {
      expect(
        audiobookMiningClipGainDb(
          followPlayback: true,
          volume: 0.5,
          curve: PlaybackVolumeCurve.linear,
        ),
        closeTo(-6.02, 0.01),
      );
      expect(
        audiobookMiningClipGainDb(
          followPlayback: true,
          volume: 0.5,
          curve: PlaybackVolumeCurve.mpvCubic,
        ),
        closeTo(-18.06, 0.01),
      );
      expect(
        audiobookMiningClipGainDb(
          followPlayback: true,
          volume: null,
          curve: PlaybackVolumeCurve.linear,
        ),
        isNull,
        reason: '没有播放器',
      );
    });
  });

  group('偏好层', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = _testDb();
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      await repo.setPref('_drain_pending_writes', 1);
      repo.dispose();
      await db.close();
    });

    test('默认开（维护者拍板）', () {
      expect(repo.miningAudioFollowPlaybackVolume, isTrue);
    });

    test('toggle 写穿 Drift', () async {
      repo.toggleMiningAudioFollowPlaybackVolume();
      expect(repo.miningAudioFollowPlaybackVolume, isFalse);
      await repo.setPref('mining_audio_follow_playback_volume', false);
      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.miningAudioFollowPlaybackVolume, isFalse);
      restored.dispose();
    });

    test('key 在偏好白名单里', () {
      expect(
        kKnownPreferenceKeys,
        contains('mining_audio_follow_playback_volume'),
      );
    });
  });

  group('调用点源码守卫', () {
    test('有声书制卡：开关 + 控制器实时音量 → gainDb 喂给裁剪', () {
      final String src = File(
        'lib/src/pages/implementations/reader_fushi/mining.part.dart',
      ).readAsStringSync();
      expect(
        src,
        contains('followPlayback: appModel.miningAudioFollowPlaybackVolume'),
      );
      expect(src, contains('volume: _audiobookController?.volume'));
      expect(src, contains('gainDb: sentenceAudioGainDb,'));
    });

    test('TtsChannel.extractAudioSegment 透传 gainDb', () {
      final String src = File(
        'lib/src/utils/misc/tts_channel.dart',
      ).readAsStringSync();
      expect(src, contains('double? gainDb,'));
      expect(src, contains('gainDb: gainDb,'));
    });

    test('设置页开关行、搜索条目、操作目录三处都挂上', () {
      const String id =
          'card_creation.anki.mining_audio_follow_playback_volume';
      final String page = File(
        'lib/src/pages/implementations/anki_settings_page.dart',
      ).readAsStringSync();
      expect(page, contains("id: '$id'"));
      expect(page, contains('value: appModel.miningAudioFollowPlaybackVolume'));
      expect(
        page,
        contains('appModel.toggleMiningAudioFollowPlaybackVolume()'),
      );
      final String schema = File(
        'lib/src/settings/settings_schema_card_creation.dart',
      ).readAsStringSync();
      expect(schema, contains("id: '$id'"));
      final String ctl = File(
        'lib/src/ops/ctl_settings_body_anki.dart',
      ).readAsStringSync();
      expect(ctl, contains("_id('mining_audio_follow_playback_volume')"));
    });

    test('统一 FFmpeg 能力清单编入 volume', () {
      final Map<String, dynamic> caps =
          jsonDecode(
                File(
                  '../tool/ffmpeg-unified/capabilities.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(
        caps['filters'] as List<dynamic>?,
        contains('volume'),
        reason: '制卡的 -af volume 在精简构建里缺滤镜就整条 ffmpeg 失败',
      );
    });
  });
}
