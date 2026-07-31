import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_search_navigation.dart';

void main() {
  group('decideReaderSearchJump', () {
    test('cross-chapter result starts a new navigation', () {
      expect(
        decideReaderSearchJump(
          targetChapter: 4,
          currentChapter: 1,
          restoreInFlight: false,
          readerContentReady: true,
        ),
        ReaderSearchJumpAction.navigate,
      );
    });

    test('same-chapter result evaluates only after the DOM is ready', () {
      expect(
        decideReaderSearchJump(
          targetChapter: 4,
          currentChapter: 4,
          restoreInFlight: false,
          readerContentReady: true,
        ),
        ReaderSearchJumpAction.evaluateNow,
      );
    });

    test('same logical chapter replaces pending while restore is in flight',
        () {
      expect(
        decideReaderSearchJump(
          targetChapter: 4,
          currentChapter: 4,
          restoreInFlight: true,
          readerContentReady: false,
        ),
        ReaderSearchJumpAction.replacePending,
      );
      expect(
        decideReaderSearchJump(
          targetChapter: 4,
          currentChapter: 4,
          restoreInFlight: false,
          readerContentReady: false,
        ),
        ReaderSearchJumpAction.replacePending,
        reason: 'logical current must not be treated as a ready DOM',
      );
    });
  });

  group('ReaderPreciseLocateQueue', () {
    test('second same-generation selection wins before restore completes', () {
      final ReaderPreciseLocateQueue queue = ReaderPreciseLocateQueue();
      queue.replace(generation: 7, js: 'first');
      queue.replace(generation: 7, js: 'second');

      expect(queue.consume(generation: 7, canApply: true), 'second');
      expect(queue.consume(generation: 7, canApply: true), isNull);
    });

    test('repeated text keeps the offset from the final selection', () {
      final ReaderPreciseLocateQueue queue = ReaderPreciseLocateQueue();
      final String first =
          ReaderPaginationScripts.scrollToSearchMatchInvocation('猫', 12);
      final String second =
          ReaderPaginationScripts.scrollToSearchMatchInvocation('猫', 91);

      queue.replace(generation: 8, js: first);
      queue.replace(generation: 8, js: second);

      expect(queue.consume(generation: 8, canApply: true), second);
      expect(second, contains(', 91)'));
    });

    test('stale completion cannot consume or clear the active request', () {
      final ReaderPreciseLocateQueue queue = ReaderPreciseLocateQueue();
      queue.replace(generation: 10, js: 'new final selection');

      expect(queue.consume(generation: 9, canApply: true), isNull);
      expect(
        queue.consume(generation: 10, canApply: true),
        'new final selection',
      );
    });

    test('navigation dispose discards pending without evaluating it', () {
      final ReaderPreciseLocateQueue queue = ReaderPreciseLocateQueue();
      queue.replace(generation: 11, js: 'must not run');

      expect(queue.consume(generation: 11, canApply: false), isNull);
      expect(queue.consume(generation: 11, canApply: true), isNull);
    });
  });

  group('restore completion generation', () {
    test('only the document that owns the active navigation can settle it', () {
      expect(
        isCurrentReaderRestoreCompletion(
          reportedGeneration: 14,
          currentGeneration: 15,
          expectedGeneration: 15,
        ),
        isFalse,
        reason: 'late completion from the replaced document must be ignored',
      );
      expect(
        isCurrentReaderRestoreCompletion(
          reportedGeneration: 15,
          currentGeneration: 15,
          expectedGeneration: 15,
        ),
        isTrue,
      );
    });
  });
}
