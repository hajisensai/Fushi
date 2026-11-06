import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/web_video_sites.dart';

/// 「在线源 › 网站」：站点入口不落库，播起的每一集按规范地址落成一本流媒体书。
void main() {
  test('每一集的规范地址：去跟踪参数，YouTube 与导入同一身份', () {
    expect(
      webVideoEpisodeUrl(
        'https://www.netflix.com/watch/81234567?trackId=255&tctx=0',
      ),
      'https://www.netflix.com/watch/81234567',
    );
    const String yt = 'https://www.youtube.com/watch?v=D8uACXBAqkE&t=42s';
    expect(
      webVideoEpisodeUrl(yt),
      'https://www.youtube.com/watch?v=D8uACXBAqkE',
    );
    expect(
      streamVideoBookUid(webVideoEpisodeUrl(yt)!),
      streamVideoBookUid('https://www.youtube.com/watch?v=D8uACXBAqkE'),
    );
    expect(
      webVideoEpisodeUrl('https://youtu.be/D8uACXBAqkE'),
      'https://www.youtube.com/watch?v=D8uACXBAqkE',
    );
    expect(
      webVideoEpisodeUrl('https://tver.jp/episodes/ep1#top'),
      'https://tver.jp/episodes/ep1',
    );
    expect(webVideoEpisodeUrl('about:blank'), isNull);
  });

  test('集名：去站名后缀；站点只给站名时用「站名 · 集 id」', () {
    expect(
      webVideoEpisodeTitle(
        pageTitle: 'Some talk - YouTube',
        episodeUrl: 'https://www.youtube.com/watch?v=abc',
        siteTitle: 'YouTube',
      ),
      'Some talk',
    );
    expect(
      webVideoEpisodeTitle(
        pageTitle: 'Netflix',
        episodeUrl: 'https://www.netflix.com/watch/81234567',
        siteTitle: 'Netflix',
      ),
      'Netflix · 81234567',
    );
  });

  test('站名默认取去掉 www. 的 host', () {
    expect(webVideoSiteDefaultTitle('https://www.tver.jp/'), 'tver.jp');
  });

  test('自加站点的偏好编解码：坏条目跳过', () {
    const List<WebVideoSite> sites = <WebVideoSite>[
      WebVideoSite(title: 'TVer', url: 'https://tver.jp/'),
    ];
    expect(decodeWebVideoSites(encodeWebVideoSites(sites)), sites);
    expect(
      decodeWebVideoSites('[{"url":"nope"},{"url":"https://abema.tv/"}]'),
      const <WebVideoSite>[
        WebVideoSite(title: 'abema.tv', url: 'https://abema.tv/'),
      ],
    );
    expect(decodeWebVideoSites('not json'), isEmpty);
    expect(decodeWebVideoSites(null), isEmpty);
  });

  test('站点入口的伪书不是任何库里的书身份', () {
    final String uid = webVideoSiteRow(
      const WebVideoSite(
        title: 'Netflix',
        url: 'https://www.netflix.com/browse',
      ),
    ).bookUid;
    expect(isWebVideoSiteBookUid(uid), isTrue);
    expect(uid.startsWith('video/stream/'), isFalse);
  });

  test('网站分区只在 Windows 出现', () {
    expect(webVideoSitesAvailable(platform: TargetPlatform.windows), isTrue);
    expect(webVideoSitesAvailable(platform: TargetPlatform.android), isFalse);
    expect(webVideoSitesAvailable(platform: TargetPlatform.macOS), isFalse);
  });

  test('Netflix / YouTube 不是某一集的页面不落库', () {
    expect(webVideoEpisodeUrl('https://www.youtube.com/'), isNull);
    expect(webVideoEpisodeUrl('https://www.youtube.com/@channel'), isNull);
    expect(webVideoEpisodeUrl('https://www.netflix.com/browse'), isNull);
    expect(
      webVideoEpisodeUrl('https://www.netflix.com/title/80100172'),
      isNull,
    );
  });

  test('占位书名：「站名 · 集 id」/ 光站名；真名不算', () {
    const String yt = 'https://www.youtube.com/watch?v=QN-imnDC0PM';
    expect(
      webVideoEpisodeTitleIsPlaceholder('YouTube · QN-imnDC0PM', yt),
      isTrue,
    );
    expect(webVideoEpisodeTitleIsPlaceholder('YouTube', yt), isTrue);
    expect(
      webVideoEpisodeTitleIsPlaceholder('Japanese Podcast 日本超市', yt),
      isFalse,
    );
    const String nf = 'https://www.netflix.com/watch/81234567';
    expect(webVideoEpisodeTitleIsPlaceholder('Netflix · 81234567', nf), isTrue);
    expect(webVideoEpisodeTitleIsPlaceholder('葬送のフリーレン · 第1話', nf), isFalse);
  });

  test('封面：YouTube 用缩略图，其它站点用页面 og:image', () {
    expect(
      webVideoEpisodeCoverUrl('https://www.youtube.com/watch?v=QN-imnDC0PM'),
      contains('QN-imnDC0PM'),
    );
    expect(
      webVideoEpisodeCoverUrl(
        'https://www.netflix.com/watch/81234567',
        pageImage: 'https://example.com/a.jpg',
      ),
      'https://example.com/a.jpg',
    );
    expect(
      webVideoEpisodeCoverUrl('https://www.netflix.com/watch/81234567'),
      isNull,
    );
  });
}
