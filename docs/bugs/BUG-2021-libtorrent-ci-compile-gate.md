## BUG-2021 · libtorrent native 构建在 PR 阶段无编译门（Android 侧从未在 CI 编译过）
- **报告**：2026-09-02（用户：CI 缺口审查，PR #1129 前置）
- **真实性**：✅ 真 bug（部分修正了报告时的说法：Windows 侧其实**有**门，Android 侧才是真空）

### 现状台账（对 develop@d7c762cd5a 逐条核实）

`native/fushi_torrent` 有三个构建入口，改动前的 CI 消费面：

| 构建脚本 | 被谁消费 | 消费方有 PR 触发吗 |
|---|---|---|
| `native/fushi_torrent/build_windows_dll.ps1` | `.github/workflows/build-multiplatform.yml:586`（windows job）<br>`.github/workflows/release-desktop.yml:350`（发布路径） | ✅ 有：`build-multiplatform.yml:29-31` 的 `pull_request` + `paths` 含 `native/**`（YAML anchor `&multiplatform_paths` 定义在 `:16`，`native/**` 在 `:21`，PR 侧 `:31` 复用 `*multiplatform_paths`）。该 job 还在 `:597-613` 跑 `packages/fushi_torrent` 的 dlopen FFI 测试 |
| `native/fushi_torrent/build_android_so.sh` | **只有** `.github/workflows/release.yml:406-409` | ❌ **无**：`release.yml:13/24/26` 的触发只有 `push`(main/develop) + `release` + `workflow_dispatch`，**没有 `pull_request`** |
| `native/fushi_torrent/build_android_so.ps1` | 无 CI 消费（开发者本机 Windows 用） | — |

### 根因

两层，第二层更隐蔽：

1. **PR 路径真空**：`release.yml` 是发布 workflow，本就没有 `pull_request` 触发（`main.yml` 的头注释明说「release.yml has no pull_request trigger」）。于是唯一编译 Android `.so` 的地方落在合并**之后**。改 C ABI bridge、`vcpkg.json` 钉版、overlay triplet/port 的 PR，NDK clang 交叉编译 + 静态链 boost/openssl/libtorrent 这条路在合进主干前**一次都没跑过**。
2. **push 路径也漏**：`release.yml:15-23` 的 push `paths` 是 `fushi/** packages/** ci/** tool/** third_party/** .github/workflows/** pubspec.yaml pubspec.lock` —— **不含 `native/**`**（对比 `build-multiplatform.yml:21` 与 `release-desktop.yml:19` 都显式补了 `native/**`，且各自留了「只改 native/ 的 PR 以前触发不了任何构建」的注释）。所以一个纯 `native/fushi_torrent/**` 的改动合进 develop 之后，那次 push 同样不触发 Android `.so` 构建；断供要等到下一个碰 `fushi/**` 的提交才暴露，而那时归因会指向无辜的提交（BUG-1772 就是这个形态：develop 上连红，且不是任何一个 commit 引入的）。

危害是实测过的：BUG-1772 里 libtorrent 从 2.0.11 漂到 2.1.1，Windows 4 个 DLL 和 Android `.so` 一起编不出来，`build_windows_dll.ps1` 对 Release 缺 DLL 即 throw = Windows 正式包直接断供。Android 侧同款风险至今没有任何合并前的信号。

- **[x] ① 已修复** — 新增 `.github/workflows/native-torrent-gate.yml`（PR 阶段只读编译门，两个 job）+ `.github/scripts/verify_torrent_abi.sh`（产物符号校验）。提交见本文件末尾。
- **[x] ② 已加自动化测试** — `fushi/test/build/libtorrent_version_pin_guard_test.dart` 追加 4 条（同一域已有的 BUG-1772 守卫扩写，不另起文件）：
  - 「`build_android_so.sh` 必须被至少一个带 `pull_request` 触发的 workflow 消费」——这条直接钉住本 bug 的根因，门被删或触发被摘掉会当场红；
  - 「overlay ports 存在时三个构建脚本都必须传 `VCPKG_OVERLAY_PORTS`」——给 PR #1129 准备的：漏给 CI 消费的 `.sh` 版传 overlay，Windows 本机编得出、Android CI 编的却是没打补丁的上游 port；
  - 「门只读、不发布、不得 `continue-on-error`、paths 覆盖自身」；
  - 判据自校验（合成语料）：`hasPullRequestTrigger` 不得退化成全文 `contains`（注释、job 级 `if: github.event_name == 'pull_request'`、步骤名里都有这个字面量），`consumesScript` 必须剥注释。
  - 变异实测：把门的 `pull_request:` 改成 `push:` → 8 条里精确红 1 条（`libtorrent_version_pin_guard_test.dart:183`）；改回后 sha256 逐字还原。

### 这道门覆盖到哪一层（以及**没**覆盖什么）

覆盖：**配置 → 编译 → 链接 → 产物校验**，两个工具链。
- `bridge-linux`（~3 min）：host GCC + Ubuntu `libtorrent-rasterbar-dev` 2.0.10，cmake configure + build + `nm -D` 符号全覆盖断言。快信号，且是 `CMakeLists.txt` 非 Windows 分支唯一被跑到的地方。
- `android-arm64`（冷编 ~40 min / 命中二进制缓存 ~5 min）：跑 `release.yml` 消费的**同一个** `build_android_so.sh`（不复制脚本内容，避免守卫守到替身），再验产物：文件存在 → ELF Machine 必须是 AArch64 → 37 个 `HT_EXPORT` 符号全部在动态符号表里 → LOAD segment 16KB 对齐（Android 15 的 16KB page size 要求，掉了的话构建照样成功、APK 却装不上）。

**没覆盖**（别误以为它管这些）：
- **Windows DLL**：已由 `build-multiplatform.yml` 的 windows job 在 PR 上真编真测（还跑 dlopen FFI 测试），这里重复跑 = 白烧一台 Windows runner 换零新增信息。
- **发布路径**：`release.yml` / `release-desktop.yml` 的产物随包、签名、发布通道一概不碰。门 `permissions: contents: read`，不上传产物、不建 tag、不碰 release。
- **`release.yml` push paths 缺 `native/**` 这个洞本身没补**：本 PR 只加 PR 阶段的门，不动发布 workflow 的触发面。后果仍在：纯 native 改动合进 develop 后不会立刻产出新的 Android `.so`。要补应是另一条 PR（改发布 workflow 触发面属于发布路径改动，风险面不同，不该和一条只读门混在一起）。
- **运行期行为**：只到「编得出、链得上、符号齐、ELF 形状对」。真机下载/做种/代理行为不在射程内。
- **其它 ABI**：只编 arm64-v8a，与 `release.yml` 的范围决策一致（其余 ABI 无 `.so` 时运行期回退外接 qBittorrent，不是静默破坏）。
- **`build_android_so.ps1`**：仍无 CI 消费（Windows 本机开发用）；守卫只保证它与 `.sh` 版的 overlay 参数不分叉。

- **备注**：报告时的说法「全仓没有任何 CI job 会编译 libtorrent」不准确——Windows 侧一直有 PR 门（`build-multiplatform.yml`）。真空只在 Android/Linux 侧，本条按实测事实收敛了范围。
