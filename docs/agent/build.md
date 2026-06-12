# 构建与依赖补丁

> [CLAUDE.md](../../CLAUDE.md) 的子文档。构建上手见 [README.md](../../README.md)；这里只补 agent 关心的增量。

## 平台与 SDK

5 平台均出包：Android / iOS / macOS / Windows / Linux（Android 走 Material 3，iOS 走 Cupertino，桌面端复用 Material；桌面 EPUB 渲染靠 fork 的 `flutter_inappwebview_windows`，Linux 阅读器能力受限）。Android：`compileSdk 36` / `minSdkVersion 24` / `targetSdk 35`。

## Melos

仓库根是 Melos workspace（`hibiki_workspace`）。常用：`melos run analyze` / `melos run test` / `melos run build:android`。

## 准备 + 构建

`tool/bootstrap.sh`（Windows：`.\tool\bootstrap.ps1`）一条命令完成：`flutter pub get` → `ci/apply-patches.sh`。`melos bootstrap` 经 post hook 做同样两步。然后：

```bash
cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

> Google Drive 同步的 OAuth 凭据已写死进源码默认值（`lib/src/sync/google_drive_auth.dart`），构建无需再传 `--dart-define`。如需换凭据，改该文件的 `defaultValue` 或自行加 `--dart-define` 覆盖。

## 发布通道

默认 push 只发 debug 通道；beta/test 和 formal 都必须手动触发。任何 push 触发的 GitHub Release 都必须是 prerelease 且 `make_latest: false`，不得创建或更新 Latest/正式 release。

- debug（push 自动）：`main` / `develop` push 会走 `.github/workflows/main.yml` 上传 Actions artifact，并走 `.github/workflows/release.yml` 发布 debug GitHub prerelease。Artifact 名称为 `hibiki-debug-apk-${{ github.sha }}`，APK 文件名为 `hibiki-<version>-<short-sha>-debug.apk`，保留 14 天。debug GitHub Release 默认 tag 为 `debug-<short-sha>`，只上传 debug APK，必须是 prerelease / non-Latest。
- beta/test（手动）：通过 `.github/workflows/release.yml` 或 `.github/workflows/release-desktop.yml` 的 `workflow_dispatch` 选择 `beta`，或手动发布一个勾选 prerelease 且非 Latest 的 GitHub Release。Android 默认 tag 为 `v<version>-beta.<run>`，产物包含 `hibiki-<version>-<short-sha>-debug.apk` 与 split ABI release APK `hibiki-<version>-<abi>.apk`；Windows 产物为 `hibiki-<version>-windows-setup.exe`。如需 Android 和 Windows 合并到同一 beta/test Release，两个手动 workflow 使用同一个 `tag_name`。
- formal（手动）：通过手动 GitHub Release 或 `workflow_dispatch` 选择 `formal`。默认 tag 为 `v<version>`；Android 产物包含 debug APK 与 split ABI release APK，Windows 产物为 installer。formal 是唯一允许成为 Latest 的通道。
- 禁止事项：不要把 push、debug tag、debug APK 或 beta/test workflow 接到 formal/Latest；不要让 push 上传正式 release APK 或发布 formal/Latest；不要把 beta/test 发布成 non-prerelease 或 Latest。

## 版本号与 build number

Flutter 版本号以 `hibiki/pubspec.yaml` 的 `version: X.Y.Z+build` 为准。准备 push 前先判断本轮改动是否影响用户可安装/可分发产物：

- 大模块、大功能、用户可见的大改：升 minor 并重置 patch，例如 `0.5.0+33` -> `0.6.0+34`。
- 小模块、小功能、修复：升 patch，例如 `0.5.0+33` -> `0.5.1+34`。
- 每次语义版本 `X.Y.Z` 变化时，`+build` 同步 +1，保证 Android `versionCode` 单调递增。
- 纯文档、PM 元数据、不影响分发行为的 CI 维护不强制 bump；发布、安装包或运行行为变化应 bump。

## 依赖补丁

Flutter 3.44.0 下部分上游依赖未适配，两种补法并存（对个别包**有重叠**）：

- **vendored**：`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`（在 `third_party/`）与 `flutter_inappwebview_windows` / `gamepads_android_stub`（在 `packages/`），经 `dependency_overrides` 的 `path:` 从仓库内解析。`third_party/` 的 fork 必须整包入库（`.gitignore` 用 `!third_party/**/*.xml` 豁免 res/manifest）；新增时把其 pubspec 的 SDK 上界 bump 到 `<4.0.0`。
- **pub-cache 补丁**：`ci/apply-patches.sh` 把 `ci/patches/{hosted,git}/<包-版本>/` 覆盖到 pub cache，按精确版本号命名；版本漂移就跳过并警告（HBK-AUDIT-005）。每次清 cache 或 `pub get` 后要重跑（bootstrap 已含）。

> `carousel_slider` / `fading_edge_scrollview` / `network_to_file_image` 两边都有：`dependency_overrides` 生效，pub-cache 同名补丁因版本对不上被自动跳过，以 vendored 为准。
