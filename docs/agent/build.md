# 构建与依赖补丁

> [CLAUDE.md](../../CLAUDE.md) 的子文档。构建上手见 [README.md](../../README.md)；这里只补 agent 关心的增量。

## 平台与 SDK

5 平台均出包：Android / iOS / macOS / Windows / Linux（`auto` 下五个平台统一走 Material 3；Cupertino / macOS renderer 仅保留为隐藏内部能力；桌面 EPUB 渲染靠 fork 的 `flutter_inappwebview_windows`，Linux 阅读器能力受限）。Android：`compileSdk 36` / `minSdkVersion 24` / `targetSdk 35`。

## Melos

仓库根是 Melos workspace（`fushi_workspace`）。常用：`melos run analyze` / `melos run test` / `melos run build:android`。

## 准备 + 构建

`tool/bootstrap.sh`（Windows：`.\tool\bootstrap.ps1`）一条命令完成：`flutter pub get` → `ci/apply-patches.sh`。`melos bootstrap` 经 post hook 做同样两步。然后：

> **代理**：`pub get` 只认继承来的 `HTTPS_PROXY`/`HTTP_PROXY`，而 agent 每次工具调用都是新 shell —— 上一条命令里设的代理不会留到下一条，这是「`setup_worktree.ps1` 首跑 socket error、带代理重跑就过」的根因。`bootstrap.ps1` 按 `调用方环境变量 > FUSHI_BOOTSTRAP_PROXY > <主 checkout>/tool/bootstrap.local.env`（gitignore，本机私有，一次配好所有 worktree 通用）取代理，三者都没有也照常直连跑（CI 不受影响），只是会先探一次 pub.dev 并在不通时把配法打在前面——**探测只示警不拦路**（实测单次探测会误报：探测 10s 超时失败的同一时刻，`pub get` 自带重试仍 45s 跑通），真判死刑交给 `pub get` 自己，失败时把同一份配法作为报错抛出。代理地址绝不写进入库脚本。

```bash
cd fushi
flutter build apk --release --target-platform android-arm64 --split-per-abi
```

### TODO-207 release channel invariants

客户端按 stable / beta / debug 三个通道过滤 GitHub Release。stable 只看正式 Latest；beta/debug 扫描最近 releases，但只接受 tag 形如 `v<version>-beta.<seq>` / `v<version>-debug.<seq>+<short-sha>` 且 `prerelease=true` 的 release。旧的 `debug-<sha>` tag 不可比较，客户端会忽略。

debug 通道发布的是 release-signed debug-channel APK：文件名保留 `-debug.apk` 供客户端过滤，APK 使用 release keystore、写入 `versionName=<version>-debug.<seq>` 和单调 `versionCode`（公式见下「版本号与 build number」），用于覆盖正式签名包并让同一平台后续 debug/beta/formal release 仍可比较。debug push 仍必须是 prerelease / non-Latest，绝不能创建或更新 formal / Latest。

**滚动 debug release（TODO-1049）**：debug 通道**不再**每次 push 新建一个 `v<version>-debug.<seq>+<short-sha>` GitHub Release——否则 debug 高频构建会在 Releases 列表无限堆积、淹没正式/beta 条目（用户明确诉求：调试版不该占 Release 位）。改为所有 debug 构建复用**同一个固定滚动 tag `debug-rolling`**（`steps.channel.outputs.publish_tag`），列表里 debug 永远只有 1 条。关键不变式：GitHub Release 的 git tag（`publish_tag=debug-rolling`）与「客户端版本比较用的版本化 tag」（`steps.channel.outputs.tag = v<version>-debug.<seq>+<short-sha>`）**解耦**——manifest `latest-debug.json` 的 `tag` 字段仍写版本化 tag（客户端据 `<seq>` 单调判断「有无更新」，逻辑零改动），而资产下载 URL 走 `releases/download/debug-rolling/<name>`（`publish_update_manifest.sh` 的 `DOWNLOAD_TAG`）。softprops 只 upsert 同名 asset、不删旧 commit 的 asset，故发布前有一步按当前 `versionName` token 清理滚动 release 上非本 seq 的陈旧资产（同 commit 的 Android+desktop 共享 seq、互不误删；新 commit 清旧 commit）。`release.yml` 里另有一步 GC 掉历史遗留的版本化 debug prerelease（tag 形如 `v...-debug.<seq>+`，不含滚动 tag），把列表收敛到单条。beta/formal 不受影响：其 release 就是版本化 tag 本身，`publish_tag == tag`。

