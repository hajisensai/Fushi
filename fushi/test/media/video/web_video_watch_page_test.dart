import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/media/video/web_video_session.dart';

/// 网页档 / 播放器档的自动判据：只有「正在看某一集」的地址才自动进播放器档，浏览 / 详情页上的
/// 预告片与悬停预览留在网页档让用户选集。
void main() {
  test('Netflix：只有 /watch/<id> 是播放页', () {
    expect(
      webVideoIsWatchPage('https://www.netflix.com/watch/81234567'),
      isTrue,
    );
    expect(
      webVideoIsWatchPage('https://www.netflix.com/watch/81234567?trackId=1'),
      isTrue,
    );
    expect(webVideoIsWatchPage('https://www.netflix.com/browse'), isFalse);
    expect(
      webVideoIsWatchPage('https://www.netflix.com/title/80100172'),
      isFalse,
    );
    expect(
      webVideoIsWatchPage('https://www.netflix.com/browse?jbv=80100172'),
      isFalse,
    );
  });

  test('YouTube：watch / shorts / live / embed 与 youtu.be 是播放页', () {
    expect(webVideoIsWatchPage('https://www.youtube.com/watch?v=abc'), isTrue);
    expect(webVideoIsWatchPage('https://m.youtube.com/shorts/abc'), isTrue);
    expect(webVideoIsWatchPage('https://www.youtube.com/live/abc'), isTrue);
    expect(webVideoIsWatchPage('https://www.youtube.com/embed/abc'), isTrue);
    expect(webVideoIsWatchPage('https://youtu.be/abc'), isTrue);
    expect(webVideoIsWatchPage('https://www.youtube.com/'), isFalse);
    expect(webVideoIsWatchPage('https://www.youtube.com/@channel'), isFalse);
    expect(webVideoIsWatchPage('https://www.youtube.com/results?q=x'), isFalse);
  });

  test('其它站点有视频就算（没有可靠的地址形状）', () {
    expect(webVideoIsWatchPage('https://tver.jp/episodes/ep1'), isTrue);
  });

  test('广告快照：ad 标记解析出来，缺省为 false', () {
    expect(parseWebVideoStatePayload(<String, Object>{'ad': true})!.ad, isTrue);
    expect(parseWebVideoStatePayload(<String, Object>{})!.ad, isFalse);
  });

  test('站点给的集名 / 封面候选解析出来，缺省为空串', () {
    final WebVideoPlaybackState s = parseWebVideoStatePayload(<String, Object>{
      'vtitle': ' 本当の名前 ',
      'vimg': 'https://example.com/a.jpg',
    })!;
    expect(s.videoTitle, '本当の名前');
    expect(s.imageUrl, 'https://example.com/a.jpg');
    expect(parseWebVideoStatePayload(<String, Object>{})!.videoTitle, isEmpty);
  });
  test('Netflix 字幕轨清单：每轨一行 id/lang/名，末行当前轨；坏行跳过', () {
    const String raw = 'T1\tja\t日本語\nT2\ten\tEnglish [CC]\n\tbad\n#T2';
    final WebVideoPlaybackState? state = parseWebVideoStatePayload(
      <String, Object?>{'href': 'https://www.netflix.com/watch/1', 'nftt': raw},
    );
    expect(state!.siteTracks, const <WebVideoSiteTrack>[
      WebVideoSiteTrack(id: 'T1', lang: 'ja', name: '日本語'),
      WebVideoSiteTrack(id: 'T2', lang: 'en', name: 'English [CC]'),
    ]);
    expect(state.siteTrackCurrent, 'T2');
    expect(parseWebVideoSiteTrackCurrent('T1\tja\tx\n#'), '');
    expect(parseWebVideoSiteTracks(null), isEmpty);
    expect(parseWebVideoStatePayload(<String, Object?>{})!.siteTracks, isEmpty);
  });
}
