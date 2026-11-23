import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/backgrounds/url_background.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';

import '../visualizer_test_helpers.dart';
import 'background_test_helpers.dart';

void main() {
  test('只认 http(s) 链接', () {
    expect(
      urlBackgroundLinkOf(' https://example.com/a.jpg '),
      'https://example.com/a.jpg',
    );
    expect(urlBackgroundLinkOf('http://x.org/b.png'), 'http://x.org/b.png');
    expect(urlBackgroundLinkOf('file:///etc/passwd'), isNull);
    expect(urlBackgroundLinkOf('C:/Users/a.png'), isNull);
    expect(urlBackgroundLinkOf('https://'), isNull);
    expect(urlBackgroundLinkOf(''), isNull);
  });

  test('链接输入框只在「图片链接」来源时显示', () {
    final LyricVisualizerTuningSpec link = urlBackgroundTunings.firstWhere(
      (LyricVisualizerTuningSpec s) => s.key == UrlBackgroundKeys.url,
    );
    expect(
      link.visibleWhen!(LyricVisualizerTuning.defaults(urlBackgroundTunings)),
      isFalse,
    );
    expect(
      link.visibleWhen!(
        LyricVisualizerTuning(urlBackgroundTunings, const <String, Object?>{
          UrlBackgroundKeys.source: kUrlBackgroundSourceLink,
        }),
      ),
      isTrue,
    );
  });

  testWidgets('还没有图：只铺底色（folia 没选网页时什么都不画）', (WidgetTester tester) async {
    final Uint8List px = await renderScene(
      tester,
      UrlBackgroundScene(),
      backgroundContext(),
      LyricVisualizerTuning(urlBackgroundTunings, const <String, Object?>{
        UrlBackgroundKeys.source: kUrlBackgroundSourceLink,
        UrlBackgroundKeys.url: 'not a url',
      }),
    );
    final Color bg = backgroundContext().palette.background;
    expect(px[0], (bg.r * 255).round());
    expect(px.sublist(0, 4), px.sublist(px.length - 4));
  });

  group('冒烟', () {
    testWidgets('图片链接来源（无效链接）+ 有音频', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        urlBackgroundEntry,
        audio: SyntheticVisualizerAudio(),
        tuning: const <String, Object?>{
          UrlBackgroundKeys.source: kUrlBackgroundSourceLink,
          UrlBackgroundKeys.url: 'ftp://nope',
        },
      );
    });
    testWidgets('素材来源 + 减弱动态效果 + 窄屏', (WidgetTester tester) async {
      await pumpBackgroundAcross(
        tester,
        urlBackgroundEntry,
        motion: false,
        playing: false,
        size: const Size(390, 844),
      );
    });
    test('已注册', () {
      expect(lyricVisualizerBackgroundOf('url'), same(urlBackgroundEntry));
    });
  });
}
