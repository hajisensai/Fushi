## BUG-2098 · 第一次查词后 attached 表面再也武装不起来，之后每次点击都穿透并推进剧情
- **报告**：2026-09-03（**用户在真机上直接观察到**：「刚刚好像看到能查到词但是还是会点击穿透」；随后按其描述定向复现）
- **真实性**：✅ 真 bug，真机逐次点击复现，两道闸门已定位，第一道已修，第二道给出确切证据。
- **症状**：BUG-2095 修好后，第一次点字**确实**弹出查词卡且不推进剧情；但从此 attached 表面挂起，用户接着点的每一下都不再被吞——直接落到游戏上推进下一句。
- **真机复现台账**（WoH v1.0，pid=14372，同一句 `二時間ほど眠っていた事になる。` 上连点四次）：
  ```
  校准后        attached=activeAttached/null
  click #1      行未变（被吞）→ attached=suspended/input_shield_rehandshake_pending
  click #2      行未变
  click #3      行 -2 → -3   ← 穿透，剧情推进
  click #4      行 -3 → -4   ← 穿透，剧情推进
  ```
- **根因（两道独立闸门，串在一条链上）**：
  1. **[x] 已修：`TargetIsForeground()` 把「本进程的查词卡拿到焦点」判成「游戏在后台」。**
     `fushi/windows/runner/attached_text_surface_window.cpp` 的 `TargetIsForeground()` 只认游戏 HWND / 其子窗 / presentation HWND 前台。查词卡是**本进程为这个游戏打开的卡**，它拿到焦点恰恰是「用户刚点了一个词」的**结果**；旧判据于是让第一次查词必然把表面挂起（`suspended/targetBackground`），命中区域随之清空，下一下点击不再被吞。
     修法：放行「带着本游戏 owner 标记的本进程查词卡」——依据是 `SetOutsideClickConsumeOwner` 落在卡片 HWND 上的 `kConsumeOutsideOwnerProperty`（**已有的身份链**，不是「同 PID」这种弱判据）；新增 `fushi::IsLookupCardConsumingForOwner()`。alt-tab 到 Fushi 主窗时表面照旧挂起，判据没有被放宽。
     真机验证：`targetBackground` 不再出现。
  2. **[ ] 未修：shield 请求序号卡在 `request=4 applied=3`，重握手判据永久非中性。**
     修掉第一道后前进到 `suspended/input_shield_rehandshake_pending` 并**永久停在那里**。本轮新加的 `shield` 台账直接读出：
     ```
     shield available=true conclusion=unknown request=4 applied=3
                requiredMask=0x0 readyMask=0x0 observedMask=0x0 statusFlags=0x0
     ```
     `AttachedArmHasConflictingTransaction()`（`low_level_mouse_hook.cpp`）里
     `(status.request_seq != 0 && status.request_seq != status.applied_seq)` 因此恒真 ⇒
     `IsNeutralForRehandshake()` 恒假 ⇒ `EnsureShieldHandshake()` 永远不发新挑战 ⇒ 表面永远回不到 armed。
     **注入侧同时报 `lookup_gate=0x0f{requested,profile_admitted,input_hook_ready,shield_ready}`** ——两侧对「shield 是否就绪」的看法相反：注入侧认为就绪，宿主认为还有一笔没应答的请求。**下一步就是查「宿主发出的第 4 号 shield 请求为什么没被注入侧 apply」**（请求发布/消费两端在 `voice_hook_ipc.h` 的 shield 槽位与 hook 侧的应答路径）。
- **[x] ③ 同轮补齐的量具（第二道闸门能被一次读出的唯一原因）**：
  - `low_level_mouse_hook.cpp`：attached 抢单例的 5 个闸门逐条报因（`hit_snapshot_missing` / `hit_snapshot_owner_mismatch` / `injected_shield_target_not_prepared` / `hook_thread_unavailable` / `singleton_owned_by_other_hwnd` / `conflicting_transaction_pending`），经 `LastAttachedGlyphArmFailure()` 带进 `SetState` 的 reason；此前 5 条全挤在一句 `low_level_mouse_singleton_busy_or_unavailable` 里。
  - `fushi/integration_test/gal_realgame_driver_itest.dart`：新增 `shield` 指令，打印 available / conclusion / request / applied / required / ready / observed / fault / statusFlags。**`request=4 applied=3` 就是它读出来的。**
- **备注**：`engine-support.yaml` 的 `hunex_gge` 不因本条提升。当前真机链路：`process_found → helper_ready → ipc_ready → text_ready ✅ → 线程选定 ✅ → 风险接受 ✅ → 校准 ✅ → activeAttached ✅ → 首次点字查词 + 不推进 ✅ → 后续点击持续被吞 ❌（本条第 2 道闸门）`。
- **关联**：[[BUG-2095]]（修好它才走到本条）、[[BUG-2092]]（同一条「状态不带原因就无法定位」的纪律）、[[BUG-2053]]（attached 四项行为的原始声明，本条说明其中「持续吞点击」在日文真机上此前未真正成立）。
