import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/reader/reader_navigation_lifecycle.dart';

void main() {
  test('late rebuild after dispose has zero side effects', () {
    int rebuilds = 0;

    runReaderRebuildIfMounted(
      mounted: false,
      rebuild: () => rebuilds++,
    );
    expect(rebuilds, 0);

    runReaderRebuildIfMounted(
      mounted: true,
      rebuild: () => rebuilds++,
    );
    expect(rebuilds, 1, reason: '未 dispose 正控必须仍能 rebuild');
  });

  test('disposed/invalid navigation cannot start generation or rebuild', () {
    int starts = 0;
    int start() {
      starts++;
      return 7;
    }

    for (final ({
      bool mounted,
      bool hasBook,
      bool hasController,
      bool validChapter,
    }) input in <({
      bool mounted,
      bool hasBook,
      bool hasController,
      bool validChapter,
    })>[
      (
        mounted: false,
        hasBook: true,
        hasController: true,
        validChapter: true,
      ),
      (
        mounted: true,
        hasBook: false,
        hasController: true,
        validChapter: true,
      ),
      (
        mounted: true,
        hasBook: true,
        hasController: false,
        validChapter: true,
      ),
      (
        mounted: true,
        hasBook: true,
        hasController: true,
        validChapter: false,
      ),
    ]) {
      expect(
        runReaderNavigationStartIfActive(
          mounted: input.mounted,
          hasBook: input.hasBook,
          hasController: input.hasController,
          validChapter: input.validChapter,
          start: start,
        ),
        isNull,
      );
    }
    expect(starts, 0, reason: 'guard 后移到副作用之后会让此断言变红');

    expect(
      runReaderNavigationStartIfActive(
        mounted: true,
        hasBook: true,
        hasController: true,
        validChapter: true,
        start: start,
      ),
      7,
    );
    expect(starts, 1, reason: '未 dispose 正控必须仍能开始导航');
  });

  test('owner epoch invalidates old lease even when controller is reused', () {
    final OwnerEpochRegistry<Object, Object> owners =
        OwnerEpochRegistry<Object, Object>();
    final Object controller = Object();
    final Object readerA = Object();
    final Object readerB = Object();

    final OwnerEpochAttachment<Object, Object> leaseA =
        owners.attach(readerA, controller);
    expect(owners.owns(readerA, leaseA), isTrue);

    owners.detach(readerA);
    final OwnerEpochAttachment<Object, Object> leaseB =
        owners.attach(readerB, controller);

    expect(identical(leaseA.resource, leaseB.resource), isTrue);
    expect(owners.owns(readerA, leaseA), isFalse);
    expect(owners.owns(readerB, leaseB), isTrue);
  });

  test('normal consecutive images preserve order and dedupe resolved host',
      () async {
    final List<String> events = <String>[];
    int currentGeneration = 10;
    bool active = false;

    final ReaderImageChapterSequenceResult result =
        await runReaderImageChapterSequence(
      chapters: <int>[2, 3, 4],
      initialNavigationGeneration: currentGeneration,
      resolveChapter: (int chapter) => chapter == 3 ? 2 : chapter,
      isCurrent: (int generation) => generation == currentGeneration,
      markActive: () {
        active = true;
        events.add('active');
        return true;
      },
      clearActiveIfOwner: () {
        active = false;
        events.add('clear');
        return true;
      },
      holdTransition: (int generation) {
        if (generation != currentGeneration) return false;
        events.add('hold:$generation');
        return true;
      },
      navigate: (int chapter) async {
        events.add('navigate:$chapter');
        currentGeneration++;
        return (loaded: true, generation: currentGeneration);
      },
      reveal: () async => events.add('reveal'),
      pause: () async => events.add('pause'),
    );

    expect(result.completed, isTrue);
    expect(result.navigationGeneration, 12);
    expect(active, isFalse);
    expect(
      events,
      <String>[
        'active',
        'hold:10',
        'navigate:2',
        'reveal',
        'pause',
        'hold:11',
        'navigate:4',
        'reveal',
        'pause',
        'clear',
        'hold:12',
      ],
      reason: '连续图片按序停留；同一 resolved host 只处理一次',
    );
  });

  test('dispose and immediate reattach cannot let old await touch new owner',
      () async {
    final OwnerEpochRegistry<Object, Object> owners =
        OwnerEpochRegistry<Object, Object>();
    final Object controller = Object();
    final Object readerA = Object();
    final Object readerB = Object();
    final OwnerEpochAttachment<Object, Object> leaseA =
        owners.attach(readerA, controller);
    final Completer<void> navigateStarted = Completer<void>();
    final Completer<void> releaseNavigate = Completer<void>();
    int currentGeneration = 0;
    bool imageActive = false;
    bool transitionHeld = false;
    int reveals = 0;
    int pauses = 0;

    bool ownerAIsCurrent() => owners.owns(readerA, leaseA);
    final Future<ReaderImageChapterSequenceResult> oldSequence =
        runReaderImageChapterSequence(
      chapters: <int>[2],
      initialNavigationGeneration: currentGeneration,
      resolveChapter: (int chapter) => chapter,
      isCurrent: (int generation) =>
          ownerAIsCurrent() && generation == currentGeneration,
      markActive: () {
        if (!ownerAIsCurrent()) return false;
        imageActive = true;
        return true;
      },
      clearActiveIfOwner: () {
        if (!ownerAIsCurrent()) return false;
        imageActive = false;
        return true;
      },
      holdTransition: (int generation) {
        if (!ownerAIsCurrent() || generation != currentGeneration) {
          return false;
        }
        transitionHeld = true;
        return true;
      },
      navigate: (int chapter) async {
        currentGeneration++;
        navigateStarted.complete();
        await releaseNavigate.future;
        return (loaded: true, generation: currentGeneration);
      },
      reveal: () async => reveals++,
      pause: () async => pauses++,
    );

    await navigateStarted.future;
    owners.detach(readerA);
    owners.attach(readerB, controller);
    // 新 reader 已开始自己的图片序列/transition。
    imageActive = true;
    transitionHeld = true;
    releaseNavigate.complete();

    final ReaderImageChapterSequenceResult result = await oldSequence;
    expect(result.completed, isFalse);
    expect(reveals, 0);
    expect(pauses, 0);
    expect(imageActive, isTrue, reason: '旧 finally 不得清新 owner 的 image-active');
    expect(transitionHeld, isTrue,
        reason: '旧 finally/cancel 不得改新 owner transition');
  });

  test('new navigation supersedes old continuation on the same reader',
      () async {
    final Completer<void> revealStarted = Completer<void>();
    final Completer<void> releaseReveal = Completer<void>();
    int currentGeneration = 20;
    bool imageActive = false;
    bool transitionHeld = false;
    int pauses = 0;

    final Future<ReaderImageChapterSequenceResult> oldSequence =
        runReaderImageChapterSequence(
      chapters: <int>[2],
      initialNavigationGeneration: currentGeneration,
      resolveChapter: (int chapter) => chapter,
      isCurrent: (int generation) => generation == currentGeneration,
      markActive: () {
        imageActive = true;
        return true;
      },
      clearActiveIfOwner: () {
        imageActive = false;
        return true;
      },
      holdTransition: (int generation) {
        if (generation != currentGeneration) return false;
        transitionHeld = true;
        return true;
      },
      navigate: (int chapter) async {
        currentGeneration++;
        return (loaded: true, generation: currentGeneration);
      },
      reveal: () async {
        revealStarted.complete();
        await releaseReveal.future;
      },
      pause: () async => pauses++,
    );

    await revealStarted.future;
    currentGeneration++;
    transitionHeld = true;
    releaseReveal.complete();

    final ReaderImageChapterSequenceResult result = await oldSequence;
    expect(result.completed, isFalse);
    expect(pauses, 0, reason: '旧 generation 不得继续 pause/最终导航');
    expect(imageActive, isFalse, reason: '同 owner 的新导航应清掉被顶替序列 active');
    expect(transitionHeld, isTrue,
        reason: '旧 generation finally 不得重持或清新导航 transition');
  });
}
