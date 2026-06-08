import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desktop and mobile controls use shared normal/fullscreen sizing', () {
    final String source =
        File('lib/src/pages/implementations/video_hibiki_page.dart')
            .readAsStringSync();

    expect(source, contains('static const double _videoControlIconSize = 32'));
    expect(
        source, contains('static const double _videoPlayPauseIconSize = 36'));
    expect(source, contains('static const TextStyle _videoControlTitleStyle'));
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
}
