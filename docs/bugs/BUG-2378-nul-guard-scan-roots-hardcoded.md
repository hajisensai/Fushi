## BUG-2378 · 裸 NUL 守卫的扫描根写死包清单，新包与 packages/*/test 全在扫描面之外

- **报告**：2026-09-09（用户：审 PR #1316 时发现）
- **真实性**：✅ 真 bug。根因 `fushi/test/tools/dart_source_no_raw_nul_guard_test.dart:44`（旧版 `const List<String> _scanRoots`）。

  扫描面是一份**字面量清单**：`fushi/lib`、`fushi/test` 加五个 `packages/<包名>/lib`。两个后果：

  1. **新包整包不在扫描面内。** PR #1316 新增 `packages/fushi_server/`，其
     `lib/src/subscription_host.dart` 里 `.join('…')` 那个参数是一个**真的 0x00 字节**（不是转义序列）。
     git 的二进制探测见到 NUL 即判 binary → `git merge` 拒绝三方合并、保留 ours 标 CONFLICT
     且**不写冲突标记** → 粗心一解就把对方整片改动静默丢掉（BUG-1145 的同款事故形状）。
     而本守卫正是为防这件事而生的，它却照常绿——因为它压根没看那个目录。
  2. **`packages/*/test` 一直全部漏扫。** 清单里每个包只登记了 `lib`。NUL 的危害是**文件层面**的，
     跟这个文件是产品代码还是测试代码毫无关系；PR #1316 新增的 6 个 `packages/fushi_server/test/*.dart`
     同样不在扫描面内。

  这就是「字面量写死接线」的典型退化：清单方向写反了——枚举的是「自有包」（准入制），
  于是新增包必须有人**回来改这个清单**才会被覆盖，而没有任何机制提醒他。守卫因此静默变瞎，
  且表现为一直绿。

- **[x] ① 已修复** — commit `d402a3ca6b`。扫描根改为**从磁盘枚举**：
  `fushi/{lib,test}` + `packages/<非 vendored 包>/{lib,test}`，并把清单方向翻过来——
  改成一份**排除**清单 `_vendoredPackages`（fork / vendored / stub 三个上游包），其余**默认落进**扫描面。
  新加的自有包从此自动被覆盖，无需任何人记得回来改。只登记磁盘上真实存在的目录，
  避免空壳目录撑出虚高的扫描根数去骗过哨兵。

- **[x] ② 已加自动化测试** — 同文件内的两条规模哨兵（`expectScanScale`）。
  关键是**两条缺一不可**：`fushi/{lib,test}` 一家就有 4300+ 个 `.dart`，足以单独顶穿任何
  文件总数下界，那时 `packages/` 的覆盖已经归零而守卫照样绿。所以包数单独钉一条
  （实测 6 个非 vendored 包，下界 5），文件总数另钉一条（实测 4589，下界 3600）。

  **变异实测**（不是「跑了绿」就算数）：在 `packages/fushi_server/lib/src/subscription_host.dart`
  和 `packages/fushi_core/test/` 各造一个含裸 NUL 的文件，守卫如实变红并同时点名两处；
  删掉变异体后恢复全绿。旧版守卫对这两个路径都是瞎的。

- **备注**：与 BUG-2379 是同一个根因模式（写死的扫描面 = 静默变瞎的门）的两处不同实例，
  一并在同一分支修。PR #1316 本身仍不能合，见该 PR 的审查评论（NUL 字节、CI 漏跑、
  分支落后 develop 150+ commit 且 ASR 依赖还钉在已改名的旧仓）——那三件要作者来处理，
  本条只修「守卫为什么没拦住」。
