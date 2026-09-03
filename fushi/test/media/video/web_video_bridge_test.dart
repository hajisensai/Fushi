import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi_audio/fushi_audio.dart';

void main() {
  group('shouldOpenInWebVideoPlayer', () {
    test('Windows + 已知网页视频站 → 网页播放器', () {
      expect(
        shouldOpenInWebVideoPlayer(
          'https://www.netflix.com/watch/81236554',
          platform: TargetPlatform.windows,
        ),
        isTrue,
      );
    });

    test('非 Windows 一律走 mpv 页（fork 纹理链路只有 Windows）', () {
      for (final TargetPlatform p in <TargetPlatform>[
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
        TargetPlatform.linux,
      ]) {
        expect(
          shouldOpenInWebVideoPlayer(
            'https://www.netflix.com/watch/1',
            platform: p,
          ),
          isFalse,
          reason: '$p 不该进网页播放器',
        );
      }
    });

    test('直链 / 非白名单 host 不进网页播放器（保持 mpv 路径零破坏）', () {
      expect(
        shouldOpenInWebVideoPlayer(
          'https://cdn.example.com/a.m3u8',
          platform: TargetPlatform.windows,
        ),
        isFalse,
      );
      expect(
        shouldOpenInWebVideoPlayer(
          'not a url',
          platform: TargetPlatform.windows,
        ),
        isFalse,
      );
    });
  });

  group('webVideoBridgeAssetsForHost', () {
    test('按站点选 bridge，顺序固定、不命中为空', () {
      expect(webVideoBridgeAssetsForHost('www.netflix.com'), <String>[
        kWebVideoNetflixBridgeAsset,
      ]);
      expect(webVideoBridgeAssetsForHost('m.youtube.com'), <String>[
        kWebVideoYoutubeBridgeAsset,
      ]);
      expect(webVideoBridgeAssetsForHost('www.hulu.jp'), <String>[
        kWebVideoStreamBridgeAsset,
      ]);
      expect(webVideoBridgeAssetsForHost('www.amazon.co.jp'), <String>[
        kWebVideoStreamBridgeAsset,
      ]);
      expect(
        webVideoBridgeAssetsForHost('www.bilibili.com'),
        isEmpty,
        reason: 'stream-bridge 只覆盖 bilibili.tv（国际站），与 manifest 一致',
      );
      expect(
        webVideoBridgeAssetsForHost('evilnetflix.com'),
        isEmpty,
        reason: '后缀匹配必须带点边界',
      );
    });

    test('站点覆盖与扩展 manifest.json 的 matches 逐条一致', () {
      // flutter test cwd = fushi 包根。
      final Map<String, dynamic> manifest =
          jsonDecode(
                File(
                  '../tools/browser-extension/manifest.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final List<dynamic> scripts =
          manifest['content_scripts'] as List<dynamic>;
      Set<String> hostsOf(String bridge) {
        for (final dynamic entry in scripts) {
          final List<dynamic> js =
              (entry as Map<String, dynamic>)['js'] as List<dynamic>;
          if (!js.contains(bridge)) continue;
          return <String>{
            for (final dynamic m in entry['matches'] as List<dynamic>)
              // `*://*.netflix.com/*` → netflix.com；`*://www.hulu.jp/*` → www.hulu.jp
              (m as String)
                  .replaceFirst(RegExp(r'^\*://(\*\.)?'), '')
                  .replaceFirst(RegExp(r'/\*$'), ''),
          };
        }
        fail('manifest.json 里没有 $bridge');
      }

      expect(kWebVideoNetflixHosts.toSet(), hostsOf('netflix-bridge.js'));
      expect(kWebVideoYoutubeHosts.toSet(), hostsOf('youtube-bridge.js'));
      expect(kWebVideoStreamBridgeHosts.toSet(), hostsOf('stream-bridge.js'));
    });
  });

  group('parseWebVideoTrackPayload', () {
    test('把 {s,e,t} 转成 AudioCue，坏条目丢弃、end<start 钳到 start', () {
      final WebVideoTrack? track = parseWebVideoTrackPayload(<String, Object?>{
        'type': 'track',
        'key': '81236554|ja',
        'videoKey': '81236554',
        'lang': 'ja',
        'cues': <Object?>[
          <String, Object?>{'s': 1000, 'e': 2000, 't': ' こんにちは '},
          <String, Object?>{'s': 3000.4, 'e': 2500, 't': 'x'},
          <String, Object?>{'s': 'bad', 'e': 1, 't': 'y'},
          <String, Object?>{'s': 4000, 'e': 5000, 't': '   '},
          'garbage',
        ],
      }, bookUid: 'video/stream/abc');
      expect(track, isNotNull);
      expect(track!.key, '81236554|ja');
      expect(track.videoKey, '81236554');
      expect(track.lang, 'ja');
      expect(track.isLive, isFalse);
      expect(track.cues.map((AudioCue c) => c.text), <String>['こんにちは', 'x']);
      expect(track.cues[0].startMs, 1000);
      expect(track.cues[0].bookKey, 'video/stream/abc');
      expect(track.cues[0].chapterHref, '81236554|ja');
      expect(track.cues[1].startMs, 3000);
      expect(track.cues[1].endMs, 3000, reason: 'end<start 钳到 start');
      expect(track.cues[1].sentenceIndex, 1);
    });

    test('缺 videoKey/lang 时从 key 拆；live 轨识别；坏形状回 null', () {
      final WebVideoTrack? t = parseWebVideoTrackPayload(<String, Object?>{
        'key': 'yt-abc|live',
        'cues': <Object?>[],
      }, bookUid: 'b');
      expect(t!.videoKey, 'yt-abc');
      expect(t.lang, kWebVideoLiveTrackLang);
      expect(t.isLive, isTrue);
      expect(
        parseWebVideoTrackPayload(<String, Object?>{'key': ''}, bookUid: 'b'),
        isNull,
      );
      expect(parseWebVideoTrackPayload('nope', bookUid: 'b'), isNull);
      expect(
        parseWebVideoTrackPayload(<String, Object?>{
          'key': 'a|b',
          'cues': 3,
        }, bookUid: 'b'),
        isNull,
      );
    });
  });

  group('parseWebVideoStatePayload', () {
    test('完整快照', () {
      final WebVideoPlaybackState? s =
          parseWebVideoStatePayload(<String, Object?>{
            'type': 'state',
            'href': 'https://www.netflix.com/watch/1',
            'videoKey': '1',
            'hasVideo': true,
            't': 12345,
            'paused': false,
            'dur': 100000,
            'vw': 1920,
            'vh': 1080,
            'rate': 1.5,
            'fs': true,
            'title': 'Netflix',
          });
      expect(s, isNotNull);
      expect(s!.isPlaying, isTrue);
      expect(s.positionMs, 12345);
      expect(s.durationMs, 100000);
      expect(s.videoWidth, 1920);
      expect(s.rate, 1.5);
      expect(s.fullscreen, isTrue);
    });

    test('无 video 时 paused 视为 true、position null；非 Map 回 null', () {
      final WebVideoPlaybackState? s = parseWebVideoStatePayload(
        <String, Object?>{'hasVideo': false},
      );
      expect(s!.isPlaying, isFalse);
      expect(s.positionMs, isNull);
      expect(s.rate, 1.0);
      expect(parseWebVideoStatePayload(null), isNull);
    });
  });

  group('chooseWebVideoTrackKey', () {
    WebVideoTrack track(String key, {int cues = 1}) {
      final int sep = key.indexOf('|');
      return WebVideoTrack(
        key: key,
        videoKey: key.substring(0, sep),
        lang: key.substring(sep + 1),
        cues: <AudioCue>[
          for (int i = 0; i < cues; i++)
            AudioCue()
              ..bookKey = 'b'
              ..chapterHref = key
              ..sentenceIndex = i
              ..textFragmentId = ''
              ..text = 'c$i'
              ..startMs = i * 1000
              ..endMs = i * 1000 + 500
              ..audioFileIndex = 0,
        ],
      );
    }

    test('只看当前视频的轨；偏好语言 > 首条整轨 > live', () {
      final List<WebVideoTrack> tracks = <WebVideoTrack>[
        track('v1|live'),
        track('v1|en'),
        track('v1|ja-JP'),
        track('v2|ja'),
      ];
      expect(
        chooseWebVideoTrackKey(tracks: tracks, videoKey: 'v1'),
        'v1|en',
        reason: '无偏好：第一条非 live 整轨',
      );
      expect(
        chooseWebVideoTrackKey(
          tracks: tracks,
          videoKey: 'v1',
          preferredLanguage: 'ja',
        ),
        'v1|ja-JP',
        reason: '语言码前缀匹配 ja → ja-JP',
      );
      expect(
        chooseWebVideoTrackKey(
          tracks: tracks,
          videoKey: 'v1',
          preferredLanguage: 'live',
        ),
        'v1|en',
        reason: 'live 不参与语言偏好',
      );
      expect(chooseWebVideoTrackKey(tracks: tracks, videoKey: 'v3'), isNull);
    });

    test('用户已选且仍属于当前视频则保持；换视频后丢弃旧选择', () {
      final List<WebVideoTrack> tracks = <WebVideoTrack>[
        track('v1|en'),
        track('v1|ja'),
        track('v2|ja'),
      ];
      expect(
        chooseWebVideoTrackKey(
          tracks: tracks,
          videoKey: 'v1',
          current: 'v1|ja',
        ),
        'v1|ja',
      );
      expect(
        chooseWebVideoTrackKey(
          tracks: tracks,
          videoKey: 'v2',
          current: 'v1|ja',
        ),
        'v2|ja',
      );
    });

    test('空轨（还没采到 cue）不当候选；只有 live 时选 live', () {
      final List<WebVideoTrack> tracks = <WebVideoTrack>[
        track('v1|en', cues: 0),
        track('v1|live'),
      ];
      expect(chooseWebVideoTrackKey(tracks: tracks, videoKey: 'v1'), 'v1|live');
    });
  });
}
