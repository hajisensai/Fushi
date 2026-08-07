import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/youtube_source_resolver.dart'
    show YoutubeCaptionTrack;
import 'package:fushi/src/sync/hibiki_library_host_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;

void main() {
  group('isPlayableStreamUrl', () {
    test('http/https with host are playable', () {
      expect(isPlayableStreamUrl('http://a.test/v.mp4'), isTrue);
      expect(isPlayableStreamUrl('https://a.test/live.m3u8'), isTrue);
      expect(isPlayableStreamUrl('HTTPS://A.TEST/x.ts'), isTrue);
      expect(isPlayableStreamUrl('  https://a.test/x.mp4  '), isTrue);
    });

    test('non-http(s) scheme / no host / empty / garbage are not playable', () {
      expect(isPlayableStreamUrl(''), isFalse);
      expect(isPlayableStreamUrl('   '), isFalse);
      expect(isPlayableStreamUrl('ftp://a.test/x.mp4'), isFalse);
      expect(isPlayableStreamUrl('file:///c:/a.mp4'), isFalse);
      expect(isPlayableStreamUrl('/local/path/a.mp4'), isFalse);
      expect(isPlayableStreamUrl('http:///nohost'), isFalse);
      expect(isPlayableStreamUrl('rtmp://a.test/live'), isFalse);
    });
  });

  group('streamVideoBookUid', () {
    test('stable + video/stream/ prefix + 12 hex chars', () {
      const String url = 'https://a.test/live.m3u8';
      final String uid = streamVideoBookUid(url);
      expect(uid, streamVideoBookUid(url)); // deterministic
      expect(uid.startsWith('video/stream/'), isTrue);
      final String digest = uid.substring('video/stream/'.length);
      expect(digest.length, 12);
      expect(RegExp(r'^[0-9a-f]{12}$').hasMatch(digest), isTrue);
    });

    test('trim does not change identity; different urls differ', () {
      const String url = 'https://a.test/live.m3u8';
      expect(streamVideoBookUid('  $url  '), streamVideoBookUid(url));
      expect(streamVideoBookUid('https://a.test/other.m3u8'),
          isNot(streamVideoBookUid(url)));
    });

    test('prefix does not collide with other video uid families', () {
      final String uid = streamVideoBookUid('https://a.test/x.mp4');
      expect(uid.startsWith('video/stream/'), isTrue);
      expect(uid.startsWith('video/ext/'), isFalse);
      expect(uid.startsWith('video/playlist/'), isFalse);
      // 单视频族是 video/<name>，stream 永远多一段 stream/<hash>，前缀互斥。
      expect(uid.split('/').length, 3);
    });
  });

  group('mediaUriForVideoPath', () {
    test('http(s) pass-through', () {
      const String u = 'https://a.test/live.m3u8';
      expect(mediaUriForVideoPath(u), u);
    });
    test('local path -> file uri', () {
      final String path = File('sample.mp4').absolute.path;
      expect(mediaUriForVideoPath(path), File(path).uri.toString());
    });
  });

  group('UrlStreamVideoClient contract (6 methods, TODO-885)', () {
    test('listRemoteVideos returns empty (no enumeration)', () async {
      final UrlStreamVideoClient c =
          UrlStreamVideoClient(streamUrl: 'https://a.test/v.mp4');
      expect(await c.listRemoteVideos(), isEmpty);
    });

    test('remoteVideoStreamUrls ignores episodeIndex, returns same stream',
        () async {
      final UrlStreamVideoClient c = UrlStreamVideoClient(
        streamUrl: 'https://a.test/v.mp4',
        subtitleUrl: 'https://a.test/v.srt',
        subtitleFileName: 'v.srt',
      );
      final RemoteVideoStreamUrls a = await c.remoteVideoStreamUrls('id');
      final RemoteVideoStreamUrls b =
          await c.remoteVideoStreamUrls('id', episodeIndex: 7);
      expect(a.streamUrl, 'https://a.test/v.mp4');
      expect(b.streamUrl, a.streamUrl);
      expect(a.subtitleUrl, 'https://a.test/v.srt');
      expect(b.subtitleUrl, a.subtitleUrl);
      expect(a.subtitleFileName, 'v.srt');
    });

    test('getRemoteVideoSubtitle downloads to dest when subtitleUrl present',
        () async {
      final MockClient mock = MockClient((http.Request req) async {
        expect(req.url.toString(), 'https://a.test/v.srt');
        expect(req.headers['Referer'], 'https://a.test/');
        return http.Response('1\n00:00:01,000 --> 00:00:02,000\nhi\n', 200);
      });
      final UrlStreamVideoClient c = UrlStreamVideoClient(
        streamUrl: 'https://a.test/v.mp4',
        subtitleUrl: 'https://a.test/v.srt',
        httpHeaderFields: const <String, String>{'Referer': 'https://a.test/'},
        httpClient: mock,
      );
      final Directory tmp = await Directory.systemTemp.createTemp('urlstream');
      final File dest = File(p.join(tmp.path, 'out.srt'));
      await c.getRemoteVideoSubtitle('id', dest);
      expect(await dest.exists(), isTrue);
      expect(await dest.readAsString(), contains('hi'));
      await tmp.delete(recursive: true);
    });

    test('getRemoteVideoSubtitle is no-op when no subtitleUrl', () async {
      bool called = false;
      final MockClient mock = MockClient((http.Request req) async {
        called = true;
        return http.Response('', 200);
      });
      final UrlStreamVideoClient c = UrlStreamVideoClient(
        streamUrl: 'https://a.test/v.mp4',
        httpClient: mock,
      );
      final Directory tmp = await Directory.systemTemp.createTemp('urlstream');
      final File dest = File(p.join(tmp.path, 'out.srt'));
      await c.getRemoteVideoSubtitle('id', dest);
      expect(called, isFalse);
      expect(await dest.exists(), isFalse);
      await tmp.delete(recursive: true);
    });

    test('downloadRemoteVideo throws UnsupportedError', () async {
      final UrlStreamVideoClient c =
          UrlStreamVideoClient(streamUrl: 'https://a.test/v.mp4');
      expect(
        () => c.downloadRemoteVideo('id', File('x')),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('remoteVideoPosition reads (0,0); putRemoteVideoPosition is no-op',
        () async {
      final UrlStreamVideoClient c =
          UrlStreamVideoClient(streamUrl: 'https://a.test/v.mp4');
      final ({int positionMs, int updatedAtMs}) pos =
          await c.remoteVideoPosition('id', episodeIndex: 3);
      expect(pos.positionMs, 0);
      expect(pos.updatedAtMs, 0);
      // no-op: must not throw / no observable side-effect.
      await c.putRemoteVideoPosition('id', 12345, 999, episodeIndex: 3);
    });
  });

  group('isKnownWebPageVideoHost / isKnownWebPageVideoUrl (TODO-1000 A1)', () {
    test('exact known hosts match', () {
      for (final String h in <String>[
        'youtube.com',
        'youtu.be',
        'netflix.com',
        'bilibili.com',
        'b23.tv',
        'nicovideo.jp',
        'vimeo.com',
        'twitch.tv',
        'abema.tv',
      ]) {
        expect(
            isKnownWebPageVideoHost(Uri.parse('https://$h/watch?v=x')), isTrue,
            reason: h);
      }
    });

    test('subdomains match via .suffix rule', () {
      expect(
          isKnownWebPageVideoHost(Uri.parse('https://www.youtube.com/watch')),
          isTrue);
      expect(isKnownWebPageVideoHost(Uri.parse('https://m.youtube.com/watch')),
          isTrue);
      expect(isKnownWebPageVideoHost(Uri.parse('https://music.youtube.com/x')),
          isTrue);
      expect(isKnownWebPageVideoHost(Uri.parse('https://www.netflix.com/x')),
          isTrue);
    });

    test('case-insensitive and trailing-dot (FQDN) tolerant', () {
      expect(isKnownWebPageVideoUrl('https://WWW.YouTube.COM/watch'), isTrue);
      expect(isKnownWebPageVideoUrl('https://youtube.com./watch'), isTrue);
    });

    test('direct-stream hosts and bare IP do NOT match', () {
      expect(
          isKnownWebPageVideoHost(Uri.parse('https://cdn.example.com/v.mp4')),
          isFalse);
      expect(
          isKnownWebPageVideoHost(Uri.parse('https://192.168.1.34/live.m3u8')),
          isFalse);
      // substring/suffix spoof must not false-positive (host != *.youtube.com).
      expect(
          isKnownWebPageVideoHost(Uri.parse('https://youtube.com.evil.test/x')),
          isFalse);
      expect(isKnownWebPageVideoHost(Uri.parse('https://notyoutube.com/x')),
          isFalse);
    });

    test('empty host / garbage url -> false', () {
      expect(isKnownWebPageVideoHost(Uri.parse('file:///c:/a.mp4')), isFalse);
      expect(isKnownWebPageVideoUrl(''), isFalse);
      expect(isKnownWebPageVideoUrl('   '), isFalse);
      expect(isKnownWebPageVideoUrl('not a url at all'), isFalse);
    });

    test(
        'REGRESSION: soft-warn never degrades to hard-reject — '
        'web-page URLs stay isPlayableStreamUrl==true (Never break userspace)',
        () {
      // A1 only adds a confirm prompt; it must NOT gate import by host.
      for (final String url in <String>[
        'https://www.youtube.com/watch?v=x',
        'https://youtu.be/abc',
        'https://www.netflix.com/title/123',
        'https://www.bilibili.com/video/BVxxx',
      ]) {
        expect(isKnownWebPageVideoUrl(url), isTrue, reason: url);
        // The play button stays enabled; user keeps the escape hatch.
        expect(isPlayableStreamUrl(url), isTrue, reason: url);
      }
    });
  });

  group('streamVideoBookUid YouTube canonicalization (TODO-1304 去重)', () {
    // 同一支视频 dQw4w9WgXcQ 的各种 URL 写法（不同 host / 短链 / 追踪参数）都必须收敛
    // 到同一 book_uid `video/stream/yt:<videoId>`，让 _uniqueBookUid 自然去重。
    const String canonical = 'video/stream/yt:dQw4w9WgXcQ';

    test('watch / youtu.be / shorts / m. / music. all converge to yt:<id>', () {
      const List<String> variants = <String>[
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://youtube.com/watch?v=dQw4w9WgXcQ',
        'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://music.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://youtu.be/dQw4w9WgXcQ',
        'https://www.youtube.com/shorts/dQw4w9WgXcQ',
        'https://www.youtube.com/embed/dQw4w9WgXcQ',
      ];
      for (final String url in variants) {
        expect(streamVideoBookUid(url), canonical, reason: url);
      }
    });

    test('tracking params (&t= &list= &si= &feature=) are stripped', () {
      const List<String> tracked = <String>[
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s',
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc123',
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&feature=share',
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10&list=PLx&feature=youtu.be',
        'https://youtu.be/dQw4w9WgXcQ?si=aBcDeFgH',
        'https://youtu.be/dQw4w9WgXcQ?t=90&si=xyz',
      ];
      for (final String url in tracked) {
        expect(streamVideoBookUid(url), canonical, reason: url);
      }
    });

    test('leading/trailing whitespace does not change identity', () {
      expect(
        streamVideoBookUid('  https://youtu.be/dQw4w9WgXcQ?si=abc  '),
        canonical,
      );
    });

    test('different YouTube videos get different uids', () {
      final String a = streamVideoBookUid('https://youtu.be/dQw4w9WgXcQ');
      final String b = streamVideoBookUid('https://youtu.be/9bZkp7q19f0');
      expect(a, 'video/stream/yt:dQw4w9WgXcQ');
      expect(b, 'video/stream/yt:9bZkp7q19f0');
      expect(a, isNot(b));
    });

    test('YouTube uid still 3-segment video/stream/ family (no prefix clash)',
        () {
      final String uid = streamVideoBookUid('https://youtu.be/dQw4w9WgXcQ');
      expect(uid.startsWith('video/stream/'), isTrue);
      expect(uid.startsWith('video/ext/'), isFalse);
      expect(uid.startsWith('video/playlist/'), isFalse);
      expect(uid.split('/').length, 3);
    });

    test('non-YouTube direct/HLS URLs keep sha1 identity (unchanged behavior)',
        () {
      // 直链保持原 sha1 行为：12 位 hex，不同 URL 各异（query 是签名/token 身份，不归一）。
      const String hls = 'https://cdn.example.com/live.m3u8?token=abc';
      final String uid = streamVideoBookUid(hls);
      final String digest = uid.substring('video/stream/'.length);
      expect(uid.startsWith('video/stream/'), isTrue);
      expect(RegExp(r'^[0-9a-f]{12}$').hasMatch(digest), isTrue);
      // 直链带不同 token → 不同身份（不被误合并）。
      expect(
        streamVideoBookUid('https://cdn.example.com/live.m3u8?token=xyz'),
        isNot(uid),
      );
      // YouTube 与直链身份形状不同（前者 yt: 前缀，后者 hex）。
      expect(digest.startsWith('yt:'), isFalse);
    });

    test('unparseable YouTube-host URL falls back to sha1 (no crash)', () {
      // youtube.com 根 URL 无 videoId → youtubeVideoIdOrNull 返 null → 回退 sha1。
      final String uid = streamVideoBookUid('https://www.youtube.com/');
      final String digest = uid.substring('video/stream/'.length);
      expect(RegExp(r'^[0-9a-f]{12}$').hasMatch(digest), isTrue);
    });
  });

  group('streamImportCoverStrategy (TODO-1304 封面门控移除守卫)', () {
    test('YouTube URLs -> youtubeThumbnail strategy', () {
      for (final String url in <String>[
        'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://youtu.be/dQw4w9WgXcQ',
        'https://m.youtube.com/watch?v=dQw4w9WgXcQ',
        'https://www.youtube.com/shorts/dQw4w9WgXcQ',
      ]) {
        expect(streamImportCoverStrategy(url),
            StreamImportCoverStrategy.youtubeThumbnail,
            reason: url);
      }
    });

    test(
        'REGRESSION: direct/HLS/m3u8 URLs -> ffmpegFrame (no longer coverless) '
        '— 旧代码把下封面门控在 isYoutubeUrl 内，直链恒无封面', () {
      for (final String url in <String>[
        'https://cdn.example.com/movie.mp4',
        'https://cdn.example.com/live.m3u8',
        'https://192.168.1.34/stream.ts',
        'https://example.com/playlist.m3u8?token=abc',
        // 已知网页视频站但非 YouTube（无法抓缩略图）→ 仍走抽帧（best-effort）。
        'https://www.bilibili.com/video/BVxxx',
      ]) {
        expect(streamImportCoverStrategy(url),
            StreamImportCoverStrategy.ffmpegFrame,
            reason: url);
      }
    });
  });

  group('StreamVideoSpec (TODO-1157 流媒体入库重开规格)', () {
    test('empty spec -> isEmpty true, toStorageJson null', () {
      const StreamVideoSpec spec = StreamVideoSpec();
      expect(spec.isEmpty, isTrue);
      expect(spec.toStorageJson(), isNull);
      expect(spec.httpHeaderFields, isEmpty);
    });

    test('round-trip via storage json preserves fields', () {
      const StreamVideoSpec spec = StreamVideoSpec(
        subtitleUrl: 'https://cdn.example.com/sub.srt',
        subtitleFileName: 'sub.srt',
        referer: 'https://example.com/',
        userAgent: 'HibikiAgent/1.0',
      );
      expect(spec.isEmpty, isFalse);
      final String? json = spec.toStorageJson();
      expect(json, isNotNull);
      final StreamVideoSpec back = StreamVideoSpec.fromStorageJson(json);
      expect(back.subtitleUrl, spec.subtitleUrl);
      expect(back.subtitleFileName, spec.subtitleFileName);
      expect(back.referer, spec.referer);
      expect(back.userAgent, spec.userAgent);
      expect(back.httpHeaderFields, <String, String>{
        'Referer': 'https://example.com/',
        'User-Agent': 'HibikiAgent/1.0',
      });
    });

    test('fromStorageJson tolerates null/empty/garbage -> empty spec', () {
      expect(StreamVideoSpec.fromStorageJson(null).isEmpty, isTrue);
      expect(StreamVideoSpec.fromStorageJson('').isEmpty, isTrue);
      expect(StreamVideoSpec.fromStorageJson('not json').isEmpty, isTrue);
      expect(StreamVideoSpec.fromStorageJson('[1,2]').isEmpty, isTrue);
    });

    test('httpHeaderFields omits empty referer/userAgent', () {
      const StreamVideoSpec spec =
          StreamVideoSpec(subtitleUrl: 'https://x/y.srt');
      expect(spec.isEmpty, isFalse);
      expect(spec.httpHeaderFields, isEmpty);
    });
  });

  group('UrlStreamVideoClient 字幕后置数据模型 (TODO-1307)', () {
    test('preresolvedCues 起播为空、setPreresolvedCues 回填（1302 菜单数据源）', () {
      final UrlStreamVideoClient client = UrlStreamVideoClient(
        streamUrl: 'https://googlevideo.test/stream',
        youtubeCaptionsUrl: 'https://youtu.be/abc',
      );
      expect(client.preresolvedCues, isEmpty);
      expect(client.youtubeCaptionsUrl, 'https://youtu.be/abc');

      final AudioCue cue = AudioCue()
        ..bookKey = 'yt:abc'
        ..sentenceIndex = 0
        ..text = 'こんにちは'
        ..startMs = 0
        ..endMs = 1000
        ..audioFileIndex = 0;
      client.setPreresolvedCues(<AudioCue>[cue]);
      expect(client.preresolvedCues.length, 1);
      expect(client.preresolvedCues.first.text, 'こんにちは');
      client.close();
    });

    test('非 YouTube 直链 client 无 youtubeCaptionsUrl（不触发字幕后置）', () {
      final UrlStreamVideoClient client =
          UrlStreamVideoClient(streamUrl: 'https://cdn.test/live.m3u8');
      expect(client.youtubeCaptionsUrl, isNull);
      expect(client.preresolvedCues, isEmpty);
      client.close();
    });
  });

  group('UrlStreamVideoClient 字幕轨列表 + per-track cue 缓存 (TODO-1302)', () {
    test('setYoutubeCaptionTracks 回填字幕轨列表（选择器数据源，独立于 cue）', () {
      final UrlStreamVideoClient client = UrlStreamVideoClient(
        streamUrl: 'https://googlevideo.test/stream',
        youtubeCaptionsUrl: 'https://youtu.be/abc',
      );
      expect(client.youtubeCaptionTracks, isEmpty);
      client.setYoutubeCaptionTracks(const <YoutubeCaptionTrack>[
        YoutubeCaptionTrack(
          baseUrl: 'https://yt/timedtext?lang=ja',
          languageCode: 'ja',
          languageName: '日本語',
          isAutoGenerated: false,
        ),
      ]);
      expect(client.youtubeCaptionTracks.length, 1);
      expect(client.youtubeCaptionTracks.first.trackKey,
          'youtube:captions:ja:human');
      client.close();
    });

    test('per-track cue 缓存：未缓存空、缓存后命中同轨（重选不重复下载）', () {
      final UrlStreamVideoClient client = UrlStreamVideoClient(
        streamUrl: 'https://googlevideo.test/stream',
        youtubeCaptionsUrl: 'https://youtu.be/abc',
      );
      expect(client.cachedCaptionCues('youtube:captions:ja:human'), isEmpty);
      final AudioCue cue = AudioCue()
        ..bookKey = 'yt:abc'
        ..sentenceIndex = 0
        ..text = 'こんにちは'
        ..startMs = 0
        ..endMs = 1000
        ..audioFileIndex = 0;
      client.cacheCaptionCues('youtube:captions:ja:human', <AudioCue>[cue]);
      expect(client.cachedCaptionCues('youtube:captions:ja:human').length, 1);
      // 别的轨 key 仍空（缓存按 trackKey 隔离）。
      expect(client.cachedCaptionCues('youtube:captions:en:asr'), isEmpty);
      client.close();
    });
  });
}
