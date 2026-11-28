import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/web_video_session.dart';

import '../../helpers/source_guard.dart';

/// BUG-5611：「制卡优先」档（composition 宿主 + WGC 离屏截取）的 WebView2 环境带了
/// `--disable-direct-composition`，WebView2 158 上浏览器进程不再往宿主 visual 出画面，播放页
/// 视频区整片白。可捕获环境的参数必须保留 DirectComposition（只关视频 overlay）。
void main() {
  List<String> switchesOf(String arguments) => arguments
      .split(RegExp(r'\s+'))
      .where((String s) => s.isNotEmpty)
      .map((String s) => s.split('=').first)
      .toList();

  test('可捕获环境不关 DirectComposition（整词匹配）', () {
    final List<String> switches = switchesOf(
      kWebVideoCapturableBrowserArguments,
    );
    expect(switches, isNot(contains('--disable-direct-composition')));
    expect(switches, isNot(contains('--disable-gpu')));
    expect(switches, isNot(contains('--disable-gpu-compositing')));
  });

  test('可捕获环境保留自动播放、只关视频 overlay', () {
    final List<String> switches = switchesOf(
      kWebVideoCapturableBrowserArguments,
    );
    expect(switches, contains('--autoplay-policy'));
    expect(switches, contains('--disable-direct-composition-video-overlays'));
  });

  test('环境单例用的就是这份参数，不在调用处另写字面量', () {
    final String code = compactCode(
      File('lib/src/media/video/web_video_session.dart').readAsStringSync(),
    );
    final int start = code.indexOf(
      'Future<WebViewEnvironment>webVideoCapturableEnvironment()',
    );
    expect(start, greaterThanOrEqualTo(0));
    final int end = code.indexOf(
      'voiddiscardWebVideoCapturableEnvironment',
      start,
    );
    expect(end, greaterThan(start));
    final String body = code.substring(start, end);
    expect(
      body,
      contains(
        'additionalBrowserArguments:kWebVideoCapturableBrowserArguments',
      ),
    );
  });
}
