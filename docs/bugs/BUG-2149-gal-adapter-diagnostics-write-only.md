## BUG-2149 · AdapterDiagnostics 是只写接口：运行期没有消费方，任何引擎都读不出 adapter 是否命中并安装
- **报告**：2026-09-05（自查：ceshi 批量适配时 CMVS 的 Next gate 读不出来）
- **真实性**：✅ 真 bug，根因 `native/galgame_hook/hook/adapter.h:46`（`virtual AdapterDiagnostics diagnostics() const = 0;`）

  **怎么发现的**：CMVS 台账里写的 Next gate 是「探针 `cmvs probe=1 installed=1`」。真机上跑 chronoclock
  体験版时发现**打不出这一对读数**——不是探针失败，是根本没有工具能打。
  顺着查：`AdapterDiagnostics`（`id` / `applicable` / `installed` / `flags`）**每个 adapter 都实现了**，
  但全仓 `grep` 下来只有 `tests/adapter_contract_test.cpp` 在读。运行期零消费方。

  于是这不是 CMVS 一家的事：**任何引擎**都答不出「我的 adapter 到底有没有被选中并安装」。
  而 `native/galgame_hook/CLAUDE.md` 的证据门要求逐门可判（`process_found → helper_ready → …`），
  其中「adapter 认领了没有」正是第一道要判的门。写了没人读的接口，等于这道门在真机上是瞎的。

- **[x] ① 已修复** — IPC 契约 **v22 → v23**：`SharedHeader` 尾部**纯追加**
  `AdapterReportSlot adapter_reports[32]` + `count` + `seq`。
  - 写者唯一：`AdapterRegistry::Poll` → `PublishAdapterReportSnapshot()`，与既有的
    `PublishLookupAdmissionSummary()` 同处、同纪律（内容先写、seq 最后发布）。
  - **槽自带 id 字符串**，不按注册顺序编号：下标制在有人往 `hook/generated/adapter_*.inc`
    中间插一行时会整体错位，而且**不报错**——读数看着正常，说的却是另一个 adapter。
  - 复用**同一份生成清单**（函数内 `consider` lambda + `#include "generated/adapter_admission.inc"`），
    所以脚手架登记的新引擎自动进读数，不存在第二份会漂移的清单。
  - 限速 1 秒：`diagnostics()` 内部会调 `probe()`，而 CMVS / AOS / Unreal 的 probe 要读盘枚举，
    Poll 最快 16 ms 一轮；诊断面没有低延迟需求。
  - 读点：`tools/ring_probe.cpp` 打 `[adapters] seq=N id=probe:x/installed:y`，
    并把「seq==0 未上报」与「上报了但无人认领」明确分开——两者混一起会在 helper 起来前稳定误报。
  - 升版是硬要求：两侧都用 `sizeof(SharedHeader)` 现算 ring / region 基址，新旧混装会整体错位
    而版本门本会放行（与 v22 同理）。两处既有的版本钉（`native_loopback_policy_test`、
    `lookup_ipc_contract_test`）随之更新，并给 v23 块补上同等强度的逐字段布局锁。

- **[x] ② 已加自动化测试** —
  - `tests/adapter_report_guard_test.py`（新，10 条 + 2 条变异自测；已登记进 `tools/run_guards.ps1`）：
    守「**声明的 adapter 成员集合 ⊆ 上报集合**」——最危险的失败形状不是编译错误，而是有人加了
    adapter 却没进读数，读数少一行而没有任何东西会红。另守写点被调用、限速真的比较了时间差、
    发布器清尾部残留槽、ring_probe 存在读点、布局变了必须升版、槽必须自带 id。
  - `tests/lookup_ipc_contract_test.cpp` 新增 `TestAdapterReportRoundTrip()`：未上报读 0 槽、
    正常往返按槽对号、adapter 变少时尾部旧槽必须清零（否则读到上一次的 probe/installed）、
    超长 id 截断且带 NUL、写侧超容量夹住、读侧按自身容量截断。

- **端到端已验（2026-09-05，四个引擎，helper x86 `119ef214…` / x64 `950e0d03…`）**：
  写点（helper DLL）与读点（ring_probe）取自同一次构建——v23 版本门本来就要求这样，否则判不兼容。

  | 游戏 | `[adapters]` 读数 | 其它引擎 |
  |---|---|---|
  | chronoclock 体験版 v2（CMVS） | `cmvs=probe:1/installed:1` | 无 kirikiri / renpy / unity 行 |
  | ATRI -My Dear Moments-（KiriKiri） | `kirikiri_z=probe:1/installed:1` | **cmvs 行整条消失** |
  | Sakura Swim Club（Ren'Py） | `renpy_ffmpeg=probe:1/installed:1` | 无 kirikiri / cmvs |
  | manosaba Ver1.0.3（Unity IL2CPP） | `unity_il2cpp=probe:1/installed:1` | 无 cmvs / renpy |

  第一行正是 CMVS 台账里那条 Next gate「探针 `cmvs probe=1 installed=1`」——它现在读得出来了。
  四局互为跨引擎负样本：每局只有该引擎的 probe 为 1，别家的行因 probe/installed 全 0 被滤掉。

- **顺带查实的一件事：`installed` 是各 adapter 自定义的，`probe:0/installed:1` 不是矛盾。**
  第一次读到 `siglus=probe:0/installed:1`、`reallive=probe:0/installed:1`、
  `kirikiri_z=probe:0/installed:1`（在 CMVS 游戏上）时看着像 bug，查下来是真数据：
  `TryHookSiglusOvk()` 装的是 **KernelBase 文件 API 共享中转**（`CreateFileW/A`/`ReadFile`/
  `CloseHandle`），HUNEX 与 Malie 都复用它，`reallive.install()` 干脆就是
  `installed_ = TryHookSiglusOvk()`。装成功就置 `installed_`，与本局是不是 Siglus 无关；
  Siglus 专属诊断位 `kDiagSiglusOvkHooksReady` 只在确实是 Siglus 时才置。
  **证据**：CMVS 那局 `hookdiag=0x00000c21` 里确实**没有** `SiglusOvkHooksReady`，与该解释一致。
  数据没错，但不解释一定会被读成矛盾——所以读点在**恰好出现这种形状时**打一行说明：
  「installed 含该 adapter 代管的共享中间件；引擎身份只看 probe」。这与本仓对诊断位的既有
  纪律同源：位只能表示它字面上说的那件事。

- **备注**：本条面只解决「读得出来」。各 adapter 的 `installed_` 语义不统一是另一件事，
  本轮**没有**去统一——那要逐个 adapter 重新定义并回归，属独立任务。
