## BUG-2099 · profile 里风险已接受时 `needsRiskAcceptance` 变成死局：不生成 request、按钮不渲染、也没有恢复触发点
- **报告**：2026-09-04（**在用户自己的真实 Fushi 环境**里跑通到这一步时撞上；不是集成测试宿主的隔离根）
- **真实性**：✅ 真 bug，真实环境复现 + 源码三处互锁可直接读出，修后当场越过。
- **症状**：真实环境里 WoH 的 profile 明明是 `unsafeLeftClickAccepted: true`，游戏内查词却永久停在 `状态: needsRiskAcceptance`，工作台上**没有任何可点的东西**能把它推进——「点击风险: 未授权」那颗 pill 是只读展示。
- **根因（三处互锁，缺一不成死局）**：
  1. **状态来源**：注入侧 `SyncToTarget` 在 `Configure` 把 `risk_accepted_` 置真之前就会跑（500ms 健康同步驱动），`ShieldPermitsLookup()` 此时为假，于是发 `riskAcceptanceRequired`；这条路径**不带 reason**，宿主 `case 'riskAcceptanceRequired'` 直接 `reason: event.reason` ⇒ 状态是 `needsRiskAcceptance/null`。
  2. **按钮不渲染**：`gal_attached_text_controller.dart` 的
     ```dart
     bool get needsUnsafeRiskAcceptance =>
         _unsafeRiskAcceptanceRequestToken != null && ... &&
         !(_profile?.unsafeLeftClickAccepted ?? false) && ...
     ```
     **要求「尚未接受」**。profile 里已经是 true ⇒ 恒假 ⇒ `unsafeRiskAcceptanceRequest` 恒 null ⇒
     `gal_attached_lookup_workbench.dart:60` 的 `if (riskRequest != null)` 不成立 ⇒ 「接受风险」按钮**永远不出现**。
     这条判据本身没错（已经接受过的局不该再问一次），错在它与 ① 的状态来源不是同一套判据。
  3. **没有恢复触发点**：`syncSession` 只在 `waitingForBodyThread` 上因新正文重新评估（[[BUG-2096]]）。从 `needsRiskAcceptance` 出发**没有任何**重新评估路径，而只有重新评估才会再调一次 `configure(riskAccepted: true)` 把 ① 的前提消掉。
  三者叠起来：**风险已授权 → 状态说需要授权 → 没按钮可点 → 也回不去**。这正是用户自己那份 Fushi 一直用不上游戏内查词的原因（其 profile 停在 `variants: []`，从未走完校准）。
- **[x] ① 已修复** — 只补**恢复时机**，不动任何准入判据：新正文到达时，若 `_profile.unsafeLeftClickAccepted` 为真且状态是 `needsRiskAcceptance`，与 `waitingForBodyThread` 一样重新走 `_evaluateAndActivate`，由它照常 `configure(riskAccepted: true)`。**没授权的局仍旧停在 `needsRiskAcceptance` 等用户点按钮**，行为不变。
- **真实环境验证**：修前该状态永久不动；修后同一条路径立刻推进到 `suspended/input_shield_rehandshake_pending → activeAttached`，attached 表面在游戏画面上真实渲染出 hook 文本（截图证据 `.codex-test/real/gm5.png`）。
- **[ ] ② 待加自动化测试** — 计划：profile 已接受风险 + 状态被状态事件钉成 `needsRiskAcceptance` + 新正文到达 ⇒ 断言重新评估并进入激活态；变异（去掉 `riskAlreadyGranted` 分支）必须红。
- **备注**：本条只解开死局。真实环境上**仍然**卡在 [[BUG-2098]] 第 2 道闸门（`shield request=4 applied=3` ⇒ `IsNeutralForRehandshake` 恒假），首次查词后表面再也武装不起来。
- **关联**：[[BUG-2096]]（同一类「恢复只挂在一次性边沿上」）、[[BUG-2098]]（下一道闸门）、[[BUG-2092]]（reason 为 null 让这条状态无从追查）。
