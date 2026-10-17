## BUG-3299 · 绑定配置切换后无绑定条目不回到用户自选配置
- **报告**：2026-10-10（反馈 #emN0S3Kypf）：书籍指定配置后，打开该书切到专用配置，再打开没指定配置的书不会回到原来的 Default。
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/profile/profile_view_model.dart` `autoApplyBinding` 经 `resolveProfileId`（`profile_repository.dart`）解析：无绑定命中时兜底返回「当前激活配置」，而绑定命中的切换又走 `switchProfile` 把 `active_profile_id` 写成绑定配置——绑定的临时切换覆盖了用户自己选的配置，无绑定的条目自然停在绑定配置上。
- **[x] ① 已修复** — 新增回退点 `profile_fallback_id`（设备本地、不进 Profile 快照）：绑定第一次离开用户自选配置时记录它；无绑定条目打开时回到它并清除；用户手动 `switchProfile` 作废回退点（`_switchTo` 是内部切换）。`resolveBoundProfileId` 区分「绑定命中」与「兜底」。
- **[x] ② 已加自动化测试** — `fushi/test/profile/profile_binding_fallback_test.dart`（回退到自选配置 / 连续两本绑定书回退点不漂移 / 手动切换作废回退点）。
- **备注**：回退点持久化（重启后仍有效）；自选配置被删时不回退。