Android / Windows / macOS / iOS debug/beta workflow 必须使用跨 workflow 统一 release 序列（cross-workflow release sequence）：发布 workflow 都用完整历史 checkout 后的 `git rev-list --count HEAD` 生成 `<seq>`，不得用各自独立的 `github.run_number` / `GITHUB_RUN_NUMBER` 生成 tag、安装包版本或 Android `versionCode` 扩展位。Android `versionCode = versionCodeBase(1_000_000_000) + 100 × <seq> + abiOffset`（公式在 `fushi/android/app/build.gradle`，CI 只把 `<seq>` 当 `--build-number` 传入），不再用旧的 `PUBSPEC_BUILD × 1_000_000 + seq` build number——那个数会把 versionCode 顶到约 66 亿，溢出 int32 且超 Android 21 亿上限，beta/release 的 Android 包根本建不出来（TODO-414）。同一 commit / 同一语义版本的自动 debug 默认 tag 必须相同，并通过同一个 concurrency group 串行上传资产，合并到同一个 GitHub Release（single GitHub Release）。客户端自装平台必须先按本平台 asset 过滤 release：Android 只接受匹配通道的 APK，Windows 只接受匹配通道的 `-windows-setup.exe`，macOS 只接受 `-macos.zip`；如果远端只有错平台新版本，Android/Windows/macOS 返回无更新而不是打开 release 页。iOS 发布 no-codesign `.ipa` 只作为 GitHub 下载产物，不做应用内自动安装。Unsupported 平台仍可在没有本平台自装 asset 时打开 release 页。若手动 Android / desktop/Apple workflow 指定 `tag_name`，也应使用同一个 tag 合并到同一个 Release，由各平台客户端选择自己的 asset。

> Google Drive 同步的 OAuth 凭据已写死进源码默认值（`lib/src/sync/google_drive_auth.dart`），构建无需再传 `--dart-define`。如需换凭据，改该文件的 `defaultValue` 或自行加 `--dart-define` 覆盖。

## 发布通道

默认 push 只发 debug 通道；beta/test 和 formal 都必须手动触发。任何 push 触发的 GitHub Release 都必须是 prerelease 且 `make_latest: false`，不得创建或更新 Latest/正式 release。

- debug（push 自动）：`main` / `develop` push 会走 `.github/workflows/main.yml` 上传 Actions artifact，并走 `.github/workflows/release.yml` 发布 Android debug GitHub prerelease；同时走 `.github/workflows/release-desktop.yml` 发布 Windows debug installer、macOS app zip、iOS no-codesign IPA。Artifact 名称为 `fushi-debug-apk-${{ github.sha }}`，Actions artifact APK 文件名为 `fushi-<version>-<short-sha>-debug.apk`，保留 14 天；Android debug GitHub Release 使用 release-signed debug-channel APK，文件名为 `fushi-<version>-debug.<seq>-<short-sha>-debug.apk`；Windows debug GitHub Release 使用 Inno Setup installer，文件名为 `fushi-<version>-debug.<seq>-windows-setup.exe`；macOS 为 `fushi-<version>-debug.<seq>-macos.zip`；iOS 为 `fushi-<version>-debug.<seq>-ios.ipa`。Windows/macOS/iOS 都用同一个 `0.x.y-debug.<seq>` 作为 Flutter `--build-name`，保证安装后的 `PackageInfo.version` 能停止同一 debug release 的重复提示/自动安装。GitHub Release 的 git tag 固定为滚动的 `debug-rolling`（TODO-1049，见上「滚动 debug release」）；客户端版本比较用的版本化 tag 仍为 `v<version>-debug.<seq>+<short-sha>`（写进 manifest `tag` 字段）。同一 commit 的 Android/Windows/macOS/iOS 自动 debug 必须落到同一个 GitHub Release（即同一个 `debug-rolling` 滚动 release），且必须是 prerelease / non-Latest；各客户端必须按本平台资产后缀过滤，不能互相吃错平台资产，也不能等 beta/test 或 formal installer。
- beta/test（手动）：通过 `.github/workflows/release.yml` 或 `.github/workflows/release-desktop.yml` 的 `workflow_dispatch` 选择 `beta`，或手动发布一个勾选 prerelease 且非 Latest 的 GitHub Release。Android 默认 tag 为 `v<version>-beta.<seq>`，产物包含 `fushi-<version>-<short-sha>-debug.apk` 与 split ABI release APK `fushi-<version>-<abi>.apk`；Windows 产物为 `fushi-<version>-windows-setup.exe`；macOS 产物为 `fushi-<version>-macos.zip`；iOS 产物为 `fushi-<version>-ios.ipa`。如需 Android、Windows、macOS、iOS 合并到同一 beta/test Release，两个手动 workflow 使用同一个 `tag_name`；未指定时，同一 commit 上两条 workflow 的默认 `<seq>` 相同，也会合并到同一 Release。
- formal（手动）：通过手动 GitHub Release 或 `workflow_dispatch` 选择 `formal`。默认 tag 为 `v<version>`；Android 产物包含 debug APK 与 split ABI release APK，Windows 产物为 installer，macOS 为 app zip，iOS 为 no-codesign IPA。formal 是唯一允许成为 Latest 的通道。
- 禁止事项：不要把 push、debug tag、debug APK 或 beta/test workflow 接到 formal/Latest；不要让 push 上传正式 release APK 或发布 formal/Latest；不要把 beta/test 发布成 non-prerelease 或 Latest。

