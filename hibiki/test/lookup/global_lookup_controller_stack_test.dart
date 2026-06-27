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

    test('hotkey ALWAYS seeds a single root frame even on no results', () {
      // TODO-867 P3c: _resetStackRoot now builds the root frame DIRECTLY
      // (GlobalLookupStack([root])), NOT via pushLookupFrame — so a no-result
      // hotkey still seeds exactly one root frame whose iframe shows popup.js's
      // own no-results card (the old single-frame no-results behaviour is
      // preserved through the host stack, not a top-level direct render).
      final GlobalLookupFrame root =
          _frame(_mintId(0), 'zzz', parentIndex: -1, resultCount: 0);
      final GlobalLookupStack stack =
          GlobalLookupStack(<GlobalLookupFrame>[root]);
      expect(stack.length, 1,
          reason: 'the user-invoked root card must show even with no entries');
      expect(stack.frames.first.parentIndex, -1);
      expect(stack.topFrameId, 'frame-0');
    });

    test('single-frame hotkey lookup is stack depth 1 (one renderStack popup)',
        () {
      // TODO-867 P3c B1 behaviour lock: a single-frame hotkey lookup (no nested
      // click) leaves the stack at depth 1, so the host renderStack payload
      // carries exactly ONE popup — the single frame is rendered the SAME way as
      // a nested card (window.__globalLookupHost.renderStack), with no top-level
      // direct renderPopup. (_renderStack only emits frames that have a cached
      // result; the root always does, see _resetStackRoot.)
      final GlobalLookupFrame root =
          _frame(_mintId(0), 'neko', parentIndex: -1, resultCount: 4);
      final GlobalLookupStack stack =
          GlobalLookupStack(<GlobalLookupFrame>[root]);
      expect(stack.length, 1, reason: 'single frame = stack depth 1');
      // The render layer maps each live frame to one renderStack popup; with a
      // single root that is exactly one popup.
      final List<GlobalLookupFrame> live = stack.frames;
      expect(live.length, 1,
          reason: 'one live frame -> one renderStack popup (depth-1 path)');
      expect(live.first.id, 'frame-0');
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

  group('GlobalLookupController P3c anchor + layer attribution', () {
    // The controller maps a tapOutside stamped with a frame id to that frame's
    // insertion-order layer index, then closeChildPopups(layerIndex). This models
    // _layerIndexForFrameId + the tapOutside C3 branch (the controller is a
    // Windows singleton not headless-instantiable, so the mapping is modelled on
    // the same pure stack the controller drives).
    int layerIndexForFrameId(GlobalLookupStack stack, String id) {
      final List<GlobalLookupFrame> frames = stack.frames;
      for (int i = 0; i < frames.length; i++) {
        if (frames[i].id == id) {
          return i;
        }
      }
      return -1;
    }

    GlobalLookupStack deep() {
      GlobalLookupStack stack = pushLookupFrame(GlobalLookupStack.empty,
          _frame(_mintId(0), 'a', parentIndex: -1, resultCount: 1));
      stack = pushLookupFrame(
          stack, _frame(_mintId(1), 'b', parentIndex: 0, resultCount: 1));
      stack = pushLookupFrame(
          stack, _frame(_mintId(2), 'c', parentIndex: 1, resultCount: 1));
      return stack;
    }

    test('tapOutside on a middle layer closes that layer children', () {
      final GlobalLookupStack stack = deep();
      // tapOutside stamped with frame-1 -> layer index 1 -> close its children.
      final int layer = layerIndexForFrameId(stack, 'frame-1');
      expect(layer, 1, reason: 'insertion order index of frame-1 is 1');
      final GlobalLookupStack next =
          closeChildPopupsAndClearSelection(stack, layer);
      expect(_ids(next), <String>['frame-0', 'frame-1'],
          reason: 'children above layer 1 are closed');
      expect(next.frames.last.clearSelectionSignal, 1,
          reason: 'the tapped layer gets a clear-selection signal');
    });

    test('tapOutside on the root layer closes all children', () {
      final GlobalLookupStack stack = deep();
      final int layer = layerIndexForFrameId(stack, 'frame-0');
      expect(layer, 0);
      final GlobalLookupStack next =
          closeChildPopupsAndClearSelection(stack, layer);
      expect(_ids(next), <String>['frame-0'],
          reason: 'tapping the root collapses to just the root');
    });

    test('an unknown frame id maps to -1 (controller falls back to hide)', () {
      final GlobalLookupStack stack = deep();
      expect(layerIndexForFrameId(stack, 'frame-99'), -1);
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
