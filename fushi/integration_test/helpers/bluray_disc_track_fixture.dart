import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_disc_menu.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_subtitle_source.dart';
import 'package:path/path.dart' as p;

import 'focus_driver.dart';

typedef BlurayTestHooksReader = VideoFushiTestHooks? Function();

/// A real stored text cue/source which would visibly replace the disc's PGS if
/// the menu-to-title handoff incorrectly restored ordinary-video preferences.
Future<void> seedPersistedBlurayTextSubtitle({
  required VideoBookRepository repo,
  required String bookUid,
  required String isolatedRoot,
}) async {
  final File file = File(p.join(isolatedRoot, 'stale-disc-subtitle.srt'));
  await file.parent.create(recursive: true);
  const String marker = 'STALE EXTERNAL SUBTITLE MUST NOT REPLACE DISC PGS';
  await file.writeAsString(
    '1\n00:00:35,000 --> 00:01:20,000\n$marker\n',
    flush: true,
  );
  await repo.saveSubtitleSelection(
    bookUid: bookUid,
    subtitleSource: file.path,
    cues: <AudioCue>[
      AudioCue()
        ..bookKey = bookUid
        ..chapterHref = ''
        ..sentenceIndex = 0
        ..textFragmentId = 'stale-disc-cue'
        ..text = marker
        ..startMs = 35000
        ..endMs = 80000
        ..audioFileIndex = 0,
    ],
  );
  expect(await repo.loadCues(bookUid), hasLength(1));
}

/// Assert actual player track IDs, then capture the known PGS cue after seeking
/// back through its packet. A sid restore while paused does not replay packets
/// that have already passed, so merely reading a selected sid is insufficient.
Future<void> verifyBlurayDiscPgs({
  required WidgetTester tester,
  required BlurayTestHooksReader hooks,
  required String expectedSubtitleId,
  required String expectedAudioId,
  required String screenshotName,
  required Future<void> Function(String name) capture,
}) async {
  expect(
    hooks()!.debugCueCount,
    0,
    reason: 'The stored external cue must not replace the disc subtitle',
  );
  await _waitForTracks(
    tester,
    hooks,
    () {
      final VideoFushiTestHooks? current = hooks();
      return current?.debugDiscTitleReady == true &&
          current?.debugDiscTrackOwner == VideoDiscTrackOwner.disc &&
          current?.debugResolvedDiscSubtitleTrackId == expectedSubtitleId &&
          current?.debugResolvedDiscAudioTrackId == expectedAudioId;
    },
    'disc-selected PGS/audio',
    onTimeout: () => capture('$screenshotName-unresolved-tracks'),
  );
  await hooks()!.debugSeekMs(36200);
  await hooks()!.debugPause();
  await _waitForTracks(tester, hooks, () {
    final int position = hooks()?.debugPositionMs ?? -1;
    return hooks()?.debugDiscTitleReady == true &&
        position >= 35900 &&
        position < 38000;
  }, 'PGS cue seek');
  await tester.pump(const Duration(milliseconds: 300));
  expect(hooks()!.debugResolvedDiscSubtitleTrackId, expectedSubtitleId);
  expect(hooks()!.debugResolvedDiscAudioTrackId, expectedAudioId);
  expect(
    hooks()!.debugGraphicSubtitleActive,
    isTrue,
    reason: 'The resolved PGS codec must use native bitmap rendering',
  );
  expect(hooks()!.debugDiscTrackOwner, VideoDiscTrackOwner.disc);
  await capture(screenshotName);
  await hooks()!.debugPlay();
}

/// Opens the production settings category and activates the real Off row using
/// keyboard focus. It verifies the native result and the persisted user choice.
Future<void> selectFushiSubtitleOffByFocus({
  required WidgetTester tester,
  required FocusDriver driver,
  required BlurayTestHooksReader hooks,
  required VideoBookRepository repo,
  required String bookUid,
}) async {
  hooks()!.debugOpenSubtitleSettings();
  await tester.pump(const Duration(milliseconds: 250));
  final Finder off = find.byKey(const ValueKey<String>('video-subtitle-off'));
  expect(await driver.focusWidget(off), isTrue);
  await driver.activate();
  await _waitForTracks(tester, hooks, () {
    final VideoFushiTestHooks? current = hooks();
    return current?.debugDiscTrackOwner == VideoDiscTrackOwner.fushi &&
        current?.debugCurrentSubtitleSource == SubtitleSource.offSentinel &&
        current?.debugActiveSubtitleTrackId == 'no';
  }, 'Fushi subtitle Off override');
  expect(
    (await repo.getByBookUid(bookUid))!.subtitleSource,
    SubtitleSource.offSentinel,
  );
  if (off.evaluate().isNotEmpty) {
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(
    find.byType(VideoFushiPage),
    findsOneWidget,
    reason: 'Closing subtitle settings must not close the player',
  );
}

Future<void> _waitForTracks(
  WidgetTester tester,
  BlurayTestHooksReader hooks,
  bool Function() predicate,
  String phase, {
  Future<void> Function()? onTimeout,
}) async {
  final Stopwatch watch = Stopwatch()..start();
  while (watch.elapsed < const Duration(seconds: 45)) {
    if (predicate()) return;
    final String? error = hooks()?.debugDiscMenuError;
    if (error != null) fail('$phase: $error');
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (onTimeout != null) {
    try {
      await onTimeout();
    } on Object catch (error) {
      debugPrint('[bluray-menu] Track diagnostic capture failed: $error');
    }
  }
  final VideoFushiTestHooks? current = hooks();
  fail(
    '$phase timed out: owner=${current?.debugDiscTrackOwner}, '
    'sid=${current?.debugActiveSubtitleTrackId}, '
    'aid=${current?.debugActiveAudioTrackId}, '
    'physicalSid=${current?.debugResolvedDiscSubtitleTrackId}, '
    'physicalAid=${current?.debugResolvedDiscAudioTrackId}, '
    'titleReady=${current?.debugDiscTitleReady}, '
    'position=${current?.debugPositionMs}',
  );
}
