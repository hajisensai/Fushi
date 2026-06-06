import 'package:flutter/widgets.dart' show Rect, Offset;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/drag_drop/card_hit_test.dart';

void main() {
  group('hitTestCards', () {
    final cards = <CardRect<String>>[
      CardRect(rect: const Rect.fromLTWH(0, 0, 100, 100), meta: 'a'),
      CardRect(rect: const Rect.fromLTWH(100, 0, 100, 100), meta: 'b'),
    ];

    test('returns meta of card containing the point', () {
      expect(hitTestCards(cards, const Offset(50, 50)), 'a');
      expect(hitTestCards(cards, const Offset(150, 50)), 'b');
    });

    test('returns null when point is outside all cards', () {
      expect(hitTestCards(cards, const Offset(300, 300)), isNull);
    });

    test('returns first match on overlap', () {
      final overlap = <CardRect<String>>[
        CardRect(rect: const Rect.fromLTWH(0, 0, 100, 100), meta: 'first'),
        CardRect(rect: const Rect.fromLTWH(0, 0, 100, 100), meta: 'second'),
      ];
      expect(hitTestCards(overlap, const Offset(10, 10)), 'first');
    });

    test('empty list returns null', () {
      expect(hitTestCards(<CardRect<String>>[], const Offset(0, 0)), isNull);
    });
  });
}
