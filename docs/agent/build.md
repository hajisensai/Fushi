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

### TODO-207 release channel invariants

客户端按 stable / beta / debug 三个通道过滤 GitHub Release。stable 只看正式 Latest；beta/debug 扫描最近 releases，但只接受 tag 形如 `v<version>-beta.<seq>` / `v<version>-debug.<seq>+<short-sha>` 且 `prerelease=true` 的 release。旧的 `debug-<sha>` tag 不可比较，客户端会忽略。

debug 通道发布的是 release-signed debug-channel APK：文件名保留 `-debug.apk` 供客户端过滤，APK 使用 release keystore、写入 `versionName=<version>-debug.<seq>` 和单调 `versionCode`（公式见下「版本号与 build number」），用于覆盖正式签名包并让同一平台后续 debug/beta/formal release 仍可比较。debug push 仍必须是 prerelease / non-Latest，绝不能创建或更新 formal / Latest。

Android / Windows debug/beta workflow 必须使用跨 workflow 统一 release 序列（cross-workflow release sequence）：两条发布 workflow 都用完整历史 checkout 后的 `git rev-list --count HEAD` 生成 `<seq>`，不得用各自独立的 `github.run_number` / `GITHUB_RUN_NUMBER` 生成 tag、安装包版本或 Android `versionCode` 扩展位。Android `versionCode = versionCodeBase(1_000_000_000) + 100 × <seq> + abiOffset`（公式在 `hibiki/android/app/build.gradle`，CI 只把 `<seq>` 当 `--build-number` 传入），不再用旧的 `PUBSPEC_BUILD × 1_000_000 + seq` build number——那个数会把 versionCode 顶到约 66 亿，溢出 int32 且超 Android 21 亿上限，beta/release 的 Android 包根本建不出来（TODO-414）。同一 commit / 同一语义版本的自动 debug 默认 tag 必须相同，并通过同一个 concurrency group 串行上传资产，合并到同一个 GitHub Release（single GitHub Release）。客户端自装平台必须先按本平台 asset 过滤 release：Android 只接受匹配通道的 APK，Windows 只接受匹配通道的 `-windows-setup.exe`；如果远端只有错平台新版本，Android/Windows 返回无更新而不是打开 release 页。Unsupported 平台仍可在没有本平台自装 asset 时打开 release 页。若手动 Android / Windows workflow 指定 `tag_name`，也应使用同一个 tag 合并到同一个 Release，由各平台客户端选择自己的 asset。

> Google Drive 同步的 OAuth 凭据已写死进源码默认值（`lib/src/sync/google_drive_auth.dart`），构建无需再传 `--dart-define`。如需换凭据，改该文件的 `defaultValue` 或自行加 `--dart-define` 覆盖。

## 发布通道

默认 push 只发 debug 通道；beta/test 和 formal 都必须手动触发。任何 push 触发的 GitHub Release 都必须是 prerelease 且 `make_latest: false`，不得创建或更新 Latest/正式 release。

- debug（push 自动）：`main` / `develop` push 会走 `.github/workflows/main.yml` 上传 Actions artifact，并走 `.github/workflows/release.yml` 发布 Android debug GitHub prerelease；同时走 `.github/workflows/release-desktop.yml` 发布 Windows debug installer GitHub prerelease。Artifact 名称为 `hibiki-debug-apk-${{ github.sha }}`，Actions artifact APK 文件名为 `hibiki-<version>-<short-sha>-debug.apk`，保留 14 天；Android debug GitHub Release 使用 release-signed debug-channel APK，文件名为 `hibiki-<version>-debug.<seq>-<short-sha>-debug.apk`；Windows debug GitHub Release 使用 Inno Setup installer，文件名为 `hibiki-<version>-debug.<seq>-windows-setup.exe`，并用同一个 `0.x.y-debug.<seq>` 作为 `flutter build windows --build-name`，保证安装后的 `PackageInfo.version` 能停止同一 debug release 的重复提示/自动安装。默认 tag 为 `v<version>-debug.<seq>+<short-sha>`，同一 commit 的 Android/Windows 自动 debug 必须落到同一个 GitHub Release，且必须是 prerelease / non-Latest；Windows 客户端 debug 通道只认带 `-debug.` 的 `-windows-setup.exe`，Android 客户端只认 APK，不能互相吃错平台资产，也不能等 beta/test 或 formal installer。Windows desktop push debug 还依赖最近一次未过期的 `ffmpeg-min-windows-x64` artifact；缺失时 `.github/workflows/release-desktop.yml` 会失败，需要先手动运行 `ffmpeg-min.yml`，或在手动 desktop release 时传 `ffmpeg_min_run_id`。
- beta/test（手动）：通过 `.github/workflows/release.yml` 或 `.github/workflows/release-desktop.yml` 的 `workflow_dispatch` 选择 `beta`，或手动发布一个勾选 prerelease 且非 Latest 的 GitHub Release。Android 默认 tag 为 `v<version>-beta.<seq>`，产物包含 `hibiki-<version>-<short-sha>-debug.apk` 与 split ABI release APK `hibiki-<version>-<abi>.apk`；Windows 产物为 `hibiki-<version>-windows-setup.exe`。如需 Android 和 Windows 合并到同一 beta/test Release，两个手动 workflow 使用同一个 `tag_name`；未指定时，同一 commit 上两条 workflow 的默认 `<seq>` 相同，也会合并到同一 Release。
- formal（手动）：通过手动 GitHub Release 或 `workflow_dispatch` 选择 `formal`。默认 tag 为 `v<version>`；Android 产物包含 debug APK 与 split ABI release APK，Windows 产物为 installer。formal 是唯一允许成为 Latest 的通道。
- 禁止事项：不要把 push、debug tag、debug APK 或 beta/test workflow 接到 formal/Latest；不要让 push 上传正式 release APK 或发布 formal/Latest；不要把 beta/test 发布成 non-prerelease 或 Latest。

