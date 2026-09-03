## BUG-1663 · iOS「检查更新」把 TestFlight 用户送到 GitHub 未签名 ipa
- **报告**：2026-08-15（用户：shishamo）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/utils/misc/platform_updater.dart:385`（`IosUpdater`
  的 `selectAsset` 恒 null）+ `fushi/lib/src/utils/misc/update_checker_release.dart:369`
  （无 asset → 一律 `_showFallbackDialog(..., json['html_url'])`）。iOS 的分发链路有三条且
  互不相干——App Store（将来）、TestFlight（`upload_testflight` 的 beta/formal 构建）、
  GitHub Release 里那个**未签名**的 `fushi-<v>-ios.ipa`（AltStore / Sideloadly 侧载）——
  代码里一条都没建模，所有 iOS 用户被无差别送到 GitHub 发布页。对 TestFlight 用户来说那
  页上的 ipa 装不上（签名不同），而他们真正的更新源 TestFlight 从没被提过。
- **[x] ① 已修复** — 按**安装来源**分流，而不是按更新通道猜（通道猜法会把 stable 通道的
  侧载用户误送进 TestFlight）。安装来源是系统写的事实：App Store 装的有 `receipt`、
  TestFlight 装的有 `sandboxReceipt`、侧载/自签的收据文件根本不存在。
  - native：`fushi/ios/Runner/AppDelegate.swift` 在既有 `app.fushi.reader/update` 通道上加
    `getInstallSource`（必须查 `fileExists`——`appStoreReceiptURL` 对侧载包也返回路径，
    只看文件名会把侧载误判成 TestFlight）。
  - Dart：新增 `fushi/lib/src/utils/misc/update_landing.dart`（`IosInstallSource` /
    `UpdateLanding` / 纯函数 `iosUpdateLanding`），`PlatformUpdater.resolveDownloadLanding`
    做平台方法、`IosUpdater` 覆写，`_showFallbackDialog` 按落地种类给文案。
  - 侧载用户的路没被掐掉：主按钮指向商店时对话框额外给「发布页」次要入口。
  - `Info.plist` 登记 `itms-beta` / `itms-apps`，否则 url_launcher 的可用性探测一律判 false。
  - 上架 App Store 后只需填 `kIosAppStoreAppId`，逻辑不用改（未填时回退发布页，不造 id 死链）。
- **[x] ② 已加自动化测试** — `fushi/test/utils/misc/ios_update_landing_test.dart`（12 例）：
  三种安装来源 → 落地入口的纯函数映射、未知值 fail-safe 回发布页、非 iOS 平台不被误伤、
  以及 native 契约源码守卫（`getInstallSource` / `sandboxReceipt` / `fileExists` /
  `Info.plist` 的两个 scheme）。守卫已做变异实测：抽掉 `fileExists` 判据、抽掉
  `itms-beta` 登记，两次都真红，还原后 sha256 与变异前一致。
- **备注**：真机验证（TestFlight 装一版点「检查更新」看是否跳 TestFlight）未做——需要一次
  手动 `workflow_dispatch` 的 beta 发版且等 App Store Connect 处理。收据判据本身是 OS 行为，
  跑不了单测，所以守的是契约。
