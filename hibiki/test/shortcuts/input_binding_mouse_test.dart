import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

void main() {
  group('MouseBinding', () {
    test('serialize/deserialize round-trip for known buttons', () {
      for (final b in const [1, 2, 3, 4]) {
        final mb = MouseBinding(b);
        expect(MouseBinding.deserialize(mb.serialize()), mb);
      }
    });

    test('middle button serializes to MouseMiddle', () {
      expect(const MouseBinding(1).serialize(), 'MouseMiddle');
    });

    test('unknown button survives round-trip via Mouse<n>', () {
      const mb = MouseBinding(7);
      expect(mb.serialize(), 'Mouse7');
      expect(MouseBinding.deserialize('Mouse7'), mb);
    });

    test('deserialize returns null for garbage', () {
      expect(MouseBinding.deserialize('Nope'), isNull);
    });

    test('equality and hashCode by button', () {
      expect(const MouseBinding(1), const MouseBinding(1));
      expect(const MouseBinding(1).hashCode, const MouseBinding(1).hashCode);
      expect(const MouseBinding(1) == const MouseBinding(2), isFalse);
    });
  });

  group('ShortcutBindingSet mouse', () {
    test('round-trips mouse bindings through json', () {
      const set = ShortcutBindingSet(mouseBindings: [MouseBinding(1)]);
      final restored = ShortcutBindingSet.fromJson(set.toJson());
      expect(restored.mouseBindings, [const MouseBinding(1)]);
    });

    test('legacy json without mouse field yields empty mouse list', () {
      final restored = ShortcutBindingSet.fromJson(const {
        'keyboard': <String>[],
        'gamepad': <String>[],
      });
      expect(restored.mouseBindings, isEmpty);
    });

    test('copyWith preserves mouse bindings', () {
      const set = ShortcutBindingSet(mouseBindings: [MouseBinding(1)]);
      expect(set.copyWith().mouseBindings, [const MouseBinding(1)]);
    });
  });
}
