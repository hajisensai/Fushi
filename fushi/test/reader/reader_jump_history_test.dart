import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_jump_history.dart';
import 'package:fushi/src/utils/components/fushi_jump_history_pill.dart';
import 'package:fushi/src/utils/misc/jump_history.dart';

ReaderJumpPoint _text(int chapter, int offset) => ReaderJumpPoint(
  kind: ReaderJumpKind.text,
  chapter: chapter,
  progress: 0,
  charOffset: offset,
);

ReaderJumpPoint _audio(int ms) => ReaderJumpPoint(
  kind: ReaderJumpKind.audio,
  chapter: 0,
  progress: 0,
  charOffset: -1,
  audioGlobalMs: ms,
);

void main() {
  test('back then forward walks like browser history', () {
    final JumpHistory<ReaderJumpPoint> h = newReaderJumpHistory();
    // A → B（目录跳转），B → C（搜索跳转）。
    h.recordDeparture(_text(1, 10));
    h.recordDeparture(_text(5, 0));
    expect(h.canGoBack, isTrue);
    expect(h.canGoForward, isFalse);

    // 在 C 按返回 → B，C 进前进栈。
    final ReaderJumpPoint? toB = h.goBack(_text(9, 3));
    expect(toB?.chapter, 5);
    expect(h.forwardTarget?.chapter, 9);

    // 再返回 → A。
    final ReaderJumpPoint? toA = h.goBack(_text(5, 0));
    expect(toA?.chapter, 1);
    expect(h.canGoBack, isFalse);

    // 前进 → B，再前进 → C。
    expect(h.goForward(_text(1, 10))?.chapter, 5);
    expect(h.goForward(_text(5, 0))?.chapter, 9);
    expect(h.canGoForward, isFalse);
    expect(h.backTarget?.chapter, 5);
  });

  test('a new jump after going back drops the forward stack', () {
    final JumpHistory<ReaderJumpPoint> h = newReaderJumpHistory();
    h.recordDeparture(_text(1, 10));
    h.goBack(_text(4, 0));
    expect(h.canGoForward, isTrue);
    h.recordDeparture(_text(1, 10));
    expect(h.canGoForward, isFalse);
  });

  test('same place is not pushed twice', () {
    final JumpHistory<ReaderJumpPoint> h = newReaderJumpHistory();
    expect(h.recordDeparture(_text(2, 40)), isTrue);
    expect(h.recordDeparture(_text(2, 40)), isFalse);
    expect(h.recordDeparture(_audio(60000)), isTrue);
    // 音频落点 1 秒内算同一处。
    expect(h.recordDeparture(_audio(60500)), isFalse);
    expect(h.recordDeparture(_audio(62000)), isTrue);
  });

  test('replaceBackTop upgrades a text point to an audio point', () {
    final JumpHistory<ReaderJumpPoint> h = newReaderJumpHistory();
    h.recordDeparture(_text(3, 7));
    h.replaceBackTop(
      const ReaderJumpPoint(
        kind: ReaderJumpKind.audio,
        chapter: 3,
        progress: 0,
        charOffset: 7,
        audioGlobalMs: 123000,
      ),
    );
    final ReaderJumpPoint? top = h.backTarget;
    expect(top?.kind, ReaderJumpKind.audio);
    expect(top?.audioGlobalMs, 123000);
    expect(top?.charOffset, 7);
  });

  test('depth is capped, oldest dropped', () {
    final JumpHistory<ReaderJumpPoint> h = newReaderJumpHistory();
    for (int i = 0; i < JumpHistory.maxDepth + 5; i++) {
      h.recordDeparture(_text(i, 0));
    }
    int count = 0;
    ReaderJumpPoint? last;
    while (h.canGoBack) {
      last = h.goBack(_text(999, count));
      count++;
    }
    expect(count, JumpHistory.maxDepth);
    expect(last?.chapter, 5);
  });

  test('clear empties both stacks', () {
    final JumpHistory<ReaderJumpPoint> h = newReaderJumpHistory();
    h.recordDeparture(_text(1, 0));
    h.recordDeparture(_text(2, 0));
    h.goBack(_text(3, 0));
    h.clear();
    expect(h.isEmpty, isTrue);
  });

  test('time label', () {
    expect(formatJumpHistoryTime(0), '0:00');
    expect(formatJumpHistoryTime(754000), '12:34');
    expect(formatJumpHistoryTime(3723000), '1:02:03');
  });
}
