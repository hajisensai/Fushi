# 单元测试跨机分流（dist_test）设计

日期：2026-10-24　状态：设计稿，未实现

## 目标与边界

把 `fushi/test/` 全量单测（约 4.4k 个 suite，CI 实测串行合计 ≈48 suite-分钟）自动分到多台机器上并行跑，结果汇总成一份与 `tool/flutter_test_failures.dart` 同口径的报告。

机器（所有者 2026-10-24 确认）：

| 机器 | 角色 | 网络 |
|---|---|---|
| 本机 Windows（RTX 5090 那台） | **协调者** + worker | — |
| 自己的 Mac（M4 Air，`shfaifsj@192.168.1.34`） | worker | 局域网，SSH 已通 |
| 朋友的 Windows | worker | 异地，Tailscale |
| 朋友的 Mac | worker | 异地，Tailscale |

已定前提：

- 只做 `fushi/test/` 单元测试；集成测试（`integration_test/`，要真 app / 显示器 / 模拟器）放第二期。
- Windows 与 Mac 的结果合并算一次全量；平台相关的 suite 钉在对应平台跑（见「亲和性」）。
- 朋友的机器随时可派活，但限并发、限内存，朋友随时可一键暂停。
- **连接方向只允许 协调者 → worker**。朋友的机器任何情况下都不能连到本机：本机不开入站端口、不跑 sshd、不做反向转发、不转发 ssh-agent。

## 总体结构

```
本机（协调者）  dart tool/dist_test.dart
   │  1. 打快照提交（含未提交改动，剔除密钥真值）
   │  2. git push 快照 → 各 worker 的裸仓（经 SSH）
   │  3. 按实测耗时切批次，放进按平台分的队列
   │  4. 每个 worker 槽位循环：ssh 领一批 → 跑 → 流式回传 json 事件
   │  5. 汇总、判绿、刷新各机器耗时表
   ▼
 worker：常驻 checkout + pub cache + 原生库缓存，只做 checkout/跑测试
```

协调者是一个 Dart CLI（`fushi/tool/dist_test.dart` + `fushi/tool/test_flow/dist_*.dart`），复用现有部件：

- 切分权重：`suite_timings.json` + `suiteShardWeights`（`tool/test_flow/suite_timings.dart`）；
- 判绿口径：`flutter_test_failures.dart` 的失败过滤与「实际执行数 ≥ min-tests」；
- 本机重活：本机 worker 槽位一律经 `tool/heavy.dart` 租约，与其它会话共享槽位。

## 1. 代码同步：快照提交

worker 必须跑**和本机完全一致**的代码，包括没提交的改动。

1. 用临时索引造快照：`GIT_INDEX_FILE=<scratch>/dist.index`，`git read-tree HEAD` → `git add -A -- . ':!<排除清单>'` → `git write-tree` → `git commit-tree -p HEAD`，得到快照 SHA；不碰真实索引、不动 stash（stash 栈全 worktree 共享）。
2. **密钥真值硬排除**：排除清单 = `git ls-files -v | grep '^S'`（所有 skip-worktree 文件，即 `setup_worktree.ps1` 搬进来的 `google_oauth_secret.dart` / `log_upload_secret.dart` 等）。临时索引里这些文件**没有** skip-worktree 位，不排除的话 `git add` 会把真值加进快照推到朋友机器上——这是本设计最危险的一步，必须有守卫：
   - 协调者推送前对快照逐一核对：排除清单里每个路径在快照树里的 blob 必须等于 HEAD 里的 blob（即入库占位值），不等就中止；
   - 契约测试 `fushi/test/tools/dist_snapshot_secret_guard_test.dart`：临时仓里造一个 skip-worktree 文件写入假真值，断言快照树里仍是占位值（并做变异实测：去掉排除逻辑必须变红）。
3. 推送：每台 worker 有一个裸仓 `~/fushi-dist.git`，`git push <worker> <sha>:refs/dist/<runId>`。增量推送，平时只传几十 KB；首次用 `git bundle` 离线带过去或让 worker 直接从 GitHub clone（Mac 经代理拉大增量会断，见 CLAUDE.local.md，首次走局域网推）。
4. worker 常驻 checkout `~/fushi-dist/work`：`git checkout --detach --force <sha>` + `git clean -fdx -e .dart_tool -e build -e native/*/prebuilt`，保留缓存。跑完删 `refs/dist/<runId>`，裸仓定期 `gc`。

