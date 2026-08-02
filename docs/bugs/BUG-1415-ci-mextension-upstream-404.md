## BUG-1415 · CI macos/windows/publish 全红：Mihon 桌面 runtime 构建 git clone 已 404 的 M-Extension-Server
- **报告**：2026-08-02（用户：巡检看板 TODO-2559「桌面发布产物出不来」；根因先由 BUG-1353 的备注记为「另一条未修的独立根因」）
- **真实性**：✅ 真 bug（外部依赖失效导致 CI 步骤本身跑不通）。根因
  `tool/mihon/build_desktop_runtime.ps1:12` 与 `tool/mihon/build_desktop_runtime.sh:15`
  的 `git clone https://github.com/miru-project/M-Extension-Server.git`——该仓库已从
  GitHub 删除（`gh api repos/miru-project/M-Extension-Server` → Not Found），git 转去
  交互取凭据 → `could not read Username for 'https://github.com'` → exit 128。
  受影响：`Build and Test` 的 windows/macos job、`Build Desktop and Apple Release
  Artifacts` 的 windows/macos job，以及依赖它们产物的 publish job（级联，
  `No files matched hibiki-*-windows-setup.exe`）。与 BUG-1353 的 BSD sed 是两条独立根因。
- **[x] ① 已修复** — 用户拍板「合并」，源码按 MPL-2.0 正式 vendor 进仓库：
  `third_party/m_extension_server/upstream_src/`（435 文件，pinned commit
  `ee55c65106bb18bf81a5ddc660d321b4e14ea2f9` 的上游树逐字节副本，只排除 `.git/`
  与上游误提交的 `.DS_Store`）。两份构建脚本改成从 vendored 树复制，不再 clone/fetch；
  `overlay/` 与 `server-build.gradle.patch` 的应用顺序与语义完全不变（先打补丁、再
  覆盖 overlay），安全边界一字未改。另因 vendored 树没有 `.git`，上游
  `server/build.gradle.kts` 的 `git rev-list HEAD --count` 会退化成空串，改走上游自带的
  `ProductRevision` 环境变量钩子钉成 commit 短 SHA。
  源码同源性证据：救回树与本仓已有的 `third_party/m_extension_server/LICENSE`
  sha256 完全相同（`3f3d9e0024b1921b067d6f7f88deb4a60cbe7a78e76c64e3f1d7fc3b779b9d04`）。
- **[x] ② 已加自动化测试** — `hibiki/test/build/mihon_vendored_server_guard_test.dart`（15 条）：
  ① vendored 树存在且完整；② LICENSE sha256 同源性；③ UPSTREAM/NOTICE 记清 commit
  与布局；④ 两份脚本都不含 `git clone|fetch` / M-Extension-Server 远端 URL（走共享
  `maskHashComments` 剥 `#` 注释，否则解释性注释会把守卫判成假红）；⑤ 两份脚本都从
  `upstream_src` 取源、钉 commit、仍应用补丁；⑥ overlay 必须在补丁**之后**应用；
  ⑦ 显式设置 `ProductRevision`；⑧ 补丁能打在 vendored 树上；⑨ **补丁每条 `-` 行都
  对得上 vendored 树的实际内容**——`git apply --unidiff-zero` 会关掉上下文校验，源文件
  内容变了它照样 exit 0 再盲替换，`--check` 挡不住漂移，实测证实；⑩ overlay 覆盖的
  上游路径仍存在（上游改名会让同名覆盖静默打空，安全边界无声消失）；⑪ 安全边界字面量
  （`NanoHTTPD("127.0.0.1"`、`HIBIKI_MIHON_TOKEN` fail-closed、`MessageDigest.isEqual`、
  鉴权早于 `when (session.uri)` 分发、`/stop`）。
  变异实测（每次反向替换还原，未用 `git checkout --`）：
  - 把 `git clone <上游 URL>` 加回 .sh → 只有「不从远端取」红；
  - 把 overlay 拷贝挪到补丁之前 → 只有「overlay 在补丁之后应用」红；
  - 改 `upstream_src/gradle/libs.versions.toml` 的 `serialization` 版本 →
    `git apply --check` **仍 exit 0**（证明 ⑨ 那条不是重复守卫），新加的逐行核对红；
  - 把 overlay 的 `NanoHTTPD("127.0.0.1", port)` 改回上游的 `NanoHTTPD(port)` →
    「安全边界」红。
  还原后 `diff -r` 确认 `upstream_src` 与救回树逐字节一致、overlay 无残留。
- **备注**：CI 侧本地验不了。macos/windows/publish 三个 job 是否真转绿**需要 CI 实证**，
  本轮只做到「离线复现整条 vendored → 补丁 → overlay 流水线并核对产物内容正确」。
  上游仓库已消失，救回源来自网络镜像 `kodjodevf/M-Extension-Server`，按 SHA 直取，
  同源性由 LICENSE sha256 一致佐证（见 `third_party/m_extension_server/UPSTREAM`）。
