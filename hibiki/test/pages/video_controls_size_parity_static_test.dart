import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop and mobile controls use shared normal/fullscreen sizing', () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();

    expect(source, contains('static const double _videoButtonBarHeight = 56'));
    expect(source, contains('static const double _videoControlIconSize = 32'));
    expect(
        source, contains('static const double _videoPlayPauseIconSize = 36'));
    expect(source, contains('TextStyle _videoControlTitleStyle(ColorScheme'));
    expect(
      'buttonBarButtonSize: _videoControlIconSize'.allMatches(source).length,
      2,
      reason:
          'media_kit built-in fullscreen buttons must use the same shared icon size as custom controls',
    );
    expect(
      'buttonBarHeight: _videoButtonBarHeight'.allMatches(source).length,
      2,
      reason:
          'normal and fullscreen controls should share one explicit touch-height source',
    );
    expect(
      '_videoControlIconSize'.allMatches(source).length,
      greaterThanOrEqualTo(10),
      reason: 'all top/bottom control buttons should share one icon size',
    );
    expect(
      'iconSize: _videoPlayPauseIconSize'.allMatches(source).length,
      2,
      reason: 'desktop and mobile play buttons should use the same size',
    );
    expect(source, isNot(contains('iconSize: 32')));
    expect(source, isNot(contains('iconSize: 36')));
    expect(
      source,
      isNot(contains(
          'style: const TextStyle(color: Colors.white, fontSize: 16)')),
    );
  });

  test('fullscreen video route is neutralized like the windowed video page',
      () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();

    expect(source, contains('Future<void> _pushNeutralizedVideoFullscreen('),
        reason:
            'media_kit default fullscreen route is outside VideoHibikiPage.neutralized; Hibiki must push its own neutralized route');
    final int helper = source.indexOf(
      'Future<void> _pushNeutralizedVideoFullscreen(',
    );
    expect(helper, greaterThanOrEqualTo(0));
    final int end = source.indexOf('Widget _buildFullscreenButton(', helper);
    expect(end, greaterThan(helper));
    final String helperBody = source.substring(helper, end);

    expect(helperBody, contains('HibikiAppUiScaleNeutralizer('),
        reason: 'fullscreen route must cancel the app-wide UI scale too');
    expect(helperBody, contains('VideoStateInheritedWidget('),
        reason: 'fullscreen route must preserve media_kit video state');
    expect(helperBody, contains('FullscreenInheritedWidget('),
        reason:
            'fullscreen controls must still see media_kit fullscreen context');
    expect(helperBody, contains('width: null'));
    expect(helperBody, contains('height: null'));
    expect(source, contains('toggleFullscreenOnDoublePress: false'),
        reason:
            'package default double-click route is unneutralized; Hibiki should replace it with its own double-click handler');
    expect(source, contains('void _handleVideoPointerUp('),
        reason: 'double-click fullscreen must remain available');
    expect(source, isNot(contains('const MaterialDesktopFullscreenButton()')));
    expect(source, isNot(contains('const MaterialFullscreenButton()')));
  });
}
