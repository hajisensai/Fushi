# 构建与依赖补丁

> [CLAUDE.md](../../CLAUDE.md) 的子文档。构建上手见 [README.md](../../README.md)；这里只补 agent 关心的增量。

## 平台与 SDK

5 平台均出包：Android / iOS / macOS / Windows / Linux（`auto` 下五个平台统一走 Material 3；Cupertino / macOS renderer 仅保留为隐藏内部能力；桌面 EPUB 渲染靠 fork 的 `flutter_inappwebview_windows`，Linux 阅读器能力受限）。Android：`compileSdk 36` / `minSdkVersion 24` / `targetSdk 35`。

## Melos

仓库根是 Melos workspace（`hibiki_workspace`）。常用：`melos run analyze` / `melos run test` / `melos run build:android`。

## 准备 + 构建

`tool/bootstrap.sh`（Windows：`.\tool\bootstrap.ps1`）一条命令完成：`flutter pub get` → `ci/apply-patches.sh`。`melos bootstrap` 经 post hook 做同样两步。然后：

> **代理**：`pub get` 只认继承来的 `HTTPS_PROXY`/`HTTP_PROXY`，而 agent 每次工具调用都是新 shell —— 上一条命令里设的代理不会留到下一条，这是「`setup_worktree.ps1` 首跑 socket error、带代理重跑就过」的根因。`bootstrap.ps1` 按 `调用方环境变量 > HIBIKI_BOOTSTRAP_PROXY > <主 checkout>/tool/bootstrap.local.env`（gitignore，本机私有，一次配好所有 worktree 通用）取代理，三者都没有也照常直连跑（CI 不受影响），只是会先探一次 pub.dev 并在不通时把配法打在前面——**探测只示警不拦路**（实测单次探测会误报：探测 10s 超时失败的同一时刻，`pub get` 自带重试仍 45s 跑通），真判死刑交给 `pub get` 自己，失败时把同一份配法作为报错抛出。代理地址绝不写进入库脚本。

