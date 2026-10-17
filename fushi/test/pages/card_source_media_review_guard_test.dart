import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart' as guard;

String _body(String source, String name) {
  final String? body = guard.topLevelFunctionBody(source, name);
  expect(body, isNotNull, reason: 'missing production method $name');
  return guard.compactCode(body!).replaceAll(',)', ')');
}

/// Native media/WebView callbacks cannot be exercised in a headless unit
/// test. Guard their shared persistence boundaries as well as the runtime
/// manga database test in manga_fushi_page_test.dart.
void main() {
  final String video = File(
    'lib/src/pages/implementations/video_fushi_page.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final String manga = File(
    'lib/src/media/manga/reader/manga_fushi_page.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');
  final String episode = File(
    'lib/src/pages/implementations/video_fushi/episode.part.dart',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  test('video persistence and study collection reject review before writing', () {
    for (final String method in <String>[
      '_persistPosition',
      '_persistRemotePosition',
    ]) {
      expect(
        _body(video, method),
        startsWith('{if(_sourceReviewActive)return;'),
        reason: 'review must return before any persistence side effect',
      );
    }
    expect(
      _body(video, '_ensureWatchTracker'),
      startsWith('{if(_sourceReviewActive||_discLearningBlocked)return;'),
      reason:
          'review and unbound disc menus both reject study collection before creating a tracker',
    );
    final int stop = video.indexOf(
      'Future<void> _reportRemotePlaybackStopped(',
    );
    final int stopGuard = video.indexOf(
      'if (_sourceReviewActive) return;',
      stop,
    );
    final int stopRequest = video.indexOf(
      '_remoteReportGate.stop(stopClient,',
      stop,
    );
    expect(stopGuard, greaterThan(stop));
    expect(stopGuard, lessThan(stopRequest));
  });

  test(
    'BUG-3490 remote review streams directly; every server report is gated',
    () {
      // 回看远端视频不再要求先下载：起播协商前不得有回看拦截。
      final int load = video.indexOf('Future<void> _loadRemoteEpisode(');
      final int request = video.indexOf(
        'await client.remoteVideoStreamUrls(',
        load,
      );
      expect(load, greaterThan(0));
      expect(request, greaterThan(load));
      expect(
        video.substring(load, request),
        isNot(contains('card_source_review_local_required')),
      );
      expect(video, contains('autoPlay: !_sourceReviewActive'));
      // 改服务器进度的四类上报只能经回看闸门发出，页面不得直调 client。
      for (final String direct in <String>[
        'client.putRemoteVideoPosition(',
        '.startRemoteVideoPlayback(',
        '.setRemoteVideoPlaybackPaused(',
        '.stopRemoteVideoPlayback(',
      ]) {
        expect(video, isNot(contains(direct)), reason: direct);
      }
      for (final String gated in <String>[
        '_remoteReportGate.position(',
        '_remoteReportGate.start(',
        '.paused(session, info.id, positionMs, paused: !playing)',
        '_remoteReportGate.stop(',
      ]) {
        expect(video, contains(gated), reason: gated);
      }
      expect(
        video,
        contains(
          'SourceReviewRemoteReportGate(isReview: () => _sourceReviewActive)',
        ),
      );
      // 「从这里继续观看」补发起播，且每次起播只发一次 Start。
      final int resume = video.indexOf('void _playAfterSourceReviewIfReady()');
      final int resumeEnd = video.indexOf('ExitFlushCallback?', resume);
      expect(
        video.substring(resume, resumeEnd),
        contains('_startRemotePlaybackSession('),
      );
      final int start = video.indexOf('void _startRemotePlaybackSession(');
      final int startSend = video.indexOf('_remoteReportGate.start(', start);
      expect(
        video.substring(start, startSend),
        contains('if (_lastReportedRemotePlaying != null) return;'),
      );
      // 媒体库在线条目（粘贴链接 / YouTube / 在线视频源剧集）同样直接在线回看：
      // 不再提示先下载，回看中也不进网页播放器（站点播放器会记观看记录）。
      final int streamBook = video.indexOf('if (isStreamVideoBook(row))');
      final int webpagePlayer = video.indexOf(
        'WebVideoFushiPage.neutralized(',
        streamBook,
      );
      expect(streamBook, greaterThan(0));
      expect(webpagePlayer, greaterThan(streamBook));
      final String streamBranch = video.substring(streamBook, webpagePlayer);
      expect(
        streamBranch,
        isNot(contains('card_source_review_local_required')),
      );
      expect(
        streamBranch,
        contains(
          'if (!_sourceReviewActive && shouldOpenInWebVideoPlayer(row.videoPath))',
        ),
      );
    },
  );

  test(
    'review completion never advances and manual episode changes keep session',
    () {
      final String completion = _body(episode, '_handlePlaybackCompleted');
      expect(
        completion,
        startsWith(
          '{if(_controller?.isBlurayNavigationSession==true)return;'
          'if(_sourceReviewActive)return;',
        ),
        reason:
            'disc VM and review completion must return before ordinary auto-advance',
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

  test('BUG-2502 continue plays once after the controller is ready', () {
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
      _body(video, '_applyLoad'),
      contains(
        '_ensureWatchTracker(controller,title);_playAfterSourceReviewIfReady();',
      ),
      reason:
          'load completion starts study before consuming the pending continue action',
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

  test(
    'BUG-3490 review defers audio / subtitle / delay saves until continue',
    () {
      final String audio = File(
        'lib/src/pages/implementations/video_fushi/audio_track.part.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final String subtitle = File(
        'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final String all = '$video\n$audio\n$subtitle';

      // 暂存出口：回看中只记下保存动作，不写；继续观看时补存。
      expect(
        video,
        contains(') => _reviewDeferredChoiceWrites.save(kind, write);'),
      );
      expect(video, contains('isReview: () => _sourceReviewActive,'));
      final int changed = video.indexOf('void _onSourceReviewChanged()');
      final int resume = video.indexOf('void _playAfterSourceReviewIfReady()');
      expect(
        video.substring(changed, resume),
        contains('unawaited(_flushReviewDeferredChoiceWrites());'),
      );

      // 写偏好 / 同步 host 的底层调用只能出现在暂存闭包里：每个写点所在方法都
      // 必须经 _saveReviewableChoice（_forgetDeletedSubtitleSelection 是清理，例外）。
      for (final ({String source, String method, String kind}) site
          in <({String source, String method, String kind})>[
            (
              source: audio,
              method: 'Future<void> _selectAudioTrack(',
              kind: 'audioTrack',
            ),
            (
              source: video,
              method: 'Future<void> _setDelayMs(',
              kind: 'primaryDelay',
            ),
            (
              source: video,
              method: 'Future<void> _setSecondaryDelayMs(',
              kind: 'secondaryDelay',
            ),
            (
              source: video,
              method: 'void _rememberRemoteSubtitleSource(',
              kind: 'primarySubtitle',
            ),
            (
              source: subtitle,
              method: 'Future<bool> _selectSubtitleSource(',
              kind: 'primarySubtitle',
            ),
            (
              source: subtitle,
              method: 'Future<void> _selectSubtitleOff(',
              kind: 'primarySubtitle',
            ),
            (
              source: subtitle,
              method: 'Future<bool> _selectSecondarySubtitleSource(',
              kind: 'secondarySubtitle',
            ),
            (
              source: subtitle,
              method: 'Future<void> _selectSecondarySubtitleOff(',
              kind: 'secondarySubtitle',
            ),
            (
              source: subtitle,
              method: 'Future<void> _clearRemoteSecondarySubtitle(',
              kind: 'secondarySubtitle',
            ),
          ]) {
        final int at = site.source.indexOf(site.method);
        expect(at, greaterThan(0), reason: site.method);
        final int end = site.source.indexOf('\n  }\n', at);
        final String body = site.source.substring(at, end);
        expect(body, contains('_saveReviewableChoice('), reason: site.method);
        expect(
          body,
          contains('_ReviewChoiceKind.${site.kind}'),
          reason: site.method,
        );
      }
      // 远端主字幕只经 _rememberRemoteSubtitleSource；直调 AppModel 的只剩清理。
      expect(
        RegExp(
          r'appModel\.setRemoteSubtitleSource\(',
        ).allMatches(subtitle).length,
        1,
      );
      expect(
        RegExp(
          r'\(\) async \{\n\s*final int nowMs = await _stampRemoteStringPref\(',
        ).allMatches(all).length,
        greaterThanOrEqualTo(3),
        reason: 'remote secondary subtitle writes are deferred closures too',
      );
      expect(
        all,
        isNot(contains('unawaited(() async {\n      final int nowMs')),
      );
    },
  );

  test('BUG-3490 deleted-subtitle cleanup still runs during review', () {
    final String subtitle = File(
      'lib/src/pages/implementations/video_fushi/subtitle.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final int at = subtitle.indexOf(
      'Future<void> _forgetDeletedSubtitleSelection(',
    );
    final String body = subtitle.substring(at, subtitle.indexOf('\n  }\n', at));
    // 清理不经暂存出口、直接落库，并作废回看中暂存的同种选择。
    expect(body, isNot(contains('_saveReviewableChoice(')));
    expect(body, isNot(contains('_sourceReviewActive')));
    expect(
      body,
      contains(
        '_reviewDeferredChoiceWrites.discard(_ReviewChoiceKind.primarySubtitle);',
      ),
    );
    expect(
      body,
      contains('unawaited(appModel.setRemoteSubtitleSource(uid, ep, null));'),
    );
    expect(body, contains('await widget.repo.saveSubtitleSelection('));
  });

  test('BUG-3490 library online items mint fingerprint-less links', () {
    final String mining = File(
      'lib/src/pages/implementations/video_fushi/lookup_mining.part.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    final String router = File(
      'lib/src/anki/card_source_router.dart',
    ).readAsStringSync().replaceAll('\r\n', '\n');
    expect(mining, contains('_resolvedStreamInfo != null &&'));
    expect(
      mining,
      contains('CardSourceLink.isContentAddressedVideoUid(sourceUid)'),
    );
    expect(
      router,
      contains('if (video != null && link.fingerprint != null) {'),
    );
    expect(
      video,
      contains('if (source != null && source.fingerprint != null) {'),
    );
    // 在线合集：链接 uid 已定位成员，链接里的 episodeIndex 不得盖掉它。
    expect(video, contains('((_resolvedStreamStartIndex == null'));
  });
}
