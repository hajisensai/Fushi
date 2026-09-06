## BUG-2140 · 第一次查词后 attached 表面再也武装不起来，之后每次点击都穿透并推进剧情
- **报告**：2026-09-03（**用户在真机上直接观察到**：「刚刚好像看到能查到词但是还是会点击穿透」；随后按其描述定向复现）
- **真实性**：✅ 真 bug，真机逐次点击复现，两道闸门已定位，第一道已修，第二道给出确切证据。
- **症状**：BUG-2138 修好后，第一次点字**确实**弹出查词卡且不推进剧情；但从此 attached 表面挂起，用户接着点的每一下都不再被吞——直接落到游戏上推进下一句。
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
  2. **[x] 已修：shield 请求序号卡在 `request=N applied=N-1`，重握手判据永久非中性。**
     修掉第一道后前进到 `suspended/input_shield_rehandshake_pending` 并**永久停在那里**。本轮新加的 `shield` 台账直接读出：
     ```
     shield available=true conclusion=unknown request=4 applied=3
                requiredMask=0x0 readyMask=0x0 observedMask=0x0 statusFlags=0x0
     ```
     `AttachedArmHasConflictingTransaction()`（`low_level_mouse_hook.cpp`）里
     `(status.request_seq != 0 && status.request_seq != status.applied_seq)` 因此恒真 ⇒
     `IsNeutralForRehandshake()` 恒假 ⇒ `EnsureShieldHandshake()` 永远不发新挑战 ⇒ 表面永远回不到 armed。
     **根因（本轮用新加的 `--dump-shield` 从注入侧原始字段读出来的）**：注入侧
     `ProcessGenericLookupInputShield()` 里
     ```cpp
     const bool release_waiting = request.active_buttons == 0 &&
                                  (pending != 0 || exact.pending_publication);
     if (release_waiting) { PublishGenericShieldStatusPayloadOnly(...); return; }  // 不推进 applied_seq
     ```
     `pending` 来自 `GenericShieldPendingMask()`，而 latch 的 ownership 有**两个来源**：
     一是真实采样到按下，二是 `PreArmLeftButtonShieldLatch()` 的**推测预武装**（为了不漏掉
     「物理点击比注入线程看到 v19 请求更早完成」那一拍，必须先占住每个 required+ready+observed 的面）。
     推测占住的 latch 只能靠 `ObserveLeftButtonNeutralTail()` 解开，而那要求该输入面**再次被游戏采样**
     并先后看到释放与中性尾。真机 WoH 上 KeyState 面（0x04）被预武装后**再没被采样过**
     （`required=0xe4 ready=0xe4 observed=0x04 fault=0`，`active_buttons=0`），于是
     `pending` 恒为 0x04 ⇒ `release_waiting` 恒真 ⇒ `applied_seq` 永远停在 `request_seq-1`。
     **一次推测预武装就把整条通路永久锁死。**
- **[x] ② 已修复** — 给 `LeftButtonShieldLatch` 加 `speculative` 位：`PreArmLeftButtonShieldLatch` 置真，
  五个真实采样点（`FilterSampledLeftButtonState` 等）坐实 ownership 时清零。新增
  `AbandonSpeculativeLeftButtonLatch()`：**宿主已发布中性请求（`active_buttons==0`）且该 latch 仍是
  纯推测、从未见过释放**时才放弃它；`ProcessGenericLookupInputShield()` 在算 `pending` 之前调用。
  被真实按下坐实过的 latch 一律保留 —— **「绝不暴露游戏没看见的 down 的尾巴」这条不变式一字未改**，
  只是不再让**没有任何证据支撑的**推测把 `applied_seq` 扣为人质。
- **真机验证（用户自己的 Fushi + 真 WoH，真词典 / 真语音 / AnkiConnect 在线）**：
  ```
  修前：click #1 后 → suspended/input_shield_rehandshake_pending，此后每次点击穿透并推进剧情
  修后：shield request_seq=2 applied_seq=2 → 连点三次全程 activeAttached、序号始终相等
        点表面内一次：台词 id 点击前 #9 / 点击后 #9  ← 剧情未推进，点击被吞
        查词卡弹出并命中真实词典（JA Wikipedia + Pixiv Light 两部，词条「よ」）
        shield request_seq=4 applied_seq=4 owner_kind=2(AttachedGlyph)
  ```
  证据截图：`.codex-test/real/full2.png`（卡片 + 工作台 `状态: activeAttached / 原生状态: visible`）。
- **[x] ③ 同轮补齐的量具（第二道闸门能被一次读出的唯一原因）**：
  - `low_level_mouse_hook.cpp`：attached 抢单例的 5 个闸门逐条报因（`hit_snapshot_missing` / `hit_snapshot_owner_mismatch` / `injected_shield_target_not_prepared` / `hook_thread_unavailable` / `singleton_owned_by_other_hwnd` / `conflicting_transaction_pending`），经 `LastAttachedGlyphArmFailure()` 带进 `SetState` 的 reason；此前 5 条全挤在一句 `low_level_mouse_singleton_busy_or_unavailable` 里。
  - `fushi/integration_test/gal_realgame_driver_itest.dart`：新增 `shield` 指令，打印 available / conclusion / request / applied / required / ready / observed / fault / statusFlags。**`request=4 applied=3` 就是它读出来的。**
- **备注**：`engine-support.yaml` 的 `hunex_gge` 不因本条提升。当前真机链路：`process_found → helper_ready → ipc_ready → text_ready ✅ → 线程选定 ✅ → 风险接受 ✅ → 校准 ✅ → activeAttached ✅ → 首次点字查词 + 不推进 ✅ → 后续点击持续被吞 ❌（本条第 2 道闸门）`。
- **关联**：[[BUG-2138]]（修好它才走到本条）、[[BUG-2143]]（同一条「状态不带原因就无法定位」的纪律）、[[BUG-2125]]（attached 四项行为的原始声明，本条说明其中「持续吞点击」在日文真机上此前未真正成立）。
