import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/video/url_stream_video.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;
import 'package:hibiki/src/media/video/youtube_source_resolver.dart';

void main() {
  group('isYoutubeUrl', () {
    test('accepts watch and youtu.be', () {
      expect(isYoutubeUrl('https://www.youtube.com/watch?v=abc123'), true);
      expect(isYoutubeUrl('https://youtu.be/abc123'), true);
    });
    test('rejects non-youtube', () {
      expect(isYoutubeUrl('https://www.netflix.com/watch/1'), false);
      expect(isYoutubeUrl('/local/file.mp4'), false);
    });
  });

  group('parseYoutubeTimedTextToCues', () {
    test('converts timedtext XML to cues with ms bounds', () {
      const xml = '<transcript>'
          '<text start="1.5" dur="2.0">走り出した</text>'
          '<text start="4.0" dur="1.5">こんにちは</text>'
          '</transcript>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:abc');
      expect(cues.length, 2);
      expect(cues[0].text, '走り出した');
      expect(cues[0].startMs, 1500);
      expect(cues[0].endMs, 3500);
      expect(cues[1].startMs, 4000);
      expect(cues[1].endMs, 5500);
    });
    test('decodes entities and skips empty', () {
      const xml =
          '<transcript><text start="0" dur="1">&#39;</text><text start="1" dur="1"></text></transcript>';
      final cues = parseYoutubeTimedTextToCues(content: xml, bookKey: 'yt:x');
      expect(cues.length, 1);
      expect(cues[0].text, "'");
    });
  });

  // TODO-1159 M0：导入对话框「网页地址」软警告的判定谓词——命中已知网页视频站
  // 且不是 YouTube 时才警告（YouTube 已由 resolveYoutubeSource 支持解析）。这里断言
  // 该组合谓词的真值表，守卫 YouTube 抑制 / 非 YouTube 保留不被回退。
  group('webpage warning suppression predicate (TODO-1159 M0)', () {
    bool warns(String url) => isKnownWebPageVideoUrl(url) && !isYoutubeUrl(url);
    test('YouTube 各形态一律不警告', () {
      expect(warns('https://www.youtube.com/watch?v=abc123'), isFalse);
      expect(warns('https://youtu.be/abc123'), isFalse);
      expect(warns('https://m.youtube.com/watch?v=abc'), isFalse);
      expect(warns('https://music.youtube.com/watch?v=abc'), isFalse);
      expect(warns('https://www.youtube-nocookie.com/embed/abc'), isFalse);
    });
    test('非 YouTube 网页视频站仍保留警告', () {
      expect(warns('https://www.netflix.com/watch/1'), isTrue);
      expect(warns('https://www.bilibili.com/video/BV1'), isTrue);
      expect(warns('https://www.nicovideo.jp/watch/sm1'), isTrue);
    });
    test('普通直链不警告', () {
      expect(warns('https://cdn.example.com/a.m3u8'), isFalse);
      expect(warns('https://example.com/video.mp4'), isFalse);
    });
  });

  // TODO-1307 A1：多 client 兜底顺序——androidVr 首选（零回归），失败才回落 ios、tv。
  group('A1 多 client 兜底顺序 (TODO-1307)', () {
    test('kYoutubeManifestClientFallback = androidVr -> ios -> tv', () {
      expect(kYoutubeManifestClientFallback.length, 3);
      expect(
        identical(
            kYoutubeManifestClientFallback[0], yt.YoutubeApiClient.androidVr),
        isTrue,
        reason: 'androidVr 必须首选（其直链无需签名解密、libmpv 普通 UA 可拉取）',
      );
      expect(
        identical(kYoutubeManifestClientFallback[1], yt.YoutubeApiClient.ios),
        isTrue,
      );
      expect(
        identical(kYoutubeManifestClientFallback[2], yt.YoutubeApiClient.tv),
        isTrue,
      );
    });
  });

  // TODO-1307 字幕后置入口：best-effort，无法解析出 videoId 时返回空 cue，绝不抛/阻断播放。
  group('resolveYoutubeCaptions best-effort (TODO-1307)', () {
    test('无法解析的 URL -> 空 cue、不联网、不抛', () async {
      expect(await resolveYoutubeCaptions('not a youtube url'), isEmpty);
      expect(await resolveYoutubeCaptions(''), isEmpty);
    });
  });
}