## 2. worker 环境

每台 worker 一次性准备（脚本 `tool/dist_test/worker_setup.ps1` / `worker_setup.sh`，在 worker 上由其所有者执行）：

- Flutter **3.47.6**（与 `.fvmrc` 一致；协调者每次领活前比对 `flutter --version`，不一致拒绝派活）；
- Rust 工具链（编 `fushi_compute` / `fushi_fsrs` / `fushi_web_core` / `fushi_rwkv` 四个测试硬依赖）；
- 专用低权限账户 `fushitest`（Windows 为普通用户，Mac 为 standard user），所有文件只落它的 home。

每轮跑之前 worker 侧的「准备」步骤，按内容哈希缓存，命中就跳过：

| 步骤 | 缓存键 | 未命中耗时（估） |
|---|---|---|
| `flutter pub get --enforce-lockfile` + `ci/apply-patches.sh` | 全部 `pubspec.lock` + `ci/patches/` 哈希 | 1–2 分钟 |
| 原生测试库 | 各 `native/fushi_*/` 源码树哈希（同 `tool/native_libs.ps1` 的判据） | 首次 5–10 分钟，之后增量 |

准备失败的 worker 本轮直接退出队列，批次由其它机器接走；报告里写明哪台、为什么。

## 3. 调度：动态批次队列

不用静态 `--file-shard=i/N`：四台机器快慢不一、朋友的机器可能中途离线，静态切分会被最慢的一台拖住。

- **批次**：按 `suite_timings.json` 的耗时，把 suite 依 LPT 顺序（重的在前）装成约 3 suite-分钟一批（约 40–80 个文件）。每批是一次 `flutter test --no-pub --reporter json <files...>`，摊薄每次进程启动与编译预热的固定开销；批太小开销占比高，太大尾部不均。批大小是参数，首轮实测后定。
- **槽位**：每台 worker 配 `slots`（同时跑几个 `flutter test` 进程）。每个槽位是协调者里的一个循环：从自己能接的队列取一批 → 一次 ssh 执行 → 读回 json 事件流 → 取下一批。快机器自然多领。
- **亲和性**（「平台相关的钉住」）：每个 suite 算出可跑的平台集合，进对应队列：
  - `@TestOn(...)` / `onPlatform:` / 文件内 `Platform.isWindows` / `isMacOS` / `isLinux` 门控（静态扫描，约 200 个文件）→ 只进对应平台队列；同时门控两个平台的文件在两个平台**各跑一次**；
  - `golden` 标签 → 只进参考平台（本机 Windows）；
  - `realdata` 标签（要本机真素材）→ 只进本机；
  - `ffmpeg` / `chrome` 标签 → 只进声明了该能力的 worker（worker 配置里 `capabilities`，准备阶段实测 ffmpeg / node+Chrome 能起才算）；
  - 其余 → 公共队列，任何 worker 都能接。
  - 静态扫描会漏：汇总时若某 suite 的 skip 原因带平台字样（json 事件里的 `skipReason`），记进 `tool/test_flow/suite_affinity.json`（入库，下次直接钉），报告里列出来。
- **掉线与超时**：ssh 断开或单批超过「预估耗时 × 3 + 5 分钟」→ 杀掉该批（按进程树）→ 原样放回队列头，换机器重跑；同一批连续在两台机器上失联才判失败。只对**失联**重派，测试失败不重试（见下）。
- 尾部：队列空了以后，仍在跑的批次不复制推测执行（会白占朋友的机器），由它跑完。

## 4. 判绿与失败分型

- 绿 = 所有批次退出码为 0 **且** 汇总执行数 ≥ 本轮预期 suite 里的测试数下限 **且** 每个排进队列的 suite 都有 `suite` + `done` 事件。任何 suite 没有结果（零执行）一律算红，不能被当成通过（BUG-1157 同一个坑）。
- 测试失败**不自动重跑掩盖**。失败的 suite 在汇总后自动在**另一台同平台机器**上单独再跑一次，只用于分型、不改变结论：
  - 两台都红 → 真红；
  - 只在一台红 → 报告标「仅 <机器> 红」，附两份输出，留给人 / reviewer 按 `docs/agent/fast-workflow.md`「并发伪红判别」分型。本轮结论仍是红。
