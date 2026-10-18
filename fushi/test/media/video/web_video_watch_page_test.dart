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

  test('地址栏：像网址的补 https，其它当搜索词', () {
    expect(webVideoAddressBarTarget('netflix.com'), 'https://netflix.com');
    expect(
      webVideoAddressBarTarget('https://www.youtube.com/watch?v=x'),
      'https://www.youtube.com/watch?v=x',
    );
    expect(
      webVideoAddressBarTarget('日本語 ポッドキャスト'),
      'https://www.google.com/search?q=%E6%97%A5%E6%9C%AC%E8%AA%9E+%E3%83%9D%E3%83%83%E3%83%89%E3%82%AD%E3%83%A3%E3%82%B9%E3%83%88',
    );
    expect(webVideoAddressBarTarget('   '), isNull);
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
}