### formal 发版顺序：迁移桥包必须先于本体（CI 硬门）

改名后**老 Hibiki 用户的迁移入口挂在 Fushi 的正式版 release 上**，所以 formal 通道多了一条
顺序约束，由 `release.yml` 的 `Require migration bridge assets on the formal tag` 步骤强制。

为什么：已出货的 Hibiki `v1.2.0` 二进制永远改不了，它挑包只看「`.apk` 结尾 + 名字含设备
`SUPPORTED_ABIS` 任一项」，**完全不认产品族**（本体侧的 `assetBelongsToThisProduct` 是
BUG-1481 之后才有的，救不了已装机的包）。GitHub API 按**文件名升序**返回资产，于是：

- 桥包资产用 `bridge-<version>-<abi>.apk`（`bridge-` < `fushi-`）→ 老客户端先命中桥包，
  升到的是能原地覆盖安装的迁移桥包（旧包名 `app.hibiki.reader` + 旧签名 + 迁移导出器）；
- 桥包**缺席**时老客户端退化成「随便拿列表里第一个 apk」，装上跨包名的 Fushi = 并存的第二个
  空 app。用户以为换代完成卸掉 Hibiki，`/data/user/0/app.hibiki.reader/` 下的数据永久丢失。

不变式与反向用例（含「前缀换成 `hibiki-` 会失守」「桥包缺席会失守」）钉在
`fushi/test/utils/misc/formal_asset_naming_legacy_contract_test.dart`。

发版顺序（**桥包先**，顺序错了硬门会直接失败，不会留下只有 `fushi-*` 的正式 release）：

```bash
# ① 先发迁移桥包（只出 Android；桥分支 release.yml 不含桌面，也不要跑 release-desktop.yml）
gh workflow run release.yml --repo hajisensai/Fushi \
  --ref bridge/auto-migrate-download \
  -f channel=formal -f tag_name=v<version> -f release_name="Fushi <version>" -f skip_tests=false

# ② 桥包资产到位后再发本体（手动 GitHub Release 或 workflow_dispatch，同一个 tag）

# ③ 收尾核对：两族资产都在
gh release view v<version> --repo hajisensai/Fushi --json assets \
  --jq '.assets[].name' | sort
```

判断桥包那一步是否成功的注意点：

- 桥分支的 `tests` job 与 `build` job **无 `needs` 依赖、并行跑**，`tests` 红**不会**挡住
  资产发布（线上桥包 `10192` 就是这么发出去的）。别看整体 run 颜色，看 `build` job 结论
  和 release 上真实的资产列表。
- 桥分支 formal 的 release 标题默认是 `Hibiki <version>`，本体那次发布会把它改写成
  `Fushi <version>`；不想出现中间态就在 ① 显式传 `-f release_name=`（**键名是 `release_name`，不是 `name`**；
  传 `name` 会被 GitHub 直接 422 拒掉：`Unexpected inputs provided: ["name"]`）。
