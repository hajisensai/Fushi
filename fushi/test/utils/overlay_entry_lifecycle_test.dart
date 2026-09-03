import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/overlay_entry_lifecycle.dart';

void main() {
  testWidgets(
    'owned entry is removed before dispose when opaque cover unmounts its widget',
    (WidgetTester tester) async {
      final GlobalKey<OverlayState> overlayKey = GlobalKey<OverlayState>();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Overlay(
            key: overlayKey,
            initialEntries: <OverlayEntry>[
              OverlayEntry(builder: (_) => const SizedBox.expand()),
            ],
          ),
        ),
      );

      final OverlayEntry owned = OverlayEntry(
        builder: (_) => const Text('owned entry'),
      );
      overlayKey.currentState!.insert(owned);
      await tester.pump();
      expect(owned.mounted, isTrue);

      final OverlayEntry opaqueCover = OverlayEntry(
        opaque: true,
        builder: (_) => const SizedBox.expand(),
      );
      overlayKey.currentState!.insert(opaqueCover);
      await tester.pump();
      expect(
        owned.mounted,
        isFalse,
        reason:
            'opaque overlay keeps the entry registered but unmounts its widget',
      );

      expect(() => removeAndDisposeOwnedOverlayEntry(owned), returnsNormally);

      opaqueCover.remove();
      opaqueCover.dispose();
    },
  );
}