- 报告落 `.codex-test/dist/<runId>/`：`summary.md`、每批原始 json 事件、每台机器的准备日志。终端只打总表和失败清单。

## 5. 耗时表与机器速度

- 汇总后用各批 json 事件里的 suite 耗时刷新本地的 `tool/test_flow/suite_timings.local.json`（不入库，按机器分列）；切批时用「该 suite 在目标机器的实测值」，没有则用 CI 值 × 该机器的速度系数（系数 = 该机器所有已测 suite 的中位比值）。
- 入库的 `suite_timings.json` 仍只由 CI 事件刷新（`update_suite_timings.dart`），不混入个人机器数据。

## 6. 朋友机器的资源约束

- 默认 `slots: 1`，每个 `flutter test` 带 `--concurrency=<n>`（默认 `n = 逻辑核数 / 2`），内存封顶沿用 `heavy_budget.dart` 的判据：worker shim 领活前读空闲内存，低于阈值就回「忙」，协调者把该批让给别人，30 秒后再问。
- **朋友侧暂停开关**：worker 机上 `~/.fushi-worker/pause` 文件存在即拒绝领活（shim 第一步检查）。朋友不需要懂任何东西，建个空文件或跑 `fushi-worker pause` 即可；正在跑的批次被他 kill 掉会被当成失联，自动转给别的机器。
- 只在 `fushitest` 账户下跑，不装服务、不开机自启；工作目录与缓存总量设上限（默认 30 GB），超出时清最旧的缓存。

## 7. 安全模型（重点）

威胁有两个方向，分别处理。

### 7.1 保护本机（朋友的机器不能碰到你的电脑）

- **网络单向**：朋友在**他自己的** Tailscale tailnet 里，用 Tailscale 的「共享机器（node sharing）」把他的两台机器分享给你的账号。共享是单向的：你的设备能连被共享的机器，被共享的机器连不进你的 tailnet。不要让朋友加入你的 tailnet，也不要反过来共享本机。在你 tailnet 的 ACL 里再加一层：只允许本机访问共享进来的那两台的 22 端口。
- **本机不开任何入站**：不装 / 不启用 sshd，不做 `ssh -R` 反向转发；协调者生成的 ssh 命令统一带 `-o ForwardAgent=no -o ForwardX11=no -o ClearAllForwardings=yes -o PermitLocalCommand=no`，并在 `~/.ssh/config` 对这两台写死同样的选项。**ssh-agent 转发是最容易被忽略的口子**：一旦转发，朋友机器上的管理员能借你的 agent 以你的身份登录你的其它机器 / GitHub。
- **专用密钥**：给分流单独生成一把 `~/.ssh/fushi_dist_ed25519`，只用于这两台，不复用你登录 GitHub / Mac 的那把。泄露最坏只影响这两台 worker。
- **不带出任何秘密**：快照剔除密钥真值（第 1 节守卫）；ssh 不传环境变量（不设 `SendEnv`），协调者不把 `HTTPS_PROXY` 等本机配置传过去；worker 侧测试只用入库占位值，与 CI 一致。
- **回传内容是不可信数据**：worker 回来的只有 json 事件流与日志文本。协调者严格按 json 解析，只读字段、不执行回传内容中的任何命令或路径；写报告时路径一律落在 `.codex-test/dist/<runId>/` 之下（拒绝 `..`）。

### 7.2 保护朋友（你只能在他机器上做「跑测试」这一件事）

- 朋友的 `fushitest` 账户 `authorized_keys` 里这把 key 写成：
  `restrict,command="~/.fushi-worker/shim" ssh-ed25519 AAAA... fushi-dist`
  `restrict` 关掉端口转发 / agent / X11 / pty；`command=` 强制所有连接只能进 shim。
- shim（`tool/dist_test/worker_shim.sh` / `.ps1`，朋友装之前可以通读，脚本很短）只认几个动词，参数逐个校验：
  - `hello` → 回报平台、Flutter 版本、核数、空闲内存、能力、是否暂停；
  - `git-receive` → 只允许 `git-receive-pack '~/fushi-dist.git'`（推快照）；
  - `prepare <sha>` → checkout + pub get + 原生库（只在 `~/fushi-dist/` 内）；
  - `run <sha> <batchId>` → 从 stdin 读文件清单，每行必须匹配 `^test/[A-Za-z0-9_/.-]+_test\.dart$` 且文件存在，然后跑 `flutter test`，stdout 回 json 事件；
  - `cleanup <runId>`。
  其它一律拒绝。你拿到这把 key 也开不了 shell。