- 桥包用 `LEGACY_KEYSTORE_*` 四件套签名（旧 Hibiki 证书，与 `v1.1.0`/`v1.2.0` 同公钥
  `d40c4a16…`），这是它能原地覆盖安装的前提；主仓 `KEYSTORE_*` 已轮换为 Fushi 新签名，
  两套 secrets 都必须在。
- Windows 老用户**不需要**桥包：他们按 `-windows-setup.exe` 后缀直接拿
  `fushi-<version>-windows-setup.exe`，Inno `AppId` 未变 → 原地升级，数据由
  `legacy_support_dir_migration.dart` 自动搬迁。所以别给桥分支发桌面产物。

### 快速发版（跳测试）

手动发版嫌慢时用「快速编译」路径：`release.yml`（Android）的 `workflow_dispatch` 带 `skip_tests` 输入，**默认 `true`**——手动 dispatch（debug/beta/formal 任意通道）默认跳过 `flutter analyze` + 主 app 单元测试 + 5 个 package 测试，直接进编译+发布。`release build` 步骤本身仍会挡住硬编译失败，发版前的真机验证仍按 [CLAUDE.md](../../CLAUDE.md) 走。约束：
- `skip_tests` **只在 `workflow_dispatch` 生效**；`push`（自动 debug）与 `release`（手动 GitHub Release）事件的 `github.event.inputs.skip_tests` 为空，恒跑完整测试门——`main`/`develop` 的持续测试信号不被削弱，慢的只让手动、你在等的那次发版跳过。
- 想手动发版也跑测试：dispatch 时把 `skip_tests` 取消勾选（设为 `false`）。
- `release-desktop.yml`（Win/mac/iOS）本就无测试步骤，天生快，无需该开关。
- 平台并行：Android（`release.yml`）与桌面（`release-desktop.yml`）是两条独立 workflow，同时 dispatch 即并行；桌面内部 `apple needs: windows` 是**故意串行**，避免两 job 抢同一 release 上传，勿改。

### Apple 签名与 TestFlight

`release-desktop.yml` 的 `ios` / `macos` job 在仓库 secrets 齐全时额外做 Apple 签名，
完整清单、首次配置、证书轮换与排障见 [apple-signing.md](apple-signing.md)。这里只记
影响发布判断的三条：

- **Apple 凭据全部可选**。缺任何一项，对应链路整段跳过，未签名 IPA / ad-hoc macOS zip
  照常发布 —— fork 和无开发者账号的状态下发布链路完全不受影响。
- **TestFlight 只在手动 `workflow_dispatch` 的 beta / formal 通道上传**（dispatch 输入
  `upload_testflight`，默认开）。push 触发的 debug 通道每次提交都会跑，传上去只会白烧
  App Store Connect 的处理配额并把构建号推高，而构建号在同一语义版本下必须单调，
  浪费不可回收。
- **GitHub Release 里的 `fushi-<版本>-ios.ipa` 仍是未签名包**，走的还是
  `flutter build ios --release --no-codesign`。老用户自签侧载的就是它，不能换成
  App Store 签名包。TestFlight 用的是另一次、只在手动 beta/formal 时才发生的签名构建，
  产物不进 Release 资产 —— 代价是这种发布下 iOS 构建两次。
- macOS 走 **Developer ID + 公证**，不进 Mac App Store：`Release.entitlements` 已刻意
  去沙盒以支持应用内自动更新替换 `/Applications/fushi.app`，商店强制沙盒，两者不可兼得。

## 版本号与 build number

Flutter 版本号以 `fushi/pubspec.yaml` 的 `version: X.Y.Z+build` 为准。准备 push 前先判断本轮改动是否影响用户可安装/可分发产物：

- **`+build`（build number）= 发布序号**：每次出包 / 发布单调 +1，**与语义版本是否变无关**——同一个 `X.Y.Z` 可连续 `+150`、`+151`…（实践即如此：多数发布只 +build、不动 `X.Y.Z`）。它仅做日志 / 可读版本标识，不进 Android `versionCode`。
- **语义版本 `X.Y.Z` 按里程碑升，不是每次发布都升**：
  - 一批功能完成 / 大模块 / 用户可见大改：升 minor 并重置 patch（如 `0.9.29` -> `0.10.0`）。
  - 一批修复 / 小功能阶段性收口：升 patch（如 `0.10.0` -> `0.10.1`）。
  - 单个零散 commit 通常**只 +build**；攒到一批 / 里程碑再升 `X.Y.Z`（届时 `+build` 也照常 +1）。
