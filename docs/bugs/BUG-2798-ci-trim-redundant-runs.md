## BUG-2798 · CI 冗余触发与排队：无关改动跑满长构建、develop 连推每次跑满发布
- **报告**：2026-09-30（用户：「有些 CI 根本没必要跑了，如果有新 CI 自动取消」，要求按根本性方案做）
- **真实性**：✅ 真问题。逐条对照 `.github/workflows/` 核实的根因：
  1. `main.yml`（Android 构建 + 全量单测，~90 min）的 `pull_request.paths` 挂整个 `.github/workflows/**`：改任何一条别的 workflow 都跑满一轮。只改 `packages/fushi_server/**` 的 PR 也跑 app 构建（app 不依赖服务端）。`build-multiplatform.yml` 同理（服务端、`.md`）。
  2. `release.yml` / `release-desktop.yml` 的 `push.paths` 挂整个 `tool/**` + `.github/workflows/**`：改 `tool/bug.dart` 或任何 workflow 都在 develop 上跑一整轮发布构建。
  3. 两条发布 workflow 的 concurrency 组对 push 也按 sha 分：`fushi-release-<workflow>-<sha>`。develop 每推一次各成一组、各跑满一轮，中间几轮的产物随即被最新那轮覆盖，排队的旧 run 永远不会被后来者顶掉。
  4. `leaderboard-worker.yml` 没有 concurrency，PR 追加提交不取消旧 run。
  5. `native-cache-warm.yml` 没有 paths，每次 develop push 都起一台 runner 探缓存。
  6. `build-multiplatform.yml` 的 android appSmoke job `continue-on-error: true`，自述约 75% 红，挡不住任何东西，却每条 PR 占一台 runner 跑模拟器。
  7. `contributors.yml` 往 README 写贡献者列表，但全仓没有它要的 `readme: contributors` 标记，这条 workflow 是死的。
- **[x] ① 已修复** — 分支 `ci/trim-redundant-runs`：
  - `main.yml`：paths 只列自身、`provide-baked-secrets` action 和 `tool/release_sequence.sh`，补上真实依赖 `third_party/**`（根 pubspec 的 path override 指向它），加 `!packages/fushi_server/**`。**故意不排除 `.md`**：它是 PR 上唯一跑 fushi/test 全量的门，而 `fushi_rename_guard`、`onnxruntime_*_guard`、`popup_mine_key_binding` 等守卫把 `.md` 当语料读。
  - `build-multiplatform.yml`：补上真实依赖（`tool/mihon/**`、`provide-baked-secrets`、`verify_torrent_abi.sh`），加 `!packages/fushi_server/**`、`!**/*.md`。android appSmoke 加 `if: github.event_name == 'workflow_dispatch'`，注释写明理由和恢复条件。
  - `release.yml` / `release-desktop.yml`：push paths 把 `tool/**`、`.github/workflows/**` 换成实际调用的脚本（逐个列出）和两条发布 workflow 自身，并排除服务端。release.yml 补上它真正编译的 `native/fushidicts|fushi_torrent|fushi_p2p/**`，release-desktop 补上 `tools/bundle_7za.ps1`。concurrency 组的 push 事件改按 `github.ref` 分，仍 `cancel-in-progress: false`：正在跑的那轮照样跑完，排队中的旧 pending 被后来者顶掉。组名仍带 workflow 名（09-03 教训）。`tool/check_release_policy.ps1` 同步更新。
  - `leaderboard-worker.yml`：加 concurrency（只取消 PR）。
  - `native-cache-warm.yml`：push 加 paths（`native/fushi_torrent/**` + 自身）。镜像换代的兜底用每日 schedule（schedule 只读 main 上的文件，要等下次同步到 main 才生效，之前可以手动 dispatch 补）。
  - 删 `contributors.yml`。
  - 新增 `server-gate.yml`：服务端只改自身时的轻量门，跑 `dart analyze`、包测试、`dart build cli` 和 `--help`，PR 与 develop push 都跑。有了它，排除服务端之后才不会一个门都没有。
  - 新增 `ci-config-gate.yml`：`.github/**` / `tool/**` 改动时跑 `check_release_policy.ps1` 和按磁盘枚举出来的 workflow / 发布脚本守卫（51 个文件），PR 与 develop push 都跑。main.yml 和发布 workflow 不再因 workflow / tool 改动触发之后，这批守卫就靠这道门接住。
- **[x] ② 已加自动化测试** — `fushi/test/build/release_workflow_concurrency_guard_test.dart`：钉住「push 按分支、其余按 tag/sha、带 workflow 名、`cancel-in-progress: false`」，PowerShell 策略字面量从同一常量推导出来。`fushi/test/build/release_workflow_path_filter_guard_test.dart` 新增一组：按 workflow 正文里**实际调用**的 `tool/` 脚本和本地 action 反向对账 push paths，按 GitHub 语义处理负向模式，同时禁止回退成 `tool/**` / `.github/workflows/**`，并要求两条发布 workflow 互相列出对方。
- **备注**：
  - 代价一：push 按分支串行后，最新 commit 的 debug 包最多要等正在跑的那一轮结束才开跑。代价二：push debug 通道的 TestFlight 只在「序列 % 3 == 0」那轮上传，那一轮如果被顶掉，这次上传就跳过，下一个整除的序列照常传，也可以用 `testflight_only` 手动补。
  - 服务端只改自身的 PR 不再跑带随包原生库的完整 serve 冒烟（它要冷编 libtorrent），这项冒烟只在共享包变动时由 build-multiplatform 跑。
  - 未在 GitHub 上实跑新 workflow，只做了 YAML 解析、actionlint、守卫测试和 check_release_policy 本地验证。
