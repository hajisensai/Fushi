## BUG-2089 · HUNEX 投影链的 compose wrapper 锚点在 WoH 上从未被调用，整条几何证据无从产生
- **报告**：2026-09-03（BUG-2088 把选中文本绑定打通、边界推进到投影段后，继续逐段收敛得出）
- **真实性**：✅ 真 bug，**已用真机计数直接证明**，不是推断。
- **定位过程（三轮收敛，每轮都靠新增诊断而非猜测）**：
  1. BUG-2086 修好文本链后，worker 侧只报一个笼统的 `kHunexGgeLookupWorkerProjectionRejected`，读不出九选一的原因 → 本轮给 `BuildHunexGgeClientProjection` 的每个拒绝点补失败码（`kWorker` 段，25..33），其中「证据身份」原本是**九个子条件的合取**，拆成了 unavailable / story / thread / client / stale 五类。
  2. 真机读出 **`stage:5(worker),failure:27(worker_evidence_unavailable)`** —— 投影证据**根本不存在**，即 sprite draw 那一段从未成功发布过证据。
  3. 但 trace 里 `stage:1..4` **一条事件都没有**，而这些诊断只在「能归属到某条语义行」时才发，所以「零事件」既可能是从没被调用、也可能是调用了但当时没有待定故事行——两者排障方向完全相反。于是本轮再补**无条件调用计数**（trace 头部 v4 新增四个 `int64`）。
- **根因（真机计数，WoH pid=35148，helper `voice_hook_x64.zip` sha256 `a977b8fb…864731b2`）**：
  ```
  calls={draw:2, glyph:250, render_item:118, input:868951,
         compose_wrapper:0, texture_upload:244563,
         quad_vertex:158167, sprite_draw:306305}
  ```
  **`surface_compose_wrapper` 被调用 0 次**，而 texture upload / quad vertex / sprite draw 各被调用二三十万次。结构扫描却报 `surface_compose_unique` + `surface_compose_calls_valid` + `surface_compose_hooks_ready`（scanner `0x0001ffff` 全绿）——**hook 装上了，函数却从来不执行**。
  这直接解释了整条链：`Detour_HunexGgeSurfaceComposeWrapper` 是唯一把 `wrapper_scope` 置真的入口（`BeginHunexGgeSurfaceComposeContext(..., /*wrapper_scope=*/true)`），而 `Detour_HunexGgeSurfaceCompositor` 的候选相关性判据里硬要求 `context.wrapper_scope`。wrapper 不跑 ⇒ `wrapper_scope` 恒假 ⇒ compositor 不产生候选 ⇒ `g_hunex_gge_pending_surface_chain` 永不 active ⇒ texture/quad 两段我在 BUG-2087 补的诊断（都以 `pending.active` 为前提）也永不触发 ⇒ sprite draw 永不发布投影证据 ⇒ worker 恒报 `worker_evidence_unavailable`。**一个锚点假阳性，让后面五段集体静默。**
  换言之：**该 masked-pattern 在 WoH 的可执行段里确实唯一命中，但命中的那个函数不在 WoH 正文的真实合成路径上。**「结构唯一」不等于「就是它」——这是扫描器设计里此前没有被证伪过的隐含假设。
- **[x] ① 已修复（仅量具与可证伪性，几何行为未改）** — 本轮**不动任何投影判据**，因为在锚点被纠正之前改下游都是盲改：
  - `include/hunex_gge_trace.h`：新增 `HunexGgeProjectionTraceStage::kWorker` 与 9 个 worker 段失败码；trace 版本 v3→v4，头部增加 `surface_compose_wrapper_calls` / `texture_upload_calls` / `quad_vertex_calls` / `sprite_draw_calls` 四个无条件计数（`slots` 偏移 184→216，同步更新 `static_assert` 与测试里的镜像断言；probe 侧镜像结构逐字段同序补齐，probe 与 helper 同源构建、版本不匹配即拒读）。
  - `hook/adapters/hunex_gge_adapter.inc`：`BuildHunexGgeClientProjection` 每个拒绝点补报点（判据与控制流一字未动）；四个投影 detour 入口各加一次计数；投影诊断去重表 4→5 段，发布器 stage 上界 4→5。
  - `tools/ring_probe.cpp`：打印 `worker` 段名、9 个新失败码名，以及四个调用计数。
- **[x] ② 已加自动化测试** — 本条是纯诊断/计数补全，无行为不变式变化，由既有守卫整批兜底并全部重跑：x64/x86 双架构 `ctest` 各 56/56 通过；`hunex_gge_trace.h` 自带的 static_assert 与 `tests/hunex_gge_lookup_test.cpp` 的布局断言在编译期钉住 v4 ABI（`slots` 偏移写死 216）；`adapter_structure_test.py` / `engine_support_manifest_test.py` / `assert_liveness_guard_test.py` / `evidence_contract_test.py` 与两个生成器 `--check` 全绿。
- **[ ] ③ 未修复：正确的 compose 锚点尚未找到** — 这是本条留下的真正实现工作。要让 WoH 发布几何，必须先回答「WoH 的正文行到底经由哪个函数合成到目标表面」，候选做法：
  1. 用 `sprite_draw` / `texture_upload` 的真实调用点反查其调用者（trace 已有 `caller_rva`/`outer_caller_rva` 机制），从下往上找真实的合成入口，替换或补充 `kSurfaceComposeWrapperPattern`；
  2. 检查现有 wrapper 模式是否命中了某条**同形但不在正文路径**的函数（例如工具栏/立绘合成），必要时把「唯一命中」升级为「唯一命中且运行期被调用过」——扫描期就能证伪的假阳性不该等到运行期才暴露；
  3. 若 WoH 的正文根本不走 wrapper 形态，则 `wrapper_scope` 这个硬前提需要重新设计（compositor 相关性判据当前完全依赖它）。
  **建议顺路加一条扫描期/启动期守卫**：hook 装上后若某个被判为「必经」的锚点在 N 秒内调用数仍为 0，应主动降级并上报，而不是让下游五段静默失败——本轮正是因为缺这条，才花了三轮真机才定位到。
- **备注**：`engine-support.yaml` 的 `hunex_gge` 不因本条提升，仍 `implemented_unverified`。本条同时**证伪**了 BUG-2087 备注里排的嫌疑顺序（段 2 的 compose destination 代数、段 5 的 `render_target == backbuffer`）——那些判据一次都没被执行到，谈不上成立与否。真机链路当前状态：`process_found → helper_ready → ipc_ready → text_ready ✅ → text_thread_selected ✅（需手动选，见 BUG-2088 备注）→ 选中文本绑定 ✅ → 投影证据 ❌（本条）`。
