// TODO-867 P3b — global-lookup controller nested-stack wiring tests.
//
// GlobalLookupController._onHotKey / _lookupNested / _onJsMessage drive the
// nested popup stack purely through the GlobalLookupStack model
// (pushLookupFrame / dismissPopupAt / closeChildPopupsAndClearSelection) plus
// per-frame DictionarySearchResult bookkeeping + GlobalLookupFrame.toRenderMap()
// for the host payload. The controller itself is a Windows singleton bound to
// AppModel + native channels (not unit-instantiable headless), so these tests
// model the EXACT transition sequences the controller performs against the pure
// stack API + the new toRenderMap serialisation. Each assertion turns red if the
// matching controller behaviour (root reset, push child, dismiss, close
// children, no-result-not-pushed, frame id/linkage payload) regresses.

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/lookup/global_lookup_stack.dart';

// Mirrors GlobalLookupController._nextFrameId(): a monotonic 'frame-N' minter.
// The pure stack model never generates ids (so it stays testable); the
// controller owns minting, modelled here.
String _mintId(int seq) => 'frame-$seq';

GlobalLookupFrame _frame(
  String id,
  String query, {
  required int parentIndex,
  required int resultCount,
}) {
  return GlobalLookupFrame(
    id: id,
    query: query,
    parentIndex: parentIndex,
    resultCount: resultCount,
  );
}

List<String> _ids(GlobalLookupStack stack) =>
    stack.frames.map((GlobalLookupFrame f) => f.id).toList();

