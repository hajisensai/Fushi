import 'package:flutter_test/flutter_test.dart';

import 'video_hibiki_page_source_corpus.dart';

void main() {
  final String pageSource = readVideoHibikiSource();

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
      'completed handler gates on the auto-play-next toggle + playlist '
      'and reentry guards (TODO-639)', () {
    expect(pageSource, contains('bool _autoAdvanceInFlight = false'));
    final String fn = _functionSource(
      pageSource,
      '  void _handlePlaybackCompleted() {',
      '  /// 启动自动连播倒计时',
    );

    expect(fn, contains('if (!mounted) return'));
    expect(fn, contains('nextPlaylistIndexAfterCompletion('));
    // TODO-639: the advance decision is the pure predicate gating on the
    // user's auto-play-next preference, next-episode existence, and reentry.
    expect(fn, contains('shouldAutoPlayNextOnCompletion('));
    expect(fn, contains('autoPlayNextEnabled: appModel.videoAutoPlayNext'),
        reason: 'EOF advance must honour the auto-play-next toggle');
    expect(fn, contains('hasNextEpisode: nextEpisode != null'));
    expect(fn, contains('alreadyAdvancing: _autoAdvanceInFlight'));
    // EOF no longer advances immediately; it starts a cancelable countdown.
    expect(fn, contains('_startAutoAdvanceCountdown('));

    // The real advance keeps the reentry guard + autoAdvance intent.
    final String runFn = _functionSource(
      pageSource,
      '  void _runAutoAdvance(int targetEpisode) {',
      '  /// 切到第 [index] 集',
    );
    expect(runFn, contains('if (_autoAdvanceInFlight) return'));
    expect(runFn, contains('if (!mounted) return'));
    expect(runFn, contains('intent: EpisodeStartIntent.autoAdvance'),
        reason:
            'non-last EOF must carry autoAdvance intent instead of reusing saved near-end positions');
  });

  test('the cancel-next countdown overlay + cancel button are wired (TODO-639)',
      () {
    // Countdown state + lifecycle.
    expect(pageSource,
        contains('ValueNotifier<int?> _autoAdvanceCountdownNotifier'));
    expect(pageSource, contains('void _cancelAutoAdvanceCountdown()'));
    expect(pageSource, contains('Timer.periodic('));
    expect(pageSource, contains('_autoAdvanceCountdownTimer?.cancel();'),
        reason: 'countdown timer must be cancelable / disposed');
    // A manual episode switch cancels any pending countdown.
    expect(
      _functionSource(
        pageSource,
        '  Future<void> _switchEpisode(',
        '  void _showEpisodeList() {',
      ),
      contains('_cancelAutoAdvanceCountdown();'),
      reason: 'switching episodes mid-countdown must clear the pending advance',
    );
    // The interactive cancel overlay is built + mounted (not under IgnorePointer).
    expect(pageSource, contains('Widget _buildAutoAdvanceOverlay()'));
    expect(pageSource, contains('_buildAutoAdvanceOverlay(),'),
        reason: 'overlay must be mounted in the controls stack');
    final String overlayFn = _functionSource(
      pageSource,
      '  Widget _buildAutoAdvanceOverlay() {',
      '\n}',
    );
    expect(overlayFn, contains('t.video_auto_play_next_countdown('));
    expect(overlayFn, contains('onPressed: _cancelAutoAdvanceCountdown'));
    expect(overlayFn, contains('t.video_auto_play_next_cancel'));
    expect(overlayFn, isNot(contains('IgnorePointer')),
        reason: 'the cancel button must be tappable (no IgnorePointer)');
  });

  test('episode switches require explicit start intents at every call site',
      () {
    final String fn = _functionSource(
      pageSource,
      '  Future<void> _switchEpisode(',
      '  void _showEpisodeList() {',
    );

    expect(fn, contains('required EpisodeStartIntent intent'));
    expect(fn, contains('startIntent: intent'));

    final String pageWithoutDefinition = pageSource.replaceFirst(fn, '');
    final Iterable<String> calls = RegExp(r'_switchEpisode\([\s\S]*?\);')
        .allMatches(pageWithoutDefinition)
        .map((RegExpMatch m) => m.group(0)!);
    expect(calls, isNotEmpty);
    for (final String call in calls) {
      expect(
        call,
        contains('intent: EpisodeStartIntent.'),
        reason: 'episode switching must not fall back to an implicit resume',
      );
    }

    expect(pageSource, contains('EpisodeStartIntent.manualPrevious'));
    expect(pageSource, contains('EpisodeStartIntent.manualNext'));
    expect(pageSource, contains('EpisodeStartIntent.listSelect'));
    expect(pageSource, contains('EpisodeStartIntent.autoAdvance'));
  });

  test('initial open uses explicit start policy before autoplay', () {
    final String initFn = _functionSource(
      pageSource,
      '  Future<void> _init() async {',
      '  Future<void> _initRemote() async {',
    );
    final String loadFn = _functionSource(
      pageSource,
      '  Future<void> _applyLoad({',
      '  /// 位置持久化',
    );

    expect(initFn, contains('EpisodeStartIntent.initialOpen'));
    expect(initFn, contains('EpisodeStartIntent.explicitCue'),
        reason: 'favorite/cue opens are not saved-position resumes');
    expect(loadFn, contains('startIntent: startIntent'));
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