- 需要明说的残余风险：测试代码本身就是你仓库里的任意 Dart 代码，shim 管不住测试里写了什么。朋友在给你跑代码，信任关系是「朋友信任你提交的代码」；专用低权限账户把影响限制在 `fushitest` 的 home 里。

### 7.3 自己的 Mac

已有 `shfaifsj@192.168.1.34` 免密登录，是你自己的机器，不走 shim，协调者直接 ssh 执行同样的步骤。但仍用快照剔除密钥（规则统一，不为自己的机器开例外），并遵守 CLAUDE.local.md 里的 PATH 拼法（非交互 ssh 不读 `~/.zshrc`，`$HOME/flutter_3.47.6/bin` 放最前）。

## 8. 配置

`fushi/tool/dist_test/workers.local.json`（`.gitignore` 排除，只在本机）：

```json
{
  "workers": [
    { "name": "self-win", "kind": "local", "os": "windows", "slots": 2, "capabilities": ["ffmpeg", "chrome", "golden", "realdata"] },
    { "name": "self-mac", "kind": "ssh-trusted", "host": "shfaifsj@192.168.1.34", "os": "macos", "slots": 2,
      "path": ["$HOME/flutter_3.47.6/bin", "/opt/homebrew/bin", "$HOME/.cargo/bin"] },
    { "name": "friend-win", "kind": "ssh-shim", "host": "fushitest@friend-win.<tailnet>.ts.net", "os": "windows", "slots": 1,
      "identity": "~/.ssh/fushi_dist_ed25519" },
    { "name": "friend-mac", "kind": "ssh-shim", "host": "fushitest@friend-mac.<tailnet>.ts.net", "os": "macos", "slots": 1,
      "identity": "~/.ssh/fushi_dist_ed25519" }
  ]
}
```

用法：

```
cd fushi
dart tool/dist_test.dart                 # 全量
dart tool/dist_test.dart test/reader     # 只分流某个子树
dart tool/dist_test.dart --workers=self-win,self-mac
dart tool/dist_test.dart --status        # 各 worker 在线 / 暂停 / 版本 / 缓存
```

## 9. 预期收益（估算，需实测）

- 串行合计 ≈48 suite-分钟（CI Linux 口径）。本机单跑全量时编译 + 加载是大头，四台机器有效并行后，理想情况在 **8–12 分钟**（每台约 1/4 工作量 + 每台 1–2 分钟固定开销 + 跨网尾部）。朋友机器的速度和上行带宽决定最后能压到多少，第一期跑完用实测替换这里的估算。
- 只改了一个子树时直接 `dist_test.dart test/<子树>`，批次少于 worker 数时自动只用最快的几台。

## 10. 分期

1. **第一期：本机 + 自己的 Mac**（都在局域网、都是自己的机器）。实现快照 + 推送 + 准备缓存 + 动态队列 + 亲和性 + 汇总判绿，跑通全量并拿到两台机器的真实耗时与速度系数；契约测试：快照密钥守卫、批次切分覆盖（并集 = 全部 suite、无重复）、亲和性扫描、json 事件汇总（含零执行判红）。
2. **第二期：接入朋友的两台**。worker_setup 脚本、shim、Tailscale 共享 + ACL、暂停开关、资源上限；用 `--status` 和一次子树分流验证，再跑全量。
3. **第三期**：失败分型的跨机复跑、`suite_affinity.json` 自动回写、按需加入集成测试（单独设计）。

## 待实测确认

- Windows OpenSSH 会话里跑 `flutter test`（无桌面会话）是否有个别单测依赖窗口站 / 字体服务；有就记进亲和性钉回本机。
- Tailscale 共享机器的单向性在你和朋友的实际账号上验证一次：从朋友机器 `tailscale ping` / `ssh` 你的本机应当不通。
- 每批进程固定开销（启动 + 编译预热）的真实值，决定批大小。