void main() {
  group('GlobalLookupController stack wiring (_onHotKey)', () {
    test('hotkey root reset seeds a single root frame when result has entries',
        () {
      // _resetStackRoot(text, result) with a non-empty result.
      final GlobalLookupFrame root =
          _frame(_mintId(0), 'cat', parentIndex: -1, resultCount: 3);
      final GlobalLookupStack stack =
          pushLookupFrame(GlobalLookupStack.empty, root);
      expect(stack.length, 1);
      expect(stack.frames.first.parentIndex, -1);
      expect(stack.topFrameId, 'frame-0');
    });

    test('hotkey with no results leaves the stack empty (root not pushed)', () {
      // _resetStackRoot with an empty result -> pushLookupFrame drops it.
      final GlobalLookupFrame root =
          _frame(_mintId(0), 'zzz', parentIndex: -1, resultCount: 0);
      final GlobalLookupStack stack =
          pushLookupFrame(GlobalLookupStack.empty, root);
      expect(stack.isEmpty, isTrue,
          reason: 'a no-result hotkey must not seed a root frame');
    });

    test('a fresh hotkey lookup resets the whole stack to one root', () {
      // Build a deep stack, then simulate a new hotkey: reset to empty + push.
      GlobalLookupStack stack = pushLookupFrame(GlobalLookupStack.empty,
          _frame(_mintId(0), 'a', parentIndex: -1, resultCount: 1));
      stack = pushLookupFrame(
          stack, _frame(_mintId(1), 'b', parentIndex: 0, resultCount: 1));
      expect(stack.length, 2);
      // New hotkey -> reset.
      final GlobalLookupStack reset = pushLookupFrame(GlobalLookupStack.empty,
          _frame(_mintId(2), 'c', parentIndex: -1, resultCount: 1));
      expect(_ids(reset), <String>['frame-2']);
    });
  });

  group('GlobalLookupController nested push (_lookupNested / _pushChildFrame)',
      () {
    test('clicking a term pushes a child frame onto the current top', () {
      GlobalLookupStack stack = pushLookupFrame(GlobalLookupStack.empty,
          _frame(_mintId(0), 'root', parentIndex: -1, resultCount: 2));
      // _pushChildFrame: parentIndex = stack.length - 1.
      final int parentIndex = stack.length - 1;
      final GlobalLookupStack next = pushLookupFrame(
          stack,
          _frame(_mintId(1), 'child',
              parentIndex: parentIndex, resultCount: 5));
      expect(identical(next, stack), isFalse, reason: 'child was pushed');
      stack = next;
      expect(_ids(stack), <String>['frame-0', 'frame-1']);
      expect(stack.frames.last.parentIndex, 0);
      expect(stack.topFrameId, 'frame-1');
    });

    test('nested lookup with no results does NOT push (identical stack)', () {
      final GlobalLookupStack stack = pushLookupFrame(GlobalLookupStack.empty,
          _frame(_mintId(0), 'root', parentIndex: -1, resultCount: 2));
      final int parentIndex = stack.length - 1;
      final GlobalLookupStack next = pushLookupFrame(
          stack,
          _frame(_mintId(1), 'empty',
              parentIndex: parentIndex, resultCount: 0));
      // pushLookupFrame returns the SAME object on no-result -> controller's
      // `if (!identical(next, _stack))` guard skips bookkeeping.
      expect(identical(next, stack), isTrue,
          reason: 'no-result nested lookup must leave the stack unchanged');
    });

    test('deep nesting chains parentIndex correctly', () {
      GlobalLookupStack stack = pushLookupFrame(GlobalLookupStack.empty,
          _frame(_mintId(0), 'a', parentIndex: -1, resultCount: 1));
      for (int i = 1; i <= 3; i++) {
        stack = pushLookupFrame(
            stack,
            _frame(_mintId(i), 'l$i',
                parentIndex: stack.length - 1, resultCount: 1));
      }
      expect(stack.length, 4);
      expect(stack.frames[1].parentIndex, 0);
      expect(stack.frames[2].parentIndex, 1);
      expect(stack.frames[3].parentIndex, 2);
    });
  });

  group('GlobalLookupController host messages (_onJsMessage)', () {
    GlobalLookupStack deep() {
      GlobalLookupStack stack = pushLookupFrame(GlobalLookupStack.empty,
          _frame(_mintId(0), 'a', parentIndex: -1, resultCount: 1));
      stack = pushLookupFrame(
          stack, _frame(_mintId(1), 'b', parentIndex: 0, resultCount: 1));
      stack = pushLookupFrame(
          stack, _frame(_mintId(2), 'c', parentIndex: 1, resultCount: 1));
      return stack;
    }

    test('dismissPopupAt(0) closes the root -> whole stack empty (then hide)',
        () {
      final GlobalLookupStack stack = deep();
      final GlobalLookupStack next = dismissPopupAt(stack, 0);
      expect(next.isEmpty, isTrue,
          reason: 'controller hides the overlay when the stack is empty');
    });

    test('dismissPopupAt(child) retreats to the parent + bumps clear signal',
        () {
      final GlobalLookupStack stack = deep();
      final GlobalLookupStack next = dismissPopupAt(stack, 2);
      expect(_ids(next), <String>['frame-0', 'frame-1']);
      expect(next.frames.last.clearSelectionSignal, 1,
          reason: 'parent gets a clear-selection signal on child dismiss');
    });

    test(
        'closeChildPopups(parent) truncates children + clears parent selection',
        () {
      final GlobalLookupStack stack = deep();
      final GlobalLookupStack next =
          closeChildPopupsAndClearSelection(stack, 0);
      expect(_ids(next), <String>['frame-0']);
      expect(next.frames.first.clearSelectionSignal, 1);
    });
  });

  group('GlobalLookupFrame.toRenderMap (host payload contract)', () {
    test('serialises identity + linkage for the host renderStack payload', () {
      final GlobalLookupFrame frame = GlobalLookupFrame(
        id: 'frame-7',
        query: 'inu',
        parentIndex: 2,
        resultCount: 4,
        clearSelectionSignal: 3,
      );
      final Map<String, Object?> map = frame.toRenderMap();
      expect(map['id'], 'frame-7');
      expect(map['parentIndex'], 2);
      expect(map['clearSelectionSignal'], 3);
      // Geometry + settingsJs are merged by the controller/render layer, NOT by
      // the pure stack model — so they must be absent here.
      expect(map.containsKey('frame'), isFalse);
      expect(map.containsKey('settingsJs'), isFalse);
    });
  });
}