- Android `versionCode` 的单调递增由 CI 的 `git rev-list --count HEAD`（每个 commit +1）**加一次性地板**经 `--build-number` 喂给 `build.gradle` 的 `versionCodeBase + 100 × <seq> + abiOffset` 保证；`build.gradle` 还带 2.1e9 上限断言，越界即 fail-fast（TODO-414）。**不依赖 pubspec `+build`**。
- 纯文档、PM 元数据、不影响分发行为的 CI 维护不强制 bump；发布、安装包或运行行为变化应 bump。
- **序号算式收在 `tool/release_sequence.sh` 一个文件里**，六处 workflow 一律 `RELEASE_SEQUENCE=$(bash tool/release_sequence.sh)`，不得在 workflow 里写裸 `git rev-list --count HEAD` 赋值（守卫会红）。算式 = 提交计数 + `RELEASE_SEQUENCE_FLOOR`。
- **为什么有地板**：提交计数只在「历史只增不减」时单调，**重写历史会让它倒退**。2026-08-12 develop 被强推成重写后的历史，计数从 10546 掉到 9466，而已发布并装到用户机器上的最大序号是 10405。序号倒退会同时锁死三处单调比较——Android `versionCode`（系统安装器拒装）、app 内更新器的 `releaseSequence` 全序比较（永远提示已是最新）、`tool/merge_update_manifest.py` 的「Never downgrades the advertised top-level release」（新包写不进清单）。这三处都没错，错的是序号倒退，所以修在源头加地板，而不是去放宽任何一处守卫。
- **什么时候要再抬地板**：只有再次重写历史、且新的 `计数 + FLOOR` 不再高于「已发布过的最大序号」时。抬之前先去 GitHub Release 资产名里查真实的 `-debug.<seq>` / `-beta.<seq>` 最大值，别凭感觉加。守卫：`fushi/test/build/release_sequence_floor_guard_test.dart`。
- 发布 workflow 修改后必须运行 `tool/check_release_policy.ps1`（Windows：`powershell -NoProfile -ExecutionPolicy Bypass -File tool/check_release_policy.ps1`；GitHub Actions 用 `pwsh`）。该守卫会拒绝重新引入 workflow-local run number、缺失完整历史 checkout、缺失同 tag/commit 发布并发锁，或文档缺少 cross-workflow release sequence / single GitHub Release 规则。

## CI 缓存配额（TODO-2721）

GitHub Actions 给每个仓库的缓存配额是**硬上限 10 GB**，超了就按 LRU 静默驱逐。
驱逐不是洁癖问题：桌面发布 run `30729229450` 变红的最后一环就是 vcpkg 缓存被驱逐
后冷编 + 拉外部镜像失败。2026-08-02 实测 `gh api
repos/hajisensai/Fushi/actions/cache/usage` = **10.65 GB / 14 条**，长期在驱逐。

三条铁律（守卫 `fushi/test/build/workflow_cache_quota_guard_test.dart`）：

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
gh api repos/hajisensai/Fushi/actions/cache/usage
gh api "repos/hajisensai/Fushi/actions/caches?per_page=100"   --jq '.actions_caches[] | "\(.size_in_bytes) \(.ref) \(.key)"' | sort -rn
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
`native/fushidicts/`、`native/fushi_torrent/` 同级）。helper 绝不链接进 `fushi.exe`，运行时仍是
隔离子进程/DLL；但两架构产物在**构建期**就解压进 Windows 主包的 `voice_hook/<arch>/`（BUG-1449），
从而离线首装可用、运行期零网络。

> 历史：这套组件曾整体迁到独立仓库 `hajisensai/hibiki-hook`。迁出的真正根因是 CI——主仓库那份
> workflow 不在默认分支，GitHub 不暴露 `workflow_dispatch` 入口，release 从没被产出过；合仓后
> workflow 就在默认分支 `develop` 上，该问题不复存在。另一条写在红线里的理由「必被杀软报毒」
> 自 C.1 起从未被验证过，**实测已证伪**：Windows Defender（签名 1.455.357.0、实时保护开启、
> runner 全盘排除项已解除）对 helper 全部 13 个文件与两个 zip 零检出，同一轮 EICAR 阳性对照
> 正常报出 `Virus:DOS/EICAR_Test_File`，证明扫描器确实在工作（hibiki-hook#8 的 av-selfscan；证据留在
> `native/galgame_hook/docs/av-selfscan-evidence.md`，该 workflow 已于 2026-08-11 删除，不再复跑）。
> 国产杀软（360/火绒等）未验证，若被拦按误报处理。

