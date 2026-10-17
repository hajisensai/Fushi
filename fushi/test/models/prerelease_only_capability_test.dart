// 正式版构建屏蔽复习（SRS）（用户 2026-10-16 拍板「正式版屏蔽srs一下」）。
//
// 构建通道只经 `--dart-define=FUSHI_BUILD_VERSION=<build-name>` 进 app：
// formal = 裸 `X.Y.Z`、beta = `X.Y.Z-beta.N`、debug = `X.Y.Z-debug.N`，手动发
// GitHub Release 的版本名取自 tag；未注入（本地 / 测试构建）为 null。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/prerelease_only_capability.dart';

void main() {
  group('isFormalReleaseBuildVersion：通道判据', () {
    test('formal 通道的裸版本是正式版', () {
      expect(isFormalReleaseBuildVersion('2.7.0'), isTrue);
      expect(isFormalReleaseBuildVersion('10.0'), isTrue);
    });

    test('beta / debug 预发布不是正式版', () {
      expect(isFormalReleaseBuildVersion('2.7.0-beta.3'), isFalse);
      expect(isFormalReleaseBuildVersion('2.7.0-debug.12215'), isFalse);
    });

    test('github-release 通道按 tag 派生的版本名判：裸版本即正式，带后缀即预发布', () {
      // release.yml：BUILD_VERSION_NAME = ${TAG#v} 再剥 +<sha>。
      expect(isFormalReleaseBuildVersion('2.7.1'), isTrue);
      expect(isFormalReleaseBuildVersion('2.7.1-beta.4'), isFalse);
      // 万一带着构建元数据进来，也与更新器同一口径（先剥 `+...` 再判）。
      expect(isFormalReleaseBuildVersion('2.7.1-debug.9+abc1234'), isFalse);
      expect(isFormalReleaseBuildVersion('2.7.1+42'), isTrue);
    });

    test('未注入版本（本地 flutter run / flutter test）不是正式版', () {
      expect(isFormalReleaseBuildVersion(null), isFalse);
    });
  });

  group('PrereleaseOnlyCapability.srs', () {
    test('正式版缺席，预发布与本地构建都在', () {
      const PrereleaseOnlyCapability srs = PrereleaseOnlyCapability.srs;
      expect(srs.availableFor(buildVersion: '2.7.0'), isFalse);
      expect(srs.availableFor(buildVersion: '2.7.0-beta.3'), isTrue);
      expect(srs.availableFor(buildVersion: '2.7.0-debug.12215'), isTrue);
      expect(srs.availableFor(buildVersion: null), isTrue);
    });

    test('测试进程没有注入 FUSHI_BUILD_VERSION：运行时判据保留复习', () {
      // 若这条红了，说明测试被带 define 跑了，全部 SRS 测试的前提都变了。
      expect(PrereleaseOnlyCapability.srs.isAvailable, isTrue);
    });
  });

  group('模块可用性委托到构建通道判据', () {
    const List<(bool, bool, bool, bool)> platforms = <(bool, bool, bool, bool)>[
      (true, true, false, false), // Windows
      (false, true, false, false), // macOS / Linux
      (false, false, true, false), // iOS
      (false, false, false, true), // Android
    ];

    test('ModuleId.srs 在正式版里五端都不存在，预发布里五端都在', () {
      for (final (bool w, bool d, bool i, bool a) p in platforms) {
        bool on(String define) => ModuleId.srs.availableOn(
          isWindows: p.$1,
          isDesktop: p.$2,
          isIOS: p.$3,
          isAndroid: p.$4,
          buildVersionDefine: define,
        );
        expect(on('2.7.0'), isFalse, reason: 'formal $p');
        expect(on('2.7.0-beta.3'), isTrue, reason: 'beta $p');
        expect(on('2.7.0-debug.12215'), isTrue, reason: 'debug $p');
        expect(on(''), isTrue, reason: '未注入 $p');
      }
    });

    test('构建通道只影响复习：其余模块在正式版与预发布里可用性相同', () {
      for (final (bool w, bool d, bool i, bool a) p in platforms) {
        for (final ModuleId m in ModuleId.values) {
          if (m == ModuleId.srs) continue;
          bool on(String define) => m.availableOn(
            isWindows: p.$1,
            isDesktop: p.$2,
            isIOS: p.$3,
            isAndroid: p.$4,
            buildVersionDefine: define,
          );
          expect(on('2.7.0'), on('2.7.0-beta.3'), reason: '${m.name} $p');
        }
      }
    });

    test('ModuleVisibility：正式版里即使 pref 开着，复习也不在可见集合中', () {
      ModuleVisibility resolve(String define) => ModuleVisibility.resolve(
        prefOf: (ModuleId _) => true,
        isWindows: true,
        isDesktop: true,
        isIOS: false,
        isAndroid: false,
        buildVersionDefine: define,
      );
      final ModuleVisibility formal = resolve('2.7.0');
      expect(formal.isEnabled(ModuleId.srs), isFalse);
      expect(formal.isEnabled(ModuleId.books), isTrue);
      expect(resolve('2.7.0-beta.3').isEnabled(ModuleId.srs), isTrue);
      expect(resolve('2.7.0-debug.12215').isEnabled(ModuleId.srs), isTrue);
      expect(resolve('').isEnabled(ModuleId.srs), isTrue);

      expect(
        ModuleVisibility.all(
          isWindows: false,
          isDesktop: false,
          isIOS: false,
          isAndroid: true,
          buildVersionDefine: '2.7.0',
        ).isEnabled(ModuleId.srs),
        isFalse,
      );
      expect(
        formal.enabled,
        resolve('2.7.0-beta.3').enabled.difference(<ModuleId>{ModuleId.srs}),
        reason: '正式版与预发布的可见集合只差复习。',
      );
    });

    test('正式版里复习的出厂默认与持久化键不变（只是不可用，用户数据不动）', () {
      // 出厂默认自 2026-10-16 起为开（ModuleId.srs 文档：「默认就是 fushi srs」，老用户
      // 由一次性判定显式写关）；正式版屏蔽只经 availableOn，不改这里。
      expect(ModuleId.srs.defaultEnabled, isTrue);
      expect(ModuleId.srs.prefKey, 'module_srs_enabled');
    });
  });
}
