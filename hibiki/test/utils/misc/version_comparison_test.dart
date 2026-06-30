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

    // BUG-480：用户铁律「正式版/测试版/调试版更新不能混」。基版本相同时，本通道的预发布
    // 绝不能被当成对正式版/别通道预发布的更新（semver 里 `x-debug.n < x`，预发布早于正式
    // 版，回灌在语义上也错）。此前这里断言「同基正式版可被本通道预发布推送=isTrue」，正是
    // 用户报告的混推根因，已随根因修复改为严格隔离。
    test(
        'BUG-480 prerelease channels do NOT push onto same-base stable install',
        () {
      // 正式版 1.0.1 装机 + 选 debug/beta 通道 → 同基预发布**不推送**（混推根因）。
      expect(
        isUpdateVersionNewer('0.5.1-debug.412', '0.5.1', UpdateChannel.debug),
        isFalse,
        reason: '正式版装机不得被同基 debug 预发布推送（不混渠道）',
      );
      expect(
        isUpdateVersionNewer('0.5.1-beta.412', '0.5.1', UpdateChannel.beta),
        isFalse,
        reason: '正式版装机不得被同基 beta 预发布推送（不混渠道）',
      );
      // stable 通道恒不接受预发布（既有契约保持）。
      expect(
        isUpdateVersionNewer('0.5.1-beta.412', '0.5.1', UpdateChannel.stable),
        isFalse,
      );
    });

    test('BUG-480 debug channel does NOT push onto same-base beta install', () {
      // beta 装机 1.0.1-beta.x + 选 debug 通道 → 同基 debug 预发布**不跨通道推送**。
      expect(
        isUpdateVersionNewer(
          '0.5.1-debug.412',
          '0.5.1-beta.300',
          UpdateChannel.debug,
        ),
        isFalse,
        reason: 'beta 装机不得被同基 debug 预发布跨通道推送',
      );
    });

    test('BUG-480 beta channel does NOT push onto same-base debug install', () {
      expect(
        isUpdateVersionNewer(
          '0.5.1-beta.412',
          '0.5.1-debug.300',
          UpdateChannel.beta,
        ),
        isFalse,
        reason: 'debug 装机不得被同基 beta 预发布跨通道推送',
      );
    });

    test(
        'BUG-480 same-channel sequence still advances (legit update preserved)',
        () {
      // 同通道序号递进=真更新，根因修复后必须仍然成立（别误伤正常 debug→debug 升级）。
      expect(
        isUpdateVersionNewer(
          '0.5.1-debug.413',
          '0.5.1-debug.412',
          UpdateChannel.debug,
        ),
        isTrue,
      );
      expect(
        isUpdateVersionNewer(
          '0.5.1-beta.413',
          '0.5.1-beta.412',
          UpdateChannel.beta,
        ),
        isTrue,
      );
    });

    test('BUG-480 same prerelease version is NOT newer (reject same version)',
        () {
      // 「不检测版本号相同」根因：同基同序号必须判 false（含带 +build 元数据的同号）。
      expect(
        isUpdateVersionNewer(
          '0.5.1-debug.412',
          '0.5.1-debug.412',
          UpdateChannel.debug,
        ),
        isFalse,
      );
      expect(
        isUpdateVersionNewer(
          '0.5.1-beta.412',
          '0.5.1-beta.412',
          UpdateChannel.beta,
        ),
        isFalse,
      );
      expect(
        isUpdateVersionNewer('1.0.1', '1.0.1', UpdateChannel.stable),
        isFalse,
        reason: '稳定通道同版本号不得提示更新',
      );
    });

    test('BUG-480 newer BASE version still updates across channel opt-in', () {
      // 跨通道升级走「基版本递增」这条正路（不靠同基回灌），必须仍然成立。
      expect(
        isUpdateVersionNewer('0.5.2-debug.1', '0.5.1', UpdateChannel.debug),
        isTrue,
      );
      expect(
        isUpdateVersionNewer('0.5.2-beta.1', '0.5.1', UpdateChannel.beta),
        isTrue,
      );
    });

    test('debug tags are normalized into comparable versions', () {
      expect(
        normalizeReleaseVersionTag('v0.5.1-debug.412+abc1234'),
        '0.5.1-debug.412',
      );
      expect(normalizeReleaseVersionTag('debug-abc1234'), isNull);
    });

    test('same installed debug run with build metadata is not newer again', () {
      expect(
        isUpdateVersionNewer(
          '0.5.4-debug.37',
          '0.5.4-debug.37+37',
          UpdateChannel.debug,
        ),
        isFalse,
      );
      expect(
        isUpdateVersionNewer(
          '0.5.4-debug.38',
          '0.5.4-debug.37',
          UpdateChannel.debug,
        ),
        isTrue,
      );
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
          _release(tag: 'v0.5.1-beta.12+abc1234', prerelease: true),
          UpdateChannel.beta,
        ),
        isFalse,
      );
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'v0.5.1-debug.12+abc1234', prerelease: true),
          UpdateChannel.beta,
        ),
        isFalse,
      );
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'v0.5.1-beta.foo', prerelease: true),
          UpdateChannel.beta,
        ),
        isFalse,
      );
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'v0.5.1-beta', prerelease: true),
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
          _release(tag: 'v0.5.1-debug.12', prerelease: true),
          UpdateChannel.debug,
        ),
        isFalse,
      );
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'v0.5.1-debug.12+foo', prerelease: true),
          UpdateChannel.debug,
        ),
        isFalse,
      );
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'debug-abc1234', prerelease: true),
          UpdateChannel.debug,
        ),
        isFalse,
      );
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'v0.5.1-debug.foo', prerelease: true),
          UpdateChannel.debug,
        ),
        isFalse,
      );
      expect(
        releaseMatchesUpdateChannel(
          _release(tag: 'v0.5.1-debug', prerelease: true),
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
