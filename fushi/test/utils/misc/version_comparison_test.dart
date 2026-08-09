import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart';
import 'package:fushi/src/utils/misc/update_checker.dart';

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

    test('BUG-846 谁后用谁: debug channel takes newer-seq debug over beta build',
        () {
      // 用户新判据「谁后构建谁赢」：同基跨轨按 release sequence 比先后（seq 三通道同尺）。
      // debug 通道用户装着 beta.300，远端 debug.412 序号更大=构建更晚 → 应更新（合集门天然
      // 限制：只有 debug 通道能看到 debug 轨，不会误推给 beta/stable 用户）。
      expect(
        isUpdateVersionNewer(
          '0.5.1-debug.412',
          '0.5.1-beta.300',
          UpdateChannel.debug,
        ),
        isTrue,
        reason: 'debug.412 比 beta.300 构建更晚（谁后用谁）',
      );
      // 反向：装着 debug.412，远端 beta.300 序号更小=更早 → 不更新。
      expect(
        isUpdateVersionNewer(
          '0.5.1-beta.300',
          '0.5.1-debug.412',
          UpdateChannel.debug,
        ),
        isFalse,
        reason: 'beta.300 比 debug.412 更早，不回退',
      );
    });

    test('BUG-846 谁后用谁: beta channel takes newer-seq beta over debug build',
        () {
      // beta 通道用户装着 debug.300（历史遗留），远端 beta.412 更晚 → 更新到 beta 头。
      expect(
        isUpdateVersionNewer(
          '0.5.1-beta.412',
          '0.5.1-debug.300',
          UpdateChannel.beta,
        ),
        isTrue,
        reason: 'beta.412 比 debug.300 构建更晚（谁后用谁）',
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

  group('currentReleaseSequence + 谁后用谁 乒乓根治 (BUG-846)', () {
    test('Android versionCode decodes to the release sequence', () {
      // 正式版包无 -debug 后缀：versionCode 1e9 + 100*7863 = 1000786300 → seq 7863。
      expect(
        currentReleaseSequence(version: '1.2.0', buildNumber: '1000786300'),
        7863,
      );
    });

    test('desktop raw build number is the release sequence', () {
      expect(
        currentReleaseSequence(version: '1.0.1', buildNumber: '6095'),
        6095,
      );
    });

    test('Android ABI offset is stripped from the release sequence', () {
      // 1e9 + 100*6095 + 2(abi offset) = 1000609502 → seq 6095。
      expect(
        currentReleaseSequence(version: '1.0.1', buildNumber: '1000609502'),
        6095,
      );
    });

    test('prerelease suffix seq wins over build number (no fabrication)', () {
      // 版本串已带 -debug.7863 → 直接取尾号（不看 buildNumber），且**不改轨道标签**。
      expect(
        currentReleaseSequence(
            version: '1.2.0-debug.7863', buildNumber: '1000792000'),
        7863,
      );
      expect(
        currentReleaseSequence(version: '1.0.1-beta.6095', buildNumber: null),
        6095,
      );
      // +build 元数据不影响。
      expect(
        currentReleaseSequence(version: '1.2.0+723', buildNumber: '1000786300'),
        7863,
      );
    });

    test('missing/unparseable build number → null (conservative, no churn)',
        () {
      expect(
          currentReleaseSequence(version: '1.2.0', buildNumber: null), isNull);
      expect(
        currentReleaseSequence(version: '1.2.0', buildNumber: 'not-a-number'),
        isNull,
      );
    });

    test(
        'debug user on plain stable 1.2.0: pushed to debug only if debug is later',
        () {
      // 装了正式版 1.2.0（seq 由 versionCode 反解为 7863），debug 通道。
      final int? localSeq =
          currentReleaseSequence(version: '1.2.0', buildNumber: '1000786300');
      expect(localSeq, 7863);
      // 远端 debug.7920 更晚 → 更新（谁后用谁）。
      expect(
        isUpdateVersionNewer('1.2.0-debug.7920', '1.2.0', UpdateChannel.debug,
            localSeq: localSeq),
        isTrue,
        reason: 'debug.7920 比本机正式版 seq 7863 更晚',
      );
      // 若本机正式版 seq 更大（正式版是最后构建，如 8000 > 7920）→ 不回退到 debug。
      expect(
        isUpdateVersionNewer('1.2.0-debug.7920', '1.2.0', UpdateChannel.debug,
            localSeq: 8000),
        isFalse,
        reason: '正式版 seq 8000 比 debug.7920 更晚，绝不回退（消除来回更新）',
      );
    });

    test(
        'debug user on debug.7920: not dragged back to earlier-seq same-base stable',
        () {
      // 装了 debug.7920，远端同基正式版 seq 更早（7800）→ 不推（谁后用谁，禁回退）。
      expect(
        isUpdateVersionNewer('1.2.0', '1.2.0-debug.7920', UpdateChannel.debug,
            remoteSeq: 7800),
        isFalse,
        reason: '同基正式版 seq 7800 比本机 debug.7920 更早，不回退',
      );
      // 正式版更晚（7950 > 7920）→ 推正式版（谁后用谁：正式版是最后构建的）。
      expect(
        isUpdateVersionNewer('1.2.0', '1.2.0-debug.7920', UpdateChannel.debug,
            remoteSeq: 7950),
        isTrue,
        reason: '同基正式版 seq 7950 比 debug.7920 更晚，应升到正式版',
      );
      // 正式版 seq 未知（302 回退拿不到）→ 保守不推，同基绝不 churn。
      expect(
        isUpdateVersionNewer('1.2.0', '1.2.0-debug.7920', UpdateChannel.debug),
        isFalse,
        reason: '正式版 seq 未知时同基保守不推',
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

    test('beta channel receives the finished same-base stable when it is later',
        () {
      // beta 用户在 1.2.0-beta.5，同基正式版 1.2.0 出了。谁后用谁：仅当正式版 seq 更大
      // （构建更晚，如 seq 20 > 5）才领到——正式版一般在 beta 之后收尾。
      expect(
        isUpdateVersionNewer('1.2.0', '1.2.0-beta.5', UpdateChannel.beta,
            remoteSeq: 20),
        isTrue,
        reason: 'beta 用户应领到同基但构建更晚的成品正式版',
      );
      // 正式版 seq 未知（302 无 manifest）→ 同基保守不推（等更高基或 manifest 提供 seq）。
      expect(
        isUpdateVersionNewer('1.2.0', '1.2.0-beta.5', UpdateChannel.beta),
        isFalse,
        reason: '正式版 seq 未知时同基不 churn',
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
        isUpdateVersionNewer('1.2.0', '1.2.0-debug.100', UpdateChannel.debug,
            remoteSeq: 150),
        isTrue,
        reason: 'debug 用户应领到同基但构建更晚(seq 150>100)的正式版',
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

    test('same-base cross-track compares by seq (谁后用谁, BUG-846)', () {
      // 谁后用谁：debug 通道用户装着 beta.100，同基 debug.200 序号更大=构建更晚 → 更新。
      // 合集门保证只有 debug 通道能看到 debug 轨（beta/stable 用户不受影响）。
      expect(
        isUpdateVersionNewer(
          '1.2.0-debug.200',
          '1.2.0-beta.100',
          UpdateChannel.debug,
        ),
        isTrue,
        reason: 'debug.200 比 beta.100 构建更晚',
      );
      // 反向更早不推。
      expect(
        isUpdateVersionNewer(
          '1.2.0-beta.100',
          '1.2.0-debug.200',
          UpdateChannel.debug,
        ),
        isFalse,
        reason: 'beta.100 比 debug.200 更早，不回退',
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

    test('BUG-846 乒乓收敛: debug user on stable 1.2.0 升到更晚的 debug.200', () async {
      // 装了正式版 1.2.0（本机 seq 150 由 currentReleaseSeq 提供），合集含同基 debug.200。
      // 谁后用谁：debug.200 更晚 → 升上去。
      final UpdateReleaseSelection? sel =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _relWithApks('v1.2.0',
              prerelease: false,
              apks: <String>['hibiki-1.2.0-arm64-v8a.apk'],
              releaseSequence: 150),
          _relWithApks('v1.2.0-debug.200+abc1234',
              prerelease: true,
              apks: <String>['hibiki-1.2.0-abc1234-debug.apk'],
              releaseSequence: 200),
        ],
        currentVersion: '1.2.0',
        currentReleaseSeq: 150,
        channel: UpdateChannel.debug,
        updater: arm64Updater(),
      );
      expect(sel?.version, '1.2.0-debug.200');
    });

    test('BUG-846 乒乓收敛: debug user on debug.200 不再被同基更早正式版拉回', () async {
      // 装了 debug.200（本机 seq 200），合集含同基正式版 seq 150（更早）。谁后用谁：不推
      // 任何东西（正式版更早、debug 即本机）→ 收敛，绝不来回更新。
      final UpdateReleaseSelection? sel =
          await selectUpdateReleaseForCurrentPlatform(
        <Map<String, dynamic>>[
          _relWithApks('v1.2.0',
              prerelease: false,
              apks: <String>['hibiki-1.2.0-arm64-v8a.apk'],
              releaseSequence: 150),
          _relWithApks('v1.2.0-debug.200+abc1234',
              prerelease: true,
              apks: <String>['hibiki-1.2.0-abc1234-debug.apk'],
              releaseSequence: 200),
        ],
        currentVersion: '1.2.0-debug.200',
        currentReleaseSeq: 200,
        channel: UpdateChannel.debug,
        updater: arm64Updater(),
      );
      expect(sel, isNull, reason: '已在合集最新（seq 200），不再提示更新');
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
  int? releaseSequence,
}) =>
    <String, dynamic>{
      'tag_name': tag,
      'prerelease': prerelease,
      'draft': false,
      'body': '',
      'html_url': 'https://github.com/hajisensai/hibiki/releases/tag/$tag',
      if (releaseSequence != null) 'releaseSequence': releaseSequence,
      'assets': <Map<String, dynamic>>[
        for (final String name in apks)
          <String, dynamic>{
            'name': name,
            'browser_download_url':
                'https://github.com/hajisensai/hibiki/releases/download/$tag/$name',
          },
      ],
    };
