import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/update_checker.dart';

void main() {
  group('isVersionNewer', () {
    test('major version bump', () {
      expect(isVersionNewer('2.0.0', '1.0.0'), isTrue);
      expect(isVersionNewer('1.0.0', '2.0.0'), isFalse);
    });

    test('minor version bump', () {
      expect(isVersionNewer('1.1.0', '1.0.0'), isTrue);
      expect(isVersionNewer('1.0.0', '1.1.0'), isFalse);
    });

    test('patch version bump', () {
      expect(isVersionNewer('1.0.1', '1.0.0'), isTrue);
      expect(isVersionNewer('1.0.0', '1.0.1'), isFalse);
    });

    test('same version', () {
      expect(isVersionNewer('1.0.0', '1.0.0'), isFalse);
      expect(isVersionNewer('0.2.9', '0.2.9'), isFalse);
    });

    test('build metadata stripped', () {
      expect(isVersionNewer('1.0.1+42', '1.0.0+1'), isTrue);
      expect(isVersionNewer('1.0.0+42', '1.0.0+1'), isFalse);
    });

    test('prerelease vs stable: stable wins on same base', () {
      expect(isVersionNewer('1.2.3', '1.2.3-beta.1'), isTrue);
      expect(isVersionNewer('1.2.3-beta.1', '1.2.3'), isFalse);
    });

    test('prerelease vs prerelease of same base: not newer', () {
      expect(isVersionNewer('1.2.3-beta.1', '1.2.3-beta.2'), isFalse);
    });

    test('higher base prerelease vs lower base stable', () {
      expect(isVersionNewer('2.0.0-beta.1', '1.9.9'), isTrue);
    });

    test('different segment counts', () {
      expect(isVersionNewer('1.0.0.1', '1.0.0'), isTrue);
      expect(isVersionNewer('1.0', '1.0.0'), isFalse);
      expect(isVersionNewer('1.0.0', '1.0'), isFalse);
    });

    test('v prefix in tag stripped before calling', () {
      // The caller strips v prefix, but isVersionNewer itself doesn't.
      // Verify the function handles versions without v prefix.
      expect(isVersionNewer('0.3.0', '0.2.9'), isTrue);
    });
  });
}