```bash
cd hibiki
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

### TODO-207 release channel invariants

客户端按 stable / beta / debug 三个通道过滤 GitHub Release。stable 只看正式 Latest；beta/debug 扫描最近 releases，但只接受 tag 形如 `v<version>-beta.<seq>` / `v<version>-debug.<seq>+<short-sha>` 且 `prerelease=true` 的 release。旧的 `debug-<sha>` tag 不可比较，客户端会忽略。

debug 通道发布的是 release-signed debug-channel APK：文件名保留 `-debug.apk` 供客户端过滤，APK 使用 release keystore、写入 `versionName=<version>-debug.<seq>` 和单调 `versionCode`（公式见下「版本号与 build number」），用于覆盖正式签名包并让同一平台后续 debug/beta/formal release 仍可比较。debug push 仍必须是 prerelease / non-Latest，绝不能创建或更新 formal / Latest。

**滚动 debug release（TODO-1049）**：debug 通道**不再**每次 push 新建一个 `v<version>-debug.<seq>+<short-sha>` GitHub Release——否则 debug 高频构建会在 Releases 列表无限堆积、淹没正式/beta 条目（用户明确诉求：调试版不该占 Release 位）。改为所有 debug 构建复用**同一个固定滚动 tag `debug-rolling`**（`steps.channel.outputs.publish_tag`），列表里 debug 永远只有 1 条。关键不变式：GitHub Release 的 git tag（`publish_tag=debug-rolling`）与「客户端版本比较用的版本化 tag」（`steps.channel.outputs.tag = v<version>-debug.<seq>+<short-sha>`）**解耦**——manifest `latest-debug.json` 的 `tag` 字段仍写版本化 tag（客户端据 `<seq>` 单调判断「有无更新」，逻辑零改动），而资产下载 URL 走 `releases/download/debug-rolling/<name>`（`publish_update_manifest.sh` 的 `DOWNLOAD_TAG`）。softprops 只 upsert 同名 asset、不删旧 commit 的 asset，故发布前有一步按当前 `versionName` token 清理滚动 release 上非本 seq 的陈旧资产（同 commit 的 Android+desktop 共享 seq、互不误删；新 commit 清旧 commit）。`release.yml` 里另有一步 GC 掉历史遗留的版本化 debug prerelease（tag 形如 `v...-debug.<seq>+`，不含滚动 tag），把列表收敛到单条。beta/formal 不受影响：其 release 就是版本化 tag 本身，`publish_tag == tag`。

Android / Windows / macOS / iOS debug/beta workflow 必须使用跨 workflow 统一 release 序列（cross-workflow release sequence）：发布 workflow 都用完整历史 checkout 后的 `git rev-list --count HEAD` 生成 `<seq>`，不得用各自独立的 `github.run_number` / `GITHUB_RUN_NUMBER` 生成 tag、安装包版本或 Android `versionCode` 扩展位。Android `versionCode = versionCodeBase(1_000_000_000) + 100 × <seq> + abiOffset`（公式在 `hibiki/android/app/build.gradle`，CI 只把 `<seq>` 当 `--build-number` 传入），不再用旧的 `PUBSPEC_BUILD × 1_000_000 + seq` build number——那个数会把 versionCode 顶到约 66 亿，溢出 int32 且超 Android 21 亿上限，beta/release 的 Android 包根本建不出来（TODO-414）。同一 commit / 同一语义版本的自动 debug 默认 tag 必须相同，并通过同一个 concurrency group 串行上传资产，合并到同一个 GitHub Release（single GitHub Release）。客户端自装平台必须先按本平台 asset 过滤 release：Android 只接受匹配通道的 APK，Windows 只接受匹配通道的 `-windows-setup.exe`，macOS 只接受 `-macos.zip`；如果远端只有错平台新版本，Android/Windows/macOS 返回无更新而不是打开 release 页。iOS 发布 no-codesign `.ipa` 只作为 GitHub 下载产物，不做应用内自动安装。Unsupported 平台仍可在没有本平台自装 asset 时打开 release 页。若手动 Android / desktop/Apple workflow 指定 `tag_name`，也应使用同一个 tag 合并到同一个 Release，由各平台客户端选择自己的 asset。

> Google Drive 同步的 OAuth 凭据已写死进源码默认值（`lib/src/sync/google_drive_auth.dart`），构建无需再传 `--dart-define`。如需换凭据，改该文件的 `defaultValue` 或自行加 `--dart-define` 覆盖。

## 发布通道

默认 push 只发 debug 通道；beta/test 和 formal 都必须手动触发。任何 push 触发的 GitHub Release 都必须是 prerelease 且 `make_latest: false`，不得创建或更新 Latest/正式 release。

- debug（push 自动）：`main` / `develop` push 会走 `.github/workflows/main.yml` 上传 Actions artifact，并走 `.github/workflows/release.yml` 发布 Android debug GitHub prerelease；同时走 `.github/workflows/release-desktop.yml` 发布 Windows debug installer、macOS app zip、iOS no-codesign IPA。Artifact 名称为 `hibiki-debug-apk-${{ github.sha }}`，Actions artifact APK 文件名为 `hibiki-<version>-<short-sha>-debug.apk`，保留 14 天；Android debug GitHub Release 使用 release-signed debug-channel APK，文件名为 `hibiki-<version>-debug.<seq>-<short-sha>-debug.apk`；Windows debug GitHub Release 使用 Inno Setup installer，文件名为 `hibiki-<version>-debug.<seq>-windows-setup.exe`；macOS 为 `hibiki-<version>-debug.<seq>-macos.zip`；iOS 为 `hibiki-<version>-debug.<seq>-ios.ipa`。Windows/macOS/iOS 都用同一个 `0.x.y-debug.<seq>` 作为 Flutter `--build-name`，保证安装后的 `PackageInfo.version` 能停止同一 debug release 的重复提示/自动安装。GitHub Release 的 git tag 固定为滚动的 `debug-rolling`（TODO-1049，见上「滚动 debug release」）；客户端版本比较用的版本化 tag 仍为 `v<version>-debug.<seq>+<short-sha>`（写进 manifest `tag` 字段）。同一 commit 的 Android/Windows/macOS/iOS 自动 debug 必须落到同一个 GitHub Release（即同一个 `debug-rolling` 滚动 release），且必须是 prerelease / non-Latest；各客户端必须按本平台资产后缀过滤，不能互相吃错平台资产，也不能等 beta/test 或 formal installer。
- beta/test（手动）：通过 `.github/workflows/release.yml` 或 `.github/workflows/release-desktop.yml` 的 `workflow_dispatch` 选择 `beta`，或手动发布一个勾选 prerelease 且非 Latest 的 GitHub Release。Android 默认 tag 为 `v<version>-beta.<seq>`，产物包含 `hibiki-<version>-<short-sha>-debug.apk` 与 split ABI release APK `hibiki-<version>-<abi>.apk`；Windows 产物为 `hibiki-<version>-windows-setup.exe`；macOS 产物为 `hibiki-<version>-macos.zip`；iOS 产物为 `hibiki-<version>-ios.ipa`。如需 Android、Windows、macOS、iOS 合并到同一 beta/test Release，两个手动 workflow 使用同一个 `tag_name`；未指定时，同一 commit 上两条 workflow 的默认 `<seq>` 相同，也会合并到同一 Release。
- formal（手动）：通过手动 GitHub Release 或 `workflow_dispatch` 选择 `formal`。默认 tag 为 `v<version>`；Android 产物包含 debug APK 与 split ABI release APK，Windows 产物为 installer，macOS 为 app zip，iOS 为 no-codesign IPA。formal 是唯一允许成为 Latest 的通道。
- 禁止事项：不要把 push、debug tag、debug APK 或 beta/test workflow 接到 formal/Latest；不要让 push 上传正式 release APK 或发布 formal/Latest；不要把 beta/test 发布成 non-prerelease 或 Latest。

### 快速发版（跳测试）

手动发版嫌慢时用「快速编译」路径：`release.yml`（Android）的 `workflow_dispatch` 带 `skip_tests` 输入，**默认 `true`**——手动 dispatch（debug/beta/formal 任意通道）默认跳过 `flutter analyze` + 主 app 单元测试 + 5 个 package 测试，直接进编译+发布。`release build` 步骤本身仍会挡住硬编译失败，发版前的真机验证仍按 [CLAUDE.md](../../CLAUDE.md) 走。约束：
- `skip_tests` **只在 `workflow_dispatch` 生效**；`push`（自动 debug）与 `release`（手动 GitHub Release）事件的 `github.event.inputs.skip_tests` 为空，恒跑完整测试门——`main`/`develop` 的持续测试信号不被削弱，慢的只让手动、你在等的那次发版跳过。
- 想手动发版也跑测试：dispatch 时把 `skip_tests` 取消勾选（设为 `false`）。
- `release-desktop.yml`（Win/mac/iOS）本就无测试步骤，天生快，无需该开关。
- 平台并行：Android（`release.yml`）与桌面（`release-desktop.yml`）是两条独立 workflow，同时 dispatch 即并行；桌面内部 `apple needs: windows` 是**故意串行**，避免两 job 抢同一 release 上传，勿改。

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

## CI 缓存配额（TODO-2721）

GitHub Actions 给每个仓库的缓存配额是**硬上限 10 GB**，超了就按 LRU 静默驱逐。
驱逐不是洁癖问题：桌面发布 run `30729229450` 变红的最后一环就是 vcpkg 缓存被驱逐
后冷编 + 拉外部镜像失败。2026-08-02 实测 `gh api
repos/hajisensai/hibiki/actions/cache/usage` = **10.65 GB / 14 条**，长期在驱逐。

三条铁律（守卫 `hibiki/test/build/workflow_cache_quota_guard_test.dart`）：

1. **pub cache 只准存一份，由 `subosito/flutter-action@v2` 存。**
   它的 `cache: true` 不只缓存 Flutter SDK，还会额外挂一个
   `Cache pub dependencies` 步骤把 `~/.pub-cache`（Windows 是
   `%LOCALAPPDATA%\Pub\Cache`）存成
   `flutter-pub-<os>-<channel>-<ver>-<arch>-<pubspec.lock hash>`。
   workflow 里再挂 `actions/cache` 存同一个目录只是换个 key 名存第二遍：实测
   `flutter-pub-linux-…-3fa29c49` = 149,357,387 B 与
   `Linux-pubcache-3fa29c49` = 149,365,205 B，同一批字节，三平台白占 447 MB，
   每个作业还要多解压一次（6~32 s）。**不要再加 `Cache pub packages` 步骤。**
   代价说清楚：flutter-action 那条 pub 缓存**没有 `restore-keys`**（实测其
   `actions/cache@v5` 输入里只有 `key`），所以 `pubspec.lock` 一变就是全冷，
   `flutter pub get` 要重下约 150 MB；旧的 `<OS>-pubcache-` 前缀能给个部分命中。
   这是有意取舍：换来的是 447 MB 永久配额 + 每作业少一次解压，而 lockfile 变更
   本来就不频繁，且那时重新解析依赖并不亏。
2. **Gradle 缓存三处必须逐字相同，且缓存步骤排在改 `*.gradle` 的 sed 前面。**
   `hashFiles()` 算的是**当时磁盘上**的内容。`main.yml` / `release.yml` 原先在缓存
   步骤之前就 `sed -i` 删掉了 `build.gradle` / `settings.gradle` 里的 aliyun 镜像行，
   而 `build-multiplatform.yml` 的同名 sed 在缓存步骤之后 —— 于是同一份内容被存成
   两条 key：`Linux-gradle-6facc6ed…`(2,901,298,096 B) 与
   `Linux-gradle-5709404c…`(2,901,388,049 B)，差 89,953 B，白占 2.7 GB。
3. **Gradle 只缓存下载物，不缓存派生产物。**
   `~/.gradle/caches` 全量含 `<ver>/transforms`（解包 AAR / jetify / desugar 输出），
   本机实测 5,073.7 MB，是 `modules-2`(1,937.2 MB) 的 2.6 倍，而它能从 modules-2
   重算。只列 `~/.gradle/caches/modules-2` + `~/.gradle/caches/journal-1` +
   `~/.gradle/wrapper/dists`。key 前缀带 `-v2-` 是为了让 `restore-keys` 够不到旧的
   胖缓存（否则每次先白拉 2.7 GB）。

另外：GitHub 缓存**按 ref 分桶**，`refs/pull/<N>/merge` 与 `refs/heads/develop` 上
同 key 是两条独立记录。正常 PR run 会命中 base 分支的缓存不新存，但仓库一旦超配额、
develop 那条被驱逐，下一个 PR run 就 miss 并在自己的 PR 桶里存一份 —— 越紧越复制，
是正反馈。`.github/workflows/cache-cleanup.yml` 在 PR 关闭时立刻删掉该 PR 桶
（GitHub 自己要等 7 天无访问才回收），并把当前用量写进 step summary。

查用量与逐条明细：

```bash
gh api repos/hajisensai/hibiki/actions/cache/usage
gh api "repos/hajisensai/hibiki/actions/caches?per_page=100"   --jq '.actions_caches[] | "\(.size_in_bytes) \(.ref) \(.key)"' | sort -rn
```

删存量缓存前先确认没有 in-flight 的 run 在用它（`gh run list --status in_progress`）。

## 依赖补丁

Flutter 3.44.0 下部分上游依赖未适配，两种补法并存（对个别包**有重叠**）：

- **vendored**：`network_to_file_image` / `carousel_slider` / `fading_edge_scrollview` / `flutter_inappwebview_android`（在 `third_party/`）与 `flutter_inappwebview_windows` / `gamepads_android_stub`（在 `packages/`），经 `dependency_overrides` 的 `path:` 从仓库内解析。`third_party/` 的 fork 必须整包入库（`.gitignore` 用 `!third_party/**/*.xml` 豁免 res/manifest）；新增时把其 pubspec 的 SDK 上界 bump 到 `<4.0.0`。
- **pub-cache 补丁**：`ci/apply-patches.sh` 把 `ci/patches/{hosted,git}/<包-版本>/` 覆盖到 pub cache，按精确版本号命名；版本漂移就跳过并警告（HBK-AUDIT-005）。每次清 cache 或 `pub get` 后要重跑（bootstrap 已含）。

> `carousel_slider` / `fading_edge_scrollview` / `network_to_file_image` 两边都有：`dependency_overrides` 生效，pub-cache 同名补丁因版本对不上被自动跳过，以 vendored 为准。

## galgame 引擎-hook 注入器 helper（同仓源码，隔离二进制随 Windows 主包）

galgame 一键制卡的引擎-hook 注入器（injector.exe + hook.dll + vendored LunaHook/Host DLL）含
`CreateRemoteThread`/`WriteProcessMemory`。**源码在本仓 `native/galgame_hook/`**（与
`native/hoshidicts/`、`native/hibiki_torrent/` 同级）。helper 绝不链接进 `Hibiki.exe`，运行时仍是
隔离子进程/DLL；但两架构的校验 zip 随 Windows 主包进入 `galgame_helper/`，从而离线首装可用。

> 历史：这套组件曾整体迁到独立仓库 `hajisensai/hibiki-hook`。迁出的真正根因是 CI——主仓库那份
> workflow 不在默认分支，GitHub 不暴露 `workflow_dispatch` 入口，release 从没被产出过；合仓后
> workflow 就在默认分支 `develop` 上，该问题不复存在。另一条写在红线里的理由「必被杀软报毒」
> 自 C.1 起从未被验证过，**实测已证伪**：Windows Defender（签名 1.455.357.0、实时保护开启、
> runner 全盘排除项已解除）对 helper 全部 13 个文件与两个 zip 零检出，同一轮 EICAR 阳性对照
> 正常报出 `Virus:DOS/EICAR_Test_File`，证明扫描器确实在工作（hibiki-hook#8 的 av-selfscan）。
> 国产杀软（360/火绒等）未验证，若被拦按误报处理。

- **构建/发布**：根 `.github/workflows/voice-hook-helper.yml`（windows-2022）。触发为
  `workflow_dispatch` + `develop` 上命中 `paths` 白名单（`native/galgame_hook/**` 或该 workflow
  自身）的 push。**必须是 paths 白名单而不是 paths-ignore**：合仓后沿用 paths-ignore 会让主仓库
  任何一次非文档提交都去重建并重发 helper。各 run 步骤经 `defaults.run.working-directory:
  native/galgame_hook` 保持相对路径不变；`softprops/action-gh-release` 的 `files:` 不吃
  working-directory，必须写仓库根起算的完整路径。
  cmake 编 x64（`-A x64`）+ x86（`-A Win32`），每架构打 `voice_hook_<arch>.zip`（injector/hook/
  LunaHook/LunaHost）+ `.sha256` 侧车，upsert 到**固定 tag `voice-hook-helper`** 的
  **prerelease、`make_latest: false`**。发布步骤有 `if: github.ref == 'refs/heads/develop'` 分支守卫
  ——只有默认分支能 upsert 那个所有用户都会自更新拉取的 release；PR 分支照跑构建与双架构
  ctest，但不发布。
- **主包内置**：`native/galgame_hook/tools/build_distribution.ps1 -RunTests` 是固定 release 与
  Windows 主包共用的唯一组包入口，输出 x64/x86 zip + `.sha256`。`build-multiplatform.yml` 把它们
  放进 Debug bundle 的 `galgame_helper/` 验证布局；`release-desktop.yml` 放进 Release bundle 的同名
  目录，Inno Setup 的 `recursesubdirs` 将其纳入安装器。`check_release_policy.ps1` 守卫这条链，禁止
  后续“构建仍绿但安装器漏带 helper”。
- **历史下载 URL**（只服务已经发布的旧客户端；新客户端不再使用）：
  `https://github.com/hajisensai/hibiki/releases/download/voice-hook-helper/voice_hook_<arch>.zip`（+ `.sha256`）。
- **老客户端不断供**：已发布版本的 app 把 `hajisensai/hibiki-hook` 编进了常量，会继续从那个仓库取
  helper。**`hajisensai/hibiki-hook` 仓库与其 `voice-hook-helper` release 必须保留、不得删除**
  （Never break userspace）；它只作为老客户端的下载宿主冻结，新开发一律在本仓 `native/galgame_hook/`。
- **app 端安装**：开 galgame 需要注入器却缺失时，`GalgameHelperInstaller`（`hibiki/lib/src/mining/
  galgame_helper_installer.dart`）先读取 exe 同级 `galgame_helper/voice_hook_<arch>.zip` 与侧车，校验
  SHA-256 后解压/换入 `voice_hook/<arch>/`，全程零网络、零下载确认；正式 Windows 主包必须命中此路。
  开发构建/旧包没有随包归档时提示更新/重新构建 Hibiki，**不回退网络**；已安装版本也没有后台自更新。
- **Magpie 同样随包唯一来源**（BUG-1292）：两个 Windows workflow 用
  `tools/build_magpie_slim.ps1` 生成 `Magpie-hibiki-slim-x64.zip` + `.sha256`，放进
  `magpie_bundle/`。`MagpieInstaller` 校验后换入 `magpie/`；ARM64 Windows 走系统 x64 模拟。
  缺包、损坏和旧构建会直接报告“安装包不完整/内置组件校验失败”，没有下载确认、镜像兜底
  或后台自更新；正式 Windows 包出现该错误即属于打包或安装损坏。
  与 helper 同款，`hibiki/windows/CMakeLists.txt` 有一条 `install(FILES ... OPTIONAL)`
  从仓库根 `dist/` 把归档拷进 bundle，**开发构建也能拿到**（先跑一次
  `pwsh -File tools/build_magpie_slim.ps1`）；`tool/check_release_policy.ps1` 守住两个
  Windows workflow 的组包步骤、`magpie_bundle/` 载荷目录和 sha256 侧车。
