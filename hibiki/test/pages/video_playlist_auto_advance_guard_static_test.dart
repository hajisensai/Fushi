import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final String pageSource = File(
    'lib/src/pages/implementations/video_hibiki_page.dart',
  ).readAsStringSync();

  test('_applyLoad binds completed callback before controller.load', () {
    final String fn = _functionSource(
      pageSource,
      '  Future<void> _applyLoad({',
      '  /// 位置持久化',
    );
    final int bindAt =
        fn.indexOf('controller.setOnCompleted(_handlePlaybackCompleted);');
    final int loadAt = fn.indexOf('await controller.load(');

    expect(bindAt, greaterThan(-1),
        reason: 'page must bind EOF handling before opening media');
    expect(loadAt, greaterThan(-1));
    expect(bindAt, lessThan(loadAt),
        reason: 'completed can fire during/just after load, so bind first');
  });

  test(
      'completed handler has reentry, mounted, playlist, and last-episode guards',
      () {
    expect(pageSource, contains('bool _autoAdvanceInFlight = false'));
    final String fn = _functionSource(
      pageSource,
      '  void _handlePlaybackCompleted() {',
      '  /// 共享 load 装配',
    );

    expect(fn, contains('if (_autoAdvanceInFlight) return'));
    expect(fn, contains('if (!mounted) return'));
    expect(fn, contains('nextPlaylistIndexAfterCompletion('));
    expect(fn, contains('if (nextEpisode == null) return'));
    expect(fn, contains('await _switchEpisode(nextEpisode)'),
        reason:
            'non-last EOF must reuse existing switch flow and saved positions');
  });

  test('_applyLoad prewarms current video and then next playlist episode', () {
    final String fn = _functionSource(
      pageSource,
      '  Future<void> _applyLoad({',
      '    // 首次 load 建观看统计采集器',
    );
    final int currentAt =
        fn.indexOf('unawaited(prewarmEmbeddedSubtitleCache(videoPath));');
    final int nextAt = fn.indexOf('_prewarmNextEpisodeSubtitleCache();');

    expect(currentAt, greaterThan(-1));
    expect(nextAt, greaterThan(currentAt),
        reason: 'next episode should be warmed after the current file warmup');
    expect(pageSource, contains('String? _lastPrewarmedEpisodePath'));
  });
}

String _functionSource(String source, String start, String end) {
  final int startIndex = source.indexOf(start);
  expect(startIndex, isNonNegative, reason: 'Missing start marker: $start');
  final int endIndex = source.indexOf(end, startIndex + start.length);
  expect(endIndex, isNonNegative, reason: 'Missing end marker: $end');
  return source.substring(startIndex, endIndex);
}
