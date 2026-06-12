import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/misc/platform_updater.dart';
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

    test('prerelease identifiers are compared when base matches', () {
      expect(isVersionNewer('1.2.3-beta.2', '1.2.3-beta.1'), isTrue);
      expect(isVersionNewer('1.2.3-beta.1', '1.2.3-beta.2'), isFalse);
      expect(isVersionNewer('1.2.3-debug.12', '1.2.3-debug.2'), isTrue);
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

    test('selected prerelease channels can move from same-base stable', () {
      expect(
        isUpdateVersionNewer(
          '0.5.1-debug.412',
          '0.5.1',
          UpdateChannel.debug,
        ),
        isTrue,
      );
      expect(
        isUpdateVersionNewer(
          '0.5.1-beta.412',
          '0.5.1',
          UpdateChannel.beta,
        ),
        isTrue,
      );
      expect(
        isUpdateVersionNewer(
          '0.5.1-beta.412',
          '0.5.1',
          UpdateChannel.stable,
        ),
        isFalse,
      );
    });

    test('debug tags are normalized into comparable versions', () {
      expect(
        normalizeReleaseVersionTag('v0.5.1-debug.412+abc1234'),
        '0.5.1-debug.412',
      );
      expect(normalizeReleaseVersionTag('debug-abc1234'), isNull);
    });
  });

  group('releaseMatchesUpdateChannel', () {
    test('stable latest excludes prereleases', () {
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'v0.5.1', prerelease: false),
          UpdateChannel.stable,
        ),
        isTrue,
      );
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'v0.5.1-beta.12', prerelease: true),
          UpdateChannel.stable,
        ),
        isFalse,
      );
    });

    test('beta prerelease excludes stable and debug releases', () {
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'v0.5.1-beta.12', prerelease: true),
          UpdateChannel.beta,
        ),
        isTrue,
      );
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'v0.5.1-debug.12+abc1234', prerelease: true),
          UpdateChannel.beta,
        ),
        isFalse,
      );
    });

    test('debug prerelease requires comparable debug tag', () {
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'v0.5.1-debug.12+abc1234', prerelease: true),
          UpdateChannel.debug,
        ),
        isTrue,
      );
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'debug-abc1234', prerelease: true),
          UpdateChannel.debug,
        ),
        isFalse,
      );
    });
  });
}

Map<String, dynamic> _release({
  required String tag,
  required bool prerelease,
  bool draft = false,
}) =>
    <String, dynamic>{
      'tag_name': tag,
      'prerelease': prerelease,
      'draft': draft,
    };
