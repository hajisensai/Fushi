import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('video subtitles and chrome derive visible colors from ColorScheme', () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();

    expect(source, contains('_subtitleTextColor(ColorScheme'));
    expect(source, contains('_videoChromeColorScheme'));
    expect(source, contains('_videoControlTitleStyle(ColorScheme'));
    expect(source, contains('_osdSurfaceColor(ColorScheme'));
    expect(source, contains('_osdTextColor(ColorScheme'));
    expect(source, contains('_subtitleStyle.resolveTextColor('));
    expect(source, contains('_subtitleStyle.resolveShadowColor('));
    expect(source, contains('_subtitleStyle.resolveBackgroundColor('));
    expect(source, contains('double get _videoUiScale => appModel.appUiScale'));
    expect(source, contains('_subtitleStyle.resolveFontWeight('));
    expect(source, contains('_subtitleStyle.resolveShadowThickness('));
    expect(source, contains('uiScale: _videoUiScale'));
    expect(source, isNot(contains('HibikiAppUiScale.of(context)')));
    expect(source, isNot(contains('fontWeight: _subtitleStyle.fontWeight')));
    expect(source,
        isNot(contains('shadowThickness: _subtitleStyle.shadowThickness')));
    expect(source, isNot(contains('color: Colors.white')));
    expect(source, isNot(contains('color: Colors.black.withValues')));
  });

  test('video letterbox/pillarbox fill is solid black (TODO-053)', () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();

    // 播放器画面外围（letterbox/pillarbox）按播放器惯例固定纯黑，不跟随主题 surface。
    expect(source, contains('fill: Colors.black,'));
    expect(
      source,
      isNot(contains('fill: Theme.of(context).colorScheme.surface')),
    );
  });
}
