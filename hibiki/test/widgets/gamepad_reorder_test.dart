import 'package:flutter_test/flutter_test.dart';

// Mirrors ReorderableListView.onReorder's index compensation. The gamepad
// up/down reorder buttons (sync URLs, dictionary audio sources, fonts,
// dictionaries) call onReorder(index, index-1) to move UP and
// onReorder(index, index+2) to move DOWN — the +2 accounts for the
// `if (newIndex > oldIndex) newIndex--` decrement. This is the easy-to-get-
// wrong bit, so it is pinned here.
List<String> applyReorder(List<String> list, int oldIndex, int newIndex) {
  final List<String> copy = <String>[...list];
  if (newIndex > oldIndex) newIndex--;
  final String item = copy.removeAt(oldIndex);
  copy.insert(newIndex, item);
  return copy;
}

void main() {
  group('gamepad reorder index math (up = index-1, down = index+2)', () {
    test('move up swaps the item with the previous one', () {
      expect(
        applyReorder(<String>['a', 'b', 'c', 'd'], 2, 2 - 1),
        <String>['a', 'c', 'b', 'd'],
      );
    });

    test('move down swaps the item with the next one (the +2 compensation)',
        () {
      expect(
        applyReorder(<String>['a', 'b', 'c', 'd'], 1, 1 + 2),
        <String>['a', 'c', 'b', 'd'],
      );
    });

    test('move up at the second slot reaches the top', () {
      expect(applyReorder(<String>['a', 'b'], 1, 1 - 1), <String>['b', 'a']);
    });

    test('move down at the first slot reaches the second', () {
      expect(applyReorder(<String>['a', 'b'], 0, 0 + 2), <String>['b', 'a']);
    });

    test('a plain index+1 down (WITHOUT compensation) would be wrong', () {
      // Demonstrates why +2 is needed: index+1 overshoots by one.
      expect(
        applyReorder(<String>['a', 'b', 'c', 'd'], 1, 1 + 1),
        isNot(<String>['a', 'c', 'b', 'd']),
      );
    });
  });
}
