// web_video_glue.js 的主视频契约：快照 / 播放命令 / 只留画面共用同一个主视频判据，观看中
// 其余 <video>（YouTube 首页内联预览等）暂停并静音——进入视频后底下的首页预览不再接着播。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _functionBody(String source, String name) {
  final int start = source.indexOf('function $name(');
  expect(start, greaterThanOrEqualTo(0), reason: '缺 $name');
  final int end = source.indexOf('\n  function ', start + 1);
  return source.substring(start, end < 0 ? source.length : end);
}

void main() {
  final String glue = File(
    'assets/web_video/web_video_glue.js',
  ).readAsStringSync();

  test('video() 走 mainVideo()，不再取 DOM 里第一个 <video>', () {
    final String body = _functionBody(glue, 'video');
    expect(body.contains('mainVideo()'), isTrue);
    expect(body.contains("querySelector('video')"), isFalse);
  });

  test('YouTube 主视频限定在 #movie_player 里（首页预览也带 html5-main-video 类）', () {
    final String body = _functionBody(glue, 'siteMainVideo');
    expect(body.contains('#movie_player video'), isTrue);
    expect(
      _functionBody(glue, 'mainVideo').contains('siteMainVideo()'),
      isTrue,
    );
  });

  test('每轮采样都让非主视频暂停并静音（观看页或播放器档）', () {
    final String silence = _functionBody(glue, 'silenceStrayVideos');
    expect(silence.contains('v === main'), isTrue);
    expect(silence.contains('.pause()'), isTrue);
    expect(silence.contains('muted = true'), isTrue);
    expect(silence.contains('videoOnlyOn'), isTrue);
    expect(silence.contains('youtubeWatchPage()'), isTrue);
    expect(
      _functionBody(glue, 'sample').contains('silenceStrayVideos()'),
      isTrue,
    );
  });
}
