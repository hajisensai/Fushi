## BUG-1207 · 安卓下载设置能选「内置引擎」并改下载目录，实际静默回退外接 qBittorrent
- **报告**：2026-07-28（用户：PR#526 审查线索）
- **真实性**：✅ 真 bug（静默回退，无任何错误提示）

  安卓上**不存在**内置 torrent 引擎的原生产物，证据链：
  - `packages/hibiki_torrent/pubspec.yaml` 没有 `flutter:`/`plugin:` 段（纯 Dart package，
    Gradle 不会为它做任何 native 构建或收集 jniLibs），包内无 `android/`、无随包二进制。
  - `native/hibiki_torrent/CMakeLists.txt:38-50` 只有 `if(WIN32)` / `if(APPLE)` 分支，
    无 Android ABI；`native/hibiki_torrent/README.md:226-230` 自己写明 Android 是未做项。
  - `hibiki/android/app/build.gradle:103-108` 的 `externalNativeBuild` 只构建 `hoshidicts`，
    `sourceSets` 无 `jniLibs.srcDirs`，`src/main/` 下无 `jniLibs/`。
  - CI 里 `hibiki_torrent` 的构建只出现在 Windows job（`build-multiplatform.yml:743-748`、
    `release-desktop.yml:321-326`）；Android 打包的 `release.yml` / `main.yml` 零命中。
  - 全仓 `git ls-files` 过滤二进制：**零个 `.so`**，零个 `libhibiki_torrent*`。

  **根因** `hibiki/lib/src/media/torrent/anime_download_config.dart:70`（修复前）：
  `resolveBackend({required bool isDesktop})` 只把 `backendAuto` 按平台规约，
  显式的 `backendEmbedded` **一律原样放行**。于是移动端解析出一个不存在的后端：
  - `hibiki/lib/src/media/torrent/embedded_torrent_host.dart:131-138` 把
    `DynamicLibrary.open('libhibiki_torrent_ffi.so')` 抛的 `ArgumentError` 吞掉返回 null（零日志）；
  - `hibiki/lib/src/models/app_model.dart:3459-3475` `_torrentBackendFor` 于是静默造一个
    `QbTorrentBackend`（`baseUrl` 可能为空）——用户以为在用内置引擎，实际走外接 qb；
  - `hibiki/lib/src/pages/implementations/torrent_settings_section.dart:292/347/420`（修复前）
    仍把「内置引擎」段画出来让用户选中，并在 `isEmbedded` 分支暴露**只有内置引擎才读取**的
    下载目录（`download_save_root`）。用户能改，改了完全不被采用 —— 死设置。

- **[x] ① 已修复** — 两处，规约收在数据层、UI 只做渲染门控：
  1. `anime_download_config.dart` `resolveBackend`：不具备内置引擎的平台**恒**返回
     `backendQbittorrent`（含存量显式选过 embedded 的配置）。存储层不动——`backend` 字段
     仍原样存 embedded，桌面上旧配置自动复原，零破坏。
  2. `torrent_settings_section.dart`：非桌面不渲染后端选择器（只剩一个可用档位，
     留着只会「点了弹回」），改为一行说明 `download_backend_desktop_only_note`
     交代本平台只有外接 qb；下载目录随 `isEmbedded` 恒 false 自动消失。
     新增 `desktopOverride` 测试注入口（照 `book_import_dialog.dart:68` 的既有范式，
     `dart:io Platform` 不可 override，不给注入口就只能退回源码扫描守卫）。
  提交：见本 PR 的 `fix(download): gate built-in torrent engine to desktop`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/torrent_settings_android_backend_gating_test.dart`
  （真断言渲染行为，非字符串存在）：非桌面下 `HibikiSegmentedStrip<String>` / 「内置引擎」标签 /
  下载目录标题与按钮**整块 findsNothing**，同时 qb 连接字段与说明文字 findsOneWidget（证明真落到
  qb 分支、不是整段没渲染的假绿）；桌面对照组断言三者原样保留（不误伤）。
  另有 4 条 `resolveBackend` 纯函数用例覆盖 auto/显式 × 两种平台能力。
  既有 `test/media/torrent/anime_download_config_backend_test.dart` 的
  「explicit backends resolve to themselves regardless of platform」是**钉住旧 bug 契约**的
  用例，已按新契约更新并注明变更理由。

  **变异实测**（把修复退回，确认断言真转红）：
  - 仅退回 `resolveBackend` 平台规约 → 转红 **3 条**
  - 仅退回 UI 平台门控 → 转红 **1 条**
  - 两处全退回 → 转红 **3 条**
- **备注**：本次只做 Android/iOS 的「不谎报」门控，未给内置引擎补 Android 产物
  （需 NDK 编 libtorrent，属独立工程，见 `native/hibiki_torrent/README.md` 的「尚未做」）。
  真机复测（Android 下载设置页目视确认无「内置引擎」档位）**未做**，本轮只有 widget 层证据。
