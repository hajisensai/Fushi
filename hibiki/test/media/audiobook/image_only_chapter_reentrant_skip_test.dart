import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'helpers/audiobook_test_harness.dart';

/// TODO-1037 / BUG-487 (reentrant cross-chapter race). During cross-chapter
/// advance through a standalone image-only chapter, the reader's
/// _pauseThroughImageOnlyChapters navigates each intermediate image chapter to
/// pause on it. Each intermediate chapter load SYNCHRONOUSLY calls
/// notifySectionRestoreCompleted, which previously cleared _chapterTransition
/// and re-ran _updateCurrentCue while audio was still playing (the pause in
/// awaitImageChapterPause only fires after this navigate's await returns) and
/// the cue still pointed at the final text chapter -> _maybeEmitCrossChapter
/// re-fired cross-chapter -> remaining image chapters skipped (the very symptom
/// f3e4d2e52 claimed to fix). Fix: the reader sets setImageChapterPauseActive
/// for the whole pause sequence; notifySectionRestoreCompleted keeps the guard
/// held and skips the recompute while active.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('image-only chapter cross-chapter reentrancy guard (TODO-1037/BUG-487)',
      () {
    test(
        'active sequence: synchronous notify on intermediate image chapter does not reenter cross-chapter',
        () async {
      final AudiobookPlayerController controller =
          await _loadPlayingController();
      final List<int> crossCalls = <int>[];
      controller.onCrossChapter = (int sec) => crossCalls.add(sec);
      controller.getCurrentReaderSection = () => 2;

      controller.holdChapterTransition();
      controller.setImageChapterPauseActive(true);
      expect(controller.chapterTransitionHeldForTesting, isTrue);

      controller.notifySectionRestoreCompleted(
        currentReaderSection: 2,
        success: true,
      );

      expect(crossCalls, isEmpty,
          reason: 'in-flight intermediate load must not reenter cross-chapter');
      expect(controller.chapterTransitionHeldForTesting, isTrue,
          reason: 'guard stays held during the pause sequence');

      controller.dispose();
    });

    test(
        'contrast: when sequence finished (active=false) final navigate still cross-chapters',
        () async {
      final AudiobookPlayerController controller =
          await _loadPlayingController();
      final List<int> crossCalls = <int>[];
      controller.onCrossChapter = (int sec) => crossCalls.add(sec);
      controller.getCurrentReaderSection = () => 2;

      controller.holdChapterTransition();
      controller.setImageChapterPauseActive(true);
      controller.setImageChapterPauseActive(false);

      controller.notifySectionRestoreCompleted(
        currentReaderSection: 2,
        success: true,
      );

      expect(crossCalls, <int>[5],
          reason:
              'reentrant path proven reachable; guard, not dead branch, blocks first case');

      controller.dispose();
    });
  });

  group('reentrancy guard wiring (TODO-1037/BUG-487)', () {
    test('notifySectionRestoreCompleted early-returns while sequence active',
        () {
      final String src = File(
        '../packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart',
      ).readAsStringSync();
      final int notifyIdx = src.indexOf('void notifySectionRestoreCompleted({');
      expect(notifyIdx, greaterThanOrEqualTo(0));
      final int clearIdx =
          src.indexOf('_chapterTransition = false;', notifyIdx);
      final String head = src.substring(notifyIdx, clearIdx);
      expect(head.contains('if (_imageChapterPauseActive) return;'), isTrue,
          reason: 'guard must early-return before clearing _chapterTransition');
    });

    test('reader toggles setImageChapterPauseActive at sequence entry/exit',
        () {
      final String src = File(
        'lib/src/pages/implementations/reader_hibiki/audiobook.part.dart',
      ).readAsStringSync();
      expect(
          src.contains('controller.setImageChapterPauseActive(true);'), isTrue);
      expect(src.contains('controller.setImageChapterPauseActive(false);'),
          isTrue);
      final int onIdx =
          src.indexOf('controller.setImageChapterPauseActive(true);');
      final int offIdx =
          src.indexOf('controller.setImageChapterPauseActive(false);');
      expect(onIdx >= 0 && offIdx > onIdx, isTrue,
          reason: 'set true at entry, false in finally');
    });
  });
}

Future<AudiobookPlayerController> _loadPlayingController() async {
  installHangingAudioPlatform();
  final AudiobookPlayerController controller = AudiobookPlayerController();
  final File audioFile = createFakeAudioFile('hibiki-reentrant-1037.mp3');
  await controller.load(
    audiobook: fakeAudiobook(),
    audioFiles: <File>[audioFile],
  );
  final List<AudioCue> cues = <AudioCue>[_sasayakiCue(0, section: 5)];
  controller.setAllBookCues(cues);
  controller.setChapterCues(cues);
  controller.followAudio.value = true;
  await controller.play();
  return controller;
}

AudioCue _sasayakiCue(int startMs, {required int section}) {
  return AudioCue()
    ..id = null
    ..bookKey = 'book'
    ..chapterHref = 'chapter'
    ..sentenceIndex = startMs ~/ 1000
    ..textFragmentId = SasayakiMatchCodec.encodeHit(
      sectionIndex: section,
      normCharStart: 0,
      normCharEnd: 10,
    )
    ..text = 'cue $startMs'
    ..startMs = startMs
    ..endMs = startMs + 1000
    ..audioFileIndex = 0;
}
