import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/url_stream_video.dart';
import 'package:hibiki/src/media/video/video_player_controller.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
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
}
