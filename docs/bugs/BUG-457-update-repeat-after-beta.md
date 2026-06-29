## BUG-457 · 已安装 beta 仍重复提示同一测试版更新

- **报告**：2026-06-29（用户：更新到 `1.0.1-beta.6095` 后仍弹出“发现新版本 1.0.1-beta.6095”）
- **真实性**：✅ 真 bug，根因见 `hibiki/lib/src/utils/misc/update_checker_release.dart:56`、`hibiki/lib/src/pages/implementations/home_page.dart:130`、`hibiki/lib/src/settings/settings_schema_system.dart:224`
- **[x] ① 已修复**：`UpdateChecker.scheduleCheck` 新增 `currentBuildNumber`，在 beta/debug 通道里把桌面 `PackageInfo.version=1.0.1` + `buildNumber=6095` 归一化为 `1.0.1-beta.6095`；Android 新版 versionCode 公式 `1000000000 + 100 * releaseSequence + abiOffset` 也会还原成 release sequence。首页自动检查和设置页手动检查均传入 `PackageInfo.buildNumber`。
- **[x] ② 已加自动化测试**：`hibiki/test/utils/misc/version_comparison_test.dart` 覆盖桌面 beta buildNumber 与 Android ABI versionCode 还原，并断言已安装 `1.0.1-beta.6095` 不再提示同一 `1.0.1-beta.6095`。
- **备注**：GitHub Release 与 `update-manifest/latest-beta.json` 本身已是 `v1.0.1-beta.6095` 且资产齐全；问题发生在客户端比较“当前版本”时只传 `PackageInfo.version`，没有带入桌面 beta 的 buildNumber。
