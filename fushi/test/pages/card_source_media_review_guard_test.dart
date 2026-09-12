import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Native media/WebView callbacks cannot be exercised in a headless unit
/// test. Guard their shared persistence boundaries as well as the runtime
/// manga database test in manga_fushi_page_test.dart.
void main() {
  final String video = File(
    'lib/src/pages/implementations/video_fushi_page.dart',
  ).readAsStringSync();
  final String manga = File(
    'lib/src/media/manga/reader/manga_fushi_page.dart',
  ).readAsStringSync();
  final String episode = File(
    'lib/src/pages/implementations/video_fushi/episode.part.dart',
  ).readAsStringSync();

  test('video persistence and study collection reject review before writing',
      () {
    for (final String signature in <String>[
      'Future<void> _persistPosition(String uid, int posMs) async {',
      'Future<void> _persistRemotePosition(String uid, int posMs) async {',
      'void _ensureWatchTracker(VideoPlayerController controller, String title) {',
    ]) {
      expect(
        video,
        contains('$signature\n    if (_sourceReviewActive) return;'),
      );
    }
    final int stop = video.indexOf(
      'Future<void> _reportRemotePlaybackStopped(',
    );
    final int stopGuard = video.indexOf(
      'if (_sourceReviewActive) return;',
      stop,
    );
    final int stopRequest = video.indexOf(
      'stopClient.stopRemoteVideoPlayback(',
      stop,
    );
    expect(stopGuard, greaterThan(stop));
    expect(stopGuard, lessThan(stopRequest));
  });

  test(
    'review rejects external negotiation before opening a playback session',
    () {
      final int load = video.indexOf('Future<void> _loadRemoteEpisode(');
      final int policy = video.indexOf('if (_sourceReviewActive)', load);
      final int request = video.indexOf(
        'await client.remoteVideoStreamUrls(',
        load,
      );
      expect(policy, greaterThan(load));
      expect(policy, lessThan(request));
      expect(video.substring(policy, request), contains('return;'));
      expect(video, contains('autoPlay: !_sourceReviewActive'));
      final int streamBook = video.indexOf('if (isStreamVideoBook(row))');
      final int earlyGuard = video.indexOf(
        'if (_sourceReviewActive)',
        streamBook,
      );
      final int webpagePlayer = video.indexOf(
        'WebVideoFushiPage.neutralized(',
        streamBook,
      );
      expect(earlyGuard, greaterThan(streamBook));
      expect(earlyGuard, lessThan(webpagePlayer));
      expect(video.substring(earlyGuard, webpagePlayer), contains('return;'));
    },
  );

  test(
    'review completion never advances and manual episode changes keep session',
    () {
      expect(
        episode,
        contains(
          'void _handlePlaybackCompleted() {\n    if (_sourceReviewActive) return;',
        ),
      );
      expect(episode, contains('sourceReviewSession: _sourceReviewSession'));
    },
  );

  test('video external navigation never pops a covering dialog', () {
    final int close = video.indexOf(
      'Future<bool> _closeForExternalNavigation()',
    );
    final int modalGuard = video.indexOf('if (route == null ||', close);
    final int pause = video.indexOf('await controller?.pause();', close);
    final int pop = video.indexOf('navigator.pop();', close);
    expect(modalGuard, greaterThan(close));
    expect(modalGuard, lessThan(pause));
    expect(video.substring(modalGuard, pause), contains('return false;'));
    expect(
      video.substring(close, pop),
      contains('if (!route.isCurrent) return false;'),
    );
  });

  test('BUG-2487 continue plays once after the controller is ready', () {
    expect(
      video,
      contains('_reviewContinued = session != null && !session.isReview;'),
    );
    final int changed = video.indexOf('void _onSourceReviewChanged()');
    final int resume = video.indexOf('void _playAfterSourceReviewIfReady()');
    final String notification = video.substring(changed, resume);
    expect(notification, contains('_reviewContinued) return;'));
    expect(notification, contains('_sourceReviewPlayPending = true;'));
    expect(notification, contains('_playAfterSourceReviewIfReady();'));

    final int consumed = video.indexOf(
      '_sourceReviewPlayPending = false;',
      resume,
    );
    final String readyGuard = video.substring(resume, consumed);
    expect(readyGuard, contains('_sourceReviewActive ||'));
    expect(readyGuard, contains('!_sourceReviewPlayPending ||'));
    expect(readyGuard, contains('controller == null'));
    final int tracker = video.indexOf(
      '_ensureWatchTracker(controller,',
      consumed,
    );
    final int play = video.indexOf('unawaited(controller.play());', tracker);
    final int flush = video.indexOf(
      'unawaited(controller.flushPosition());',
      play,
    );
    expect(tracker, greaterThan(consumed));
    expect(play, greaterThan(tracker));
    expect(flush, greaterThan(play));
    expect(
      video,
      contains(
        '_ensureWatchTracker(controller, title);\n'
        '    _playAfterSourceReviewIfReady();',
      ),
    );
  });

  test(
    'manga review gates positions, chapter state and the reading ledger',
    () {
      for (final String signature in <String>[
        'void _noteVisiblePages() {',
        'void _ensureStudyClock(FushiDatabase db) {',
        'Future<void> _persistPosition(int page, double fraction) async {',
        'Future<void> _saveCurrentChapterState({int? readAt}) async {',
        'Future<void> _flushReadingStats() async {',
      ]) {
        expect(
          manga,
          contains('$signature\n    if (_sourceReviewActive) return;'),
        );
      }
      expect(manga, contains('entry.copyWith(currentChapterIndex: index)'));
      expect(manga, contains('chapter.key == widget.sourceReview!.chapterId'));
      expect(manga, contains('_readLedger.reset();'));
    },
  );

  test(
    'continuing to watch drops the review banner instead of relabelling it',
    () {
      // A second permanent top bar squeezes the video and contradicts the
      // single-top-bar layout (BUG-102). Continuing means ordinary watching, so
      // the banner must unmount rather than switch to a "watching" label.
      expect(video, contains('when session.isReview)'));
      expect(
        video,
        contains(
          'if (_sourceReviewSession case final SourceReviewSession session',
        ),
      );
      // The banner was the only attach point; without the page taking over, the
      // session could no longer surface its failures after it unmounts.
      expect(video, contains('_sourceReviewSession?.attachContext(context);'));
      // No in-page way back to the clip survives: the Anki source link is it.
      expect(video, isNot(contains('returnToSource')));
    },
  );
}
