## BUG-2137 · attached 子面回 `noGlyphClusters` 时撤回了跨轮次共享的 provider 认领，与 BUG-2142 是同一个活锁的另一道门
- **报告**：2026-09-03（BUG-2142 修好之后，WoH 上仍然稳定停在 `suspended/geometryProviderPending`，用 BUG-2143 补的 reason + 本轮新加的准入输入日志一路追到）
- **真实性**：✅ 真 bug，真机日志逐毫秒复现，且**修 BUG-2142 之后依然存在**——那条修的是「被抢占的旧轮次去撤回」，这条是「一条本该是瞬态的子面状态去撤回」。
- **定位过程**：BUG-2142 只记了结论 `attachedReady=true→false`，而 `attachedReady = lookupSurfaceActive && attachedProviderClaimed` 是**两个输入的合取**，只看结论分不清是「宿主没认领」还是「查词面整体没武装」，两者排障方向完全相反。本轮先把两个输入一起打进日志，答案当场出来：
  ```
  20:22:00.125  attachedReady=true   lookupSurfaceActive=true claimed=true   status=waitingForBodyThread/null
  20:22:00.133  attachedReady=false  lookupSurfaceActive=true claimed=false  status=fallback/noGlyphClusters   ← 8ms 后
  20:22:00.554  attachedReady=false  lookupSurfaceActive=true claimed=false  status=suspended/geometryProviderPending
  ```
  `lookupSurfaceActive` 全程为真，**变的只有 claimed**，且随之而来的状态是 `fallback/noGlyphClusters`——一条子面状态事件把认领撤了。
- **根因**：`fushi/lib/src/lookup/gal_attached_text_controller.dart` 的 `handleSurfaceStateChanged` 里 `case 'noGlyphClusters'` 无条件调 `_activationFailure(...)`，而 `_activationFailure` 会 `_setAttachedProviderClaim(false)`。`_attachedProviderClaimed` 是**跨轮次共享**、经 `lookup_geometry_admission_flags` 发布给注入侧 registry 的单一状态；撤掉之后 registry 永远不把 `kind=4/id=11` 判成 ready，而宿主的 `_evaluateAndActivate` 又在等这个 ready 才肯进 `activeAttached`——两边互等成活锁，**此后每一行都救不回来**。
  子面那侧（`fushi/windows/runner/attached_text_surface_window.cpp:1689,1695`）发的是 `SetState("ready", "noGlyphClusters")`，语义本来就是「本轮建不出簇」，state 是 `ready` 而不是 error——它从来没说过通路坏了。
- **[x] ① 已修复** — `_activationFailure` 新增 `withdrawClaim`（默认 true，其余七个调用点行为一字不变），`noGlyphClusters` 这一条传 `withdrawClaim: false`：**fail-closed 的部分全部保留**（面照旧隐藏、状态照旧降级成 `fallback`/`suspended`），只是不再动那份共享认领；认领的释放仍由当前轮次的 detach / 真失败分支负责。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_attached_text_controller_test.dart` 新增「BUG-2137 正文推送前的 noGlyphClusters 不得撤回共享认领」：同步一轮拿到认领 → 子面回 `noGlyphClusters` → 断言认领仍在、面已隐藏、状态已降级 → 再收到 `kind=4/id=11` 的 ready 后能正常收敛到 `activeAttached`。**变异实测**：去掉 `withdrawClaim: false` 当场红。既有契约测试「no glyph clusters fail closed and source text cannot forge visibility」保持绿（43/43），证明 fail-closed 语义没有被放宽。
- **关联**：[[BUG-2142]]（同一活锁的第一道门：被抢占的旧轮次撤回认领）、[[BUG-2143]]（本条能被定位全靠它补的 reason token）。
