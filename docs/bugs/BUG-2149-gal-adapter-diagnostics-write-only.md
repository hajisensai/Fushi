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

- **备注**：**端到端未验**——写点与读点各自有测试，但「在真游戏上打出那一行」尚未跑过
  （改动时用户在用机器，不启动游戏打断）。桌面空闲后第一件事就是拿 chronoclock 体験版复验，
  那同时就是 CMVS 台账里那条 Next gate。在此之前不得宣称本条面「可用」。
