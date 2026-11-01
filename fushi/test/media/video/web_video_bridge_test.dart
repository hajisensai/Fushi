import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi_audio/fushi_audio.dart';

void main() {
  group('shouldOpenInWebVideoPlayer', () {
    // 2026-09-13 暂时砍掉过；底层合成（网页站点画面垫在原生播放器下面）落地后重新打开。
    test('总开关开着：Windows 命中站点进网页播放后端，其它平台照旧', () {
      expect(kWebVideoPlayerEnabled, isTrue);
      expect(
        shouldOpenInWebVideoPlayer(
          'https://www.netflix.com/watch/81236554',
          platform: TargetPlatform.windows,
        ),
        isTrue,
      );
      expect(
        shouldOpenInWebVideoPlayer(
          'https://www.netflix.com/watch/81236554',
          platform: TargetPlatform.android,
        ),
        isFalse,
      );
    });
  });

  group('web_video_glue.js 契约', () {
    final String glue = File(
      'assets/web_video/web_video_glue.js',
    ).readAsStringSync();

    test('snapshot() 上报音量 / 静音 / 缓冲（原生播放器控件的真相源）', () {
      final int start = glue.indexOf('function snapshot()');
      final int end = glue.indexOf('function same(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final String body = glue.substring(start, end);
      for (final String field in <String>['vol:', 'muted:', 'buf:']) {
        expect(body.contains(field), isTrue, reason: 'snapshot 缺 $field');
      }
    });

    test('命令表里 setVolume 只定义一次（重复键后者覆盖前者，签名会悄悄变）', () {
      expect(RegExp(r'\bsetVolume:').allMatches(glue).length, 1);
    });
  });

  group('isWebVideoPlayerEligible（平台 / 站点判据，不含总开关）', () {
    test('Windows + 已知网页视频站 → 够格', () {
      expect(
        isWebVideoPlayerEligible(
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
          isWebVideoPlayerEligible(
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
        isWebVideoPlayerEligible(
          'https://cdn.example.com/a.m3u8',
          platform: TargetPlatform.windows,
        ),
        isFalse,
      );
      expect(
        isWebVideoPlayerEligible('not a url', platform: TargetPlatform.windows),
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

    test('languageCode 单独上报（YouTube 语言段是显示名）；旧 glue 没有时等于 lang', () {
      final WebVideoTrack yt = parseWebVideoTrackPayload(<String, Object?>{
        'key': 'yt-abc|English (auto)',
        'lang': 'English (auto)',
        'languageCode': 'en',
        'cues': <Object?>[
          <String, Object?>{'s': 0, 'e': 1000, 't': 'hi'},
        ],
      }, bookUid: 'b')!;
      expect(yt.lang, 'English (auto)', reason: '面板标签照旧用语言段');
      expect(yt.languageCode, 'en');
      final WebVideoTrack legacy = parseWebVideoTrackPayload(<String, Object?>{
        'key': '81236554|ja',
        'cues': <Object?>[],
      }, bookUid: 'b')!;
      expect(legacy.languageCode, 'ja');
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
            'vol': 0.4,
            'muted': true,
            'buf': true,
          });
      expect(s, isNotNull);
      expect(s!.isPlaying, isTrue);
      expect(s.positionMs, 12345);
      expect(s.durationMs, 100000);
      expect(s.videoWidth, 1920);
      expect(s.rate, 1.5);
      expect(s.fullscreen, isTrue);
      expect(s.volume, 0.4);
      expect(s.muted, isTrue);
      expect(s.buffering, isTrue);
    });

    test('音量越界钳到 0–1；旧 glue 没有音量 / 缓冲字段时取默认', () {
      expect(
        parseWebVideoStatePayload(<String, Object?>{'vol': 3})!.volume,
        1.0,
      );
      final WebVideoPlaybackState legacy = parseWebVideoStatePayload(
        <String, Object?>{'hasVideo': true, 't': 1},
      )!;
      expect(legacy.volume, isNull);
      expect(legacy.muted, isFalse);
      expect(legacy.buffering, isFalse);
    });

    test('YouTube 按需加载的占位轨（lzt）进站点轨清单，与 Netflix 的 nftt 同一清单', () {
      final WebVideoPlaybackState s =
          parseWebVideoStatePayload(<String, Object?>{
            'videoKey': 'yt-x',
            'hasVideo': true,
            'lzt':
                'English (auto)\ten\tEnglish (auto)\t\t0\n'
                '日本語\tja\t日本語\t\t0\n'
                '#',
          })!;
      expect(s.siteTracks, hasLength(2));
      final WebVideoSiteTrack ja = s.siteTracks[1];
      expect(ja.isLazy, isTrue);
      expect(ja.lang, 'ja', reason: '语言码给语言偏好挑轨');
      expect(ja.name, '日本語');
      expect(
        ja.storeKey('yt-x'),
        'yt-x|日本語',
        reason: '与 providers 的占位轨 key 同形',
      );
      expect(s.siteTrackCurrent, '', reason: '占位轨没有「站点当前轨」');
      expect(
        pickWebVideoSiteTrackForLanguage(s.siteTracks, 'ja'),
        ja,
        reason: '每集按语言偏好替用户开轨对占位轨同样生效',
      );

      final WebVideoPlaybackState nf =
          parseWebVideoStatePayload(<String, Object?>{
            'videoKey': '81001',
            'hasVideo': true,
            'nftt': 'T:ja\tja\t日本語\tPRIMARY\t0\n#T:ja',
            'lzt': '',
          })!;
      expect(nf.siteTracks, hasLength(1));
      expect(nf.siteTracks.single.isLazy, isFalse);
      expect(nf.siteTracks.single.storeKey('81001'), '81001|ja~T:ja');
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

    test('用户显式选定且仍属于当前视频则保持；换视频后丢弃旧选择', () {
      final List<WebVideoTrack> tracks = <WebVideoTrack>[
        track('v1|en'),
        track('v1|ja'),
        track('v2|ja'),
      ];
      expect(
        chooseWebVideoTrackKey(tracks: tracks, videoKey: 'v1', pinned: 'v1|ja'),
        'v1|ja',
      );
      expect(
        chooseWebVideoTrackKey(tracks: tracks, videoKey: 'v2', pinned: 'v1|ja'),
        'v2|ja',
      );
    });

    // 回归：页面把上一次的自动结果当 current 传回、而函数「current 在就保持」，先到的 live 轨
    // （DOM 采样）就被钉死，后到的整轨永远选不上。自动结果每次重算，只有显式选择钉住。
    test('整轨后到取代自动选中的 live；用户显式选 live 则钉住', () {
      final List<WebVideoTrack> early = <WebVideoTrack>[track('v1|live')];
      final String? auto = chooseWebVideoTrackKey(
        tracks: early,
        videoKey: 'v1',
        preferredLanguage: 'en',
      );
      expect(auto, 'v1|live', reason: '只有 live 时先显示 live');
      final List<WebVideoTrack> later = <WebVideoTrack>[
        ...early,
        track('v1|en'),
      ];
      expect(
        chooseWebVideoTrackKey(
          tracks: later,
          videoKey: 'v1',
          preferredLanguage: 'en',
        ),
        'v1|en',
        reason: '整轨到了：自动结果改成整轨',
      );
      expect(
        chooseWebVideoTrackKey(
          tracks: later,
          videoKey: 'v1',
          preferredLanguage: 'en',
          pinned: 'v1|live',
        ),
        'v1|live',
        reason: '用户亲手选了 live：不被自动规则改掉',
      );
    });

    test('语言偏好按 languageCode 匹配：YouTube 轨 key 语言段是显示名', () {
      WebVideoTrack yt(String label, String code) => WebVideoTrack(
        key: 'yt-x|$label',
        videoKey: 'yt-x',
        lang: label,
        languageCode: code,
        cues: track('yt-x|$label').cues,
      );
      final List<WebVideoTrack> tracks = <WebVideoTrack>[
        yt('English (auto)', 'en'),
        yt('日本語 (自動生成)', 'ja'),
      ];
      expect(
        chooseWebVideoTrackKey(
          tracks: tracks,
          videoKey: 'yt-x',
          preferredLanguage: 'ja',
        ),
        'yt-x|日本語 (自動生成)',
      );
      expect(
        track('v1|ja-JP').languageCode,
        'ja-JP',
        reason: '没有 languageCode 时语言段就是语言码',
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
