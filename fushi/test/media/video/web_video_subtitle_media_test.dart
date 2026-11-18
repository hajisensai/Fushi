import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/video_stream_subtitle_audio.dart';
import 'package:fushi/src/media/video/web_video_subtitle_media.dart';
import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show YoutubeAudioStream;

/// glue `mediaSource()` 回执的形状（见 web_video_glue_js_test.dart 的同名用例）。
String _probe({
  bool hasVideo = true,
  String src = '',
  bool eme = false,
  List<Object?> manifests = const <Object?>[],
  String ua = 'Mozilla/5.0 Edg/140',
}) => jsonEncode(<String, Object?>{
  'href': 'https://evil.example/ignored',
  'ua': ua,
  'hasVideo': hasVideo,
  'src': src,
  'eme': eme,
  'manifests': manifests,
});

void main() {
  group('parseWebVideoMediaProbe', () {
    test('解析 JSON 字符串与 Map；清单只收 http(s)', () {
      final WebVideoMediaProbe probe = parseWebVideoMediaProbe(
        _probe(
          src: 'blob:https://a.example/x',
          manifests: <Object?>[
            'https://cdn.example/master.m3u8',
            'file:///C:/secret.m3u8',
            'javascript:alert(1)//.m3u8',
            42,
          ],
        ),
      )!;
      expect(probe.hasVideo, isTrue);
      expect(probe.src, 'blob:https://a.example/x');
      expect(probe.userAgent, 'Mozilla/5.0 Edg/140');
      expect(probe.manifests, <String>['https://cdn.example/master.m3u8']);
      expect(
        parseWebVideoMediaProbe(<String, Object?>{'hasVideo': true})!.hasVideo,
        isTrue,
      );
    });

    test('坏形状回 null', () {
      expect(parseWebVideoMediaProbe(null), isNull);
      expect(parseWebVideoMediaProbe('not json'), isNull);
      expect(parseWebVideoMediaProbe('[1]'), isNull);
    });
  });

  group('resolveWebVideoSubtitleMedia', () {
    const String page = 'https://anime.example/ep/1';

    WebVideoSubtitleMedia resolve(String raw, {String pageUrl = page}) =>
        resolveWebVideoSubtitleMedia(
          parseWebVideoMediaProbe(raw),
          pageUrl: pageUrl,
        );

    test('没有视频 / 回执坏了 → noVideo', () {
      expect(
        resolve(_probe(hasVideo: false)).block,
        WebVideoSubtitleMediaBlock.noVideo,
      );
      expect(
        resolveWebVideoSubtitleMedia(null, pageUrl: page).block,
        WebVideoSubtitleMediaBlock.noVideo,
      );
    });

    test('EME 加密流优先拦下（YouTube 付费片也一样）', () {
      expect(
        resolve(_probe(eme: true, src: 'https://cdn.example/a.mp4')).block,
        WebVideoSubtitleMediaBlock.encrypted,
      );
      expect(
        resolve(
          _probe(eme: true),
          pageUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        ).block,
        WebVideoSubtitleMediaBlock.encrypted,
      );
    });

    test('YouTube 观看页按视频 id 走现取 audio-only 流，不读页面地址', () {
      final WebVideoSubtitleMedia media = resolve(
        _probe(src: 'blob:https://www.youtube.com/x'),
        pageUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
      );
      expect(media.block, isNull);
      expect(media.kind, WebVideoSubtitleMediaKind.youtube);
      expect(media.youtubeId, 'dQw4w9WgXcQ');
      expect(media.hasPicture, isFalse);
    });

    test('http(s) 直链按后缀分形态', () {
      final WebVideoSubtitleMedia mp4 = resolve(
        _probe(src: 'https://cdn.example/v/ep1.mp4?sig=1'),
      );
      expect(mp4.kind, WebVideoSubtitleMediaKind.direct);
      expect(mp4.url, 'https://cdn.example/v/ep1.mp4?sig=1');
      expect(mp4.hasPicture, isTrue);
      expect(
        resolve(_probe(src: 'https://cdn.example/v/index.m3u8')).kind,
        WebVideoSubtitleMediaKind.hls,
      );
    });

    test('MSE（blob:）用这个视频最早的 HLS 清单，没有 HLS 再用 DASH', () {
      final WebVideoSubtitleMedia hls = resolve(
        _probe(
          src: 'blob:https://anime.example/x',
          manifests: <Object?>[
            'https://cdn.example/manifest.mpd',
            'https://cdn.example/master.m3u8',
            'https://cdn.example/720p.m3u8',
          ],
        ),
      );
      expect(hls.kind, WebVideoSubtitleMediaKind.hls);
      expect(hls.url, 'https://cdn.example/master.m3u8');
      final WebVideoSubtitleMedia dash = resolve(
        _probe(
          src: 'blob:https://anime.example/x',
          manifests: <Object?>['https://cdn.example/manifest.mpd'],
        ),
      );
      expect(dash.kind, WebVideoSubtitleMediaKind.dash);
    });

    test('MSE 而页面没有请求过清单 → noMediaAddress', () {
      expect(
        resolve(_probe(src: 'blob:https://anime.example/x')).block,
        WebVideoSubtitleMediaBlock.noMediaAddress,
      );
    });
  });

  test('请求头：UA / Referer / Cookie，空值不带', () {
    expect(
      webVideoMediaRequestHeaders(
        userAgent: 'UA',
        referer: 'https://a.example/ep',
        cookie: 'sid=1',
      ),
      <String, String>{
        'User-Agent': 'UA',
        'Referer': 'https://a.example/ep',
        'Cookie': 'sid=1',
      },
    );
    expect(
      webVideoMediaRequestHeaders(userAgent: '', referer: '', cookie: ''),
      isEmpty,
    );
    expect(
      webVideoCookieHeader(<(String, String)>[
        ('sid', '1'),
        ('', 'x'),
        ('cf', 'a=b'),
      ]),
      'sid=1; cf=a=b',
    );
  });

  group('prepareWebVideoSubtitleAudio', () {
    test('其它站点：页面给的清单 + 页面同一身份的请求头（Cookie 按媒体地址取）', () async {
      final List<String> cookieAsked = <String>[];
      final VideoStreamSubtitleAudioInput input =
          await prepareWebVideoSubtitleAudio(
            probe: () async => _probe(
              src: 'blob:https://anime.example/x',
              manifests: <Object?>['https://cdn.example/master.m3u8'],
            ),
            pageUrl: 'https://anime.example/ep/1',
            cookieHeader: (String url) async {
              cookieAsked.add(url);
              return 'sid=1';
            },
          );
      expect(input.url, 'https://cdn.example/master.m3u8');
      expect(input.headers, <String, String>{
        'User-Agent': 'Mozilla/5.0 Edg/140',
        'Referer': 'https://anime.example/ep/1',
        'Cookie': 'sid=1',
      });
      expect(input.audioStreamIndex, isNull);
      expect(cookieAsked, <String>['https://cdn.example/master.m3u8']);
    });

    test('YouTube：现取 audio-only 流并登记中继，带回放请求头', () async {
      final List<String> resolved = <String>[];
      final VideoStreamSubtitleAudioInput input =
          await prepareWebVideoSubtitleAudio(
            probe: () async => _probe(src: 'blob:https://www.youtube.com/x'),
            pageUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
            cookieHeader: (String url) async =>
                fail('YouTube 不读页面 cookie: $url'),
            youtubeAudio: (String id) async {
              resolved.add(id);
              return const YoutubeAudioStream(
                url: 'https://r1.googlevideo.com/videoplayback?id=1',
                httpHeaders: <String, String>{'User-Agent': 'yt'},
              );
            },
            relay: (String url, Map<String, String> headers) async =>
                'http://127.0.0.1:9/relay?u=${Uri.encodeComponent(url)}',
          );
      expect(resolved, <String>['dQw4w9WgXcQ']);
      expect(input.url, startsWith('http://127.0.0.1:9/relay?u='));
      expect(input.headers, <String, String>{'User-Agent': 'yt'});
    });

    test('拿不到媒体抛 WebVideoSubtitleMediaBlocked（带原因）', () async {
      await expectLater(
        prepareWebVideoSubtitleAudio(
          probe: () async => _probe(eme: true),
          pageUrl: 'https://www.netflix.com/watch/1',
          cookieHeader: (String _) async => '',
        ),
        throwsA(
          isA<WebVideoSubtitleMediaBlocked>().having(
            (WebVideoSubtitleMediaBlocked e) => e.reason,
            'reason',
            WebVideoSubtitleMediaBlock.encrypted,
          ),
        ),
      );
      await expectLater(
        prepareWebVideoSubtitleAudio(
          probe: () async => null,
          pageUrl: 'https://anime.example/ep/1',
          cookieHeader: (String _) async => '',
        ),
        throwsA(
          isA<WebVideoSubtitleMediaBlocked>().having(
            (WebVideoSubtitleMediaBlocked e) => e.reason,
            'reason',
            WebVideoSubtitleMediaBlock.noVideo,
          ),
        ),
      );
    });
  });

  test('参考画面：有画面的地址带请求头；YouTube / 拿不到媒体为 null', () async {
    final ({String url, Map<String, String> headers})? frame =
        await webVideoSubtitleFrameInput(
          probe: () async => _probe(src: 'https://cdn.example/ep1.mp4'),
          pageUrl: 'https://anime.example/ep/1',
          cookieHeader: (String _) async => 'sid=1',
        );
    expect(frame?.url, 'https://cdn.example/ep1.mp4');
    expect(frame?.headers['Cookie'], 'sid=1');
    expect(
      await webVideoSubtitleFrameInput(
        probe: () async => _probe(),
        pageUrl: 'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
        cookieHeader: (String _) async => '',
      ),
      isNull,
    );
    expect(
      await webVideoSubtitleFrameInput(
        probe: () async => _probe(src: 'blob:https://anime.example/x'),
        pageUrl: 'https://anime.example/ep/1',
        cookieHeader: (String _) async => '',
      ),
      isNull,
    );
  });

  test('入口判据：播放器档、已落书、未加密、能跑 ASR 缺一不可', () {
    bool gate({
      bool webMode = true,
      bool playerMode = true,
      bool episodeBound = true,
      bool encrypted = false,
      bool asrSupported = true,
    }) => webVideoSubtitlePipelineAvailable(
      webMode: webMode,
      playerMode: playerMode,
      episodeBound: episodeBound,
      encrypted: encrypted,
      asrSupported: asrSupported,
    );
    expect(gate(), isTrue);
    expect(gate(webMode: false), isFalse);
    expect(gate(playerMode: false), isFalse);
    expect(gate(episodeBound: false), isFalse);
    expect(gate(encrypted: true), isFalse);
    expect(gate(asrSupported: false), isFalse);
  });

  test('生成字幕轨：key 挂在视频 key 下，语言码取自导出名', () {
    expect(webVideoGeneratedTrackKey('yt-abc'), 'yt-abc|fushi-generated');
    expect(
      webVideoGeneratedSubtitleLanguage('C:/x/Ep 1 [0123abcd].ja.srt'),
      'ja',
    );
    expect(
      webVideoGeneratedSubtitleLanguage('/x/Ep 1 [k].zh-Hans.srt'),
      'zh-Hans',
    );
    expect(webVideoGeneratedSubtitleLanguage('/x/plain.srt'), isNull);
  });
}
