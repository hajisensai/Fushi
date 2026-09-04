## BUG-2092 · attached 状态机十二处 `needsRiskAcceptance` / `needsCalibration` / `waitingForBodyThread` 不带 reason，真机上无法定位是哪条分支
- **报告**：2026-09-03（BUG-2091 备注里那条「还有一条更靠前的分支在 `_evaluateAndActivate` 里提前返回、`statusReason=null`」的追查）
- **真实性**：✅ 真 bug，真机上直接被它挡住定位。
- **根因**：`fushi/lib/src/lookup/gal_attached_text_controller.dart` 的 `_setStatus` 有可选 `reason`，但**十二个**分支都只传状态不传原因。同一个 `needsRiskAcceptance` 在该文件里有六个互不相干的来源（profile 缺失、profile 里风险未接受、注入侧回 `riskAcceptanceRequired`、原生 provider 就绪但风险门不满足、标定时未接受、状态事件里风险未接受），`needsCalibration` 有四个，`waitingForBodyThread` 有三个。真机上驱动台账只能读到 `attached=needsRiskAcceptance/null`，**十二选一，无法判断**。
- **真机证据**（WoH，本轮两次会话）：
  ```
  19:38:00  profile status=needsRiskAcceptance reason=null profile={... unsafeLeftClickAccepted: true ...}
  ```
  profile 里风险明明已接受，状态却停在 `needsRiskAcceptance`——六个来源里至少两个当场自相矛盾，但没有 reason 就分不清是哪个，只能靠读源码逐条排除，排了两轮仍未收敛。
- **[x] ① 已修复** — 十二处补上互不重复的 reason token，一处一因，不改任何判据、不改状态取值：
  `evaluate_profile_missing` / `evaluate_profile_risk_not_accepted` / `evaluate_no_variant_for_client` / `evaluate_no_source_text` / `configure_risk_acceptance_required`（优先透传注入侧 `result.reason`）/ `native_provider_risk_gate_unsatisfied` / `calibration_risk_not_accepted` / `state_event_no_variant_for_client` / `state_event_risk_not_accepted` / `state_event_profile_missing` / `state_event_no_source_text` / `target_detached_waiting_body_thread` / `profile_load_failed` / `profile_cleared`。
- **真机复验（本条修好当场生效）**：换上带 token 的构建后，同一路径立刻报出
  ```
  19:47:13  accept=true  attached=waitingForBodyThread/evaluate_no_source_text
  ```
  一步就定位到真正的下一道边界（attached 侧根本没拿到正文文本），而这在补 reason 之前是完全读不出来的。
- **[ ] ② 待加自动化测试** — 计划加源码守卫：`gal_attached_text_controller.dart` 里凡 `_setStatus(` 落到 `needsRiskAcceptance` / `needsCalibration` / `waitingForBodyThread` / `suspended` 四个「非终态、需排障」状态的调用点，必须带 `reason:`；正向再断言 token 互不重复。
- **关联**：[[BUG-2091]]（本条是它备注里悬着的那条更靠前分支的定位工具）、[[BUG-2086]]（同一类问题的注入侧版本：把「音频钩子就绪」谎报成「文本钩子就绪」）。
