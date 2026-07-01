import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_trends.dart';

void main() {
  group('goalProgressFraction', () {
    test('partial progress is read/goal', () {
      expect(goalProgressFraction(500, 1000), closeTo(0.5, 1e-9));
      expect(goalProgressFraction(250, 1000), closeTo(0.25, 1e-9));
    });

    test('caps at 1.0 when read exceeds goal', () {
      expect(goalProgressFraction(1500, 1000), 1.0);
    });

    test('read == goal yields exactly 1.0', () {
      expect(goalProgressFraction(1000, 1000), 1.0);
    });

    test('goal <= 0 returns null (closed / not set)', () {
      expect(goalProgressFraction(500, 0), isNull);
      expect(goalProgressFraction(0, 0), isNull);
      expect(goalProgressFraction(500, -100), isNull);
    });

    test('read < 0 treated as 0', () {
      expect(goalProgressFraction(-5, 1000), 0);
    });
  });

  group('goalReached', () {
    test('true when read >= goal and goal > 0', () {
      expect(goalReached(1000, 1000), isTrue);
      expect(goalReached(1500, 1000), isTrue);
    });

    test('false when read < goal', () {
      expect(goalReached(999, 1000), isFalse);
    });

    test('false when goal <= 0 regardless of read', () {
      expect(goalReached(5, 0), isFalse);
      expect(goalReached(0, 0), isFalse);
      expect(goalReached(100, -1), isFalse);
    });
  });
}
