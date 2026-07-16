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

  group('effectiveCurrentVersionForUpdateChannel (BUG-457)', () {
    test(
        'debug channel: plain X.Y.Z release restores seq from Android '
        'versionCode and detects newer debug build', () {
      // 复现用户设备：versionName=1.2.0（本地 release 包无 -debug 后缀），
      // versionCode=1000786300 → seq 7863；远端 debug 1.2.0-debug.7920 必须判为更新。
      final String effective = effectiveCurrentVersionForUpdateChannel(
        version: '1.2.0',
        buildNumber: '1000786300',
        channel: UpdateChannel.debug,
      );
      expect(effective, '1.2.0-debug.7863');
      expect(
        isUpdateVersionNewer(
            '1.2.0-debug.7920', effective, UpdateChannel.debug),
        isTrue,
        reason: 'installed debug seq 7863 must see debug 7920 as an update',
      );
    });

    test('debug channel: same installed seq is not re-offered', () {
      final String effective = effectiveCurrentVersionForUpdateChannel(
        version: '1.2.0',
        buildNumber: '1000792000',
        channel: UpdateChannel.debug,
      );
      expect(effective, '1.2.0-debug.7920');
      expect(
        isUpdateVersionNewer(
            '1.2.0-debug.7920', effective, UpdateChannel.debug),
        isFalse,
      );
    });

    test('desktop build number (raw seq) restores installed beta sequence', () {
      expect(
        effectiveCurrentVersionForUpdateChannel(
          version: '1.0.1',
          buildNumber: '6095',
          channel: UpdateChannel.beta,
        ),
        '1.0.1-beta.6095',
      );
      expect(
        isUpdateVersionNewer(
          '1.0.1-beta.6095',
          effectiveCurrentVersionForUpdateChannel(
            version: '1.0.1',
            buildNumber: '6095',
            channel: UpdateChannel.beta,
          ),
          UpdateChannel.beta,
        ),
        isFalse,
        reason: 'installed beta 6095 must not prompt for beta 6095 again',
      );
    });

    test('Android ABI versionCode offset is decoded to the release sequence',
        () {
      // 1e9 + 100*6095 + 2(abi offset) = 1000609502
      expect(
        effectiveCurrentVersionForUpdateChannel(
          version: '1.0.1',
          buildNumber: '1000609502',
          channel: UpdateChannel.beta,
        ),
        '1.0.1-beta.6095',
      );
    });

    test('stable channel returns normalized version unchanged', () {
      expect(
        effectiveCurrentVersionForUpdateChannel(
          version: '1.2.0+723',
          buildNumber: '1000786300',
          channel: UpdateChannel.stable,
        ),
        '1.2.0',
      );
    });

    test('version already carrying channel suffix is left untouched', () {
      expect(
        effectiveCurrentVersionForUpdateChannel(
          version: '1.2.0-debug.7863',
          buildNumber: '1000786300',
          channel: UpdateChannel.debug,
        ),
        '1.2.0-debug.7863',
      );
    });

    test('missing/unparseable build number fails open (no restore)', () {
      expect(
        effectiveCurrentVersionForUpdateChannel(
          version: '1.2.0',
          buildNumber: null,
          channel: UpdateChannel.debug,
        ),
        '1.2.0',
      );
      expect(
        effectiveCurrentVersionForUpdateChannel(
          version: '1.2.0',
          buildNumber: 'not-a-number',
          channel: UpdateChannel.debug,
        ),
        '1.2.0',
      );
    });

    test('foreign-channel prerelease suffix is not rewritten', () {
      // 本机装 beta 包但切到 debug 通道 → 不猜，交由既有严格判据（不还原）。
      expect(
        effectiveCurrentVersionForUpdateChannel(
          version: '1.2.0-beta.10',
          buildNumber: '1000786300',
          channel: UpdateChannel.debug,
        ),
        '1.2.0-beta.10',
      );
    });
  });

  // BUG-846：嵌套合集——越激进的通道合集越大（stable⊆beta⊆debug）。测试版/调试版应能
  // 收到更新的正式版/更高基版本，永不掉队；但更保守的通道不得反向收到更激进轨道。
  group('BUG-846 nested update channels (isUpdateVersionNewer)', () {
    test('beta channel receives a higher-base stable release', () {
      expect(
        isUpdateVersionNewer('1.3.0', '1.2.0-beta.5', UpdateChannel.beta),
        isTrue,
        reason: 'beta 用户应收到更高基版本的正式版',
      );
    });

    test('beta channel receives the finished same-base stable release', () {
      // beta 用户在 1.2.0-beta.5，正式版 1.2.0 出了（成品早于预发布？不——预发布早于成品，
      // semver 里 1.2.0 > 1.2.0-beta.5）→ 应领到成品 1.2.0（用户原始诉求）。
      expect(
        isUpdateVersionNewer('1.2.0', '1.2.0-beta.5', UpdateChannel.beta),
        isTrue,
        reason: 'beta 用户应领到同基的成品正式版',
      );
    });

    test('stranded beta gets newer stable patch when beta paused', () {
      // beta 停在 1.2.0-beta.5，正式版继续发补丁 1.2.1 → 不再被卡死。
      expect(
        isUpdateVersionNewer('1.2.1', '1.2.0-beta.5', UpdateChannel.beta),
        isTrue,
      );
    });

    test('debug channel receives stable and beta (largest 合集)', () {
      expect(
        isUpdateVersionNewer('1.3.0', '1.2.0-debug.100', UpdateChannel.debug),
        isTrue,
        reason: 'debug 用户应收到更高基正式版',
      );
      expect(
        isUpdateVersionNewer('1.2.0', '1.2.0-debug.100', UpdateChannel.debug),
        isTrue,
        reason: 'debug 用户应领到同基成品正式版',
      );
      expect(
        isUpdateVersionNewer(
          '1.3.0-beta.1',
          '1.2.0-debug.100',
          UpdateChannel.debug,
        ),
        isTrue,
        reason: 'debug 合集含 beta 轨：更高基 beta 也应收到',
      );
    });

    test('stable channel never receives prereleases (smallest 合集)', () {
      expect(
        isUpdateVersionNewer('1.3.0-beta.1', '1.2.0', UpdateChannel.stable),
        isFalse,
        reason: '正式版通道合集只含 stable，不收 beta',
      );
      expect(
        isUpdateVersionNewer('1.3.0-debug.1', '1.2.0', UpdateChannel.stable),
        isFalse,
        reason: '正式版通道不收 debug',
      );
    });

    test('beta channel does NOT receive debug builds (debug ∉ beta 合集)', () {
      // 关键不对称：debug 只在 debug 合集里；beta 用户拿不到 debug 预发布。
      expect(
        isUpdateVersionNewer(
          '1.3.0-debug.1',
          '1.2.0-beta.5',
          UpdateChannel.beta,
        ),
        isFalse,
        reason: 'beta 合集={stable,beta}，不含 debug 轨',
      );
    });

    test('same-base cross-track prerelease still blocked (BUG-480 preserved)',
        () {
      // 嵌套放开的只是「正向收更稳定轨/更高基」；同基跨轨预发布互推仍禁。
      expect(
        isUpdateVersionNewer(
          '1.2.0-debug.200',
          '1.2.0-beta.100',
          UpdateChannel.debug,
        ),
        isFalse,
        reason: '同基 beta 装机不得被同基 debug 跨轨回灌',
      );
    });
  });

  group('BUG-846 releaseEligibleForChannel (nested admission)', () {
    test('beta 合集 admits stable + beta, rejects debug', () {
      expect(
        releaseEligibleForChannel(
          _release(tag: 'v1.2.0', prerelease: false),
          UpdateChannel.beta,
        ),
        isTrue,
      );
      expect(
        releaseEligibleForChannel(
          _release(tag: 'v1.3.0-beta.1', prerelease: true),
          UpdateChannel.beta,
        ),
        isTrue,
      );
      expect(
        releaseEligibleForChannel(
          _release(tag: 'v1.3.0-debug.1+abc1234', prerelease: true),
          UpdateChannel.beta,
        ),
        isFalse,
      );
    });

    test('debug 合集 admits all three tracks', () {
      expect(
        releaseEligibleForChannel(
          _release(tag: 'v1.2.0', prerelease: false),
          UpdateChannel.debug,
        ),
        isTrue,
      );
      expect(
        releaseEligibleForChannel(
          _release(tag: 'v1.3.0-beta.1', prerelease: true),
          UpdateChannel.debug,
        ),
        isTrue,
      );
      expect(
        releaseEligibleForChannel(
          _release(tag: 'v1.3.0-debug.1+abc1234', prerelease: true),
          UpdateChannel.debug,
        ),
        isTrue,
      );
    });

    test('stable 合集 admits only stable', () {
      expect(
        releaseEligibleForChannel(
          _release(tag: 'v1.2.0', prerelease: false),
          UpdateChannel.stable,
        ),
        isTrue,
      );
      expect(
        releaseEligibleForChannel(
          _release(tag: 'v1.3.0-beta.1', prerelease: true),
          UpdateChannel.stable,
        ),
        isFalse,
      );
    });
  });

  group('BUG-846 selectUpdateReleaseForCurrentPlatform (union + ordering)', () {
    AndroidUpdater arm64Updater() =>
        AndroidUpdater(abiProvider: () async => <String>['arm64-v8a']);

    test('beta user picks higher-base beta over same-base stable', () async {
      // beta 轨领先（1.3.0-beta.1）时选 beta，而非因 stable 1.2.0 排前而误选旧版。
      final UpdateReleaseSelection? sel =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _relWithApks('v1.2.0',
              prerelease: false, apks: <String>['hibiki-1.2.0-arm64-v8a.apk']),
          _relWithApks('v1.3.0-beta.1',
              prerelease: true, apks: <String>['hibiki-1.3.0-arm64-v8a.apk']),
        ],
        currentVersion: '1.2.0-beta.5',
        channel: UpdateChannel.beta,
        updater: arm64Updater(),
      );
      expect(sel?.version, '1.3.0-beta.1');
    });

    test('stranded beta user falls back to newer stable', () async {
      // beta 停在 1.2.0-beta.5（latest beta == 本机），正式版补丁 1.2.1 出 → 选 stable。
      final UpdateReleaseSelection? sel =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _relWithApks('v1.2.1',
              prerelease: false, apks: <String>['hibiki-1.2.1-arm64-v8a.apk']),
          _relWithApks('v1.2.0-beta.5',
              prerelease: true, apks: <String>['hibiki-1.2.0-arm64-v8a.apk']),
        ],
        currentVersion: '1.2.0-beta.5',
        channel: UpdateChannel.beta,
        updater: arm64Updater(),
      );
      expect(sel?.version, '1.2.1');
    });

    test('debug user can install a stable release asset (non-debug apk name)',
        () async {
      // selectAsset 按 release 自身轨道过滤 asset：stable 包无 -debug 后缀，debug 用户
      // 仍能选到它（否则会因不含 -debug 被误拒、拿不到 stable 更新）。
      final UpdateReleaseSelection? sel =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _relWithApks('v1.3.0',
              prerelease: false, apks: <String>['hibiki-1.3.0-arm64-v8a.apk']),
        ],
        currentVersion: '1.2.0-debug.100',
        channel: UpdateChannel.debug,
        updater: arm64Updater(),
      );
      expect(sel?.version, '1.3.0');
      expect(sel?.asset?.name, 'hibiki-1.3.0-arm64-v8a.apk');
    });

    test('debug user stays on debug track over same-base stable', () async {
      // 同基场景：debug 轨更前沿构建优先于同基成品 stable，避免塌回 stable 后再也收不到
      // 后续 debug 构建。
      final UpdateReleaseSelection? sel =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _relWithApks('v1.2.0',
              prerelease: false, apks: <String>['hibiki-1.2.0-arm64-v8a.apk']),
          _relWithApks('v1.2.0-debug.200+abc1234',
              prerelease: true,
              apks: <String>['hibiki-1.2.0-abc1234-debug.apk']),
        ],
        currentVersion: '1.2.0-debug.100',
        channel: UpdateChannel.debug,
        updater: arm64Updater(),
      );
      expect(sel?.version, '1.2.0-debug.200');
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

Map<String, dynamic> _relWithApks(
  String tag, {
  required bool prerelease,
  required List<String> apks,
}) =>
    <String, dynamic>{
      'tag_name': tag,
      'prerelease': prerelease,
      'draft': false,
      'body': '',
      'html_url': 'https://github.com/hajisensai/hibiki/releases/tag/$tag',
      'assets': <Map<String, dynamic>>[
        for (final String name in apks)
          <String, dynamic>{
            'name': name,
            'browser_download_url':
                'https://github.com/hajisensai/hibiki/releases/download/$tag/$name',
          },
      ],
    };
