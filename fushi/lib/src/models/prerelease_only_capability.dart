/// 只在**预发布构建**（debug / beta 通道，以及本地 / 测试构建）里提供、**正式版**
/// 构建里整体缺席的能力，以及它们的唯一构建通道判据。
///
/// 与 `StoreRestrictedCapability` 同一种形状、正交的另一条边界：那边按「平台是否
/// 走 App Store」判，这边按「这份二进制是哪个发布通道出的」判。复习（SRS）2026-10-16
/// 由所有者拍板「正式版屏蔽」——功能仍在迭代，只给预发布通道的用户用。
///
/// 判据只在本文件写一次的理由与合规边界相同：「是不是正式版」一旦散成各消费端各自
/// 解析版本串，漏掉的那一处就会让正式版静默露出入口（本地 `flutter run` /
/// `flutter test` 全都没注入版本，任何一处漏判在本机和 CI 上都看不出来）。消费端
/// 一律经 `ModuleId.availableOn` → `ModuleVisibility` 问这里，不自己读
/// `FUSHI_BUILD_VERSION`（守卫 `test/build/prerelease_only_capability_guard_test.dart`）。
///
/// **通道从哪来**：发布通道本身不进 app，唯一的构建期注入是
/// `--dart-define=FUSHI_BUILD_VERSION=<build-name>`（`release.yml` /
/// `release-desktop.yml`）：formal 为裸 `X.Y.Z`，beta 为 `X.Y.Z-beta.N`，debug 为
/// `X.Y.Z-debug.N`；手动发 GitHub Release（`CHANNEL=github-release`）的版本名取自
/// tag——裸版本 tag 即正式版，带 `-beta.N` / `-debug.N` 即预发布。通道归属复用更新器
/// 的同一套判据 [channelForUpdateVersion]（反馈修复进度判「本机属于哪个通道」用的也是
/// 它），不另造正则：两者若各判各的，就会出现「更新器认为本机是正式版、复习却还在」
/// 这类分叉。
///
/// **未注入（`null`）一律当预发布**：本地 `flutter run`、`flutter test` 与注入这条
/// define 之前的历史包都没有版本证据。把「未知」当正式版会让开发者本机与全部现有
/// 测试里的复习消失，而正式版发布路径恒注入版本——安全方向是保留。
library;

import 'package:fushi/src/utils/misc/build_version.dart';
import 'package:fushi/src/utils/misc/platform_updater.dart' show UpdateChannel;
import 'package:fushi/src/utils/misc/update_checker.dart'
    show channelForUpdateVersion;

/// [buildVersion]（运行中代码的完整 build-name，见 `fushiRunningCodeVersion`）是否
/// 来自**正式版**发布通道。
///
/// `null` = 没有版本证据（本地 / 测试构建）→ 不是正式版。
bool isFormalReleaseBuildVersion(String? buildVersion) =>
    buildVersion != null &&
    channelForUpdateVersion(buildVersion) == UpdateChannel.stable;

/// 一类只在预发布构建里提供的能力。
enum PrereleaseOnlyCapability {
  /// Fushi 内置复习（SRS，`ModuleId.srs`）：牌组、复习、笔记编辑与浏览，连同它在
  /// 底栏 / 设置开关 / 引导 / 查词设置 / 制卡目标 / 本机 API 上的全部入口（都经
  /// 模块可见性收口）。正式版里用户已有的复习数据**不删**、备份类别与表不动，只是
  /// 模块不可用——换装预发布版即原样回来。
  srs;

  /// 本能力在 [buildVersion] 这份构建里**是否存在**（与用户意愿无关）。纯函数，
  /// 测试显式注入版本串断言各通道的结论。
  ///
  /// 各值当前判据相同，仍逐个走枚举：将来某一项转正（正式版也提供）时，改动面
  /// 是这里的一行，而不是把一个共享布尔拆开。
  bool availableFor({required String? buildVersion}) => switch (this) {
    PrereleaseOnlyCapability.srs => !isFormalReleaseBuildVersion(buildVersion),
  };

  /// 运行中这份构建上的判据。
  bool get isAvailable => availableFor(buildVersion: fushiRunningCodeVersion);
}