- **没有独立的 helper 发布通道了**（2026-08-11 起）：helper 只由 Windows 主包的两个 workflow
  顺带构建并随包落地，不再单独发 release。原先的 `.github/workflows/voice-hook-helper.yml`
  （upsert 固定 tag `voice-hook-helper` 的 prerelease）与 `av-selfscan.yml`（Defender 实扫该
  release 资产）**已一并删除**，`voice-hook-helper` release 本体也已删除。删除的前提是
  `8cd11846fe`（helper/Magpie 全部随包零网络）+ `fb2e2ed685`（BUG-1449 构建期解压随包）之后
  app 侧**再无任何联网取 helper 的代码路径**——`galgame_helper_installer.dart` 里一个 http 都没有。
  - ⚠️ **代价是已知且被接受的**：2026-07-20（`3eb73c880c` 引入按需下载）到 2026-07-26 之间
    发布的 Windows debug 包既没有随包 helper（离线随包 `a3d741778c` 是 07-27 才落地），又把
    `kGalgameHelperRepo = 'hajisensai/hibiki'` 编进了常量（该仓已改名，URL 重定向到
    `hajisensai/Fushi`）。这批包里**没更新过的**用户开 galgame 会撞 404「引擎组件下载失败」，
    症状同 BUG-961，唯一恢复手段是更新到新版。用户 2026-08-11 明确拍板接受此破坏。
  - 更早的一批客户端把 `hajisensai/hibiki-hook` 编进常量，**那个仓库早已不存在**，与本次删除无关。
- **构建入口**：`native/galgame_hook/tools/build_distribution.ps1 -RunTests` 是唯一组包入口，
  cmake 编 x64（`-A x64`）+ x86（`-A Win32`），每架构打 `voice_hook_<arch>.zip`（injector/hook/
  LunaHook/LunaHost，x86 另带 Locale Emulator）+ `.sha256` 侧车。`build-multiplatform.yml` 与
  `release-desktop.yml` 的 windows job 都调它（`pull_request`/`push` + paths 含 `native/**`），
  所以**双架构编译与 ctest 是 PR 门**；`native-galgame-gate.yml` 另跑那 7 条平台无关的静态守卫。
  产物由 `tools/install_into_bundle.ps1` 在构建期解压进 bundle 的 `voice_hook/<arch>/`，
  Inno Setup 的 `recursesubdirs` 将其纳入安装器。`check_release_policy.ps1` 守卫这条链，禁止
  后续“构建仍绿但安装器漏带 helper”。
- **app 端安装**：开 galgame 需要注入器却缺失时，`GalgameHelperInstaller`（`fushi/lib/src/mining/
  galgame_helper_installer.dart`）先读取 exe 同级 `galgame_helper/voice_hook_<arch>.zip` 与侧车，校验
  SHA-256 后解压/换入 `voice_hook/<arch>/`，全程零网络、零下载确认；正式 Windows 主包必须命中此路。
  开发构建/旧包没有随包归档时提示更新/重新构建 Fushi，**不回退网络**；已安装版本也没有后台自更新。
- **Magpie 同样随包唯一来源**（BUG-1292）：两个 Windows workflow 用
  `tools/build_magpie_slim.ps1` 生成 `Magpie-hibiki-slim-x64.zip` + `.sha256`，放进
  `magpie_bundle/`。`MagpieInstaller` 校验后换入 `magpie/`；ARM64 Windows 走系统 x64 模拟。
  缺包、损坏和旧构建会直接报告“安装包不完整/内置组件校验失败”，没有下载确认、镜像兜底
  或后台自更新；正式 Windows 包出现该错误即属于打包或安装损坏。
  与 helper 同款，`fushi/windows/CMakeLists.txt` 有一条 `install(FILES ... OPTIONAL)`
  从仓库根 `dist/` 把归档拷进 bundle，**开发构建也能拿到**（先跑一次
  `pwsh -File tools/build_magpie_slim.ps1`）；`tool/check_release_policy.ps1` 守住两个
  Windows workflow 的组包步骤、`magpie_bundle/` 载荷目录和 sha256 侧车。
