import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/stream_video_launch.dart';
import 'package:hibiki/src/media/video/url_stream_video.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-1301（BUG-588）：油管应用内制卡「没句子音频、没 gif」的根因是应用内播放路径
/// **无条件**把制卡音频源指向 audio-only DASH 流（audioStreamUrl）——该流 ffmpeg `-ss`
/// HTTP seek 会 stall→120s 超时→无音频，`requireAudio` 默认 true 又让整卡 abort→已抽好的
/// GIF 连坐丢弃。批量路径（youtube_clip_miner.dart:67）用守卫
/// `audioSource: miningVideoHasAudio ? null : audioStreamUrl` 早已正确；本组测试守住方向 A
/// 的信号接线：`miningVideoHasAudio` 沿 UrlStreamVideoClient → RemoteVideoStreamUrls 不再
/// 被丢，且应用内选择公式与批量守卫**逐字一致**。

/// 与 youtube_clip_miner.dart:67 / video_hibiki_page.dart 的制卡音频源选择**同一公式**：
/// muxed 挖矿流自带音轨 → null（引擎回落 miningSource 抽音频）；纯分离流 → audio-only URL。
String? _miningAudioSourceFor(RemoteVideoStreamUrls urls) =>
    urls.miningVideoHasAudio ? null : urls.audioStreamUrl;

VideoBookRow _row({required String videoPath, String? streamSpecJson}) =>
    VideoBookRow(
      bookUid: 'video/stream/abc',
      title: 'stream',
      videoPath: videoPath,
      lastPositionMs: 0,
      currentEpisode: 0,
      delayMs: 0,
      streamSpecJson: streamSpecJson,
    );

void main() {
  group('miningVideoHasAudio 信号沿 UrlStreamVideoClient 不被丢 (TODO-1301)', () {
    test('muxed 挖矿流（自带音轨）→ remoteVideoStreamUrls 回填 true', () async {
      // 复刻 resolver「同时有分离流 + muxed」的实况：audioStreamUrl 非空（播放用分离流），
      // 但 miningVideoHasAudio=true（制卡用 muxed 360p 抽音频）——这正是 audioStreamUrl==null
      // 无法推断该信号、必须显式透传的核心场景。
      final UrlStreamVideoClient c = UrlStreamVideoClient(
        streamUrl: 'https://v/play',
        audioStreamUrl: 'https://v/audio',
        miningVideoUrl: 'https://v/mine',
        miningVideoHasAudio: true,
      );
      final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls('id');
      expect(urls.miningVideoHasAudio, isTrue);
      // 应用内选择公式：muxed → null（引擎回落 miningSource 抽音频，不指向 audio-only DASH）。
      expect(_miningAudioSourceFor(urls), isNull);
    });

    test('纯分离流（无 muxed）→ remoteVideoStreamUrls 回填 false，用 audio-only URL',
        () async {
      final UrlStreamVideoClient c = UrlStreamVideoClient(
        streamUrl: 'https://v/play',
        audioStreamUrl: 'https://v/audio',
        miningVideoUrl: 'https://v/mine',
        miningVideoHasAudio: false,
      );
      final RemoteVideoStreamUrls urls = await c.remoteVideoStreamUrls('id');
      expect(urls.miningVideoHasAudio, isFalse);
      expect(_miningAudioSourceFor(urls), 'https://v/audio');
    });

    test('episodeIndex 变化不改变 miningVideoHasAudio（单 URL 流恒等）', () async {
      final UrlStreamVideoClient c = UrlStreamVideoClient(
        streamUrl: 'https://v/play',
        audioStreamUrl: 'https://v/audio',
        miningVideoUrl: 'https://v/mine',
        miningVideoHasAudio: true,
      );
      final RemoteVideoStreamUrls a = await c.remoteVideoStreamUrls('id');
      final RemoteVideoStreamUrls b =
          await c.remoteVideoStreamUrls('id', episodeIndex: 5);
      expect(a.miningVideoHasAudio, b.miningVideoHasAudio);
      expect(b.miningVideoHasAudio, isTrue);
    });
  });

  group('RemoteVideoStreamUrls.miningVideoHasAudio JSON 契约 (TODO-1301)', () {
    test('fromJson 解析 miningVideoHasAudio=true', () {
      final RemoteVideoStreamUrls urls =
          RemoteVideoStreamUrls.fromJson(<String, Object?>{
        'url': 'https://v/play',
        'audioStreamUrl': 'https://v/audio',
        'miningVideoUrl': 'https://v/mine',
        'miningVideoHasAudio': true,
      });
      expect(urls.miningVideoHasAudio, isTrue);
      expect(_miningAudioSourceFor(urls), isNull);
    });

    test('fromJson 缺字段 → 默认 false（保持旧远端 host 行为，用 audio-only 流）', () {
      final RemoteVideoStreamUrls urls =
          RemoteVideoStreamUrls.fromJson(<String, Object?>{
        'url': 'https://v/play',
        'audioStreamUrl': 'https://v/audio',
      });
      expect(urls.miningVideoHasAudio, isFalse);
      expect(_miningAudioSourceFor(urls), 'https://v/audio');
    });

    test('fromJson 非 bool 值 → false（脏数据不崩）', () {
      final RemoteVideoStreamUrls urls =
          RemoteVideoStreamUrls.fromJson(<String, Object?>{
        'url': 'https://v/play',
        'miningVideoHasAudio': 'yes',
      });
      expect(urls.miningVideoHasAudio, isFalse);
    });
  });

  group('buildStreamVideoLaunch 直链分支 miningVideoHasAudio (TODO-1301)', () {
    test('直链/HLS（单 muxed 流）→ 客户端 miningVideoHasAudio=true', () async {
      final launch = await buildStreamVideoLaunch(
          _row(videoPath: 'https://cdn.example.com/live.m3u8'));
      expect(launch.client.miningVideoHasAudio, isTrue);
      final RemoteVideoStreamUrls urls =
          await launch.client.remoteVideoStreamUrls(launch.info.id);
      expect(urls.miningVideoHasAudio, isTrue);
      // 直链无分离 audio-only 流 → 制卡音频从 miningSource(直链自身) 抽。
      expect(_miningAudioSourceFor(urls), isNull);
      launch.client.close();
    });
  });

  group('video_hibiki_page 制卡音频源接线守卫 (TODO-1301 回归)', () {
    late String src;
    setUpAll(() {
      src = File('lib/src/pages/implementations/video_hibiki_page.dart')
          .readAsStringSync();
    });

    test('应用内路径复用批量守卫公式（muxed 时置 null）', () {
      // 必须与 youtube_clip_miner.dart:67 逐字一致：muxed → null 回落 miningSource 抽音频。
      expect(
        src.contains('urls.miningVideoHasAudio ? null : urls.audioStreamUrl'),
        isTrue,
        reason: '应用内制卡音频源必须走 miningVideoHasAudio 守卫，与批量路径一致',
      );
    });

    test('不得再无条件把制卡音频源指向 audio-only DASH 流（旧根因 BUG-588）', () {
      // 旧代码：if (urls.audioStreamUrl != null) setMiningAudioSourceOverride(urls.audioStreamUrl);
      expect(
        src.contains('setMiningAudioSourceOverride(urls.audioStreamUrl)'),
        isFalse,
        reason: '无条件指向 audio-only 流会致 ffmpeg seek stall→无音频，GIF 连坐丢弃',
      );
    });
  });
}
