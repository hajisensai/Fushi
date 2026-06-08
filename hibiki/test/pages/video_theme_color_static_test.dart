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
    expect(source, contains('fontWeight: _subtitleStyle.fontWeight'));
    expect(source, contains('shadowThickness: _subtitleStyle.shadowThickness'));
    expect(source, isNot(contains('color: Colors.white')));
    expect(source, isNot(contains('color: Colors.black.withValues')));
  });
}
