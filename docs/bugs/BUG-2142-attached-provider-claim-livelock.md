## BUG-2142 · 被抢占的旧轮次撤回 attached provider 认领，与注入侧 registry 形成活锁
- **报告**：2026-09-03（在 WoH 上走 attached 兜底路径时定位；**不是 HUNEX 专有**，attached 是六款游戏共用的兜底）
- **真实性**：✅ 真 bug，根因在 `fushi/lib/src/lookup/gal_attached_text_controller.dart` 的 `_claimAttachedProvider`，并有真机日志复现。
- **根因**：`_attachedProviderClaimed` 是**跨轮次共享的单一状态**（经 `lookup_geometry_admission_flags` 发布给注入侧），而注入侧 `geometry_provider_registry` 是在自己的轮询里 `Reconcile` 才把 `kind=4/id=11` 判成 ready 的。旧实现里 `_claimAttachedProvider` 在发现自己被抢占（`stillCurrent()` 为假）时会顺手 `_setAttachedProviderClaim(false)` —— 撤掉的却是**新轮次刚发出的**那份认领。registry 下一拍看到 `attachedReady=false`，于是永远不授予；而宿主的 `_evaluateAndActivate` 又在等 registry 把 `kind=4/id=11` 报成 ready 才肯进 `activeAttached`。**两边互等，形成活锁**，状态永久停在 `suspended/geometryProviderPending`。同一函数里 callback 抛异常那条分支也无条件撤回，同样越权。
- **真机证据**（WoH，`hibiki_glookup.log`，两次会话稳定复现）：
  ```
  17:52:11.401867  geometryAdmission=auto attachedReady=true   request=3 applied=2
  17:52:11.442122  geometryAdmission=auto attachedReady=false  request=4 applied=3   ← 40ms 后被旧轮次撤回
  17:52:11.452144  geometryAdmission=auto attachedReady=false  request=4 applied=4
  ```
  此时 `profile.unsafeLeftClickAccepted=true`、文本在流、variant 与客户区 aspect 匹配、registry 仲裁本身也没问题（`BestReadyProviderIndexLocked` 在 auto 档下 `native < 0` 会正常落到 attached，一个永远不 ready 的原生 provider **不会**挡住兜底）。
- **[x] ① 已修复** — `_claimAttachedProvider` 里两处越权撤回都收紧为「只有仍然当前的这一轮才有权撤回」：
  - 被抢占分支（`!stillCurrent()`）**不再**撤回，直接 `return false`；认领的释放交给当前轮次的 detach / 失败分支。
  - callback 抛异常分支把撤回与 `_activationFailure` 一起移进 `_isCurrent(operation, target)` 判定内。
  未改任何准入判据、未放宽风险门，只修「谁有权改这份共享状态」。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_attached_provider_claim_livelock_guard_test.dart`：源码守卫，锁住「`_claimAttachedProvider` 的被抢占分支里不得出现 `_setAttachedProviderClaim(false)`」，并正向要求认领本身仍必须发出。变异实测：把撤回加回去 → 当场红。`flutter test test/lookup --no-pub` 744 通过；`flutter analyze` 无问题。
- **备注**：⚠️ **真机未复验**。修复后的会话里 WoH 的 attached 停在 `suspended`（`statusReason=null`，且 admission `request` 停在 2、宿主根本没走到认领），说明**还有一条更靠前的分支**在 `_evaluateAndActivate` 里提前返回，与本条活锁不是同一处。下一轮先定位那条 reason 为 null 的 suspended 来源（`_setStatus(suspended)` 的调用点里带 reason 的都已排除，需查 capture 挂起 / target 前后台事件这两类路径），再回来验证本条。
- **关联**：BUG-2135（WoH 原生几何不可用，attached 因此成为该引擎唯一通路）、BUG-2125（attached 表面已实现吞点击 / Shift 悬浮 / 关弹窗不推进 / 带图与整句音频四项行为）。
