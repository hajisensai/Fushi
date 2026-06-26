// TODO-867 P3a pure-function lookup popup stack tests.
// Port of hoshi LookupPopupTest.kt stack part. Pure logic only:
// three close rules, scroll/reselect cuts children, no-result not pushed,
// boundaries (empty/single/deep/out-of-range), immutability. Each key
// assertion turns red if the matching implementation is removed.

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/global_lookup_stack.dart';

const String rt = 'root';
const String ch = 'child';
const String gr = 'grand';
const String em = 'empty';

GlobalLookupFrame frame(
  String id, {
  int parentIndex = -1,
  int resultCount = 1,
  int clearSelectionSignal = 0,
}) {
  return GlobalLookupFrame(
    id: id,
    query: id,
    parentIndex: parentIndex,
    resultCount: resultCount,
    clearSelectionSignal: clearSelectionSignal,
  );
}

GlobalLookupStack stackOf(List<String> ids) {
  final List<GlobalLookupFrame> frames = <GlobalLookupFrame>[];
  for (int i = 0; i < ids.length; i++) {
    frames.add(frame(ids[i], parentIndex: i - 1));
  }
  return GlobalLookupStack(frames);
}

List<String> idsOf(GlobalLookupStack stack) =>
    stack.frames.map((GlobalLookupFrame f) => f.id).toList();

