import 'package:flutter_test/flutter_test.dart';

import 'video_fushi_page_source_corpus.dart';

void main() {
  final String pageSource = readVideoFushiSource();

  test('_applyLoad binds completed callback before controller.load', () {
    final String fn = _functionSource(
      pageSource,
      '  Future<void> _applyLoad({',
      '  /// 位置持久化',
    );
    final int bindAt = fn.indexOf(
      'controller.setOnCompleted(_handlePlaybackCompleted);',
    );
    final int loadAt = fn.indexOf('await controller.load(');

    expect(
      bindAt,
      greaterThan(-1),
      reason: 'page must bind EOF handling before opening media',
    );
    expect(loadAt, greaterThan(-1));
    expect(
      bindAt,
      lessThan(loadAt),
      reason: 'completed can fire during/just after load, so bind first',
    );
  });

  test('completed handler gates on the auto-play-next toggle + playlist '
      'and reentry guards (TODO-639)', () {
    expect(pageSource, contains('bool _autoAdvanceInFlight = false'));
    // 媒体服务器线路故障转移落地后，EOF 回调分三层：_handlePlaybackCompleted
    // 取 EOF 那一刻的位置 → _handlePlaybackEnded 先问能否换线路续播（流中途断了）
    // → 换不了 / 真播完才进 _finishPlaybackCompleted 做连播门控。前两层只许转发，
    // 门控整段钉在 _finishPlaybackCompleted（连同它调用的 _autoAdvanceTargetEpisode）。
    final String entry = _functionSource(
      pageSource,
      '  void _handlePlaybackCompleted() =>',
      '  /// 播放器报 EOF',
    );
    expect(entry, contains('_handlePlaybackEnded('));
    final String ended = _functionSource(
      pageSource,
      '  void _handlePlaybackEnded({',
      '  /// 流断了之后换线路重载',
    );
    expect(ended, contains('_finishPlaybackCompleted(positionMs);'));
    expect(
      ended,
      isNot(contains('_startAutoAdvanceCountdown(')),
      reason: '连播只能经 _finishPlaybackCompleted 的门控进倒计时',
    );
    final String fn = _functionSource(
      pageSource,
      '  void _finishPlaybackCompleted(int? positionMs) {',
      '  /// 启动自动连播倒计时',
    );

    expect(fn, contains('if (!mounted) return'));
    // 拍板台 QHbRRctQdW：目标集由连播顺序决定——顺序模式走纯函数
    // sequentialNextEpisode（末集/单集/越界 → null），随机模式走跨页面的轮次记录。
    expect(
      fn,
      contains('final int? nextEpisode = _autoAdvanceTargetEpisode();'),
    );
    expect(
      fn,
      contains('appModel.videoPlaylistOrder == VideoPlaylistOrder.sequential'),
    );
    expect(
      fn,
      contains('sequentialNextEpisode(count: episodes.length, current: cur)'),
    );
    expect(fn, contains('VideoShuffleRounds.instance.next('));
    // TODO-639: the advance decision is the pure predicate gating on the
    // user's auto-play-next preference, next-episode existence, and reentry.
    expect(fn, contains('shouldAutoPlayNextOnCompletion('));
    expect(
      fn,
      contains('autoPlayNextEnabled: appModel.videoAutoPlayNext'),
      reason: 'EOF advance must honour the auto-play-next toggle',
    );
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
    expect(
      runFn,
      contains('intent: EpisodeStartIntent.autoAdvance'),
      reason:
          'non-last EOF must carry autoAdvance intent instead of reusing saved near-end positions',
    );
  });

  test(
    'the cancel-next countdown overlay + cancel button are wired (TODO-639)',
    () {
      // Countdown state + lifecycle.
      expect(
        pageSource,
        contains('ValueNotifier<int?> _autoAdvanceCountdownNotifier'),
      );
      expect(pageSource, contains('void _cancelAutoAdvanceCountdown()'));
      expect(pageSource, contains('Timer.periodic('));
      expect(
        pageSource,
        contains('_autoAdvanceCountdownTimer?.cancel();'),
        reason: 'countdown timer must be cancelable / disposed',
      );
      // A manual episode switch cancels any pending countdown.
      expect(
        _functionSource(
          pageSource,
          '  Future<void> _switchEpisode(',
          '  void _showEpisodeList() {',
        ),
        contains('_cancelAutoAdvanceCountdown();'),
        reason:
            'switching episodes mid-countdown must clear the pending advance',
      );
      // The interactive cancel overlay is built + mounted (not under IgnorePointer).
      expect(pageSource, contains('Widget _buildAutoAdvanceOverlay()'));
      expect(
        pageSource,
        contains('_buildAutoAdvanceOverlay(),'),
        reason: 'overlay must be mounted in the controls stack',
      );
      final String overlayFn = _functionSource(
        pageSource,
        '  Widget _buildAutoAdvanceOverlay() {',
        '\n}',
      );
      expect(overlayFn, contains('t.video_auto_play_next_countdown('));
      expect(overlayFn, contains('onPressed: _cancelAutoAdvanceCountdown'));
      expect(overlayFn, contains('t.video_auto_play_next_cancel'));
      expect(
        overlayFn,
        isNot(contains('IgnorePointer')),
        reason: 'the cancel button must be tappable (no IgnorePointer)',
      );
    },
  );

  test(
    'episode switches require explicit start intents at every call site',
    () {
      final String fn = _functionSource(
        pageSource,
        '  Future<void> _switchEpisode(',
        '  void _showEpisodeList() {',
      );

      expect(fn, contains('required EpisodeStartIntent intent'));
      expect(fn, contains('startIntent: intent'));

      final String pageWithoutDefinition = pageSource.replaceFirst(fn, '');
      final Iterable<String> calls = RegExp(
        r'_switchEpisode\([\s\S]*?\);',
      ).allMatches(pageWithoutDefinition).map((RegExpMatch m) => m.group(0)!);
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
    },
  );

  test('initial open uses explicit start policy before autoplay', () {
    // 统一合集 Phase 3：每集（含播放列表某一集）都照单视频路径 _loadSingle 加载，显式
    // 起播策略（initialOpen / explicitCue）落在 _loadSingle。
    final String loadSingleFn = _functionSource(
      pageSource,
      '  Future<void> _loadSingle(VideoBookRow row) async {',
      '  Future<({String videoPath, String? subtitleSource})>',
    );
    final String loadFn = _functionSource(
      pageSource,
      '  Future<void> _applyLoad({',
      '  /// 位置持久化',
    );

    expect(loadSingleFn, contains('EpisodeStartIntent.initialOpen'));
    expect(
      loadSingleFn,
      contains('EpisodeStartIntent.explicitCue'),
      reason: 'favorite/cue opens are not saved-position resumes',
    );
    expect(loadFn, contains('startIntent: startIntent'));
  });

  test('_applyLoad prewarms current video and then next playlist episode', () {
    final String fn = _functionSource(
      pageSource,
      '  Future<void> _applyLoad({',
      // BUG-2587 起采集器按身份建，原「首次 load 建观看统计采集器」注释已删，
      // 以调用行本身作尾界标。
      '    _ensureWatchTracker(controller, title);',
    );
    // BUG-4838：调用多了取消信号参数，按调用形状（不看换行）找。
    final int currentAt =
        RegExp(
          r'unawaited\(\s*prewarmEmbeddedSubtitleCache\(\s*videoPath,',
        ).firstMatch(fn)?.start ??
        -1;
    final int nextAt = fn.indexOf('_prewarmNextEpisodeSubtitleCache();');

    expect(currentAt, greaterThan(-1));
    expect(
      nextAt,
      greaterThan(currentAt),
      reason: 'next episode should be warmed after the current file warmup',
    );
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