## 版本号与 build number

Flutter 版本号以 `hibiki/pubspec.yaml` 的 `version: X.Y.Z+build` 为准。准备 push 前先判断本轮改动是否影响用户可安装/可分发产物：

- **`+build`（build number）= 发布序号**：每次出包 / 发布单调 +1，**与语义版本是否变无关**——同一个 `X.Y.Z` 可连续 `+150`、`+151`…（实践即如此：多数发布只 +build、不动 `X.Y.Z`）。它仅做日志 / 可读版本标识，不进 Android `versionCode`。
- **语义版本 `X.Y.Z` 按里程碑升，不是每次发布都升**：
  - 一批功能完成 / 大模块 / 用户可见大改：升 minor 并重置 patch（如 `0.9.29` -> `0.10.0`）。
  - 一批修复 / 小功能阶段性收口：升 patch（如 `0.10.0` -> `0.10.1`）。
  - 单个零散 commit 通常**只 +build**；攒到一批 / 里程碑再升 `X.Y.Z`（届时 `+build` 也照常 +1）。
- Android `versionCode` 的单调递增由 CI 的 `git rev-list --count HEAD`（每个 commit +1）经 `--build-number` 喂给 `build.gradle` 的 `versionCodeBase + 100 × <seq> + abiOffset` 保证；`build.gradle` 还带 2.1e9 上限断言，越界即 fail-fast（TODO-414）。**不依赖 pubspec `+build`**。
- 纯文档、PM 元数据、不影响分发行为的 CI 维护不强制 bump；发布、安装包或运行行为变化应 bump。
- 发布 workflow 修改后必须运行 `tool/check_release_policy.ps1`（Windows：`powershell -NoProfile -ExecutionPolicy Bypass -File tool/check_release_policy.ps1`；GitHub Actions 用 `pwsh`）。该守卫会拒绝重新引入 workflow-local run number、缺失完整历史 checkout、缺失同 tag/commit 发布并发锁，或文档缺少 cross-workflow release sequence / single GitHub Release 规则。

## 依赖补丁

Flutter 3.44.0 下部分上游依赖未适配，两种补法并存（对个别包**有重叠**）：

- **vendored**：`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`（在 `third_party/`）与 `flutter_inappwebview_windows` / `gamepads_android_stub`（在 `packages/`），经 `dependency_overrides` 的 `path:` 从仓库内解析。`third_party/` 的 fork 必须整包入库（`.gitignore` 用 `!third_party/**/*.xml` 豁免 res/manifest）；新增时把其 pubspec 的 SDK 上界 bump 到 `<4.0.0`。
- **pub-cache 补丁**：`ci/apply-patches.sh` 把 `ci/patches/{hosted,git}/<包-版本>/` 覆盖到 pub cache，按精确版本号命名；版本漂移就跳过并警告（HBK-AUDIT-005）。每次清 cache 或 `pub get` 后要重跑（bootstrap 已含）。

> `carousel_slider` / `fading_edge_scrollview` / `network_to_file_image` 两边都有：`dependency_overrides` 生效，pub-cache 同名补丁因版本对不上被自动跳过，以 vendored 为准。