void main() {
  group('GlobalLookupStack base', () {
    test('empty stack', () {
      final GlobalLookupStack s = GlobalLookupStack.empty;
      expect(s.isEmpty, isTrue);
      expect(s.isNotEmpty, isFalse);
      expect(s.length, 0);
      expect(s.topFrame, isNull);
      expect(s.topFrameId, isNull);
    });

    test('single-frame topFrame/topFrameId', () {
      final GlobalLookupStack s = stackOf(<String>[rt]);
      expect(s.length, 1);
      expect(s.topFrameId, rt);
      expect(s.topFrame!.id, rt);
    });

    test('deep stack top is deepest child', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch, gr]);
      expect(s.length, 3);
      expect(s.topFrameId, gr);
    });
  });

  group('pushLookupFrame', () {
    test('push frame with results pushed', () {
      final GlobalLookupStack s0 = GlobalLookupStack.empty;
      final GlobalLookupStack s1 =
          pushLookupFrame(s0, frame(rt, resultCount: 2));
      expect(idsOf(s1), <String>[rt]);
      final GlobalLookupStack s2 =
          pushLookupFrame(s1, frame(ch, parentIndex: 0, resultCount: 1));
      expect(idsOf(s2), <String>[rt, ch]);
    });

    test('no results not pushed original unchanged', () {
      final GlobalLookupStack s1 = stackOf(<String>[rt]);
      final GlobalLookupStack s2 =
          pushLookupFrame(s1, frame(em, parentIndex: 0, resultCount: 0));
      expect(idsOf(s2), <String>[rt]);
      final GlobalLookupStack s3 =
          pushLookupFrame(GlobalLookupStack.empty, frame(em, resultCount: 0));
      expect(s3.isEmpty, isTrue);
    });

    test('immutability push does not mutate original', () {
      final GlobalLookupStack s1 = stackOf(<String>[rt]);
      final GlobalLookupStack s2 =
          pushLookupFrame(s1, frame(ch, parentIndex: 0));
      expect(s1.length, 1);
      expect(s2.length, 2);
      expect(identical(s1, s2), isFalse);
    });
  });

  group('closeChildPopups truncate to parent inclusive', () {
    test('truncate to parentIndex inclusive', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch, gr]);
      expect(idsOf(closeChildPopups(s, 0)), <String>[rt]);
      expect(idsOf(closeChildPopups(s, 1)), <String>[rt, ch]);
    });

    test('parentIndex already last identity same object', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch]);
      expect(identical(closeChildPopups(s, 1), s), isTrue);
    });

    test('parentIndex out of range high unchanged', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch]);
      expect(identical(closeChildPopups(s, 5), s), isTrue);
    });

    test('parentIndex negative empty stack', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch]);
      expect(closeChildPopups(s, -1).isEmpty, isTrue);
    });

    test('does not mutate original', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch, gr]);
      closeChildPopups(s, 0);
      expect(idsOf(s), <String>[rt, ch, gr]);
    });
  });

  group('dismissPopupAt close index and children', () {
    test('close child back to parent keep prefix', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch, gr]);
      expect(idsOf(dismissPopupAt(s, 1)), <String>[rt]);
      expect(idsOf(dismissPopupAt(s, 2)), <String>[rt, ch]);
    });

    test('close root index 0 empty stack', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch, gr]);
      expect(dismissPopupAt(s, 0).isEmpty, isTrue);
    });

    test('closing child bumps parent clearSelectionSignal once', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch, gr]);
      final GlobalLookupStack afterChild = dismissPopupAt(s, 1);
      expect(
        afterChild.frames
            .singleWhere((GlobalLookupFrame f) => f.id == rt)
            .clearSelectionSignal,
        1,
      );
      final GlobalLookupStack afterGrand = dismissPopupAt(s, 2);
      expect(
        afterGrand.frames
            .singleWhere((GlobalLookupFrame f) => f.id == ch)
            .clearSelectionSignal,
        1,
      );
    });

    test('non-parent retained frames keep their signal', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch, gr]);
      final GlobalLookupStack after = dismissPopupAt(s, 2);
      expect(
        after.frames
            .singleWhere((GlobalLookupFrame f) => f.id == rt)
            .clearSelectionSignal,
        0,
      );
    });

    test('index out of range high unchanged', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch]);
      expect(identical(dismissPopupAt(s, 9), s), isTrue);
    });

    test('index negative empty stack', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch]);
      expect(dismissPopupAt(s, -3).isEmpty, isTrue);
    });

    test('does not mutate original signal', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch, gr]);
      dismissPopupAt(s, 1);
      expect(idsOf(s), <String>[rt, ch, gr]);
      expect(s.frames.first.clearSelectionSignal, 0);
    });
  });

  group('closeChildPopupsAndClearSelection tap outside popup', () {
    test('tap outside root keep root bump root signal', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch, gr]);
      final GlobalLookupStack after = closeChildPopupsAndClearSelection(s, 0);
      expect(idsOf(after), <String>[rt]);
      expect(after.frames.single.clearSelectionSignal, 1);
    });

    test('tap outside child keep root child only child bumped', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch, gr]);
      final GlobalLookupStack after = closeChildPopupsAndClearSelection(s, 1);
      expect(idsOf(after), <String>[rt, ch]);
      expect(
        after.frames
            .singleWhere((GlobalLookupFrame f) => f.id == rt)
            .clearSelectionSignal,
        0,
      );
      expect(
        after.frames
            .singleWhere((GlobalLookupFrame f) => f.id == ch)
            .clearSelectionSignal,
        1,
      );
    });

    test('parentIndex out of range unchanged', () {
      final GlobalLookupStack s = stackOf(<String>[rt]);
      expect(identical(closeChildPopupsAndClearSelection(s, 3), s), isTrue);
      expect(identical(closeChildPopupsAndClearSelection(s, -1), s), isTrue);
    });
  });

  group('closeChildPopupsForScrolledParent scroll reselect cuts children', () {
    test('root only parent already last identity no bump', () {
      final GlobalLookupStack s = stackOf(<String>[rt]);
      final GlobalLookupStack scrolled =
          closeChildPopupsForScrolledParent(s, 0);
      expect(identical(scrolled, s), isTrue);
      expect(scrolled.frames.single.clearSelectionSignal, 0);
    });

    test('parent with child scrolled cut child bump parent signal', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch]);
      final GlobalLookupStack scrolled =
          closeChildPopupsForScrolledParent(s, 0);
      expect(idsOf(scrolled), <String>[rt]);
      expect(scrolled.frames.single.clearSelectionSignal, 1);
    });

    test('deep middle scrolled cut all its children', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch, gr]);
      final GlobalLookupStack scrolled =
          closeChildPopupsForScrolledParent(s, 1);
      expect(idsOf(scrolled), <String>[rt, ch]);
      expect(
        scrolled.frames
            .singleWhere((GlobalLookupFrame f) => f.id == ch)
            .clearSelectionSignal,
        1,
      );
    });

    test('parentIndex out of range high identity', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch]);
      expect(identical(closeChildPopupsForScrolledParent(s, 9), s), isTrue);
    });

    test('does not mutate original stack', () {
      final GlobalLookupStack s = stackOf(<String>[rt, ch]);
      closeChildPopupsForScrolledParent(s, 0);
      expect(idsOf(s), <String>[rt, ch]);
      expect(s.frames.first.clearSelectionSignal, 0);
    });
  });

  group('immutability and equality', () {
    test('frames is unmodifiable', () {
      final GlobalLookupStack s = stackOf(<String>[rt]);
      expect(() => s.frames.add(frame('x')), throwsUnsupportedError);
    });

    test('GlobalLookupStack value equality', () {
      expect(stackOf(<String>['a', 'b']), stackOf(<String>['a', 'b']));
      expect(stackOf(<String>['a', 'b']) == stackOf(<String>['a']), isFalse);
    });

    test('GlobalLookupFrame copyWith does not mutate original', () {
      final GlobalLookupFrame f = frame(rt, clearSelectionSignal: 2);
      final GlobalLookupFrame g =
          f.copyWith(clearSelectionSignal: f.clearSelectionSignal + 1);
      expect(f.clearSelectionSignal, 2);
      expect(g.clearSelectionSignal, 3);
      expect(g.id, rt);
    });
  });
}
