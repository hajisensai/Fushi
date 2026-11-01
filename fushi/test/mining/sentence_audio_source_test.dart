import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preference_keys.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_anki/fushi_anki_core.dart' show MiningRequestOverrides;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/mining/sentence_audio_source.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart';

/// 视频制卡句子音频来源（反馈 pNF2ZL7Kfc）：ffmpeg 参数、来源决策与回退、wire 往返、
/// 偏好落盘。全部纯函数 / 内存库，不依赖 ffmpeg。
void main() {
  group('buildFfmpegClipArgs 中置声道', () {
    List<String> clip({
      bool? frontCenterOnly,
      double? tempo,
      int audioChannels = 1,
      int? audioStreamIndex,
      int? audioStreamCount,
    }) => frontCenterOnly == null
        ? buildFfmpegClipArgs(
            inputPath: '/v/ep.mkv',
            startMs: 1000,
            endMs: 2500,
            outputPath: '/t/out.aac',
            tempo: tempo,
            audioChannels: audioChannels,
            audioStreamIndex: audioStreamIndex,
            audioStreamCount: audioStreamCount,
          )
        : buildFfmpegClipArgs(
            inputPath: '/v/ep.mkv',
            startMs: 1000,
            endMs: 2500,
            outputPath: '/t/out.aac',
            tempo: tempo,
            audioChannels: audioChannels,
            audioStreamIndex: audioStreamIndex,
            audioStreamCount: audioStreamCount,
            frontCenterOnly: frontCenterOnly,
          );

    test('默认（不传 / 传 false）与改动前逐字节相同', () {
      const List<String> before = <String>[
        '-y',
        '-ss',
        '1.000',
        '-t',
        '1.500',
        '-i',
        '/v/ep.mkv',
        '-vn',
        '-map_chapters',
        '-1',
        '-c:a',
        'aac',
        '-ac',
        '1',
        '-b:a',
        '64k',
        '/t/out.aac',
      ];
      expect(clip(), before);
      expect(clip(frontCenterOnly: false), before);
      expect(
        clip(frontCenterOnly: false, audioChannels: 2),
        clip(audioChannels: 2),
      );
      expect(clip(frontCenterOnly: false, tempo: 1.5), clip(tempo: 1.5));
    });

    test('只取中置：-af pan=mono|c0=FC，放在编码器之前', () {
      final List<String> args = clip(frontCenterOnly: true);
      final int af = args.indexOf('-af');
      expect(af, greaterThan(0));
      expect(args[af + 1], 'pan=mono|c0=FC');
      expect(af, lessThan(args.indexOf('-c:a')));
    });

    test('中置 + 倍速串成同一条 -af 链（先 pan 再 atempo）', () {
      final List<String> args = clip(frontCenterOnly: true, tempo: 1.5);
      expect(args.where((String a) => a == '-af'), hasLength(1));
      expect(args[args.indexOf('-af') + 1], 'pan=mono|c0=FC,atempo=1.500');
    });

    test('中置时 -ac 恒为 1（高保真档的 2 声道也压成 1）', () {
      final List<String> args = clip(frontCenterOnly: true, audioChannels: 2);
      expect(args[args.indexOf('-ac') + 1], '1');
    });

    test('指定音轨：-map 0:a:N?；越界不加 -map（BUG-345）', () {
      final List<String> mapped = clip(
        audioStreamIndex: 2,
        audioStreamCount: 3,
      );
      expect(mapped[mapped.indexOf('-map') + 1], '0:a:2?');
      expect(
        clip(audioStreamIndex: 3, audioStreamCount: 3),
        isNot(contains('-map')),
      );
      final List<String> center = clip(
        frontCenterOnly: true,
        audioStreamIndex: 1,
        audioStreamCount: 2,
      );
      expect(center[center.indexOf('-map') + 1], '0:a:1?');
      expect(center[center.indexOf('-af') + 1], 'pan=mono|c0=FC');
    });

    test('buildFfmpegSentenceAudioFilter：都不要时 null', () {
      expect(buildFfmpegSentenceAudioFilter(), isNull);
      expect(buildFfmpegSentenceAudioFilter(tempo: 1.0), isNull);
      expect(
        buildFfmpegSentenceAudioFilter(tempo: 0.8),
        buildFfmpegAtempoFilter(0.8),
      );
      expect(
        buildFfmpegSentenceAudioFilter(frontCenterOnly: true),
        kFfmpegFrontCenterFilter,
      );
    });
  });

  group('ffprobe 声道布局探测', () {
    test('参数：只选那条音轨、只要声道字段、JSON', () {
      expect(
        buildFfprobeAudioChannelLayoutArgs(
          inputPath: '/v/ep.mkv',
          audioStreamIndex: 1,
        ),
        <String>[
          '-v',
          'error',
          '-select_streams',
          'a:1',
          '-show_entries',
          'stream=channels,channel_layout',
          '-of',
          'json',
          '/v/ep.mkv',
        ],
      );
    });

    test('解析：取首条流；坏输入两者皆 null', () {
      final ({String? layout, int? channels}) ok =
          parseFfprobeAudioChannelLayout(
            jsonEncode(<String, Object?>{
              'streams': <Object?>[
                <String, Object?>{'channels': 6, 'channel_layout': '5.1(side)'},
              ],
            }),
          );
      expect(ok.layout, '5.1(side)');
      expect(ok.channels, 6);
      final ({String? layout, int? channels}) bad =
          parseFfprobeAudioChannelLayout('not json');
      expect(bad.layout, isNull);
      expect(bad.channels, isNull);
      final ({String? layout, int? channels}) empty =
          parseFfprobeAudioChannelLayout('{"streams":[]}');
      expect(empty.layout, isNull);
    });
  });

  group('channelLayoutHasFrontCenter', () {
    test('具名多声道布局含 FC', () {
      for (final String layout in <String>[
        '5.1',
        '5.1(side)',
        '7.1',
        '3.0',
        '6.1',
        '7.1(wide-side)',
        '5.1.4',
      ]) {
        expect(channelLayoutHasFrontCenter(layout), isTrue, reason: layout);
      }
    });

    test('立体声 / 单声道 / quad 等确定没有 FC', () {
      for (final String layout in <String>[
        'stereo',
        'mono',
        'quad',
        '2.1',
        '3.0(back)',
        '6.0(front)',
      ]) {
        expect(channelLayoutHasFrontCenter(layout), isFalse, reason: layout);
      }
    });

    test('显式声道表：ffprobe 的 + 写法与 mpv 的 - 写法', () {
      expect(channelLayoutHasFrontCenter('FL+FR+FC+LFE+BL+BR'), isTrue);
      expect(
        channelLayoutHasFrontCenter('6 channels (FL+FR+FC+LFE+SL+SR)'),
        isTrue,
      );
      expect(channelLayoutHasFrontCenter('fl-fr-fc-lfe-sl-sr'), isTrue);
      expect(channelLayoutHasFrontCenter('fl-fr-sl-sr'), isFalse);
    });

    test('未知布局不按声道数猜（6 声道不一定是 5.1）', () {
      expect(channelLayoutHasFrontCenter(null), isNull);
      expect(channelLayoutHasFrontCenter(''), isNull);
      expect(channelLayoutHasFrontCenter('unknown6'), isNull);
      expect(channelLayoutHasFrontCenter(null, channelCount: 6), isNull);
    });

    test('声道数 < 3 时即使布局未知也确定没有 FC', () {
      expect(channelLayoutHasFrontCenter(null, channelCount: 2), isFalse);
      expect(channelLayoutHasFrontCenter('unknown1', channelCount: 1), isFalse);
    });
  });

  group('planSentenceAudioSource', () {
    const SentenceAudioTrackInfo surround = SentenceAudioTrackInfo(
      channelLayout: '5.1(side)',
      channelCount: 6,
    );
    const SentenceAudioTrackInfo stereo = SentenceAudioTrackInfo(
      channelLayout: 'stereo',
      channelCount: 2,
    );
    const SentenceAudioTrackInfo unknown = SentenceAudioTrackInfo();

    test('默认来源 = 当前播放音轨，参数与改动前相同', () {
      for (final int? playing in <int?>[null, 0, 1]) {
        final SentenceAudioSourcePlan plan = planSentenceAudioSource(
          pick: SentenceAudioSourcePick.currentTrack,
          playingIndex: playing,
          tracks: const <SentenceAudioTrackInfo>[surround, stereo],
        );
        expect(plan.audioStreamIndex, playing);
        expect(plan.frontCenter, isFalse);
        expect(plan.fallback, isNull);
      }
    });

    test('指定音轨：存在就 map 它（可与正在播的不同）', () {
      final SentenceAudioSourcePlan plan = planSentenceAudioSource(
        pick: SentenceAudioSourcePick.track(1),
        playingIndex: 0,
        tracks: const <SentenceAudioTrackInfo>[surround, stereo],
      );
      expect(plan.audioStreamIndex, 1);
      expect(plan.fallback, isNull);
      expect(plan.differsFromPlaying(0), isTrue);
      expect(plan.differsFromPlaying(1), isFalse);
    });

    test('指定音轨越界：回退当前播放音轨 + trackMissing', () {
      final SentenceAudioSourcePlan plan = planSentenceAudioSource(
        pick: SentenceAudioSourcePick.track(4),
        playingIndex: 1,
        tracks: const <SentenceAudioTrackInfo>[surround, stereo],
      );
      expect(plan.audioStreamIndex, 1);
      expect(plan.frontCenter, isFalse);
      expect(plan.fallback, SentenceAudioFallbackReason.trackMissing);
    });

    test('单轨视频选第 1 条 = 默认（不加 -map）', () {
      final SentenceAudioSourcePlan plan = planSentenceAudioSource(
        pick: SentenceAudioSourcePick.track(0),
        playingIndex: null,
        tracks: const <SentenceAudioTrackInfo>[stereo],
      );
      expect(plan.audioStreamIndex, isNull);
      expect(plan.fallback, isNull);
    });

    test('中置：当前轨是 5.1 → 显式 map 当前轨 + pan，不必探测', () {
      final SentenceAudioSourcePlan plan = planSentenceAudioSource(
        pick: SentenceAudioSourcePick.frontCenter,
        playingIndex: null,
        tracks: const <SentenceAudioTrackInfo>[surround],
      );
      expect(plan.audioStreamIndex, 0);
      expect(plan.frontCenter, isTrue);
      expect(plan.frontCenterNeedsProbe, isFalse);
      expect(plan.fallback, isNull);
      expect(plan.differsFromPlaying(null), isFalse);
    });

    test('中置：取的是正在播的那条轨的布局', () {
      final SentenceAudioSourcePlan plan = planSentenceAudioSource(
        pick: SentenceAudioSourcePick.frontCenter,
        playingIndex: 1,
        tracks: const <SentenceAudioTrackInfo>[surround, stereo],
      );
      expect(plan.frontCenter, isFalse);
      expect(plan.audioStreamIndex, 1);
      expect(plan.fallback, SentenceAudioFallbackReason.noFrontCenter);
    });

    test('中置：立体声 → 回退当前播放音轨 + noFrontCenter', () {
      final SentenceAudioSourcePlan plan = planSentenceAudioSource(
        pick: SentenceAudioSourcePick.frontCenter,
        playingIndex: null,
        tracks: const <SentenceAudioTrackInfo>[stereo],
      );
      expect(plan.audioStreamIndex, isNull);
      expect(plan.frontCenter, isFalse);
      expect(plan.fallback, SentenceAudioFallbackReason.noFrontCenter);
    });

    test('中置：播放器没报布局 → 交引擎探测，不当场回退', () {
      final SentenceAudioSourcePlan plan = planSentenceAudioSource(
        pick: SentenceAudioSourcePick.frontCenter,
        playingIndex: null,
        tracks: const <SentenceAudioTrackInfo>[unknown],
      );
      expect(plan.frontCenter, isTrue);
      expect(plan.frontCenterNeedsProbe, isTrue);
      expect(plan.fallback, isNull);
    });
  });

  group('SentenceAudioSourcePick wire', () {
    test('往返', () {
      for (final SentenceAudioSourcePick pick in <SentenceAudioSourcePick>[
        SentenceAudioSourcePick.currentTrack,
        SentenceAudioSourcePick.frontCenter,
        SentenceAudioSourcePick.track(0),
        SentenceAudioSourcePick.track(3),
      ]) {
        expect(SentenceAudioSourcePick.fromWireName(pick.wireName), pick);
        // 操作目录 / CLI 的选项记号取 toString()，必须能原样写回。
        expect(pick.toString(), pick.wireName);
      }
      expect(SentenceAudioSourcePick.track(2).wireName, 'track:2');
    });

    test('坏值一律回退当前播放音轨', () {
      for (final String? raw in <String?>[
        null,
        '',
        'nope',
        'track:',
        'track:-1',
        'track:x',
      ]) {
        expect(
          SentenceAudioSourcePick.fromWireName(raw),
          SentenceAudioSourcePick.currentTrack,
          reason: '$raw',
        );
      }
      expect(SentenceAudioSourcePick.tryFromWireName(null), isNull);
      expect(SentenceAudioSourcePick.tryFromWireName(' '), isNull);
    });

    test('高级制卡覆盖项带上来源并往返；没改来源时覆盖项仍为空', () {
      const MiningRequestOverrides o = MiningRequestOverrides(
        audioSource: 'front_center',
      );
      expect(o.isEmpty, isFalse);
      final MiningRequestOverrides? back = MiningRequestOverrides.readFrom(
        MiningRequestOverrides.attach(const <String, String>{}, o),
      );
      expect(back!.audioSource, 'front_center');
      expect(const MiningRequestOverrides().isEmpty, isTrue);
      expect(o.copyWith(clearAudioSource: true).isEmpty, isTrue);
    });
  });

  group('偏好层', () {
    late FushiDatabase db;
    late PreferencesRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      repo = PreferencesRepository(db);
      await repo.loadFromDb();
    });

    tearDown(() async {
      await repo.setPref('_drain_pending_writes', 1);
      repo.dispose();
      await db.close();
    });

    test('默认 = 当前播放音轨（行为不变）', () {
      expect(repo.videoMiningAudioSource, SentenceAudioSourcePick.currentTrack);
    });

    test('写穿 Drift 并跨实例可见；key 在白名单', () async {
      await repo.setVideoMiningAudioSource(SentenceAudioSourcePick.track(1));
      final PreferencesRepository restored = PreferencesRepository(db);
      await restored.loadFromDb();
      expect(restored.videoMiningAudioSource, SentenceAudioSourcePick.track(1));
      restored.dispose();
      final Map<String, String> prefs = await db.getAllPrefs();
      expect(prefs.containsKey('video_mining_audio_source'), isTrue);
      expect(kKnownPreferenceKeys, contains('video_mining_audio_source'));
    });
  });

  test('统一 FFmpeg 能力清单编入 pan（中置声道取音）', () {
    final Map<String, dynamic> caps =
        jsonDecode(
              File(
                '../tool/ffmpeg-unified/capabilities.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(caps['filters'] as List<dynamic>, contains('pan'));
  });
}
