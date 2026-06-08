## BUG-138 · 同步服务端提示卡底部留白过多
- **报告**：2026-06-08（用户截图：「这个底下有多余的留白，删一下」）
- **真实性**：✅ 真 bug（沿真实代码路径定位）。截图里的「同步操作」提示卡来自 `buildSyncBackupDestination()` 的 `sync.server_mode_note` 自定义项；该项只是说明文本，没有下方控件，却把 `AdaptiveSettingsRow` 设成 `controlBelow: true`。`AdaptiveSettingsRow` 在该模式下走列布局并使用更高的 `minHeight`，用于承载真正的下方控件；用在纯说明行上会让卡片底部出现多余留白。根因 `hibiki/lib/src/sync/sync_settings_schema.dart:228`。
- **[x] ① 已修复** — 本提交：移除 `sync.server_mode_note` 的 `controlBelow: true`，让说明行回到默认紧凑 row 布局，只收掉多余底部留白，不改变同步服务端门控逻辑。
- **[x] ② 已加自动化测试** — `hibiki/test/sync/sync_settings_visibility_test.dart` 增加源码守卫，确认 `sync.server_mode_note` 仍由 `AdaptiveSettingsRow` 渲染，但不得再声明 `controlBelow: true`。
- **备注**：设置页纯视觉布局修复。已做目标测试；未做设备截图复测。
